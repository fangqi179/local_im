import Foundation
import Network

/// 线上协议（v3，强制端到端加密）：每个 TCP 连接只承载一次投递。
///
///   记录 = 4 字节大端长度 + 内容
///   连接开始：[hello 帧(明文 JSON)] ⇄ [hello 帧(明文 JSON)]，见 `E2E`
///   之后每条记录都是 ChaChaPoly 密文（内容 = 密文 + 16 字节 tag）：
///   文本：  [text 帧]                          → 对方回 [ack 帧]
///   文件：  [file 帧][若干加密分块，明文合计 fileSize 字节] → 对方回 [ack 帧]
///   信息：  [info 帧(本方 DeviceInfo)]              → 对方回 [info 帧(对方 DeviceInfo)]
///
/// 不再兼容 v2 及以前的明文协议：旧版发来的首帧不是 hello，直接断开。
enum FrameType: String, Codable {
    case text
    case file
    case ack
    /// 设备信息握手：请求和应答都携带发送方自己的 DeviceInfo
    case info
    /// 加密握手（明文），见 `E2E`
    case hello
}

struct Header: Codable {
    var type: FrameType
    var msgId: String
    var fromId: String = ""
    var fromName: String = ""
    var fromHost: String?
    var text: String?
    var fileName: String?
    var fileSize: Int64?
    var info: DeviceInfo?
    var hello: Hello?
}

enum WireError: Error {
    case closed
    case badLength
    case badHeader
    case handshake(String)
}

enum Wire {
    static let maxHeaderSize: UInt32 = 8 * 1024 * 1024

    /// 文件分块的明文大小
    static let chunkSize = 256 * 1024

    static func record(_ body: Data) -> Data {
        let len = UInt32(body.count)
        var out = Data([UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff),
                        UInt8(len >> 8 & 0xff), UInt8(len & 0xff)])
        out.append(body)
        return out
    }

    /// 明文帧，只用于 hello。
    static func frame(_ header: Header) -> Data {
        record((try? JSONEncoder().encode(header)) ?? Data())
    }

    /// 加密帧。
    static func secureFrame(_ header: Header, _ channel: SecureChannel) throws -> Data {
        try record(channel.seal(JSONEncoder().encode(header)))
    }

    /// 加密的文件分块。
    static func secureChunk(_ chunk: Data, _ channel: SecureChannel) throws -> Data {
        try record(channel.seal(chunk))
    }

    static func readRecord(_ conn: NWConnection, _ completion: @escaping (Result<Data, Error>) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            guard let data, data.count == 4 else {
                completion(.failure(error ?? WireError.closed)); return
            }
            let len = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len > 0, len <= maxHeaderSize else {
                completion(.failure(WireError.badLength)); return
            }
            conn.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, error in
                guard let body, body.count == Int(len) else {
                    completion(.failure(error ?? WireError.closed)); return
                }
                completion(.success(body))
            }
        }
    }

    /// 读取明文帧（hello）。
    static func readHeader(_ conn: NWConnection, _ completion: @escaping (Result<Header, Error>) -> Void) {
        readRecord(conn) { result in
            completion(result.flatMap { body in
                (try? JSONDecoder().decode(Header.self, from: body)).map { .success($0) } ?? .failure(WireError.badHeader)
            })
        }
    }

    /// 读取并解密一条记录。
    static func readSecure(_ conn: NWConnection, _ channel: SecureChannel,
                           _ completion: @escaping (Result<Data, Error>) -> Void) {
        readRecord(conn) { result in
            completion(result.flatMap { body in Result { try channel.open(body) } })
        }
    }

    /// 读取并解密一个帧。
    static func readSecureHeader(_ conn: NWConnection, _ channel: SecureChannel,
                                 _ completion: @escaping (Result<Header, Error>) -> Void) {
        readSecure(conn, channel) { result in
            completion(result.flatMap { body in
                (try? JSONDecoder().decode(Header.self, from: body)).map { .success($0) } ?? .failure(WireError.badHeader)
            })
        }
    }
}

/// 进度回调节流：最多每 100ms 一次，完成时必发。
final class ProgressThrottle {
    private var last = Date.distantPast
    func shouldEmit(done: Int64, total: Int64) -> Bool {
        if done >= total { return true }
        let now = Date()
        if now.timeIntervalSince(last) >= 0.1 { last = now; return true }
        return false
    }
}

/// 只触发一次的标志。
final class Once {
    private(set) var fired = false
    func fire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}
