import Foundation

/// The folder the Messages scanner and archive treat as `~`.
public enum UserHome {
    /// On a Mac, the person's home folder, as before. iOS has no
    /// `homeDirectoryForCurrentUser`; there it is the app's own container,
    /// where no Messages database exists, so those features find nothing.
    public static var directory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
