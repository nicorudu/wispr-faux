#!/bin/bash
# Builds Wispr Faux in Release and installs it in /Applications for everyday use.
#
#   scripts/install.sh           build, install and launch
#   scripts/install.sh --login   ...and turn on Open Wispr Faux at Login
#
# Run it again after pulling or changing code. Only one Wispr Faux may run at a time
# (two would both react to the hotkey), so any running copy is quit first; Wispr Faux
# quits cleanly on SIGTERM, so its launch agent doesn't relaunch it.
#
# The app was called Dictate before. If /Applications/Dictate.app is that old build
# (bundle ID com.example.dictate), it is quit, its launch agent is stopped, and it is
# removed. Its models, history and settings are moved over on the first launch.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

app_name="Wispr Faux"
installed="/Applications/$app_name.app"

echo "Building Release…"
xcodegen generate --quiet
xcodebuild -project WisprFaux.xcodeproj -scheme WisprFaux -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath build build -quiet

# Quits a running app by process name and waits for it to exit.
quit_app() {
    if pgrep -x "$1" >/dev/null; then
        echo "Quitting the running $1…"
        # It may have exited since pgrep saw it (e.g. after launchctl bootout); that's fine.
        pkill -TERM -x "$1" || true
        for _ in $(seq 1 40); do pgrep -x "$1" >/dev/null || break; sleep 0.25; done
        sleep 1 # LaunchServices needs a moment after a quit, or `open` fails with -600.
    fi
}

# Retire the old Dictate install, if there is one.
if [[ -d /Applications/Dictate.app ]]; then
    old_id=$(defaults read /Applications/Dictate.app/Contents/Info CFBundleIdentifier 2>/dev/null || true)
    if [[ "$old_id" == "com.example.dictate" ]]; then
        echo "Removing the old Dictate.app (now Wispr Faux)…"
        launchctl bootout "gui/$(id -u)/com.example.dictate.agent" 2>/dev/null || true
        quit_app Dictate
        rm -rf /Applications/Dictate.app
    fi
fi

quit_app "$app_name"

built="build/Build/Products/Release/$app_name.app"
if [[ -d "$installed" ]]; then
    installed_id=$(defaults read "$installed/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    built_id=$(defaults read "$PWD/$built/Contents/Info" CFBundleIdentifier)
    if [[ "$installed_id" != "$built_id" ]]; then
        echo "$installed is a different app ($installed_id), so it was left alone." >&2
        exit 1
    fi
    rm -rf "$installed"
fi
cp -R "$built" /Applications/

agent="gui/$(id -u)/com.example.wisprfaux.agent"
if launchctl print "$agent" >/dev/null 2>&1; then
    # Start it through the launch agent, so launchd relaunches it if it ever crashes.
    launchctl kickstart "$agent"
elif [[ "${1:-}" == "--login" ]]; then
    open "$installed" --args -EnableOpenAtLogin YES
else
    open "$installed"
fi
echo "Installed $installed and launched it."
