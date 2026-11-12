# Wispr Faux for iPhone

A keyboard with a mic button: hold it, speak, let go, and the text is typed where you're writing, in any app. Transcription runs on the iPhone with Whisper large-v3 turbo, as on the Mac. Stumble cleanup ("Tuesday, no wait, Wednesday" → "Wednesday") is optional and uses the Mac app's cloud providers.

**Status:** written but not yet built. The first build in Xcode will probably need a round or two of fixes; send the errors back to Claude.

## How it works, and why it's built this way

iOS doesn't let a keyboard use the microphone, and gives a keyboard only about 50–70 MB of memory, far too little for Whisper. So the work is split, the same way Wispr Flow does it:

1. **A session runs in the Wispr Faux app.** Starting one turns the microphone on and keeps the app running in the background. iOS only lets an app turn the microphone on while it's in front, so a session always starts in the app.
2. **The keyboard drives it.** Hold the mic button: the keyboard tells the app to record. Let go: the app transcribes (and cleans up, if that's on) and hands the text back, and the keyboard types it in.
3. **If no session is running**, the mic button opens the app, which starts one. Go back to where you were with **◀** at the top-left of the screen, then hold the mic button.

While a session runs, iOS shows the orange microphone dot. Only what you say while holding the button is transcribed; between dictations the app keeps just the last 0.3 s of audio in memory (so the first word isn't clipped), and no audio is ever stored.

**How long a session lasts.** You pick: 15 minutes, 1, 4 or 12 hours after the last dictation, or *Until I end it*. iOS can still end a session on its own: when the app is swiped away in the app switcher, when the phone restarts, when a phone call or another app takes the microphone and doesn't give it back, or when iOS needs the memory for the app in front (more likely on an iPhone with less memory, like the iPhone 13). When that happens, the next tap on the mic button opens the app to start a new session. A session running all day costs some battery, since the microphone is on; check **Settings → Battery** after a day to see how much.

Music and podcasts keep playing during a session. Bluetooth headphones aren't switched to their call mode: the iPhone's own microphone is used.

## What you need

- An iPhone on iOS 17 or later. The iPhone 13 and iPhone 15 Pro both work.
- Your Mac with Xcode 16.2 or later and XcodeGen (`brew install xcodegen`), as for the Mac app.
- A **paid Apple Developer membership** ($99/year) on the team the Mac app signs with (FS3T7J3D7X). With it, an app you install from Xcode keeps working for a year. With a free account it stops after 7 days, and keyboards that use App Groups may not install at all. Check or renew it at <https://developer.apple.com/account>.
- **On a work phone:** your company's device management may block third-party keyboards or Full Access. If the keyboard doesn't appear in Settings, or *Allow Full Access* is greyed out, that's why, and only IT can change it.

## Install it, step by step

Do this once per iPhone (once for your iPhone 15 Pro, once for your work iPhone 13).

### 1. Generate the Xcode project

```bash
cd ios
```

```bash
xcodegen generate
```

```bash
open WisprFauxPhone.xcodeproj
```

### 2. Connect the iPhone and turn on Developer Mode

1. Plug the iPhone into the Mac and tap **Trust** on the iPhone.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode** → on, then restart it when asked. (The option appears only after the iPhone has been connected to Xcode once.)

### 3. Build and run

1. In Xcode, at the top, pick the **WisprFauxPhone** scheme and your iPhone as the destination.
2. Press **⌘R**. The first build downloads WhisperKit and takes a few minutes.
3. If Xcode says the **bundle identifier** or **App Group** is unavailable, open `project.yml`, change `WF_BUNDLE_PREFIX` and `WF_APP_GROUP` to your own name (e.g. `com.yourname.wisprfaux` and `group.com.yourname.wisprfaux`), run `xcodegen generate` again, and build again.
4. The first launch on the iPhone may say the developer isn't trusted: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.

### 4. Set it up on the iPhone

Open **Wispr Faux** and work through **Setup**:

1. **Microphone** → **Allow**.
2. **Speech model** → **Download** (646 MB, use Wi-Fi). Then keep the app open while it says *Preparing*: the first time, iOS prepares the model for the Neural Engine, which can take a few minutes.
3. **Keyboard**: tap **Open Settings** → **Keyboards** → turn on **Wispr Faux** and **Allow Full Access**. Full Access is what lets the keyboard talk to the app; the keyboard itself never sends anything over the network.

### 5. Try it

1. In Wispr Faux, tap the box under **Try it**.
2. Hold **🌐** on the keyboard and pick **Wispr Faux**.
3. Tap the blue mic button. The first time, it starts a session (you're already in the app, so just carry on).
4. **Hold** the mic button, speak, let go. The text appears.

Elsewhere, say in Messages: switch to the Wispr Faux keyboard and hold the mic. If no session is running, it opens Wispr Faux; tap **◀ Messages** at the top-left to go back, then hold the mic again.

| Gesture | Result |
|---|---|
| Hold the mic, speak, let go | Dictate |
| Tap the mic (short) | Keeps listening until the next tap: hands-free |
| ✕ next to the mic | Cancel: nothing is typed |
| 🌐 | Back to your usual keyboard |

The keyboard has plain letters, numbers and symbols, with automatic capitals and a double space for a full stop, but no autocorrect or predictions. Switch to the Apple keyboard with 🌐 for long typing.

### 6. Optional: clean up stumbles

In Wispr Faux, under **Clean up stumbles (cloud)**: turn it on, pick **GLM-4.7-Flash (Z.ai)** (free with an account) or **DeepSeek** (paid, about $0.0001 per cleanup), tap **Get a key**, paste the key, **Save**, then **Test**. The key is kept in the iPhone's keychain. As on the Mac, only dictations with a stumble are sent, only their text, and a reply that adds words or rewrites is ignored.

## Updating

Pull the latest code on the Mac, then with each iPhone connected:

```bash
cd ios && xcodegen generate
```

and press **⌘R** in Xcode. Settings, history and the downloaded model are kept.

## Troubleshooting

- **The mic button keeps opening the app.** The session isn't running: open Wispr Faux and check the Session section (it says why the last one ended). Swiping Wispr Faux away in the app switcher ends the session.
- ***Didn't hear anything.*** Check that Wispr Faux has the microphone (**Settings → Wispr Faux → Microphone**).
- **Sessions keep ending on their own on the iPhone 13.** iOS is reclaiming memory. Switch **Model** to *Whisper small (English)*, which uses much less.
- **"Allow Full Access to dictate"** on the keyboard: **Settings → General → Keyboard → Keyboards → Wispr Faux → Allow Full Access**.
- **Slow transcription.** The first dictation after the model loads is slower. **Try it** shows the timing of the last dictation.

## Layout

```
ios/
  project.yml          XcodeGen spec: the app, the keyboard, and PostProcessKit
  App/                 The app: SessionController (the session and its state machine),
                       SessionMicrophone, PhoneTranscriber, PhoneCleanup, the setup screen
  Keyboard/            The keyboard extension: the mic bar and keys (KeyboardView),
                       KeyboardModel, KeyboardViewController
  Shared/              SessionChannel: how the keyboard and the app talk (App Group
                       defaults and Darwin notifications)
```

Compiled straight from the Mac app's sources, so there's one copy of each: `Packages/DictationKit/Sources/TranscriptionKit` (Whisper models and their store), `CleanupKit` (the cloud engines, prompt and safety check; not the MLX engine), `PostProcessKit`, `HistoryKit`, and `WisprFaux/KeychainItem.swift`. Nothing in the Mac package or the Mac app was changed.
