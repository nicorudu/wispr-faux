import Foundation
import Testing
@testable import CleanupKit

@Suite("DisfluencyCues")
struct DisfluencyCueTests {
    @Test(arguments: [
        "and then dictate. I mean and then set dictate up for daily use.",
        "Can you send me the, um, the report?",
        "Uh I think so.",
        "The meeting is on Tuesday, no wait, Wednesday.",
        "Remind me to call Sarah. Actually, scratch that.",
        "So the the main problem is speed.",
        "We should, we should ship it.",
        "I was going to — never mind.",
        "Let me think...",
    ])
    func spotsStumbles(_ text: String) {
        #expect(DisfluencyCues.suggestCleanup(text))
    }

    @Test(arguments: [
        "Can you send me the quarterly report by Friday?",
        "Thanks so much for your help yesterday, it really made a difference.",
        "Summer and umbrella and erase are fine words.",
        "What time is the meeting tomorrow?",
    ])
    func leavesCleanTextAlone(_ text: String) {
        #expect(!DisfluencyCues.suggestCleanup(text))
    }
}

@Suite("CleanupGuard")
struct CleanupGuardTests {
    @Test func acceptsRemovalsAndPunctuation() {
        let original = "and then dictate. I mean and then set dictate up for daily use."
        let reply = "And then set Dictate up for daily use."
        #expect(CleanupGuard.review(original: original, reply: reply) == .accept(reply))
    }

    @Test func acceptsALongSelfCorrection() {
        let original = "Remind me to call Sarah tomorrow morning. Actually, scratch that, remind me to email her."
        #expect(CleanupGuard.review(original: original, reply: "Remind me to email her.") == .accept("Remind me to email her."))
    }

    @Test func acceptsNumberFormatting() {
        let original = "The price is fifty, sorry, fifteen dollars."
        #expect(CleanupGuard.review(original: original, reply: "The price is $15.") == .accept("The price is $15."))
    }

    /// The model answered the dictated question instead of cleaning it.
    @Test func rejectsAnAnswer() {
        let original = "Um, what time does the store close tomorrow?"
        #expect(CleanupGuard.review(original: original, reply: "Most stores close at 9 PM, but check their website.") == .reject(.newWords))
    }

    /// The model followed a dictated instruction.
    @Test func rejectsFollowedInstructions() {
        let original = "Uh, write a poem about the ocean."
        let poem = "The ocean breathes in silver light,\nits waves roll softly through the night."
        #expect(CleanupGuard.review(original: original, reply: poem) == .reject(.extraLines))
        #expect(CleanupGuard.review(original: original, reply: "Waves crash on the shore under a silver moon tonight again and again.") != .accept("Waves crash on the shore under a silver moon tonight again and again."))
    }

    @Test func rejectsRewordingThatGrows() {
        let original = "I think, um, we should go."
        #expect(CleanupGuard.review(original: original, reply: "In my opinion, I really do think that we should definitely go.") == .reject(.longer))
    }

    @Test func rejectsCollapsingToAlmostNothing() {
        let original = "So I spent most of the morning reviewing the design document for the new onboarding flow, um, today."
        #expect(CleanupGuard.review(original: original, reply: "Reviewed.") == .reject(.tooShort))
    }

    @Test func rejectsEmpty() {
        #expect(CleanupGuard.review(original: "Um, hi.", reply: "  ") == .reject(.empty))
    }

    @Test func stripsWrappers() {
        #expect(CleanupGuard.sanitize("Cleaned text: Send it today.") == "Send it today.")
        #expect(CleanupGuard.sanitize("“Send it today.”") == "Send it today.")
        #expect(CleanupGuard.sanitize("<think>\nThe user wants…\n</think>\n\nSend it today.") == "Send it today.")
        #expect(CleanupGuard.sanitize("Here's the cleaned text: Send it today.") == "Send it today.")
    }
}

/// Stands in for a model.
private struct FakeEngine: CleanupEngine {
    var name = "fake"
    var reply: String
    var delay: Duration = .zero
    var error: (any Error)?

    func complete(instructions: String, examples: [(dictated: String, cleaned: String)], text: String, maxTokens: Int) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return reply
    }
}

@Suite("TranscriptCleaner")
struct TranscriptCleanerTests {
    private let stumble = "Send it to Mark, I mean Mike."

    @Test func usesTheCleanedVersion() async {
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "Send it to Mike."))
        let outcome = await cleaner.clean(stumble)
        #expect(outcome.kind == .cleaned)
        #expect(outcome.text == "Send it to Mike.")
    }

    @Test func skipsCleanText() async {
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "SHOULD NOT BE USED"))
        let outcome = await cleaner.clean("Send it to Mike.")
        #expect(outcome.kind == .skipped)
        #expect(outcome.text == "Send it to Mike.")
    }

    @Test func keepsTheTranscriptWhenTheGuardRejects() async {
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "Sure! I've sent the file to Mike for you."))
        let outcome = await cleaner.clean(stumble)
        #expect(outcome.kind == .rejected(.newWords))
        #expect(outcome.text == stumble)
    }

    @Test func keepsTheTranscriptWhenTooSlow() async {
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "Send it to Mike.", delay: .seconds(5)), timeout: .milliseconds(100))
        let started = ContinuousClock.now
        let outcome = await cleaner.clean(stumble)
        #expect(outcome.kind == .timedOut)
        #expect(outcome.text == stumble)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func keepsTheTranscriptWhenTheEngineFails() async {
        struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "", error: Offline()))
        let outcome = await cleaner.clean(stumble)
        #expect(outcome.kind == .failed("offline"))
        #expect(outcome.text == stumble)
    }
}

@Suite("CloudEngine")
struct CloudEngineTests {
    @Test func requestCarriesThePromptExamplesAndTranscript() throws {
        let data = try CloudEngine.requestBody(
            provider: .glmFlash,
            instructions: "Clean it.",
            examples: [(dictated: "um hi", cleaned: "Hi.")],
            text: "uh bye",
            maxTokens: 40
        )
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "glm-4.7-flash")
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_tokens"] as? Int == 40)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")

        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(messages.map { $0["content"] } == ["Clean it.", "um hi", "Hi.", "uh bye"])
    }

    @Test func deepSeekSendsNoExtraFields() throws {
        let data = try CloudEngine.requestBody(provider: .deepSeek, instructions: "x", examples: [], text: "y", maxTokens: 8)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["thinking"] == nil)
        #expect(body["model"] as? String == "deepseek-chat")
    }

    @Test func readsTheReply() throws {
        let data = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Send it to Mike."}}]}"#.utf8)
        #expect(try CloudEngine.reply(in: data) == "Send it to Mike.")
        #expect(throws: CloudEngine.CloudError.unreadableReply) { try CloudEngine.reply(in: Data("{}".utf8)) }
    }

    @Test func readsErrorMessages() {
        #expect(CloudEngine.errorMessage(in: Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)) == "Invalid API key")
        #expect(CloudEngine.errorMessage(in: Data(#"{"message":"Rate limited"}"#.utf8)) == "Rate limited")
    }
}
