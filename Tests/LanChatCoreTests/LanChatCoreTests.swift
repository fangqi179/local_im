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
    private func startNode(_ id: String, events: @escaping (NodeEvent) -> Void) -> (ChatNode, NWEndpoint) {
        let node = ChatNode(id: id, name: "Node-\(id)", host: "host-\(id)",
                            downloadsDirectory: tmp.appendingPathComponent(id), discovery: false)
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
        b.sendText(msgId: "m1", text: "你好，局域网 👋", to: endpointA)
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
        b.sendFile(msgId: "f1", fileURL: src, to: endpointA)
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
        b.sendFile(msgId: "f2", fileURL: src, to: endpointA)
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
        b.sendFile(msgId: "e1", fileURL: src, to: endpointA)
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
        b.sendText(msgId: "x", text: "hi", to: .hostPort(host: "127.0.0.1", port: 1))
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
        b.sendFile(msgId: "nf", fileURL: tmp.appendingPathComponent("不存在.txt"), to: endpointA)
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
        b.sendText(msgId: "ping1", text: "ping", to: endpointOfA!)
        wait(for: [got, resolved], timeout: 10)
        print("Bonjour 解析到的对方 IP：\(ipOfA ?? "-")")
        XCTAssertNotNil(ipOfA)
        XCTAssertFalse(ipOfA?.contains("%") ?? true)
        a.stop(); b.stop()
    }
}
