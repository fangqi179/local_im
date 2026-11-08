import Foundation

public enum Diagnostics {
    /// 本机网络身份信息的文本报告，用于排查 MAC / ARP 是否可读。
    public static func report() -> String {
        let info = LocalDevice.info(deviceId: "-", displayName: "-", listenPort: nil)
        var lines = ["主机 \(info.localHostName) / \(info.computerName) / \(info.model) / \(info.osVersion)"]
        for i in info.interfaces {
            let arpSelf = i.ipv4.first.map { ARPTable.mac(for: $0.components(separatedBy: "/")[0]) ?? "nil" } ?? "-"
            lines.append("\(i.name) \(i.displayName ?? "") 当前MAC=\(i.mac ?? "nil") 硬件MAC=\(i.hardwareMAC ?? "nil") 自身ARP=\(arpSelf) \(i.ipv4) bc=\(i.broadcast ?? "-")")
        }
        lines.append("ARP 表条目数：\(ARPTable.entryCount())")
        // LANCHAT_DIAG_IPS="1.2.3.4 5.6.7.8"：逐个查询 ARP，用于与 `arp -an` 对拍
        for ip in (ProcessInfo.processInfo.environment["LANCHAT_DIAG_IPS"] ?? "").split(separator: " ") {
            lines.append("ARP \(ip) \(ARPTable.mac(for: String(ip)) ?? "nil")")
        }
        return lines.joined(separator: "\n")
    }
}
