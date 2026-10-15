// Export the canonical icon artwork for the macOS bundle. The iconset sizes
// are generated from the full-size light PNG by scripts/build-app.sh.
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("make-icon: \(message)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count > 4 {
    fail("usage: make-icon.swift [output.png] [light|dark] [size]")
}
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "AppIcon.png")
let appearance = arguments.count > 2 ? arguments[2] : "light"
guard appearance == "light" || appearance == "dark" else {
    fail("appearance must be light or dark")
}
let size = arguments.count > 3 ? Int(arguments[3]) : 1024
guard let size, (1...1024).contains(size) else {
    fail("size must be an integer from 1 to 1024")
}
let source = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/app-icon\(appearance == "dark" ? "-dark" : "").png")
guard let data = try? Data(contentsOf: source),
    data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
    let image = NSBitmapImageRep(data: data),
    image.pixelsWide == 1024, image.pixelsHigh == 1024 else {
    fail("expected a decodable 1024 x 1024 PNG at \(source.path)")
}

let result: Data
if size == 1024 {
    result = data
} else {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fail("could not create the resized icon")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fail("could not encode the resized icon")
    }
    result = png
}
do {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    if output.standardizedFileURL != source.standardizedFileURL {
        try result.write(to: output)
    }
} catch {
    fail("could not write \(output.path): \(error.localizedDescription)")
}
