import Foundation
import Network

public struct PeerRef: Equatable, Sendable {
    public let id: String
    public let name: String
    /// 对方主机名（LocalHostName），旧版本客户端可能为空
    public var host: String = ""
}

public struct PeerInfo: Equatable {
    public let id: String
    public let name: String
    public let host: String
    public let endpoint: NWEndpoint
    /// Bonjour 广播的原始信息
    public var bonjourName: String = ""
    public var bonjourDomain: String = ""
    /// 本机在哪些网卡上收到了对方的广播
    public var interfaces: [String] = []
    public var txt: [String: String] = [:]
}

/// 一次与对方的 info 握手得到的结果：对方自报的信息 + 本机实测的信息。
public struct PeerObservation: Equatable, Sendable {
    /// 对方自报（旧版本客户端为 nil）
    public var info: DeviceInfo?
    /// 实测：连接对端 IP / 端口
    public var ip: String?
    public var port: UInt16?
    /// 实测：本机经由哪块网卡、哪个本机地址连到对方
    public var localInterface: String?
    public var localIP: String?
    /// 实测：本机 ARP 表中对方 IP 对应的 MAC（跨网段或无权限时为 nil）
    public var arpMAC: String?
    /// 实测：info 请求往返耗时（仅主动查询时有）
    public var rttMs: Double?
    /// true = 本机主动查询；false = 对方来查询本机时顺带得到
    public var outbound: Bool
    public var at: Date
}

public enum NodeEvent {
    case listening(port: UInt16)
    case listenerFailed(String)
    case peersChanged([PeerInfo])
    /// 得知对方的 IP 地址：来自主动解析或一次真实连接的对端地址。
    case peerAddress(peerId: String, ip: String)
    case peerObserved(peerId: String, PeerObservation)
    case incomingText(msgId: String, from: PeerRef, text: String)
    case incomingFileStarted(msgId: String, from: PeerRef, fileName: String, size: Int64, url: URL)
    case incomingFileFinished(msgId: String, url: URL)
    case incomingFileFailed(msgId: String)
    case transferProgress(msgId: String, fraction: Double)
    case outgoingDelivered(msgId: String)
    /// unreachable = 连接根本没建立起来（对方很可能已掉线），区别于读文件失败等本地原因。
    case outgoingFailed(msgId: String, reason: String, unreachable: Bool)
}

/// 局域网节点：Bonjour 广播 + 发现，TCP 收发文本和文件。
/// 所有网络工作在内部串行队列执行，事件回调 `onEvent` 在主线程派发。
public final class ChatNode {
    public static let serviceType = "_lanchat._tcp"

    public let id: String
    public let downloadsDirectory: URL
    public var onEvent: ((NodeEvent) -> Void)?

    private var name: String
    private let host: String
    private let discovery: Bool
    /// Bonjour 当前可见设备 id → 端点，用于给连接对端地址找到对应设备、判断哪些是新出现的设备
    private var visible: [String: NWEndpoint] = [:]
    private let queue = DispatchQueue(label: "lanchat.node")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var stopped = false
    private var listenPort: UInt16?

    /// - Parameter discovery: 是否启用 Bonjour 广播与发现（测试时可关闭，直接用 host:port 互连）。
    public init(id: String, name: String, host: String = "", downloadsDirectory: URL, discovery: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.downloadsDirectory = downloadsDirectory
        self.discovery = discovery
    }

    public func start() {
        queue.async {
            self.stopped = false
            self.startListener()
            if self.discovery { self.startBrowser() }
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
        }
    }

    public func updateName(_ newName: String) {
        queue.async {
            self.name = newName
            if self.discovery { self.listener?.service = self.makeService() }
        }
    }

    // MARK: - Listener / Browser

