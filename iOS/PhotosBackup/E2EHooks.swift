import Foundation
import PhotosBackupCore
#if DEBUG
import Photos
#endif

extension AppEnvironment {
    /// Google, except in a debug build given PHOTOS_BACKUP_GOOGLE_ENDPOINT
    /// (scripts/ios-e2e.sh points it at Tests/E2E/fake_google_photos.py).
    static let googleEndpoints: GooglePhotosEndpoints = {
        #if DEBUG
        if let base = E2EHooks.value("PHOTOS_BACKUP_GOOGLE_ENDPOINT").flatMap(URL.init(string:)) { return .local(base) }
        #endif
        return .google
    }()
}

#if DEBUG
/// Debug builds only, and compiled out of Release (scripts/ios-e2e.sh and
/// the report check the Release binary for these names): the end-to-end run
/// against the fake Google.
///
/// - PHOTOS_BACKUP_E2E_ACCOUNT=<email> signs in an account with a synthetic
///   credential built by GoogleSignIn.credential (never a real token; the
///   fake accepts any) and skips the welcome guide.
/// - PHOTOS_BACKUP_E2E_ALBUM=<name> makes that album from every photo in the
///   simulator's library if it is missing, and selects it.
/// - PHOTOS_BACKUP_E2E_RUN=1 starts a backup once the above are done.
@MainActor
enum E2EHooks {
    nonisolated static func value(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// True when a hook took over the launch (no welcome guide, its own run).
    static func apply(to model: AppModel) async -> Bool {
        let email = value("PHOTOS_BACKUP_E2E_ACCOUNT")
        let album = value("PHOTOS_BACKUP_E2E_ALBUM")
        let run = value("PHOTOS_BACKUP_E2E_RUN") == "1"
        guard email != nil || album != nil || run else { return false }
        if let email {
            let account = GoogleSignIn.Account(email: email, masterToken: "aas_et/e2e-synthetic-not-a-token")
            model.signInForTesting(credential: GoogleSignIn.credential(for: account, androidID: GoogleSignIn.newAndroidID()), email: email)
            model.settings.onboardingCompleted = true
            model.showingOnboarding = false
        }
        // The script grants Photos access with `simctl privacy`; on a freshly
        // booted iOS 26.2 simulator on CI that grant did not take, and the
        // album step then sat behind the system's access prompt until the
        // run timed out (2026-11-26). Saying what access the app sees, and
        // not waiting on a prompt, lets the script grant again and relaunch.
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        model.log(.app, "E2E: Photos access \(Self.name(of: access))", problem: access != .authorized)
        guard access == .authorized else { return true }
        if let album {
            do {
                let id = try await ensureAlbum(named: album)
                await model.reloadAlbums()
                model.selectForTesting(albumID: id)
            } catch {
                model.log(.app, "E2E: could not make the album (\(error.localizedDescription))", problem: true)
            }
        }
        if run { model.backUpNow(to: .chosen, trigger: .automation) }
        return true
    }

    /// PHOTOS_BACKUP_E2E_BACKGROUND_TASK=1: hands BackgroundCoordinator's
    /// handler a stand-in task from App.init, before any scene exists, as a
    /// cold launch for a BGProcessingTask would (the simulator cannot submit a
    /// real one). The task writes its completion to the timeline.
    static func simulateBackgroundLaunchIfAsked() {
        guard value("PHOTOS_BACKUP_E2E_BACKGROUND_TASK") == "1" else { return }
        BackgroundCoordinator.shared.handle(StandInTask())
    }

    private final class StandInTask: BackgroundProcessingTask {
        var expirationHandler: (() -> Void)?

        func setTaskCompleted(success: Bool) {
            MainActor.assumeIsolated {
                BackgroundCoordinator.shared.logForTesting("E2E: background task completed (success: \(success))")
            }
        }
    }

    private static func name(of status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown"
        }
    }

    /// The album's local identifier, made from every photo and video in the
    /// library when no album of that name exists.
    private static func ensureAlbum(named name: String) async throws -> String {
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: String?
        existing.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == name {
                found = collection.localIdentifier
                stop.pointee = true
            }
        }
        if let found { return found }
        // Fetched before the change block: PhotoKit answers a fetch inside one
        // with an empty, unauthorized result ("can trigger deadlock").
        let assets = PHAsset.fetchAssets(with: PhotoLibrary.listing)
        var created: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            request.addAssets(assets)
            created = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let created else { throw CocoaError(.featureUnsupported) }
        return created
    }
}

extension AppModel {
    /// The E2E hook's sign-in: the same path as a real one after the
    /// exchange (Keychain item, AccountLibrary adoption), with no network.
    func signInForTesting(credential: String, email: String) {
        connectForTesting(credential: credential, email: email)
    }

    func selectForTesting(albumID: String) {
        guard !state.selectedAlbumIDs.contains(albumID) else { return }
        state.selectedAlbumIDs.insert(albumID)
        saveState()
    }
}
#endif
