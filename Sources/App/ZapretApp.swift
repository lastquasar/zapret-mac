import AppKit
import SwiftUI

@main
struct ZapretApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: Look(model).menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?
    private let seenKey = "welcomeShown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: seenKey) {
            showWelcome()
        }
    }

    /// Opening the app again from Finder or Launchpad brings the window back,
    /// because a menu bar app is otherwise easy to lose.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWelcome()
        return false
    }

    @MainActor
    private func showWelcome() {
        if let welcome {
            welcome.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Zapret"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(model: AppModel.shared) { [weak window] in
            window?.close()
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcome = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: self.seenKey)
                self.welcome = nil
            }
        }
    }
}