    private func makeService() -> NWListener.Service {
        var dict = ["id": id, "name": name, "host": host, "ver": "2"]
        let primary = LocalDevice.interfaces().first { $0.name.hasPrefix("en") && !$0.ipv4.isEmpty }
        if let mac = primary?.mac ?? primary?.hardwareMAC { dict["mac"] = mac }
        let txt = NWTXTRecord(dict)
        // 服务名用唯一 id，避免同名设备冲突；显示名放在 TXT 记录里，可随时更新。
        return NWListener.Service(name: id, type: Self.serviceType, domain: nil, txtRecord: txt)
    }

    private func startListener() {
        let l: NWListener
        do {
            l = try NWListener(using: .tcp)
        } catch {
            emit(.listenerFailed(error.localizedDescription)); return
        }
        if discovery { l.service = makeService() }
        l.newConnectionHandler = { [weak self] conn in self?.acceptIncoming(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                if let port = l.port {
                    self.listenPort = port.rawValue
                    self.emit(.listening(port: port.rawValue))
                }
            case .failed(let error):
                self.emit(.listenerFailed(error.localizedDescription))
                l.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) {
                    if !self.stopped, self.listener === l { self.startListener() }
                }
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.handleBrowse(results) }
        b.stateUpdateHandler = { [weak self, weak b] state in
            guard let self, let b else { return }
            if case .failed = state {
                b.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) {
                    if !self.stopped, self.browser === b { self.startBrowser() }
                }
            }
        }
        browser = b
        b.start(queue: queue)
    }

    private func handleBrowse(_ results: Set<NWBrowser.Result>) {
        var map: [String: PeerInfo] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata,
                  let pid = txt["id"], !pid.isEmpty, pid != id else { continue }
            var ifaces = r.interfaces.map(\.name)
            if let existing = map[pid] { ifaces = Array(Set(existing.interfaces + ifaces)).sorted() }
            var info = map[pid] ?? PeerInfo(id: pid, name: txt["name"] ?? "未知设备", host: txt["host"] ?? "",
                                            endpoint: r.endpoint)
            if case .service(let sname, _, let domain, _) = r.endpoint {
                info.bonjourName = sname; info.bonjourDomain = domain
            }
            info.interfaces = ifaces
            info.txt = txt.dictionary
            map[pid] = info
        }
        let previous = visible
        visible = map.mapValues(\.endpoint)
        emit(.peersChanged(Array(map.values)))
        // 新出现（或端点变化）的设备：握手交换设备信息，同时得到 IP
        for (pid, info) in map where previous[pid] != info.endpoint {
            exchangeInfo(peerId: pid, endpoint: info.endpoint)
        }
    }

    /// 重新与对方握手，刷新设备信息、IP、ARP、延迟。
    public func refreshInfo(peerId: String) {
        queue.async {
            guard let endpoint = self.visible[peerId] else { return }
            self.exchangeInfo(peerId: peerId, endpoint: endpoint)
        }
    }

    /// 直接对某个端点握手（测试或未经 Bonjour 的场景）。
    public func refreshInfo(peerId: String, endpoint: NWEndpoint) {
        queue.async { self.exchangeInfo(peerId: peerId, endpoint: endpoint) }
    }

    private func localInfo() -> DeviceInfo {
        LocalDevice.info(deviceId: id, displayName: name, listenPort: listenPort)
    }

    private func infoHeader() -> Header {
        Header(type: .info, msgId: UUID().uuidString, fromId: id, fromName: name, fromHost: host, info: localInfo())
    }

    /// 本机实测部分：连接两端地址、网卡、ARP。
    private func observe(_ conn: NWConnection, outbound: Bool) -> PeerObservation {
        let path = conn.currentPath
        let remote = path?.remoteEndpoint ?? conn.endpoint
        let ip = Self.ipString(remote)
        var port: UInt16?
        if case .hostPort(_, let p) = remote { port = p.rawValue }
        let arp = ip.flatMap { $0.contains(":") ? nil : ARPTable.mac(for: $0) }
        return PeerObservation(info: nil, ip: ip, port: port,
                               localInterface: path?.availableInterfaces.first?.name,
                               localIP: Self.ipString(path?.localEndpoint),
                               arpMAC: arp, rttMs: nil, outbound: outbound, at: Date())
    }

    /// 与对方握手：建立 TCP 连接，发送本机 DeviceInfo，等待对方 DeviceInfo。
    /// 优先走 IPv4（地址便于阅读），连不上再接受任意地址。旧版本对方不认识 info 帧时，仍能得到 IP。
    private func exchangeInfo(peerId: String, endpoint: NWEndpoint, ipv4Only: Bool = true) {
        let params = NWParameters.tcp
        if ipv4Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        let once = Once()
        let done: (PeerObservation?) -> Void = { [weak self] obs in
            guard once.fire() else { return }
            conn.cancel()
            guard let self else { return }
            if let obs {
                if let ip = obs.ip { self.emit(.peerAddress(peerId: peerId, ip: ip)) }
                self.emit(.peerObserved(peerId: peerId, obs))
            } else if ipv4Only {
                self.exchangeInfo(peerId: peerId, endpoint: endpoint, ipv4Only: false)
            }
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var obs = self.observe(conn, outbound: true)
                let t0 = Date()
                conn.send(content: Wire.frame(self.infoHeader()), completion: .contentProcessed { _ in })
                Wire.readHeader(conn) { result in
                    if case .success(let h) = result, h.type == .info {
                        obs.info = h.info
                        obs.rttMs = Date().timeIntervalSince(t0) * 1000
                    }
                    // 连接后 ARP 表才有对方条目，读取放在应答之后更可靠
                    if obs.arpMAC == nil, let ip = obs.ip, !ip.contains(":") { obs.arpMAC = ARPTable.mac(for: ip) }
                    done(obs)
                }
            case .waiting, .failed: done(nil)
            case .cancelled: conn.stateUpdateHandler = nil
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { done(nil) }
    }

    /// 从连接对端端点提取便于显示的 IP 文本（IPv4 映射地址转回 IPv4，去掉 IPv6 的 %接口 后缀）。
    static func ipString(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = a.asIPv4.map { "\($0)" } ?? "\(a)"
        case .name(let n, _): text = n
        @unknown default: return nil
        }
        // 去掉 "%en0" 之类的接口后缀（IPv4 链路地址也会带）
        return text.components(separatedBy: "%")[0]
    }

    // MARK: - Incoming

    private func acceptIncoming(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed: conn.cancel()
            case .cancelled: conn.stateUpdateHandler = nil
            default: break
            }
        }
        conn.start(queue: queue)
        Wire.readHeader(conn) { [weak self] result in
            guard let self, case .success(let h) = result else { conn.cancel(); return }
            let from = PeerRef(id: h.fromId, name: h.fromName, host: h.fromHost ?? "")
            if !h.fromId.isEmpty, let ip = Self.ipString(conn.currentPath?.remoteEndpoint ?? conn.endpoint) {
                self.emit(.peerAddress(peerId: h.fromId, ip: ip))
            }
            switch h.type {
            case .text:
                self.emit(.incomingText(msgId: h.msgId, from: from, text: h.text ?? ""))
                self.sendAck(h.msgId, on: conn)
            case .file:
                self.receiveFile(h, from: from, on: conn)
            case .info:
                var obs = self.observe(conn, outbound: false)
                obs.info = h.info
                conn.send(content: Wire.frame(self.infoHeader()), completion: .contentProcessed { _ in conn.cancel() })
                if !h.fromId.isEmpty { self.emit(.peerObserved(peerId: h.fromId, obs)) }
            case .ack:
                conn.cancel()
            }
        }
    }

    private func sendAck(_ msgId: String, on conn: NWConnection) {
        conn.send(content: Wire.frame(Header(type: .ack, msgId: msgId)),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func receiveFile(_ h: Header, from: PeerRef, on conn: NWConnection) {
        guard let size = h.fileSize, size >= 0 else { conn.cancel(); return }
        let fileName = Self.sanitize(h.fileName ?? "")
        let fm = FileManager.default
        let url: URL
        let handle: FileHandle
        do {
            try fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            url = Self.uniqueURL(in: downloadsDirectory, name: fileName)
            guard fm.createFile(atPath: url.path, contents: nil) else { throw WireError.closed }
            handle = try FileHandle(forWritingTo: url)
        } catch {
            conn.cancel(); return
        }
        emit(.incomingFileStarted(msgId: h.msgId, from: from, fileName: fileName, size: size, url: url))

        let receiver = FileReceiver(conn: conn, handle: handle, size: size) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.emit(.transferProgress(msgId: h.msgId, fraction: 1))
                self.emit(.incomingFileFinished(msgId: h.msgId, url: url))
                self.sendAck(h.msgId, on: conn)
            } else {
                try? fm.removeItem(at: url)
                self.emit(.incomingFileFailed(msgId: h.msgId))
                conn.cancel()
            }
        } progress: { [weak self] fraction in
            self?.emit(.transferProgress(msgId: h.msgId, fraction: fraction))
        }
        receiver.pump()
    }

    // MARK: - Outgoing

    public func sendText(msgId: String, text: String, to endpoint: NWEndpoint) {
        queue.async {
            let header = Header(type: .text, msgId: msgId, fromId: self.id, fromName: self.name,
                                fromHost: self.host, text: text)
            self.openConnection(to: endpoint, msgId: msgId) { conn, complete in
                conn.send(content: Wire.frame(header), completion: .contentProcessed { error in
                    if let error { complete(false, error.localizedDescription); return }
                    Self.awaitAck(conn, msgId: msgId, complete)
                })
            }
        }
    }

    public func sendFile(msgId: String, fileURL: URL, to endpoint: NWEndpoint) {
        queue.async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let handle = try? FileHandle(forReadingFrom: fileURL) else {
                self.emit(.outgoingFailed(msgId: msgId, reason: "无法读取文件", unreachable: false)); return
            }
            let header = Header(type: .file, msgId: msgId, fromId: self.id, fromName: self.name,
                                fromHost: self.host, fileName: fileURL.lastPathComponent, fileSize: size)
            self.openConnection(to: endpoint, msgId: msgId, onFail: { try? handle.close() }) { conn, complete in
                conn.send(content: Wire.frame(header), completion: .contentProcessed { error in
                    if let error { try? handle.close(); complete(false, error.localizedDescription); return }
                    let sender = FileSender(conn: conn, handle: handle, size: size) { ok, reason in
                        if ok { Self.awaitAck(conn, msgId: msgId, complete) } else { complete(false, reason) }
                    } progress: { fraction in
                        self.emit(.transferProgress(msgId: msgId, fraction: fraction))
                    }
                    sender.pump()
                })
            }
        }
    }

    private typealias Completion = (Bool, String?) -> Void

    private static func awaitAck(_ conn: NWConnection, msgId: String, _ complete: @escaping Completion) {
        Wire.readHeader(conn) { result in
            if case .success(let h) = result, h.type == .ack, h.msgId == msgId {
                complete(true, nil)
            } else {
                complete(false, "对方未确认接收")
            }
        }
    }

    private func openConnection(to endpoint: NWEndpoint, msgId: String, onFail: (() -> Void)? = nil,
                                ready: @escaping (NWConnection, @escaping Completion) -> Void) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let once = Once()
        var started = false
        let complete: Completion = { [weak self] ok, reason in
            guard once.fire() else { return }
            conn.cancel()
            if !ok { onFail?() }
            self?.emit(ok ? .outgoingDelivered(msgId: msgId)
                          : .outgoingFailed(msgId: msgId, reason: reason ?? "发送失败", unreachable: !started))
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !started {
                    started = true
                    if let pid = self.visible.first(where: { $0.value == endpoint })?.key,
                       let ip = Self.ipString(conn.currentPath?.remoteEndpoint) {
                        self.emit(.peerAddress(peerId: pid, ip: ip))
                    }
                    ready(conn, complete)
                }
            case .waiting(let error):
                complete(false, "无法连接：\(error.localizedDescription)")
            case .failed(let error):
                complete(false, error.localizedDescription)
            case .cancelled:
                conn.stateUpdateHandler = nil
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) {
            if !started { complete(false, "连接超时") }
        }
    }

    /// 探测对方是否可连接：只建立 TCP 连接，成功即断开，不发送任何数据。
    /// 回调在主线程执行。
    public func probe(_ endpoint: NWEndpoint, timeout: TimeInterval = 3,
                      completion: @escaping (Bool) -> Void) {
        queue.async {
            let conn = NWConnection(to: endpoint, using: .tcp)
            let once = Once()
            let done: (Bool) -> Void = { ok in
                guard once.fire() else { return }
                conn.cancel()
                DispatchQueue.main.async { completion(ok) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: done(true)
                case .waiting, .failed: done(false)
                case .cancelled: conn.stateUpdateHandler = nil
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + timeout) { done(false) }
        }
    }

    // MARK: - Helpers

    private func emit(_ event: NodeEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    static func sanitize(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "未命名文件" : name
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 1
        repeat {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            url = dir.appendingPathComponent(candidate)
            i += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}

/// 从连接读取固定长度的文件数据并写盘。
private final class FileReceiver {
    let conn: NWConnection
    let handle: FileHandle
    let size: Int64
    let done: (Bool) -> Void
    let progress: (Double) -> Void
    var received: Int64 = 0
    let throttle = ProgressThrottle()

    init(conn: NWConnection, handle: FileHandle, size: Int64,
         done: @escaping (Bool) -> Void, progress: @escaping (Double) -> Void) {
        self.conn = conn; self.handle = handle; self.size = size
        self.done = done; self.progress = progress
    }

    func finish(_ ok: Bool) {
        try? handle.close()
        done(ok)
    }

    func pump() {
        if received >= size { finish(true); return }
        let want = Int(min(Int64(1 << 20), size - received))
        conn.receive(minimumIncompleteLength: 1, maximumLength: want) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                do { try handle.write(contentsOf: data) } catch { finish(false); return }
                received += Int64(data.count)
                if throttle.shouldEmit(done: received, total: size), size > 0 {
                    progress(Double(received) / Double(size))
                }
            }
            if received >= size { finish(true); return }
            if error != nil || isComplete { finish(false); return }
            pump()
        }
    }
}

/// 分块读取本地文件并写入连接。
private final class FileSender {
    let conn: NWConnection
    let handle: FileHandle
    let size: Int64
    let done: (Bool, String?) -> Void
    let progress: (Double) -> Void
    var sent: Int64 = 0
    let throttle = ProgressThrottle()

    init(conn: NWConnection, handle: FileHandle, size: Int64,
         done: @escaping (Bool, String?) -> Void, progress: @escaping (Double) -> Void) {
        self.conn = conn; self.handle = handle; self.size = size
        self.done = done; self.progress = progress
    }

    func pump() {
        if sent >= size { try? handle.close(); done(true, nil); return }
        let want = Int(min(Int64(256 * 1024), size - sent))
        let chunk: Data
        do { chunk = try handle.read(upToCount: want) ?? Data() } catch {
            try? handle.close(); done(false, "读取文件失败"); return
        }
        if chunk.isEmpty { try? handle.close(); done(false, "文件在发送过程中被修改"); return }
        conn.send(content: chunk, completion: .contentProcessed { [self] error in
            if let error { try? handle.close(); done(false, error.localizedDescription); return }
            sent += Int64(chunk.count)
            if throttle.shouldEmit(done: sent, total: size) {
                progress(Double(sent) / Double(size))
            }
            pump()
        })
    }
}
