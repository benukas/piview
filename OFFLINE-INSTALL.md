# Offline Installation Guide

If your network blocks GitHub, you can install Piview offline using one of these methods:

## Method 1: Manual File Transfer (Recommended)

### Step 1: Download Files (on a machine with GitHub access)

Download these files from GitHub:
- `setup.sh`
- `piview.py`
- `install-offline.sh`
- `close_browser.sh`
- `screen_keepalive.sh`
- `export_logs.sh`

Or download the entire repository as a ZIP file from GitHub.

### Step 2: Transfer to Raspberry Pi

Transfer the files to your Raspberry Pi using one of these methods:

**Option A: USB Drive**
```bash
# On Pi, mount USB drive and copy files
sudo mkdir -p /mnt/usb
sudo mount /dev/sda1 /mnt/usb  # Adjust device as needed
cp /mnt/usb/piview/* ~/
cd ~/
```

**Option B: SCP/SFTP (from another machine)**
```bash
# From your computer (with GitHub access)
scp setup.sh piview.py install-offline.sh pi@raspberrypi.local:~/
```

**Option C: Direct Copy/Paste**
```bash
# On Pi, create directory and paste file contents
mkdir -p ~/piview
cd ~/piview
# Then copy/paste file contents using nano or vi
```

### Step 3: Run Offline Installer

```bash
cd ~/piview  # or wherever you put the files
chmod +x install-offline.sh
bash install-offline.sh
```

## Method 2: Create Standalone Installer Script

### Step 1: Create installer script

On a machine with GitHub access, create a file called `piview-standalone.sh`:

```bash
#!/bin/bash
# This script embeds all Piview code and can run completely offline

# [All setup.sh and piview.py code embedded here]
# See create-standalone.sh for generation script
```

### Step 2: Transfer and Run

Transfer the standalone script to your Pi and run:
```bash
chmod +x piview-standalone.sh
./piview-standalone.sh
```

## Method 3: Use Alternative Download Source

If you have access to other sources, you can modify `install.sh` to download from:
- A company internal Git server
- A file server
- A CDN
- A USB drive path

## Quick Setup (Minimal Files)

If you only have `setup.sh` and `piview.py`:

```bash
# On your Pi
chmod +x setup.sh
./setup.sh
```

The setup script will handle everything else.

## Troubleshooting

### "setup.sh not found"
- Make sure you're in the directory containing setup.sh
- Check file permissions: `ls -la setup.sh`

### "Permission denied"
- Make script executable: `chmod +x setup.sh`
- Don't run as root (the script will check this)

### "Network required for package installation"
- The setup script needs internet to install packages (apt-get)
- If you're completely offline, you'll need to:
  1. Install dependencies manually first
  2. Or use a Pi with internet access for initial setup

## Required Dependencies (if installing completely offline)

If you need to install dependencies manually:

```bash
sudo apt-get update
sudo apt-get install -y \
    chromium-browser \
    xserver-xorg \
    xinit \
    x11-xserver-utils \
    xdotool \
    unclutter \
    python3 \
    python3-pip \
    watchdog \
    ca-certificates \
    libnss3-tools \
    wpasupplicant \
    wireless-tools
```

Then run `./setup.sh` which will skip package installation.
