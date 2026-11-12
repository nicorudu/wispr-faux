# Wispr Faux for Windows

Push-to-talk dictation for Windows: hold **Ctrl**, speak, let go, and the text appears in whatever app has the cursor. It works like the Mac app (see the [main README](../README.md) and [BUILD_PLAN.md](../BUILD_PLAN.md)):

- **On-device speech to text** with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) through [Whisper.net](https://github.com/sandrohanea/whisper.net), using Whisper large-v3 turbo. It runs on the graphics card through Vulkan when there is one (NVIDIA, AMD or Intel), otherwise on the CPU.
- **Stumble cleanup** ("Tuesday, no wait, Wednesday" → "Wednesday"), off by default, with the same prompt, examples and safety checks as the Mac app: on this PC with Qwen3 1.7B through [llama.cpp](https://github.com/ggml-org/llama.cpp) ([LLamaSharp](https://github.com/SciSharp/LLamaSharp)), or with a cloud model (GLM-4.7-Flash or DeepSeek).
- **Pastes with Ctrl+V** into the focused app and **puts your clipboard back** 500 ms later, every format included (text, images, files, rich text).
- **Runs from the system tray** and **opens when you sign in**.

Nothing leaves your PC except the model downloads and, if you choose the cloud option, the text of dictations that have a stumble.

## Install it on your PC, step by step

You need Windows 10 (version 1809 or later) or Windows 11, 64-bit, a microphone, and about 4 GB of free disk space (the app is about 370 MB, the speech model 574 MB, the optional cleanup model 1.1 GB).

### 1. Get the code

**Easiest: download a ZIP.** In a browser where you're signed in to GitHub, open <https://github.com/nicorudu/dictate/archive/refs/heads/claude/wonderful-bell-h0nr7l.zip> (once this branch is merged, use <https://github.com/nicorudu/dictate/archive/refs/heads/main.zip>). Right-click the downloaded ZIP → **Extract All…** → extract it to, say, `Documents\dictate`.

**Or with Git**, which makes updating easier. Install Git once in PowerShell:

```powershell
winget install --id Git.Git -e
```

Then close and reopen PowerShell and clone the repository:

```powershell
git clone https://github.com/nicorudu/dictate.git "$HOME\Documents\dictate"
```

```powershell
cd "$HOME\Documents\dictate"
```

```powershell
git checkout claude/wonderful-bell-h0nr7l
```

(Skip the `git checkout` once this branch is merged into `main`.)

### 2. Run the installer

Open the `windows` folder in File Explorer and **double-click `install.cmd`**. Or, in PowerShell:

```powershell
cd "$HOME\Documents\dictate\windows"
```

```powershell
.\install.cmd
```

The installer:

1. Installs the **.NET 8 SDK** with `winget` if no .NET SDK 8 or later is installed. Windows may ask for permission (a UAC prompt) for this one step. If `winget` isn't available, it stops and tells you to install the SDK from <https://dotnet.microsoft.com/download/dotnet/8.0> (pick **SDK 8.0, Windows x64**), then run it again.
2. **Builds** Wispr Faux. The first build downloads packages and takes a few minutes.
3. **Installs** it in `%LOCALAPPDATA%\Programs\Wispr Faux`. No administrator rights are needed.
4. **Downloads Whisper large-v3 turbo** (574 MB) into `%LOCALAPPDATA%\Wispr Faux\Models`.
5. Adds **Wispr Faux** to the Start menu and has it **open when you sign in**.
6. **Starts** it.

Options (pass them after `install.cmd` or `.\install.ps1`):

| Option | Effect |
|---|---|
| `-WithLocalCleanup` | Also download Qwen3 1.7B (1.1 GB) for stumble cleanup on this PC |
| `-NoLogin` | Don't open Wispr Faux at sign-in |
| `-SkipModelDownload` | Don't download the speech model now (Settings has a Download button) |
| `-NoLaunch` | Don't start it at the end |

### 3. Let Windows give it the microphone

Open **Settings → Privacy & security → Microphone** and turn on both **Microphone access** and **Let desktop apps access your microphone**. When desktop apps are blocked, Windows hands them silence rather than an error; Wispr Faux notices and says *Microphone access is off in Windows Settings*. The Settings window has a link straight to this page.

If you have more than one microphone, pick one in Wispr Faux's **Settings → Microphone** (the default follows Windows' default microphone).

### 4. Find the tray icon

Wispr Faux has no window: it lives in the **system tray**, as a grey microphone next to the clock. If you don't see it, click the **^** arrow next to the clock. To keep it visible, drag it onto the taskbar, or turn it on under **Settings → Personalization → Taskbar → Other system tray icons**.

- **Left-click** the icon: Settings.
- **Right-click**: the menu (Paste Last Transcript, Copy Last Transcript, Recent, Settings, Open at Sign-in, Quit).

The icon turns **red** while listening and **amber** while transcribing. A slash means something needs attention (usually the speech model isn't downloaded yet).

### 5. Try it

Open Notepad, click in it, then:

1. **Hold Ctrl** (either one). A pill at the bottom of the screen says *Listening* and its bars follow your voice.
2. **Speak.**
3. **Let go of Ctrl.** The pill says *Transcribing*, then the text appears at the cursor.

The very first dictation after starting can take a few extra seconds while the model warms up.

| Gesture | Result |
|---|---|
| Hold Ctrl, speak, release | Dictate |
| Ctrl + Space | Hands-free: keeps listening after you let go of Ctrl; press Ctrl again to stop |
| Esc | Cancel while listening or transcribing (nothing is pasted) |
| Ctrl + another key, or Ctrl-click (Ctrl+C, Ctrl+S…) | Works as a normal shortcut; the dictation is cancelled |

**Settings → Hold to talk** can limit it to the left or right Ctrl, or use **Right Alt (AltGr)** instead. Ctrl and Alt always reach your apps as usual.

### 6. Optional: clean up stumbles

**Settings → Clean up stumbles**:

- **On this PC**: click **Download Qwen3 1.7B (1.1 GB)**, then **Test**. It runs on the graphics card when there is one; on a CPU alone a cleanup takes 1–4 s. A cleanup that takes longer than 5 s is skipped and the dictation is pasted as spoken.
- **Cloud**: pick **GLM-4.7-Flash (Z.ai)** (free with an account) or **DeepSeek** (paid, about $0.0001 per cleanup), click **Get a key**, paste the key, **Save key**, then **Test**. The key is encrypted for your Windows account (DPAPI). Only the text of dictations with a stumble is sent; audio never leaves the PC. Both providers are in China, and free tiers may use requests for training.

As on the Mac, only dictations that show a stumble go to the model, and a reply that adds words, grows, adds lines or drops almost everything is rejected: the dictation is then pasted exactly as spoken.

### Updating

With Git:

```powershell
cd "$HOME\Documents\dictate"
```

```powershell
git pull
```

```powershell
.\windows\install.cmd
```

With a ZIP: download and extract the new ZIP, then run its `windows\install.cmd`. The installer quits the running copy, replaces it and starts the new one; settings, history, models and keys are kept.

### Uninstalling

```powershell
.\windows\uninstall.ps1
```

That removes the app, its Start menu entry and its sign-in entry. Add `-RemoveData` to also delete `%LOCALAPPDATA%\Wispr Faux` (models, history, settings, API keys). If PowerShell refuses to run scripts, use `powershell -ExecutionPolicy Bypass -File .\windows\uninstall.ps1`.

## How it behaves

- **Pasting.** Every clipboard format is backed up, the text is put on the clipboard marked so Windows clipboard history (Win+V), cloud clipboard and clipboard managers skip it, Ctrl+V is pressed, and 500 ms later the clipboard is put back, unless you copied something new meanwhile. A second paste inside that window keeps the original backup. Formats Windows keeps as GDI objects (bitmaps, metafiles) aren't backed up; Windows rebuilds a copied bitmap from its image data, which is kept.
- **Spacing.** When the character before the cursor isn't a space, a space goes first, so consecutive dictations don't run together. Only that one character is read (through UI Automation).
- **Password fields** are never pasted into: the text is copied and the pill says so.
- **Not a text field** (the desktop, a button, a list), or you switched apps while it was transcribing: the text is copied and the pill says *press Ctrl+V to paste*. When UI Automation can't tell what's focused, Wispr Faux pastes; a stray Ctrl+V does no harm.
- **Apps running as administrator.** Windows doesn't let a normal app type into them, so Wispr Faux copies the text instead and says so. (Running Wispr Faux itself as administrator would lift this, but isn't recommended.)
- **Silence.** Taps under 250 ms are ignored; quiet recordings show *Didn't hear anything*; Whisper's "[BLANK_AUDIO]"-style output, and its invented "Thank you." on near-silence, are dropped.
- **History.** The last 100 transcripts are in `%LOCALAPPDATA%\Wispr Faux\history.json` (the original wording is kept when cleanup changed it). No audio is stored.
- **Recording** is capped at 5 minutes. The microphone is only open while you hold the key.
- **Only one copy runs** at a time. Opening Wispr Faux from the Start menu while it's running opens its Settings.
- **Log.** `%LOCALAPPDATA%\Wispr Faux\Logs\wisprfaux.log` records timings, lengths, app names and errors, never what you said or what's on the clipboard. **Settings → Open the log** opens it.

### Speech models

**Settings → Speech to text → Model**:

| Model | Download | Notes |
|---|---|---|
| **Whisper large-v3 turbo (5-bit)** | 574 MB | Default; the Mac app's model, quantized for whisper.cpp |
| Whisper large-v3 turbo (8-bit) | 874 MB | Slightly more accurate |
| Whisper large-v3 turbo (full) | 1.6 GB | Unquantized; wants a GPU |
| Whisper small (English only) | 488 MB | For slow PCs without a GPU |

**Language** defaults to detecting it for each dictation; picking your language avoids the occasional wrong guess on short clips. **Use the graphics card** is on by default; turn it off if dictation crashes or garbles on your GPU (quit and reopen Wispr Faux afterwards).

On a PC with a recent GPU, turbo transcribes a 5–10 s dictation in well under a second. On a CPU alone, expect a few seconds on a modern 8-core processor; switch to *small (English only)* if that's too slow.

## Troubleshooting

- **Nothing happens when I hold Ctrl.** Check that the tray icon is there. If it shows a slash, open Settings and download the speech model. If the log says the keyboard hook failed, restart Wispr Faux. Some antivirus programs block apps that watch the keyboard: allow `WisprFaux.exe` in `%LOCALAPPDATA%\Programs\Wispr Faux`.
- ***Didn't hear anything.*** Check **Settings → Privacy & security → Microphone** (step 3), pick the right microphone in Wispr Faux's Settings, and check the input level under **Settings → System → Sound → Input**.
- **The text is copied instead of pasted.** The pill says why: a password field, no text field, an app running as administrator, or you switched apps.
- **The speech model download fails.** Run `install.cmd` again (downloads resume), or click Download in Settings. The models come from Hugging Face (`huggingface.co`); a firewall or proxy may block it.
- **Transcription failed / the model failed to load on the GPU.** Turn off **Use the graphics card** in Settings, quit Wispr Faux from the tray menu and open it again. Updating the graphics driver often fixes Vulkan problems too.
- **"Windows protected your PC" / SmartScreen** doesn't appear for a copy you built yourself. If an antivirus quarantines it, that's the keyboard hook; see the first item.
- **It doesn't start at sign-in.** Check **Task Manager → Startup apps** (Wispr Faux must be *Enabled*) or the *Open at Sign-in* item in the tray menu.

## Differences from the Mac app

| | Mac | Windows |
|---|---|---|
| Hotkey | Control, Fn, Right Option or Right Command | Ctrl (either side), or Right Alt (AltGr). Windows has no Fn key event |
| Hotkey mechanism | `CGEventTap` | Low-level keyboard and mouse hooks (`WH_KEYBOARD_LL`, `WH_MOUSE_LL`) |
| Speech model | WhisperKit, Core ML on the Neural Engine | whisper.cpp (Whisper.net 1.9.1), Vulkan GPU or CPU |
| Cleanup on device | Qwen3 1.7B on MLX, 3 s limit | Qwen3 1.7B (GGUF, 4-bit) on llama.cpp (LLamaSharp 0.27), 5 s limit |
| Focused-field reads | Accessibility API | UI Automation |
| Clipboard "don't record" marker | `org.nspasteboard.TransientType` | `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0` |
| API keys | Keychain | DPAPI-encrypted file, readable only by your Windows account |
| Open at login | Launch agent, relaunched after a crash | `HKCU\…\Run` entry; not relaunched after a crash (open it from the Start menu) |
| Permissions | Microphone, Accessibility, Input Monitoring | Only the microphone privacy switch |

## For developers

```
windows/
  WisprFaux.sln
  install.ps1, install.cmd    Build, install, download models, start at sign-in
  uninstall.ps1
  src/WisprFaux.Core/         Platform-neutral logic (net8.0), ported from the Mac's DictationKit:
    Cleanup/                    DisfluencyCues, CleanupPrompt, CleanupGuard, TranscriptCleaner, CloudEngine
    Hotkey/                     ShortcutMatcher (Windows virtual keys), triggers
    Audio/                      LevelStats, SpeechGate
    Text/, History/, Settings/  TextCleaner, word splitting, HistoryStore, AppSettings, ModelCatalog
  src/WisprFaux/              The Windows app (net8.0-windows, WinForms):
    DictationController.cs      The state machine
    TrayApp.cs, Program.cs      Tray icon and menu, single instance, --quit / --background
    Platform/                   InputHook, TextInserter + ClipboardSnapshot, FocusedField (UI Automation), Win32 calls, log
    Services/                   AudioRecorder (NAudio), TranscriptionService (Whisper.net),
                                LocalCleanupEngine (LLamaSharp), CleanupService, ModelDownloader,
                                SecretStore (DPAPI), StartupManager
    UI/                         StatusPill, SettingsForm, TrayIcons
  tests/WisprFaux.Core.Tests/ xUnit tests for the core (run on any OS)
```

Build and run from a terminal in `windows`:

```powershell
dotnet build WisprFaux.sln
```

```powershell
dotnet test tests\WisprFaux.Core.Tests
```

```powershell
dotnet run --project src\WisprFaux
```

Quit the installed copy first (tray menu → Quit), since only one copy runs at a time. Visual Studio 2022 (with the *.NET desktop development* workload) opens `WisprFaux.sln` directly.

The core tests also run on macOS and Linux (`dotnet test tests/WisprFaux.Core.Tests`). The app project builds there too (`EnableWindowsTargeting` is on), but only runs on Windows.
