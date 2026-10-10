import Foundation
import Testing
@testable import PhotosBackupCore

private func fields(_ form: String) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = form.replacingOccurrences(of: "+", with: "%20")
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Suite struct GoogleSignInTests {
    @Test func cookieValueIsAcceptedWithOrWithoutItsName() throws {
        let token = "oauth2_4/0AbCdEfGhIjKlMnOpQrStUv"
        #expect(try GoogleSignIn.normalizedOAuthToken(token) == token)
        #expect(try GoogleSignIn.normalizedOAuthToken("  oauth_token=\(token)\n") == token)
        #expect(throws: GoogleSignIn.Failure.self) { try GoogleSignIn.normalizedOAuthToken("short") }
        #expect(throws: GoogleSignIn.Failure.self) { try GoogleSignIn.normalizedOAuthToken("oauth2_4/abc\ndefghijklmnopq") }
    }

    @Test func exchangeCarriesTheTokenAsPlayServicesWould() {
        let form = GoogleSignIn.exchangeForm(oauthToken: "oauth2_4/0A+b/c", androidID: "0123456789abcdef")
        let sent = fields(form)
        #expect(sent["Token"] == "oauth2_4/0A+b/c")
        #expect(sent["service"] == "ac2dm")
        #expect(sent["ACCESS_TOKEN"] == "1")
        #expect(sent["add_account"] == "1")
        #expect(sent["androidId"] == "0123456789abcdef")
        #expect(sent["client_sig"] == "38918a453d07199354f8b19af05ec6562ced5788")
        // '+' and '/' in the token must survive the form encoding.
        #expect(form.contains("Token=oauth2_4%2F0A%2Bb%2Fc"))
    }

    @Test func parsesTheAccountGoogleReturns() throws {
        let body = "Token=aas_et/AKppINa\nAuth=x\nEmail=someone@gmail.com\nservices=mail\n"
        #expect(try GoogleSignIn.parseExchange(body) == GoogleSignIn.Account(email: "someone@gmail.com", masterToken: "aas_et/AKppINa"))
    }

    @Test(arguments: [
        ("Error=BadAuthentication\n", "each sign-in works only once"),
        ("Error=NeedsBrowser\n", "browser"),
        ("Error=Bizarre\n", "Bizarre"),
        ("Email=someone@gmail.com\n", "no account token"),
        ("Token=aas_et/x\nEmail=not an address\n", "no account address"),
    ])
    func refusalsSayWhatWentWrong(body: String, phrase: String) {
        do {
            _ = try GoogleSignIn.parseExchange(body)
            Issue.record("expected a failure for \(body)")
        } catch {
            #expect(error.localizedDescription.contains(phrase))
        }
    }

    @Test func credentialIsWhatGpmcReads() {
        let account = GoogleSignIn.Account(email: "some.one+tag@gmail.com", masterToken: "aas_et/AK+pp/IN==")
        let credential = GoogleSignIn.credential(for: account, androidID: "0123456789abcdef")
        let sent = fields(credential)
        // Every field gpmc 0.9.0's Api._get_auth_token reads.
        for key in ["androidId", "app", "client_sig", "callerSig", "device_country", "Email", "google_play_services_version",
                    "lang", "oauth2_foreground", "sdk_version", "service", "Token"] {
            #expect(sent[key] != nil, "missing \(key)")
        }
        #expect(sent["Token"] == "aas_et/AK+pp/IN==")
        #expect(sent["Email"] == "some.one+tag@gmail.com")
        #expect(sent["service"] == "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native")
        #expect(sent["app"] == "com.google.android.apps.photos")
        // gpmc finds the address and language by scanning for the first pair
        // containing "Email" / "lang"; byte order puts the real ones first.
        #expect(credential.hasPrefix("Email=some.one%2Btag%40gmail.com&Token="))
        #expect(GoogleSignIn.looksLikeAuthData(credential))
    }

    @Test func tellsAPastedCredentialFromACookie() {
        #expect(GoogleSignIn.looksLikeAuthData("androidId=1&app=x&Email=a%40b.c&Token=aas_et%2Fx"))
        #expect(!GoogleSignIn.looksLikeAuthData("oauth2_4/0AbCdEfGhIjKlMnOp"))
    }

    @Test func readsTheAddressOutOfACredential() {
        let credential = GoogleSignIn.credential(for: .init(email: "some.one+tag@gmail.com", masterToken: "aas_et/x"), androidID: "0123456789abcdef")
        #expect(GoogleSignIn.email(inCredential: credential) == "some.one+tag@gmail.com")
        // An Android-captured auth_data, in its own field order.
        #expect(GoogleSignIn.email(inCredential: "androidId=1&app=x&Email=me%40example.com&Token=aas_et%2Fx") == "me@example.com")
        #expect(GoogleSignIn.email(inCredential: "androidId=1&Token=x") == nil)
    }

    @Test func gmailAliasesAreOneAccount() {
        #expect(GoogleSignIn.sameAccount("John.Smith@gmail.com", "johnsmith@googlemail.com"))
        #expect(GoogleSignIn.sameAccount("Me@Example.com", "me@example.com"))
        #expect(!GoogleSignIn.sameAccount("john.smith@example.com", "johnsmith@example.com"))
        #expect(!GoogleSignIn.sameAccount("a@gmail.com", "b@gmail.com"))
    }

    @Test func androidIDsAreSixteenHexDigitsAndFresh() {
        let id = GoogleSignIn.newAndroidID()
        #expect(id.count == 16 && id.allSatisfy(\.isHexDigit))
        #expect(id != GoogleSignIn.newAndroidID())
    }
}

@Suite struct AccountStateTests {
    private func backedUp(by email: String?) -> BackupState {
        var state = BackupState()
        state.selectedAlbumIDs = ["all-photos"]
        state.accountEmail = email
        state.recordUpload(assetID: "a", mediaKey: "k", existing: false)
        state.recordAlbum("trip", googleAlbumID: "g", added: ["a"])
        return state
    }

    @Test func anotherAccountStartsFromNothingButTheSelection() {
        let adopted = backedUp(by: "old@gmail.com").adopting(account: "new@gmail.com")
        #expect(adopted.uploaded.isEmpty)
        #expect(adopted.mirrors.isEmpty)
        #expect(adopted.selectedAlbumIDs == ["all-photos"])
        #expect(adopted.accountEmail == "new@gmail.com")
    }

    @Test func theSameAccountKeepsItsHistory() {
        let state = backedUp(by: "Me@Gmail.com")
        #expect(state.adopting(account: "me@gmail.com").uploaded == state.uploaded)
        #expect(state.adopting(account: "m.e@googlemail.com").uploaded == state.uploaded)
        // History from before accounts were tracked is assumed to be this one.
        #expect(backedUp(by: nil).adopting(account: "me@gmail.com").uploaded.count == 1)
    }

    @Test func stateWrittenBeforeAccountsDecodes() throws {
        let json = #"{"mirrors":{},"selectedAlbumIDs":["all-photos"],"uploaded":{}}"#
        let state = try JSONDecoder().decode(BackupState.self, from: Data(json.utf8))
        #expect(state.accountEmail == nil)
        #expect(state.selectedAlbumIDs == ["all-photos"])
    }
}
