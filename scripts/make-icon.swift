// 2026-10-15: Translucent Photos-inspired petals and one infinity glyph keep
// the photo and unlimited-backup meanings legible without a separate badge.
import AppKit

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let dark = CommandLine.arguments.dropFirst(2).first == "dark"
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.36 : 0.18)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
(dark ? color(0.12, 0.13, 0.16) : color(0.96, 0.97, 0.99)).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: dark ? [color(0.25, 0.27, 0.31), color(0.10, 0.11, 0.14)]
    : [NSColor.white, color(0.88, 0.91, 0.96)])!.draw(in: tile, angle: -90)
NSGradient(starting: NSColor.white.withAlphaComponent(dark ? 0.09 : 0.7),
    ending: NSColor.white.withAlphaComponent(0))!.draw(
        fromCenter: NSPoint(x: 350, y: 920), radius: 0,
        toCenter: NSPoint(x: 350, y: 920), radius: 650, options: [])
NSGraphicsContext.restoreGraphicsState()
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
edge.lineWidth = 3
NSColor.white.withAlphaComponent(dark ? 0.23 : 0.9).setStroke()
edge.stroke()

// 2026-10-15: Eight overlapping lenses recall Photos; broad color areas survive
// reduction to 32 px while a restrained rim conveys glass at larger sizes.
let palette: [NSColor] = [color(1, 0.26, 0.28), color(1, 0.54, 0.12),
    color(1, 0.80, 0.10), color(0.43, 0.80, 0.18), color(0.08, 0.76, 0.66),
    color(0.12, 0.59, 0.98), color(0.39, 0.35, 0.95), color(0.85, 0.24, 0.73)]
for (index, tint) in palette.enumerated() {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 512, yBy: 512)
    transform.rotate(byDegrees: -Double(index) * 45)
    transform.concat()
    let rect = NSRect(x: -116, y: -32, width: 232, height: 322)
    let lens = NSBezierPath(roundedRect: rect, xRadius: 116, yRadius: 116)
    NSGraphicsContext.saveGraphicsState()
    lens.addClip()
    NSGradient(colors: [tint.blended(withFraction: dark ? 0.12 : 0.23, of: .white)!.withAlphaComponent(0.92),
        tint.withAlphaComponent(dark ? 0.84 : 0.78)])!.draw(in: rect, angle: -90)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.24), ending: NSColor.white.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: -60, y: 250), radius: 0,
            toCenter: NSPoint(x: -60, y: 250), radius: 205, options: [])
    NSGraphicsContext.restoreGraphicsState()
    lens.lineWidth = 2
    NSColor.white.withAlphaComponent(0.24).setStroke()
    lens.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

// 2026-10-15: A continuous, custom vector loop avoids font-dependent symbol
// metrics and gives both appearances precisely the same silhouette.
let loop = NSBezierPath()
loop.move(to: NSPoint(x: 512, y: 512))
loop.curve(to: NSPoint(x: 354, y: 598), controlPoint1: NSPoint(x: 443, y: 586), controlPoint2: NSPoint(x: 408, y: 616))
loop.curve(to: NSPoint(x: 354, y: 426), controlPoint1: NSPoint(x: 248, y: 568), controlPoint2: NSPoint(x: 248, y: 456))
loop.curve(to: NSPoint(x: 512, y: 512), controlPoint1: NSPoint(x: 408, y: 408), controlPoint2: NSPoint(x: 443, y: 438))
loop.curve(to: NSPoint(x: 670, y: 598), controlPoint1: NSPoint(x: 581, y: 586), controlPoint2: NSPoint(x: 616, y: 616))
loop.curve(to: NSPoint(x: 670, y: 426), controlPoint1: NSPoint(x: 776, y: 568), controlPoint2: NSPoint(x: 776, y: 456))
loop.curve(to: NSPoint(x: 512, y: 512), controlPoint1: NSPoint(x: 616, y: 408), controlPoint2: NSPoint(x: 581, y: 438))
loop.lineWidth = 49
loop.lineCapStyle = .round
loop.lineJoinStyle = .round
NSGraphicsContext.saveGraphicsState()
let loopShadow = NSShadow()
loopShadow.shadowColor = color(0.15, 0.12, 0.35, 0.24)
loopShadow.shadowBlurRadius = 10
loopShadow.shadowOffset = NSSize(width: 0, height: -4)
loopShadow.set()
NSColor.white.withAlphaComponent(0.96).setStroke()
loop.stroke()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
