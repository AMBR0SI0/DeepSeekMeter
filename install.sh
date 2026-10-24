#!/bin/bash
# Builds DeepSeekMeter and installs it as a macOS app.
# Usage: ./install.sh
set -euo pipefail

cd "$(dirname "$0")"

APP="DeepSeekMeter.app"

./build.sh

# Replace a running copy rather than failing on a busy bundle.
pkill -x DeepSeekMeter 2>/dev/null || true

DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/$APP"

echo "installed: $DEST/$APP"

# First launch registers the menu bar item; the app has no Dock icon.
open "$DEST/$APP"

cat <<'NOTE'

DeepSeek Meter is now in your menu bar.
- Hover the pill for live windows, click it for the full report.
- Drag it to either screen edge; it remembers the corner.
- Add it to System Settings > General > Login Items to keep it around.

If the balance does not appear, set DEEPSEEK_API_KEY or make sure
~/.claude/settings.json has env.ANTHROPIC_AUTH_TOKEN (see README).
NOTE
