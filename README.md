# Piview

**Piview** is an open-source, one-shot kiosk mode setup for Raspberry Pi OS Lite. **Factory-hardened** with bulletproof screen blanking prevention, automatic recovery, and aggressive monitoring. Perfect for factory environments where screens must never shut off.

## Features

- 🚀 **One-shot setup** - Single script installs everything
- 🔄 **Auto-refresh** - Automatically refreshes the page at configurable intervals
- 🖥️ **True kiosk mode** - Fullscreen, no UI chrome, no distractions
- 🔌 **Auto-start** - Runs automatically on boot with aggressive restart policy
- 💾 **Read-only SD card** - Toggle read-only mode to protect SD card from wear
- ⏰ **Automatic time sync** - NTP time synchronization
- ⌨️ **Browser controls** - Close browser with ESC/q key or script
- 🎯 **Pi OS Lite optimized** - Works on headless Raspberry Pi OS Lite

## Factory-Hardened Features (Bulletproof)

- 🛡️ **Multi-layer screen blanking prevention** - Multiple methods to ensure screen never blanks:
  - X server settings (xset)
  - Console blanking disabled
  - HDMI power management disabled
  - Kernel parameters configured
  - Background keepalive thread
  - Backup keepalive service
- 🔄 **Automatic browser recovery** - Restarts browser if it crashes
- 📊 **Health monitoring** - Continuous health checks with automatic recovery
- 📝 **Comprehensive logging** - All events logged to `/var/log/piview.log`
- 🔁 **Aggressive restart policy** - Systemd service restarts immediately on failure
- ⚡ **No sleep/suspend** - All system sleep modes disabled
- 🎯 **Watchdog monitoring** - Background threads monitor and fix issues automatically

## Quick Start

### One-Line Installation (Recommended)

```bash
curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
```

That's it! The installer will download and set up everything automatically.

### Manual Installation

If you prefer to install manually:

1. Download Files

Transfer `piview.py` and `setup.sh` to your Raspberry Pi.

2. Run Setup

```bash
chmod +x setup.sh
./setup.sh
```

The setup script will:
- Install all dependencies (Chromium, X server, Python, etc.)
- Configure NTP time synchronization
- Set up kiosk mode with **bulletproof screen blanking prevention**
- Disable all system sleep/suspend/hibernate modes
- Configure kernel parameters to prevent console blanking
- Create configuration file
- Install systemd service with aggressive restart policy
- Install backup screen keepalive service
- Set up comprehensive logging
- Optionally enable read-only SD card mode

During setup, you'll be prompted for:
- The URL to display
- Refresh interval (seconds)
- Whether to enable read-only mode

### 3. Configure URL

Edit the configuration file:

```bash
sudo nano /etc/piview/config.json
```

Example configuration:

```json
{
  "url": "https://example.com",
  "refresh_interval": 60,
  "browser": "chromium-browser"
}
```

### 4. Start Piview

If you enabled the service during setup, it will start automatically on boot. To start manually:

```bash
sudo systemctl start piview.service
```

Or run directly (requires X server):

```bash
startx
```

## Configuration

The configuration file is located at `/etc/piview/config.json`

### Settings

