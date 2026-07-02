import Foundation
import Darwin
import Network
import CoreWLAN
import SystemConfiguration

/// 单个网络接口的详情。
public struct NetworkInterfaceInfo: Sendable, Identifiable {
    public let id: String          // BSD 名（en0…）
    public let displayName: String // "Wi-Fi" / "以太网" / 接口名
    public let type: Kind
    public let isActive: Bool
    public let ipv4: String?
    public let ipv6: String?
    public let macAddress: String?
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double

    public enum Kind: String, Sendable {
        case wifi, ethernet, cellular, loopback, vpn, other
        public var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .ethernet: return "cable.connector"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .vpn: return "lock.shield"
            case .loopback: return "arrow.triangle.2.circlepath"
            case .other: return "network"
            }
        }
    }
}

/// Wi-Fi 详情。
public struct WiFiInfo: Sendable {
    public let ssid: String?       // macOS 14+ 读 SSID 需定位授权；无授权为 nil
    public let bssid: String?
    public let rssi: Int?          // dBm 信号强度
    public let channel: Int?
    public let txRate: Double?     // Mbps
    public let security: String?
    /// 信号强度 0...1（-30dBm≈满格，-90dBm≈无）。
    public var signalFraction: Double? {
        guard let r = rssi else { return nil }
        return min(1, max(0, Double(r + 90) / 60))
    }
}

/// 网络全景快照。
public struct NetworkDetail: Sendable {
    public var interfaces: [NetworkInterfaceInfo]
    public var wifi: WiFiInfo?
    public var publicIP: String?
    public var pingHost: String
    public var pingMilliseconds: Double?
}

/// 网络详细信息读取器（对标 iStat 网络面板：公网IP/内网/Wi-Fi/Ping/每接口）。
/// 全部无需 root、Developer ID 直销可行；SSID 在 macOS 14+ 需定位授权，无授权优雅降级。
public final class NetworkInfoService: @unchecked Sendable {
    private let stateLock = NSLock()
    private var prevPerIf: [String: (down: UInt64, up: UInt64)] = [:]
    private var prevTime: Date?
    private var cachedPublicIP: String?
    private var publicIPFetchedAt: Date?

    public let pingHost: String
    private let wifiClient = CWWiFiClient.shared()

    public init(pingHost: String = "1.1.1.1") { self.pingHost = pingHost }

    // MARK: 每接口（NET_RT_IFLIST2 计数 + getifaddrs 地址）

