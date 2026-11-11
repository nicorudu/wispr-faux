# Dictate

Push-to-talk dictation for macOS: hold a key, speak, release, and the text appears in the focused app.
The roadmap, architecture and step-by-step plan are in [BUILD_PLAN.md](BUILD_PLAN.md).

**Status:** Step 1 (skeleton) done. The app launches as a menu-bar item; dictation is wired in Steps 2–6.

## Requirements

- macOS 14+ on Apple Silicon
- Xcode 16.2+ (`/Applications/Xcode.app`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Layout

```
project.yml                  XcodeGen spec (source of truth for Dictate.xcodeproj)
Dictate/                     App target: menu bar, settings, DictationController
Packages/DictationKit/       Core modules, each testable on its own
  HotkeyKit                  CGEventTap, shortcuts, keycodes          (Step 2)
  InsertionKit               Clipboard backup/restore + Cmd+V         (Step 3)
  AudioKit                   AVAudioEngine → 16 kHz mono              (Step 4)
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

## Signing and permissions

- **Signing identity:** builds are signed with the Developer ID Application identity for team `FS3T7J3D7X` (set in `project.yml`). Keep the identity stable: macOS ties Accessibility and Input Monitoring grants to it.
- **Bundle ID:** `com.example.dictate` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` before granting permissions; grants are tied to the bundle ID too.
- **No sandbox:** the event tap, Accessibility reads and synthetic Cmd+V all need it off. Hardened Runtime is on, and the microphone entitlement is declared.
