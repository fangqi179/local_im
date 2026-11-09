import AppKit
import CryptoKit
import Foundation
import LanChatCore
import SystemConfiguration
import UserNotifications

struct PeerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let ip: String
    let mac: String
    let verdict: IdentityVerdict
    let online: Bool
    /// 不能通信的原因（加密密钥变更待确认、对方版本过旧）
    let blocked: String?
    let lastMessage: ChatMessage?
    let unread: Int

    var canSend: Bool { online && blocked == nil }
}

/// 本机身份：首次启动生成唯一 id，名字默认为电脑名称。
struct Identity: Codable {
    var id: String
    var name: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var peers: [PeerRow] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var displayName: String
    @Published var alertMessage: String?
    /// 聊天窗口右侧的设备信息面板
    @Published var showInspector = false
    @Published var selectedPeerId: String? {
        didSet {
            guard oldValue != selectedPeerId else { return }
            loadMessages()
            markSelectedRead()
        }
    }

    let dataDirectory: URL
    let downloadsDirectory: URL
    private let identityURL: URL
    private var identity: Identity
    private let store: ChatStore
    private let node: ChatNode
    /// Bonjour 当前能看到的设备
    private var online: [String: PeerInfo] = [:]
    /// 本次运行中得知的对方 IP（数据库里保存最后一次，供离线时显示）
    private var addresses: [String: String] = [:]
    /// 本次运行中最近一次握手结果
    @Published private(set) var observations: [String: PeerObservation] = [:]
    /// MAC 与历史记录完全不同的设备 → 上次的 MAC 集合
    private var macChanged: [String: Set<String>] = [:]
    private var storedPeers: [String: StoredPeer] = [:]
    /// Bonjour 仍能看到、但实际连不上的设备（对方异常掉线，缓存记录尚未过期）。
    /// 视为离线，并定时探测，连得上或收到对方消息就恢复。
    private var unreachable: Set<String> = []
    private var probing: Set<String> = []
    private var probeTimer: Timer?
    private static let probeInterval: TimeInterval = 5
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    var myId: String { identity.id }
    /// 本机主机名（LocalHostName，与 `xxx.local` 中的 xxx 一致）
    let myHost: String = (SCDynamicStoreCopyLocalHostName(nil) as String?)
        ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    var selectedPeer: PeerRow? { peers.first { $0.id == selectedPeerId } }

    init() {
        // LANCHAT_PROFILE 允许同一台机器运行多份实例（调试用）
        let profile = ProcessInfo.processInfo.environment["LANCHAT_PROFILE"].map { "-\($0)" } ?? ""
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = support.appendingPathComponent("LanChat\(profile)", isDirectory: true)
        downloadsDirectory = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LanChat\(profile)", isDirectory: true)
        try? fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        identityURL = dataDirectory.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: identityURL),
           let saved = try? JSONDecoder().decode(Identity.self, from: data) {
            identity = saved
        } else {
            let name = Host.current().localizedName ?? NSFullUserName()
            identity = Identity(id: UUID().uuidString, name: name + profile)
            try? JSONEncoder().encode(identity).write(to: identityURL)
        }
        displayName = identity.name

        do {
            store = try ChatStore(url: dataDirectory.appendingPathComponent("chat.sqlite"))
        } catch {
            fatalError("无法打开本地数据库：\(error)")
        }
        store.failInterrupted()

