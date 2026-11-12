#!/bin/bash
# Builds Dictate in Release and installs it in /Applications for everyday use.
#
#   scripts/install.sh           build, install and launch
#   scripts/install.sh --login   ...and turn on Open Dictate at Login
#
# Run it again after pulling or changing code. Only one Dictate may run at a time
# (two would both react to the hotkey), so any running copy is quit first; Dictate
# quits cleanly on SIGTERM, so its launch agent doesn't relaunch it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "Building Release…"
xcodegen generate --quiet
xcodebuild -project Dictate.xcodeproj -scheme Dictate -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath build build -quiet

if pgrep -x Dictate >/dev/null; then
    echo "Quitting the running Dictate…"
    pkill -TERM -x Dictate
    for _ in $(seq 1 40); do pgrep -x Dictate >/dev/null || break; sleep 0.25; done
    sleep 1 # LaunchServices needs a moment after a quit, or `open` fails with -600.
fi

built=build/Build/Products/Release/Dictate.app
if [[ -d /Applications/Dictate.app ]]; then
    installed_id=$(defaults read /Applications/Dictate.app/Contents/Info CFBundleIdentifier 2>/dev/null || true)
    built_id=$(defaults read "$PWD/$built/Contents/Info" CFBundleIdentifier)
    if [[ "$installed_id" != "$built_id" ]]; then
        echo "/Applications/Dictate.app is a different app ($installed_id), so it was left alone." >&2
        exit 1
    fi
    rm -rf /Applications/Dictate.app
fi
cp -R "$built" /Applications/

agent="gui/$(id -u)/com.example.dictate.agent"
if launchctl print "$agent" >/dev/null 2>&1; then
    # Start it through the launch agent, so launchd relaunches it if it ever crashes.
    launchctl kickstart "$agent"
elif [[ "${1:-}" == "--login" ]]; then
    open /Applications/Dictate.app --args -EnableOpenAtLogin YES
else
    open /Applications/Dictate.app
fi
echo "Installed /Applications/Dictate.app and launched it."
