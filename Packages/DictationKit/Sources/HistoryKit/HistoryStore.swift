import Foundation

public struct TranscriptRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let appBundleID: String?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), appBundleID: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.appBundleID = appBundleID
    }
}

/// Recent transcripts, newest first. In memory for now; moves to SQLite (GRDB) when
/// the history window lands (v0.2), keeping this interface.
public actor HistoryStore {
    public let capacity: Int
    private var records: [TranscriptRecord] = []

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    public func add(_ record: TranscriptRecord) {
        records.insert(record, at: 0)
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
    }

    public var latest: TranscriptRecord? { records.first }

    public var all: [TranscriptRecord] { records }
}
