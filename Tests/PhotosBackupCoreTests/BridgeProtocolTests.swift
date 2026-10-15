import Foundation
import Testing
@testable import PhotosBackupCore

private func event(_ json: String) throws -> BridgeEvent {
    try BridgeEvent.decode(Data(json.utf8))
}

@Suite struct BridgeEventTests {
    // These lines are verbatim what Bridge/gpmc_bridge.py emits.
    @Test func decodesEveryEventTheBridgeEmits() throws {
        #expect(try event(#"{"type":"version","v":1,"protocol":1,"gpmc":"0.9.0","python":"3.13.15"}"#)
            == .version(protocolVersion: 1, gpmc: "0.9.0", python: "3.13.15"))
        #expect(try event(#"{"type":"auth","v":1,"email":"someone@example.com"}"#) == .auth(email: "someone@example.com"))
        #expect(try event(#"{"type":"progress","v":1,"id":"A/L0/001","phase":"uploading","bytes_completed":5,"bytes_total":10}"#)
            == .progress(id: "A/L0/001", phase: .uploading, completed: 5, total: 10))
        #expect(try event(#"{"type":"item","v":1,"id":"A","media_key":"k","status":"existing"}"#) == .item(id: "A", mediaKey: "k", existing: true))
        #expect(try event(#"{"type":"item","v":1,"id":"A","media_key":"k","status":"uploaded"}"#) == .item(id: "A", mediaKey: "k", existing: false))
        #expect(try event(#"{"type":"verified","v":1,"id":"A","media_key":"k","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":12}"#)
            == .verified(id: "A", mediaKey: "k", sha256: String(repeating: "a", count: 64), bytes: 12))
        #expect(try event(#"{"type":"item_failed","v":1,"id":"A","message":"413","retryable":false}"#)
            == .itemFailed(id: "A", message: "413", retryable: false))
        #expect(try event(#"{"type":"item_failed","v":1,"id":"A","message":"503","retryable":true}"#)
            == .itemFailed(id: "A", message: "503", retryable: true))
        #expect(try event(#"{"type":"fatal","v":1,"kind":"rate_limit","message":"429"}"#) == .fatal(kind: .rateLimit, message: "429"))
        #expect(try event(#"{"type":"fatal","v":1,"kind":"storage_full","message":"full"}"#) == .fatal(kind: .storageFull, message: "full"))
        #expect(try event(#"{"type":"album","v":1,"album_id":"g","added":2}"#) == .album(id: "g", added: 2))
        #expect(try event(#"{"type":"album_failed","v":1,"message":"500"}"#) == .albumFailed(message: "500"))
        #expect(try event(#"{"type":"done","v":1,"uploaded":1,"existing":1,"failed":0}"#) == .done(uploaded: 1, existing: 1, failed: 0))
        #expect(try event(#"{"type":"fatal","v":1,"kind":"auth","message":"403"}"#) == .fatal(kind: .auth, message: "403"))
        #expect(try event(#"{"type":"stopped","v":1}"#) == .stopped)
    }

    @Test func readsItemFailuresFromABridgeWithoutTheRetryableField() throws {
        // What the bridge sent before the field existed: still a failure,
        // with no opinion on retrying (the engine reads the message instead).
        #expect(try event(#"{"type":"item_failed","v":1,"id":"A","message":"413"}"#) == .itemFailed(id: "A", message: "413", retryable: nil))
        #expect(try event(#"{"type":"item_failed","v":1,"id":"A","message":"x","retryable":"yes"}"#) == .itemFailed(id: "A", message: "x", retryable: nil))
    }

    @Test func toleratesWhatANewerBridgeMightSay() throws {
        #expect(try event(#"{"type":"progress","v":1,"id":null,"phase":"teleporting"}"#) == .progress(id: nil, phase: .unknown, completed: 0, total: 0))
        #expect(try event(#"{"type":"fatal","v":1,"kind":"cosmic","message":"x"}"#) == .fatal(kind: .unknown, message: "x"))
        #expect(try event(#"{"type":"hello","v":2}"#) == .unknown(type: "hello"))
    }

    @Test func rejectsLinesThatAreNotEvents() {
        #expect(throws: BridgeEvent.DecodingError.self) { try event("INFO gpmc said something") }
        #expect(throws: BridgeEvent.DecodingError.self) { try event(#"{"type":"item","v":1}"#) }
    }
}

@Suite struct BridgeRequestTests {
    @Test func uploadRequestUsesTheBridgeFieldNames() throws {
        let request = BridgeRequest.upload("auth", items: [BridgeItem(id: "A", path: "/s/1/IMG.HEIC", filename: "IMG.HEIC")],
                                           quality: .original, threads: 2, album: AlbumTarget(id: nil, name: "Trip"))
        let json = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(json["command"] as? String == "upload")
        #expect(json["auth_data"] as? String == "auth")
        #expect(json["quality"] as? String == "original")
        #expect(json["threads"] as? Int == 2)
        #expect((json["album"] as? [String: String]) == ["name": "Trip"])
        #expect((json["items"] as? [[String: String]]) == [["id": "A", "path": "/s/1/IMG.HEIC", "filename": "IMG.HEIC"]])
        #expect(json["media_keys"] == nil)
    }

    @Test func addToAlbumCarriesMediaKeys() throws {
        let request = BridgeRequest.addToAlbum("auth", mediaKeys: ["k1"], album: AlbumTarget(id: "g", name: "Trip"))
        let json = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(json["command"] as? String == "add-to-album")
        #expect((json["media_keys"] as? [String]) == ["k1"])
        #expect(json["items"] == nil)
    }

    @Test func verificationRequestCarriesAnImmutableExpectedFingerprint() throws {
        let request = BridgeRequest.verifyOriginal("auth", items: [
            OriginalVerificationItem(id: "device:1", path: "/private/staging/one.heic", mediaKey: "key",
                                     expectedSHA256: String(repeating: "b", count: 64), expectedBytes: 42),
        ])
        let json = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(json["command"] as? String == "verify-original")
        let item = try #require((json["items"] as? [[String: Any]])?.first)
        #expect(item["media_key"] as? String == "key")
        #expect(item["expected_sha256"] as? String == String(repeating: "b", count: 64))
        #expect(item["expected_bytes"] as? Int == 42)
    }
}

@Suite struct LineSplitterTests {
    @Test func reassemblesLinesAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data(#"{"a":1}"#.utf8) + Data("\n{\"b\"".utf8)) == [Data(#"{"a":1}"#.utf8)])
        #expect(splitter.append(Data(":2}\n\n".utf8)) == [Data(#"{"b":2}"#.utf8)])
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.finish() == Data("tail".utf8))
        #expect(splitter.finish() == nil)
    }
}
