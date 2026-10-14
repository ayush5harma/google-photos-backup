import Foundation
import Observation
import PhotosBackupCore

@MainActor
@Observable
final class ICloudSource {
    typealias Phase = ICloudMenuStatus.Phase

    private(set) var phase: Phase = .signedOut
    private(set) var uploaded = 0
    private(set) var existing = 0
    private(set) var failed = 0
    private(set) var pending = 0
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var notice: String?
    private(set) var verification = ICloudVerificationState()
    var trustedPhones: [ICloudTrustedPhone] { verification.phones }
    var deviceCodeAvailable: Bool { verification.deviceCodeAvailable }
    var selectedSMSPhoneID: Int? { verification.selectedSMSPhoneID }
    private(set) var accountState: ICloudAccountState
    var account: String { accountState.selectedAccount }
    var hasSavedSession: Bool { accountState.hasSavedSession }
    var hasConfirmedSelection: Bool { accountState.pendingAccount == nil && accountState.hasSavedSession }
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let model: AppModel

    init(model: AppModel) {
        self.model = model
        accountState = ICloudAccountState(confirmedAccount: AppEnvironment.defaults.string(forKey: "icloudSourceAccount"))
    }

    #if DEBUG
    func applyFixture(phase: Phase, account: String = "", confirmed: Bool = false,
                      completed: Int = 0, total: Int = 0, uploaded: Int = 0,
                      existing: Int = 0, failed: Int = 0, pending: Int = 0) {
        accountState = ICloudAccountState(confirmedAccount: confirmed ? account : nil)
        if !confirmed && !account.isEmpty { accountState.beginSignIn(account) }
        self.phase = phase
        self.completed = completed
        self.total = total
        self.uploaded = uploaded
        self.existing = existing
        self.failed = failed
        self.pending = pending
        notice = phase == .needs2FA ? "Enter the code Apple sent to a trusted device or phone number." : nil
    }
    #endif

    var isActive: Bool { phase == .backingUp || phase == .stopping }
    var isRunning: Bool { operation != nil }
    var runtimeAvailable: Bool {
        guard let runtime = BridgeRuntime.locate() else { return false }
        return FileManager.default.fileExists(atPath: runtime.script.deletingLastPathComponent()
            .appendingPathComponent("icloud_bridge.py").path)
    }

    func check() {
        guard operation == nil else { return }
        guard let saved = accountState.useSavedSession() else { phase = .signedOut; return }
        phase = .checking
        verification = ICloudVerificationState()
        start(.init(command: .status, account: saved, stateDir: stateDirectory.path))
    }

    func useAnotherAccount() {
        guard operation == nil else { return }
        accountState.beginAnotherAccount()
        verification = ICloudVerificationState()
        phase = .signedOut
        notice = nil
    }

    func signIn(account: String, password: String) {
        guard operation == nil else { return }
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !password.isEmpty else {
            notice = "Enter your Apple Account and password."
            return
        }
        accountState.beginSignIn(normalized)
        verification = ICloudVerificationState()
        phase = .signingIn
        notice = nil
        start(.init(command: .signIn, account: normalized, stateDir: stateDirectory.path, password: password))
    }

    func sendCode(to phoneID: Int, password: String) {
        guard operation == nil, !account.isEmpty, !password.isEmpty,
              verification.sendSMS(to: phoneID) else { return }
        phase = .signingIn
        notice = nil
        start(.init(command: .sendCode, account: account, stateDir: stateDirectory.path,
                    password: password, phoneID: phoneID))
    }

    func useDeviceCode() {
        guard deviceCodeAvailable, operation == nil else { return }
        verification.chooseDeviceCode()
        notice = "Enter the code shown on your trusted device."
    }

    func choosePhone() {
        guard operation == nil else { return }
        verification.choosePhone()
        notice = "Request a text message for the selected trusted phone."
    }

