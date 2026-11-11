# Dictate

Push-to-talk dictation for macOS: hold a key, speak, release, and the text appears in the focused app.
The roadmap, architecture and step-by-step plan are in [BUILD_PLAN.md](BUILD_PLAN.md).

**Status:** Step 2 (permissions + hotkey) done. Step 3 (paste spike) is built: *Paste Test String* in the menu pastes into the app in front and then puts the clipboard back. Checking it across the app matrix below is still to do. Step 4 (audio spike) done: holding the hotkey records 16 kHz mono that plays back cleanly (checked on a fifine USB mic), and the menu plays the last recording back. Transcription and wiring it all together come in Steps 5–6.

Dictate is a personal tool that runs entirely on this Mac: no accounts, no cloud, no network calls.

## Requirements

- macOS 14+ on Apple Silicon
- Xcode 16.2+ (`/Applications/Xcode.app`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Layout

```
project.yml                  XcodeGen spec (source of truth for Dictate.xcodeproj)
Dictate/                     App target: menu bar, settings, setup window, DictationController
Packages/DictationKit/       Core modules, each testable on its own
  HotkeyKit                  CGEventTap, shortcut matching, keycodes  (Step 2, done)
  InsertionKit               Clipboard backup/restore + Cmd+V         (Step 3, built)
  AudioKit                   AVAudioEngine → 16 kHz mono, levels, WAV (Step 4, built)
  TranscriptionKit           Transcriber protocol, WhisperKit engine  (Step 5)
  PostProcessKit             Rule-based transcript cleanup
  ContextKit                 Focused-field info via Accessibility     (Step 6)
  HistoryKit                 Recent transcripts
```

## Build and run

```bash
xcodegen generate
```

```bash
open Dictate.xcodeproj
```

Or build from the command line. `DEVELOPER_DIR` is needed while `xcode-select` points at the Command Line Tools:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dictate.xcodeproj -scheme Dictate -configuration Debug -derivedDataPath build build
```

```bash
open build/Build/Products/Debug/Dictate.app
```

## Tests

```bash
cd Packages/DictationKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Setup and hotkey

On first launch Dictate opens **Set Up Dictate** (also in the menu: *Finish Setup…* / *Permissions…*):

- **Microphone, Accessibility, Input Monitoring.** Each row updates live as you flip switches in System Settings. If the hotkey still says *relaunch needed* after granting Input Monitoring, click **Relaunch Dictate**.
- **Globe key** (only shown if Fn is turned on). Set *System Settings → Keyboard → “Press 🌐 key to”* to **Do Nothing**, or Fn also opens emoji / switches input source. The row reads the current setting.
- **Try it.** Hold Control: the dot lights up. Control+Space locks hands-free; press Control again to stop; Esc cancels.

Shortcuts:

| Gesture | Result |
|---|---|
| Hold Control (either side), release | Start / stop dictation |
| Control + Space | Hands-free: keeps listening after Control is released; press Control again to stop |
| Esc | Cancel (only swallowed while dictating) |
| Control + another key or a click (e.g. ⌃C, Ctrl-click) | Treated as a normal shortcut: dictation is cancelled and the key or click passes through |

Other keys: **Settings → Hold to talk** can switch on Fn (🌐), Right Option or Right Command, or limit Control to one side. Fn is swallowed so macOS doesn't act on it too; the others always reach apps, so they keep working as modifiers.

Watch hotkey events live:

```bash
log stream --style compact --predicate 'subsystem == "com.example.dictate"'
```

Debug builds add a **Debug** menu: *Simulate Event-Tap Timeout on Next Key* stalls the tap for 2.5 s on your next key press so macOS disables it; the log should then show it re-enabled, and the hotkey keeps working.

## Paste test (Step 3)

1. Copy something to check the clipboard survives: some text, or an image (e.g. select all in Preview and press ⌘C).
2. Click into a text field in the app you're testing.
3. Menu bar icon → **Paste Test String**. A line like `Dictate paste test 6:20:15 PM · café ✓` should appear.
4. Open the menu again. It shows how long the paste took and whether the clipboard came back, e.g. *Clipboard restored ✓ (image, 3 types, 1.2 MB)*. Press ⌘V somewhere to confirm.

Check each app: TextEdit, Notes, a Safari textarea, a Chrome textarea, Slack, VS Code, Terminal, Mail.

How it works (`InsertionKit`):

- Every item and type on the clipboard is backed up first. Unlike the teardown, PDF, RTFD and sound data are kept so the clipboard comes back identical; only file promises are skipped.
- The text goes on the clipboard marked `org.nspasteboard.TransientType`, so clipboard managers don't record it.
- ⌘V uses the key that types V with ⌘ held in the current layout (Dvorak, AZERTY, Dvorak – QWERTY ⌘), falling back to keycode 9.
- The clipboard is restored 500 ms later, unless something new was copied in the meantime. A second paste inside that window keeps the original backup.

The log (`log stream` command above) records each paste's timing and backup size. It never records clipboard contents.

## Recording test (Step 4)

1. Hold the hotkey (Control), say a sentence, release. The setup window's *Try it* row shows a live level bar while you hold.
2. Open the menu. It shows the last recording, e.g. *Last recording: 3.2 s · loudest −18 dBFS · would transcribe*, and the mic it came from with how long after the key press the first sample arrived.
3. **Play Last Recording** plays it back; **Show Recording in Finder** reveals the WAV.

Only the last recording is kept, as a 16 kHz mono 16-bit WAV in `$TMPDIR/Dictate/last-recording.wav`. It's overwritten on every recording and deleted when Dictate quits. Check it from Terminal:

```bash
afinfo "$TMPDIR/Dictate/last-recording.wav"
```

```bash
afplay "$TMPDIR/Dictate/last-recording.wav"
```

What the numbers mean:

- **Loudest** is the loudest 30 ms of the clip. Speech should reach roughly −30 to −10 dBFS. Around −55 dBFS or lower, the mic gain is too low: raise *System Settings → Sound → Input → Input volume* (and any gain knob on the mic). *⚠︎ clipped* means it's too high. If the level never moves when you talk, watch the *Input level* meter on that same Settings page: if it's flat too, the problem is the mic itself (mute button, gain knob, wrong side of the mic), not Dictate.
- **would transcribe / too short / too quiet** is the gate that will keep accidental taps and silence away from Whisper (Whisper invents text for silence). Under 250 ms, or a loudest 30 ms below −45 dBFS, is skipped. These thresholds are first guesses to tune with real recordings.
- **First sample N ms after the key** is how much of the start of your speech is lost. A new audio engine is built for each recording so the mic is only on while you hold the key; on the fifine USB mic that costs about 110–180 ms. Cutting this is a Step 6 job (e.g. keeping a prepared engine between recordings).

The log line for each recording also has the device format, tap buffer size, each input channel's peak before the mix to mono, and engine start time:

```bash
log stream --style compact --predicate 'subsystem == "com.example.dictate" AND category == "Audio"'
```

How it works (`AudioKit`):

- `MicrophoneRecorder` (an actor on its own queue) taps `AVAudioEngine`'s input node. It records only while the key is held: no always-on mic.
- `MonoResampler` turns whatever the device delivers into 16 kHz mono Float32. Multi-channel input is averaged to mono first; `AVAudioConverter`'s own downmix outputs silence for discrete channel layouts. Buffers stream through one converter, so there are no clicks at buffer boundaries.
- On release the mic stays on until the tap buffer covering the key-up arrives (usually well under 100 ms, at most 300 ms). Tap buffers come whole, 100 ms at a time on the fifine, so stopping straight away would cut off the end of the last word.
- A recording is capped at 5 minutes. If the input device changes mid-recording, what was captured so far is kept and the menu says so.
- Pressing the hotkey while the mic is unplugged or still reconnecting shows *Not recording: The microphone isn't available…* instead of crashing. AVAudioEngine reports some device problems as Objective-C exceptions, which Swift can't catch, so the engine setup runs inside a small `@try/@catch` shim (`ObjCExceptions` target).

Debug builds can record without the hotkey: *Debug → Record 3 Seconds Without the Hotkey*, or at launch:

```bash
open build/Build/Products/Debug/Dictate.app --args -DebugRecordSeconds 3
```

## Signing and permissions

- **Signing identity:** builds are signed with the Developer ID Application identity for team `FS3T7J3D7X` (set in `project.yml`). Keep the identity stable: macOS ties Accessibility and Input Monitoring grants to it.
- **Bundle ID:** `com.example.dictate` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` before granting permissions; grants are tied to the bundle ID too.
- **No sandbox:** the event tap, Accessibility reads and synthetic Cmd+V all need it off. Hardened Runtime is on, and the microphone entitlement is declared.
