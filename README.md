# Piview

**Piview** is an open-source, one-shot kiosk mode setup for Raspberry Pi OS Lite. **Factory-hardened** with bulletproof screen blanking prevention, automatic recovery, and aggressive monitoring. Perfect for factory environments where screens must never shut off.

## Features

- 🚀 **One-shot setup** - Single script installs everything
- 🔄 **Auto-refresh** - Automatically refreshes the page at configurable intervals
- 🖥️ **True kiosk mode** - Fullscreen, no UI chrome, no distractions
- 🔌 **Auto-start** - Runs automatically on boot with aggressive restart policy
- 💾 **Read-only SD card** - Toggle read-only mode to protect SD card from wear
- ⏰ **Automatic time sync** - NTP time synchronization
- ⌨️ **Browser controls** - Close browser with Alt+F4 or script
- 🎯 **Pi OS Lite optimized** - Works on headless Raspberry Pi OS Lite
- 🔒 **SSL certificate support** - Install certificates or bypass SSL errors
- 🛡️ **Hardware watchdog** - Auto-reboot on kernel freeze (optional)

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
- ✅ **"Exited Cleanly" fix** - Prevents Chromium crash nag bars
- 🔧 **Hardware watchdog** - Auto-reboots Pi if kernel freezes (optional)

## Quick Start

### One-Line Installation (Recommended)

```bash
curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
```

That's it! The installer will download and set up everything automatically.

### Manual Installation

If you prefer to install manually:

1. **Download Files**

Transfer `piview.py` and `setup.sh` to your Raspberry Pi.

2. **Run Setup**

```bash
chmod +x setup.sh
./setup.sh
```

The setup script will:
- **Configure WiFi** (SSID and password) - Essential for Pi OS Lite command-line setup
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
- Optionally configure hardware watchdog

