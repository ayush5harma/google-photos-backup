import Foundation
import PhotosBackupCore
import Testing

struct ICloudProtocolTests {
    @Test func requestKeepsCredentialsInStdinPayload() throws {
        let request = ICloudRequest(command: .backup, account: "someone@example.test",
                                    stateDir: "/private/state", stagingDir: "/private/staging",
                                    authData: "synthetic-google-token")
        let data = try request.encoded()
        #expect(data.last == UInt8(ascii: "\n"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "backup")
        #expect(object["state_dir"] as? String == "/private/state")
        #expect(object["staging_dir"] as? String == "/private/staging")
        #expect(object["auth_data"] as? String == "synthetic-google-token")
        #expect(object["password"] == nil)
    }

    @Test func authenticationAndResumeEvents() {
        #expect(decode(#"{"type":"auth","v":1,"status":"needs_2fa","account":"someone@example.test"}"#) == .auth(.needs2FA))
        #expect(decode(#"{"type":"auth","v":1,"status":"signed_out"}"#) == .auth(.signedOut))
        #expect(decode(#"{"type":"progress","v":1,"completed":4,"total":10,"uploaded":2}"#) == .progress(completed: 4, total: 10))
        #expect(decode(#"{"type":"done","v":1,"uploaded":2,"existing":1,"failed":1,"pending":6}"#)
                == .done(uploaded: 2, existing: 1, failed: 1, pending: 6))
    }

    @Test func privateFailureDetailsDoNotBecomeDisplayEvents() {
        let event = decode(#"{"type":"fatal","v":1,"kind":"auth","message":"private account and path"}"#)
        #expect(event == .failure(kind: "auth"))
        #expect(decode(#"{"type":"item_failed","id":"private-photo-name","code":"upload_failed"}"#) == .itemFailed)
    }

    @Test func freshSignInIsSavedOnlyAfterConfirmation() {
        var state = ICloudAccountState(confirmedAccount: nil)
        #expect(!state.hasSavedSession)
        state.beginSignIn("new@example.test")
        #expect(state.selectedAccount == "new@example.test")
        #expect(state.confirmedAccount == nil)
        #expect(state.pendingAccount == "new@example.test")
        #expect(state.confirmSignIn() == "new@example.test")
        #expect(state.hasSavedSession)
    }

    @Test func failedSecondSignInKeepsLastConfirmedSession() {
        var state = ICloudAccountState(confirmedAccount: "saved@example.test")
        state.beginAnotherAccount()
        #expect(state.confirmedAccount == "saved@example.test")
        state.beginSignIn("other@example.test")
        #expect(state.selectedAccount == "other@example.test")
        #expect(state.confirmedAccount == "saved@example.test")
        #expect(state.useSavedSession() == "saved@example.test")
        #expect(state.selectedAccount == "saved@example.test")
        state.beginSignIn("other@example.test")
        #expect(state.confirmSignIn() == "other@example.test")
    }

    private func decode(_ line: String) -> ICloudEvent? { ICloudEvent.decode(Data(line.utf8)) }
}