    func verify(code: String, password: String) {
        guard operation == nil, !account.isEmpty else { return }
        guard verification.canVerify else {
            notice = "Choose a trusted phone and request a text message first."
            return
        }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            notice = "Enter the verification code and your Apple Account password."
            return
        }
        phase = .signingIn
        notice = nil
        start(.init(command: .verify2FA, account: account, stateDir: stateDirectory.path,
                    password: password, code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                    phoneID: verification.selectedSMSPhoneID))
    }

    func backUp() {
        guard operation == nil, hasConfirmedSelection,
              phase == .ready || phase == .finished || phase == .stopped || phase == .failed else { return }
        guard runtimeAvailable else {
            notice = "The iCloud helper is unavailable. Reinstall Photos Backup and try again."
            return
        }
        guard let auth = model.authData else {
            notice = "Connect your Google Photos account before starting this backup."
            return
        }
        uploaded = 0; existing = 0; failed = 0; pending = 0; completed = 0; total = 0
        notice = nil
        phase = .backingUp
        start(.init(command: .backup, account: account, stateDir: stateDirectory.path,
                    stagingDir: stagingDirectory.path, authData: auth))
    }

    func pause() {
        guard phase == .backingUp else { return }
        phase = .stopping
        if let process, process.isRunning { process.terminate() }
    }

    func stopForQuit() {
        guard operation != nil else { return }
        phase = .stopping
        if let process, process.isRunning { process.terminate() }
    }

    private var stateDirectory: URL { model.paths.support.appendingPathComponent("iCloud Source", isDirectory: true) }
    private var stagingDirectory: URL { model.paths.staging.deletingLastPathComponent().appendingPathComponent("iCloud Source", isDirectory: true) }

    private func start(_ request: ICloudRequest) {
        operation = Task {
            defer { operation = nil }
            if phase == .stopping { phase = .stopped; return }
            do {
                let exit = try await run(request)
                if phase == .stopping { phase = .stopped; notice = "Paused. Start again to resume remaining items." }
                else if exit != 0, phase != .failed, phase != .needs2FA,
                        phase != .signedOut, phase != .stopped {
                    phase = .failed
                    notice = "The iCloud source could not finish. Check the account and network, then try again."
                } else if phase == .checking || phase == .signingIn || phase == .backingUp {
                    phase = .failed
                    notice = "The iCloud source ended without confirming its result. Try again."
                }
            } catch {
                phase = .failed
                notice = "The iCloud source could not start. Check that the app's helper is installed."
            }
        }
    }

    private func run(_ request: ICloudRequest) async throws -> Int32 {
        guard let runtime = BridgeRuntime.locate() else { throw RunError.unavailable }
        let script = runtime.script.deletingLastPathComponent().appendingPathComponent("icloud_bridge.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw RunError.unavailable }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let child = Process()
        child.executableURL = runtime.python
        child.arguments = ["-I", "-B", script.path]
        child.currentDirectoryURL = stateDirectory
        child.environment = ["HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin",
                             "TMPDIR": NSTemporaryDirectory()]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        // 2026-10-15: Authentication and file failures can contain private paths or account data.
        child.standardError = FileHandle.nullDevice
        let (events, sink) = AsyncStream<ICloudEvent>.makeStream()
        let splitter = ICloudSplitter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            let lines = chunk.isEmpty ? splitter.finish() : splitter.append(chunk)
            for line in lines {
                if let event = ICloudEvent.decode(line) { sink.yield(event) }
            }
            if chunk.isEmpty { handle.readabilityHandler = nil; sink.finish() }
        }
        do { try child.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw RunError.unavailable
        }
        process = child
        defer { process = nil }
        do { try input.fileHandleForWriting.write(contentsOf: request.encoded()) }
        catch { if child.isRunning { child.terminate() } }
        try? input.fileHandleForWriting.close()
        for await event in events { receive(event) }
        return await Task.detached { child.waitUntilExit(); return child.terminationStatus }.value
    }

    private func receive(_ event: ICloudEvent) {
        switch event {
        case .auth(.signedIn, _, _):
            if phase != .backingUp && phase != .stopping {
                if let confirmed = accountState.confirmSignIn() {
                    AppEnvironment.defaults.set(confirmed, forKey: "icloudSourceAccount")
                }
                phase = .ready
                notice = nil
                verification = ICloudVerificationState()
            }
        case .auth(.signedOut, _, _): phase = .signedOut; notice = "Sign in to your Apple Account to back up iCloud Photos."
        case let .auth(.needs2FA, phones, deviceAvailable):
            verification.receiveChallenge(phones: phones, deviceCodeAvailable: deviceAvailable)
            phase = .needs2FA
            notice = selectedSMSPhoneID == nil
                ? (deviceAvailable ? "Enter the code shown on your trusted device, or request a text message." : "Choose a trusted phone and request a text message.")
                : "Enter the code sent to your trusted phone."
        case let .progress(done, count): completed = done; total = count
        case .item(let didUpload): if didUpload { uploaded += 1 } else { existing += 1 }
        case .itemFailed: failed += 1
        case let .done(sent, present, errors, remaining):
            uploaded = sent; existing = present; failed = errors; pending = remaining
            phase = .finished
            notice = remaining > 0 ? "Some items remain. Start again to resume." : "Backup finished."
        case .stopped: phase = .stopped; notice = "Paused. Start again to resume remaining items."
        case .reclaim: break
        case .failure(let kind):
            if kind == "mfa_delivery" {
                phase = .needs2FA
                verification.choosePhone()
                notice = "Could not send the text message. Choose a trusted phone and try again."
                break
            }
            phase = .failed
            notice = switch kind {
            case "auth": "Apple or Google sign-in expired or was refused. Check both accounts, then resume."
            case "unsupported_2sa": "Legacy Apple two-step verification is not supported. Use an account with two-factor authentication, or back up through the Mac Photos library."
            case "network": "The network interrupted this backup. Try again when connected."
            case "icloud_unavailable": "iCloud Photos is unavailable or still indexing. Check Photos on iCloud.com and web access, then retry when the library is ready."
            default: "The iCloud source could not finish. Check the account and try again."
            }
        case .unknown: break
        }
    }

    private enum RunError: Error { case unavailable }
}

private final class ICloudSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()
    func append(_ data: Data) -> [Data] { lock.withLock { splitter.append(data) } }
    func finish() -> [Data] { lock.withLock { splitter.finish().map { [$0] } ?? [] } }
}
