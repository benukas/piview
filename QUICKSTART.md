# Piview Quick Start Guide

## Installation (One Line)

```bash
curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
```

Or if you have the files locally:

```bash
chmod +x setup.sh && ./setup.sh
```

During setup, you'll be asked for:
- URL to display
- Refresh interval (seconds)
- Whether to enable read-only mode

## Configure URL

Edit the config file:

```bash
sudo nano /etc/piview/config.json
```

Change the `url` and `refresh_interval` values.

## Start Piview

### Auto-start (Recommended)
```bash
sudo systemctl enable piview.service
sudo systemctl start piview.service
```

### Manual Start
```bash
startx
```

## Close Browser

- **Keyboard**: Press `Alt+F4`
- **Script**: `/opt/piview/close_browser.sh`
- **Command**: `pkill -f chromium-browser`

Browser will auto-restart after a few seconds.

## Read-Only Mode

```bash
# Enable (protects SD card)
sudo overlayroot.sh enable

# Disable (to make changes)
sudo overlayroot.sh disable

# Check status
sudo overlayroot.sh status
```

## Stop Piview

```bash
sudo systemctl stop piview.service
```

## Check Status

```bash
sudo systemctl status piview.service
```

## View Logs

```bash
sudo journalctl -u piview.service -f
```

## Configuration File

```
/etc/piview/config.json
```

## That's It!

Piview will display your URL and auto-refresh at the configured interval.
