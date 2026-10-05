#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
"$PROJECT_DIR/macos/scripts/build-app.sh"
DESTINATION="$HOME/Applications/Socket Manager.app"
if [ -e "$DESTINATION" ]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$EXISTING_ID" != "ch.samuelheinrich.socketmanager" ]; then
        printf 'Ziel gehört einer anderen App: %s\n' "$DESTINATION" >&2
        exit 1
    fi
    if /usr/bin/pgrep -f "$DESTINATION/Contents/MacOS/SocketManager" >/dev/null; then
        printf 'Bitte Socket Manager vor dem Aktualisieren über das Menü beenden.\n' >&2
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$PROJECT_DIR/dist/Socket Manager.app" "$DESTINATION"
/usr/bin/open "$DESTINATION"
printf 'Installiert und gestartet: %s\n' "$DESTINATION"
