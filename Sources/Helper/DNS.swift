import Foundation

/// Local DNS server on 127.0.0.1:53 that forwards queries over HTTPS,
/// so the ISP cannot spoof answers for Discord and YouTube.
/// AAAA and HTTPS queries get an empty answer: this keeps apps on IPv4,
/// which is the only family we route through the TUN device.
final class DNSProxy {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dns", attributes: .concurrent)
    private let session: URLSession
    private let upstreams = [
        "https://1.1.1.1/dns-query",
        "https://8.8.8.8/dns-query",
        "https://9.9.9.9/dns-query",
    ]
    private let preferred = Locked(0)
    /// Plain DNS servers from before we took over; used if DoH is down.
    var fallbackServers: [String] = []

    private let port: UInt16

    init(port: UInt16 = 53) {
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.connectionProxyDictionary = [:]
        cfg.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: cfg)
    }

    var running: Bool { fd >= 0 }

    func start() throws {
        if running { return }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw IPCError.io }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            close(s)
            log("dns: bind 127.0.0.1:\(port) failed errno=\(errno)")
            throw IPCError.io
        }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: DispatchQueue(label: "dns.read"))
        src.setEventHandler { [weak self] in self?.receive() }
        src.setCancelHandler { close(s) }
        src.resume()
        source = src
        log("dns: listening on 127.0.0.1:\(port)")
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &len)
            }
        }
        guard n >= 12 else { return }
        let query = Data(buf[0..<n])
        let s = fd
        queue.async { [weak self] in
            guard let self, let answer = self.resolve(query) else { return }
            var to = from
            answer.withUnsafeBytes { raw in
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(s, raw.baseAddress, raw.count, 0, $0, len)
                    }
                }
            }
        }
    }

    private func resolve(_ query: Data) -> Data? {
        if let type = questionType(query), type == 28 || type == 65 {
            return emptyAnswer(query)
        }
        let first = preferred.get()
        for i in 0..<upstreams.count {
            let idx = (first + i) % upstreams.count
            if let answer = doh(upstreams[idx], query) {
                if idx != first { preferred.set(idx) }
                return answer
            }
        }
        for server in fallbackServers where server != "127.0.0.1" {
            if let answer = plain(server, query) { return answer }
        }
        return nil
    }

    private func doh(_ url: String, _ query: Data) -> Data? {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        req.httpBody = query
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, let data, data.count >= 12 {
                result = data
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return result
    }

    private func plain(_ server: String, _ query: Data) -> Data? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }
        let sent = query.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(s, &buf, buf.count, 0)
        return n >= 12 ? Data(buf[0..<n]) : nil
    }

    /// QTYPE of the first question, or nil if the packet is malformed.
    private func questionType(_ q: Data) -> UInt16? {
        let b = [UInt8](q)
        var i = 12
        while i < b.count {
            let l = Int(b[i])
            if l == 0 { break }
            if l & 0xc0 != 0 { return nil }
            i += l + 1
        }
        guard i + 2 < b.count else { return nil }
        return UInt16(b[i + 1]) << 8 | UInt16(b[i + 2])
    }

    /// NOERROR response with the question echoed and no answers.
    private func emptyAnswer(_ q: Data) -> Data {
        var b = [UInt8](q)
        b[2] = 0x80 | (b[2] & 0x01) // QR=1, keep RD
        b[3] = 0x80 // RA=1, RCODE=0
        b[6] = 0; b[7] = 0 // ANCOUNT
        b[8] = 0; b[9] = 0 // NSCOUNT
        b[10] = 0; b[11] = 0 // ARCOUNT
        // Drop any EDNS OPT record the client appended after the question.
        var i = 12
        while i < b.count, b[i] != 0 { i += Int(b[i]) + 1 }
        let end = min(i + 5, b.count)
        return Data(b[0..<end])
    }
}

/// Points every network service at 127.0.0.1 and puts it back afterwards.
/// The original settings are saved to disk, so a crash cannot lose them.
enum SystemDNS {
    private static let backupPath = ZapretPaths.state + "/dns-backup.json"
    private static let networksetup = "/usr/sbin/networksetup"

    static func services() -> [String] {
        run(networksetup, ["-listallnetworkservices"]).output
            .split(separator: "\n")
            .dropFirst() // "An asterisk (*) denotes ..."
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    static func servers(of service: String) -> [String] {
        let out = run(networksetup, ["-getdnsservers", service]).output
        if out.contains("aren't any") { return [] }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var isApplied: Bool { currentDNSServers().first == "127.0.0.1" }

    static func apply() {
        var backup = readJSON([String: [String]].self, backupPath) ?? [:]
        for svc in services() {
            let current = servers(of: svc)
            if current == ["127.0.0.1"] { continue }
            if backup[svc] == nil { backup[svc] = current }
            writeJSON(backup, backupPath)
            run(networksetup, ["-setdnsservers", svc, "127.0.0.1"])
        }
        flush()
        log("dns: system resolvers set to 127.0.0.1")
    }

    static func restore() {
        guard let backup = readJSON([String: [String]].self, backupPath) else { return }
        for (svc, servers) in backup {
            run(networksetup, ["-setdnsservers", svc] + (servers.isEmpty ? ["Empty"] : servers))
        }
        try? FileManager.default.removeItem(atPath: backupPath)
        flush()
        log("dns: system resolvers restored")
    }

    static func flush() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
}
