#!/usr/bin/env bash
#
# Launches a built v2s.app and fails if the process dies during startup.
#
# A binary that binds a symbol the running macOS does not have is killed by
# dyld before AppKit draws anything, so users only see "nothing happens" when
# they open the app. Running this on every macOS version we support catches
# that before a release ships.
#
# Usage: scripts/smoke_launch.sh path/to/v2s.app [seconds]

set -euo pipefail

APP_PATH="${1:?usage: $0 path/to/v2s.app [seconds]}"
ALIVE_SECONDS="${2:-15}"
EXECUTABLE="$APP_PATH/Contents/MacOS/v2s"
LOG_FILE="$(mktemp -t v2s-launch)"
STARTED_MARKER="$(mktemp -t v2s-started)"

echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
echo "Binary architectures: $(lipo -archs "$EXECUTABLE")"
echo "Minimum macOS: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist")"

"$EXECUTABLE" >"$LOG_FILE" 2>&1 &
APP_PID=$!

for ((second = 0; second < ALIVE_SECONDS; second++)); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if kill -0 "$APP_PID" 2>/dev/null; then
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "v2s stayed running for ${ALIVE_SECONDS}s."
  exit 0
fi

set +e
wait "$APP_PID"
STATUS=$?
set -e

echo "::error::v2s exited during startup with status ${STATUS}"
echo "----- v2s output -----"
cat "$LOG_FILE"
echo "----------------------"

# The reason for a crash is in its crash report, which ReportCrash can take most of a minute to write.
REPORT=""
for ((attempt = 0; attempt < 60; attempt++)); do
  REPORT="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'v2s*.ips' -newer "$STARTED_MARKER" 2>/dev/null | head -n 1)"
  [[ -n "$REPORT" ]] && break
  sleep 1
done

if [[ -n "$REPORT" ]]; then
  echo "----- crash report: $REPORT -----"
  python3 - "$REPORT" <<'PY'
import json
import sys

with open(sys.argv[1]) as report:
    report.readline()  # The first line is a summary header.
    crash = json.load(report)

for key in ("exception", "termination", "asi"):
    if key in crash:
        print(f"{key}: {json.dumps(crash[key])}")

images = crash.get("usedImages", [])
thread = crash["threads"][crash.get("faultingThread", 0)]
for frame in thread.get("frames", [])[:40]:
    image = images[frame["imageIndex"]] if frame.get("imageIndex", -1) < len(images) else {}
    print(f"  {image.get('name', '?'):<32} {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")
PY
fi

exit 1
