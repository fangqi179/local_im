import Foundation
import SQLite3

public enum MessageKind: String, Sendable {
    case text
    case file
}

public enum MessageStatus: String, Sendable {
    case sending
    case sent
    case failed
    case receiving
    case received
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let peerId: String
    public let outgoing: Bool
    public let kind: MessageKind
    public var text: String
    public var fileName: String?
    public var fileSize: Int64
    public var filePath: String?
    public var status: MessageStatus
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        peerId: String,
        outgoing: Bool,
        kind: MessageKind,
        text: String = "",
        fileName: String? = nil,
        fileSize: Int64 = 0,
        filePath: String? = nil,
        status: MessageStatus,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.peerId = peerId
        self.outgoing = outgoing
        self.kind = kind
        self.text = text
        self.fileName = fileName
        self.fileSize = fileSize
        self.filePath = filePath
        self.status = status
        self.timestamp = timestamp
    }
}

public struct StoredPeer: Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let ip: String
    public let lastSeen: Date
    public var firstSeen: Date = .distantPast
    /// 最近一次握手得到的对方自报信息
    public var info: DeviceInfo?
    /// 最近一次在 ARP 表中观察到的 MAC
    public var arpMAC: String = ""
    /// 最近一次握手时间
    public var infoAt: Date?
    /// 已信任的对方身份公钥（尚未完成过加密握手时为 nil）
    public var publicKey: Data?
    /// 用户已与对方核对过安全码
    public var keyVerified = false
    /// 对方出示了与已信任公钥不同的新公钥，等待用户确认
    public var pendingKey: Data?
}

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): return "SQLite: \(m)" }
    }
}

