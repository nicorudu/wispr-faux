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
}

@Suite("Synthetic events")
struct SyntheticEventTests {
    @Test func inserterTagsMatchTheTapFilter() {
        #expect(TextInserter.eventTag == syntheticEventTag)
    }
}
