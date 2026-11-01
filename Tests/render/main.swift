import SwiftUI
// Renders the UI in each state to PNG files, for a visual check.
let out = CommandLine.arguments[1]
func st(_ s: EngineState, _ m: String, _ en: Bool, warn: String? = nil) -> HelperStatus {
    HelperStatus(state: s, message: m, enabled: en, warning: warn, strategy: nil, version: zapretHelperVersion, report: nil)
}
@MainActor func save<V: View>(_ v: V, _ name: String) {
    let r = ImageRenderer(content: v.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
    r.scale = 2
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
MainActor.assumeIsolated {
    save(PanelView(model: AppModel(preview: st(.off, "Выключено", false))), "panel-off")
    save(PanelView(model: AppModel(preview: st(.picking, "Подбираю настройки… Это займёт до минуты.", true))), "panel-picking")
    save(PanelView(model: AppModel(preview: st(.on, "Работает", true, warn: "Включён другой VPN. Zapret может работать неправильно."))), "panel-on")
    save(PanelView(model: AppModel(preview: st(.error, "YouTube и Discord не открываются ни с одной настройкой. Повторю через 10 минут.", true))), "panel-error")
    save(WelcomeView(model: AppModel(preview: nil), close: {}), "welcome-off")
    save(WelcomeView(model: AppModel(preview: st(.on, "Работает", true)), close: {}), "welcome-on")
}
