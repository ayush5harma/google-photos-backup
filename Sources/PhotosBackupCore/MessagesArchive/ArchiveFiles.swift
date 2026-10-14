import CryptoKit
import Foundation

/// File rules for the archive: it is private message text, so folders the
/// archive creates are 0700 and every file it writes is 0600, written whole
/// (temporary file, then rename) so a reader never sees half a page.
enum ArchiveFiles {
    static let directoryMode = 0o700
    static let fileMode = 0o600

    /// Creates the folder (and parents) 0700. An existing folder keeps its
    /// mode: the user may have chosen one of their own.
    static func makeDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: directoryMode])
    }

    static let partialSuffix = ".partial"

    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)\(partialSuffix)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: fileMode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Writes only when the bytes differ, so an unchanged archive keeps its
    /// modification dates (and Time Machine has nothing new to copy).
    @discardableResult
    static func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
        if let existing = try? Data(contentsOf: url), existing == data { return false }
        try write(data, to: url)
        return true
    }

    /// Half-written files (".name.<uuid>.partial") a killed run left behind.
    /// Called only while holding the folder's run lock.
    static func removePartials(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(partialSuffix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func setPrivate(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: fileMode], ofItemAtPath: url.path)
    }

    static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    static func totalSize(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker { total += size(of: url) ?? 0 }
        return total
    }

    static func isChild(_ file: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(rootPath)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A conversation's folder name: a readable part taken from the chat
    /// identifier and a hash of the chat guid. Both derive from the guid, so
    /// renaming a group or a contact never moves the folder.
    static func slug(forChatGUID guid: String) -> String {
        let identifier = guid.split(separator: ";").last.map(String.init) ?? guid
        var readable = ""
        for scalar in identifier.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { readable.unicodeScalars.append(scalar) }
            else if !readable.isEmpty, readable.last != "-" { readable += "-" }
        }
        readable = String(readable.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(24))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (readable.isEmpty ? "chat" : readable) + "-" + hash(guid).prefix(10)
    }

    /// A file name safe on any file system and in a URL path, keeping the
    /// extension so browsers know what to do with it.
    static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { $0.isASCII && allowed.contains($0) ? $0 : "_" }))
        while cleaned.hasPrefix(".") || cleaned.hasPrefix(" ") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "attachment" }
        guard cleaned.count > 80 else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        return String(stem.prefix(70)) + (ext.isEmpty || ext.count > 8 ? "" : "." + ext)
    }
}

/// One archive run per folder at a time, across the app and any second copy
/// of it: an flock on a file in the temporary folder named after the archive
/// folder. Kept out of the archive itself, which may be in a synced folder
/// where locks do not hold. A file system without flock runs unlocked.
final class ArchiveRunLock {
    private var descriptor: Int32

    init(folder: URL, in temporaryDirectory: URL) throws {
        let key = ArchiveFiles.hash(folder.standardizedFileURL.resolvingSymlinksInPath().path).prefix(16)
        let path = temporaryDirectory.appendingPathComponent("photos-backup-archive-lock-\(key)").path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            descriptor = -1
            if code == EWOULDBLOCK { throw MessagesArchiveError.alreadyRunning }
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
