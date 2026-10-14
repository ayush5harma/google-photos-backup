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
        #expect(decode(#"{"type":"auth","v":1,"status":"needs_2fa","account":"someone@example.test"}"#)
                == .auth(.needs2FA, phones: [], deviceCodeAvailable: true))
        #expect(decode(#"{"type":"auth","v":1,"status":"signed_out"}"#)
                == .auth(.signedOut, phones: [], deviceCodeAvailable: true))
        #expect(decode(#"{"type":"progress","v":1,"completed":4,"total":10,"uploaded":2}"#) == .progress(completed: 4, total: 10))
        #expect(decode(#"{"type":"done","v":1,"uploaded":2,"existing":1,"failed":1,"pending":6}"#)
                == .done(uploaded: 2, existing: 1, failed: 1, pending: 6))
    }

    @Test func phoneOnlyChallengeRequestsSMSBeforeVerification() throws {
        let event = decode(#"{"type":"auth","v":1,"status":"needs_2fa","device_code_available":false,"phones":[{"id":17,"label":"***1234"}]}"#)
        #expect(event == .auth(.needs2FA, phones: [ICloudTrustedPhone(id: 17, label: "***1234")], deviceCodeAvailable: false))

        var choice = ICloudVerificationState()
        choice.receiveChallenge(phones: [ICloudTrustedPhone(id: 17, label: "***1234")], deviceCodeAvailable: false)
        #expect(!choice.canVerify)
        let unknownPhoneAccepted = choice.sendSMS(to: 99)
        #expect(!unknownPhoneAccepted)
        let selectedPhoneAccepted = choice.sendSMS(to: 17)
        #expect(selectedPhoneAccepted)
        #expect(choice.canVerify)
        let send = ICloudRequest(command: .sendCode, account: "someone@example.test", stateDir: "/private/state",
                                 password: "synthetic-password", phoneID: 17)
        let sendObject = try #require(JSONSerialization.jsonObject(with: send.encoded()) as? [String: Any])
        #expect(sendObject["command"] as? String == "send-code")
        #expect(sendObject["phone_id"] as? Int == 17)
        #expect(sendObject["password"] as? String == "synthetic-password")

        let verify = ICloudRequest(command: .verify2FA, account: "someone@example.test", stateDir: "/private/state",
                                   password: "synthetic-password", code: "123456", phoneID: choice.selectedSMSPhoneID)
        let verifyObject = try #require(JSONSerialization.jsonObject(with: verify.encoded()) as? [String: Any])
        #expect(verifyObject["phone_id"] as? Int == 17)
        #expect(verifyObject["code"] as? String == "123456")
        choice.choosePhone()
        #expect(!choice.canVerify)
    }

    @Test func deviceCodeNeedsNoPhoneIDAndCanReplaceSMSChoice() throws {
        var choice = ICloudVerificationState()
        choice.receiveChallenge(phones: [ICloudTrustedPhone(id: 3, label: "***9876")], deviceCodeAvailable: true)
        #expect(choice.canVerify)
        let selectedPhoneAccepted = choice.sendSMS(to: 3)
        #expect(selectedPhoneAccepted)
        choice.chooseDeviceCode()
        #expect(choice.selectedSMSPhoneID == nil)
        #expect(choice.canVerify)
        let request = ICloudRequest(command: .verify2FA, account: "someone@example.test", stateDir: "/private/state",
                                    password: "synthetic-password", code: "654321", phoneID: choice.selectedSMSPhoneID)
        let object = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(object["phone_id"] == nil)
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
