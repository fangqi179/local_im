import Foundation
import XCTest
@testable import LanChatCore

final class DeviceInfoTests: XCTestCase {
    func testLocalInfo() throws {
        let info = LocalDevice.info(deviceId: "x", displayName: "测试", listenPort: 1234)
        XCTAssertFalse(info.localHostName.isEmpty)
        XCTAssertFalse(info.model.isEmpty)
        XCTAssertTrue(info.osVersion.hasPrefix("macOS"))
        XCTAssertFalse(info.interfaces.contains { $0.name.hasPrefix("lo") || $0.name.hasPrefix("utun") })
        for i in info.interfaces where i.mac != nil {
            XCTAssertEqual(i.mac!.count, 17, "MAC 格式应为 xx:xx:xx:xx:xx:xx")
        }
        // JSON 往返
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded, info)
        print("本机信息：", info.interfaces.map { "\($0.name) \($0.displayName ?? "") \($0.mac ?? "-") \($0.ipv4) bc=\($0.broadcast ?? "-")" })
    }

    func testMACNormalize() {
        XCTAssertEqual(MAC.normalize("A:1B:2:3c:4D:e"), "0a:1b:02:3c:4d:0e")
    }

    func testMacForIP() {
        var a = NetworkInterfaceInfo(name: "en0"); a.mac = "aa:aa:aa:aa:aa:aa"; a.ipv4 = ["10.0.0.2/24"]
        var b = NetworkInterfaceInfo(name: "en1"); b.mac = "bb:bb:bb:bb:bb:bb"; b.ipv4 = ["192.168.1.9/24"]
        let info = DeviceInfo(deviceId: "", displayName: "", computerName: "", localHostName: "", hostName: "",
                              userName: "", fullName: "", model: "", arch: "", osVersion: "", appVersion: "",
                              listenPort: nil, startedAt: 0, interfaces: [a, b])
        XCTAssertEqual(info.mac(forIP: "192.168.1.9"), "bb:bb:bb:bb:bb:bb")
        XCTAssertEqual(info.mac(forIP: "8.8.8.8"), "aa:aa:aa:aa:aa:aa")
        XCTAssertEqual(info.ips, ["10.0.0.2", "192.168.1.9"])
    }

    /// 与系统 `arp -an` 的结果逐条对拍。
    func testARPMatchesSystemTool() throws {
        try XCTSkipIf(ARPTable.entryCount() == 0, "本进程无权读取 ARP 表（未获本地网络权限），跳过")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let re = try NSRegularExpression(pattern: #"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-f:]+) on"#)
        var checked = 0
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            let ip = String(out[Range(m.range(at: 1), in: out)!])
            let mac = String(out[Range(m.range(at: 2), in: out)!])
            XCTAssertEqual(ARPTable.mac(for: ip), MAC.normalize(mac), ip)
            checked += 1
        }
        print("ARP 对拍条目数：\(checked)")
        XCTAssertNil(ARPTable.mac(for: "203.0.113.77"))
    }
}
