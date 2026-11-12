# Dictation App — Build Plan

*Project name: **Wispr Faux** (working codename was Dictate). Written 2026-11-11 from a static teardown of Wispr Flow 1.6.1457 (app.asar + Swift helper), done with REA.*

A push-to-talk dictation app for macOS: hold a key, speak, release, and clean text appears in whatever text field has focus.

> **Originality note.** The teardown is for understanding the mechanics only. This project uses its own code, name, UI and assets. It does not reuse Wispr's code, endpoints, keys or branding.

---

## 0. Decisions (recommended defaults — change before Step 1 if needed)

| Decision | Recommendation | Why |
|---|---|---|
| Platform | **macOS only**, Apple Silicon, **macOS 14+** | Your machine is an M4 on macOS 15.1. All the hard parts are macOS-native. |
| Stack | **Native Swift 6 + SwiftUI/AppKit, single process** | Wispr runs Electron *plus* a Swift helper over a stdin/fd-3 pipe. They need Electron for Windows and a web UI; an MVP doesn't. One process means no IPC, a small binary and simpler debugging. |
| Speech-to-text | **On-device: WhisperKit** (Swift package, Core ML). whisper.cpp is the backup option. | No backend, no API keys, works offline, private. Wispr streams audio to a cloud gRPC service; a cloud engine can be added later behind the same protocol. |
| Transcription mode | **Batch on key release** (MVP) | Simple and good enough for utterances under ~30 s. Streaming comes later. |
| Text cleanup | MVP: rules only. Phase 2: **Claude** (see §6) | Wispr has the server return both `asr_text` (raw) and `llm_text` (formatted). |
| Distribution | **Developer ID, notarized, not sandboxed, not the Mac App Store** | Active event taps, Accessibility reads and synthetic Cmd+V don't work in the sandbox. Wispr's helper ships with *no entitlements*, i.e. unsandboxed. |
| Storage | SQLite via **GRDB** for history; **Keychain** for any API keys | |

---

## 1. Teardown → design decisions

| Area | What Wispr Flow does (observed) | What we build |
|---|---|---|
| **Process model** | Electron main process ↔ Swift helper. JSON over stdin; replies on fd 3 (`fdopen(3,"w")`, unbuffered). | A single Swift app. Keep a thin internal command layer anyway, so a UI shell could be split off later. |
| **Hotkey** | **Active** `CGEventTap` at the session tap, head-insert. Mask `0x6001C00` = keyDown, keyUp, flagsChanged, otherMouseDown/Up. Fn = keycode **63** via flagsChanged. Matched keys are **swallowed** (callback returns NULL). Re-enables the tap after timeout/user-input disable. Logs a metric if the callback takes over 250 ms. | Same. |
| **Default shortcuts** | Hold Fn = push-to-talk. Fn+Space = hands-free lock. Esc = cancel. Ctrl+Cmd+V = paste last. Ctrl+Cmd+C = copy last. | Same set, user-configurable. |
| **External keyboards** | "Found an external non-Apple keyboard. Assuming no Fn key available." There's an IOHID fallback behind a flag. | A configurable fallback hotkey (e.g. hold Right Option). |
| **Audio** | Hidden renderer: `getUserMedia` → AudioWorklet → **16 kHz mono**, 640-sample (40 ms) Int16 chunks, or WebCodecs Opus at 64 kbps / 20 ms. | `AVAudioEngine` input tap → `AVAudioConverter` → 16 kHz mono Float32 in memory. |
| **Transcription** | Cloud: gRPC `flow_api.v1.TranscriptionService/TranscribeStream` (duplex), plus an HTTP fallback. Sends app/textbox/vocabulary context. | On-device WhisperKit, batch, behind a `Transcriber` protocol. |
| **Context** | The helper reads the focused field through Accessibility: `AXFocusedUIElement`, `AXValue`, `AXSelectedTextRange`, before/after text, `isEditable`, `AXSecureTextField`. | MVP: `isEditable` + secure-field check only. Later: send context to the LLM. |
| **Insertion** | 1. Back up every pasteboard type (skipping file contents, PDF, RTFD and sound). 2. `clearContents`. 3. Write HTML + plain string. 4. Wait 10 ms and verify `changeCount` changed. 5. Send **Cmd+V** via `CGEventPost`, with V looked up for the current keyboard layout (`UCKeyTranslate`, fallback keycode 9) and 5 ms between down and up. 6. Warn if keys are still held. 7. **Restore the clipboard after 500 ms.** | Same algorithm. |
| **Not editable** | Shows a "void dictation" notice and copies the text to the clipboard. | Same. |