During setup, you'll be prompted for:
- **WiFi SSID and password** (optional - for Pi OS Lite)
- The URL to display
- Refresh interval (seconds)
- **SSL certificate handling** (install certificate, ignore errors, or use defaults)
- Whether to enable read-only mode
- Whether to enable hardware watchdog (recommended for factory)

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
  "browser": "chromium-browser",
  "ignore_ssl_errors": true
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
- **ignore_ssl_errors**: Ignore SSL certificate errors (default: true) - Useful for self-signed certs in factory environments
- **cert_installed**: Whether SSL certificate was installed locally (set automatically)
- **connection_retry_delay**: Seconds to wait before retrying failed connections (default: 5)
- **max_connection_retries**: Maximum retries for connection failures (default: 3)
- **kiosk_flags**: Browser flags for kiosk mode (usually don't need to change)

### SSL Certificate Options

During setup, you can choose:

1. **Install certificate file** (recommended - most secure)
   - Provide path to `.crt` or `.pem` file
   - Certificate is installed to system store and Chromium's NSS database
   - Chromium will trust the certificate natively

2. **Ignore SSL errors** (for testing/development)
   - Uses Chromium flags to bypass SSL certificate validation
   - Useful for self-signed certificates in factory environments

3. **Use system defaults** (no special handling)
   - Standard SSL validation
   - Will show errors for self-signed certificates

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
- Press `Alt+F4` to close browser (it will auto-restart)

**Method 2: Script**
```bash
/opt/piview/close_browser.sh
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

### Hardware Watchdog

If enabled during setup, the hardware watchdog will automatically reboot the Pi if the kernel freezes (due to power spikes, RAM glitches, etc.).

**To enable manually:**
1. Edit `/boot/config.txt` and add: `dtparam=watchdog=on`
2. Install: `sudo apt-get install watchdog`
3. Edit `/etc/watchdog.conf` and uncomment: `watchdog-device = /dev/watchdog`
4. Enable: `sudo systemctl enable --now watchdog`
5. Reboot for changes to take effect

**To disable:**
1. Remove `dtparam=watchdog=on` from `/boot/config.txt`
2. Disable service: `sudo systemctl disable watchdog`
3. Reboot

### Time Synchronization

NTP time sync is automatically configured during setup. To manually sync:

```bash
sudo ntpdate -s time.nist.gov
```

Or restart the NTP service:

```bash
sudo systemctl restart systemd-timesyncd
# or
sudo systemctl restart ntp
```

## Uninstall

To completely remove Piview:

```bash
# Use the uninstall script (recommended)
./uninstall.sh

# Or manually:
sudo systemctl stop piview.service
sudo systemctl disable piview.service
sudo rm /etc/systemd/system/piview.service
sudo rm /etc/systemd/system/piview-keepalive.service
sudo rm /etc/systemd/system/disable-screen-blanking.service
sudo systemctl daemon-reload
sudo rm -rf /opt/piview
sudo rm -rf /etc/piview  # Optional - removes config
```

## Requirements

- Raspberry Pi (tested on Raspberry Pi OS Lite and Desktop)
- Internet connection (for web pages and NTP)
- Display connected to Pi
- Keyboard (optional, for closing browser with Alt+F4)

## Troubleshooting

### Browser won't start

- Check if Chromium is installed: `which chromium-browser`
- Install if missing: `sudo apt-get install chromium-browser xserver-xorg xinit`
- Check X server is running: `echo $DISPLAY`
- Check logs: `tail -f /var/log/piview.log`

### URLs not loading / SSL errors / Connection issues

- **SSL Certificate Errors**: 
  - If you installed a certificate, verify it's in the system store: `ls /usr/local/share/ca-certificates/`
  - If using ignore SSL errors, check config: `cat /etc/piview/config.json | grep ignore_ssl_errors`
- **Connection Failures**: Piview automatically retries connections. Check logs: `tail -f /var/log/piview.log`
- Verify internet connection: `ping google.com`
- Check URLs are accessible: `curl -k <url>` (the -k flag ignores SSL like Piview does)
- Ensure URLs include `http://` or `https://`
- Check network connectivity: `curl -v <url>`
- Browser will automatically restart on connection failures

### Service won't start

- Check logs: `sudo journalctl -u piview.service -n 50`
- Verify X server is available: `xset q`
- Check config file syntax: `python3 -m json.tool /etc/piview/config.json`
- Ensure user has permission to start X server
- Check all services: `sudo systemctl status piview*`

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

- Check NTP service: `sudo systemctl status systemd-timesyncd` or `sudo systemctl status ntp`
- Manually sync: `sudo ntpdate -s pool.ntp.org`
- Check timezone: `timedatectl`

### Chromium shows "didn't shut down correctly" nag bar

This should be automatically fixed by Piview. If you still see it:
- Check that Piview is running: `sudo systemctl status piview.service`
- Restart the service: `sudo systemctl restart piview.service`
- The fix is applied automatically before each browser launch

### Export Logs

To export all logs for troubleshooting:

```bash
/opt/piview/export_logs.sh
# or
piview-export-logs
```

This creates a tarball with all relevant logs and system information.

## File Locations

- Main script: `/opt/piview/piview.py`
- Configuration: `/etc/piview/config.json`
- Systemd service: `/etc/systemd/system/piview.service`
- Screen keepalive service: `/etc/systemd/system/piview-keepalive.service`
- Screen blanking prevention: `/etc/systemd/system/disable-screen-blanking.service`
- X init config: `~/.xinitrc` (Pi OS Lite) or `~/.config/autostart/piview.desktop` (Desktop)
- Close browser script: `/opt/piview/close_browser.sh`
- Screen keepalive script: `/opt/piview/screen_keepalive.sh`
- Export logs script: `/opt/piview/export_logs.sh` (also at `/usr/local/bin/piview-export-logs`)
- Log file: `/var/log/piview.log`

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

# Hardware watchdog (if enabled)
sudo systemctl status watchdog
```

## Support

For issues or questions:
1. Check the log file: `tail -f /var/log/piview.log`
2. Review service logs: `sudo journalctl -u piview.service -n 100`
3. Check all services are running: `sudo systemctl status piview*`
4. Export logs: `/opt/piview/export_logs.sh`
5. Verify all dependencies are installed
6. Ensure read-only mode is disabled if making changes
7. Check screen blanking prevention: `xset q`

## License

Open source - feel free to use and modify for your needs.

## Contributing

Contributions welcome! This is designed to be simple and reliable for factory environments.
