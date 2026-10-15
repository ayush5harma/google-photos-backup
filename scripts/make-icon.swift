// Export the canonical icon artwork for the macOS bundle. The iconset sizes
// are generated from the full-size light PNG by scripts/build-app.sh.
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("make-icon: \(message)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count > 3 {
    fail("usage: make-icon.swift [output.png] [light|dark]")
}
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "AppIcon.png")
let appearance = arguments.count > 2 ? arguments[2] : "light"
guard appearance == "light" || appearance == "dark" else {
    fail("appearance must be light or dark")
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

do {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    if output.standardizedFileURL != source.standardizedFileURL {
        try data.write(to: output)
    }
} catch {
    fail("could not write \(output.path): \(error.localizedDescription)")
}
