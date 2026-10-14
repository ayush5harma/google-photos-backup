import PhotosBackupCore
import Testing

struct ICloudMenuStatusTests {
    private func status(_ phase: ICloudMenuStatus.Phase, apple: Bool = true, google: Bool = true,
                        runtime: Bool = true, completed: Int = 0, total: Int = 0,
                        uploaded: Int = 0, existing: Int = 0, failed: Int = 0, pending: Int = 0) -> ICloudMenuStatus {
        ICloudMenuStatus(phase: phase, hasAppleSession: apple, hasGoogleAccount: google,
                         runtimeAvailable: runtime, completed: completed, total: total,
                         uploaded: uploaded, existing: existing, failed: failed, pending: pending)
    }

    @Test func startRequiresBothAccountsAndHelper() {
        #expect(status(.signedOut, apple: false).action == .open)
        #expect(status(.signedOut, apple: true).headline == "Check saved iCloud session")
        #expect(status(.needs2FA, apple: false).action == .open)
        #expect(status(.ready, apple: false).action == .open)
        #expect(status(.ready, google: false).headline == "Connect Google Photos")
        #expect(status(.ready, google: false).action == .open)
        #expect(status(.ready, runtime: false).headline == "iCloud helper unavailable")
        #expect(status(.ready, runtime: false).action == .open)
        #expect(status(.ready).action == .start)
    }

    @Test func activeAndPausedRunsExposeOnlyTheirOwnControls() {
        let moving = status(.backingUp, completed: 3, total: 10, uploaded: 2, existing: 1)
        #expect(moving.action == .pause)
        #expect(moving.fraction == 0.3)
        #expect(moving.takesMenuBarLabel)
        #expect(status(.stopping).action == .open)
        #expect(status(.stopped).action == .resume)
        #expect(status(.stopped, google: false).action == .open)
        #expect(status(.failed).action == .open)
    }

    @Test func finishedRunResumesOnlyWhenItemsRemain() {
        #expect(status(.finished, uploaded: 5, existing: 2).action == .open)
        let partial = status(.finished, uploaded: 5, failed: 1, pending: 4)
        #expect(partial.action == .resume)
        #expect(partial.headline == "4 iCloud items remain")
        #expect(status(.finished, runtime: false, pending: 4).action == .open)
        #expect(!partial.takesMenuBarLabel)
    }
}
