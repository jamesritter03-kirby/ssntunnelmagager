import Foundation
import Darwin
import CommonCrypto

/// A WinBox-style "connect by MAC address" client for MikroTik RouterOS, speaking
/// the open MAC-Telnet protocol over UDP broadcast (port 20561). The router's MAC
/// address in each packet header selects which device answers, so a freshly
/// flattened switch with no IP address can still be reached on the same broadcast
/// domain — no raw sockets or elevated privileges required.
///
/// Output arrives via `onOutput`; feed keystrokes back with `send(_:)`.
final class MacTelnetClient {
    private let port: UInt16 = 20561
    private static let cpMagic: [UInt8] = [0x56, 0x34, 0x12, 0xff]

    // Packet types.
    private let PTYPE_SESSIONSTART: UInt8 = 0
    private let PTYPE_DATA: UInt8 = 1
    private let PTYPE_ACK: UInt8 = 2
    private let PTYPE_PING: UInt8 = 4
    private let PTYPE_PONG: UInt8 = 5
    private let PTYPE_END: UInt8 = 255

    // Control packet types.
    private let CP_BEGINAUTH: UInt8 = 0
    private let CP_ENCRYPTIONKEY: UInt8 = 1
    private let CP_PASSWORD: UInt8 = 2
    private let CP_USERNAME: UInt8 = 3
    private let CP_TERM_TYPE: UInt8 = 4
    private let CP_TERM_WIDTH: UInt8 = 5
    private let CP_TERM_HEIGHT: UInt8 = 6
    private let CP_END_AUTH: UInt8 = 9
    private let CP_PLAINDATA: UInt8 = 0xff

    private enum State { case sessionStart, beginAuth, authDone, connected, closed }

    private let dstMac: [UInt8]
    private let username: String
    private let password: String
    private let targetIP: String?

    private var srcMac: [UInt8] = [0, 0, 0, 0, 0, 0]
    private let sesKey: UInt16 = UInt16.random(in: 1...0xFFFE)
    private var outCounter: UInt32 = 0
    private var inCounter: UInt32 = 0

    private var fd: Int32 = -1
    private var state: State = .sessionStart
    private var retryPacket: [UInt8]?
    private var retries = 0
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24

    private let queue = DispatchQueue(label: "mac-telnet.rx")
    private var running = false

    /// Terminal output from the device (UTF-8 / VT bytes).
    var onOutput: (([UInt8]) -> Void)?
    /// A short human-readable status line (connecting / errors / closed).
    var onStatus: ((String) -> Void)?
    /// Fired once when the session ends.
    var onClose: (() -> Void)?

    /// - Parameter macAddress: router MAC, e.g. "E4:8D:8C:11:22:33" or "e48d8c112233".
    init(macAddress: String, username: String, password: String, targetIP: String? = nil) {
        self.dstMac = MacTelnetClient.parseMac(macAddress) ?? [0, 0, 0, 0, 0, 0]
        self.username = username
        self.password = password
        self.targetIP = (targetIP?.isEmpty ?? true) ? nil : targetIP
    }

    // MARK: - Lifecycle

    func start(cols: UInt16 = 80, rows: UInt16 = 24) {
        self.cols = cols
        self.rows = rows
        srcMac = MacTelnetClient.pickSourceMac(target: targetIP)

        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { onStatus?("Could not open a UDP socket."); onClose?(); return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindOK != 0 { onStatus?("Could not bind the UDP socket."); close(fd); onClose?(); return }

        // 1-second receive timeout so the loop can resend the handshake.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        running = true
        feedText("\u{1b}[2mConnecting via MAC-Telnet to \(MacTelnetClient.formatMac(dstMac)) as \(username)…\u{1b}[0m\r\n")

        retryPacket = header(PTYPE_SESSIONSTART, counter: 0)
        sendToRouter(retryPacket!)

        queue.async { [weak self] in self?.receiveLoop() }
    }

    func stop() {
        guard running else { return }
        if state == .connected { sendToRouter(header(PTYPE_END, counter: outCounter)) }
        running = false
        state = .closed
        if fd >= 0 { close(fd); fd = -1 }
        onClose?()
    }

    // MARK: - Terminal I/O

    func send(_ data: [UInt8]) {
        guard running, state == .connected, !data.isEmpty else { return }
        let pkt = header(PTYPE_DATA, counter: outCounter, payload: data)
        outCounter &+= UInt32(data.count)
        sendToRouter(pkt)
    }

    func resize(cols: UInt16, rows: UInt16) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        guard running, state == .connected else { return }
        var payload = control(CP_TERM_WIDTH, leU16(self.cols))
        payload += control(CP_TERM_HEIGHT, leU16(self.rows))
        let pkt = header(PTYPE_DATA, counter: outCounter, payload: payload)
        outCounter &+= UInt32(payload.count)
        sendToRouter(pkt)
    }

    // MARK: - Receive loop / state machine

    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(12)

