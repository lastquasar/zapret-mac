import Foundation

// Root helper, started by launchd. The app talks to it over a Unix socket.

setvbuf(stderr, nil, _IOLBF, 0)

// launchd appends to this file forever; keep it small.
if let size = (try? FileManager.default.attributesOfItem(atPath: ZapretPaths.log))?[.size] as? Int, size > 5 << 20 {
    truncate(ZapretPaths.log, 0)
}

log("helper \(zapretHelperVersion) starting")
let engine = Engine()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler {
        log("helper: signal \(sig), restoring network")
        engine.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

func handle(_ fd: Int32) {
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard let line = try? readLine(fd, limit: 4096),
          let req = try? JSONDecoder().decode(HelperRequest.self, from: line) else { return }

    var reply: HelperStatus
    switch req.cmd {
    case "enable": engine.enable(); reply = engine.status
    case "disable": engine.disable(); reply = engine.status
    case "repick": engine.repick(); reply = engine.status
    case "update-lists": engine.updateLists(); reply = engine.status
    case "report": reply = engine.status; reply.report = engine.report()
    default: reply = engine.status
    }
    guard var data = try? JSONEncoder().encode(reply) else { return }
    data.append(0x0a)
    try? writeAll(fd, data)
}

unlink(ZapretPaths.socket)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = unixAddress(ZapretPaths.socket)
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard server >= 0, bound == 0, listen(server, 16) == 0 else {
    log("helper: cannot listen on \(ZapretPaths.socket), errno \(errno)")
    exit(1)
}
// Any local user may talk to us; the commands take no arguments, so the
// worst a stranger can do is switch the bypass on or off.
chmod(ZapretPaths.socket, 0o666)

engine.boot()

Thread.detachNewThread {
    while true {
        let c = accept(server, nil, nil)
        if c < 0 { continue }
        DispatchQueue.global().async { handle(c) }
    }
}

dispatchMain()
