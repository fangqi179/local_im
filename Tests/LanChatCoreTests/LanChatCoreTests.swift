import CryptoKit
import Network
import SQLite3
import XCTest
@testable import LanChatCore

final class ChatNodeTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lanchat-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// 启动一个不走 Bonjour 的节点，返回其监听端口。
    private func startNode(_ id: String, key: Curve25519.Signing.PrivateKey = .init(),
                           pinned: [String: Data] = [:],
                           events: @escaping (NodeEvent) -> Void) -> (ChatNode, NWEndpoint) {
        let node = ChatNode(id: id, name: "Node-\(id)", host: "host-\(id)",
                            downloadsDirectory: tmp.appendingPathComponent(id),
                            identityKey: key, pinnedKeys: pinned, discovery: false)
        let ready = expectation(description: "\(id) listening")
        var port: UInt16 = 0
        node.onEvent = { e in
            if case .listening(let p) = e { port = p; ready.fulfill() }
            events(e)
        }
        node.start()
        wait(for: [ready], timeout: 5)
        return (node, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    func testTextDelivery() {
        let received = expectation(description: "received")
        let delivered = expectation(description: "delivered")
        var got: (String, PeerRef)?
        var senderIP: String?
        let (a, endpointA) = startNode("A") { e in
            if case .incomingText(let id, let from, let text) = e, id == "m1" {
                got = (text, from); received.fulfill()
            }
            if case .peerAddress("B", let ip) = e { senderIP = ip }
        }
        let (b, _) = startNode("B") { e in
            if case .outgoingDelivered("m1") = e { delivered.fulfill() }
        }
        b.sendText(msgId: "m1", text: "你好，局域网 👋", to: endpointA, peerId: "A")
        wait(for: [received, delivered], timeout: 5)
        XCTAssertEqual(got?.0, "你好，局域网 👋")
        XCTAssertEqual(got?.1, PeerRef(id: "B", name: "Node-B", host: "host-B"))
        XCTAssertEqual(senderIP, "127.0.0.1", "接收方应从连接上得知发送方 IP")
        a.stop(); b.stop()
    }

    func testFileTransfer() throws {
        let size = 3 * 1024 * 1024 + 123
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8.random(in: 0...255) }
        let src = tmp.appendingPathComponent("报告 v1.bin")
        try Data(bytes).write(to: src)

        let finished = expectation(description: "finished")
        let delivered = expectation(description: "delivered")
        var outURL: URL?
        var startedName: String?
        var sawProgress = false
        let (a, endpointA) = startNode("A") { e in
            switch e {
            case .incomingFileStarted("f1", _, let name, let s, _):
                startedName = name; XCTAssertEqual(s, Int64(size))
            case .incomingFileFinished("f1", let url):
                outURL = url; finished.fulfill()
            default: break
            }
        }
        let (b, _) = startNode("B") { e in
            switch e {
            case .transferProgress("f1", _): sawProgress = true
            case .outgoingDelivered("f1"): delivered.fulfill()
            case .outgoingFailed(_, let r, _): XCTFail(r)
            default: break
            }
        }
        b.sendFile(msgId: "f1", fileURL: src, to: endpointA, peerId: "A")
        wait(for: [finished, delivered], timeout: 20)
        XCTAssertEqual(startedName, "报告 v1.bin")
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(outURL)), Data(bytes))

        // 同名文件再次接收不覆盖
        let finished2 = expectation(description: "finished2")
        a.onEvent = { e in
            if case .incomingFileFinished("f2", let url) = e {
                XCTAssertEqual(url.lastPathComponent, "报告 v1 (1).bin"); finished2.fulfill()
            }
        }
        b.sendFile(msgId: "f2", fileURL: src, to: endpointA, peerId: "A")
        wait(for: [finished2], timeout: 20)
        a.stop(); b.stop()
    }

    func testEmptyFile() throws {
        let src = tmp.appendingPathComponent("empty.txt")
        try Data().write(to: src)
        let delivered = expectation(description: "delivered")
        let (a, endpointA) = startNode("A") { _ in }
        let (b, _) = startNode("B") { e in
            if case .outgoingDelivered("e1") = e { delivered.fulfill() }
        }
        b.sendFile(msgId: "e1", fileURL: src, to: endpointA, peerId: "A")
        wait(for: [delivered], timeout: 5)
        a.stop(); b.stop()
    }

    func testSendToClosedPortFails() {
        let failed = expectation(description: "failed")
        let (b, _) = startNode("B") { e in
            if case .outgoingFailed("x", _, let unreachable) = e {
                XCTAssertTrue(unreachable, "连不上应标记为不可达"); failed.fulfill()
            }
        }
        b.sendText(msgId: "x", text: "hi", to: .hostPort(host: "127.0.0.1", port: 1), peerId: "A")
        wait(for: [failed], timeout: 15)
        b.stop()
    }

    func testMissingFileIsNotUnreachable() {
        let failed = expectation(description: "failed")
        let (a, endpointA) = startNode("A") { _ in }
        let (b, _) = startNode("B") { e in
            if case .outgoingFailed("nf", _, let unreachable) = e {
                XCTAssertFalse(unreachable, "本地文件问题不应把对方判为离线"); failed.fulfill()
            }
        }
        b.sendFile(msgId: "nf", fileURL: tmp.appendingPathComponent("不存在.txt"), to: endpointA, peerId: "A")
        wait(for: [failed], timeout: 5)
        a.stop(); b.stop()
    }

    func testProbe() {
        let (a, endpointA) = startNode("A") { _ in }
        let up = expectation(description: "up")
        let down = expectation(description: "down")
        a.probe(endpointA) { ok in XCTAssertTrue(ok); up.fulfill() }
        a.probe(.hostPort(host: "127.0.0.1", port: 1)) { ok in XCTAssertFalse(ok); down.fulfill() }
        wait(for: [up, down], timeout: 10)
        a.stop()
    }

    func testInfoExchange() {
        let bSawA = expectation(description: "B 得到 A 的信息")
        let aSawB = expectation(description: "A 得到 B 的信息")
        var obsOfA: PeerObservation?
        var obsOfB: PeerObservation?
        let (a, endpointA) = startNode("A") { e in
            if case .peerObserved("B", let o) = e { obsOfB = o; aSawB.fulfill() }
        }
        let (b, _) = startNode("B") { e in
            if case .peerObserved("A", let o) = e { obsOfA = o; bSawA.fulfill() }
        }
        b.refreshInfo(peerId: "A", endpoint: endpointA)
        wait(for: [bSawA, aSawB], timeout: 10)

        XCTAssertEqual(obsOfA?.info?.deviceId, "A")
        XCTAssertEqual(obsOfA?.info?.displayName, "Node-A")
        XCTAssertNotNil(obsOfA?.info?.listenPort)
        XCTAssertEqual(obsOfA?.ip, "127.0.0.1")
        XCTAssertNotNil(obsOfA?.rttMs)
        XCTAssertTrue(obsOfA?.outbound ?? false)

        XCTAssertEqual(obsOfB?.info?.deviceId, "B", "握手是双向的：被查询方也拿到查询方的信息")
        XCTAssertFalse(obsOfB?.outbound ?? true)
        a.stop(); b.stop()
    }

    // MARK: 端到端加密

    func testHandshakePinsKeysOnBothSides() {
        let keyA = Curve25519.Signing.PrivateKey(), keyB = Curve25519.Signing.PrivateKey()
        let aLearned = expectation(description: "A 记住 B 的公钥")
        let bLearned = expectation(description: "B 记住 A 的公钥")
        let delivered = expectation(description: "delivered")
        let (a, endpointA) = startNode("A", key: keyA) { e in
            if case .peerKeyLearned("B", "Node-B", let k) = e {
                XCTAssertEqual(k, keyB.publicKey.rawRepresentation); aLearned.fulfill()
            }
        }
        let (b, _) = startNode("B", key: keyB) { e in
            if case .peerKeyLearned("A", "Node-A", let k) = e {
                XCTAssertEqual(k, keyA.publicKey.rawRepresentation); bLearned.fulfill()
            }
            if case .outgoingDelivered("k1") = e { delivered.fulfill() }
        }
        b.sendText(msgId: "k1", text: "hi", to: endpointA, peerId: "A")
        wait(for: [aLearned, bLearned, delivered], timeout: 5)
        a.stop(); b.stop()
    }

    /// 接收方记住的 B 公钥与实际不同 → 拒绝，并上报密钥变更；发送方失败但不判为不可达。
    func testReceiverRejectsChangedKey() {
        let mismatch = expectation(description: "A 发现 B 的密钥变了")
        let failed = expectation(description: "B 发送失败")
        let (a, endpointA) = startNode("A", pinned: ["B": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation]) { e in
            if case .peerKeyMismatch("B", _, _) = e { mismatch.fulfill() }
            if case .incomingText = e { XCTFail("密钥不符时不应收下消息") }
        }
        let (b, _) = startNode("B") { e in
            if case .outgoingFailed("km", _, let unreachable) = e { XCTAssertFalse(unreachable); failed.fulfill() }
        }
        b.sendText(msgId: "km", text: "hi", to: endpointA, peerId: "A")
        wait(for: [mismatch, failed], timeout: 5)
        a.stop(); b.stop()
    }

    /// 发送方记住的 A 公钥与实际不同（有人冒充 A）→ 不发送内容。
    func testSenderRejectsChangedKey() {
        let mismatch = expectation(description: "B 发现 A 的密钥变了")
        let failed = expectation(description: "B 发送失败")
        let (a, endpointA) = startNode("A") { e in
            if case .incomingText("km2", _, _) = e { XCTFail("密钥不符时不应发出消息") }
        }
        let (b, _) = startNode("B", pinned: ["A": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation]) { e in
            if case .peerKeyMismatch("A", _, _) = e { mismatch.fulfill() }
            if case .outgoingFailed("km2", let reason, _) = e {
                XCTAssertTrue(reason.contains("密钥已变更"), reason); failed.fulfill()
            }
        }
        b.sendText(msgId: "km2", text: "hi", to: endpointA, peerId: "A")
        wait(for: [mismatch, failed], timeout: 5)

        // 用户确认信任新密钥后恢复通信
        let delivered = expectation(description: "delivered")
        b.onEvent = { if case .outgoingDelivered("km3") = $0 { delivered.fulfill() } }
        b.pin(peerId: "A", key: a.publicKey)
        b.sendText(msgId: "km3", text: "hi", to: endpointA, peerId: "A")
        wait(for: [delivered], timeout: 5)
        a.stop(); b.stop()
    }

    /// 端点上的设备不是预期的那台 → 拒绝。
    func testSenderRejectsUnexpectedPeer() {
        let failed = expectation(description: "failed")
        let (a, endpointA) = startNode("A") { e in
            if case .incomingText = e { XCTFail("不应发出消息") }
        }
        let (b, _) = startNode("B") { e in
            if case .outgoingFailed("wp", let reason, _) = e {
                XCTAssertTrue(reason.contains("与预期不符"), reason); failed.fulfill()
            }
        }
        b.sendText(msgId: "wp", text: "hi", to: endpointA, peerId: "C")
        wait(for: [failed], timeout: 5)
        a.stop(); b.stop()
    }

    /// 旧版明文协议的 text 帧不被接受。
    func testPlaintextFrameRejected() {
        let (a, endpointA) = startNode("A") { e in
            if case .incomingText = e { XCTFail("不应接受明文消息") }
        }
        let closed = expectation(description: "connection closed without ack")
        let conn = NWConnection(to: endpointA, using: .tcp)
        conn.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let h = Header(type: .text, msgId: "plain", fromId: "old", fromName: "旧版", text: "明文")
            conn.send(content: Wire.frame(h), completion: .contentProcessed { _ in })
            Wire.readRecord(conn) { result in
                if case .success = result { XCTFail("不应收到任何应答") }
                closed.fulfill()
            }
        }
        conn.start(queue: .global())
        wait(for: [closed], timeout: 5)
        conn.cancel(); a.stop()
    }

    func testSecureChannelDetectsTampering() throws {
        let c = try E2E.makeClientHello(deviceId: "B", identity: .init())
        let (reply, server, peer) = try E2E.respond(to: c.hello, deviceId: "A", identity: .init())
        XCTAssertEqual(peer.deviceId, "B")
        let (client, serverPeer) = try E2E.finish(c, reply: reply)
        XCTAssertEqual(serverPeer.deviceId, "A")

        let sealed = try client.seal(Data("机密".utf8))
        XCTAssertNil(sealed.range(of: Data("机密".utf8)), "密文中不应出现明文")
        XCTAssertEqual(try server.open(sealed), Data("机密".utf8))
        XCTAssertThrowsError(try server.open(sealed), "重放同一条记录应失败")

        var tampered = try client.seal(Data("hello".utf8))
        tampered[0] ^= 1
        XCTAssertThrowsError(try server.open(tampered))
    }

    func testForgedHelloRejected() throws {
        let c = try E2E.makeClientHello(deviceId: "B", identity: .init())
        var forged = c.hello
        forged.deviceId = "A"   // 改设备 ID，签名不再匹配
        XCTAssertThrowsError(try E2E.respond(to: forged, deviceId: "S", identity: .init()))

        // 中间人替换应答方的临时公钥
        let (reply, _, _) = try E2E.respond(to: c.hello, deviceId: "A", identity: .init())
        var mitm = reply
        mitm.ephemeralKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try E2E.finish(c, reply: mitm))
    }

    func testSafetyCodeIsSymmetric() {
        let a = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let b = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(E2E.safetyCode(a, b), E2E.safetyCode(b, a))
        XCTAssertEqual(E2E.safetyCode(a, b).split(separator: " ").count, 8)
        XCTAssertNotEqual(E2E.safetyCode(a, b), E2E.safetyCode(a, a))
        XCTAssertEqual(E2E.fingerprint(a).count, 39)
    }

    func testIdentityKeyFile() throws {
        let url = tmp.appendingPathComponent("sub/identity.key")
        let k1 = try E2E.loadOrCreateIdentityKey(at: url)
        let k2 = try E2E.loadOrCreateIdentityKey(at: url)
        XCTAssertEqual(k1.rawRepresentation, k2.rawRepresentation)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testIPString() {
        XCTAssertEqual(ChatNode.ipString(.hostPort(host: "192.168.1.8", port: 80)), "192.168.1.8")
        XCTAssertEqual(ChatNode.ipString(.hostPort(host: "::ffff:10.0.0.2", port: 80)), "10.0.0.2")
        XCTAssertEqual(ChatNode.ipString(.hostPort(host: .ipv6(IPv6Address("fe80::1%lo0")!), port: 80)), "fe80::1")
        XCTAssertEqual(ChatNode.ipString(.hostPort(host: .ipv4(IPv4Address("192.168.5.15%lo0")!), port: 80)), "192.168.5.15")
        XCTAssertNil(ChatNode.ipString(nil))
    }

    func testSanitize() {
        XCTAssertEqual(ChatNode.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(ChatNode.sanitize(".hidden"), "hidden")
        XCTAssertEqual(ChatNode.sanitize(""), "未命名文件")
        XCTAssertEqual(ChatNode.sanitize("a:b.txt"), "a_b.txt")
    }
}

final class ChatStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lanchat-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ChatStore(url: url)

        store.upsertPeer(id: "p1", name: "老王")
        store.upsertPeer(id: "p1", name: "老王的 Mac")
        XCTAssertEqual(store.peers().map(\.name), ["老王的 Mac"])
        store.upsertPeer(id: "p1", name: "老王的 Mac", host: "wang-mbp")
        store.upsertPeer(id: "p1", name: "老王的 Mac", host: "")   // 空主机名不覆盖
        store.updatePeerIP(id: "p1", ip: "192.168.1.20")
        XCTAssertEqual(store.peers().first?.host, "wang-mbp")
        XCTAssertEqual(store.peers().first?.ip, "192.168.1.20")

        let m1 = ChatMessage(id: "1", peerId: "p1", outgoing: true, kind: .text, text: "hi", status: .sending,
                             timestamp: Date(timeIntervalSince1970: 100))
        let m2 = ChatMessage(id: "2", peerId: "p1", outgoing: false, kind: .file, fileName: "a.pdf",
                             fileSize: 42, filePath: "/tmp/a.pdf", status: .receiving,
                             timestamp: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(store.insert(m1))
        XCTAssertFalse(store.insert(m1), "重复 id 应被忽略")
        XCTAssertTrue(store.insert(m2, read: false))

        XCTAssertEqual(store.messages(peerId: "p1").map(\.id), ["1", "2"])
        XCTAssertEqual(store.lastMessage(peerId: "p1")?.fileName, "a.pdf")
        XCTAssertEqual(store.unreadCount(peerId: "p1"), 1)
        store.markRead(peerId: "p1")
        XCTAssertEqual(store.unreadCount(peerId: "p1"), 0)

        store.failInterrupted()
        XCTAssertEqual(store.message(id: "1")?.status, .failed)
        XCTAssertEqual(store.message(id: "2")?.status, .failed)

        store.updateFile(id: "2", path: nil, status: .received)
        XCTAssertNil(store.message(id: "2")?.filePath)
        XCTAssertEqual(store.message(id: "2")?.status, .received)

        var info = LocalDevice.info(deviceId: "p1", displayName: "老王的 Mac", listenPort: 9)
        info.interfaces = [NetworkInterfaceInfo(name: "en0")]
        store.updatePeerObservation(id: "p1", info: info, arpMAC: "aa:bb:cc:dd:ee:ff")
        store.updatePeerObservation(id: "p1", info: nil, arpMAC: nil)  // nil 不覆盖
        XCTAssertEqual(store.peers().first?.info, info)
        XCTAssertEqual(store.peers().first?.arpMAC, "aa:bb:cc:dd:ee:ff")
        XCTAssertNotNil(store.peers().first?.infoAt)

        // 公钥：首次信任 → 核对 → 出现新公钥 → 用户信任新公钥（清除核对状态）
        let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
        XCTAssertNil(store.peers().first?.publicKey)
        store.pinPeerKey(id: "p1", name: "忽略", key: k1)
        XCTAssertEqual(store.peers().first?.name, "老王的 Mac", "已存在的联系人不改名")
        store.setKeyVerified(id: "p1", true)
        XCTAssertEqual(store.peers().first?.keyVerified, true)
        store.setPendingKey(id: "p1", key: k2)
        XCTAssertEqual(store.peers().first?.publicKey, k1)
        XCTAssertEqual(store.peers().first?.pendingKey, k2)
        store.pinPeerKey(id: "p1", name: "", key: k2)
        XCTAssertEqual(store.peers().first?.publicKey, k2)
        XCTAssertNil(store.peers().first?.pendingKey)
        XCTAssertEqual(store.peers().first?.keyVerified, false)
        store.pinPeerKey(id: "new", name: "新设备", key: k1)
        XCTAssertEqual(store.pinnedKeys(), ["p1": k2, "new": k1])
        store.deletePeer(id: "new")

        store.deletePeer(id: "p1")
        XCTAssertTrue(store.peers().isEmpty)
        XCTAssertTrue(store.messages(peerId: "p1").isEmpty)
    }
}

