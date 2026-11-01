import Foundation

/// Bumped whenever the helper changes, so the app knows to reinstall it.
let zapretHelperVersion = "3"

enum ZapretPaths {
    static let label = "local.zapret.helper"
    static let socket = "/var/run/zapret.sock"
    static let base = "/Library/Application Support/Zapret"
    static let bin = base + "/bin"
    static let data = base + "/data"
    static let defaultLists = base + "/lists-default"
    static let state = base + "/state"
    static let logDir = "/Library/Logs/Zapret"
    static let log = logDir + "/helper.log"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
}

enum EngineState: String, Codable {
    case off, starting, picking, on, waiting, error
}

struct HelperRequest: Codable {
    var cmd: String
}

struct HelperStatus: Codable {
    var state: EngineState
    var message: String
    var enabled: Bool
    var warning: String?
    var strategy: String?
    var version: String
    var report: String?
}

enum IPCError: Error {
    case connect, io
}

/// One request/response round trip over the helper's Unix socket.
/// Each side writes a single JSON line.
func ipcCall(_ request: HelperRequest, timeout: TimeInterval = 3) throws -> HelperStatus {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.connect }
    defer { close(fd) }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = unixAddress(ZapretPaths.socket)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else { throw IPCError.connect }

    var out = try JSONEncoder().encode(request)
    out.append(0x0a)
    try writeAll(fd, out)
    let line = try readLine(fd)
    return try JSONDecoder().decode(HelperStatus.self, from: line)
}

func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.prefix(raw.count - 1).enumerated() { raw[i] = b }
    }
    return addr
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { throw IPCError.io }
            off += n
        }
    }
}

func readLine(_ fd: Int32, limit: Int = 4 << 20) throws -> Data {
    var result = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while result.count < limit {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        result.append(contentsOf: buf[0..<n])
        if buf[n - 1] == 0x0a { break }
    }
    guard !result.isEmpty else { throw IPCError.io }
    return result
}