/// 本地聊天记录（SQLite）。非线程安全，请在同一线程（主线程）使用。
public final class ChatStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS peers(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                last_seen REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY,
                peer_id TEXT NOT NULL,
                outgoing INTEGER NOT NULL,
                kind TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                file_name TEXT,
                file_size INTEGER NOT NULL DEFAULT 0,
                file_path TEXT,
                status TEXT NOT NULL,
                ts REAL NOT NULL,
                is_read INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_messages_peer_ts ON messages(peer_id, ts);
            """)
        // 旧库升级：peers 表逐步增加的列
        let cols = Set(query("PRAGMA table_info(peers)", []) { $0.string(1) ?? "" })
        let added: [(String, String)] = [
            ("host", "TEXT NOT NULL DEFAULT ''"),
            ("ip", "TEXT NOT NULL DEFAULT ''"),
            ("first_seen", "REAL NOT NULL DEFAULT 0"),
            ("info_json", "TEXT NOT NULL DEFAULT ''"),
            ("arp_mac", "TEXT NOT NULL DEFAULT ''"),
            ("info_at", "REAL NOT NULL DEFAULT 0"),
            ("public_key", "TEXT NOT NULL DEFAULT ''"),
            ("key_verified", "INTEGER NOT NULL DEFAULT 0"),
            ("pending_key", "TEXT NOT NULL DEFAULT ''"),
        ]
        for (name, def) in added where !cols.contains(name) {
            try exec("ALTER TABLE peers ADD COLUMN \(name) \(def)")
        }
        try exec("UPDATE peers SET first_seen = last_seen WHERE first_seen = 0")
    }

    deinit { sqlite3_close(db) }

    // MARK: Peers

    /// 新增或更新联系人；host 为空时保留原有主机名。
    public func upsertPeer(id: String, name: String, host: String = "", lastSeen: Date = Date()) {
        run("""
            INSERT INTO peers(id, name, host, last_seen, first_seen) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen,
                host = CASE WHEN excluded.host = '' THEN peers.host ELSE excluded.host END
            """, [id, name, host, lastSeen.timeIntervalSince1970, lastSeen.timeIntervalSince1970])
    }

    /// 记录联系人最近一次的 IP（联系人不存在时忽略）。
    public func updatePeerIP(id: String, ip: String) {
        run("UPDATE peers SET ip = ? WHERE id = ?", [ip, id])
    }

    /// 保存一次握手结果；info / arpMAC 为 nil 时保留原值。
    public func updatePeerObservation(id: String, info: DeviceInfo?, arpMAC: String?, at: Date = Date()) {
        let json = info.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        run("""
            UPDATE peers SET info_json = COALESCE(?, info_json), arp_mac = COALESCE(?, arp_mac), info_at = ?
            WHERE id = ?
            """, [json, arpMAC, at.timeIntervalSince1970, id])
    }

    /// 信任对方公钥（首次见到，或用户确认了新公钥）：清除待确认的公钥和核对状态。联系人不存在时新建。
    public func pinPeerKey(id: String, name: String, key: Data, at: Date = Date()) {
        let t = at.timeIntervalSince1970
        run("""
            INSERT INTO peers(id, name, last_seen, first_seen, public_key) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET public_key = excluded.public_key, pending_key = '', key_verified = 0
            """, [id, name, t, t, key.base64EncodedString()])
    }

    /// 记录对方出示的、与已信任公钥不同的新公钥。
    public func setPendingKey(id: String, key: Data) {
        run("UPDATE peers SET pending_key = ? WHERE id = ?", [key.base64EncodedString(), id])
    }

    public func setKeyVerified(id: String, _ verified: Bool) {
        run("UPDATE peers SET key_verified = ? WHERE id = ?", [verified, id])
    }

    /// 全部已信任的公钥，启动时交给 ChatNode。
    public func pinnedKeys() -> [String: Data] {
        var out: [String: Data] = [:]
        for p in peers() { if let k = p.publicKey { out[p.id] = k } }
        return out
    }

    public func peers() -> [StoredPeer] {
        query("""
            SELECT id, name, host, ip, last_seen, first_seen, info_json, arp_mac, info_at,
                   public_key, key_verified, pending_key FROM peers
            """, []) { s in
            var p = StoredPeer(id: s.string(0) ?? "", name: s.string(1) ?? "", host: s.string(2) ?? "",
                               ip: s.string(3) ?? "", lastSeen: Date(timeIntervalSince1970: s.double(4)))
            p.firstSeen = Date(timeIntervalSince1970: s.double(5))
            if let json = s.string(6), !json.isEmpty {
                p.info = try? JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
            }
            p.arpMAC = s.string(7) ?? ""
            let at = s.double(8)
            p.infoAt = at > 0 ? Date(timeIntervalSince1970: at) : nil
            p.publicKey = s.string(9).flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            p.keyVerified = s.int64(10) != 0
            p.pendingKey = s.string(11).flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            return p
        }
    }

    /// 删除联系人及其全部聊天记录（不删除已接收的文件）。
    public func deletePeer(id: String) {
        run("DELETE FROM messages WHERE peer_id = ?", [id])
        run("DELETE FROM peers WHERE id = ?", [id])
    }

    // MARK: Messages

    /// 插入消息；若 id 已存在则忽略并返回 false（用于去重重传）。
    @discardableResult
    public func insert(_ m: ChatMessage, read: Bool = true) -> Bool {
        run("""
            INSERT OR IGNORE INTO messages
            (id, peer_id, outgoing, kind, text, file_name, file_size, file_path, status, ts, is_read)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [m.id, m.peerId, m.outgoing, m.kind.rawValue, m.text, m.fileName, m.fileSize,
                  m.filePath, m.status.rawValue, m.timestamp.timeIntervalSince1970, read])
        return sqlite3_changes(db) > 0
    }

    public func updateStatus(id: String, status: MessageStatus) {
        run("UPDATE messages SET status = ? WHERE id = ?", [status.rawValue, id])
    }

    public func updateFile(id: String, path: String?, status: MessageStatus) {
        run("UPDATE messages SET file_path = ?, status = ? WHERE id = ?", [path, status.rawValue, id])
    }

    public func message(id: String) -> ChatMessage? {
        query("SELECT \(Self.columns) FROM messages WHERE id = ?", [id], Self.decode).first
    }

    public func messages(peerId: String) -> [ChatMessage] {
        query("SELECT \(Self.columns) FROM messages WHERE peer_id = ? ORDER BY ts, rowid",
              [peerId], Self.decode)
    }

    public func lastMessage(peerId: String) -> ChatMessage? {
        query("SELECT \(Self.columns) FROM messages WHERE peer_id = ? ORDER BY ts DESC, rowid DESC LIMIT 1",
              [peerId], Self.decode).first
    }

    public func unreadCount(peerId: String) -> Int {
        query("SELECT COUNT(*) FROM messages WHERE peer_id = ? AND is_read = 0", [peerId]) {
            Int($0.int64(0))
        }.first ?? 0
    }

    public func markRead(peerId: String) {
        run("UPDATE messages SET is_read = 1 WHERE peer_id = ? AND is_read = 0", [peerId])
    }

    public func clearMessages(peerId: String) {
        run("DELETE FROM messages WHERE peer_id = ?", [peerId])
    }

    /// 上次退出时仍在进行中的传输标记为失败。
    public func failInterrupted() {
        run("UPDATE messages SET status = 'failed' WHERE status IN ('sending', 'receiving')", [])
    }

    // MARK: SQLite helpers

    private static let columns =
        "id, peer_id, outgoing, kind, text, file_name, file_size, file_path, status, ts"

    private static func decode(_ s: Row) -> ChatMessage {
        ChatMessage(
            id: s.string(0) ?? "",
            peerId: s.string(1) ?? "",
            outgoing: s.int64(2) != 0,
            kind: MessageKind(rawValue: s.string(3) ?? "") ?? .text,
            text: s.string(4) ?? "",
            fileName: s.string(5),
            fileSize: s.int64(6),
            filePath: s.string(7),
            status: MessageStatus(rawValue: s.string(8) ?? "") ?? .failed,
            timestamp: Date(timeIntervalSince1970: s.double(9))
        )
    }

    struct Row {
        let stmt: OpaquePointer
        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(msg)
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("LanChat SQL prepare failed: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Any?]) {
        guard let stmt = prepare(sql, args) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("LanChat SQL step failed: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ args: [Any?], _ map: (Row) -> T) -> [T] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(map(Row(stmt: stmt)))
        }
        return out
    }
}
