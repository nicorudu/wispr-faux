# Wispr Faux

Push-to-talk dictation for macOS: hold a key, speak, release, and the text appears in the focused app.
The roadmap, architecture and step-by-step plan are in [BUILD_PLAN.md](BUILD_PLAN.md).

**Windows:** a C#/.NET version with the same features (hold Ctrl, whisper.cpp with Whisper large-v3 turbo, stumble cleanup on the PC or in the cloud, clipboard-safe paste, tray icon, open at sign-in) is in [windows/](windows/). Its [README](windows/README.md) has step-by-step install instructions.

**iPhone:** a keyboard with a hold-to-talk mic button, transcribing on the iPhone with the same Whisper model, is in [ios/](ios/) (written, not yet built). Its [README](ios/README.md) explains how it works and how to install it from Xcode.

**Status:** Steps 1–6 done: hold Control, speak, release, and the text is pasted into the focused app, transcribed on-device with Whisper large-v3 turbo. Stumbles ("Tuesday, no wait, Wednesday") are cleaned up by a small model on this Mac, or optionally a cloud model. Step 7 is under way: use it for a week and fix what comes up.

Wispr Faux is a personal tool that runs entirely on this Mac: no accounts, no cloud, no network calls (beyond model downloads and the optional cloud cleanup).

## Requirements