---

## 2. Architecture

```
┌─────────────────────────── Wispr Faux.app (single process) ──────────────────────────┐
│                                                                                      │
│  HotkeyKit ──events──▶ DictationController (actor, state machine) ◀── Settings/Prefs │
│  (CGEventTap thread)        │        │          │          │                         │
│                             ▼        ▼          ▼          ▼                         │
│                        AudioKit  Transcriber  PostProcess  InsertionKit ──▶ Cmd+V    │
│                       (AVAudio-  (WhisperKit) (rules →     (pasteboard   into the    │
│                        Engine)                 Claude v0.3) snapshot/     focused app│
│                             │                              restore)                  │
│                             ▼                                   ▲                    │
│                       StatusPill (non-activating NSPanel)   ContextKit (AX reads)    │
│                       MenuBarExtra · Onboarding · History (GRDB)                     │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Modules (local Swift package `DictationKit`, one target each so they can be unit-tested)

- **HotkeyKit**
  - `EventTapMonitor`: tap on its own thread with its own CFRunLoop; tap watchdog.
  - `ShortcutMatcher`: tracks held keys and matches combos.
  - Fn handling, and tagging of our own synthetic events.
- **AudioKit**
  - `MicrophoneRecorder`: AVAudioEngine plus conversion to 16 kHz mono.
  - Level meter.
  - Silence and short-press gate.
- **TranscriptionKit**
  - `protocol Transcriber { func transcribe(_ pcm16k: [Float]) async throws -> String }`
  - `WhisperKitTranscriber` now; `CloudTranscriber` later.
- **PostProcessKit**
  - Trim, fix capitalization at the start, strip known silence junk, apply user replacements.
  - `ClaudeFormatter` comes in v0.3.
- **ContextKit**
  - `FocusedFieldReader`: AX focused element, editable or secure, before/after text later.
- **InsertionKit**
  - `PasteboardSnapshot`, `TextInserter`.
  - `KeyboardLayout`: finds the keycode for "v".
  - `KeyPoster`: synthetic Cmd+V, Tab and Enter, tagged.
- **HistoryKit**
  - GRDB store for recent transcripts; powers "paste last".
- **App target**
  - `DictationController`, `StatusPill`, `MenuBarExtra`, onboarding and permissions, settings.
  - Launch at login via `SMAppService.mainApp`.

### State machine (`DictationController`)

```
idle ──hotkey down──▶ recording ──hotkey up──▶ transcribing ──▶ inserting ──▶ idle
                        │  ▲                        │                │
           Fn+Space ────┘  │ (locked/hands-free;    ├─ error ────────┴──▶ idle (+ notice)
                           │  hotkey again = stop)  │
               Esc ────────┴────────────────────────┴──▶ cancelled ──▶ idle (nothing pasted)
