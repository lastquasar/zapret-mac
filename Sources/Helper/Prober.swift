import Foundation

/// Checks whether YouTube and Discord open through a given path.
/// A "pass" means the TLS handshake finished and enough data arrived:
/// DPI either kills the handshake or freezes the stream after ~16 KB.
enum Prober {
    struct Target {
        let name: String
        let url: String
        /// nil accepts any HTTP status: we only need the connection to work.
        let status: Int?
        let minBytes: Int
    }

    static let targets = [
        Target(name: "youtube", url: "https://www.youtube.com/", status: 200, minBytes: 64_000),
        Target(name: "googlevideo", url: "https://redirector.googlevideo.com/report_mapping", status: 200, minBytes: 1),
        Target(name: "ytimg", url: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg", status: 200, minBytes: 8_000),
        Target(name: "discord", url: "https://discord.com/", status: 200, minBytes: 32_000),
        Target(name: "discord-api", url: "https://discord.com/api/v10/gateway", status: 200, minBytes: 10),
        Target(name: "discord-gateway", url: "https://gateway.discord.gg/", status: nil, minBytes: 0),
        Target(name: "discord-cdn", url: "https://cdn.discordapp.com/", status: nil, minBytes: 0),
        Target(name: "discord-updates", url: "https://updates.discord.com/", status: nil, minBytes: 0),
    ]

    /// Runs all targets in parallel. socksPort nil means the normal system path.
    /// Returns the names of the targets that passed.
    static func probe(socksPort: Int?, timeout: TimeInterval = 10) -> Set<String> {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        if let socksPort {
            cfg.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy": "127.0.0.1",
                "SOCKSPort": socksPort,
            ]
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let passed = Locked(Set<String>())
        let group = DispatchGroup()
        for t in targets {
            group.enter()
            session.dataTask(with: URL(string: t.url)!) { data, resp, err in
                defer { group.leave() }
                guard err == nil, let http = resp as? HTTPURLResponse else { return }
                if let s = t.status, http.statusCode != s { return }
                if (data?.count ?? 0) < t.minBytes { return }
                passed.update { $0.insert(t.name) }
            }.resume()
        }
        _ = group.wait(timeout: .now() + timeout + 2)
        return passed.get()
    }

    /// Plain internet check by IP, so it does not depend on DNS.
    static func internetWorks(socksPort: Int?) -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        if let socksPort {
            cfg.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort]
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: URL(string: "http://1.1.1.1/cdn-cgi/trace")!) { data, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200 && (data?.count ?? 0) > 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8)
        return ok
    }
}
