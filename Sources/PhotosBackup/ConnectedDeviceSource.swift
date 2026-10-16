import Foundation
@preconcurrency import ImageCaptureCore
import Observation
import PhotosBackupCore

/// Imports originals from cameras exposed through Image Capture. Optional
/// deletion requires explicit confirmation and independent Google readback.
@MainActor
@Observable
final class ConnectedDeviceSource: NSObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let model: String
        var isConnected: Bool
    }
    enum Status: Equatable {
        case searching
        case unavailable(String)
        case locked(String)
        case ready(name: String, count: Int)
        case importing

        var message: String {
            switch self {
            case .searching: "Looking for a connected phone or camera…"
            case let .unavailable(reason), let .locked(reason): reason
            case let .ready(name, count): "\(name) · \(count.formatted()) photos and videos"
            case .importing: "Copying selected originals from the device…"
            }
        }
    }

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var cameras: [String: ICCameraDevice] = [:]
    private var deviceIDs: [ObjectIdentifier: String] = [:]
    private var files: [String: ICCameraFile] = [:]
    private var continuation: CheckedContinuation<URL, Error>?
    private var importingID: String?
    private var downloadFolder: URL?
    private var selection = ConnectedDeviceSelection()
    /// We may choose the first device while the browser is initially
    /// discovering hardware. Once that initial choice has happened, a later
    /// connection must never replace a disconnected selection implicitly.
    private var hasMadeInitialSelection = false

    private(set) var status: Status = .searching
    private(set) var items: [DeviceMediaItem] = []
    private(set) var devices: [Device] = []
    var selectedDeviceID: String? { selection.selectedID }
    var deviceSelectionLocked: Bool { selection.lockedID != nil }
    /// Image Capture must advertise deletion support before reclaim is offered.
    private(set) var supportsDeviceDeletion = false

    /// A reclaim decision is intentionally stricter than importing. Every
    /// related component Image Capture can identify must be selected together;
    /// an ambiguous relationship is retained rather than guessed at.
    func reclaimBlocker(for selected: Set<String>) -> String? {
        guard supportsDeviceDeletion else {
            return "This device does not allow deletion through Image Capture."
        }
        guard let camera, !camera.isLocked, !camera.isAccessRestrictedAppleDevice else {
            return "Unlock and trust the device before reclaim can be reviewed."
        }
        for id in selected {
            guard let file = files[id] else { return "A selected file is no longer available on the device." }
            let relationship = file.relatedUUID ?? file.groupUUID
            guard let relationship else { continue }
            let members = Set(files.compactMap { key, candidate in
                (candidate.relatedUUID == relationship || candidate.groupUUID == relationship) ? key : nil
            })
            guard members.count > 1 else {
                return "The paired components for a selected Live Photo cannot be established."
            }
            guard members.isSubset(of: selected) else {
                return "Select every paired component of each Live Photo before reclaim."
            }
        }
        return nil
    }

    /// Keep paired components together within the bounded batch. Oversized
    /// camera groups are copied in normal batches and retained at the source.
    func batchKeepingPairsTogether(_ queued: [DeviceMediaItem], limit: Int) -> [DeviceMediaItem] {
        var groups: [String: Set<String>] = [:]
        for (id, file) in files {
            guard let relationship = file.relatedUUID ?? file.groupUUID else { continue }
            let members = Set(files.compactMap { candidateID, candidate in
                (candidate.relatedUUID == relationship || candidate.groupUUID == relationship) ? candidateID : nil
            })
            if members.count > 1 { groups[id] = members }
        }
        return DeviceImportPlan.batchKeepingGroupsTogether(queued, limit: limit, groups: groups)
    }

    override init() {
        super.init()
        #if DEBUG
        if Snapshots.isRequested {
            items = [
                .init(id: "fixture:photo", filename: "Coast.jpg", byteCount: 4_200_000, createdAt: nil, isMovie: false),
                .init(id: "fixture:video", filename: "Morning.mov", byteCount: 18_600_000, createdAt: nil, isMovie: true)
            ]
            status = .ready(name: "Test iPhone", count: items.count)
            return
        }
        #endif
        browser.delegate = self
        browser.start()
    }

    deinit { browser.stop() }

    func refresh() {
        #if DEBUG
        if Snapshots.isRequested { return }
        #endif
        items = []
        files = [:]
        status = .searching
        if !deviceSelectionLocked, let selectedDeviceID {
            camera = cameras[selectedDeviceID]
        }
        if let camera {
            if camera.hasOpenSession {
                load(camera)
            } else {
                camera.requestOpenSession()
            }
        }
    }

    func selectDevice(_ id: String) {
        guard !deviceSelectionLocked, let camera = cameras[id] else { return }
        guard selection.select(id) else { return }
        self.camera = camera
        items = []
        files = [:]
        if camera.hasOpenSession {
            load(camera)
        } else {
            camera.requestOpenSession()
        }
    }

    func lockSelectedDeviceForImport() -> Bool {
        selection.beginImport(available: Set(cameras.keys))
    }

    func releaseSelectedDeviceAfterImport() {
        selection.endImport()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = Self.deviceID(for: camera)
        cameras[id] = camera
        deviceIDs[ObjectIdentifier(camera)] = id
        upsertDevice(camera, id: id, connected: true)
        camera.delegate = self
        camera.requestOpenSession()
        if !hasMadeInitialSelection {
            hasMadeInitialSelection = true
            selectDevice(id)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let key = ObjectIdentifier(device)
        guard let id = deviceIDs.removeValue(forKey: key) else { return }
        cameras[id] = nil
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].isConnected = false }
        if selectedDeviceID == id {
            disconnected("The selected device was removed.")
            selection.disconnected(id)
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard deviceIDs[ObjectIdentifier(device)] == selectedDeviceID else { return }
        if error != nil { status = .locked("Unlock and trust the selected device, then keep it connected.") }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard deviceIDs[ObjectIdentifier(device)] == selectedDeviceID else { return }
        disconnected("The selected device connection closed.")
    }

    func didRemove(_ device: ICDevice) {
        guard deviceIDs[ObjectIdentifier(device)] == selectedDeviceID else { return }
        disconnected("The selected device was removed.")
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        if deviceIDs[ObjectIdentifier(device)] == selectedDeviceID { load(device) }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        if let camera = device as? ICCameraDevice, deviceIDs[ObjectIdentifier(camera)] == selectedDeviceID { load(camera) }
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard deviceIDs[ObjectIdentifier(device)] == selectedDeviceID else { return }
        items = []
        files = [:]
        status = .locked("Unlock and trust the iPhone, then keep it connected.")
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        if deviceIDs[ObjectIdentifier(camera)] == selectedDeviceID { load(camera) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        if deviceIDs[ObjectIdentifier(camera)] == selectedDeviceID { load(camera) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { load(camera) }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) { load(camera) }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    /// Downloads one original into the already private, bounded batch folder.
    /// Calls are serial from BackupEngine; Image Capture has one active
    /// download per camera, which also avoids unbounded staging.
    func download(_ item: DeviceMediaItem, into folder: URL) async throws -> URL {
        guard let camera, let file = files[item.id] else {
            throw ImportError.disconnected
        }
        guard continuation == nil else { throw ImportError.busy }
        guard !camera.isLocked, !camera.isAccessRestrictedAppleDevice else {
            throw ImportError.locked
        }
        let destination = Self.safeName(item.filename, id: item.id)
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: folder,
            .saveAsFilename: destination,
            .overwrite: true,
            // Explicitly false even if framework defaults ever change.
            .deleteAfterSuccessfulDownload: false,
            .sidecarFiles: false,
        ]
        status = .importing
        importingID = item.id
        downloadFolder = folder
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            camera.requestDownloadFile(file, options: options, downloadDelegate: self,
                                       didDownloadSelector: #selector(downloaded(_:error:options:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func downloaded(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        let continuation = continuation
        self.continuation = nil
        importingID = nil
        let folder = downloadFolder
        downloadFolder = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let name = options[ICDownloadOption.savedFilename.rawValue] as? String,
                  let folder {
            continuation?.resume(returning: folder.appendingPathComponent(name))
        } else {
            continuation?.resume(throwing: ImportError.missingOutput)
        }
        if case .importing = status { status = currentReadyStatus() }
    }

    func cancelDownload() {
        camera?.cancelDownload()
    }

    /// Called only after Google has independently read back the exact staged
    /// originals and the person confirmed this preview. It intentionally uses
    /// no \"delete after download\" option, and never purges Recently Deleted.
    func deleteVerified(_ ids: Set<String>) async throws -> Set<String> {
        if let blocker = reclaimBlocker(for: ids) { throw ImportError.reclaimUnavailable(blocker) }
        guard let camera else { throw ImportError.disconnected }
        let targets = ids.compactMap { files[$0] }
        guard targets.count == ids.count else { throw ImportError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = DeleteContinuationGate(continuation)
            let progress = camera.requestDeleteFiles(targets, deleteFailed: { _ in
                // The completion result remains the only authority for what
                // actually changed; no per-file error text is displayed.
            }, completion: { result, error in
                if let error { gate.fail(error); return }
                let successful = Set((result[ICDeleteResult.successful] ?? []).compactMap { item in
                    self.files.first(where: { $0.value === item })?.key
                })
                gate.succeed(successful)
            })
            // A nil progress means Image Capture rejected the request before
            // it was queued. Resume now; the gate safely ignores any broken
            // driver's late completion rather than hanging a reclaim run.
            if progress == nil {
                gate.fail(ImportError.reclaimUnavailable("The device rejected the deletion request; source media was retained."))
            }
        }
    }

    private func load(_ camera: ICCameraDevice) {
        // Delegate notifications may arrive from an unselected device after a
        // picker change. They must not overwrite the active catalog.
        guard let selectedDeviceID,
              deviceIDs[ObjectIdentifier(camera)] == selectedDeviceID,
              camera === self.camera
        else { return }
        guard !camera.isLocked, !camera.isAccessRestrictedAppleDevice else {
            items = []
            files = [:]
            status = .locked("Unlock and trust the iPhone, then keep it connected.")
            return
        }
        if camera.capabilities.contains(ICDeviceCapability.cameraDeviceSupportsHEIF.rawValue) {
            camera.mediaPresentation = .originalAssets
        }
        supportsDeviceDeletion = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        let cameraFiles = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let descriptors = cameraFiles.compactMap { file -> (DeviceMediaItem, ICCameraFile)? in
            let deviceID = Self.deviceID(for: camera)
            let id = DeviceImportPlan.stableIdentifier(deviceID: deviceID, fingerprint: file.fingerprint,
                                                       objectHandle: file.ptpObjectHandle,
                                                       filename: file.originalFilename ?? file.name ?? "file")
            let filename = file.originalFilename ?? file.name ?? "Untitled"
            let item = DeviceMediaItem(id: id, filename: filename, byteCount: Int64(file.fileSize),
                                       createdAt: file.fileCreationDate as Date?, isMovie: file.uti == "public.movie")
            return (item, file)
        }
        items = DeviceImportPlan.unique(descriptors.map(\.0))
        files = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.0.id, $0.1) })
        status = currentReadyStatus()
    }

    private static func deviceID(for camera: ICCameraDevice) -> String {
        camera.uuidString ?? "usb:\(camera.usbVendorID):\(camera.usbProductID):\(camera.usbLocationID)"
    }

    private func upsertDevice(_ camera: ICCameraDevice, id: String, connected: Bool) {
        let value = Device(id: id, name: camera.name ?? "Connected device", model: camera.productKind ?? "Camera", isConnected: connected)
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index] = value
        } else {
            devices.append(value)
            devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func currentReadyStatus() -> Status {
        guard let camera else { return .unavailable("No connected phone or camera is available.") }
        return .ready(name: camera.name ?? "Connected device", count: items.count)
    }

    private func disconnected(_ message: String) {
        camera = nil
        files = [:]
        items = []
        continuation?.resume(throwing: ImportError.disconnected)
        continuation = nil
        status = .unavailable(message)
    }

    private static func safeName(_ name: String, id: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        let suffix = String(id.hashValue, radix: 16)
        return "\(stem.prefix(120))-\(suffix).\(ext.isEmpty ? "media" : ext)"
    }

    enum ImportError: LocalizedError {
        case disconnected, busy, locked, missingOutput, reclaimUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .disconnected: "The device was disconnected before the original could be copied."
            case .busy: "Another device import is already in progress."
            case .locked: "Unlock and trust the iPhone before importing."
            case .missingOutput: "The device did not return a downloaded file."
            case let .reclaimUnavailable(reason): reason
            }
        }
    }
}

/// Image Capture callbacks are normally on the main thread but drivers are
/// external. A one-shot gate protects against a rejected request followed by
/// a late callback, which would otherwise resume a continuation twice.
private final class DeleteContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Set<String>, Error>?

    init(_ continuation: CheckedContinuation<Set<String>, Error>) {
        self.continuation = continuation
    }

    func succeed(_ ids: Set<String>) { resolve(.success(ids)) }
    func fail(_ error: Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Set<String>, Error>) {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(with: result)
    }
}
