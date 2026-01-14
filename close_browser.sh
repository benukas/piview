#!/bin/bash
# Close Piview browser
# This script can be run to close the browser (it will auto-restart)
# Usage: /opt/piview/close_browser.sh

# Kill chromium browser (tries both names)
pkill -f chromium-browser || pkill -f chromium || true

# Wait a moment
sleep 1

# Try to send ESC key via xdotool if available
if command -v xdotool >/dev/null 2>&1; then
    export DISPLAY=:0
    xdotool key Escape 2>/dev/null || true
fi

echo "Browser closed. Piview will restart it automatically in a few seconds."