```

Two guards:
- **Taps shorter than ~250 ms** count as accidental: discard, no transcription.
- **A maximum recording length** (e.g. 5 min) with a warning near the limit. Wispr has the same pair of warning/timeout constants.

### Threading rules

- **Event tap callback:** O(1) work only. Read the keycode and flags, decide whether to swallow, and push an event into an `AsyncStream`. Never block; macOS disables slow taps.
- **Audio render thread:** append samples to a preallocated buffer, with no locks or allocation in the hot path.
- **Transcription:** a background `Task`. Load the model once at launch to pre-warm it.
- **Insertion:** serialized on the main actor (pasteboard + `CGEventPost`).

---

## 3. MVP scope (v0.1)

**In:**
- Hold-to-talk on **Fn**, a configurable fallback hotkey, **Esc** to cancel.
- Fn+Space hands-free lock (small extra once hold-to-talk works).
- On-device transcription with WhisperKit; a model picker in Settings (speed vs accuracy).
- Rule-based cleanup.
- Paste into the focused field with full clipboard backup and restore.
- Not editable or secure field → copy to clipboard + notification, no paste.
- Status pill: listening / processing, live level meter. **It must never take focus.**
- Menu bar item: paste last transcript, copy last transcript, open history, settings, quit.
- Onboarding for Microphone, Accessibility and Input Monitoring, with live status checks.
- Local history (last 100 transcripts); no audio stored by default.

**Out (later):**
- LLM formatting, command mode (voice-edit selected text).
- Streaming partial results, cloud engine.
- Custom vocabulary, per-app styles.
- Accounts, sync, analytics, Windows, meeting notes, Bluetooth device integrations.

**Definition of done (manual test matrix):**
- [ ] Hold Fn → speak → release inserts text in: **TextEdit, Notes, Safari textarea, Chrome textarea, Slack, VS Code, Terminal, Mail**.
- [ ] Clipboard is identical before and after (test with copied text **and** a copied image).
- [ ] Pressing Fn doesn't open the emoji / input-source picker (with the documented System Settings change, §5 gotcha 4).
- [ ] The fallback hotkey works on an external non-Apple keyboard.
- [ ] Esc mid-recording pastes nothing.
- [ ] Focused password field → no paste, notice shown.
- [ ] Your own synthetic Cmd+V never triggers your own shortcuts.
- [ ] Release-to-paste latency measured and logged for 5 s and 15 s utterances. Target: under 1 s for a 5 s utterance on the M4; confirm in Step 5.

---

## 4. Roadmap

| Version | Adds |
|---|---|
| **v0.1** | MVP above |
| **v0.2** | History window; custom dictionary/replacements; custom vocabulary as a Whisper prompt; start/stop sounds; launch at login; mic picker; per-app opt-out list |
| **v0.3** | **Claude cleanup** (§6): punctuation, filler removal, lists, tone per app. Command mode: select text, hold a hotkey, speak an instruction, the selection is replaced. Uses AX before/after context. |
| **v0.4** | Streaming partial results in the pill; optional cloud speech-to-text engine; `{{TAB}}`/`{{BREAK}}`-style multi-field insertion (Wispr pastes sections and presses Tab between them) |
| **later** | Windows port (`WH_KEYBOARD_LL` hook, `SendInput` Ctrl+V, UI Automation for context), which mirrors Wispr's separate Windows helper |

---

## 5. Gotchas to design for (from the teardown and macOS behaviour)

1. **Permissions are tied to code signature.**
   - Accessibility / Input Monitoring grants attach to bundle ID + signing identity.
   - Ad-hoc-signed dev builds can lose them on every rebuild. Sign dev builds with your **Apple Development** team from day one.
   - If stuck: `tccutil reset Accessibility <bundle-id>`.
2. **Tap disabled by timeout.**
   - Handle `.tapDisabledByTimeout` / `.tapDisabledByUserInput` by calling `CGEvent.tapEnable(tap:enable:true)`.
   - Keep the callback tiny.
3. **Secure Event Input.**
   - When another app turns it on (password fields, some terminals), keyboard taps may stop seeing keystrokes.
   - Check `IsSecureEventInputEnabled()` and show a hint in the pill.
4. **The Fn/Globe key is shared with the OS.**
   - Onboarding should tell users to set *System Settings → Keyboard → "Press 🌐 key to" → Do Nothing*, and to check that macOS Dictation's shortcut isn't on Fn.
   - Also swallow matched Fn events in the tap.
5. **Focus stealing.**
   - The pill must be an `NSPanel` with `.nonactivatingPanel` that never becomes key.
   - Otherwise Cmd+V lands in your own app.
6. **Clipboard restore timing.**
   - Restoring too early makes the target app paste the *old* clipboard. Wispr waits **500 ms**.
   - Skip the restore if `changeCount` moved after your write (the user copied something meanwhile).
   - Optionally add the `org.nspasteboard.TransientType` / `ConcealedType` markers (nspasteboard.org convention) so clipboard managers ignore the temporary write.
7. **Keyboard layouts.**
   - Find V's keycode for the current layout (`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`); fall back to `kVK_ANSI_V` (9).
   - Otherwise Dvorak/AZERTY users get the wrong shortcut.
8. **Your own synthetic events.**
   - Tag posted events with `eventSourceUserData` and ignore tagged events in the tap.
9. **Whisper invents text on silence or very short audio** (e.g. a lone "Thank you.").
   - Gate on RMS level and duration before transcribing; drop known junk outputs.
10. **Mic start latency** can clip the first syllable.
    - Start the engine on key-down immediately and measure.
    - Don't keep the mic always-on: it shows the orange privacy dot. Wispr starts on press too.
11. **Bluetooth headsets.** Opening an AirPods mic switches them to the lower-quality call profile. Prefer the built-in mic by default and expose a mic picker.

---

## 6. Phase-2 Claude cleanup (v0.3) — API shape

Swift has no official Anthropic SDK, so call the Messages API over HTTP with `URLSession`.

```
POST https://api.anthropic.com/v1/messages
x-api-key: <from Keychain>
anthropic-version: 2026-10-21
anthropic-beta: server-side-fallback-2026-07-01
content-type: application/json
```

```json
{
  "model": "claude-opus-5-5",
  "max_tokens": 4096,
  "output_config": { "effort": "low" },
  "fallbacks": "default",
  "system": [
    { "type": "text",
      "text": "You clean up dictated text. Fix punctuation and capitalization, remove filler words and false starts, keep the speaker's wording and language. Output only the cleaned text.",
      "cache_control": { "type": "ephemeral" } }
  ],
  "messages": [
    { "role": "user", "content": "<raw transcript>" }
  ]
}
```

**Model**
- `claude-opus-5-5` is the default.
- `effort: "low"` keeps this short rewrite fast; thinking is always on for this model and is controlled only through effort.
- If latency or cost matters more than quality here, `claude-haiku-5-5` is the alternative. That's your call; measure both on your own transcripts.

**Request rules**
- Don't send `temperature`/`top_p`: they return a 400 on API version 2026-10-21.
- Don't prefill an assistant turn.
- `fallbacks: "default"` + the beta header lets the server retry on another model if the request is declined.

**Never block the user's text**
- Wrap the call in a ~2–3 s timeout.
- On timeout, any error, or `stop_reason == "refusal"`, **paste the raw transcript**.
- Read the text only from `content` blocks with `type == "text"`.

**Caching**
- Mark the stable system prompt with `cache_control`. It only actually caches once the prefix passes the model's minimum length, so check `usage.cache_read_input_tokens`.

**API keys**
- Personal use: the user pastes their own key; store it in the Keychain.
- If you distribute the app, **never ship a key in the binary**. Proxy through your own backend.

---

## 7. First steps

**Step 1 — Toolchain and skeleton (day 1)**
1. `xcode-select` points at the Command Line Tools, but Xcode is installed. Switch it (needs your password):
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. Create the app:
   - Xcode → macOS App (SwiftUI), name `WisprFaux` (display name "Wispr Faux"), bundle ID `com.<you>.wisprfaux`, signed with your Apple Development team.
   - Signing & Capabilities: **Hardened Runtime ON**, **App Sandbox OFF**.
   - Info: `LSUIElement = YES` (menu bar only); `NSMicrophoneUsageDescription`.
3. Add a local Swift package `Packages/DictationKit` with the targets from §2, then `git init`.

   ```
   WHISPER_CLONE/
   ├── BUILD_PLAN.md
   ├── rea/                       # existing REA checkout — not part of the app
   ├── WisprFaux.xcodeproj
   ├── WisprFaux/                 # app target (UI, controller, onboarding)
   └── Packages/DictationKit/     # HotkeyKit, AudioKit, TranscriptionKit, …
   ```

**Step 2 — Permissions + hotkey spike.** *Done when Fn down/up logs reliably, the tap survives a forced timeout, and Fn no longer opens the emoji picker.*

```swift
let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                      | (1 << CGEventType.keyUp.rawValue)
                      | (1 << CGEventType.flagsChanged.rawValue)
