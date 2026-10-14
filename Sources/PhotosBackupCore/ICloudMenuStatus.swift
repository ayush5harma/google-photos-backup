import Foundation

public struct ICloudMenuStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case signedOut, checking, needs2FA, ready, signingIn, backingUp, stopping, stopped, finished, failed
    }

    public enum Action: Equatable, Sendable {
        case open, start, pause, resume
    }

    public let phase: Phase
    public let headline: String
    public let action: Action
    public let completed: Int
    public let total: Int
    public let uploaded: Int
    public let existing: Int
    public let failed: Int
    public let pending: Int

    public init(phase: Phase, hasAppleSession: Bool, hasGoogleAccount: Bool, runtimeAvailable: Bool,
                completed: Int, total: Int, uploaded: Int, existing: Int, failed: Int, pending: Int) {
        self.phase = phase
        self.completed = max(0, completed)
        self.total = max(0, total)
        self.uploaded = max(0, uploaded)
        self.existing = max(0, existing)
        self.failed = max(0, failed)
        self.pending = max(0, pending)

        let ready = hasAppleSession && hasGoogleAccount && runtimeAvailable
        switch phase {
        case .signedOut:
            headline = hasAppleSession ? "Check saved iCloud session" : "Sign in to iCloud Photos"
            action = .open
        case .checking: headline = "Checking iCloud session…"; action = .open
        case .needs2FA: headline = "Apple verification required"; action = .open
        case .signingIn: headline = "Signing in to iCloud…"; action = .open
        case .ready:
            headline = !hasAppleSession ? "Sign in to iCloud Photos" :
                !hasGoogleAccount ? "Connect Google Photos" :
                !runtimeAvailable ? "iCloud helper unavailable" : "Ready to back up"
            action = ready ? .start : .open
        case .backingUp:
            headline = self.total > 0 ? "Backing up \(self.completed) of \(self.total)" : "Backing up iCloud Photos…"
            action = .pause
        case .stopping: headline = "Pausing iCloud backup…"; action = .open
        case .stopped:
            headline = "iCloud backup paused"
            action = ready ? .resume : .open
        case .finished:
            headline = self.pending > 0 ? "\(self.pending) iCloud items remain" : "iCloud backup finished"
            action = ready && self.pending > 0 ? .resume : .open
        case .failed: headline = "iCloud backup needs attention"; action = .open
        }
    }

    public var takesMenuBarLabel: Bool {
        switch phase {
        case .backingUp, .stopping, .stopped, .failed: true
        default: false
        }
    }

    public var symbol: String {
        switch phase {
        case .backingUp, .stopping: "arrow.up.circle.fill"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.circle"
        default: "icloud"
        }
    }

    public var fraction: Double? {
        guard phase == .backingUp, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}
