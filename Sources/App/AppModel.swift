import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var status: HelperStatus?
    @Published private(set) var installing = false
    @Published var localError: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?
    private var pending: Bool?

    /// An older helper is installed: the button must reinstall it first.
    var needsUpdate: Bool { status != nil && !helperUpToDate }
    var enabled: Bool { pending ?? (needsUpdate ? false : status?.enabled ?? false) }
    var state: EngineState {
        if installing { return .starting }
        if let pending { return pending ? .starting : .off }
        if needsUpdate { return .off }
        return status?.state ?? .off
    }
    var helperUpToDate: Bool { status?.version == zapretHelperVersion }

    #if PREVIEW
    init(preview: HelperStatus?, installing: Bool = false, error: String? = nil) {
        status = preview
        self.installing = installing
        localError = error
    }
    #endif

    init() {
        // The app was renamed and moved; point the login item at this copy.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refresh() }
        }
    }

    func refresh() {
        Task.detached {
            let s = try? ipcCall(HelperRequest(cmd: "status"))
            await MainActor.run {
                self.status = s
                if let s, let p = self.pending, s.enabled == p { self.pending = nil }
            }
        }
    }

    // MARK: - Actions

    func toggle() {
        enabled ? turnOff() : turnOn()
    }

    func turnOn() {
        localError = nil
        Task {
            if !helperUpToDate {
                installing = true
                let ok = await Installer.install()
                installing = false
                guard ok else {
                    localError = "Не получилось установить. Нажмите «Включить» ещё раз и введите пароль от Mac."
                    return
                }
            }
            pending = true
            await send("enable")
            if !launchAtLogin { setLaunchAtLogin(true) }
        }
    }

    func turnOff() {
        pending = false
        Task { await send("disable") }
    }

    func repick() { Task { await send("repick") } }
    func updateLists() { Task { await send("update-lists") } }

    func saveReport() {
        Task {
            let text = await Task.detached { (try? ipcCall(HelperRequest(cmd: "report"), timeout: 20))?.report }.value
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HH-mm"
            let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(appName)-отчёт-\(f.string(from: Date())).txt")
            let body = text ?? "Помощник \(appName) не отвечает. Вероятно, он не установлен.\n"
            try? body.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Удалить \(appName)?"
        alert.informativeText = "Обход выключится, настройки сети вернутся к обычным. macOS попросит пароль."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await send("disable")
            guard await Installer.uninstall() else { return }
            setLaunchAtLogin(false)
            let done = NSAlert()
            done.messageText = "\(appName) удалён"
            done.informativeText = "Теперь перетащите приложение \(appName) из папки «Программы» в Корзину."
            done.runModal()
            NSApp.terminate(nil)
        }
    }

    func quit() {
        Task {
            if status != nil { await send("disable") }
            NSApp.terminate(nil)
        }
    }

    private func send(_ cmd: String) async {
        let s = await Task.detached { try? ipcCall(HelperRequest(cmd: cmd)) }.value
        if let s { status = s }
    }
}
