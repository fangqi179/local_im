import Foundation
import LanChatCore

/// 一项身份校验结果。
struct IdentityCheck: Identifiable, Equatable {
    enum State { case pass, warn, unknown }
    let id: String
    let title: String
    let state: State
    let detail: String
}

/// 身份总评，用于列表里的小盾牌。
enum IdentityVerdict: Equatable {
    case keyChanged // 对方加密密钥变更，通信已阻断
    case warning    // 至少一项不一致
    case verified   // 已与对方核对安全码（密码学意义上的确认），且无告警
    case matched    // 未核对安全码，但 ARP 实测 MAC 与对方自报一致
    case unknown    // 信息不足
}

/// 设备信息面板所需的全部数据。
struct PeerDetail {
    let id: String
    let name: String
    let online: Bool
    let firstSeen: Date?
    let lastSeen: Date?
    /// Bonjour 广播（仅在线时有）
    let bonjour: PeerInfo?
    /// 对方自报（本次握手，否则为上次保存的）
    let info: DeviceInfo?
    let infoAt: Date?
    /// 本次运行中最近一次握手的实测信息
    let observation: PeerObservation?
    let ip: String
    /// ARP 实测 MAC（本次或上次保存的）
    let arpMAC: String?
    /// 与上次记录相比 MAC 全部变了：上次的 MAC 集合
    let previousMACs: Set<String>?
    /// 已信任的对方身份公钥
    let publicKey: Data?
    let keyVerified: Bool
    /// 对方出示的新公钥（待确认）
    let pendingKey: Data?
    let myPublicKey: Data
    /// 对方广播的协议版本低于本机（不支持加密）
    let outdated: Bool

    /// 双方的安全码（尚未握手时为 nil）
    var safetyCode: String? { publicKey.map { E2E.safetyCode($0, myPublicKey) } }

    /// 列表和标题里显示的 MAC：优先 ARP 实测，其次对方自报的、与连接 IP 同网卡的 MAC，最后用广播里的
    var displayMAC: String {
        arpMAC ?? info?.mac(forIP: ip.isEmpty ? nil : ip) ?? bonjour?.txt["mac"] ?? ""
    }

    var checks: [IdentityCheck] {
        var out: [IdentityCheck] = []
        let reported = info?.macs ?? []

        // 0. 端到端加密
        if let pendingKey {
            out.append(.init(id: "e2e", title: "加密密钥", state: .warn,
                             detail: "对方出示了新的身份公钥（\(E2E.fingerprint(pendingKey))），与之前记录的不同，通信已阻断"))
        } else if outdated {
            out.append(.init(id: "e2e", title: "加密密钥", state: .warn,
                             detail: "对方的 LanChat 版本过旧，不支持端到端加密，无法通信"))
        } else if publicKey != nil {
            out.append(keyVerified
                ? .init(id: "e2e", title: "加密密钥", state: .pass, detail: "端到端加密，已与对方核对安全码")
                : .init(id: "e2e", title: "加密密钥", state: .unknown,
                        detail: "端到端加密。首次连接时记录了对方公钥，尚未核对安全码"))
        } else {
            out.append(.init(id: "e2e", title: "加密密钥", state: .unknown, detail: "尚未与对方完成加密握手"))
        }

        // 1. ARP 实测 MAC vs 自报
        if let arp = arpMAC.map(MAC.normalize) {
            if reported.isEmpty {
                out.append(.init(id: "mac", title: "MAC 地址", state: .unknown,
                                 detail: "ARP 实测 \(arp)，对方未上报网卡信息（可能是旧版本）"))
            } else if reported.contains(arp) {
                let iface = info?.interfaces.first { [$0.mac, $0.hardwareMAC].compactMap { $0.map(MAC.normalize) }.contains(arp) }
                out.append(.init(id: "mac", title: "MAC 地址", state: .pass,
                                 detail: "ARP 实测 \(arp) 与对方自报的 \(iface.map { "\($0.name)（\($0.displayName ?? "")）" } ?? "网卡") 一致"))
            } else {
                out.append(.init(id: "mac", title: "MAC 地址", state: .warn,
                                 detail: "ARP 实测 \(arp) 不在对方自报的 MAC 中。若双方不在同一网段（经过路由器）属正常，否则对方信息可能被伪造"))
            }
        } else {
            out.append(.init(id: "mac", title: "MAC 地址", state: .unknown,
                             detail: "未能从 ARP 表读到对方 MAC（跨网段、仅 IPv6，或本机未授予\u{201C}本地网络\u{201D}权限）"))
        }

        // 2. 连接 IP vs 自报
        if let info, !ip.isEmpty {
            if info.ips.contains(ip) {
                out.append(.init(id: "ip", title: "IP 地址", state: .pass, detail: "连接实测 \(ip) 属于对方自报的网卡地址"))
            } else {
                out.append(.init(id: "ip", title: "IP 地址", state: .warn,
                                 detail: "连接实测 \(ip) 不在对方自报的地址中（可能经过 NAT / VPN）"))
            }
        }

        // 3. 设备 ID
        if let info {
            if info.deviceId == id {
                out.append(.init(id: "id", title: "设备 ID", state: .pass, detail: "握手应答的设备 ID 与广播一致"))
            } else {
                out.append(.init(id: "id", title: "设备 ID", state: .warn,
                                 detail: "应答方自称 \(info.deviceId)，与广播的 \(id) 不一致"))
            }
        }

        // 4. Bonjour 广播里的 MAC vs 自报
        if let txtMAC = bonjour?.txt["mac"].map(MAC.normalize), !reported.isEmpty {
            out.append(reported.contains(txtMAC)
                ? .init(id: "txt", title: "广播信息", state: .pass, detail: "Bonjour 广播的 MAC \(txtMAC) 与握手信息一致")
                : .init(id: "txt", title: "广播信息", state: .warn, detail: "Bonjour 广播的 MAC \(txtMAC) 与握手信息不一致"))
        }

        // 5. 与历史记录对比
        if let prev = previousMACs {
            out.append(.init(id: "history", title: "历史记录", state: .warn,
                             detail: "MAC 与上次记录完全不同（上次：\(prev.sorted().joined(separator: ", "))）。可能更换了网卡、开启了 Wi-Fi 私有地址，或是另一台设备冒用了此 ID"))
        } else if let firstSeen, info != nil {
            out.append(.init(id: "history", title: "历史记录", state: .pass,
                             detail: "自 \(Self.dateFormatter.string(from: firstSeen)) 首次发现以来，硬件信息未发生变化"))
        }
        return out
    }

    var verdict: IdentityVerdict {
        if pendingKey != nil { return .keyChanged }
        let c = checks
        if c.contains(where: { $0.state == .warn }) { return .warning }
        if keyVerified { return .verified }
        if c.first(where: { $0.id == "mac" })?.state == .pass { return .matched }
        return .unknown
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
