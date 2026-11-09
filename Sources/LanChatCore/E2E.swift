import CryptoKit
import Foundation

/// 端到端加密（协议 v3）。
///
/// 每台设备有一对长期 Ed25519 身份密钥。每条 TCP 连接开始时双方交换 hello：
///
///   发起方 → [hello(设备 ID, 身份公钥, 临时 X25519 公钥, 签名)]
///   接收方 → [hello(同上，签名还覆盖发起方的 hello)]
///
/// 双方用临时密钥做 X25519，HKDF（salt = 握手记录哈希）派生两个方向各自的 ChaChaPoly 密钥，
/// 之后所有帧（Header、文件分块、ack）都是加密记录。临时密钥用完即弃，具备前向保密。
/// 身份公钥首次见到时记住（TOFU），之后变化即拒绝通信，需用户手动确认；
/// 双方可比对"安全码"排除首次连接时的中间人。
public enum E2E {
    public static let protocolVersion = 3
    static let label = Data("LanChat-E2E-v3".utf8)

    // MARK: 身份密钥

    /// 读取本机身份私钥；不存在时生成并以 0600 权限保存。
    public static func loadOrCreateIdentityKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        let fm = FileManager.default
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(key.rawRepresentation.base64EncodedString().utf8)
        // 先以 0600 创建空文件再写入，避免内容短暂以默认权限落盘
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        return key
    }

    // MARK: 指纹与安全码

    /// 公钥指纹：SHA-256 前 16 字节，每 2 字节一组的十六进制。
    public static func fingerprint(_ publicKey: Data) -> String {
        let bytes = Array(SHA256.hash(data: publicKey).prefix(16))
        return stride(from: 0, to: bytes.count, by: 2)
            .map { String(format: "%02X%02X", bytes[$0], bytes[$0 + 1]) }
            .joined(separator: " ")
    }

    /// 双方的安全码：与顺序无关，两台设备上显示的结果相同。8 组 × 5 位数字。
    public static func safetyCode(_ a: Data, _ b: Data) -> String {
        let (lo, hi) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = Array(SHA512.hash(data: label + lo + hi))
        return (0..<8).map { g in
            let v = digest[(g * 5)..<(g * 5 + 5)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return String(format: "%05llu", v % 100_000)
        }.joined(separator: " ")
    }

    // MARK: 握手

    /// 发起方一次握手的本地状态。
    struct ClientState {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        let hello: Hello
    }

    /// 握手结果中对方的身份。
    struct PeerIdentity {
        let deviceId: String
        let publicKey: Data
    }

    static func part(_ h: Hello) -> Data {
        let id = Data(h.deviceId.utf8)
        var len = UInt32(id.count).bigEndian
        return Data(bytes: &len, count: 4) + id + h.identityKey + h.ephemeralKey
    }

    static func clientTranscript(_ c: Hello) -> Data { label + Data("C".utf8) + part(c) }
    static func fullTranscript(_ c: Hello, _ s: Hello) -> Data {
        clientTranscript(c) + Data("S".utf8) + part(s)
    }

    static func makeClientHello(deviceId: String, identity: Curve25519.Signing.PrivateKey) throws -> ClientState {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var h = Hello(deviceId: deviceId, identityKey: identity.publicKey.rawRepresentation,
                      ephemeralKey: eph.publicKey.rawRepresentation, signature: Data())
        h.signature = try identity.signature(for: Data(SHA256.hash(data: clientTranscript(h))))
        return ClientState(ephemeral: eph, hello: h)
    }

    /// 接收方：校验发起方 hello，生成应答 hello 与加密通道。信任检查由调用方在发送应答前完成。
    static func respond(to c: Hello, deviceId: String, identity: Curve25519.Signing.PrivateKey)
        throws -> (Hello, SecureChannel, PeerIdentity) {
        try verify(c, transcript: clientTranscript(c))
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var s = Hello(deviceId: deviceId, identityKey: identity.publicKey.rawRepresentation,
                      ephemeralKey: eph.publicKey.rawRepresentation, signature: Data())
        let transcript = fullTranscript(c, s)
        s.signature = try identity.signature(for: Data(SHA256.hash(data: transcript)))
        let keys = try deriveKeys(eph, peerEphemeral: c.ephemeralKey, transcript: transcript)
        let channel = SecureChannel(sendKey: keys.s2c, recvKey: keys.c2s)
        return (s, channel, PeerIdentity(deviceId: c.deviceId, publicKey: c.identityKey))
    }

    /// 发起方：校验接收方应答，得到加密通道。
    static func finish(_ state: ClientState, reply s: Hello) throws -> (SecureChannel, PeerIdentity) {
        let transcript = fullTranscript(state.hello, s)
        try verify(s, transcript: transcript)
        let keys = try deriveKeys(state.ephemeral, peerEphemeral: s.ephemeralKey, transcript: transcript)
        return (SecureChannel(sendKey: keys.c2s, recvKey: keys.s2c),
                PeerIdentity(deviceId: s.deviceId, publicKey: s.identityKey))
    }

    private static func verify(_ h: Hello, transcript: Data) throws {
        guard !h.deviceId.isEmpty,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: h.identityKey),
              pub.isValidSignature(h.signature, for: Data(SHA256.hash(data: transcript))) else {
            throw E2EError.badSignature
        }
    }

    private static func deriveKeys(_ eph: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Data,
                                   transcript: Data) throws -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        let shared = try eph.sharedSecretFromKeyAgreement(with: peer)
        let salt = Data(SHA256.hash(data: transcript))
        let c2s = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("c2s".utf8), outputByteCount: 32)
        let s2c = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("s2c".utf8), outputByteCount: 32)
        return (c2s, s2c)
    }
}

/// hello 帧携带的握手数据（Data 在 JSON 中为 base64）。
struct Hello: Codable, Equatable {
    var deviceId: String
    var identityKey: Data
    var ephemeralKey: Data
    var signature: Data
}

enum E2EError: Error {
    case badSignature
    case decrypt
    case counterExhausted
}

/// 握手完成后的加密通道：两个方向独立密钥，nonce 为递增计数器（TCP 有序，乱序/重放/篡改都会解密失败）。
/// 非线程安全，只在 ChatNode 的串行队列上使用。
final class SecureChannel {
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    init(sendKey: SymmetricKey, recvKey: SymmetricKey) {
        self.sendKey = sendKey
        self.recvKey = recvKey
    }

    /// 加密一条记录，返回 密文+tag（不含长度前缀）。
    func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter < .max else { throw E2EError.counterExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        // ciphertext 可能是切片（startIndex ≠ 0），重新组装成从 0 开始的 Data
        var out = Data(capacity: box.ciphertext.count + 16)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    func open(_ record: Data) throws -> Data {
        guard record.count >= 16, recvCounter < .max else { throw E2EError.decrypt }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(recvCounter),
                                               ciphertext: record.dropLast(16), tag: record.suffix(16))
            let plain = try ChaChaPoly.open(box, using: recvKey)
            recvCounter += 1
            return plain
        } catch {
            throw E2EError.decrypt
        }
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var be = counter.bigEndian
        // 12 字节 nonce = 4 字节 0 + 8 字节大端计数器
        let bytes = Data(count: 4) + Data(bytes: &be, count: 8)
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
