import SwiftUI

struct ICloudSourceView: View {
    @Environment(AppModel.self) private var model
    @State private var appleAccount = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var selectedPhoneID: Int?
    @State private var confirmReclaim = false
    @State private var confirmAutomaticReclaim = false

    private var source: ICloudSource { model.iCloud }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                introduction
                accountPanel
                if source.phase == .ready || source.phase == .backingUp || source.phase == .stopping ||
                    source.phase == .stopped || source.phase == .finished ||
                    (source.phase == .failed && source.hasConfirmedSelection) {
                    transferPanel
                }
                if !source.reclaimFiles.isEmpty { reclaimPanel }
                safetyPanel
            }
            .readablePage()
        }
        .confirmationDialog("Move verified originals to Recently Deleted?", isPresented: $confirmReclaim, titleVisibility: .visible) {
            Button("Verify and Move to Recently Deleted", role: .destructive) { source.reclaimVerifiedCopies() }
        } message: {
            Text("This removes \(source.reclaimCount) selected iCloud items from all synced devices after Google original verification. Apple keeps them in Recently Deleted temporarily; space may not be freed immediately.")
        }
        .confirmationDialog("Automatically reclaim this backup batch?", isPresented: $confirmAutomaticReclaim, titleVisibility: .visible) {
            Button("Back Up, Verify and Reclaim", role: .destructive) { source.backUp(reclaimAfterBackup: true) }
        } message: {
            Text("For this run only, process up to 100 iCloud items, then independently verify all original components in Google Photos and move verified sources to Recently Deleted across all synced devices. Unverified items stay. Space recovery may be delayed.")
        }
        .navigationTitle("iCloud Photos")
        .navigationSubtitle("Copy iCloud Photos to Google Photos")
        .task {
            appleAccount = source.account
            #if DEBUG
            if Snapshots.isRequested { return }
            #endif
            if source.phase == .signedOut || source.phase == .ready { source.check() }
        }
        .onChange(of: source.phase) { _, newPhase in
            if newPhase == .ready { password = ""; verificationCode = "" }
            if newPhase == .needs2FA, selectedPhoneID == nil { selectedPhoneID = source.trustedPhones.first?.id }
        }
        .onChange(of: source.trustedPhones) { _, phones in
            if !phones.contains(where: { $0.id == selectedPhoneID }) { selectedPhoneID = phones.first?.id }
        }
        .onChange(of: selectedPhoneID) { _, phoneID in
            if source.selectedSMSPhoneID != nil, source.selectedSMSPhoneID != phoneID {
                source.choosePhone()
                verificationCode = ""
            }
        }
        .onDisappear { password = ""; verificationCode = "" }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Back up iCloud Photos").font(.largeTitle.bold())
            Text("Sign in to the Apple Account that holds your iCloud Photos. This can be a different account from the one signed in to this Mac. Photos Backup downloads originals temporarily and uploads them to your connected Google Photos account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Apple Account", systemImage: "person.crop.circle")
                        .font(.headline)
                    Spacer()
                    statusLabel
                }
                if let notice = source.notice {
                    Text(notice).foregroundStyle(source.phase == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if source.phase == .checking || source.phase == .signingIn {
                    ProgressView(source.phase == .checking ? "Checking saved session…" : "Signing in…")
                } else if source.phase == .needs2FA {
                    twoFactorForm
                } else if source.phase == .signedOut || source.phase == .failed {
                    signInForm
                } else {
                    HStack {
                        Text(source.account).textSelection(.enabled)
                        Spacer()
                        Button("Check Session") { source.check() }
                            .disabled(source.isRunning)
                        Button("Use Another Account") {
                            source.useAnotherAccount()
                            appleAccount = ""
                            password = ""
                            verificationCode = ""
                        }
                        .disabled(source.isRunning)
                    }
                }
                if source.phase == .signedOut {
                    Text("If you already use iCloud Photos in the Mac Photos app, you can back up those downloaded originals from Albums instead.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Apple Account email", text: $appleAccount)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            HStack {
                Button("Sign In") { source.signIn(account: appleAccount, password: password) }
                    .buttonStyle(.borderedProminent)
                    .disabled(source.isRunning || appleAccount.isEmpty || password.isEmpty)
                if source.hasSavedSession {
                    Button("Use Saved Session") {
                        source.check()
                        appleAccount = source.account
                        password = ""
                        verificationCode = ""
                    }
                        .disabled(source.isRunning)
                }
            }
            Text("Your password and verification code are sent to the local helper for sign-in and are not saved by this form. Apple may ask you to approve the sign-in on a trusted device.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var twoFactorForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if source.deviceCodeAvailable {
                Text("Approve the sign-in on your trusted device and enter its code, or request a text message below.")
            } else {
                Text("Choose a trusted phone to receive a text message with a verification code.")
            }
            if password.isEmpty {
                SecureField("Apple Account password", text: $password)
                    .textContentType(.password)
            }
            if !source.trustedPhones.isEmpty {
                HStack {
                    Picker("Trusted phone", selection: $selectedPhoneID) {
                        ForEach(source.trustedPhones) { phone in
                            Text(phone.label).tag(Optional(phone.id))
                        }
                    }
                    Button(source.selectedSMSPhoneID == selectedPhoneID ? "Resend Text Message" : "Send Text Message") {
                        if let selectedPhoneID {
                            source.sendCode(to: selectedPhoneID, password: password)
                            verificationCode = ""
                        }
                    }
                    .disabled(source.isRunning || selectedPhoneID == nil || password.isEmpty)
                }
            }
            if source.deviceCodeAvailable || source.selectedSMSPhoneID != nil {
                TextField(source.selectedSMSPhoneID == nil ? "Trusted device code" : "Text message code", text: $verificationCode)
                    .textContentType(.oneTimeCode)
            }
            HStack {
                Button("Verify Code") { source.verify(code: verificationCode, password: password) }
                    .buttonStyle(.borderedProminent)
                    .disabled(source.isRunning || verificationCode.isEmpty || password.isEmpty ||
                              (!source.deviceCodeAvailable && source.selectedSMSPhoneID == nil))
                if source.deviceCodeAvailable && source.selectedSMSPhoneID != nil {
                    Button("Use Device Code") {
                        source.useDeviceCode()
                        verificationCode = ""
                    }
                }
                Button("Start Again") { source.signIn(account: appleAccount, password: password) }
                    .disabled(source.isRunning || password.isEmpty)
                if source.hasSavedSession {
                    Button("Use Saved Session") {
                        source.check()
                        appleAccount = source.account
                        password = ""
                        verificationCode = ""
                    }
                    .disabled(source.isRunning)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var transferPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label("iCloud to Google Photos", systemImage: "arrow.up.icloud")
                    .font(.headline)
                if !model.hasAuthData {
                    Text("Connect Google Photos in Account settings before starting.")
                        .foregroundStyle(.secondary)
                }
                if source.total > 0 {
                    ProgressView(value: Double(source.completed), total: Double(source.total)) {
                        Text("Processed \(source.completed) of \(source.total)")
                    }
                }
                HStack(spacing: 18) {
                    count("Uploaded", source.uploaded)
                    count("Already present", source.existing)
                    count("Failed", source.failed)
                    if source.pending > 0 { count("Remaining", source.pending) }
                }
                HStack {
                    if source.phase == .backingUp {
                        Button("Pause Backup") { source.pause() }
                    } else if source.phase == .stopping {
                        ProgressView("Pausing…")
                    } else {
                        Button(source.phase == .stopped || source.phase == .finished ? "Resume Backup" : "Start Backup") {
                            source.backUp()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(source.isRunning || !model.hasAuthData || !source.hasConfirmedSelection)
                    }
                }
                Button("Back Up and Automatically Reclaim…") { confirmAutomaticReclaim = true }
                    .disabled(source.isRunning || !model.hasAuthData || !source.hasConfirmedSelection)
                Text("A resumed run checks its account-bound progress. Items are counted as backed up only after Google confirms them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var reclaimPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Reclaim selected iCloud originals", systemImage: "trash").font(.headline)
                Text("Select up to 100 backed-up items from this run. Live Photo components must all pass a fresh byte-for-byte Google original check. Nothing is removed during preview.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(source.reclaimFiles.keys.sorted(), id: \.self) { id in
                    Toggle(source.reclaimFiles[id] ?? id, isOn: Binding(
                        get: { source.reclaimSelection.contains(id) },
                        set: { if $0 { source.reclaimSelection.insert(id) } else { source.reclaimSelection.remove(id) } }
                    )).disabled(source.isRunning)
                }
                Button("Preview Selected Items") { source.previewReclaim() }
                    .disabled(source.isRunning || source.reclaimSelection.isEmpty)
                if source.reclaimToken != nil {
                    Text("\(source.reclaimCount) eligible items · \(ByteCountFormatter.string(fromByteCount: Int64(source.reclaimBytes), countStyle: .file)). Preview expires after 15 minutes.")
                    Button("Verify and Reclaim…", role: .destructive) { confirmReclaim = true }
                        .disabled(source.isRunning || source.reclaimCount == 0)
                }
            }
        }
    }

    private var safetyPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("You control source removal", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("Backup keeps iCloud originals. Optional reclaim verifies each Google original before moving selected items to Recently Deleted across synced devices. It never empties Recently Deleted or promises immediate space recovery.")
                Text("If sign-in is unavailable, check whether iCloud web data access is enabled for this Apple Account. Accounts using Advanced Data Protection may not work with this source. You can use the Mac Photos library and the Albums backup instead.")
                    .foregroundStyle(.secondary)
                Link("Open iCloud account settings", destination: URL(string: "https://www.icloud.com/settings/")!)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLabel: some View {
        Text(statusTitle)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var statusTitle: String {
        switch source.phase {
        case .signedOut: "Signed out"
        case .checking: "Checking"
        case .needs2FA: "Verification required"
        case .ready: "Connected"
        case .signingIn: "Signing in"
        case .backingUp: "Backing up"
        case .stopping: "Pausing"
        case .stopped: "Paused"
        case .finished: "Finished"
        case .failed: "Needs attention"
        }
    }

    private func count(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.title3.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
