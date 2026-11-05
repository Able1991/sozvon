// Рисует иконку приложения в стиле macOS и собирает Sources/Sozvon/Resources/AppIcon.icns.
// Запуск: swift tools/make_icon.swift
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // Сетка Apple: сквиркл 824×824 по центру холста 1024, тень снизу.
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    let grad = NSGradient(colors: [
        NSColor(red: 0.98, green: 0.36, blue: 0.42, alpha: 1),  // сверху: тёплый коралл
        NSColor(red: 0.86, green: 0.13, blue: 0.36, alpha: 1),
        NSColor(red: 0.55, green: 0.10, blue: 0.40, alpha: 1),  // снизу: глубокая малина
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    grad.draw(in: rect, angle: -90)
    // Мягкий блик сверху, как у системных иконок.
    let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    gloss.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    ctx.restoreGState()

    // Белый глиф waveform из SF Symbols с лёгкой тенью.
    let cfg = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let g = glyph.size
        let r = CGRect(x: (size - g.width) / 2, y: (size - g.height) / 2 - 6 * s, width: g.width, height: g.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
        glyph.draw(in: r)
        ctx.restoreGState()
    }
    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(render(CGFloat(px)), px).write(to: set.appendingPathComponent(name))
    }
}
try! png(render(1024), 1024).write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Sources/Sozvon/Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Sources/Sozvon/Resources/AppIcon.icns готов" : "iconutil упал")
