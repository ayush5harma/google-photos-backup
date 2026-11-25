// Turn the macOS icon artwork into full-bleed opaque iOS app icons.
//
// docs/app-icon.png and docs/app-icon-dark.png are macOS tiles: a rounded
// square at (92, 92)-(916, 916) on a transparent margin, with alpha 252-253
// even inside the tile (measured 2026-11-26). iOS draws its own mask and wants
// an opaque square: used as they are, the margin would show as a dark frame
// inside the mask. So the tile is cropped six pixels inside its edge (past its lighter one-pixel rim), each
// row's transparent corner pixels take that row's nearest tile colour (iOS's
// own corner radius cuts them away anyway), and the result is drawn opaque at
// 1024 px into the asset catalog.
//
// Usage: swift scripts/make-ios-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-ios-icon: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("iOS/PhotosBackup/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let tile = CGRect(x: 98, y: 98, width: 812, height: 812)
let size = 1024
let opaque: UInt8 = 252

func opaqueIcon(from source: URL) -> CGImage {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          image.width == 1024, image.height == 1024,
          let cropped = image.cropping(to: tile) else { fail("expected a 1024 x 1024 PNG at \(source.path)") }
    let width = cropped.width, height = cropped.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // The context owns its buffer: a Swift array passed as &pixels is only
    // guaranteed for the call, and a copy-on-write left the context drawing
    // the unmodified pixels (the first run's corners came out black).
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let buffer = context.data else { fail("no bitmap context") }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let original = Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
    // Undoes the premultiplication of a pixel of the nearly opaque tile, so
    // its colour comes through unchanged once alpha is dropped.
    func straight(_ at: Int, into target: Int) {
        let alpha = max(Double(original[at + 3]), 1) / 255
        for channel in 0..<3 { pixels[target + channel] = UInt8(min(255, (Double(original[at + channel]) / alpha).rounded())) }
        pixels[target + 3] = 255
    }
    for y in 0..<height {
        let row = y * width * 4
        let solid = (0..<width).filter { original[row + $0 * 4 + 3] >= opaque }
        guard let first = solid.first, let last = solid.last else { continue }
        for x in 0..<width {
            // Only the corners outside the tile take an edge colour; the
            // artwork's own semi-transparent pixels inside it keep theirs.
            let from = x < first ? first : (x > last ? last : x)
            straight(row + from * 4, into: row + x * 4)
        }
    }
    guard let filled = context.makeImage(),
          let flat = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fail("no output context") }
    flat.interpolationQuality = .high
    flat.draw(filled, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = flat.makeImage() else { fail("could not draw the icon") }
    return result
}

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    fail("could not create \(output.path): \(error.localizedDescription)")
}
for suffix in ["", "-dark"] {
    let image = opaqueIcon(from: root.appendingPathComponent("docs/app-icon\(suffix).png"))
    let target = output.appendingPathComponent("AppIcon\(suffix).png")
    guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(target.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(target.path)") }
}
