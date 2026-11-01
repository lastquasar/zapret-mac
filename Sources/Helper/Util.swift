import Foundation
import SystemConfiguration

private let logQueue = DispatchQueue(label: "log")
private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    logQueue.sync {
        FileHandle.standardError.write("\(logFormatter.string(from: Date())) \(message)\n".data(using: .utf8)!)
    }
}

/// Runs a command to completion and returns its exit code and combined output.
@discardableResult
func run(_ path: String, _ args: [String]) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Name of the interface macOS uses for the internet (en0, en1, ...).
/// Our utun device is not a network service, so it never shows up here.
func primaryInterface() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "zapret" as CFString, nil, nil),
          let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    else { return nil }
    return dict["PrimaryInterface"] as? String
}

/// Gateway of the primary interface (the home router).
func primaryRouter() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "zapret" as CFString, nil, nil),
          let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    else { return nil }
    return dict["Router"] as? String
}

/// DNS servers macOS uses right now (from DHCP or manual settings).
func currentDNSServers() -> [String] {
    guard let store = SCDynamicStoreCreate(nil, "zapret" as CFString, nil, nil),
          let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
    else { return [] }
    return dict["ServerAddresses"] as? [String] ?? []
}

func readJSON<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

func writeJSON<T: Encodable>(_ value: T, _ path: String) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// A thread-safe box for values shared between the engine queue and others.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}
