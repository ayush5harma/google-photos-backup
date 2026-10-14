import Foundation
import Testing
@testable import PhotosBackupCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let hour: TimeInterval = 3600

/// A healthy Mac: full access, a run completed an hour ago, nothing held.
private func healthy() -> DiagnosticSnapshot {
    var snapshot = DiagnosticSnapshot()
    snapshot.generatedAt = now
    snapshot.photosAccess = .full
    snapshot.account = "ann.lee@gmail.com"
    snapshot.accountStatus = "Connected"
    snapshot.runs = [completedRun(hoursAgo: 1)]
    return snapshot
}

private func completedRun(hoursAgo: Double, failed: Int = 0, trigger: RunTrigger = .timer) -> RunRecord {
    let start = now.addingTimeInterval(-hoursAgo * hour)
    return RunRecord(kind: .photos, trigger: trigger, startedAt: start, finishedAt: start.addingTimeInterval(60),
                     uploaded: 2, failed: failed, outcome: .completed, conditions: "Wi-Fi, on power")
}

private func problem(_ message: String, hoursAgo: Double, _ category: EventCategory = .run) -> EventRecord {
    EventRecord(date: now.addingTimeInterval(-hoursAgo * hour), category: category, message: message, isProblem: true)
}

@Suite struct DiagnosticFindingTests {
    @Test func aHealthyMacHasNothingToSay() {
        #expect(DiagnosticReport.findings(healthy()).isEmpty)
    }

    @Test func accountRefusalsInTheLastWeek() {
        var snapshot = healthy()
        snapshot.events = [problem("Google refused the account (403)", hoursAgo: 2, .account),
                           problem("Google refused the account (403)", hoursAgo: 30, .account)]
        #expect(DiagnosticReport.findings(snapshot).first?.hasPrefix("Google refused the account 2 times") == true)
        snapshot.events = [problem("Google refused the account (403)", hoursAgo: 8 * 24, .account)]
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
    }

    @Test func limitedOrDeniedPhotosAccess() {
        var snapshot = healthy()
        snapshot.photosAccess = .limited
        #expect(DiagnosticReport.findings(snapshot) == ["Photos access is limited to selected photos, so only those can be backed up."])
        snapshot.photosAccess = .denied
        #expect(DiagnosticReport.findings(snapshot).first?.contains("denied") == true)
    }

    @Test func fullDiskAccessMattersOnlyWithAMessagesFeatureOn() {
        var snapshot = healthy()
        snapshot.fullDiskAccess = false
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
        snapshot.messagesFeatureOn = true
        #expect(DiagnosticReport.findings(snapshot).first?.contains("Full Disk Access") == true)
        snapshot.fullDiskAccess = true
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
    }

    @Test func noCompletedRunInADayWhileAutomaticIsOn() {
        var snapshot = healthy()
        snapshot.runs = [completedRun(hoursAgo: 30)]
        #expect(DiagnosticReport.findings(snapshot).first?.hasPrefix("No backup has completed in the last 24 hours") == true)
        snapshot.runs = []
        #expect(DiagnosticReport.findings(snapshot).count == 1)
        snapshot.automaticBackups = false
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
    }

    @Test func repeatedFailuresAcrossRecentRuns() {
        var snapshot = healthy()
        snapshot.runs = [completedRun(hoursAgo: 1, failed: 2), completedRun(hoursAgo: 2, failed: 1),
                         completedRun(hoursAgo: 3), completedRun(hoursAgo: 4, failed: 4)]
        #expect(DiagnosticReport.findings(snapshot) == ["3 of the last 4 runs had failed items (7 in all)."])
        snapshot.runs.removeLast()
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
    }

    @Test func rateLimitingInTheLastDay() {
        var snapshot = healthy()
        snapshot.events = [EventRecord(date: now.addingTimeInterval(-hour), category: .network,
                                       message: "\(EventPhrase.rateLimited); uploads wait 60 s")]
        #expect(DiagnosticReport.findings(snapshot).first?.hasPrefix("Google asked the app to slow down once") == true)
        snapshot.events[0].date = now.addingTimeInterval(-25 * hour)
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
    }

