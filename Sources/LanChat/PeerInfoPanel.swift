import AppKit
import LanChatCore
import SwiftUI

/// 列表/面板里的身份小盾牌。
struct VerdictIcon: View {
    let verdict: IdentityVerdict

    var body: some View {
        switch verdict {
        case .keyChanged:
            Image(systemName: "xmark.shield.fill").foregroundStyle(.red)
                .font(.caption).help("对方的加密密钥已变更，通信已暂停，查看设备信息确认")
        case .verified:
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                .font(.caption).help("已与对方核对安全码，端到端加密")
        case .matched:
            Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                .font(.caption).help("端到端加密，MAC 与对方自报一致；尚未核对安全码")
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
                encryptionSection(d)
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

    @ViewBuilder
    private func encryptionSection(_ d: PeerDetail) -> some View {
        Section("端到端加密") {
            if let pending = d.pendingKey {
                Label("对方的加密密钥已变更，通信已暂停", systemImage: "xmark.shield.fill")
                    .foregroundStyle(.red).font(.callout.weight(.medium))
                Text("可能是对方重装了 LanChat 或更换了电脑，也可能有人在冒充。请当面或电话让对方打开本机的设备信息面板，核对下面的新安全码一致后再信任。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                row("原指纹", d.publicKey.map(E2E.fingerprint))
                row("新指纹", E2E.fingerprint(pending))
                row("新安全码", E2E.safetyCode(pending, d.myPublicKey).groupedInTwoLines)
                Button("信任新密钥", role: .destructive) { model.trustNewKey(d.id) }
            } else if d.outdated {
                Label("对方版本过旧，不支持端到端加密", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("本机只进行加密通信，请对方升级 LanChat 后再收发消息。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let key = d.publicKey, let code = d.safetyCode {
                row("安全码", code.groupedInTwoLines)
                Text("与对方当面或电话核对：两台设备上显示的安全码完全一致，即可确认通信没有被中间人窃听。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if d.keyVerified {
                    HStack {
                        Label("已核对", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        Spacer()
                        Button("取消标记") { model.setKeyVerified(d.id, false) }.buttonStyle(.borderless)
                    }
                } else {
                    Button("已核对一致，标记为已验证") { model.setKeyVerified(d.id, true) }
                }
                row("对方指纹", E2E.fingerprint(key))
                row("本机指纹", E2E.fingerprint(d.myPublicKey))
            } else {
                Text("尚未与对方建立过加密连接。对方上线后会自动握手并记录其公钥。")
                    .font(.caption).foregroundStyle(.secondary)
                row("本机指纹", E2E.fingerprint(d.myPublicKey))
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
        if let code = d.safetyCode {
            lines.append("安全码：\(code)\(d.keyVerified ? "（已核对）" : "")  对方指纹：\(d.publicKey.map(E2E.fingerprint) ?? "-")  本机指纹：\(E2E.fingerprint(d.myPublicKey))")
        }
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

private extension String {
    /// "11111 22222 33333 44444 55555 …" → 每行 4 组
    var groupedInTwoLines: String {
        let groups = split(separator: " ")
        return stride(from: 0, to: groups.count, by: 4)
            .map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }
            .joined(separator: "\n")
    }
}