    /// 采样一次每接口吞吐（需与上次采样有时间差才有速率）。
    public func interfaces() -> [NetworkInterfaceInfo] {
        let counters = perInterfaceCounters()
        let now = Date()
        stateLock.lock()
        let prev = prevPerIf
        let prevT = prevTime
        prevPerIf = counters.mapValues { ($0.down, $0.up) }
        prevTime = now
        stateLock.unlock()
        let dt = prevT.map { now.timeIntervalSince($0) } ?? 0

        let addrs = interfaceAddresses()
        // 隐藏系统自组网/桥接等噪声接口（除非它们真的携带 IP 在用）
        let noisePrefixes = ["anpi", "awdl", "llw", "gif", "stf", "pktap", "bridge", "ap", "XHC", "utun"]
        var out: [NetworkInterfaceInfo] = []
        for (name, c) in counters {
            guard !name.hasPrefix("lo") else { continue }
            let kind = classify(name)
            guard kind != .loopback else { continue }
            let addr = addrs[name]
            let hasAddr = (addr?.ipv4 != nil || addr?.ipv6 != nil)
            // utun 有地址=VPN 在用，保留；其余噪声接口无地址则跳过
            if noisePrefixes.contains(where: { name.hasPrefix($0) }), !hasAddr { continue }
            var down = 0.0, up = 0.0
            if dt > 0, let p = prev[name] {
                down = c.down >= p.down ? Double(c.down - p.down) / dt : 0
                up = c.up >= p.up ? Double(c.up - p.up) / dt : 0
            }
            out.append(NetworkInterfaceInfo(
                id: name, displayName: friendlyName(name, kind: kind), type: kind,
                isActive: hasAddr, ipv4: addr?.ipv4, ipv6: addr?.ipv6, macAddress: c.mac,
                downBytesPerSec: down, upBytesPerSec: up))
        }
        // 活跃优先、物理接口优先
        return out.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.type != b.type { return a.type.rawValue < b.type.rawValue }
            return a.id < b.id
        }
    }

    private func perInterfaceCounters() -> [String: (down: UInt64, up: UInt64, mac: String?)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: (down: UInt64, up: UInt64, mac: String?)] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0, offset + msglen <= len else { break }
                // 读 if_msghdr2（160 字节，大于 if_msghdr）前先确认可安全读取，防越界读
                if hdr.ifm_type == UInt8(RTM_IFINFO2),
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let if2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(if2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        result[name] = (if2.ifm_data.ifi_ibytes, if2.ifm_data.ifi_obytes, nil)
                    }
                }
                offset += msglen
            }
        }
        return result
    }

    private func interfaceAddresses() -> [String: (ipv4: String?, ipv6: String?)] {
        var out: [String: (ipv4: String?, ipv6: String?)] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return out }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            guard let sa = p.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let salen = socklen_t(sa.pointee.sa_len)
            guard getnameinfo(sa, salen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: host)
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }   // 去掉 ipv6 zone
            var entry = out[name] ?? (nil, nil)
            if family == UInt8(AF_INET) { if entry.ipv4 == nil { entry.ipv4 = ip } }
            else { if entry.ipv6 == nil, !ip.hasPrefix("fe80") { entry.ipv6 = ip } }
            out[name] = entry
        }
        return out
    }

    private func classify(_ name: String) -> NetworkInterfaceInfo.Kind {
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("en0") { return .wifi }        // 便携机默认 en0=Wi-Fi
        if name.hasPrefix("en") { return .ethernet }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        if name.hasPrefix("pdp_ip") { return .cellular }
        return .other
    }

    private func friendlyName(_ name: String, kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
        case .wifi: return "Wi-Fi (\(name))"
        case .ethernet: return "以太网 (\(name))"
        case .vpn: return "VPN (\(name))"
        case .cellular: return "蜂窝 (\(name))"
        default: return name
        }
    }

    // MARK: Wi-Fi（CoreWLAN）

    public func wifi() -> WiFiInfo? {
        guard let iface = wifiClient.interface() else { return nil }
        // 无任何字段可读时（未连接/未授权）返回 nil
        let ssid = iface.ssid()
        let rssi = iface.rssiValue()
        let channel = iface.wlanChannel()?.channelNumber
        let tx = iface.transmitRate()
        let sec = securityString(iface.security())
        if ssid == nil && rssi == 0 && channel == nil { return nil }
        return WiFiInfo(ssid: ssid, bssid: iface.bssid(), rssi: rssi == 0 ? nil : rssi,
                        channel: channel, txRate: tx > 0 ? tx : nil, security: sec)
    }

    private func securityString(_ s: CWSecurity) -> String? {
        switch s {
        case .none: return "开放"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal: return "WPA2"
        case .wpa3Personal: return "WPA3"
        case .enterprise, .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise: return "企业级"
        default: return nil
        }
    }

    // MARK: Ping（TCP 握手 RTT，无需 root）

    /// 用 NWConnection 对 host:443 做一次握手计时得近似 RTT（毫秒）。
    private final class PingBox: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    public func ping() async -> Double? {
        let host = NWEndpoint.Host(pingHost)
        let port = NWEndpoint.Port(rawValue: 443)!
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let box = PingBox()
            let conn = NWConnection(host: host, port: port, using: .tcp)
            let start = Date()
            @Sendable func finish(_ ms: Double?) {
                guard box.claim() else { return }
                conn.cancel()
                cont.resume(returning: ms)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Date().timeIntervalSince(start) * 1000)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }   // 超时
        }
    }

    // MARK: 公网 IP（按需 HTTPS 获取，缓存 5 分钟）

    private func cachedFreshPublicIP() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let ip = cachedPublicIP, let at = publicIPFetchedAt, Date().timeIntervalSince(at) < 300 { return ip }
        return nil
    }
    private func storePublicIP(_ ip: String) {
        stateLock.lock(); cachedPublicIP = ip; publicIPFetchedAt = Date(); stateLock.unlock()
    }

    public func publicIP() async -> String? {
        if let cached = cachedFreshPublicIP() { return cached }
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty, ip.count < 64 else { return nil }
        storePublicIP(ip)
        return ip
    }
}
