import Foundation
import Testing
@testable import PhotosBackupCore

private let english = Locale(identifier: "en_US")

private func status(signedIn: Bool = true, accountProblem: Bool = false, activity: MenuBarStatus.Activity = .idle, remaining: Int = 0,
                    pending: Int = 0, total: Int = 100, failed: Int = 0, problem: String? = nil, archiving: Bool = false) -> MenuBarStatus {
    MenuBarStatus(.init(signedIn: signedIn, accountProblem: accountProblem, activity: activity, remaining: remaining, pending: pending,
                        total: total, failed: failed, problem: problem, archiving: archiving), locale: english)
}

@Suite struct MenuBarStatusTests {
    @Test func upToDateWhenEverythingSelectedIsBackedUp() {
        let up = status()
        #expect(up.kind == .upToDate)
        #expect(up.headline == "Up to date")
        #expect(up.symbol == "checkmark.circle")
    }

    @Test func backingUpCountsWhatIsLeftWithThousandsSeparators() {
        let running = status(activity: .running, remaining: 1234)
        #expect(running.kind == .backingUp)
        #expect(running.headline == "Backing up 1,234 items")
        #expect(status(activity: .running, remaining: 1).headline == "Backing up 1 item")
        // Planning, before the run knows its size.
        #expect(status(activity: .running).headline == "Backing up…")
        #expect(status(activity: .pausing, remaining: 5).headline == "Pausing after this batch")
        #expect(status(activity: .stopping).headline == "Stopping…")
    }

    @Test func waitingSaysWhy() {
        let waiting = status(activity: .waiting(.onBattery))
        #expect(waiting.kind == .waiting)
        #expect(waiting.headline == "Paused on battery power")
        #expect(status(activity: .waiting(nil)).headline == "Waiting")
    }

    @Test func signInComesFirst() {
        let signedOut = status(signedIn: false, activity: .running, failed: 3)
        #expect(signedOut.kind == .attention)
        #expect(signedOut.headline == "Sign in to start")
        let refused = status(accountProblem: true)
        #expect(refused.kind == .attention)
        #expect(refused.headline == "Sign in again")
    }

    // A run in progress is what a person wants to see; a problem from an
    // earlier one only once nothing is moving.
    @Test func aRunningBackupOutranksOlderProblems() {
        #expect(status(activity: .running, remaining: 2, failed: 4).kind == .backingUp)
        #expect(status(activity: .running, problem: "Google storage is full").kind == .backingUp)
        #expect(status(problem: "Google storage is full").headline == "Google storage is full")
        #expect(status(failed: 2, problem: "Google storage is full").headline == "Google storage is full")
    }

    @Test func failuresNeedAttentionOnceIdle() {
        let failed = status(pending: 3, failed: 3)
        #expect(failed.kind == .attention)
        #expect(failed.headline == "3 items couldn't be backed up")
        #expect(failed.symbol == "exclamationmark.circle")
        #expect(status(failed: 1).headline == "1 item couldn't be backed up")
    }

    @Test func pausedOutranksFailures() {
        let paused = status(activity: .paused, failed: 2)
        #expect(paused.kind == .paused)
        #expect(paused.headline == "Paused")
        #expect(paused.symbol == "pause.circle")
    }

    @Test func idleWithWorkLeftIsReadyNotUpToDate() {
        let ready = status(pending: 12000)
        #expect(ready.kind == .ready)
        #expect(ready.headline == "12,000 items to back up")
        #expect(status(total: 0).headline == "Choose what to back up")
    }

    @Test func archivingShowsWhenPhotosAreIdle() {
        let archiving = status(archiving: true)
        #expect(archiving.kind == .backingUp)
        #expect(archiving.headline == "Archiving Messages")
        #expect(status(activity: .running, remaining: 3, archiving: true).headline == "Backing up 3 items")
    }

    @Test func everyKindHasItsOwnTemplateSymbol() {
        let kinds: [MenuBarStatus] = [status(), status(activity: .running), status(activity: .paused),
                                      status(activity: .waiting(.offline)), status(failed: 1), status(pending: 1)]
        #expect(Set(kinds.map(\.symbol)).count == kinds.count)
    }
}

@Suite struct RunNotificationTests {
    private func run(_ kind: RunKind = .photos, _ trigger: RunTrigger = .timer, uploaded: Int = 0, failed: Int = 0,
                     outcome: RunOutcome = .completed) -> RunRecord {
        RunRecord(kind: kind, trigger: trigger, uploaded: uploaded, failed: failed, outcome: outcome)
    }

    @Test func automaticRunsThatUploadedSaySo() throws {
        let note = try #require(RunNotification(run(uploaded: 24), locale: english))
        #expect(note.title == "24 photos backed up")
        #expect(note.body == "Everything you selected is in Google Photos.")
        #expect(RunNotification(run(uploaded: 1), locale: english)?.title == "1 photo backed up")
        #expect(RunNotification(run(.messagesMedia, uploaded: 1203), locale: english)?.title == "1,203 Messages photos and videos backed up")
    }

    @Test func runsSomeoneStartedAreNotAnnounced() {
        for trigger in RunTrigger.allCases where !trigger.isAutomatic {
            #expect(RunNotification(run(.photos, trigger, uploaded: 5, failed: 1), locale: english) == nil)
        }
    }

    @Test func runsThatChangedNothingAreQuiet() {
        #expect(RunNotification(run(uploaded: 0), locale: english) == nil)
        #expect(RunNotification(run(.messagesArchive, .schedule, uploaded: 0), locale: english) == nil)
    }

    @Test func failuresAreCountedAndPointToActivity() throws {
        let mixed = try #require(RunNotification(run(uploaded: 10, failed: 2), locale: english))
        #expect(mixed.title == "10 photos backed up")
        #expect(mixed.body == "2 couldn't be backed up. Open Activity to try again.")
        #expect(mixed.opensActivity)
        let failedOnly = try #require(RunNotification(run(failed: 1), locale: english))
        #expect(failedOnly.title == "1 item couldn't be backed up")
        #expect(failedOnly.opensActivity)
    }

    @Test func aRunThatStoppedEarlyDoesNotClaimToBeComplete() throws {
        let paused = try #require(RunNotification(run(uploaded: 3, outcome: .paused), locale: english))
        #expect(paused.body == "The rest continues with the next backup.")
    }

    @Test func archiveRunsCountNewMessages() throws {
        let note = try #require(RunNotification(run(.messagesArchive, .schedule, uploaded: 1203), locale: english))
        #expect(note.title == "Messages archived")
        #expect(note.body == "1,203 new messages")
        #expect(RunNotification(run(.messagesArchive, .schedule, uploaded: 1), locale: english)?.body == "1 new message")
    }
}

@Suite struct ProblemThrottleTests {
    @Test func onePerCategoryPerHour() {
        var throttle = ProblemThrottle()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let answers = [throttle.allows(.account, at: start),
                       throttle.allows(.account, at: start.addingTimeInterval(59 * 60)),
                       throttle.allows(.network, at: start.addingTimeInterval(60)),
                       throttle.allows(.account, at: start.addingTimeInterval(60 * 60))]
        #expect(answers == [true, false, true, true])
    }

    // A refused notification must not push the window on, or a problem that
    // repeats every minute would never be announced again.
    @Test func refusalsDoNotExtendTheWindow() {
        var throttle = ProblemThrottle()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let answers = [throttle.allows(.run, at: start),
                       throttle.allows(.run, at: start.addingTimeInterval(50 * 60)),
                       throttle.allows(.run, at: start.addingTimeInterval(61 * 60))]
        #expect(answers == [true, false, true])
    }
}
