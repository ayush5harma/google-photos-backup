// 2026-10-15: Photo cards and an infinity seal identify the unlimited-photo
// workflow without borrowing Google's logo. Explicit bitmap sizing keeps the
// release icon identical on Retina and headless CI renderers.
import AppKit

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// macOS icons leave a margin around the tile (824 of 1024 points).
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// A soft drop shadow under the tile, as the system's own icons have.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(red: 0.10, green: 0.38, blue: 0.95, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [NSColor(red: 0.16, green: 0.72, blue: 0.88, alpha: 1),
                    NSColor(red: 0.12, green: 0.40, blue: 0.82, alpha: 1),
                    NSColor(red: 0.10, green: 0.19, blue: 0.53, alpha: 1)],
           atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// Light from above: a broad glow across the top of the tile.
NSGradient(starting: NSColor.white.withAlphaComponent(0.16), ending: NSColor.white.withAlphaComponent(0))!
    .draw(fromCenter: NSPoint(x: tile.midX, y: tile.maxY + 80), radius: 0, toCenter: NSPoint(x: tile.midX, y: tile.maxY + 80), radius: 620, options: [])
NSGraphicsContext.restoreGraphicsState()
let inner = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
inner.lineWidth = 6
NSColor.white.withAlphaComponent(0.22).setStroke()
inner.stroke()

/// A photo card: white mat, a picture of a sun over two hills.
func card(center: NSPoint, width: Double, height: Double, angle: Double, alpha: Double) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: angle)
    transform.concat()
    let frame = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
    let mat = NSBezierPath(roundedRect: frame, xRadius: 46, yRadius: 46)
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor(red: 0.02, green: 0.12, blue: 0.40, alpha: 0.35 * alpha)
    cardShadow.shadowBlurRadius = 30
    cardShadow.shadowOffset = NSSize(width: 0, height: -14)
    NSGraphicsContext.saveGraphicsState()
    cardShadow.set()
    NSColor.white.withAlphaComponent(alpha).setFill()
    mat.fill()
    NSGraphicsContext.restoreGraphicsState()

    let picture = frame.insetBy(dx: 30, dy: 30)
    let picturePath = NSBezierPath(roundedRect: picture, xRadius: 24, yRadius: 24)
    NSGraphicsContext.saveGraphicsState()
    picturePath.addClip()
    NSGradient(starting: NSColor(red: 0.62, green: 0.84, blue: 1.0, alpha: alpha),
               ending: NSColor(red: 0.85, green: 0.94, blue: 1.0, alpha: alpha))!.draw(in: picture, angle: -90)
    NSColor(red: 1.0, green: 0.78, blue: 0.25, alpha: alpha).setFill()
    NSBezierPath(ovalIn: NSRect(x: picture.maxX - 150, y: picture.maxY - 150, width: 92, height: 92)).fill()
    let far = NSBezierPath()
    far.move(to: NSPoint(x: picture.minX, y: picture.minY + 90))
    far.curve(to: NSPoint(x: picture.maxX, y: picture.minY + 120),
              controlPoint1: NSPoint(x: picture.minX + picture.width * 0.35, y: picture.minY + 260),
              controlPoint2: NSPoint(x: picture.minX + picture.width * 0.6, y: picture.minY + 60))
    far.line(to: NSPoint(x: picture.maxX, y: picture.minY))
    far.line(to: NSPoint(x: picture.minX, y: picture.minY))
    far.close()
    NSColor(red: 0.30, green: 0.72, blue: 0.48, alpha: alpha).setFill()
    far.fill()
    let near = NSBezierPath()
    near.move(to: NSPoint(x: picture.minX, y: picture.minY + 40))
    near.curve(to: NSPoint(x: picture.maxX, y: picture.minY + 170),
               controlPoint1: NSPoint(x: picture.minX + picture.width * 0.45, y: picture.minY + 20),
               controlPoint2: NSPoint(x: picture.minX + picture.width * 0.75, y: picture.minY + 200))
    near.line(to: NSPoint(x: picture.maxX, y: picture.minY))
    near.line(to: NSPoint(x: picture.minX, y: picture.minY))
    near.close()
    NSColor(red: 0.16, green: 0.58, blue: 0.38, alpha: alpha).setFill()
    near.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

card(center: NSPoint(x: 492, y: 552), width: 500, height: 400, angle: 11, alpha: 0.72)
card(center: NSPoint(x: 512, y: 500), width: 520, height: 420, angle: -4, alpha: 1)

// 2026-10-15: A broad infinity mark remains legible at Dock and 32-pixel sizes.
let badge = NSRect(x: 618, y: 196, width: 236, height: 236)
NSGraphicsContext.saveGraphicsState()
let badgeShadow = NSShadow()
badgeShadow.shadowColor = NSColor(red: 0.02, green: 0.12, blue: 0.40, alpha: 0.4)
badgeShadow.shadowBlurRadius = 26
badgeShadow.shadowOffset = NSSize(width: 0, height: -10)
badgeShadow.set()
NSColor.white.setFill()
NSBezierPath(ovalIn: badge).fill()
NSGraphicsContext.restoreGraphicsState()
let config = NSImage.SymbolConfiguration(pointSize: 140, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0.10, green: 0.42, blue: 0.97, alpha: 1)]))
if let arrow = NSImage(systemSymbolName: "infinity", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let fit = min(160 / arrow.size.width, 105 / arrow.size.height)
    let drawn = NSSize(width: arrow.size.width * fit, height: arrow.size.height * fit)
    arrow.draw(in: NSRect(x: badge.midX - drawn.width / 2, y: badge.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
}

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
