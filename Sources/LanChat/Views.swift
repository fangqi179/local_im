import AppKit
import LanChatCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            PeerListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let peer = model.selectedPeer {
                ChatView(peer: peer).id(peer.id)
            } else {
                ContentUnavailableView(
                    "选择一个联系人",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("同一局域网内运行 LanChat 的设备会自动出现在左侧")
                )
            }
        }
        .alert("提示", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct PeerListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let onlinePeers = model.peers.filter(\.online)
        let offlinePeers = model.peers.filter { !$0.online }
        List(selection: $model.selectedPeerId) {
            Section("在线 · \(onlinePeers.count)") {
                if onlinePeers.isEmpty {
                    Text("正在搜索局域网内的设备…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(onlinePeers) { PeerRowView(peer: $0).tag($0.id) }
            }
            if !offlinePeers.isEmpty {
                Section("离线") {
                    ForEach(offlinePeers) { PeerRowView(peer: $0).tag($0.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { MyIdentityBar() }
    }
}

struct PeerRowView: View {
    @EnvironmentObject var model: AppModel
    let peer: PeerRow

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: peer.name, online: peer.online)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(peer.name).fontWeight(.medium).lineLimit(1)
                    VerdictIcon(verdict: peer.verdict)
                    Spacer(minLength: 4)
                    if let t = peer.lastMessage?.timestamp {
                        Text(shortTime(t)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if peer.unread > 0 {
                        Text("\(peer.unread)")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                    }
                }
                if !peer.addressLine.isEmpty {
                    Text(peer.addressLine)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 3)
        .help(peer.addressLine)
        .contextMenu {
            Button("查看设备信息") {
                model.selectedPeerId = peer.id
                model.showInspector = true
            }
            Divider()
            Button("清空聊天记录", role: .destructive) { model.clearConversation(peer.id) }
            if !peer.online {
                Button("移除联系人", role: .destructive) { model.removePeer(peer.id) }
            }
        }
    }

    private var preview: String {
        guard let m = peer.lastMessage else { return peer.online ? "在线" : "离线" }
        switch m.kind {
        case .text: return m.text.replacingOccurrences(of: "\n", with: " ")
        case .file: return "[文件] \(m.fileName ?? "")"
        }
    }
}

struct Avatar: View {
    let name: String
    let online: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(color.gradient)
                .frame(width: 34, height: 34)
                .overlay(Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
            Circle()
                .fill(online ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
    }

    private var color: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .brown]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
}

struct MyIdentityBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: model.displayName, online: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text("本机 · \(model.myHost)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("设置")
        }
        .padding(10)
        .background(.bar)
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let peer: PeerRow
    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, msg in
                            // 与上一条间隔超过 5 分钟时显示时间分隔
                            if i == 0 || msg.timestamp.timeIntervalSince(model.messages[i - 1].timestamp) > 300 {
                                Text(longTime(msg.timestamp))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: model.messages.last?.id) { scrollToBottom(proxy, animated: true) }
            }
            Divider()
            if let reason = peer.blocked {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
                    Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("查看设备信息") { model.showInspector = true }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
            }
            inputBar
        }
        .navigationTitle(peer.name)
        .navigationSubtitle(([peer.online ? "在线" : "离线"] + [peer.addressLine].filter { !$0.isEmpty })
            .joined(separator: " · "))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Label("松开以发送给 \(peer.name)", systemImage: "arrow.down.doc")
                        .font(.title3).padding(12).background(.regularMaterial, in: Capsule()))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard peer.online else { model.alertMessage = "对方当前离线，无法发送文件。"; return false }
            if let reason = peer.blocked { model.alertMessage = reason; return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.sendFiles([url]) }
                }
            }
            return true
        }
        .onAppear { inputFocused = true }
        .inspector(isPresented: $model.showInspector) {
            PeerInfoPanel(peerId: peer.id)
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: {
                    Label("设备信息", systemImage: "info.circle")
                }
                .help("查看对方的设备、网络与身份校验信息")
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: pickFiles) {
                Image(systemName: "paperclip").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("发送文件（也可以直接把文件拖进窗口）")
            .disabled(!peer.canSend)

            TextField(!peer.online ? "对方离线，暂时无法发送"
                        : peer.blocked != nil ? "暂时无法发送（见上方提示）" : "输入消息，回车发送，⌥回车换行",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .disabled(!peer.canSend)
                .onSubmit(send)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

            Button("发送", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!peer.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func send() {
        guard peer.canSend else { return }
        model.sendText(draft)
        draft = ""
        inputFocused = true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "发送"
        panel.message = "选择要发送给 \(peer.name) 的文件"
        if panel.runModal() == .OK { model.sendFiles(panel.urls) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = model.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

struct MessageBubble: View {
    @EnvironmentObject var model: AppModel
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.outgoing { Spacer(minLength: 60); statusView }
            content
                .frame(maxWidth: 520, alignment: message.outgoing ? .trailing : .leading)
                .help(longTime(message.timestamp))
            if !message.outgoing { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .text:
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(message.outgoing ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(message.outgoing ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .contextMenu {
                    Button("拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
        case .file:
            fileCard
        }
    }

    private var fileCard: some View {
        let exists = message.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let done = message.status == .sent || message.status == .received
        return HStack(spacing: 10) {
            Image(nsImage: icon(exists: exists))
                .resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.fileName ?? "文件").lineLimit(2).truncationMode(.middle)
                if let p = model.progress[message.id], !done {
                    ProgressView(value: p).progressViewStyle(.linear).frame(width: 180)
                    Text("\(Int(p * 100))% · \(byteString(message.fileSize))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(fileSubtitle(exists: exists, done: done))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if done && exists { model.open(message) } }
        .contextMenu {
            Button("打开") { model.open(message) }.disabled(!exists || !done)
            Button("在 Finder 中显示") { model.reveal(message) }.disabled(!exists)
        }
    }

    private func fileSubtitle(exists: Bool, done: Bool) -> String {
        let size = byteString(message.fileSize)
        switch message.status {
        case .sending: return "\(size) · 等待发送…"
        case .receiving: return "\(size) · 正在接收…"
        case .failed: return "\(size) · \(message.outgoing ? "发送失败" : "接收失败")"
        case .sent, .received: return exists ? "\(size) · 双击打开" : "\(size) · 文件已移动或删除"
        }
    }

    private func icon(exists: Bool) -> NSImage {
        if exists, let path = message.filePath { return NSWorkspace.shared.icon(forFile: path) }
        let ext = ((message.fileName ?? "") as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    @ViewBuilder private var statusView: some View {
        switch message.status {
        case .sending:
            ProgressView().controlSize(.small)
        case .failed:
            Button { model.retry(message) } label: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("发送失败，点击重试")
        default:
            EmptyView()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""

    var body: some View {
        Form {
            Section("本机") {
                TextField("显示名称", text: $name)
                    .onSubmit { model.rename(name) }
                HStack {
                    Spacer()
                    Button("保存") { model.rename(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == model.displayName)
                }
                LabeledContent("设备 ID") {
                    Text(model.myId).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section("本地存储") {
                LabeledContent("聊天记录") { pathButton(model.dataDirectory) }
                LabeledContent("接收的文件") { pathButton(model.downloadsDirectory) }
            }
            Section {
                Text("LanChat 只在局域网内工作：通过 Bonjour 发现设备，点对点直连传输，不经过任何服务器，所有记录只保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { name = model.displayName }
    }

    private func pathButton(_ url: URL) -> some View {
        Button {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } label: {
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.link)
    }
}

// MARK: - Formatting

extension PeerRow {
    /// "主机名 · IP · MAC"，缺哪项就省略哪项；离线时为最后一次已知信息
    var addressLine: String {
        [host, ip, mac].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

private func shortTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d"
    return f.string(from: d)
}

private func longTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "yyyy年M月d日 HH:mm"
    return f.string(from: d)
}
