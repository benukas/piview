#!/bin/bash
# Create a standalone installer that embeds all code
# Run this on a machine with GitHub access
# Output: piview-standalone-installer.sh (can be used completely offline)

set -e

echo "Creating standalone installer..."

OUTPUT_FILE="piview-standalone-installer.sh"

cat > "$OUTPUT_FILE" << 'STANDALONEEOF'
#!/bin/bash
# Piview - Standalone Installer (No Internet Required)
# This file contains all Piview code embedded
# Usage: bash piview-standalone-installer.sh

set -e

echo "=========================================="
echo "Piview - Standalone Installer"
echo "=========================================="
echo ""

# Extract embedded files
INSTALL_DIR="$HOME/piview-install"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Extracting embedded files..."

# Create setup.sh
cat > setup.sh << 'SETUPEOF'
STANDALONEEOF

# Read setup.sh and embed it
if [ -f setup.sh ]; then
    cat setup.sh >> "$OUTPUT_FILE"
else
    echo "Error: setup.sh not found. Please run this from the piview directory."
    exit 1
fi

cat >> "$OUTPUT_FILE" << 'STANDALONEEOF'
SETUPEOF

# Create piview.py
cat > piview.py << 'PYTHONEOF'
STANDALONEEOF

# Read piview.py and embed it
if [ -f piview.py ]; then
    cat piview.py >> "$OUTPUT_FILE"
else
    echo "Error: piview.py not found. Please run this from the piview directory."
    exit 1
fi

cat >> "$OUTPUT_FILE" << 'STANDALONEEOF'
PYTHONEOF

# Create other required files
cat > close_browser.sh << 'CLOSEEOF'
#!/bin/bash
# Close browser script
pkill -f chromium || pkill -f chromium-browser || true
CLOSEEOF

cat > screen_keepalive.sh << 'KEEPALIVEEOF'
#!/bin/bash
# Screen keepalive script
while true; do
    sleep 30
    xset s reset 2>/dev/null || true
    xset -dpms 2>/dev/null || true
done
KEEPALIVEEOF

chmod +x setup.sh close_browser.sh screen_keepalive.sh

echo "Files extracted!"
echo ""
echo "Running setup..."
echo ""
./setup.sh

# Cleanup
cd "$HOME"
rm -rf "$INSTALL_DIR"

echo ""
echo "Installation complete!"
STANDALONEEOF

chmod +x "$OUTPUT_FILE"

echo "Standalone installer created: $OUTPUT_FILE"
echo ""
echo "This file can be transferred to your Pi and run completely offline."
echo "File size: $(du -h $OUTPUT_FILE | cut -f1)"
