import AppKit
import LanChatCore
import SwiftUI

/// 列表/面板里的身份小盾牌。
struct VerdictIcon: View {
    let verdict: IdentityVerdict

    var body: some View {
        switch verdict {
        case .verified:
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                .font(.caption).help("身份已校验：ARP 实测 MAC 与对方自报一致")
        case .warning:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                .font(.caption).help("身份校验有不一致项，查看设备信息了解详情")
        case .unknown:
            EmptyView()
        }
    }
}

/// 聊天窗口右侧的设备信息面板。
struct PeerInfoPanel: View {
    @EnvironmentObject var model: AppModel
    let peerId: String

    var body: some View {
        if let d = model.detail(for: peerId) {
            Form {
                header(d)
                Section("身份校验") {
                    ForEach(d.checks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            checkIcon(check.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title).font(.callout.weight(.medium))
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let o = d.observation { observedSection(o) } else if d.arpMAC != nil || !d.ip.isEmpty {
                    Section("本机实测（上次记录）") {
                        row("对方 IP", d.ip)
                        row("ARP MAC", d.arpMAC)
                    }
                }
                if let info = d.info { deviceSection(info) }
                if let info = d.info {
                    ForEach(info.interfaces, id: \.name) { interfaceSection($0) }
                }
                if let b = d.bonjour { bonjourSection(b) }
                Section("记录") {
                    row("设备 ID", d.id)
                    row("首次发现", d.firstSeen.map(fmt))
                    row("最近在线", d.lastSeen.map(fmt))
                }
            }
            .formStyle(.grouped)
            .onAppear { if d.online { model.refreshInfo(peerId) } }
        } else {
            ContentUnavailableView("没有设备信息", systemImage: "questionmark.circle")
        }
    }

    // MARK: Sections

    private func header(_ d: PeerDetail) -> some View {
        Section {
            HStack(spacing: 10) {
                Avatar(name: d.name, online: d.online)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(d.name).font(.headline)
                        VerdictIcon(verdict: d.verdict)
                    }
                    Text(d.infoAt.map { "信息更新于 \(fmt($0))" } ?? "尚未握手")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshInfo(peerId) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(!d.online).help("重新握手刷新")
                Button { copyAll(d) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("拷贝全部信息")
            }
            if d.info == nil {
                Text(d.online ? "对方未返回设备信息，可能是旧版本 LanChat。" : "对方离线，显示的是上次记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func observedSection(_ o: PeerObservation) -> some View {
        Section("本机实测") {
            row("对方地址", [o.ip, o.port.map { "端口 \($0)" }].compactMap { $0 }.joined(separator: " · "))
            row("ARP MAC", o.arpMAC ?? "未读到")
            row("经由本机", [o.localInterface, o.localIP].compactMap { $0 }.joined(separator: " · "))
            row("往返延迟", o.rttMs.map { String(format: "%.1f ms", $0) })
            row("来源", o.outbound ? "本机主动握手" : "对方握手时记录")
            row("时间", fmt(o.at))
        }
    }

    private func deviceSection(_ i: DeviceInfo) -> some View {
        Section("设备（对方自报）") {
            row("显示名称", i.displayName)
            row("电脑名称", i.computerName)
            row("本地主机名", i.localHostName.isEmpty ? nil : i.localHostName + ".local")
            row("主机名", i.hostName)
            row("登录用户", i.userName)
            row("用户全名", i.fullName)
            row("机型", [i.model, i.arch].filter { !$0.isEmpty }.joined(separator: " · "))
            row("系统", i.osVersion)
            row("LanChat", i.appVersion)
            row("监听端口", i.listenPort.map(String.init))
            row("App 启动于", fmt(Date(timeIntervalSince1970: i.startedAt)))
        }
    }

    private func interfaceSection(_ n: NetworkInterfaceInfo) -> some View {
        Section("网卡 \(n.name)" + (n.displayName.map { " · \($0)" } ?? "")) {
            row("类型", n.type)
            row("当前 MAC", n.mac)
            if let hw = n.hardwareMAC, hw != n.mac {
                row("硬件 MAC", hw + (n.mac != nil ? "（当前使用私有地址）" : ""))
            }
            row("IPv4", n.ipv4.isEmpty ? nil : n.ipv4.joined(separator: "\n"))
            row("广播地址", n.broadcast)
            row("IPv6", n.ipv6.isEmpty ? nil : n.ipv6.joined(separator: "\n"))
        }
    }

    private func bonjourSection(_ b: PeerInfo) -> some View {
        Section("Bonjour 广播") {
            row("服务名", b.bonjourName)
            row("服务类型", ChatNode.serviceType)
            row("域", b.bonjourDomain)
            row("收到广播的网卡", b.interfaces.isEmpty ? nil : b.interfaces.joined(separator: ", "))
            row("TXT 记录", b.txt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).font(.callout.monospaced()).textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private func checkIcon(_ s: IdentityCheck.State) -> some View {
        switch s {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private func fmt(_ d: Date) -> String { PeerDetail.dateFormatter.string(from: d) }

    private func copyAll(_ d: PeerDetail) {
        var lines = ["# \(d.name)（\(d.id)）"]
        lines += d.checks.map { "[\($0.state == .pass ? "✓" : $0.state == .warn ? "!" : "?")] \($0.title)：\($0.detail)" }
        if let o = d.observation {
            lines.append("实测：\(o.ip ?? "-"):\(o.port.map(String.init) ?? "-") ARP=\(o.arpMAC ?? "-") 经由 \(o.localInterface ?? "-") \(o.localIP ?? "") RTT=\(o.rttMs.map { String(format: "%.1fms", $0) } ?? "-")")
        }
        if let i = d.info {
            lines.append("设备：\(i.computerName) / \(i.localHostName).local / \(i.userName)（\(i.fullName)）/ \(i.model) \(i.arch) / \(i.osVersion) / LanChat \(i.appVersion)")
            for n in i.interfaces {
                lines.append("网卡 \(n.name) \(n.displayName ?? "")：MAC=\(n.mac ?? "-") 硬件=\(n.hardwareMAC ?? "-") IPv4=\(n.ipv4.joined(separator: ",")) 广播=\(n.broadcast ?? "-") IPv6=\(n.ipv6.joined(separator: ","))")
            }
        }
        if let b = d.bonjour {
            lines.append("Bonjour：\(b.bonjourName).\(ChatNode.serviceType).\(b.bonjourDomain) 网卡=\(b.interfaces.joined(separator: ",")) TXT=\(b.txt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        lines.append("首次发现：\(d.firstSeen.map(fmt) ?? "-")  最近在线：\(d.lastSeen.map(fmt) ?? "-")")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
