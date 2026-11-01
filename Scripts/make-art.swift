// Draws the app icon set and the DMG instruction picture.
// Usage: swift make-art.swift <output dir> <app name> [icon picture]
// Without a picture the icon is a green shield.
import AppKit

let out = CommandLine.arguments[1]
let name = CommandLine.arguments[2]
let source = CommandLine.arguments.count > 3 ? NSImage(contentsOfFile: CommandLine.arguments[3]) : nil
try? FileManager.default.createDirectory(atPath: out + "/AppIcon.iconset", withIntermediateDirectories: true)

func png(_ size: NSSize, scale: CGFloat = 1, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func symbol(_ name: String, _ pointSize: CGFloat, _ color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

// MARK: icon

func drawIcon(_ r: NSRect) {
    let inset = r.width * 0.1
    let box = r.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    if let source {
        // The picture, cropped to a square (aspect fill), inside the standard icon shape.
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let src = source.size
        let side = min(src.width, src.height)
        let crop = NSRect(x: (src.width - side) / 2, y: (src.height - side) / 2, width: side, height: side)
        source.draw(in: box, from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return
    }
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.5, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.4, alpha: 1)])!
        .draw(in: path, angle: -90)
    let s = symbol("shield.lefthalf.filled", box.width * 0.45, .white)
    let sz = s.size
    s.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = png(NSSize(width: base, height: base), scale: CGFloat(scale), drawIcon)
        try! data.write(to: URL(fileURLWithPath: out + "/AppIcon.iconset/" + name))
    }
}

// MARK: instruction picture

let steps = [
    "Перетащите значок \(name) на папку «Программы» (справа).",
    "Откройте папку «Программы» и дважды щёлкните \(name). macOS скажет, что не может проверить приложение. Нажмите «Готово».",
    "Нажмите на яблоко в левом верхнем углу экрана → «Системные настройки» → «Конфиденциальность и безопасность».",
    "Прокрутите вниз. Рядом с надписью про \(name) нажмите «Всё равно открыть» и введите пароль от Mac.",
    "\(name) откроется. Нажмите большую кнопку. Готово!",
]

let W: CGFloat = 900, H: CGFloat = 960
let picture = png(NSSize(width: W, height: H), scale: 2) { r in
    NSColor.white.setFill()
    r.fill()
    let title = NSAttributedString(string: "Как открыть \(name) в первый раз", attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.black])
    title.draw(at: NSPoint(x: 60, y: H - 110))
    let sub = NSAttributedString(string: "Это нужно сделать только один раз.", attributes: [
        .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.darkGray])
    sub.draw(at: NSPoint(x: 60, y: H - 155))

    var y = H - 230
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 4
    for (i, text) in steps.enumerated() {
        let circle = NSRect(x: 60, y: y - 44, width: 56, height: 56)
        NSColor(calibratedRed: 0.1, green: 0.62, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let num = NSAttributedString(string: "\(i + 1)", attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white])
        num.draw(at: NSPoint(x: circle.midX - num.size().width / 2, y: circle.midY - num.size().height / 2))
        let body = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.black, .paragraphStyle: para])
        let rect = body.boundingRect(with: NSSize(width: W - 200, height: 400), options: [.usesLineFragmentOrigin])
        body.draw(with: NSRect(x: 140, y: y - rect.height + 6, width: W - 200, height: rect.height),
                  options: [.usesLineFragmentOrigin])
        y -= max(rect.height, 56) + 48
    }
}
try! picture.write(to: URL(fileURLWithPath: out + "/Как открыть.png"))
print("art written to \(out)")
