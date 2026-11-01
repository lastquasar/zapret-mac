import Foundation

/// Domain lists from Flowseal's repo, merged into one hosts file for ciadpi.
enum Lists {
    static let names = ["list-general.txt", "list-google.txt"]
    static let updatedDir = ZapretPaths.state + "/lists"
    static let hostsFile = ZapretPaths.state + "/hosts.txt"
    private static let stampPath = ZapretPaths.state + "/lists-updated"
    private static let rawBase = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/"

    /// Always covered, even if the upstream lists change shape.
    private static let extras = [
        "discord.com", "discord.gg", "discord.co", "discord.dev", "discord.new", "discord.gift",
        "discord.media", "discordapp.com", "discordapp.net", "discordcdn.com", "discordstatus.com",
        "discord-attachments-uploads-prd.storage.googleapis.com", "dis.gd",
        "youtube.com", "youtu.be", "yt.be", "ytimg.com", "googlevideo.com", "ggpht.com",
        "youtube-nocookie.com", "youtubei.googleapis.com", "youtube.googleapis.com",
        "yt3.googleusercontent.com", "jnn-pa.googleapis.com", "wide-youtube.l.google.com",
    ]

    /// Rebuilds hosts.txt. Returns true if its content changed.
    @discardableResult
    static func rebuild() -> Bool {
        var hosts = Set(extras)
        for name in names {
            let updated = updatedDir + "/" + name
            let path = FileManager.default.fileExists(atPath: updated) ? updated : ZapretPaths.defaultLists + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            hosts.formUnion(parse(text))
        }
        let content = hosts.sorted().joined(separator: "\n") + "\n"
        let old = try? String(contentsOfFile: hostsFile, encoding: .utf8)
        if old == content { return false }
        try? content.write(toFile: hostsFile, atomically: true, encoding: .utf8)
        log("lists: hosts.txt has \(hosts.count) domains")
        return true
    }

    /// Keeps only plain domain names; drops zapret's "^" exact-match prefix and comments.
    static func parse(_ text: String) -> [String] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("#") || line.isEmpty { return nil }
            if line.hasPrefix("^") { line.removeFirst() }
            guard line.contains("."), line.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return line
        }
    }

    static var isStale: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stampPath),
              let date = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(date) > 24 * 3600
    }

    /// Downloads fresh lists. Returns true if hosts.txt changed.
    static func update() -> Bool {
        try? FileManager.default.createDirectory(atPath: updatedDir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        var gotAny = false
        for name in names {
            let sem = DispatchSemaphore(value: 0)
            var body: String?
            session.dataTask(with: URL(string: rawBase + name)!) { data, resp, _ in
                if (resp as? HTTPURLResponse)?.statusCode == 200, let data {
                    body = String(data: data, encoding: .utf8)
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 20)
            // A list with almost nothing in it is more likely broken than real.
            if let body, parse(body).count >= 5 {
                try? body.write(toFile: updatedDir + "/" + name, atomically: true, encoding: .utf8)
                gotAny = true
            } else {
                log("lists: download of \(name) failed")
            }
        }
        if gotAny {
            FileManager.default.createFile(atPath: stampPath, contents: nil)
        }
        return rebuild()
    }
}
