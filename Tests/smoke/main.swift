import Foundation
// Smoke test without root: DNS proxy on a high port and probes through ciadpi.
let vendor = CommandLine.arguments[1]
let dns = DNSProxy(port: 15353)
try! dns.start()
for (name, type) in [("discord.com", "A"), ("discord.com", "AAAA"), ("www.youtube.com", "TYPE65")] {
    let r = run("/usr/bin/dig", ["+short", "+time=5", "@127.0.0.1", "-p", "15353", name, type])
    print("dig \(name) \(type): [\(r.output.split(separator: "\n").prefix(3).joined(separator: ", "))]")
}
let hosts = NSTemporaryDirectory() + "zapret-hosts.txt"
let lists = try! String(contentsOfFile: vendor + "/flowseal/lists/list-general.txt", encoding: .utf8)
try! (Lists.parse(lists) + ["youtube.com", "googlevideo.com", "discord.com"]).joined(separator: "\n").write(toFile: hosts, atomically: true, encoding: .utf8)
print("parsed hosts:", Lists.parse(lists).count)
for (i, s) in strategies.enumerated() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: vendor + "/byedpi/ciadpi")
    p.arguments = ciadpiArguments(strategy: s, port: 18100 + i, hostsFile: hosts, dataDir: vendor + "/flowseal/bin")
    p.environment = ["CIADPI_BOUND_IF": primaryInterface() ?? "en0"]
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    Thread.sleep(forTimeInterval: 0.3)
    if !p.isRunning { print("\(s.id): ciadpi exited \(p.terminationStatus)"); continue }
    let t0 = Date()
    let passed = Prober.probe(socksPort: 18100 + i)
    print("\(s.id): \(passed.count)/\(Prober.targets.count) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s missing \(Set(Prober.targets.map(\.name)).subtracting(passed).sorted())")
    kill(p.processIdentifier, SIGKILL)
}
print("internet direct:", Prober.internetWorks(socksPort: nil))
