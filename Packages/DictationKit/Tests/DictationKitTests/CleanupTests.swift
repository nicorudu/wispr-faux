import Foundation
import PostProcessKit
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
        "Tell them it's bad, don't say bad, say it isn't ready.",
        "Order three pizzas, make that four.",
    ])
    func spotsStumbles(_ text: String) {
        #expect(DisfluencyCues.suggestCleanup(text))
    }

    @Test(arguments: [
        "Can you send me the quarterly report by Friday?",
        "Thanks so much for your help yesterday, it really made a difference.",
        "Summer and umbrella and erase are fine words.",
        "What time is the meeting tomorrow?",
        "Can you make that happen by Friday?",
    ])
    func leavesCleanTextAlone(_ text: String) {
        #expect(!DisfluencyCues.suggestCleanup(text))
    }
}

@Suite("FormattingCues")
struct FormattingCueTests {
    @Test(arguments: [
        "Here are three things we need for the launch first a landing page second three demo videos and third a press release.",
        "Number one we ship the beta, number two we collect feedback.",
        "There are two main reasons we should wait.",
        "Firstly the budget, secondly the timeline.",
    ])
    func spotsLists(_ text: String) {
        #expect(FormattingCues.suggestFormatting(text))
    }

    @Test(arguments: [
        "Hey Sarah hope your week is going well quick question did you review the Q4 deck thanks.",
        "Hi Tom, the contract looks good to me. Talk soon.",
        "Dear Ms. Lee, please find the report attached. Thank you so much.",
        "hello team the build is green again cheers Alex",
    ])
    func spotsEmails(_ text: String) {
        #expect(FormattingCues.suggestFormatting(text))
    }

    @Test(arguments: [
        "First of all, thanks for coming in today.",
        "Hey, are you free for lunch?",
        "Thanks for the help, I'll take it from here and let you know how it goes.",
        "These are things we should discuss later.",
        "Can you send me the quarterly report by Friday?",
    ])
    func leavesPlainTextAlone(_ text: String) {
        #expect(!FormattingCues.suggestFormatting(text))
    }
}

@Suite("CleanupPrompt")
struct CleanupPromptTests {
    @Test func plainStumblesGetNoLayoutRules() {
        let prompt = CleanupPrompt(for: "Send it to Mark, I mean Mike.")
        #expect(!prompt.instructions.contains("line"))
        #expect(!prompt.examples.contains { $0.cleaned.contains("\n") })
    }

    @Test func plainStumblesGetOnlyTheBasicExamples() {
        let prompt = CleanupPrompt(for: "Send it to Mark, I mean Mike.")
        #expect(prompt.examples.count == CleanupPrompt.cleanups.count + CleanupPrompt.traps.count)
    }

    @Test func longerCorrectionsGetTheirRuleAndExample() {
        let scratch = CleanupPrompt(for: "Can we meet Tuesday? Scratch that, let's do Thursday.")
        #expect(scratch.instructions.contains("\"scratch that\" takes back"))
        #expect(scratch.examples.contains { $0 == CleanupPrompt.scratchExample })
        #expect(!scratch.examples.contains { $0 == CleanupPrompt.dontSayExample })

        let dontSay = CleanupPrompt(for: "Say it was terrible, actually don’t say terrible, say rough.")
        #expect(dontSay.instructions.contains("\"don't say X, say Y\""))
        #expect(dontSay.examples.contains { $0 == CleanupPrompt.dontSayExample })
    }

    @Test func listsGetTheListRuleAndExample() {
        let prompt = CleanupPrompt(for: "We need three things first milk second eggs and third bread.")
        #expect(prompt.instructions.contains("lists laid out"))
        #expect(!prompt.instructions.contains("emails laid out"))
        #expect(prompt.examples.contains { $0.cleaned.contains("\n1. ") })
    }

    @Test func emailsGetTheEmailRuleAndExample() {
        let prompt = CleanupPrompt(for: "Hey Sarah quick question did you see the deck thanks.")
        #expect(prompt.instructions.contains("emails laid out"))
        #expect(!prompt.instructions.contains("lists laid out"))
        #expect(prompt.examples.contains { $0.cleaned.contains("\n\n") })
    }

    /// The traps come last, closest to the transcript, whatever else is added.
    @Test func trapsComeLast() {
        let prompt = CleanupPrompt(for: "Hey Sarah, two things first the deck second the budget, thanks.")
        #expect(prompt.examples.suffix(CleanupPrompt.traps.count).map(\.dictated) == CleanupPrompt.traps.map(\.dictated))
    }
}