        let identityKey: Curve25519.Signing.PrivateKey
        do {
            identityKey = try E2E.loadOrCreateIdentityKey(at: dataDirectory.appendingPathComponent("identity.key"))
        } catch {
            // 不静默重新生成：那会让所有联系人看到"密钥已变更"
            fatalError("无法读取本机加密密钥 identity.key：\(error)")
        }
        node = ChatNode(id: identity.id, name: identity.name, host: myHost, downloadsDirectory: downloadsDirectory,
                        identityKey: identityKey, pinnedKeys: store.pinnedKeys())
        node.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        node.start()
        refreshPeers()

        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSelectedRead() }
        }
    }

    // MARK: - Actions

    func rename(_ newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != identity.name else { return }
        identity.name = name
        displayName = name
        try? JSONEncoder().encode(identity).write(to: identityURL)
        node.updateName(name)
    }

    func sendText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let peerId = selectedPeerId, let info = reachable(peerId) else { return }
        if let reason = blockReason(peerId) { alertMessage = reason; return }
        let msg = ChatMessage(peerId: peerId, outgoing: true, kind: .text, text: text, status: .sending)
        store.insert(msg)
        messages.append(msg)
        node.sendText(msgId: msg.id, text: text, to: info.endpoint, peerId: peerId)
        refreshPeers()
    }

    func sendFiles(_ urls: [URL]) {
        guard let peerId = selectedPeerId else { return }
        guard let info = reachable(peerId) else { alertMessage = "对方当前离线，无法发送文件。"; return }
        if let reason = blockReason(peerId) { alertMessage = reason; return }
        var skipped: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                skipped.append(url.lastPathComponent); continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let msg = ChatMessage(peerId: peerId, outgoing: true, kind: .file, fileName: url.lastPathComponent,
                                  fileSize: size, filePath: url.path, status: .sending)
            store.insert(msg)
            messages.append(msg)
            progress[msg.id] = 0
            node.sendFile(msgId: msg.id, fileURL: url, to: info.endpoint, peerId: peerId)
        }
        if !skipped.isEmpty {
            alertMessage = "暂不支持发送文件夹，已跳过：\(skipped.joined(separator: "、"))\n可先压缩成 zip 再发送。"
        }
        refreshPeers()
    }

    func retry(_ msg: ChatMessage) {
        guard msg.outgoing, msg.status == .failed else { return }
        guard let info = reachable(msg.peerId) else { alertMessage = "对方当前离线，稍后再试。"; return }
        if let reason = blockReason(msg.peerId) { alertMessage = reason; return }
        switch msg.kind {
        case .text:
            node.sendText(msgId: msg.id, text: msg.text, to: info.endpoint, peerId: msg.peerId)
        case .file:
            guard let path = msg.filePath, FileManager.default.fileExists(atPath: path) else {
                alertMessage = "原文件已不存在，无法重发。"; return
            }
            progress[msg.id] = 0
            node.sendFile(msgId: msg.id, fileURL: URL(fileURLWithPath: path), to: info.endpoint, peerId: msg.peerId)
        }
        setStatus(msg.id, .sending)
    }

    func clearConversation(_ peerId: String) {
        store.clearMessages(peerId: peerId)
        if peerId == selectedPeerId { messages = [] }
        refreshPeers()
    }

    func removePeer(_ peerId: String) {
        store.deletePeer(id: peerId)
        node.unpin(peerId: peerId)  // 再次出现时按新设备重新记录公钥
        if peerId == selectedPeerId { selectedPeerId = nil }
        refreshPeers()
    }

    // MARK: - 端到端加密

    var myPublicKey: Data { node.publicKey }

    /// 不能与对方通信的原因；nil 表示可以通信。
    func blockReason(_ peerId: String) -> String? {
        let name = online[peerId]?.name ?? storedPeers[peerId]?.name ?? "对方"
        if storedPeers[peerId]?.pendingKey != nil {
            return "「\(name)」的加密密钥已变更，通信已暂停。请与对方核对安全码后，在设备信息面板中选择\u{201C}信任新密钥\u{201D}。"
        }
        if let txt = online[peerId]?.txt, (Int(txt["ver"] ?? "") ?? 0) < E2E.protocolVersion {
            return "「\(name)」使用的 LanChat 版本过旧，不支持端到端加密，请对方升级后再通信。"
        }
        return nil
    }

    /// 用户确认接受对方的新公钥。
    func trustNewKey(_ peerId: String) {
        guard let p = storedPeers[peerId], let key = p.pendingKey else { return }
        store.pinPeerKey(id: peerId, name: p.name, key: key)
        node.pin(peerId: peerId, key: key)
        refreshPeers()
        node.refreshInfo(peerId: peerId)
    }

    /// 标记已（或取消）与对方核对安全码。
    func setKeyVerified(_ peerId: String, _ verified: Bool) {
        store.setKeyVerified(id: peerId, verified)
        refreshPeers()
    }

    func reveal(_ msg: ChatMessage) {
        guard let path = msg.filePath, FileManager.default.fileExists(atPath: path) else {
            alertMessage = "文件已被移动或删除。"; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ msg: ChatMessage) {
        guard let path = msg.filePath, FileManager.default.fileExists(atPath: path) else {
            alertMessage = "文件已被移动或删除。"; return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Node events

    private func handle(_ event: NodeEvent) {
        switch event {
        case .listening:
            break
        case .listenerFailed(let reason):
            NSLog("LanChat listener failed: %@", reason)
        case .peersChanged(let list):
            online = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // 从 Bonjour 消失的设备本来就是离线，不再需要探测；重新出现时按新设备对待
            unreachable.formIntersection(online.keys)
            for p in list { store.upsertPeer(id: p.id, name: p.name, host: p.host) }
            refreshPeers()
        case .peerAddress(let peerId, let ip):
            // 同一设备可能先后通过 IPv4 / IPv6 连接，优先保留 IPv4，便于阅读
            if let current = addresses[peerId], Self.isIPv4(current), !Self.isIPv4(ip) { break }
            guard addresses[peerId] != ip else { break }
            addresses[peerId] = ip
            store.updatePeerIP(id: peerId, ip: ip)
            refreshPeers()
        case .peerObserved(let peerId, let obs):
            var obs = obs
            let previous = storedPeers[peerId]
            if obs.arpMAC == nil, obs.ip != nil, let old = observations[peerId], old.ip == obs.ip {
                obs.arpMAC = old.arpMAC  // 对方来查询时 ARP 可能还没刷新，沿用同一 IP 的上次结果
            }
            if let new = obs.info?.macs, !new.isEmpty, let old = previous?.info?.macs, !old.isEmpty,
               new.isDisjoint(with: old) {
                macChanged[peerId] = old
                NSLog("LanChat peer %@ MAC changed: %@ -> %@", peerId, old.sorted().joined(separator: ","),
                      new.sorted().joined(separator: ","))
            }
            observations[peerId] = obs
            store.updatePeerObservation(id: peerId, info: obs.info, arpMAC: obs.arpMAC, at: obs.at)
            refreshPeers()
        case .incomingText(let msgId, let from, let text):
            let msg = ChatMessage(id: msgId, peerId: from.id, outgoing: false, kind: .text,
                                  text: text, status: .received)
            receive(msg, from: from, preview: text)
        case .incomingFileStarted(let msgId, let from, let fileName, let size, let url):
            let msg = ChatMessage(id: msgId, peerId: from.id, outgoing: false, kind: .file, fileName: fileName,
                                  fileSize: size, filePath: url.path, status: .receiving)
            progress[msgId] = 0
            if !receive(msg, from: from, preview: "[文件] \(fileName)") {
                // 对方重传之前失败的文件
                store.updateFile(id: msgId, path: url.path, status: .receiving)
                updateLocal(msgId) { $0.filePath = url.path; $0.status = .receiving }
            }
        case .transferProgress(let msgId, let fraction):
            progress[msgId] = fraction
        case .incomingFileFinished(let msgId, let url):
            progress[msgId] = nil
            store.updateFile(id: msgId, path: url.path, status: .received)
            updateLocal(msgId) { $0.filePath = url.path; $0.status = .received }
            refreshPeers()
        case .incomingFileFailed(let msgId):
            progress[msgId] = nil
            setStatus(msgId, .failed)
        case .outgoingDelivered(let msgId):
            progress[msgId] = nil
            setStatus(msgId, .sent)
        case .outgoingFailed(let msgId, let reason, let isUnreachable):
            NSLog("LanChat send %@ failed: %@", msgId, reason)
            progress[msgId] = nil
            setStatus(msgId, .failed)
            if isUnreachable, let peerId = store.message(id: msgId)?.peerId {
                markUnreachable(peerId)
            }
        case .peerKeyLearned(let peerId, let name, let key):
            store.pinPeerKey(id: peerId, name: online[peerId]?.name ?? name, key: key)
            refreshPeers()
        case .peerKeyMismatch(let peerId, let name, let key):
            let alreadyPending = storedPeers[peerId]?.pendingKey == key
            store.setPendingKey(id: peerId, key: key)
            refreshPeers()
            guard !alreadyPending else { break }
            NSLog("LanChat peer %@ presented a different identity key: %@", peerId, E2E.fingerprint(key))
            let shown = online[peerId]?.name ?? storedPeers[peerId]?.name ?? name
            alertMessage = """
                「\(shown)」出示的加密密钥与之前记录的不同，已拒绝与其通信。

                可能是对方重装了 LanChat 或更换了电脑，也可能有人在冒充。请当面或电话与对方核对安全码，确认无误后在设备信息面板中选择\u{201C}信任新密钥\u{201D}。
                """
        }
    }

    /// 保存一条收到的消息。返回 false 表示是重复消息。
    @discardableResult
    private func receive(_ msg: ChatMessage, from: PeerRef, preview: String) -> Bool {
        unreachable.remove(from.id)  // 能收到对方消息，说明对方在线
        store.upsertPeer(id: from.id, name: online[from.id]?.name ?? from.name, host: from.host)
        if let ip = addresses[from.id] { store.updatePeerIP(id: from.id, ip: ip) }
        let viewing = msg.peerId == selectedPeerId && NSApp.isActive
        guard store.insert(msg, read: viewing) else { return false }
        if msg.peerId == selectedPeerId { messages.append(msg) }
        refreshPeers()
        if !viewing { notify(title: from.name, body: preview) }
        return true
    }

    private func setStatus(_ id: String, _ status: MessageStatus) {
        store.updateStatus(id: id, status: status)
        updateLocal(id) { $0.status = status }
        refreshPeers()
    }

    private func updateLocal(_ id: String, _ mutate: (inout ChatMessage) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { mutate(&messages[i]) }
    }

    private func loadMessages() {
        messages = selectedPeerId.map { store.messages(peerId: $0) } ?? []
    }

    private func markSelectedRead() {
        guard let id = selectedPeerId, NSApp.isActive else { return }
        store.markRead(peerId: id)
        refreshPeers()
    }

    private func refreshPeers() {
        let stored = store.peers()
        storedPeers = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = stored.map { p in
            let d = detail(for: p.id)
            return PeerRow(id: p.id, name: online[p.id]?.name ?? p.name,
                           host: online[p.id]?.host.nonEmpty ?? p.host, ip: addresses[p.id] ?? p.ip,
                           mac: d?.displayMAC ?? "", verdict: d?.verdict ?? .unknown,
                           online: reachable(p.id) != nil, blocked: blockReason(p.id),
                           lastMessage: store.lastMessage(peerId: p.id), unread: store.unreadCount(peerId: p.id))
        }
        peers = rows.sorted { a, b in
            if a.online != b.online { return a.online }
            let ta = a.lastMessage?.timestamp ?? .distantPast
            let tb = b.lastMessage?.timestamp ?? .distantPast
            if ta != tb { return ta > tb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let unread = peers.reduce(0) { $0 + $1.unread }
        NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    private static func isIPv4(_ ip: String) -> Bool { !ip.contains(":") && ip.contains(".") }

    // MARK: - Device info

    func detail(for peerId: String) -> PeerDetail? {
        let p = storedPeers[peerId]
        guard p != nil || online[peerId] != nil else { return nil }
        let obs = observations[peerId]
        return PeerDetail(
            id: peerId,
            name: online[peerId]?.name ?? p?.name ?? "",
            online: reachable(peerId) != nil,
            firstSeen: p?.firstSeen,
            lastSeen: p?.lastSeen,
            bonjour: online[peerId],
            info: obs?.info ?? p?.info,
            infoAt: obs?.at ?? p?.infoAt,
            observation: obs,
            ip: addresses[peerId] ?? p?.ip ?? "",
            arpMAC: obs?.arpMAC ?? p?.arpMAC.nonEmpty,
            previousMACs: macChanged[peerId],
            publicKey: p?.publicKey,
            keyVerified: p?.keyVerified ?? false,
            pendingKey: p?.pendingKey,
            myPublicKey: myPublicKey,
            outdated: online[peerId].map { (Int($0.txt["ver"] ?? "") ?? 0) < E2E.protocolVersion } ?? false
        )
    }

    /// 重新握手刷新对方设备信息（设备信息面板的"刷新"按钮）。
    func refreshInfo(_ peerId: String) {
        node.refreshInfo(peerId: peerId)
    }

    // MARK: - Reachability

    /// 真正可发送的对方：Bonjour 可见且没有被判定为连不上。
    private func reachable(_ peerId: String) -> PeerInfo? {
        unreachable.contains(peerId) ? nil : online[peerId]
    }

    private func markUnreachable(_ peerId: String) {
        guard online[peerId] != nil, unreachable.insert(peerId).inserted else { return }
        NSLog("LanChat peer %@ unreachable, marked offline", peerId)
        refreshPeers()
        if probeTimer == nil {
            probeTimer = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.probeUnreachable() }
            }
        }
    }

    private func probeUnreachable() {
        guard !unreachable.isEmpty else {
            probeTimer?.invalidate(); probeTimer = nil; return
        }
        for peerId in unreachable where !probing.contains(peerId) {
            guard let info = online[peerId] else { continue }
            probing.insert(peerId)
            node.probe(info.endpoint) { [weak self] ok in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probing.remove(peerId)
                    if ok, self.unreachable.remove(peerId) != nil {
                        NSLog("LanChat peer %@ reachable again", peerId)
                        self.refreshPeers()
                    }
                }
            }
        }
    }

    private func notify(title: String, body: String) {
        NSApp.requestUserAttention(.informationalRequest)
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
