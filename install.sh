#!/bin/bash
# Builds TokenMeter and installs it as a macOS app.
# Usage: ./install.sh
set -euo pipefail

cd "$(dirname "$0")"

APP="TokenMeter.app"

./build.sh

# Replace a running copy rather than failing on a busy bundle.
pkill -x TokenMeter 2>/dev/null || true

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

Token Meter is now in your menu bar.
- Click the pill for live windows, click again for the full report.
- Drag it anywhere; it settles against a side and stays above the Dock.
- Add it to System Settings > General > Login Items to keep it around.

Your provider is detected from ~/.claude/settings.json. If the balance
or spend does not appear, open the menu bar item > Edit Configuration…
(see README for keys, balances and pricing).
NOTE
