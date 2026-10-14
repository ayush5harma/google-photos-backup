import Foundation
import Testing
@testable import PhotosBackupCore

private let redactor = Redactor(homeDirectory: "/Users/ann")

@Suite struct RedactorTests {
    @Test func masterTokensAreRemoved() {
        let text = "auth failed for aas_et/AKppINa1B2c3-_xyz.9== at android.clients.google.com"
        #expect(redactor.redact(text) == "auth failed for aas_et/<redacted> at android.clients.google.com")
        #expect(redactor.redact("Token=aas_et%2FAKpp%3D%3D&x=1") == "Token=<redacted>&x=1")
    }

    @Test func oauthAndBearerTokensAreRemoved() {
        #expect(redactor.redact("cookie oauth2_4/0AeaYSHA-b_c.d") == "cookie oauth2_4/<redacted>")
        #expect(redactor.redact("got ya29.a0AfB_byC-xyz.123 back") == "got ya29.<redacted> back")
        #expect(redactor.redact("Authorization: Bearer abc.DEF-123") == "Authorization: Bearer <redacted>")
    }

    @Test func authDataFieldsAreRemovedButHarmlessOnesKept() {
        let authData = "androidId=3a1f9c&app=com.google.android.apps.photos&client_sig=38918a45&Email=ann.lee%40gmail.com&Token=secret-value&lang=en_US"
        let redacted = redactor.redact(authData)
        #expect(!redacted.contains("secret-value"))
        #expect(!redacted.contains("3a1f9c"))
        #expect(!redacted.contains("ann.lee"))
        #expect(redacted.contains("Token=<redacted>"))
        #expect(redacted.contains("client_sig=38918a45"))
        #expect(redacted.contains("Email=a***@gmail.com"))
        #expect(redactor.redact("Auth=xyz\nExpiry=1700000000") == "Auth=<redacted>\nExpiry=1700000000")
    }

    @Test func emailAddressesKeepTheirFirstLetterAndDomain() {
        #expect(redactor.redact("Connected john.smith+photos@gmail.com") == "Connected j***@gmail.com")
        #expect(redactor.redact("a@b.co and Zed@example.org.") == "a***@b.co and Z***@example.org.")
        #expect(Redactor.maskEmail("jane@example.com") == "j***@example.com")
        // Percent-encoded, as in auth_data: nothing of the local part survives.
        #expect(redactor.redact("Email=john%2Bwork%40example.com&x=1") == "Email=j***@example.com&x=1")
        #expect(redactor.redact("john.doe%2Bphotos%2Etag@gmail.com") == "j***@gmail.com")
    }

    @Test func phoneNumbersAreMaskedButOtherNumbersAreNot() {
        #expect(redactor.redact("from +1 (415) 555-0123 today") == "from [phone ending 23] today")
        #expect(redactor.redact("tel:+919876543210") == "tel:[phone ending 10]")
        #expect(redactor.redact("call 415-555-0199") == "call [phone ending 99]")
        let ordinary = "2026-10-14T10:00:00Z uploaded 1234567890 bytes, media key AF1QipN123456789, 3 of 20, gpmc 0.9.0"
        #expect(redactor.redact(ordinary) == ordinary)
    }

    @Test(arguments: [
        ("call +91 98765 43210 now", "call [phone ending 10] now"),
        ("call 9876543210 now", "call [phone ending 10] now"),
        ("call 98765 43210 now", "call [phone ending 10] now"),
        ("call (555) 123-4567 now", "call [phone ending 67] now"),
        ("call 555-123-4567 now", "call [phone ending 67] now"),
        ("call 555.123.4567.", "call [phone ending 67]."),
    ])
    func commonPhoneFormatsAreMasked(text: String, expected: String) {
        #expect(redactor.redact(text) == expected)
    }

