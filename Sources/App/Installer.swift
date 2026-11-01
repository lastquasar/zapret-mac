import Foundation

/// Installs or removes the root helper with one administrator prompt.
enum Installer {
    static var payload: String { Bundle.main.resourcePath! + "/payload" }

    static func install() async -> Bool {
        let ok = await runAsAdmin(script: payload + "/install.sh", args: [payload],
                                  prompt: "\(appName) нужно один раз получить разрешение, чтобы настроить сеть.")
        guard ok else { return false }
        // Wait for launchd to start the new helper.
        for _ in 0..<50 {
            if let s = try? ipcCall(HelperRequest(cmd: "status")), s.version == zapretHelperVersion { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    static func uninstall() async -> Bool {
        await runAsAdmin(script: payload + "/uninstall.sh", args: [],
                         prompt: "\(appName) удалит свои файлы и вернёт настройки сети.")
    }

    private static func runAsAdmin(script: String, args: [String], prompt: String) async -> Bool {
        let command = (["/bin/sh", script] + args).map(shellQuote).joined(separator: " ")
        let source = "do shell script \(appleString(command)) with administrator privileges with prompt \(appleString(prompt))"
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
