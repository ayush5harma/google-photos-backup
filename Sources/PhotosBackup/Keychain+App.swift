import PhotosBackupCore

extension Keychain {
    /// The app's own service; a sandboxed debug build gets one of its own.
    static let app = Keychain(service: AppEnvironment.keychainService)
}
