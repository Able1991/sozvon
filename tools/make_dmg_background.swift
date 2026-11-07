// Draws the DMG window background: packaging/dmg-background.png and @2x.
// Run: swift tools/make_dmg_background.swift
//
// Finder draws the icon labels itself, white in dark mode and black in light mode, so the band under the
// icons has a relative luminance near 0.18, where both read at about 4.5:1.
import AppKit

let W: CGFloat = 660, H: CGFloat = 400
/// Icon centers, the same as in packaging/dmg-settings.py (points from the top left).
let app = CGPoint(x: 170, y: 210), apps = CGPoint(x: 490, y: 210)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Top-left origin, like Finder's coordinates.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    let full = CGRect(x: 0, y: 0, width: W, height: H)

    // Base: rose on the app's side to periwinkle on the Applications side, both near luminance 0.19.
    let base = CGGradient(colorsSpace: cs, colors: [rgb(0xB8577F), rgb(0x8A68B0), rgb(0x5E7FC4)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: W, y: 0), options: [])
    // Depth: a little lighter at the top, a little darker at the very bottom (away from the labels).
    let shade = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.10), rgb(0xffffff, 0), rgb(0xffffff, 0),
                                                     rgb(0x000000, 0.16)] as CFArray,
                           locations: [0, 0.35, 0.75, 1])!
    ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: H), options: [])

    // Soft glows behind the two icons: coral behind Sozvon, blue behind Applications.
    func glow(_ c: CGPoint, _ color: UInt32, _ alpha: CGFloat) {
        let g = CGGradient(colorsSpace: cs, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 120, options: [])
    }
    glow(app, 0xFF8A9A, 0.50)
    glow(apps, 0x9CC2FF, 0.45)

    // The arrow: the app's voice wave, blue from the left meeting coral from the right, as in the capsule,
    // ending in a chevron that points at Applications.
    let heights: [CGFloat] = [6, 10, 16, 12, 22, 30, 18, 26, 34, 20, 14, 24, 16, 10, 6]
    let x0: CGFloat = 262, step: CGFloat = 8, bar: CGFloat = 4
    for (i, h) in heights.enumerated() {
        let x = x0 + CGFloat(i) * step
        let t = CGFloat(i) / CGFloat(heights.count - 1)
        // Fade in from the app, full at the chevron.
        let alpha = 0.35 + 0.6 * t
        let r = CGRect(x: x, y: app.y - h / 2, width: bar, height: h)
        ctx.setFillColor(rgb(0xffffff, alpha))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
        ctx.fillPath()
    }
    let tip = CGPoint(x: x0 + CGFloat(heights.count) * step + 14, y: app.y)
    ctx.setStrokeColor(rgb(0xffffff, 0.95))
    ctx.setLineWidth(4); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: tip.x - 13, y: tip.y - 14))
    ctx.addLine(to: tip)
    ctx.addLine(to: CGPoint(x: tip.x - 13, y: tip.y + 14))
    ctx.strokePath()

    // Caption above the icons: the bottom may be covered by Finder's path and status bars.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, y: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: p, .shadow: shadow,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(in: CGRect(x: 0, y: y, width: W, height: size * 1.5))
    }
    text("Drag Sozvon to Applications", 18, .semibold, 0.96, y: 56)
    NSGraphicsContext.restoreGraphicsState()
    _ = full

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: W, height: H)  // 72 dpi at 1x, 144 at 2x: Finder picks by the size
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "packaging", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try! render(scale: 1).write(to: dir.appendingPathComponent("dmg-background.png"))
try! render(scale: 2).write(to: dir.appendingPathComponent("dmg-background@2x.png"))
print("packaging/dmg-background.png, @2x")