        while running {
            var from = sockaddr()
            var fromLen = socklen_t(MemoryLayout<sockaddr>.size)
            let n = recvfrom(fd, &buf, buf.count, 0, &from, &fromLen)
            if n < 0 {
                if state == .connected { continue } // idle keepalive
                if Date() > deadline {
                    feedText("\r\n\u{1b}[31mNo response from the device. MAC-Telnet may be disabled " +
                             "on its interface, or it is on a different broadcast domain.\u{1b}[0m\r\n")
                    stop(); return
                }
                if let rp = retryPacket, retries < 12 { retries += 1; sendToRouter(rp) }
                continue
            }
            if n < 20 { continue }
            handlePacket(Array(buf[0..<n]))
        }
    }

    private func handlePacket(_ data: [UInt8]) {
        let ptype = data[1]
        let seskey = UInt16(data[14]) << 8 | UInt16(data[15])
        if seskey != sesKey && ptype != PTYPE_SESSIONSTART { return }
        let counter = UInt32(data[16]) << 24 | UInt32(data[17]) << 16 | UInt32(data[18]) << 8 | UInt32(data[19])

        switch ptype {
        case PTYPE_ACK:
            return
        case PTYPE_PING:
            let echo = data.count > 20 ? Array(data[20...]) : []
            sendToRouter(header(PTYPE_PONG, counter: counter, payload: echo))
        case PTYPE_END:
            feedText("\r\n\u{1b}[2m— session closed by device —\u{1b}[0m\r\n")
            stop()
        case PTYPE_SESSIONSTART:
            if state == .sessionStart { sendBeginAuth() }
        case PTYPE_DATA:
            let payloadLen = UInt32(data.count - 20)
            sendToRouter(header(PTYPE_ACK, counter: counter &+ payloadLen))
            if counter == inCounter {
                inCounter &+= payloadLen
                processControl(data)
            }
        default:
            return
        }
    }

    private func processControl(_ data: [UInt8]) {
        var pos = 20
        let end = data.count
        while pos < end {
            if end - pos >= 9 && Array(data[pos..<pos + 4]) == MacTelnetClient.cpMagic {
                let cptype = data[pos + 4]
                var len = Int(UInt32(data[pos + 5]) << 24 | UInt32(data[pos + 6]) << 16 |
                              UInt32(data[pos + 7]) << 8 | UInt32(data[pos + 8]))
                let dataStart = pos + 9
                if dataStart + len > end { len = end - dataStart }

                switch cptype {
                case CP_ENCRYPTIONKEY:
                    if (state == .beginAuth || state == .sessionStart) && len >= 16 {
                        sendAuth(salt: Array(data[dataStart..<dataStart + 16]))
                    }
                case CP_END_AUTH:
                    if state != .connected {
                        state = .connected
                        retryPacket = nil
                        feedText("\u{1b}[2m— connected —\u{1b}[0m\r\n")
                    }
                case CP_PLAINDATA:
                    if len > 0 { onOutput?(Array(data[dataStart..<dataStart + len])) }
                default:
                    break
                }
                pos = dataStart + len
            } else {
                onOutput?(Array(data[pos..<end]))
                pos = end
            }
        }
    }

    private func sendBeginAuth() {
        let payload = control(CP_BEGINAUTH, [])
        retryPacket = header(PTYPE_DATA, counter: outCounter, payload: payload)
        outCounter &+= UInt32(payload.count)
        state = .beginAuth
        retries = 0
        sendToRouter(retryPacket!)
    }

    private func sendAuth(salt: [UInt8]) {
        // password field = 0x00 + md5( 0x00 + password + 16-byte salt )
        var toHash: [UInt8] = [0]
        toHash += Array(password.utf8)
        toHash += salt
        let digest = MacTelnetClient.md5(toHash)
        var passField: [UInt8] = [0]
        passField += digest

        var payload = control(CP_PASSWORD, passField)
        payload += control(CP_USERNAME, Array(username.utf8))
        payload += control(CP_TERM_TYPE, Array("xterm".utf8))
        payload += control(CP_TERM_WIDTH, leU16(cols))
        payload += control(CP_TERM_HEIGHT, leU16(rows))

        retryPacket = header(PTYPE_DATA, counter: outCounter, payload: payload)
        outCounter &+= UInt32(payload.count)
        state = .authDone
        retries = 0
        sendToRouter(retryPacket!)
    }

    // MARK: - Packet construction / transmit

    private func header(_ ptype: UInt8, counter: UInt32, payload: [UInt8] = []) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 20 + payload.count)
        p[0] = 1
        p[1] = ptype
        for i in 0..<6 { p[2 + i] = srcMac[i] }
        for i in 0..<6 { p[8 + i] = dstMac[i] }
        p[14] = UInt8(sesKey >> 8)
        p[15] = UInt8(sesKey & 0xFF)
        p[16] = UInt8((counter >> 24) & 0xFF)
        p[17] = UInt8((counter >> 16) & 0xFF)
        p[18] = UInt8((counter >> 8) & 0xFF)
        p[19] = UInt8(counter & 0xFF)
        if !payload.isEmpty { for i in 0..<payload.count { p[20 + i] = payload[i] } }
        return p
    }

    private func control(_ cptype: UInt8, _ data: [UInt8]) -> [UInt8] {
        var p = MacTelnetClient.cpMagic
        p.append(cptype)
        let len = UInt32(data.count)
        p.append(UInt8((len >> 24) & 0xFF))
        p.append(UInt8((len >> 16) & 0xFF))
        p.append(UInt8((len >> 8) & 0xFF))
        p.append(UInt8(len & 0xFF))
        p += data
        return p
    }

    private func sendToRouter(_ packet: [UInt8]) {
        guard fd >= 0 else { return }
        // Unicast to the device when its IP is known, plus a global broadcast so a
        // device with no IP can still be reached on the local segment.
        if let ip = targetIP { sendPacket(packet, toIPv4: ip) }
        sendPacket(packet, toIPv4: "255.255.255.255")
        for b in MacTelnetClient.directedBroadcasts() { sendPacket(packet, toIPv4: b) }
    }

    private func sendPacket(_ packet: [UInt8], toIPv4 ip: String) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        _ = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                packet.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, packet.count, 0, sap,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func feedText(_ s: String) { onOutput?(Array(s.utf8)) }

    // MARK: - Helpers

    private func leU16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    private static func parseMac(_ mac: String) -> [UInt8]? {
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var out = [UInt8]()
        var idx = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    private static func formatMac(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func md5(_ bytes: [UInt8]) -> [UInt8] {
        var ctx = CC_MD5_CTX()
        CC_MD5_Init(&ctx)
        CC_MD5_Update(&ctx, bytes, CC_LONG(bytes.count))
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        CC_MD5_Final(&digest, &ctx)
        return digest
    }

    /// Local interface MAC to advertise as the packet source: prefers the NIC on
    /// the same subnet as `target`, else the first up, non-loopback NIC.
    private static func pickSourceMac(target: String?) -> [UInt8] {
        var macByName: [String: [UInt8]] = [:]
        var v4ByName: [String: (ip: UInt32, mask: UInt32)] = [:]

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [0, 0, 0, 0, 0, 0] }
        defer { freeifaddrs(ifap) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            let flags = Int32(cur.pointee.ifa_flags)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if let sa = cur.pointee.ifa_addr, !isLoopback {
                if sa.pointee.sa_family == UInt8(AF_LINK) {
                    if let mac = macBytes(sa) { macByName[name] = mac }
                } else if sa.pointee.sa_family == UInt8(AF_INET) {
                    let ip = ipv4(sa)
                    let mask = cur.pointee.ifa_netmask.map { ipv4($0) } ?? 0
                    if ip != 0 { v4ByName[name] = (ip, mask) }
                }
            }
            ptr = cur.pointee.ifa_next
        }

        var targetIP: UInt32 = 0
        if let t = target {
            var a = in_addr()
            if inet_pton(AF_INET, t, &a) == 1 { targetIP = UInt32(bigEndian: a.s_addr) }
        }

        // Prefer the interface whose subnet contains the target.
        if targetIP != 0 {
            for (name, v4) in v4ByName where (v4.ip & v4.mask) == (targetIP & v4.mask) {
                if let mac = macByName[name] { return mac }
            }
        }
        // Otherwise first interface that has both an IPv4 and a MAC.
        for (name, _) in v4ByName {
            if let mac = macByName[name] { return mac }
        }
        return macByName.values.first ?? [0, 0, 0, 0, 0, 0]
    }

    /// Directed broadcast address of every active IPv4 interface.
    private static func directedBroadcasts() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) == 0, let sa = cur.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET), let nm = cur.pointee.ifa_netmask {
                let ip = ipv4(sa), mask = ipv4(nm)
                if ip != 0 {
                    let bc = ip | ~mask
                    let s = "\((bc >> 24) & 0xFF).\((bc >> 16) & 0xFF).\((bc >> 8) & 0xFF).\(bc & 0xFF)"
                    if !out.contains(s) { out.append(s) }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return out
    }

    private static func ipv4(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }

    /// Extract a 6-byte MAC from an AF_LINK `sockaddr_dl`.
    private static func macBytes(_ sa: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
        return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> [UInt8]? in
            let alen = Int(dl.pointee.sdl_alen)
            let nlen = Int(dl.pointee.sdl_nlen)
            guard alen == 6 else { return nil }
            let raw = UnsafeRawPointer(dl)
            let dataOffset = 8 + nlen // sdl_data begins at byte offset 8
            var mac = [UInt8](repeating: 0, count: 6)
            for i in 0..<6 { mac[i] = raw.load(fromByteOffset: dataOffset + i, as: UInt8.self) }
            return mac.allSatisfy { $0 == 0 } ? nil : mac
        }
    }
}
