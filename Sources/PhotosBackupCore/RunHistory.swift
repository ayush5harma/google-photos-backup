import Foundation

/// The last runs, newest first, for the Activity history and the report.
public struct RunHistory: Codable, Equatable, Sendable {
    public static let limit = 40

    public private(set) var runs: [RunRecord]

    public init(runs: [RunRecord] = []) {
        self.runs = Self.trimmed(runs.sorted { $0.startedAt > $1.startedAt })
    }

    public mutating func add(_ run: RunRecord) {
        var runs = runs.filter { $0.id != run.id }
        let index = runs.firstIndex { $0.startedAt <= run.startedAt } ?? runs.endIndex
        runs.insert(run, at: index)
        self.runs = Self.trimmed(runs)
    }

    /// Past the limit the oldest run a person started goes first, as on
    /// iOS: automatic runs are what a diagnosis needs (did the timer fire,
    /// did conditions hold it), while a person remembers their own runs.
    /// Before either, the oldest run that found nothing to do: the timer
    /// fires every 30 minutes, and forty of those would push out every run
    /// that did something within a day. The newest run always stays, so a
    /// run that just ended is visible.
    static func trimmed(_ newestFirst: [RunRecord]) -> [RunRecord] {
        var runs = newestFirst
        while runs.count > limit {
            let older = runs.indices.dropFirst()
            if let oldestIdle = older.last(where: { runs[$0].isIdle }) {
                runs.remove(at: oldestIdle)
            } else if let oldestManual = older.last(where: { !runs[$0].trigger.isAutomatic }) {
                runs.remove(at: oldestManual)
            } else {
                runs.removeLast()
            }
        }
        return runs
    }

    public init(from decoder: Decoder) throws {
        self.init(runs: try decoder.singleValueContainer().decode([RunRecord].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(runs)
    }
}

extension RunRecord {
    /// Completed with nothing uploaded, found or failed.
    public var isIdle: Bool {
        outcome == .completed && uploaded == 0 && existing == 0 && failed == 0
    }
}

/// One JSON file holding one value, written atomically. A file that no
/// longer decodes (a crash in an older version, a hand edit) is moved aside
/// as `<name>.unreadable` for inspection and the value starts empty: history
/// and the timeline are worth less than an app that starts.
public struct RecordStore<Value: Codable & Sendable>: Sendable {
    public enum Loaded: Sendable {
        case missing
        case loaded(Value)
        /// The file was unreadable and now lies at `setAside`.
        case unreadable(setAside: URL, error: String)
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var setAsideURL: URL { url.appendingPathExtension("unreadable") }

    public func load() -> Loaded {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return .missing }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(Value.self, from: Data(contentsOf: url)))
        } catch {
            try? files.removeItem(at: setAsideURL)
            try? files.moveItem(at: url, to: setAsideURL)
            return .unreadable(setAside: setAsideURL, error: error.localizedDescription)
        }
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
