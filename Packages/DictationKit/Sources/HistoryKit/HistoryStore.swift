import Foundation

public struct TranscriptRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let appBundleID: String?
    /// The app the text was meant for, e.g. "Slack".
    public let appName: String?
    /// The transcript as spoken, when cleanup changed it.
    public let original: String?

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        appBundleID: String? = nil,
        appName: String? = nil,
        original: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.appBundleID = appBundleID
        self.appName = appName
        self.original = original
    }
}

/// Recent transcripts, newest first, capped at `capacity`. With a `fileURL` the list is
/// kept in a JSON file readable only by the user, loaded at start and saved on every
/// change; without one it lives in memory (tests). No audio is ever stored.
public actor HistoryStore {
    public let capacity: Int
    public nonisolated let fileURL: URL?
    private var records: [TranscriptRecord]

    public init(capacity: Int, fileURL: URL? = nil) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.fileURL = fileURL
        records = Array((fileURL.flatMap(Self.load) ?? []).prefix(capacity))
    }

    public func add(_ record: TranscriptRecord) {
        records.insert(record, at: 0)
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
        save()
    }

    public func removeAll() {
        records.removeAll()
        save()
    }

    public var latest: TranscriptRecord? { records.first }

    public var all: [TranscriptRecord] { records }

    // MARK: - File

    /// A missing or unreadable file starts an empty history rather than failing.
    private static func load(from url: URL) -> [TranscriptRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([TranscriptRecord].self, from: data)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
            // Transcripts can be private: only this user may read them.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // History is a convenience; a failed save never blocks dictation.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
