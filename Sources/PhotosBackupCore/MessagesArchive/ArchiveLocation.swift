import Foundation

/// Where an archive folder really is. A folder can sit in a sync service
/// without saying so in its path: on the developer's Mac ~/Documents is a
/// symlink into Google Drive, and iCloud's Desktop & Documents syncs
/// ~/Documents in place. The archive is private message text, so the app
/// says plainly when it is stored in a cloud as well.
public enum ArchiveLocation {
    /// 2026-10-15: Keep the default in the home folder, visible in Finder and
    /// outside Documents, which iCloud Desktop & Documents (or a symlink, as
    /// on the developer's Mac into Google Drive) would sync with every
    /// message in it. A DEBUG sandbox run keeps it inside the sandbox.
    public static func defaultFolder(home: URL, sandbox: URL?) -> URL {
        if let sandbox { return sandbox.appendingPathComponent("Archive", isDirectory: true) }
        return home.appendingPathComponent(MessagesArchiver.defaultFolderName, isDirectory: true)
    }

    /// 2026-10-15: Retain the earlier default when it contains an archive.
    public static func previousDefaultFolder(home: URL) -> URL {
        home.appendingPathComponent("Documents/\(MessagesArchiver.defaultFolderName)", isDirectory: true)
    }

    /// 2026-10-15: Pin the folder in settings so an archive at the previous
    /// default keeps being used instead of moving silently; nil when there is
    /// nothing to pin.
    public static func folderToKeep(setting: String?, home: URL, sandbox: URL?) -> URL? {
        guard setting == nil, sandbox == nil else { return nil }
        let old = previousDefaultFolder(home: home)
        return FileManager.default.fileExists(atPath: old.appendingPathComponent(ArchiveManifest.fileName).path) ? old : nil
    }

    public static func describe(_ trigger: RunTrigger) -> String {
        switch trigger {
        case .manual, .retry: "Archive Now"
        case .automation: RunTrigger.automation.title
        default: trigger.isAutomatic ? "daily archive" : trigger.title
        }
    }

    /// The path with symlinks resolved, for a folder that may not exist yet:
    /// the nearest existing ancestor is resolved and the rest appended.
    public static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(existing.path, &buffer).map { String(cString: $0) } ?? existing.path
        return rest.reduce(URL(fileURLWithPath: resolved)) { $0.appendingPathComponent($1) }.path
    }

    /// The sync service the folder is stored in ("iCloud Drive", "Google
    /// Drive", "Dropbox", "OneDrive", "Box"), or nil for a folder that stays
    /// on this Mac.
    public static func syncService(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = realPath(url)
        let library = realPath(home.appendingPathComponent("Library", isDirectory: true))
        if isInside(path, library + "/Mobile Documents") { return "iCloud Drive" }
        let cloudStorage = library + "/CloudStorage/"
        if isInside(path, String(cloudStorage.dropLast())) {
            let provider = path.dropFirst(cloudStorage.count).split(separator: "/").first.map(String.init) ?? ""
            return providerName(provider)
        }
        if isUbiquitous(URL(fileURLWithPath: path)) { return "iCloud Drive" }
        return nil
    }

    /// File Provider folders are named "<Provider>-<account>".
    static func providerName(_ folder: String) -> String {
        let prefix = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        switch prefix.lowercased() {
        case "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "dropbox": return "Dropbox"
        case "box": return "Box"
        case "": return "a cloud service"
        default: return prefix
        }
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// iCloud Desktop & Documents leaves the path alone and marks the items.
    private static func isUbiquitous(_ url: URL) -> Bool {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.pathComponents.count > 1 { current.deleteLastPathComponent() }
        return (try? current.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }
}