    @Test func conditionsHoldingForLong() {
        var snapshot = healthy()
        snapshot.holding = .onBattery
        snapshot.holdingSince = now.addingTimeInterval(-10 * 60)
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
        snapshot.holdingSince = now.addingTimeInterval(-3 * hour)
        #expect(DiagnosticReport.findings(snapshot) == ["Uploads have been held for 3 hours: paused on battery power."])
    }

    @Test func manyFailuresOfOneKind() {
        var snapshot = healthy()
        snapshot.failureMessages = Array(repeating: "413 Client Error: Request Entity Too Large for url: https://x", count: 6)
            + ["[Errno 2] No such file: '/tmp/1'", "[Errno 2] No such file: '/tmp/2'"]
        #expect(DiagnosticReport.findings(snapshot) == ["6 uploads failed with HTTP 413."])
        snapshot.failureMessages = (1...5).map { "[Errno 2] No such file: '/tmp/\($0)'" }
        #expect(DiagnosticReport.findings(snapshot) == ["5 uploads failed with \u{201C}[Errno #] No such file: '/tmp/#'\u{201D}."])
    }

    @Test func stagingLeftoversOnlyWhenNoRunIsUsingThem() {
        var snapshot = healthy()
        snapshot.storage.staging = 5_000_000
        #expect(DiagnosticReport.findings(snapshot).first?.contains("left behind") == true)
        snapshot.runActive = true
        #expect(DiagnosticReport.findings(snapshot).isEmpty)
    }
}

@Suite struct DiagnosticReportTextTests {
    @Test func whatStandsOutComesFirstAndEverythingIsRedacted() {
        var snapshot = healthy()
        snapshot.photosAccess = .limited
        snapshot.settings = [.init("Quality", "Original"), .init("Automatic", "On")]
        snapshot.lastError = "Google refused Token=aas_et/abc for ann.lee@gmail.com at /Users/ann/Library"
        snapshot.events = [problem("upload of /Users/ann/Pictures/x.jpg failed, call +1 415 555 0123", hoursAgo: 1, .photos)]
        let text = DiagnosticReport.build(snapshot, redactor: Redactor(homeDirectory: "/Users/ann"), timeZone: TimeZone(identifier: "UTC")!)

        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "Photos Backup diagnostic report")
        #expect(lines[4] == "What stands out")
        #expect(lines[5].hasPrefix("- Photos access is limited"))
        #expect(text.contains("Google account: a***@gmail.com (Connected)"))
        #expect(text.contains("Quality: Original"))
        #expect(text.contains("Last error: Google refused Token=<redacted> for a***@gmail.com at ~/Library"))
        #expect(text.contains("[photos] upload of ~/Pictures/x.jpg failed, call [phone ending 23]"))
        #expect(text.contains("Wi-Fi, on power"))
        for secret in ["ann.lee", "aas_et/abc", "/Users/ann", "555"] { #expect(!text.contains(secret), "\(secret)") }
    }

    @Test func everyTimeIsLocalISO8601WithItsOffset() throws {
        var snapshot = healthy()
        snapshot.runs = [completedRun(hoursAgo: 30)]
        snapshot.events = [problem("x", hoursAgo: 1)]
        let india = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let text = DiagnosticReport.build(snapshot, redactor: Redactor(homeDirectory: "/Users/ann"), timeZone: india)
        // generatedAt 2033-05-18T03:33:20Z is 09:03:20 in India.
        #expect(text.contains("Generated 2033-05-18T09:03:20+05:30"))
        // The run started 30 h earlier and ended a minute later: 21:34:20Z.
        #expect(text.contains("(last on 2033-05-17T03:04:20+05:30)"))
        #expect(text.contains("2033-05-18T08:03:20+05:30 [run] x"))
        #expect(!text.contains("Z)"))
    }

    @Test func saysSoWhenNothingStandsOut() {
        let text = DiagnosticReport.build(healthy(), redactor: Redactor(homeDirectory: "/Users/ann"))
        #expect(text.contains("What stands out\n- Nothing stands out.\n"))
        #expect(text.contains("Recent problems (newest first)\nNone."))
    }
}
