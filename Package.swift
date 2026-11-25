// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotosBackup",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "PhotosBackup", targets: ["PhotosBackup"]),
        // The iOS app (iOS/PhotosBackup.xcodeproj) links the core as a
        // library; the Mac app stays a plain executable.
        .library(name: "PhotosBackupCore", targets: ["PhotosBackupCore"]),
    ],
    targets: [
        // Everything that can be decided without PhotoKit or a process:
        // the bridge protocol, the persisted state and the backup planner.
        .target(name: "PhotosBackupCore"),
        .executableTarget(
            name: "PhotosBackup",
            dependencies: ["PhotosBackupCore"],
            // PhotoKit and Process callbacks predate Sendable; the app target
            // keeps Swift 5 checking and confines its state to the main actor.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "PhotosBackupCoreTests", dependencies: ["PhotosBackupCore"]),
        // Views measured the way AppKit sizes a window, against the app
        // module itself.
        .testTarget(
            name: "PhotosBackupViewTests",
            dependencies: ["PhotosBackup"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
