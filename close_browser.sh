#!/bin/bash
# Close Piview browser
# This script can be run to close the browser (it will auto-restart)

# Kill chromium browser
pkill -f chromium-browser || true

# Alternative: Send ESC key via xdotool
# xdotool key Escape 2>/dev/null || true

echo "Browser closed. Piview will restart it automatically."