final class ChatStoreMigrationTests: XCTestCase {
    func testOldSchemaGetsHostAndIPColumns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lanchat-old-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        // 模拟上一版的 peers 表结构
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE peers(id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL); INSERT INTO peers VALUES('p', '旧联系人', 0);", nil, nil, nil)
        sqlite3_close(db)

        let store = try ChatStore(url: url)
        XCTAssertEqual(store.peers().first?.name, "旧联系人")
        XCTAssertEqual(store.peers().first?.host, "")
        store.updatePeerIP(id: "p", ip: "10.1.1.1")
        XCTAssertEqual(store.peers().first?.ip, "10.1.1.1")
        XCTAssertNil(store.peers().first?.publicKey, "旧联系人没有公钥，下次连接按首次见到处理")
        XCTAssertTrue(store.pinnedKeys().isEmpty)
    }
}

/// 真实 Bonjour 发现 + 通过发现到的端点发消息。设置 LANCHAT_BONJOUR_TEST=1 运行。
final class BonjourDiscoveryTests: XCTestCase {
    func testDiscoverAndSend() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LANCHAT_BONJOUR_TEST"] == "1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = ChatNode(id: "bonjour-A-\(UUID().uuidString)", name: "甲", host: "host-甲", downloadsDirectory: dir)
        let b = ChatNode(id: "bonjour-B-\(UUID().uuidString)", name: "乙", downloadsDirectory: dir)
        let found = expectation(description: "B discovers A")
        let got = expectation(description: "A receives")
        var endpointOfA: NWEndpoint?
        let resolved = expectation(description: "B resolves A's IP")
        var ipOfA: String?
        a.onEvent = { if case .incomingText(_, let from, "ping") = $0, from.name == "乙" { got.fulfill() } }
        b.onEvent = { e in
            if case .peersChanged(let list) = e, endpointOfA == nil, let p = list.first(where: { $0.id == a.id }) {
                XCTAssertEqual(p.name, "甲")
                XCTAssertEqual(p.host, "host-甲")
                endpointOfA = p.endpoint; found.fulfill()
            }
            if case .peerAddress(let pid, let ip) = e, pid == a.id, ipOfA == nil { ipOfA = ip; resolved.fulfill() }
        }
        a.start(); b.start()
        wait(for: [found], timeout: 15)
        b.sendText(msgId: "ping1", text: "ping", to: endpointOfA!, peerId: a.id)
        wait(for: [got, resolved], timeout: 10)
        print("Bonjour 解析到的对方 IP：\(ipOfA ?? "-")")
        XCTAssertNotNil(ipOfA)
        XCTAssertFalse(ipOfA?.contains("%") ?? true)
        a.stop(); b.stop()
    }
}
