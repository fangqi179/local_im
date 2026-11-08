import Darwin
import Foundation
import SystemConfiguration

/// 一块网卡的信息。
public struct NetworkInterfaceInfo: Codable, Equatable, Sendable {
    /// BSD 名称，如 en0
    public var name: String
    /// 系统显示名称，如 Wi-Fi、Thunderbolt Bridge
    public var displayName: String?
    /// 类型，如 IEEE80211、Ethernet、Bridge
    public var type: String?
    /// 当前实际使用的 MAC（Wi-Fi 开启"私有地址"时是随机地址，与硬件 MAC 不同）
    public var mac: String?
    /// 出厂硬件 MAC
    public var hardwareMAC: String?
    /// "192.168.5.15/24"
    public var ipv4: [String] = []
    public var ipv6: [String] = []
    /// IPv4 广播地址
    public var broadcast: String?

    public init(name: String) { self.name = name }
}

/// 设备自报的身份信息，通过 info 握手交换。
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var deviceId: String
    public var displayName: String
    public var computerName: String
    public var localHostName: String
    public var hostName: String
    public var userName: String
    public var fullName: String
    public var model: String
    public var arch: String
    public var osVersion: String
    public var appVersion: String
    public var listenPort: UInt16?
    /// App 启动时间（Unix 秒）
    public var startedAt: Double
    public var interfaces: [NetworkInterfaceInfo]

    /// 本机所有网卡的 MAC（小写、已规范化）
    public var macs: Set<String> {
        Set(interfaces.flatMap { [$0.mac, $0.hardwareMAC].compactMap { $0.map(MAC.normalize) } })
    }

    /// 本机所有 IP（不带前缀长度）
    public var ips: Set<String> {
        Set(interfaces.flatMap { $0.ipv4 + $0.ipv6 }.map { $0.components(separatedBy: "/")[0] })
    }

    /// 与给定 IP 同一块网卡的 MAC；找不到时返回第一块有 IPv4 的网卡的 MAC。
    public func mac(forIP ip: String?) -> String? {
        if let ip, let hit = interfaces.first(where: { iface in
            (iface.ipv4 + iface.ipv6).contains { $0.components(separatedBy: "/")[0] == ip }
        }), let mac = hit.mac ?? hit.hardwareMAC { return mac }
        let first = interfaces.first { !$0.ipv4.isEmpty && ($0.mac ?? $0.hardwareMAC) != nil }
        return first?.mac ?? first?.hardwareMAC
    }
}

public enum MAC {
    /// "0:1b:2:..." → "00:1b:02:..."
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    /// 系统隐私限制下返回的占位地址
    static let placeholder = "02:00:00:00:00:00"

    static func format(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

// MARK: - 本机信息采集

public enum LocalDevice {
    public static var localHostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?)
            ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }

    public static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? localHostName
    }

    static let startedAt = Date().timeIntervalSince1970

    public static func info(deviceId: String, displayName: String, listenPort: UInt16?) -> DeviceInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfo(
            deviceId: deviceId,
            displayName: displayName,
            computerName: computerName,
            localHostName: localHostName,
            hostName: ProcessInfo.processInfo.hostName,
            userName: NSUserName(),
            fullName: NSFullUserName(),
            model: sysctlString("hw.model") ?? "Mac",
            arch: sysctlString("hw.machine") ?? "",
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            listenPort: listenPort,
            startedAt: startedAt,
            interfaces: interfaces()
        )
    }

    /// 处于活动状态、有 IP 地址的物理/桥接网卡（排除回环、VPN 隧道、AWDL 等）。
    public static func interfaces() -> [NetworkInterfaceInfo] {
        var meta: [String: (display: String?, type: String?, hw: String?)] = [:]
        for iface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String? {
                meta[bsd] = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?,
                             SCNetworkInterfaceGetInterfaceType(iface) as String?,
                             (SCNetworkInterfaceGetHardwareAddressString(iface) as String?).map(MAC.normalize))
            }
        }

        var byName: [String: NetworkInterfaceInfo] = [:]
        var order: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        let skipPrefixes = ["lo", "utun", "awdl", "llw", "gif", "stf", "anpi", "ap", "ipsec", "ppp"]
        var p = head
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            guard !skipPrefixes.contains(where: { name.hasPrefix($0) }),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, let addr = ifa.ifa_addr else { continue }
            if byName[name] == nil {
                var info = NetworkInterfaceInfo(name: name)
                info.displayName = meta[name]?.display
                info.type = meta[name]?.type
                info.hardwareMAC = meta[name]?.hw.flatMap { $0 == MAC.placeholder ? nil : $0 }
                byName[name] = info
                order.append(name)
            }
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let alen = Int(dl.pointee.sdl_alen), nlen = Int(dl.pointee.sdl_nlen)
                    guard alen == 6 else { return }
                    let base = UnsafeRawPointer(dl).advanced(by: 8 + nlen)  // sdl_data 起始偏移 8
                    let mac = MAC.format((0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) })
                    if mac != MAC.placeholder { byName[name]?.mac = mac }
                }
            case AF_INET:
                guard let ip = numericHost(addr) else { break }
                let prefix = ifa.ifa_netmask.flatMap(numericHost).map(prefixLength) ?? 32
                byName[name]?.ipv4.append("\(ip)/\(prefix)")
                if ifa.ifa_flags & UInt32(IFF_BROADCAST) != 0, let b = ifa.ifa_dstaddr.flatMap(numericHost) {
                    byName[name]?.broadcast = b
                }
            case AF_INET6:
                guard let ip = numericHost(addr) else { break }
                byName[name]?.ipv6.append(ip.components(separatedBy: "%")[0])
            default: break
            }
        }
        var result = order.compactMap { byName[$0] }.filter { !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }
        // 当前 MAC 被系统隐藏时，用 ARP 表中本机 IP 的永久条目补上
        for i in result.indices where result[i].mac == nil {
            if let ip = result[i].ipv4.first?.components(separatedBy: "/")[0], let mac = ARPTable.mac(for: ip) {
                result[i].mac = mac
            }
        }
        return result
    }

    static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_len)
        guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }

    static func prefixLength(_ mask: String) -> Int {
        mask.split(separator: ".").compactMap { UInt8($0) }.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - ARP

/// 读取系统 ARP 缓存（等价于 `arp -an`），得到"网络上实际观察到的"对方 MAC。
/// 只对同一二层网段有效；跨路由器时查到的是网关的 MAC。
public enum ARPTable {
    /// ARP 表条目数；为 0 通常表示系统限制了本进程读取（需要"本地网络"权限）。
    public static func entryCount() -> Int {
        guard let buf = dump() else { return 0 }
        var n = 0, offset = 0
        while offset + 2 <= buf.count {
            let msgLen = Int(buf[offset]) | Int(buf[offset + 1]) << 8
            guard msgLen > 0 else { break }
            n += 1; offset += msgLen
        }
        return n
    }

    private static func dump() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        len += 4096  // 两次调用之间表可能变大
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(len))
    }

    public static func mac(for ipv4: String) -> String? {
        var target = in_addr()
        guard inet_pton(AF_INET, ipv4, &target) == 1, let buf = dump() else { return nil }
        let len = buf.count

        return buf.withUnsafeBytes { raw -> String? in
            var offset = 0
            let hdr = MemoryLayout<rt_msghdr>.size
            while offset + hdr <= len {
                let msgLen = Int(raw.load(fromByteOffset: offset, as: UInt16.self))  // rtm_msglen
                guard msgLen > 0 else { break }
                defer { offset += msgLen }
                // rt_msghdr 后依次是 sockaddr_in（目标 IP）和 sockaddr_dl（MAC）
                let sinOff = offset + hdr
                guard sinOff + 8 <= len else { break }
                let sinLen = Int(raw[sinOff])
                let addr = raw.load(fromByteOffset: sinOff + 4, as: UInt32.self)  // sin_addr
                guard addr == target.s_addr else { continue }
                let dlOff = sinOff + (sinLen > 0 ? (sinLen + 3) & ~3 : 4)
                guard dlOff + 8 <= len else { return nil }
                // sockaddr_dl: len(0) family(1) index(2-3) type(4) nlen(5) alen(6) slen(7) data(8…)
                let nlen = Int(raw[dlOff + 5])
                let alen = Int(raw[dlOff + 6])
                guard alen == 6, dlOff + 8 + nlen + 6 <= len else { return nil }
                return MAC.format((0..<6).map { raw[dlOff + 8 + nlen + $0] })
            }
            return nil
        }
    }
}