let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                            options: .defaultTap,            // active: can swallow events
                            eventsOfInterest: mask, callback: tapCallback,
                            userInfo: Unmanaged.passUnretained(self).toOpaque())
// In tapCallback:
//  - type == .tapDisabledByTimeout / .tapDisabledByUserInput → re-enable and return.
//  - if event.getIntegerValueField(.eventSourceUserData) == kSyntheticTag → pass through.
//  - type == .flagsChanged, keycode 63 → fnDown = event.flags.contains(.maskSecondaryFn);
//    send the event to the controller; return nil to swallow it.
```

Check permissions with `AXIsProcessTrustedWithOptions` (prompt), `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`, and `AVCaptureDevice.requestAccess(for: .audio)`.

**Step 3 — Paste spike.** *Done when a "Paste test string" menu item inserts text into every app in the §3 matrix and a copied image survives the round-trip.*

```swift
func postCommandV() {
    let v = KeyboardLayout.keyCode(for: "v") ?? 9               // layout-aware, fallback kVK_ANSI_V
    for keyDown in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: keyDown)
        e?.flags = .maskCommand
        e?.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)
        e?.post(tap: .cgSessionEventTap)
        if keyDown { usleep(5_000) }
    }
}
// Insert: snapshot all pasteboard items → clearContents → write string → usleep(10ms) and
// verify changeCount → postCommandV() → after 500 ms restore the snapshot (unless changeCount moved).
```

**Step 4 — Audio spike.** *Done when holding Fn records 16 kHz mono that plays back cleanly; write a temporary WAV for checking only.*

**Step 5 — Transcription.**
- Add the WhisperKit package and **pin a version**.
- Load the model at launch; transcribe the recorded buffer.
- Log load time, audio length and transcribe time.
- Try a small English model first, then a large "turbo" variant, and keep the best speed/accuracy trade-off on the M4.

**Step 6 — Wire it end to end.** `DictationController` state machine, status pill, Esc cancel, not-editable fallback, history, "paste last".

**Step 7 — Dogfood for a week** against the §3 matrix. Log every failure with app name, bundle ID and step. Fix, then start v0.2.

---

## Appendix — constants observed in the teardown

| Item | Value |
|---|---|
| Event tap | session tap (1), head insert (0), options 0 (active), mask `0x6001C00` |
| Fn | keycode 63 (`0x3F`), flag `maskSecondaryFn` (`0x800000`) |
| Other keycodes | Return 36, Tab 48 (`0x30`), V fallback 9 |
| Cmd flag | `0x100000` |
| Paste timings | key down→up 5 ms · after pasteboard write 10 ms · after Cmd+V 10 ms · restore after **500 ms** |
| Multi-section paste | 150 ms before Tab · 50 ms between sections |
| Tap callback | slow-handler metric over 250 ms |
| Audio | 16 kHz mono · 640-sample (40 ms) chunks · Opus 64 kbps / 20 ms frames |
| Skipped when backing up clipboard | file contents, PDF, RTFD, sound |