    @Test(arguments: [
        "Backed up 1,234 of 5,678 items in 2026",
        "uploaded 8589934592 bytes and 123456789 bytes",
        "took 00:05:30, 1h 23m, 95 s",
        "epoch 1700000000 at 2026-10-14T10:00:00+05:30",
        "media key AF1QipN98765432109xyz, exit 3, attempt 2 of 3, HTTP 503",
        "version 0.9.0, 12.5 MB, 3.13.15, 100 of 2000",
    ])
    func ordinaryNumbersAreLeftAlone(text: String) {
        #expect(redactor.redact(text) == text)
    }

    @Test func stagingPathsLoseTheirFileNames() {
        let staged = "/Users/ann/Library/Caches/io.github.x/Staging/0F8E5D7A-1B2C-4D3E-8F90-A1B2C3D4E5F6/0/Passport scan.jpg"
        #expect(redactor.redact("[Errno 2] No such file or directory: '\(staged)'")
            == "[Errno 2] No such file or directory: '<staging>/…'")
        #expect(redactor.redact("could not read \(staged): permission denied") == "could not read <staging>/…: permission denied")
    }

    @Test func homeFolderPathsBecomeTilde() {
        #expect(redactor.redact("It is in /Users/ann. Then /Users/ann!") == "It is in ~. Then ~!")
        #expect(redactor.redact("log at /Users/ann/Library/Logs/x.log") == "log at ~/Library/Logs/x.log")
        #expect(redactor.redact("home is /Users/ann") == "home is ~")
        // Another folder that merely starts with the same name is left alone.
        #expect(redactor.redact("/Users/anne/x") == "/Users/anne/x")
    }

    @Test func uploadURLsLoseTheirSessionID() {
        let message = "503 Server Error: Service Unavailable for url: https://photos.googleapis.com/data/upload/uploadmedia/interactive?upload_id=AEnB2Uo&x=1"
        #expect(redactor.redact(message).hasSuffix("interactive?upload_id=<redacted>&x=1"))
    }
}

@Suite struct EventLogTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func event(_ secondsAgo: TimeInterval, problem: Bool = false, _ message: String = "x") -> EventRecord {
        EventRecord(date: now.addingTimeInterval(-secondsAgo), category: .run, message: message, isProblem: problem)
    }

    @Test func everyWriteIsRedacted() {
        var log = EventLog(now: now)
        log.append(event(0, "Connected ann@gmail.com with Token=abc from /Users/ann/x"), redactor: redactor, now: now)
        #expect(log.events.first?.message == "Connected a***@gmail.com with Token=<redacted> from ~/x")
    }

    @Test func newestFirstAndLongMessagesShortened() {
        var log = EventLog(now: now)
        log.append(event(10, "older"), redactor: redactor, now: now)
        log.append(event(0, String(repeating: "y", count: 2000)), redactor: redactor, now: now)
        log.append(event(5, "middle"), redactor: redactor, now: now)
        #expect(log.events.map(\.message.count) == [EventLog.messageLimit, 6, 5])
        #expect(log.events[0].message.hasSuffix("..."))
    }

    @Test func nothingOlderThanFourteenDays() {
        let day: TimeInterval = 24 * 60 * 60
        let log = EventLog(events: [event(13 * day), event(15 * day, problem: true), event(0)], now: now)
        #expect(log.events.count == 2)
        var later = log
        later.append(event(0), redactor: redactor, now: now.addingTimeInterval(2 * day))
        #expect(later.events.count == 2)
    }

    @Test func atMostFourHundredAndProblemsOutliveRoutineLines() {
        var log = EventLog(now: now)
        // The oldest five are problems, the rest routine.
        for second in (0..<405).reversed() {
            log.append(event(TimeInterval(second), problem: second >= 400), redactor: redactor, now: now)
        }
        #expect(log.events.count == 400)
        #expect(log.events.filter { $0.isProblem }.count == 5)
        #expect(log.events.first?.date == now)

        // A log of nothing but problems still stops at the limit, oldest out.
        var problems = EventLog(now: now)
        for second in (0..<410).reversed() { problems.append(event(TimeInterval(second), problem: true), redactor: redactor, now: now) }
        #expect(problems.events.count == 400)
        #expect(problems.events.last?.date == now.addingTimeInterval(-399))
    }
}
