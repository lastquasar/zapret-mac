import Foundation

struct Settings: Codable {
    var enabled = false
    var strategy: String?
}

/// Owns everything that changes the network: DNS, ciadpi, tun2socks, routes.
/// All of that runs on `q`; IPC threads only read the status snapshot.
final class Engine {
    static let tunName = "utun225"
    static let tunAddr = "198.18.0.1"
    static let mainPort = 10800
    static let probeBasePort = 10810

    private let q = DispatchQueue(label: "engine")
    private let statusBox: Locked<HelperStatus>
    /// Bumped by "disable" so a long strategy search stops early.
    private let generation = Locked(0)
    private let settingsPath = ZapretPaths.state + "/settings.json"
    private var settings: Settings
    private let dns = DNSProxy()
    private var ciadpi: Process?
    private var tun: Process?
    private var iface: String?
    /// Interface and gateway of the scoped routes ciadpi uses to bypass the TUN device.
    private var scoped: (iface: String, router: String)?
    private var strategy: Strategy?
    private var retryAt: Date?
    private var netFailures = 0
    private var healthFailures = 0
    private var tick = 0
    private var timer: DispatchSourceTimer?

    init() {
        try? FileManager.default.createDirectory(atPath: ZapretPaths.state, withIntermediateDirectories: true)
        settings = readJSON(Settings.self, ZapretPaths.state + "/settings.json") ?? Settings()
        statusBox = Locked(HelperStatus(state: .off, message: "Выключено", enabled: settings.enabled,
                                        warning: nil, strategy: settings.strategy,
                                        version: zapretHelperVersion, report: nil))
    }

    var status: HelperStatus { statusBox.get() }

    func boot() {
        q.async {
            self.cleanupLeftovers()
            Lists.rebuild()
            if self.settings.enabled { self.bringUp() }
            self.startTimer()
        }
    }

    // MARK: - Commands from the app

    func enable() {
        statusBox.update { $0.enabled = true }
        q.async {
            self.settings.enabled = true
            self.saveSettings()
            if ![.on, .picking].contains(self.statusBox.get().state) { self.bringUp() }
        }
    }

    func disable() {
        statusBox.update { $0.enabled = false }
        generation.update { $0 += 1 }
        q.async {
            self.settings.enabled = false
            self.saveSettings()
            self.retryAt = nil
            self.tearDown()
            self.setStatus(.off, "Выключено")
        }
    }

    func repick() {
        q.async {
            guard self.settings.enabled else { return }
            if self.statusBox.get().state == .on {
                self.repickLive()
            } else {
                self.settings.strategy = nil
                self.bringUp()
            }
        }
    }

    func updateLists() {
        q.async {
            if Lists.update(), self.statusBox.get().state == .on { self.restartCiadpi() }
        }
    }

    /// Called on SIGTERM: put the network back but remember that the user wants it on.
    func shutdown() {
        generation.update { $0 += 1 }
        q.sync { self.tearDown() }
    }

    // MARK: - Bring up / tear down

    private func bringUp() {
        let gen = generation.get()
        retryAt = nil
        netFailures = 0
        healthFailures = 0
        setStatus(.starting, "Включаю…")
        tearDown()

        guard let ifc = primaryInterface() else {
            return wait("Нет подключения к интернету. Жду сеть…", retry: 15)
        }
        iface = ifc
        if !FileManager.default.fileExists(atPath: Lists.hostsFile) { Lists.rebuild() }

        guard Prober.internetWorks(socksPort: nil) else {
            return wait("Нет подключения к интернету. Жду сеть…", retry: 15)
        }

        // Plain DNS from before we took over, in case all DoH servers fail.
        let backup = readJSON([String: [String]].self, ZapretPaths.state + "/dns-backup.json") ?? [:]
        dns.fallbackServers = currentDNSServers().filter { $0 != "127.0.0.1" } + backup.values.flatMap { $0 }
        do {
            try dns.start()
        } catch {
            return fail("Не удалось запустить DNS. Повторю через минуту.", retry: 60)
        }
        SystemDNS.apply()

        guard let s = pickStrategy(iface: ifc, gen: gen) else {
            if cancelled(gen) { return tearDown() }
            tearDown()
            return fail("YouTube и Discord не открываются ни с одной настройкой. Повторю через 10 минут.", retry: 600)
        }
        if cancelled(gen) { return tearDown() }
        use(s)

        guard startMainCiadpi(), startTun() else {
            tearDown()
            return fail("Не удалось включить обход. Повторю через минуту.", retry: 60)
        }
        if !Prober.internetWorks(socksPort: nil) {
            log("engine: internet check through TUN failed right after start")
            tearDown()
            return fail("Сеть не заработала через обход. Повторю через 5 минут.", retry: 300)
        }
        setStatus(.on, "Работает")
        updateWarning()
    }

