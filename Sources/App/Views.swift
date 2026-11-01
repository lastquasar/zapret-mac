import SwiftUI

let appName = "zapret-mac"

/// What the user sees, reduced to three looks: off, busy, on.
enum Look {
    case off, busy, on, problem

    @MainActor init(_ model: AppModel) {
        switch model.state {
        case .on: self = .on
        case .starting, .picking: self = .busy
        case .waiting, .error: self = .problem
        case .off: self = model.enabled ? .busy : .off
        }
    }

    var title: String {
        switch self {
        case .off: "Выключено"
        case .busy: "Включаю…"
        case .on: "Работает"
        case .problem: "Есть проблема"
        }
    }

    var colors: [Color] {
        switch self {
        case .off: [Color(white: 0.55), Color(white: 0.42)]
        case .busy: [.orange, Color(red: 0.85, green: 0.45, blue: 0.1)]
        case .on: [Color(red: 0.2, green: 0.8, blue: 0.45), Color(red: 0.1, green: 0.6, blue: 0.35)]
        case .problem: [Color(red: 0.95, green: 0.35, blue: 0.3), Color(red: 0.75, green: 0.2, blue: 0.2)]
        }
    }

    var menuIcon: String {
        switch self {
        case .off: "shield.slash"
        case .busy: "shield"
        case .on: "shield.lefthalf.filled"
        case .problem: "exclamationmark.shield"
        }
    }
}

struct PowerButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 132

    var body: some View {
        let look = Look(model)
        Button(action: model.toggle) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: look.colors, startPoint: .top, endPoint: .bottom))
                    .shadow(color: look.colors[0].opacity(0.45), radius: look == .off ? 4 : 14, y: 4)
                if look == .busy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.installing)
        .animation(.easeInOut(duration: 0.25), value: look)
        .help(model.enabled ? "Выключить" : "Включить")
    }
}

struct StatusText: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let look = Look(model)
        VStack(spacing: 4) {
            Text(look.title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detail: String {
        if model.installing { return "Введите пароль от Mac. Это нужно один раз." }
        if model.needsUpdate { return "\(appName) обновился. Нажмите кнопку и введите пароль от Mac." }
        if !model.enabled { return "Нажмите кнопку, чтобы открыть YouTube и Discord." }
        let msg = model.status?.message ?? ""
        if Look(model) == .on && msg == "Работает" { return "YouTube и Discord открываются." }
        return msg
    }
}

struct Notice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The menu bar popover: one button, one status line, a gear for rare things.
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(appName).font(.headline)
                Spacer()
                Menu {
                    Button("Подобрать настройки заново", action: model.repick)
                        .disabled(!model.enabled)
                    Button("Обновить списки сайтов", action: model.updateLists)
                    Toggle("Запускать при входе в систему", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }))
                    Divider()
                    Button("Сохранить отчёт на Рабочий стол", action: model.saveReport)
                    Button("Удалить \(appName)…", action: model.uninstall)
                    Divider()
                    Button("Выключить и выйти", action: model.quit)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            PowerButton(model: model)
                .padding(.top, 4)
            StatusText(model: model)
            if let text = model.localError ?? (model.status?.warning != nil ? "Включён другой VPN. \(appName) может работать неправильно." : nil) {
                Notice(text: text)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

/// Shown once, on first launch, so the user does not have to find the menu bar icon.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    private var inApplications: Bool {
        #if PREVIEW
        return true
        #else
        return Bundle.main.bundlePath.hasPrefix("/Applications/")
        #endif
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(appName)
                .font(.largeTitle.weight(.bold))
            Text("Открывает YouTube и Discord.\nПросто нажмите кнопку.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if inApplications {
                PowerButton(model: model, size: 150)
                    .padding(.vertical, 8)
                StatusText(model: model)
                if let text = model.localError { Notice(text: text) }
                if Look(model) == .on {
                    Text("Готово! \(appName) теперь живёт в строке меню вверху экрана — значок щита. Это окно можно закрыть.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Закрыть", action: close)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            } else {
                Notice(text: "Сначала перетащите \(appName) в папку «Программы», затем откройте его оттуда.")
                Button("Закрыть", action: close).controlSize(.large)
            }
        }
        .padding(32)
        .frame(width: 420)
    }
}
