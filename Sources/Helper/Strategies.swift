import Foundation

/// TCP desync settings for ByeDPI. The user never sees these:
/// the helper tries them in order and keeps the first one that works.
/// macOS has no raw-packet fakes, so only split/disorder/oob/tlsrec tricks apply.
struct Strategy {
    let id: String
    let args: [String]
}

let strategies: [Strategy] = [
    Strategy(id: "split-disorder-sni", args: ["-s1+s", "-d3+s", "-r1+s"]),
    Strategy(id: "disorder1", args: ["-d1"]),
    Strategy(id: "tlsrec-split", args: ["-r1+s", "-s1"]),
    Strategy(id: "tlsrec-oob", args: ["-r1+s", "-o1+s"]),
    Strategy(id: "multi-disorder", args: ["-d1", "-d3+s", "-s6+s", "-d9+s", "-s12+s", "-d15+s", "-s20+s", "-d25+s", "-s30+s", "-d35+s"]),
    Strategy(id: "tlsrec-multi", args: ["-r1+s", "-r3+s", "-d1+s", "-s5+s"]),
    Strategy(id: "split-tlsminor", args: ["-s1+s", "-d3+s", "-m", "1", "-r1+s"]),
    Strategy(id: "disorder-sni-end", args: ["-d1", "-d0+se", "-r1+se"]),
    Strategy(id: "tlsrec-disorder-mid", args: ["-r1+sm", "-d1+sm", "-s2+sm"]),
    Strategy(id: "split-http", args: ["-s1", "-d3+s", "-M", "h,d", "-r1+s"]),
    // OOB tricks broke connections in tests on macOS; keep them as a last resort.
    Strategy(id: "disoob-tlsrec", args: ["-q1+s", "-r1+s"]),
    Strategy(id: "oob-sni-middle", args: ["-o1", "-o0+sm", "-r1+sm"]),
]

/// Discord voice ports and QUIC, taken from Flowseal's general.bat.
private let udpGroups: [(ports: String, fake: String)] = [
    ("50000-50100", "ACTIVE_DISCORD_UDP.bin"),
    ("19294-19344", "ACTIVE_DISCORD_UDP.bin"),
    ("443", "quic_initial_www_google_com.bin"),
]

/// Full ciadpi command line for one strategy.
/// Group order matters: UDP groups first (ciadpi picks the first match),
/// then the TCP group limited to the host list; anything else passes untouched.
func ciadpiArguments(strategy: Strategy, port: Int, hostsFile: String, dataDir: String = ZapretPaths.data) -> [String] {
    var args = ["-i", "127.0.0.1", "-p", "\(port)", "-I", "0.0.0.0", "-c", "2048"]
    for (i, g) in udpGroups.enumerated() {
        if i > 0 { args += ["-A", "n"] }
        args += ["-K", "u", "-V", g.ports, "-a", "6", "-t", "64", "-l", dataDir + "/" + g.fake]
    }
    args += ["-A", "n", "-K", "t,h", "-H", hostsFile] + strategy.args
    return args
}