    private func tearDown() {
        removeRoutes()
        stop(tun); tun = nil
        stop(ciadpi); ciadpi = nil
        SystemDNS.restore()
        dns.stop()
    }

    /// Removes anything a crashed helper may have left behind.
    private func cleanupLeftovers() {
        removeRoutes()
        if let ifc = primaryInterface() { removeScopedRoutes(ifc) }
        run("/usr/bin/pkill", ["-9", "-f", ZapretPaths.bin + "/ciadpi"])
        run("/usr/bin/pkill", ["-9", "-f", ZapretPaths.bin + "/tun2socks"])
        SystemDNS.restore()
    }

    private func wait(_ message: String, retry: TimeInterval) {
        tearDown()
        setStatus(.waiting, message)
        retryAt = Date().addingTimeInterval(retry)
    }

    private func fail(_ message: String, retry: TimeInterval) {
        setStatus(.error, message)
        retryAt = Date().addingTimeInterval(retry)
    }

    private func cancelled(_ gen: Int) -> Bool {
        generation.get() != gen || !settings.enabled
    }

    private func use(_ s: Strategy) {
        strategy = s
        settings.strategy = s.id
        saveSettings()
        statusBox.update { $0.strategy = s.id }
        log("engine: using strategy \(s.id)")
    }

    // MARK: - Strategy search

    /// Tries strategies (the saved one first) on spare ports, 4 at a time.
    /// Returns the first that passes every probe, or else the best partial one.
    private func pickStrategy(iface: String, gen: Int) -> Strategy? {
        setStatus(.picking, "Подбираю настройки… Это займёт до минуты.")
        var order = strategies
        if let saved = settings.strategy, let i = order.firstIndex(where: { $0.id == saved }) {
            order.insert(order.remove(at: i), at: 0)
        }
        let full = Prober.targets.count
        var best: (strategy: Strategy, score: Int)?
        var start = 0
        while start < order.count {
            if cancelled(gen) { return nil }
            let batch = Array(order[start..<min(start + 4, order.count)])
            var scores = [Int](repeating: 0, count: batch.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                let port = Engine.probeBasePort + i
                guard let p = launchCiadpi(batch[i], port: port, iface: iface, quiet: true) else { return }
                let passed = Prober.probe(socksPort: port)
                stop(p)
                lock.lock(); scores[i] = passed.count; lock.unlock()
                log("pick: \(batch[i].id) passed \(passed.count)/\(full) \(passed.sorted())")
            }
            for (i, s) in batch.enumerated() {
                if scores[i] == full { return s }
                if scores[i] > (best?.score ?? 0) { best = (s, scores[i]) }
            }
            start += batch.count
        }
        return best?.strategy
    }

    /// Searches again while the current setup keeps running.
    private func repickLive() {
        let gen = generation.get()
        guard let ifc = iface, let s = pickStrategy(iface: ifc, gen: gen), !cancelled(gen) else {
            if !cancelled(gen) { setStatus(.on, "Работает") }
            return
        }
        if s.id != strategy?.id {
            use(s)
            restartCiadpi()
        }
        setStatus(.on, "Работает")
    }

    // MARK: - Processes

