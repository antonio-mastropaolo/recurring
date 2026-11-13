#!/bin/bash
# Build Recurring v3, install the single canonical bundle to ~/Applications,
# link the `recurring` CLI, register login + syncd LaunchAgents, purge stale
# v1/v2 bundles + LaunchServices ghosts, and (re)launch.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Recurring v3"
DEST="$HOME/Applications/$APP_NAME.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
AGENT="$HOME/Library/LaunchAgents/com.amastro.recurring.v3.plist"
SYNC_AGENT="$HOME/Library/LaunchAgents/com.amastro.recurring.v3.syncd.plist"
PY="/opt/homebrew/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"

./scripts/test.sh

xcodegen generate --quiet
dd=$(mktemp -d)
trap 'rm -rf "$dd"' EXIT
xcodebuild -project Recurring.xcodeproj -scheme Recurring -configuration Release \
  -derivedDataPath "$dd" build -quiet
built="$dd/Build/Products/Release/$APP_NAME.app"

# Stop every running instance by exact process name (never a wildcard/grep sweep).
stop_all() {
  for pid in $(pgrep -x "$1" || true); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.5
}
stop_all "$APP_NAME"

# Stop any prior syncd instance by exact verified PID from ~/.recurring/sync_state.json.
if [ -f "$HOME/.recurring/sync_state.json" ]; then
  dpid=$("$PY" -c 'import json,pathlib; p=pathlib.Path.home()/".recurring"/"sync_state.json"; d=json.loads(p.read_text()); print(d.get("daemon_pid") or "")' 2>/dev/null || true)
  if [ -n "${dpid:-}" ] && kill -0 "$dpid" 2>/dev/null; then
    cmd_check=$(ps -p "$dpid" -o command= 2>/dev/null || true)
    case "$cmd_check" in
      *recurring*sync*--daemon*|*recurring_sync.py*) kill "$dpid" 2>/dev/null || true; sleep 0.5 ;;
    esac
  fi
fi

# Retire superseded versions: exact process name, exact bundle path, exact LaunchAgent.
for old in "Recurring v1" "Recurring v2"; do
  stop_all "$old"
  if [ -d "$HOME/Applications/$old.app" ]; then
    "$LSREG" -u "$HOME/Applications/$old.app" 2>/dev/null || true
    rm -rf "$HOME/Applications/$old.app"
  fi
done
for ver in v1 v2; do
  OLD_AGENT="$HOME/Library/LaunchAgents/com.amastro.recurring.$ver.plist"
  if [ -f "$OLD_AGENT" ]; then
    launchctl bootout "gui/$(id -u)/com.amastro.recurring.$ver" 2>/dev/null || true
    rm -f "$OLD_AGENT"
  fi
done

# Copy next to the destination first, then swap — a failed copy never leaves you with no app.
mkdir -p "$HOME/Applications"
staging="$DEST.installing"; previous="$DEST.previous"
rm -rf "$staging" "$previous"
cp -R "$built" "$staging"
[ -d "$DEST" ] && mv "$DEST" "$previous"
mv "$staging" "$DEST"
[ -d "$previous" ] && { "$LSREG" -u "$previous" 2>/dev/null || true; rm -rf "$previous"; }
"$LSREG" -u "$built" 2>/dev/null || true
"$LSREG" -kill -r -domain local -domain system -domain user 2>/dev/null || true
"$LSREG" -f "$DEST"
killall Dock 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/cli/recurring" "$HOME/.local/bin/recurring"

mkdir -p "$HOME/.recurring"
chmod 700 "$HOME/.recurring"

# 1. Login LaunchAgent for Recurring v3.app
mkdir -p "$(dirname "$AGENT")"
tmp_agent=$(mktemp)
plutil -create xml1 "$tmp_agent"
plutil -insert Label -string "com.amastro.recurring.v3" "$tmp_agent"
plutil -insert ProgramArguments -array "$tmp_agent"
plutil -insert ProgramArguments -string /usr/bin/open -append "$tmp_agent"
plutil -insert ProgramArguments -string -a -append "$tmp_agent"
plutil -insert ProgramArguments -string "$DEST" -append "$tmp_agent"
plutil -insert RunAtLoad -bool true "$tmp_agent"
plutil -lint -s "$tmp_agent"
mv "$tmp_agent" "$AGENT"
chmod 644 "$AGENT"

# 2. Persistent Invoice Sync Daemon LaunchAgent (IMAP IDLE push + 20s Gmail delta + hourly sweep)
tmp_sync=$(mktemp)
plutil -create xml1 "$tmp_sync"
plutil -insert Label -string "com.amastro.recurring.v3.syncd" "$tmp_sync"
plutil -insert ProgramArguments -array "$tmp_sync"
plutil -insert ProgramArguments -string "$PY" -append "$tmp_sync"
plutil -insert ProgramArguments -string "$PWD/cli/recurring" -append "$tmp_sync"
plutil -insert ProgramArguments -string sync -append "$tmp_sync"
plutil -insert ProgramArguments -string --daemon -append "$tmp_sync"
plutil -insert RunAtLoad -bool true "$tmp_sync"
plutil -insert KeepAlive -bool true "$tmp_sync"
plutil -insert StartInterval -integer 3600 "$tmp_sync"
plutil -insert StandardOutPath -string "$HOME/.recurring/syncd.log" "$tmp_sync"
plutil -insert StandardErrorPath -string "$HOME/.recurring/syncd.log" "$tmp_sync"
plutil -insert EnvironmentVariables -dictionary "$tmp_sync"
plutil -insert EnvironmentVariables.PATH -string "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$tmp_sync"
plutil -insert EnvironmentVariables.HOME -string "$HOME" "$tmp_sync"
plutil -lint -s "$tmp_sync"
mv "$tmp_sync" "$SYNC_AGENT"
chmod 644 "$SYNC_AGENT"

launchctl bootout "gui/$(id -u)/com.amastro.recurring.v3.syncd" 2>/dev/null || true
for _ in $(seq 1 15); do
  launchctl print "gui/$(id -u)/com.amastro.recurring.v3.syncd" >/dev/null 2>&1 || break
  sleep 0.2
done
launchctl bootstrap "gui/$(id -u)" "$SYNC_AGENT" 2>/dev/null || launchctl load -w "$SYNC_AGENT" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/com.amastro.recurring.v3.syncd" 2>/dev/null || true

open "$DEST"
echo "installed $DEST + syncd ($(git rev-parse --short HEAD 2>/dev/null || echo uncommitted))"
