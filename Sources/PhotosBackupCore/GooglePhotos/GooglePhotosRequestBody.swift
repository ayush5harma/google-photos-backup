import Foundation

/// The request bodies, field for field gpmc 0.9.0's (gpmc/api.py) and the
/// bridge's batched commit (Bridge/gpmc_bridge.py _commit_body). Pure, so
/// GooglePhotosGolden can hold each byte-equal to what gpmc encodes.
enum GooglePhotosRequestBody {
    typealias Wire = ProtobufWire

    /// gpmc's Api constants: an Android 9 Pixel XL running Photos 49029607.
    static let make = "Google"
    static let albumModel = "Pixel XL"
    static let androidAPIVersion: UInt64 = 28
    /// commit field 4.2; gpmc calls it unknown_int, the bridge
    /// _ESTIMATED_CAPTURE_NANOS.
    static let commitField4Unknown: UInt64 = 46_000_000

    /// The model and quality code a commit declares (gpmc Client._upload_file
    /// and the bridge's QUALITIES): Original commits as a Pixel XL at
    /// quality 3 and stays free, storage saver as a Pixel 2 at 1, and quota
    /// as a Pixel 8 at 3, which Google counts against the account's storage.
    static func profile(_ quality: UploadQuality) -> (model: String, quality: UInt64) {
        switch quality {
        case .original: ("Pixel XL", 3)
        case .saver: ("Pixel 2", 1)
        case .quota: ("Pixel 8", 3)
        }
    }

    static func device(model: String) -> Data {
        Wire.string(3, model) + Wire.string(4, make) + Wire.int(5, androidAPIVersion)
    }

    /// {"1": {"1": {"1": sha1}, "2": {}}}
    static func findRemoteMedia(sha1: Data) -> Data {
        Wire.bytes(1, Wire.bytes(1, Wire.bytes(1, sha1)) + Wire.bytes(2, Data()))
    }

    /// gpmc's get_download_urls: {"1": {"1": {"1": key}}, "2": {"1": {"7": {"2": {}}},
    /// "5": {"2": {}, "3": {}, "5": {"1": {}, "3": 0}}}}, in its field order.
    static func downloadURLs(mediaKey: String) -> Data {
        let options = Wire.bytes(1, Wire.bytes(7, Wire.bytes(2, Data())))
            + Wire.bytes(5, Wire.bytes(2, Data()) + Wire.bytes(3, Data()) + Wire.bytes(5, Wire.bytes(1, Data()) + Wire.int(3, 0)))
        return Wire.bytes(1, Wire.bytes(1, Wire.string(1, mediaKey))) + Wire.bytes(2, options)
    }

    /// {"1": 2, "2": 2, "3": 1, "4": 3, "7": size}
    static func uploadStart(size: Int64) -> Data {
        Wire.int(1, 2) + Wire.int(2, 2) + Wire.int(3, 1) + Wire.int(4, 3) + Wire.int(7, signed: size)
    }

    /// One commit item: receipt, name, hash, {timestamp, 46000000}, quality, 10: 1.
    static func commitItem(_ file: UploadedFile, quality: UInt64) -> Data {
        let stamp = Int64(file.timestamp.timeIntervalSince1970.rounded(.towardZero))
        return Wire.bytes(1, file.receipt)
            + Wire.string(2, file.fileName)
            + Wire.bytes(3, file.sha1)
            + Wire.bytes(4, Wire.int(1, signed: stamp) + Wire.int(2, commitField4Unknown))
            + Wire.int(7, quality)
            + Wire.int(10, 1)
    }

    /// gpmc's commit_upload for one file and the bridge's batch for several
    /// are one shape: field 1 repeated per item, one device, capabilities
    /// bytes [1, 3]. A batch of one is byte-equal to gpmc's single commit.
    static func commit(_ files: [UploadedFile], quality: UploadQuality) -> Data {
        let profile = profile(quality)
        let items = files.reduce(Data()) { $0 + Wire.bytes(1, commitItem($1, quality: profile.quality)) }
        return items + Wire.bytes(2, device(model: profile.model)) + Wire.bytes(3, Data([1, 3]))
    }

    /// gpmc's create_album; its timestamp is int(time.time()) at the call.
    static func createAlbum(name: String, mediaKeys: [String], now: Date) -> Data {
        let keys = mediaKeys.reduce(Data()) { $0 + Wire.bytes(4, Wire.bytes(1, Wire.string(1, $1))) }
        return Wire.string(1, name)
            + Wire.int(2, signed: seconds(now))
            + Wire.int(3, 1)
            + keys
            + Wire.bytes(6, Data())
            + Wire.bytes(7, Wire.int(1, 3))
            + Wire.bytes(8, device(model: albumModel))
    }

    /// gpmc's add_media_to_album.
    static func addMediaToAlbum(albumKey: String, mediaKeys: [String], now: Date) -> Data {
        mediaKeys.reduce(Data()) { $0 + Wire.string(1, $1) }
            + Wire.string(2, albumKey)
            + Wire.bytes(5, Wire.int(1, 2))
            + Wire.bytes(6, device(model: albumModel))
            + Wire.int(7, signed: seconds(now))
    }

    static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.towardZero))
    }
}
