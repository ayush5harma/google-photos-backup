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

    /// Reclaim batches are allowed to grow past the regular limit so related
    /// camera components are never separated. The caller supplies only
    /// relationships it has established with confidence.
    public static func batchKeepingGroupsTogether(_ queued: [DeviceMediaItem], limit: Int,
                                                   groups: [String: Set<String>]) -> [DeviceMediaItem] {
        guard !queued.isEmpty else { return [] }
        let queuedIDs = Set(queued.map(\.id))
        var ids = Set(queued.prefix(max(1, limit)).map(\.id))
        var changed = true
        while changed {
            changed = false
            for id in Array(ids) {
                for related in groups[id, default: []] where queuedIDs.contains(related) {
                    if ids.insert(related).inserted { changed = true }
                }
            }
        }
        return queued.filter { ids.contains($0.id) }
    }
}