- macOS 14+ on Apple Silicon
- Xcode 16.2+ (`/Applications/Xcode.app`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Layout

```
project.yml                  XcodeGen spec (source of truth for WisprFaux.xcodeproj)
WisprFaux/                   App target: menu bar, settings, setup window, DictationController
  LaunchAgents/              Opens Wispr Faux at login and relaunches it after a crash
Packages/DictationKit/       Core modules, each testable on its own
  HotkeyKit                  CGEventTap, shortcut matching, keycodes  (Step 2, done)
  InsertionKit               Clipboard backup/restore + Cmd+V         (Step 3, done)
  AudioKit                   AVAudioEngine → 16 kHz mono, levels, WAV (Step 4, done)
  TranscriptionKit           Whisper on Core ML (WhisperKit 1.1.1)    (Step 5, done)
  WisprFauxBench             `wisprfaux-bench`: compares models on audio files
  PostProcessKit             Spacing, non-speech markers, word errors (Step 6, done)
  CleanupKit                 Stumble cleanup: gate, guard, MLX/cloud  (done)
  ContextKit                 Focused-field kind via Accessibility     (Step 6, done)
  HistoryKit                 Last 100 transcripts, on disk            (Step 6, done)
```

## Everyday use

Install the Release build in /Applications and have it open at login:

```bash
scripts/install.sh --login
```

**Coming from Dictate?** The app used to be called Dictate (`com.example.dictate`). The first `scripts/install.sh` after the rename stops and removes /Applications/Dictate.app and its login agent, and the first launch moves its models, history and settings over. Because the bundle ID changed, macOS treats it as a new app: grant Microphone, Accessibility and Input Monitoring again in **Set Up Wispr Faux**, turn **Open Wispr Faux at login** back on (or install with `--login`), re-enter a cloud cleanup API key if you used one, and remove the stale *Dictate* entries from System Settings → Privacy & Security and → General → Login Items.

Run `scripts/install.sh` again after changing or pulling code. It builds Release, quits any running Wispr Faux, replaces /Applications/Wispr Faux.app, and starts it again. Permissions carry over because the bundle ID and signing identity stay the same. The first launch after an install recompiles the Whisper model for the Neural Engine (about 2 minutes; a dictation made meanwhile shows *Loading speech model* and waits); later launches take a couple of seconds.

**Open at login** is a launch agent (`WisprFaux/LaunchAgents/com.example.wisprfaux.agent.plist`, registered through `SMAppService`):

- It starts Wispr Faux when you log in, after a restart or shutdown.
- If Wispr Faux crashes, launchd relaunches it within seconds (checked with `kill -9`: back in 1 s, models ready in 1.6 s).
- **Quit Wispr Faux** from the menu (or a normal stop, like the one `scripts/install.sh` sends) is respected: it stays quit until the next login, or until you open it from /Applications.
- Only one Wispr Faux runs at a time, since two would both react to the hotkey. The copy launchd started wins; a second copy steps aside.

**Settings → General → Open Wispr Faux at login** turns it on or off; System Settings → General → Login Items lists it under Wispr Faux. Only the installed copy can turn it on, so a development build never becomes the login item. Versions before the agent registered the app itself as the login item; the first launch of the new version moves that over. When running a development build from Xcode or `build/`, quit the installed Wispr Faux first (`launchctl kickstart gui/$(id -u)/com.example.wisprfaux.agent` starts it again).

## Build and run

```bash
xcodegen generate
```

```bash
open WisprFaux.xcodeproj
```

Or build from the command line. `DEVELOPER_DIR` is needed while `xcode-select` points at the Command Line Tools:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project WisprFaux.xcodeproj -scheme WisprFaux -configuration Debug -derivedDataPath build build
```

```bash
open "build/Build/Products/Debug/Wispr Faux.app"
```

## Tests

```bash
cd Packages/DictationKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Setup and hotkey

On first launch Wispr Faux opens **Set Up Wispr Faux** (also in the menu: *Finish Setup…* / *Permissions…*):

- **Microphone, Accessibility, Input Monitoring.** Each row updates live as you flip switches in System Settings. If the hotkey still says *relaunch needed* after granting Input Monitoring, click **Relaunch Wispr Faux**.
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
log stream --style compact --predicate 'subsystem == "com.example.wisprfaux"'
```

Debug builds add a **Debug** menu: *Simulate Event-Tap Timeout on Next Key* stalls the tap for 2.5 s on your next key press so macOS disables it; the log should then show it re-enabled, and the hotkey keeps working.

## Dictating (Step 6)

Hold Control, speak, release. A pill at the bottom of the screen shows *Listening* with a level meter, then *Transcribing*, and the text is pasted where the cursor is. Control + Space keeps listening hands-free until the next Control press.

- **Esc** cancels while recording or transcribing; nothing is pasted.
- **Password fields** are never pasted into: the text is copied instead and the pill says so.
- **No text field focused** (a button, a list, the desktop), or you switched apps while it was transcribing: the text is copied and the pill says *press ⌘V to paste*. Where Accessibility can't tell what's focused (Slack, VS Code and other Electron apps), Wispr Faux pastes; a stray ⌘V does no harm.
- **Spacing:** when the character before the cursor isn't a space, a space goes first, so consecutive dictations don't run together. Only that one character is read.
- **Silence:** taps under 250 ms are ignored; quiet recordings show *Didn't hear anything*; Whisper's "[BLANK_AUDIO]"-style output, and its invented "Thank you." on near-silence, are dropped.
- **Menu:** *Paste Last Transcript*, *Copy Last Transcript*, and *Recent* (click an entry to copy it; *Clear History* at the bottom).
- **History:** the last 100 transcripts, in `~/Library/Application Support/Wispr Faux/history.json`, readable only by your user. No audio is stored (Debug builds keep the latest recording as a temporary WAV, deleted on quit).

Measured with an M-Track 2X2 into Notes and the Claude app: release to pasted in 1.2–1.7 s for 12–27 s dictations, mostly transcription (it grows with the number of words; about 0.7 s for a sentence). The log line for each paste has the app, the kind of field and the timings, never the words:

```bash
log stream --style compact --predicate 'subsystem == "com.example.wisprfaux" AND category == "Paste"'
```

Not done yet:

- Paste-last and copy-last shortcuts (⌃⌘V, ⌃⌘C in the plan) are menu items for now; the hotkey layer can learn them as Wispr Faux's own commands.
- Dictating mid-sentence keeps Whisper's capital first letter ("…I think Maybe").
- Long dictations wait for the whole transcription after release. Transcribing while you speak (v0.4 streaming) would cut that.

## Cleaning up stumbles

Whisper writes down exactly what was said, stumbles included. **Settings → Clean up stumbles** fixes them before pasting: fillers ("um", "uh"), repeated words, broken-off phrases, and self-corrections ("Tuesday, no wait, Wednesday" → "Wednesday"; "send it to Mark, I mean Mike" → "send it to Mike").

- **Only when needed.** A transcript goes to the model only when it shows a stumble: a filler, "I mean", "sorry", "no wait", "wait", "actually", "scratch that", a doubled word, or a dash or ellipsis. Clean dictations are pasted as Whisper wrote them, with no extra delay.
- **On this Mac** (the default): Qwen3 1.7B (`mlx-community/Qwen3-1.7B-4bit`, 0.98 GB) on the GPU through [MLX](https://github.com/ml-explore/mlx-swift-lm). It lives in `~/Library/Application Support/Wispr Faux/Models/llm`; Settings has a Download button when it's missing. About 0.55 s per cleanup, and nothing leaves the Mac.
- **Cloud**: any provider with the common chat-completions API. Presets: **GLM-4.7-Flash** from Z.ai (free with an account, about one request per second) and **DeepSeek** (paid, about $0.0001 per cleanup). Paste the API key in Settings; it's stored in the macOS keychain. Only the text of dictations with a stumble is sent; audio never leaves the Mac. Both providers are in China, and free tiers may use requests for training.
- **Safety.** The model's reply is checked before it's pasted. Cleanup only removes words, so a reply that brings in words that weren't said, gets longer, adds lines or drops almost everything is rejected: that's a model answering a dictated question, following a dictated instruction, or rewording. A reply slower than 3 s (4 s for cloud) or an error also falls back. In every one of those cases the transcript is pasted as spoken. Esc cancels during cleanup too.
- **History** keeps the original wording of any dictation that cleanup changed.
- **Test** in Settings runs a sample stumble through the current engine and shows the result and timing.

Measured on the M4 Mac mini with `wisprfaux-bench cleanup` (10 stumbles plus 6 traps: a question, a dictated instruction, a prompt injection, a "sorry" and an "actually" that aren't corrections, and a long clean paragraph). A case passes when the pasted text is within 15% of the expected text:

| Model (on this Mac) | Passed | Per cleanup | Download |
|---|---|---|---|
| LFM2.5 1.2B | 10/16 (once flipped a meaning) | 0.40 s | 0.64 GB |
| **Qwen3 1.7B** | **14/16** | **0.55 s** | 0.98 GB |
| Qwen3 4B Instruct 2507 | 14/16 | 1.26 s | 2.28 GB |

Every model wrote a haiku when told to "write a haiku", and the guard rejected all of them. `mlx-swift-lm` is pinned to 2.30.6, the last release that builds with Swift 6.0 (Xcode 16); newer releases support newer models (Qwen3.5, Gemma 4) but need Xcode 26.

### How pasting works (`InsertionKit`)

- Every item and type on the clipboard is backed up first. Unlike the teardown, PDF, RTFD and sound data are kept so the clipboard comes back identical; only file promises are skipped.
- The text goes on the clipboard marked `org.nspasteboard.TransientType`, so clipboard managers don't record it.
- ⌘V uses the key that types V with ⌘ held in the current layout (Dvorak, AZERTY, Dvorak – QWERTY ⌘), falling back to keycode 9.
- The clipboard is restored 500 ms later, unless something new was copied in the meantime. A second paste inside that window keeps the original backup.

The log (`log stream` command above) records each paste's timing and backup size. It never records clipboard contents.

## Recording (Step 4)

The setup window's *Try it* row shows a live level bar while you hold the hotkey. Debug builds also have a **Debug** menu showing the last recording, e.g. *Last recording: 3.2 s · loudest −18 dBFS · would transcribe*, the mic it came from and how long after the key press the first sample arrived, with **Play Last Recording** and **Show Recording in Finder**.

Debug builds keep only the last recording, as a 16 kHz mono 16-bit WAV in `$TMPDIR/Wispr Faux/last-recording.wav`, overwritten on every recording and deleted when Wispr Faux quits. Release builds store no audio. Check it from Terminal:

```bash
afinfo "$TMPDIR/Wispr Faux/last-recording.wav"
```

```bash
afplay "$TMPDIR/Wispr Faux/last-recording.wav"
```

What the numbers mean:

- **Loudest** is the loudest 30 ms of the clip. Speech should reach roughly −30 to −10 dBFS. Around −55 dBFS or lower, the mic gain is too low: raise *System Settings → Sound → Input → Input volume* (and any gain knob on the mic). *⚠︎ clipped* means it's too high. If the level never moves when you talk, watch the *Input level* meter on that same Settings page: if it's flat too, the problem is the mic itself (mute button, gain knob, wrong side of the mic), not Wispr Faux.
- **would transcribe / too short / too quiet** is the gate that will keep accidental taps and silence away from Whisper (Whisper invents text for silence). Under 250 ms, or a loudest 30 ms below −45 dBFS, is skipped. These thresholds are first guesses to tune with real recordings.
- **First sample N ms after the key** is how much of the start of your speech is lost. A new audio engine is built for each recording so the mic is only on while you hold the key; on the fifine USB mic that costs about 110–180 ms. Cutting this is a Step 6 job (e.g. keeping a prepared engine between recordings).

The log line for each recording also has the device format, tap buffer size, each input channel's peak before the mix to mono, and engine start time:

```bash
log stream --style compact --predicate 'subsystem == "com.example.wisprfaux" AND category == "Audio"'
```

How it works (`AudioKit`):

- `MicrophoneRecorder` (an actor on its own queue) taps `AVAudioEngine`'s input node. It records only while the key is held: no always-on mic.
- `MonoResampler` turns whatever the device delivers into 16 kHz mono Float32. Multi-channel input is averaged to mono first; `AVAudioConverter`'s own downmix outputs silence for discrete channel layouts. Buffers stream through one converter, so there are no clicks at buffer boundaries.
- On release the mic stays on until the tap buffer covering the key-up arrives (usually well under 100 ms, at most 300 ms). Tap buffers come whole, 100 ms at a time on the fifine, so stopping straight away would cut off the end of the last word.
- A recording is capped at 5 minutes. If the input device changes mid-recording, what was captured so far is kept and the menu says so.
- Pressing the hotkey while the mic is unplugged or still reconnecting shows *Not recording: The microphone isn't available…* instead of crashing. AVAudioEngine reports some device problems as Objective-C exceptions, which Swift can't catch, so the engine setup runs inside a small `@try/@catch` shim (`ObjCExceptions` target).

Debug builds can record without the hotkey: *Debug → Record 3 Seconds Without the Hotkey*, or at launch:

```bash
open "build/Build/Products/Debug/Wispr Faux.app" --args -DebugRecordSeconds 3
```

## Transcription (Step 5)

Wispr Faux transcribes with [WhisperKit](https://github.com/argmaxinc/WhisperKit) (pinned to 1.1.1), which runs Whisper on the Mac's Neural Engine. Nothing leaves the Mac.

- **Model:** Whisper large-v3 turbo, compressed (`openai_whisper-large-v3-v20240930_turbo_632MB`, 646 MB). Models live in `~/Library/Application Support/Wispr Faux/Models`.
- **Getting it:** if the model isn't there, the menu shows a **Download** button. That download, and `wisprfaux-bench download`, are the only things in Wispr Faux that use the network. Loading and transcribing work entirely from those files, and a model only counts as downloaded once its tokenizer is there too (otherwise WhisperKit would fetch it at load time).
- **Status:** the menu shows the model's state while it's loading, downloading or missing; Debug builds show the last dictation's timings in the Debug menu. The log records timings and length, never the words.
- **Another model:** `defaults write com.example.wisprfaux transcription.model openai_whisper-small.en`, then relaunch. `defaults delete com.example.wisprfaux transcription.model` goes back to the default.

Measured on the M4 Mac mini (16 GB):

| | small.en (487 MB) | large-v3 turbo, compressed (646 MB) |
|---|---|---|
| 5 s of speech → text | 0.26–0.30 s | 0.6–0.8 s |
| 15 s of speech → text | 0.69 s | 1.08 s |
| Key up → text in the menu (app, M-Track mic) | – | 0.9 s for 6–10 s of speech |
| Load at launch | 17 s, every launch | 2–7 s; ~2 min the first time |
| Errors on synthetic test speech | 1.1% | 1.1% |

Turbo is the default: it punctuates better, loads quickly once compiled, and stays under a second for a typical dictation. Debug and Release builds transcribe at the same speed, since the work runs on the Neural Engine.

**Load time:** the first load compiles the model for the Neural Engine, which takes 2–4 minutes; the menu says *Loading…* meanwhile, and a dictation made then waits for it. macOS caches the result, so later launches take a few seconds. A Debug rebuild keeps the cache; a new Release build (each `scripts/install.sh`) recompiles once. The cache is shared and limited, though: it's rebuilt after a macOS update, and loading the same model from another program (such as `wisprfaux-bench`) can push Wispr Faux's copy out, costing one more 2-minute load. macOS also deletes it when the disk runs low (it did at 3 GB free), so keep a few GB free.

### Comparing models

`wisprfaux-bench` is built with `xcodebuild`, which compiles MLX's Metal shaders (plain `swift build` doesn't):

```bash
cd Packages/DictationKit && xcodebuild -scheme wisprfaux-bench -configuration Release -destination "platform=macOS,arch=arm64" -derivedDataPath .build-xcode build -quiet
```

Whisper models:

```bash
.build-xcode/Build/Products/Release/wisprfaux-bench models
```

```bash
.build-xcode/Build/Products/Release/wisprfaux-bench download small.en
```

```bash
.build-xcode/Build/Products/Release/wisprfaux-bench run turbo_632MB clip1.wav clip2.aiff --runs 3
```

Any audio file works. A `.txt` file with the same name next to it is used as the reference transcript, and the run reports the word error rate. `say -o clip.aiff -f clip.txt` makes test clips with known text.

Cleanup engines (16 built-in cases; `cleanup-models` lists the choices):

```bash
.build-xcode/Build/Products/Release/wisprfaux-bench cleanup-download qwen3-1.7b
```

```bash
.build-xcode/Build/Products/Release/wisprfaux-bench cleanup local qwen3-1.7b
```

```bash
WISPRFAUX_CLEANUP_KEY=your-key .build-xcode/Build/Products/Release/wisprfaux-bench cleanup cloud zai-glm-4.7-flash
```

Loading the Whisper model from `wisprfaux-bench` can push Wispr Faux's compiled copy out of macOS's cache (see Load time above).

## Signing and permissions

- **Signing identity:** builds are signed with the Developer ID Application identity for team `FS3T7J3D7X` (set in `project.yml`). Keep the identity stable: macOS ties Accessibility and Input Monitoring grants to it.
- **Bundle ID:** `com.example.wisprfaux` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` before granting permissions; grants are tied to the bundle ID too.
- **No sandbox:** the event tap, Accessibility reads and synthetic Cmd+V all need it off. Hardened Runtime is on, and the microphone entitlement is declared.