@Suite("EmailLayout")
struct EmailLayoutTests {
    @Test func layOutAnEmailLeftOnOneLine() {
        let cleaned = "Hey Sarah, hope your week is going well. Quick question: did you get a chance to review the Q4 deck? If not, no worries. Just let me know by tomorrow. Thanks."
        #expect(EmailLayout.apply(to: cleaned) == """
            Hey Sarah,

            Hope your week is going well. Quick question: did you get a chance to review the Q4 deck? If not, no worries. Just let me know by tomorrow.

            Thanks.
            """)
        #expect(WordErrorRate.words(EmailLayout.apply(to: cleaned)) == WordErrorRate.words(cleaned))
    }

    @Test func handlesOtherGreetingsAndSignOffs() {
        #expect(EmailLayout.apply(to: "Hi team. The build is green again. The release is on for Thursday, cheers, Alex.")
            == "Hi team,\n\nThe build is green again. The release is on for Thursday.\n\nCheers, Alex.")
        #expect(EmailLayout.apply(to: "Dear Dr. Lee: please find the report attached. Let me know if anything is missing. Thank you so much!")
            == "Dear Dr. Lee,\n\nPlease find the report attached. Let me know if anything is missing.\n\nThank you so much!")
    }

    @Test(arguments: [
        // No name: a quick message, not an email.
        "Hey, can you grab some milk on your way home? Thanks.",
        // A one-sentence message.
        "Hey Sarah, are you free tonight? Thanks.",
        // The greeting isn't punctuated, so where the name ends is unclear.
        "Hey Sarah hope your week is going well. Did you see the deck? Thanks.",
        // No sign-off at the end.
        "Hey Sarah, hope your week is going well. Did you see the deck? Talk to you later about it.",
        // Already laid out.
        "Hey Sarah,\n\nHope your week is going well. Did you see the deck?\n\nThanks!",
    ])
    func leavesOtherTextAlone(_ text: String) {
        #expect(EmailLayout.apply(to: text) == text)
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
        #expect(CleanupGuard.review(original: original, reply: poem) == .reject(.longer))
        #expect(CleanupGuard.review(original: original, reply: "Waves crash on the shore under a silver moon tonight again and again.") != .accept("Waves crash on the shore under a silver moon tonight again and again."))
    }

    @Test func acceptsANumberedList() {
        let original = "Here are three things we need for the launch first a landing page second three demo videos and third a press release ready by Friday."
        let reply = """
            Here are three things we need for the launch:
            1. A landing page
            2. Three demo videos
            3. A press release ready by Friday
            """
        #expect(CleanupGuard.review(original: original, reply: reply) == .accept(reply))
        let bullets = reply.replacingOccurrences(of: #"\d\. "#, with: "- ", options: .regularExpression)
        #expect(CleanupGuard.review(original: original, reply: bullets) == .accept(bullets))
    }

    @Test func acceptsAnEmailLayout() {
        let original = "Hey Sarah hope your week is going well quick question did you get a chance to review the Q4 deck thanks."
        let reply = "Hey Sarah,\n\nHope your week is going well. Quick question: did you get a chance to review the Q4 deck?\n\nThanks!"
        #expect(CleanupGuard.review(original: original, reply: reply) == .accept(reply))
    }

    /// Layout is free; words still aren't, even inside a list.
    @Test func rejectsNewWordsInAList() {
        let original = "We need three things first a landing page second demo videos and third a press release."
        let reply = """
            We need three things:
            1. A polished landing page
            2. Short demo videos
            3. A launch tweet
            """
        #expect(CleanupGuard.review(original: original, reply: reply) == .reject(.newWords))
    }

    /// Only a number or bullet that starts a line is layout; numbers inside a line are words.
    @Test func listMarkersOnlyCountAtTheStartOfALine() {
        #expect(CleanupGuard.withoutListMarkers("1. Ship it\n2) Test it\n- Done\n• Yes") == "Ship it\nTest it\nDone\nYes")
        #expect(CleanupGuard.withoutListMarkers("Room 12. Floor 3) here") == "Room 12. Floor 3) here")
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

    @Test func tidiesLayout() {
        #expect(CleanupGuard.sanitize("Hi Tom,  \r\n\n\n\nThanks!\n") == "Hi Tom,\n\nThanks!")
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

    @Test func cleansAListWithoutAStumble() async {
        let list = "We have two goals first hire a designer and second cut onboarding time."
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "We have two goals:\n1. Hire a designer\n2. Cut onboarding time"))
        let outcome = await cleaner.clean(list)
        #expect(outcome.kind == .cleaned)
        #expect(outcome.text == "We have two goals:\n1. Hire a designer\n2. Cut onboarding time")
    }

    @Test func laysOutAnEmailTheModelLeftOnOneLine() async {
        let email = "Hey Sarah hope your week is going well did you see the deck if not no worries thanks"
        let cleaner = TranscriptCleaner(engine: FakeEngine(reply: "Hey Sarah, hope your week is going well. Did you see the deck? If not, no worries. Thanks!"))
        let outcome = await cleaner.clean(email)
        #expect(outcome.kind == .cleaned)
        #expect(outcome.text == "Hey Sarah,\n\nHope your week is going well. Did you see the deck? If not, no worries.\n\nThanks!")
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