    private func launchCiadpi(_ s: Strategy, port: Int, iface: String, quiet: Bool) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ZapretPaths.bin + "/ciadpi")
        p.arguments = ciadpiArguments(strategy: s, port: port, hostsFile: Lists.hostsFile)
        // Our ByeDPI patch reads this and pins outgoing sockets to the real interface.
        p.environment = ["CIADPI_BOUND_IF": iface]
        p.standardOutput = FileHandle.nullDevice
        if quiet { p.standardError = FileHandle.nullDevice }
        do { try p.run() } catch {
            log("engine: ciadpi failed to start: \(error)")
            return nil
        }
        Thread.sleep(forTimeInterval: 0.3)
        guard p.isRunning else {
            log("engine: ciadpi exited at once, code \(p.terminationStatus)")
            return nil
        }
        return p
    }

    private func startMainCiadpi() -> Bool {
        guard let s = strategy, let ifc = iface else { return false }
        ciadpi = launchCiadpi(s, port: Engine.mainPort, iface: ifc, quiet: false)
        return ciadpi != nil
    }

    private func restartCiadpi() {
        stop(ciadpi)
        ciadpi = nil
        if !startMainCiadpi() { log("engine: ciadpi restart failed") }
    }

    private func startTun() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ZapretPaths.bin + "/tun2socks")
        // tun2socks uses pflag: long options need two dashes.
        p.arguments = ["--device", Engine.tunName,
                       "--proxy", "socks5://127.0.0.1:\(Engine.mainPort)",
                       "--loglevel", "warn", "--udp-timeout", "60s", "--mtu", "1500"]
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            log("engine: tun2socks failed to start: \(error)")
            return false
        }
        tun = p
        // Wait for the utun device to appear before configuring it.
        var up = false
        for _ in 0..<30 {
            if run("/sbin/ifconfig", [Engine.tunName]).code == 0 { up = true; break }
            if !p.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard up else {
            log("engine: \(Engine.tunName) did not appear")
            return false
        }
        run("/sbin/ifconfig", [Engine.tunName, Engine.tunAddr, Engine.tunAddr, "up"])
        addScopedRoutes()
        // Two /1 routes beat the default route without replacing it,
        // so macOS still knows the real gateway.
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            let r = run("/sbin/route", ["-q", "-n", "add", "-net", net, "-interface", Engine.tunName])
            if r.code != 0 { log("engine: route add \(net) failed: \(r.output)") }
        }
        if let ifc = iface {
            let check = run("/sbin/route", ["-n", "get", "-ifscope", ifc, "1.1.1.1"]).output
            log("engine: scoped route check: " + check.split(separator: "\n")
                .filter { $0.contains("gateway") || $0.contains("interface") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
        }
        return true
    }

    /// ciadpi sockets are pinned to the real interface (IP_BOUND_IF). macOS
    /// prefers our more specific /1 routes over that interface's default route
    /// and then fails with "Network is unreachable". The same /1 routes scoped
    /// to the real interface give pinned sockets a way out.
    private func addScopedRoutes() {
        guard let ifc = iface, let router = primaryRouter() else {
            log("engine: no gateway for scoped routes")
            return
        }
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            let r = run("/sbin/route", ["-q", "-n", "add", "-ifscope", ifc, "-net", net, router])
            if r.code != 0 { log("engine: scoped route add \(net) failed: \(r.output)") }
        }
        scoped = (ifc, router)
    }

    private func removeScopedRoutes(_ ifc: String) {
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            run("/sbin/route", ["-q", "-n", "delete", "-ifscope", ifc, "-net", net])
        }
    }

    private func restartTun() {
        removeRoutes()
        stop(tun)
        tun = nil
        if !startTun() { log("engine: tun2socks restart failed") }
    }

    private func removeRoutes() {
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            run("/sbin/route", ["-q", "-n", "delete", "-net", net, "-interface", Engine.tunName])
        }
        if let s = scoped { removeScopedRoutes(s.iface) }
        scoped = nil
    }

    // MARK: - Background checks

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        timer = t
    }

    private func onTick() {
        tick += 1
        guard settings.enabled else { return }
        if let r = retryAt {
            if Date() >= r { bringUp() }
            return
        }
        guard statusBox.get().state == .on else { return }

        guard let ifc = primaryInterface() else {
            setStatus(.on, "Нет подключения к интернету")
            return
        }
        if ifc != iface || primaryRouter() != scoped?.router {
            log("engine: network changed to \(ifc) via \(primaryRouter() ?? "-")")
            iface = ifc
            restartTun()
            restartCiadpi()
        }
        if ciadpi?.isRunning != true { log("engine: ciadpi died"); restartCiadpi() }
        if tun?.isRunning != true { log("engine: tun2socks died"); restartTun() }
        if tick % 6 == 0 {
            if !SystemDNS.isApplied { SystemDNS.apply() }
            updateWarning()
        }
        if tick % 3 == 0 { checkConnectivity() }
        if tick % 30 == 0 { checkHealth() }
        if tick % 360 == 1, Lists.isStale, Lists.update() { restartCiadpi() }
    }

    /// If the internet works directly but not through the TUN device,
    /// first restart tun2socks, then give up and restore the normal network.
    private func checkConnectivity() {
        if Prober.internetWorks(socksPort: nil) {
            netFailures = 0
            if statusBox.get().message != "Работает" { setStatus(.on, "Работает") }
            return
        }
        netFailures += 1
        guard netFailures >= 3 else { return }
        if Prober.internetWorks(socksPort: Engine.mainPort) {
            if netFailures == 3 {
                log("engine: TUN path broken, restarting tun2socks")
                restartTun()
                return
            }
            log("engine: TUN path still broken, falling back to the normal network")
            tearDown()
            fail("Обход временно выключен из-за ошибки сети. Повторю через 5 минут.", retry: 300)
        } else {
            setStatus(.on, "Нет подключения к интернету")
        }
    }

    private func checkHealth() {
        let passed = Prober.probe(socksPort: Engine.mainPort)
        if passed.count == Prober.targets.count {
            healthFailures = 0
            return
        }
        healthFailures += 1
        log("health: \(passed.count)/\(Prober.targets.count) passed, failure \(healthFailures)")
        if healthFailures >= 2 {
            healthFailures = 0
            repickLive()
        }
    }

    /// Another VPN with its own catch-all routes will fight with ours.
    private func updateWarning() {
        let routes = run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output
        let other = routes.split(separator: "\n").contains { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, let ifc = cols.last, ifc.hasPrefix("utun"), ifc != Engine.tunName else { return false }
            return ["default", "0/1", "128.0/1"].contains(String(cols[0]))
        }
        let text = other ? "Включён другой VPN. Zapret может работать неправильно." : nil
        statusBox.update { $0.warning = text }
    }

    // MARK: - Status and report

    private func setStatus(_ state: EngineState, _ message: String) {
        let old = statusBox.get()
        if old.state != state || old.message != message {
            log("status: \(state.rawValue) — \(message)")
        }
        statusBox.update { $0.state = state; $0.message = message }
    }

    private func saveSettings() {
        writeJSON(settings, settingsPath)
    }

    func report() -> String {
        let s = status
        var parts = [
            "Zapret report \(Date())",
            "state: \(s.state.rawValue) — \(s.message)",
            "enabled: \(s.enabled), strategy: \(s.strategy ?? "-"), warning: \(s.warning ?? "-")",
            "primary interface: \(primaryInterface() ?? "-")",
            "dns: \(currentDNSServers())",
            "== ifconfig \(Engine.tunName)", run("/sbin/ifconfig", [Engine.tunName]).output,
            "== routes", run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output,
            "== processes", run("/bin/ps", ["-axo", "pid,etime,command"]).output
                .split(separator: "\n").filter { $0.contains("Zapret") || $0.contains("PID") }.joined(separator: "\n"),
        ]
        if let log = try? String(contentsOfFile: ZapretPaths.log, encoding: .utf8) {
            parts.append("== helper log (tail)")
            parts.append(log.split(separator: "\n").suffix(300).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }
}

/// SIGKILL right away: children inherit our SIG_IGN for SIGTERM,
/// and neither ciadpi nor tun2socks has state worth a clean exit.
private func stop(_ p: Process?) {
    guard let p, p.isRunning else { return }
    kill(p.processIdentifier, SIGKILL)
    p.waitUntilExit()
}
