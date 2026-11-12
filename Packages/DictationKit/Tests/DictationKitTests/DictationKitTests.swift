import Foundation
import Testing
import HistoryKit
import HotkeyKit
import InsertionKit
import PostProcessKit

@Suite("TextCleaner")
struct TextCleanerTests {
    @Test func trimsSurroundingWhitespace() {
        #expect(TextCleaner().clean("  hello world \n") == "hello world")
    }

    @Test func appliesLongestReplacementFirst() {
        let cleaner = TextCleaner(replacements: ["dictate": "Dictate", "dictate app": "the Dictate app"])
        #expect(cleaner.clean("I love dictate app") == "I love the Dictate app")
    }

    @Test(arguments: ["", "  ", "Thank you.", " you ", "[BLANK_AUDIO]"])
    func flagsSilenceArtifacts(_ transcript: String) {
        #expect(TextCleaner.isLikelySilenceArtifact(transcript))
    }

    @Test func keepsRealSpeech() {
        #expect(!TextCleaner.isLikelySilenceArtifact("Thank you for the update."))
    }
}

@Suite("TextCleaner spacing and markers")
struct TextCleanerMarkerTests {
    @Test func nonSpeechMarkers() {
        #expect(TextCleaner.isNonSpeechMarker("[BLANK_AUDIO]"))
        #expect(TextCleaner.isNonSpeechMarker(" (silence) "))
        #expect(TextCleaner.isNonSpeechMarker("[Music]"))
        #expect(!TextCleaner.isNonSpeechMarker("Call me (maybe) later."))
        #expect(!TextCleaner.isNonSpeechMarker("Thank you."))
        #expect(!TextCleaner.isNonSpeechMarker(""))
    }

    @Test func leadingSpace() {
        #expect(TextCleaner.needsLeadingSpace(after: "."))
        #expect(TextCleaner.needsLeadingSpace(after: "d"))
        #expect(TextCleaner.needsLeadingSpace(after: ","))
        #expect(!TextCleaner.needsLeadingSpace(after: nil))
        #expect(!TextCleaner.needsLeadingSpace(after: " "))
        #expect(!TextCleaner.needsLeadingSpace(after: "\n"))
        #expect(!TextCleaner.needsLeadingSpace(after: "("))
        #expect(!TextCleaner.needsLeadingSpace(after: "“"))
    }
}

@Suite("HistoryStore")
struct HistoryStoreTests {
    @Test func keepsNewestFirstWithinCapacity() async {
        let store = HistoryStore(capacity: 2)
        await store.add(TranscriptRecord(text: "one"))
        await store.add(TranscriptRecord(text: "two"))
        await store.add(TranscriptRecord(text: "three"))

        #expect(await store.all.map(\.text) == ["three", "two"])
        #expect(await store.latest?.text == "three")
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "wisprfaux-history-\(UUID().uuidString)/history.json")
    }

    @Test func survivesARestart() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let first = HistoryStore(capacity: 3, fileURL: file)
        await first.add(TranscriptRecord(text: "café ✓", appBundleID: "com.apple.TextEdit", appName: "TextEdit"))
        await first.add(TranscriptRecord(text: "second"))

        let reopened = HistoryStore(capacity: 3, fileURL: file)
        #expect(await reopened.all.map(\.text) == ["second", "café ✓"])
        #expect(await reopened.all.last?.appName == "TextEdit")

        // Only the user can read it.
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        await reopened.removeAll()
        #expect(await HistoryStore(capacity: 3, fileURL: file).all.isEmpty)
    }

    @Test func aSmallerCapacityTrimsOnLoad() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(capacity: 5, fileURL: file)
        for text in ["a", "b", "c"] { await store.add(TranscriptRecord(text: text)) }
        #expect(await HistoryStore(capacity: 2, fileURL: file).all.map(\.text) == ["c", "b"])
    }

    @Test func anUnreadableFileStartsEmpty() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(await HistoryStore(capacity: 3, fileURL: file).all.isEmpty)
    }
}

@Suite("Synthetic events")
struct SyntheticEventTests {
    @Test func inserterTagsMatchTheTapFilter() {
        #expect(TextInserter.eventTag == syntheticEventTag)
    }
}
