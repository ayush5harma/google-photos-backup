import Foundation

/// A media file exposed by a directly connected camera or phone.  This is
/// intentionally a flat list: Image Capture does not expose the Photos
/// library's logical albums, and inventing them would be misleading.
public struct DeviceMediaItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let byteCount: Int64
    public let createdAt: Date?
    public let isMovie: Bool

    public init(id: String, filename: String, byteCount: Int64, createdAt: Date?, isMovie: Bool) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.isMovie = isMovie
    }
}

/// Pure selection rules shared by the connected-device UI and its tests.
public enum DeviceImportPlan {
    /// Image Capture's `locked` flag specifically prohibits deletion. Reading
    /// an Apple device becomes available when its session is open and it is
    /// no longer access-restricted (trusted/unlocked at connection time).
    public static func canReadOriginals(hasOpenSession: Bool, accessRestricted: Bool) -> Bool {
        hasOpenSession && !accessRestricted
    }

    /// File fingerprints and PTP handles are only unique within one camera.
    /// The device UUID keeps two cameras with identical names/handles from
    /// sharing backup state, while remaining stable across reconnects.
    public static func stableIdentifier(deviceID: String, fingerprint: String?, objectHandle: UInt32, filename: String) -> String {
        let local = fingerprint?.isEmpty == false ? fingerprint! : "\(objectHandle):\(filename)"
        return "device:\(deviceID):\(local)"
    }

    /// Keep the first occurrence of every stable camera identity. The order
    /// from Image Capture is preserved, so a reconnect cannot reshuffle a
    /// person's selection.
    public static func unique(_ items: [DeviceMediaItem]) -> [DeviceMediaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    public static func selected(_ items: [DeviceMediaItem], ids: Set<String>) -> [DeviceMediaItem] {
        unique(items).filter { ids.contains($0.id) }
    }

    /// Keep small related groups together, but never expand beyond a bounded
    /// batch. Oversized groups are copied normally; the deletion completeness
    /// guard retains their sources instead of staging an unbounded burst.
    public static func batchKeepingGroupsTogether(_ queued: [DeviceMediaItem], limit: Int,
                                                   groups: [String: Set<String>]) -> [DeviceMediaItem] {
        guard !queued.isEmpty else { return [] }
        let cap = max(2, limit)
        let queuedIDs = Set(queued.map(\.id))
        var ids = Set(queued.prefix(max(1, limit)).map(\.id))
        var changed = true
        while changed {
            changed = false
            for id in Array(ids) {
                for related in groups[id, default: []] where queuedIDs.contains(related) {
                    if ids.insert(related).inserted { changed = true }
                    if ids.count > cap { return Array(queued.prefix(max(1, limit))) }
                }
            }
        }
        return queued.filter { ids.contains($0.id) }
    }
}

/// Selection is independent of ImageCaptureCore so the no-switch rule can be
/// tested without hardware. Losing the selected device leaves no selection;
/// another attached phone/tablet is never selected as a fallback.
public struct ConnectedDeviceSelection: Equatable, Sendable {
    public private(set) var selectedID: String?
    public private(set) var lockedID: String?

    public init() {}

    @discardableResult
    public mutating func select(_ id: String) -> Bool {
        guard lockedID == nil else { return false }
        selectedID = id
        return true
    }

    @discardableResult
    public mutating func beginImport(available: Set<String>) -> Bool {
        guard let selectedID, available.contains(selectedID) else { return false }
        lockedID = selectedID
        return true
    }

    public mutating func endImport() { lockedID = nil }

    public mutating func disconnected(_ id: String) {
        if selectedID == id { selectedID = nil }
    }
}
