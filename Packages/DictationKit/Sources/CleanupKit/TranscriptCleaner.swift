import Foundation

/// Something that runs the cleanup prompt: a model on this Mac or a cloud API.
public protocol CleanupEngine: Sendable {
    /// Shown in logs and settings, e.g. "GLM-4.7-Flash (Z.ai)".
    var name: String { get }

    /// Sends the instructions, the worked examples and the transcript, and returns the
    /// model's reply as-is (the guard checks it).
    func complete(
        instructions: String,
        examples: [(dictated: String, cleaned: String)],
        text: String,
        maxTokens: Int
    ) async throws -> String
}

/// What happened to one transcript.
public struct CleanupOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The model's version was used.
        case cleaned
        /// No sign of a stumble, a list or an email, so the model wasn't asked.
        case skipped
        /// The model's reply failed the guard; the transcript was kept.
        case rejected(CleanupGuard.Reason)
        /// No reply in time; the transcript was kept.
        case timedOut
        /// The engine failed (network, model); the transcript was kept.
        case failed(String)
    }

    /// What to paste.
    public var text: String
    public var kind: Kind
    public var duration: Duration

    public var changedText: Bool { kind == .cleaned }
}

/// Runs a transcript through an engine, but only when it shows a stumble or reads as a
/// list or an email, within a time limit, and through `CleanupGuard`. Whatever goes
/// wrong, the transcript comes back unchanged, so cleanup can never lose or garble a
/// dictation.
public struct TranscriptCleaner: Sendable {
    public let engine: any CleanupEngine
    public var timeout: Duration
    /// Ask the model even when `shouldClean` says no (for benchmarks).
    public var alwaysRun: Bool

    public init(engine: any CleanupEngine, timeout: Duration = .seconds(3), alwaysRun: Bool = false) {
        self.engine = engine
        self.timeout = timeout
        self.alwaysRun = alwaysRun
    }

    public func clean(_ transcript: String) async -> CleanupOutcome {
        let started = ContinuousClock.now
        func outcome(_ text: String, _ kind: CleanupOutcome.Kind) -> CleanupOutcome {
            CleanupOutcome(text: text, kind: kind, duration: .now - started)
        }

        guard alwaysRun || Self.shouldClean(transcript) else {
            return outcome(transcript, .skipped)
        }
        // Cleanup only shortens text: room for the whole transcript, plus punctuation,
        // line breaks and list numbers.
        let maxTokens = WordCount.of(transcript) * 2 + 32
        let prompt = CleanupPrompt(for: transcript)

        let reply: String?
        do {
            reply = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    try await engine.complete(
                        instructions: prompt.instructions,
                        examples: prompt.examples,
                        text: transcript,
                        maxTokens: maxTokens
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            return outcome(transcript, .failed(error.localizedDescription))
        }

        guard let reply else { return outcome(transcript, .timedOut) }
        switch CleanupGuard.review(original: transcript, reply: reply) {
        case .accept(let cleaned):
            let laidOut = FormattingCues.looksLikeEmail(transcript) ? EmailLayout.apply(to: cleaned) : cleaned
            return outcome(laidOut, .cleaned)
        case .reject(let reason):
            return outcome(transcript, .rejected(reason))
        }
    }
}

extension TranscriptCleaner {
    /// Whether a transcript is worth sending to the model: it shows a stumble, or reads as
    /// a list or an email that could be laid out.
    public static func shouldClean(_ transcript: String) -> Bool {
        DisfluencyCues.suggestCleanup(transcript) || FormattingCues.suggestFormatting(transcript)
    }
}

enum WordCount {
    static func of(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
