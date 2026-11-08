import Foundation
import Network

/// 线上协议：每个 TCP 连接只承载一次投递。
///
///   帧 = 4 字节大端长度 + JSON 头
///   文本：  [text 帧]                     → 对方回 [ack 帧]
///   文件：  [file 帧][fileSize 字节原始数据] → 对方回 [ack 帧]
///   信息：  [info 帧(本方 DeviceInfo)]         → 对方回 [info 帧(对方 DeviceInfo)]
enum FrameType: String, Codable {
    case text
    case file
    case ack
    /// 设备信息握手：请求和应答都携带发送方自己的 DeviceInfo
    case info
}

struct Header: Codable {
    var type: FrameType
    var msgId: String
    var fromId: String = ""
    var fromName: String = ""
    var fromHost: String?
    var text: String?
    var fileName: String?
    var fileSize: Int64?
    var info: DeviceInfo?
}

enum WireError: Error {
    case closed
    case badLength
    case badHeader
}

enum Wire {
    static let maxHeaderSize: UInt32 = 8 * 1024 * 1024

    static func frame(_ header: Header) -> Data {
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        let len = UInt32(json.count)
        var out = Data([UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff),
                        UInt8(len >> 8 & 0xff), UInt8(len & 0xff)])
        out.append(json)
        return out
    }

    static func readHeader(_ conn: NWConnection, _ completion: @escaping (Result<Header, Error>) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            guard let data, data.count == 4 else {
                completion(.failure(error ?? WireError.closed)); return
            }
            let len = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len > 0, len <= maxHeaderSize else {
                completion(.failure(WireError.badLength)); return
            }
            conn.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, error in
                guard let body, body.count == Int(len) else {
                    completion(.failure(error ?? WireError.closed)); return
                }
                guard let header = try? JSONDecoder().decode(Header.self, from: body) else {
                    completion(.failure(WireError.badHeader)); return
                }
                completion(.success(header))
            }
        }
    }
}

/// 进度回调节流：最多每 100ms 一次，完成时必发。
final class ProgressThrottle {
    private var last = Date.distantPast
    func shouldEmit(done: Int64, total: Int64) -> Bool {
        if done >= total { return true }
        let now = Date()
        if now.timeIntervalSince(last) >= 0.1 { last = now; return true }
        return false
    }
}

/// 只触发一次的标志。
final class Once {
    private(set) var fired = false
    func fire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}
