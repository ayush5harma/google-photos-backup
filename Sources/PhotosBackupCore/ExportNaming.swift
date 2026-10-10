import Foundation

public enum ExportNaming {
    /// The name Google Photos should show for an exported asset.
    ///
    /// An edited photo's current rendition is a resource called
    /// "FullSizeRender.jpeg" (or .heic, .mov); the name people know is the
    /// original's, so keep the original's stem and take the rendition's
    /// extension, the way Photos' own "Export" names it.
    public static func uploadFilename(original: String?, rendition: String) -> String {
        let renditionName = sanitized(rendition)
        guard let original, !original.isEmpty else { return renditionName }
        let originalName = sanitized(original)
        let stem = (originalName as NSString).deletingPathExtension
        let ext = (renditionName as NSString).pathExtension
        guard !stem.isEmpty else { return renditionName }
        return ext.isEmpty ? originalName : "\(stem).\(ext)"
    }

    /// A single path component: no separators, no leading dot, not empty.
    public static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.drop(while: { $0 == "." }))
        return trimmed.isEmpty ? "asset" : trimmed
    }
}
