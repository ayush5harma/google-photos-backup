// Draws the app icon: a white upload arrow over a photo glyph on a blue
// squircle. Run by build-app.sh as `swift make-icon.swift <out.png>`; drawn
// in code so the repository carries no binary artwork.
import AppKit

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icons leave a margin around the squircle (824 of 1024 points).
let inset = (size - 824) / 2
let rect = NSRect(x: inset, y: inset, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.27, green: 0.56, blue: 1.0, alpha: 1),
           ending: NSColor(red: 0.07, green: 0.31, blue: 0.86, alpha: 1))!.draw(in: squircle, angle: -90)

func symbol(_ name: String, points: CGFloat, weight: NSFont.Weight, in box: NSRect, alpha: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let fit = min(box.width / glyph.size.width, box.height / glyph.size.height)
    let drawn = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
    glyph.draw(in: NSRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
}

symbol("photo.on.rectangle.angled", points: 400, weight: .regular, in: rect.insetBy(dx: 150, dy: 190).offsetBy(dx: 0, dy: -40), alpha: 0.55)
symbol("arrow.up.circle.fill", points: 300, weight: .semibold, in: NSRect(x: rect.midX - 150, y: rect.midY + 20, width: 300, height: 300), alpha: 1)

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