- **url**: Single URL to display (required)
- **refresh_interval**: Seconds between auto-refresh (default: 60)
- **browser**: Browser executable (default: "chromium-browser")
- **kiosk_flags**: Browser flags for kiosk mode (usually don't need to change)

### Changing URL

Edit the config file and Piview will pick up changes:

```bash
sudo nano /etc/piview/config.json
```

The browser will refresh automatically at the configured interval, or you can restart the service:

```bash
sudo systemctl restart piview.service
```

## Usage

### Service Management

```bash
# Start service
sudo systemctl start piview.service

# Stop service
sudo systemctl stop piview.service

# Enable auto-start on boot
sudo systemctl enable piview.service

# Disable auto-start
sudo systemctl disable piview.service

# Check status
sudo systemctl status piview.service

# View logs
sudo journalctl -u piview.service -f
```

### Closing the Browser

**Method 1: Keyboard**
- Press `ESC` or `q` key to close browser (it will auto-restart)

**Method 2: Script**
```bash
./close_browser.sh
```

**Method 3: Kill process**
```bash
pkill -f chromium-browser
```

The browser will automatically restart after a few seconds.

### Read-Only SD Card Mode

Protect your SD card from excessive writes in factory environments:

```bash
# Enable read-only mode
sudo overlayroot.sh enable

# Disable read-only mode (to make changes)
sudo overlayroot.sh disable

# Check status
sudo overlayroot.sh status
```

**Important:** When read-only mode is enabled, you must disable it before making any system changes. After disabling, reboot for changes to take full effect.

### Time Synchronization

NTP time sync is automatically configured during setup. To manually sync:

```bash
sudo ntpdate -s time.nist.gov
```

Or restart the NTP service:

```bash
sudo systemctl restart ntp
```

## Requirements

- Raspberry Pi (tested on Raspberry Pi OS Lite)
- Internet connection (for web pages and NTP)
- Display connected to Pi
- Keyboard (optional, for closing browser)

## Troubleshooting

### Browser won't start

- Check if Chromium is installed: `which chromium-browser`
- Install if missing: `sudo apt-get install chromium-browser xserver-xorg xinit`
- Check X server is running: `echo $DISPLAY`

### URLs not loading

- Verify internet connection: `ping google.com`
- Check URLs are accessible: `curl <url>`
- Ensure URLs include `http://` or `https://`

### Service won't start

- Check logs: `sudo journalctl -u piview.service -n 50`
- Verify X server is available
- Check config file syntax: `python3 -m json.tool /etc/piview/config.json`
- Ensure user has permission to start X server

### Screen goes blank (Should NOT happen with bulletproof mode)

If screen still blanks (very rare), check:
- Screen keepalive service: `sudo systemctl status piview-keepalive.service`
- Restart keepalive: `sudo systemctl restart piview-keepalive.service`
- Check logs: `tail -f /var/log/piview.log`
- Manual fix: `xset s off -dpms s noblank && xset s reset`
- Check power management: `xset q`
- Verify display is not in power save mode
- Check kernel parameter: `cat /proc/cmdline | grep consoleblank`

### Read-only mode issues

- If you can't make changes, disable read-only mode first
- Some operations require read-write mode
- Reboot after toggling read-only mode for full effect

### Time is incorrect

- Check NTP service: `sudo systemctl status ntp`
- Manually sync: `sudo ntpdate -s pool.ntp.org`
- Check timezone: `timedatectl`

## File Locations

- Main script: `/opt/piview/piview.py`
- Configuration: `/etc/piview/config.json`
- Systemd service: `/etc/systemd/system/piview.service`
- Screen keepalive service: `/etc/systemd/system/piview-keepalive.service`
- Screen blanking prevention: `/etc/systemd/system/disable-screen-blanking.service`
- X init config: `~/.xinitrc`
- Close browser script: `/opt/piview/close_browser.sh`
- Screen keepalive script: `/opt/piview/screen_keepalive.sh`
- Read-only toggle: `/usr/local/bin/overlayroot.sh`
- Log file: `/var/log/piview.log`

## Uninstall

To remove Piview:

```bash
# Stop and disable service
sudo systemctl stop piview.service
sudo systemctl disable piview.service

# Remove service file
sudo rm /etc/systemd/system/piview.service
sudo systemctl daemon-reload

# Remove application files
sudo rm -rf /opt/piview

# Remove config (optional)
sudo rm -rf /etc/piview

# Remove read-only script (optional)
sudo rm /usr/local/bin/overlayroot.sh
```

## License

Open source - feel free to use and modify for your needs.

## Contributing

Contributions welcome! This is designed to be simple and reliable for factory environments.

## Monitoring & Logs

### View Logs

```bash
# Piview application logs
tail -f /var/log/piview.log

# Systemd service logs
sudo journalctl -u piview.service -f

# Screen keepalive logs
sudo journalctl -u piview-keepalive.service -f

# All Piview-related logs
sudo journalctl -u piview* -f
```

### Check Status

```bash
# Main service
sudo systemctl status piview.service

# Screen keepalive backup
sudo systemctl status piview-keepalive.service

# Screen blanking prevention
sudo systemctl status disable-screen-blanking.service
```

## Support

For issues or questions:
1. Check the log file: `tail -f /var/log/piview.log`
2. Review service logs: `sudo journalctl -u piview.service -n 100`
3. Check all services are running: `sudo systemctl status piview*`
4. Verify all dependencies are installed
5. Ensure read-only mode is disabled if making changes
6. Check screen blanking prevention: `xset q`
