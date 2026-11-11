import Observation
import HistoryKit

/// Owns the dictation state machine (BUILD_PLAN.md §2):
///
///     idle ─hotkey down─▶ recording ─hotkey up─▶ transcribing ─▶ inserting ─▶ idle
///
/// Step 1 only holds the state. Hotkey (Step 2), insertion (Step 3), audio (Step 4)
/// and transcription (Step 5) get wired in here in Step 6.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case inserting

        var label: String {
            switch self {
            case .idle: "Idle"
            case .recording: "Listening…"
            case .transcribing: "Transcribing…"
            case .inserting: "Inserting…"
            }
        }

        var menuBarSymbol: String {
            switch self {
            case .idle: "mic"
            case .recording: "mic.fill"
            case .transcribing, .inserting: "ellipsis.circle"
            }
        }
    }

    private(set) var state: State = .idle

    /// Recent transcripts; backs "Paste Last Transcript".
    let history = HistoryStore(capacity: 100)
}
