#!/usr/bin/env python3
"""
Piview - Bulletproof Kiosk Mode for Pi OS Lite
Factory-hardened with aggressive screen blanking prevention and auto-recovery
"""

import json
import time
import subprocess
import os
import sys
import signal
import threading
import logging
import urllib.request
import ssl
from pathlib import Path
from datetime import datetime

# Configuration file path
CONFIG_FILE = Path("/etc/piview/config.json")
USER_CONFIG_FILE = Path.home() / ".piview" / "config.json"
LOG_FILE = Path("/var/log/piview.log")

DEFAULT_CONFIG = {
    "url": "http://example.com",
    "refresh_interval": 60,  # seconds
    "browser": "chromium-browser",
    "health_check_interval": 10,  # seconds between health checks
    "max_browser_restarts": 10,  # max restarts before giving up
    "ignore_ssl_errors": True,  # Ignore SSL certificate errors (for self-signed certs)
    "connection_retry_delay": 5,  # seconds to wait before retrying connection
    "max_connection_retries": 3,  # max retries for connection failures
    "kiosk_flags": [
        "--kiosk",
        "--noerrdialogs",
        "--disable-infobars",
        "--disable-session-crashed-bubble",
        "--disable-restore-session-state",
        "--disable-sync",
        "--disable-dev-shm-usage",
        "--no-sandbox",
        "--disable-gpu",
        "--user-data-dir=/tmp/chromium-ssl-bypass"
    ]
}

class Piview:
    def __init__(self):
        # Initialize logger FIRST - before anything else that might use it
        self.logger = None
        
        self.running = True
        self.browser_process = None
        self.browser_restart_count = 0
        self.browser_launch_time = 0  # Track when browser was launched (for ignoring early exits)
        self.last_browser_check = time.time()
        self.last_screen_keepalive = time.time()
        self.last_health_check = time.time()
        self.connection_failures = 0
        self.last_url_check = 0
        self.consecutive_network_failures = 0
        self.network_failover_triggered = False
        
        # Setup X server environment EARLY (before logging, so it's available)
        self.setup_x_environment()
        
        # Setup logging (must be early)
        self.setup_logging()
        
        # Load config after logging is ready
        self.config = self.load_config()
        
        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        
        # Initialize screen blanking prevention
        self.prevent_screen_blanking()
        
        # Start background threads
        self.start_background_threads()
    
    def setup_x_environment(self):
        """Setup X server environment variables early"""
        # Set DISPLAY
        display = os.environ.get('DISPLAY', ':0')
        os.environ['DISPLAY'] = display
        
        # Set XAUTHORITY if not already set
        if 'XAUTHORITY' not in os.environ:
            # Try to get actual user (not just from env)
            try:
                import pwd
                username = pwd.getpwuid(os.getuid()).pw_name
            except Exception:
                username = os.environ.get('USER', os.environ.get('USERNAME', 'pi'))
            
            xauth_paths = [
                f"/home/{username}/.Xauthority",
                os.path.expanduser("~/.Xauthority"),
                f"/root/.Xauthority"
            ]
            
            for xauth_path in xauth_paths:
                if os.path.exists(xauth_path):
                    os.environ['XAUTHORITY'] = xauth_path
                    break
            else:
                # If not found, try to create it or use xauth to generate
                try:
                    # Try to get XAUTHORITY from xauth
                    result = subprocess.run(
                        ["xauth", "list"],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        timeout=2,
                        env=dict(os.environ, DISPLAY=display)
                    )
                    if result.returncode == 0:
                        # Xauth works, use default location
                        default_xauth = os.path.expanduser("~/.Xauthority")
                        os.environ['XAUTHORITY'] = default_xauth
                except Exception:
                    pass
    
    def setup_logging(self):
        """Setup logging to file and console"""
        # Always initialize logger to None first
        self.logger = None
        
        try:
            # Ensure log directory exists
            try:
                LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                # Can't create directory, use fallback
                print(f"Warning: Could not create log directory: {e}", file=sys.stderr)
                return
            
            # Try to set up file logging
            try:
                file_handler = logging.FileHandler(LOG_FILE)
                file_handler.setLevel(logging.INFO)
                file_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
            except Exception as e:
                # Can't create file handler, continue with console only
                print(f"Warning: Could not create log file: {e}", file=sys.stderr)
                file_handler = None
            
            # Set up console handler
            console_handler = logging.StreamHandler(sys.stdout)
            console_handler.setLevel(logging.INFO)
            console_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
            
            # Configure logger
            self.logger = logging.getLogger(__name__)
            self.logger.setLevel(logging.INFO)
            self.logger.handlers.clear()  # Clear any existing handlers
            
            if file_handler:
                self.logger.addHandler(file_handler)
            self.logger.addHandler(console_handler)
            
        except Exception as e:
            # Complete fallback - just use print
            print(f"Warning: Logging setup failed: {e}", file=sys.stderr)
            self.logger = None
    
    def log(self, message, level='info'):
        """Log a message"""
        if self.logger:
            if level == 'error':
                self.logger.error(message)
            elif level == 'warning':
                self.logger.warning(message)
            else:
                self.logger.info(message)
        else:
            print(f"[{datetime.now()}] {message}")
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        self.log("Shutting down Piview...")
        self.running = False
        self.close_browser()
        sys.exit(0)
    
    def prevent_screen_blanking(self):
        """Prevent screen blanking - user-space layer (kernel handled by systemd service)"""
        try:
            # User-space layer: xset commands (if X is available)
            # Kernel layer is handled by disable-screen-blanking.service (consoleblank=0)
            if os.environ.get('DISPLAY'):
                subprocess.run(
                    ["xset", "s", "off", "-dpms", "s", "noblank"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
            
            # Note: tvservice is deprecated but kept for compatibility
            # It will fail gracefully on newer firmware
            try:
                subprocess.run(
                    ["tvservice", "-p"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
            except Exception:
                pass  # Expected on newer firmware
            
        except Exception as e:
            self.log(f"Warning: Could not set screen blanking prevention: {e}", 'warning')
    
    def keep_screen_alive(self):
        """Periodically send keepalive signals to prevent screen blanking"""
        try:
            if os.environ.get('DISPLAY'):
                # Move mouse slightly (invisible to user)
                subprocess.run(
                    ["xdotool", "mousemove_relative", "--", "1", "0"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1
                )
                time.sleep(0.1)
                subprocess.run(
                    ["xdotool", "mousemove_relative", "--", "-1", "0"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1
                )
                
                # Re-apply xset settings
                subprocess.run(
                    ["xset", "s", "reset"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1
                )
        except Exception:
            pass
    
    def screen_keepalive_thread(self):
        """Background thread to keep screen alive"""
        while self.running:
            try:
                time.sleep(30)  # Every 30 seconds
                if time.time() - self.last_screen_keepalive >= 30:
                    self.keep_screen_alive()
                    self.prevent_screen_blanking()
                    self.last_screen_keepalive = time.time()
            except Exception as e:
                self.log(f"Screen keepalive error: {e}", 'warning')
                time.sleep(60)
    
    def health_check_thread(self):
        """Background thread for health monitoring"""
        while self.running:
            try:
                time.sleep(self.config.get("health_check_interval", 10))
                
                # Check browser process (but ignore exits during first 15s after launch)
                if self.browser_process:
                    if self.browser_process.poll() is not None:
                        elapsed = time.time() - self.browser_launch_time if self.browser_launch_time > 0 else 999
                        if elapsed < 15:
                            self.log(f"Browser exited during startup phase ({elapsed:.1f}s) - ignoring (may be normal)", 'info')
                        else:
                            self.log("Browser process died, restarting...", 'warning')
                            self.restart_browser()
                
                # Check X server
                if os.environ.get('DISPLAY'):
                    result = subprocess.run(
                        ["xset", "q"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=2
                    )
                    if result.returncode != 0:
                        self.log("X server not responding, may need restart", 'warning')
                
                # Check network connectivity (for failover)
                url = self.config.get("url", "")
                if url and time.time() - self.last_url_check > 30:  # Check every 30 seconds
                    if not self.check_url_connectivity(url):
                        self.consecutive_network_failures += 1
                        self.log(f"Network connectivity check failed ({self.consecutive_network_failures} consecutive)", 'warning')
                        
                        # Trigger failover after 3 consecutive failures
                        if self.consecutive_network_failures >= 3 and not self.network_failover_triggered:
                            self.force_network_failover()
                    else:
                        self.consecutive_network_failures = 0
                        if self.network_failover_triggered:
                            self.log("Network connectivity restored", 'info')
                            self.network_failover_triggered = False
                    self.last_url_check = time.time()
                
                # Re-apply screen blanking prevention
                self.prevent_screen_blanking()
                
                self.last_health_check = time.time()
            except Exception as e:
                self.log(f"Health check error: {e}", 'warning')
                time.sleep(30)
    
    def start_background_threads(self):
        """Start background monitoring threads"""
        try:
            screen_thread = threading.Thread(target=self.screen_keepalive_thread, daemon=True)
            screen_thread.start()
            
            health_thread = threading.Thread(target=self.health_check_thread, daemon=True)
            health_thread.start()
        except Exception as e:
            self.log(f"Could not start background threads: {e}", 'warning')
    
    def load_config(self):
        """Load configuration from file"""
        # Try user config first, then system config, then defaults
        config_file = USER_CONFIG_FILE if USER_CONFIG_FILE.exists() else CONFIG_FILE
        
        if not config_file.exists():
            # Create user config with defaults
            if config_file == USER_CONFIG_FILE:
                config_file.parent.mkdir(parents=True, exist_ok=True)
                self.save_config(DEFAULT_CONFIG, config_file)
            return DEFAULT_CONFIG.copy()
        
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)
                # Merge with defaults
                merged = DEFAULT_CONFIG.copy()
                merged.update(config)
                return merged
        except (json.JSONDecodeError, IOError) as e:
            self.log(f"Error loading config: {e}. Using defaults.", 'warning')
            return DEFAULT_CONFIG.copy()
    
    def save_config(self, config, config_file=None):
        """Save configuration to file"""
        if config_file is None:
            config_file = USER_CONFIG_FILE if USER_CONFIG_FILE.exists() else CONFIG_FILE
        
        config_file.parent.mkdir(parents=True, exist_ok=True)
        try:
            with open(config_file, 'w') as f:
                json.dump(config, f, indent=2)
        except IOError as e:
            self.log(f"Error saving config: {e}", 'error')
    
    def close_browser(self):
        """Close the browser aggressively"""
        if self.browser_process:
            try:
                self.browser_process.terminate()
                self.browser_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    self.browser_process.kill()
                    self.browser_process.wait(timeout=2)
                except Exception:
                    pass
            except Exception as e:
                self.log(f"Error closing browser: {e}", 'warning')
            finally:
                self.browser_process = None
        
        # Kill any remaining browser processes aggressively
        for _ in range(3):
            try:
                subprocess.run(
                    ["pkill", "-9", "-f", self.config["browser"]],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                time.sleep(0.5)
            except Exception:
                pass
    
    def refresh_page(self):
        """Refresh the current page with connection verification"""
        if self.browser_process and self.browser_process.poll() is None:
            try:
                # Check URL connectivity before refresh
                url = self.config.get("url", "")
                if url and time.time() - self.last_url_check > 30:  # Check every 30 seconds
                    if not self.check_url_connectivity(url):
                        self.log("URL not reachable, restarting browser...", 'warning')
                        self.restart_browser()
                        self.last_url_check = time.time()
                        return True
                    self.last_url_check = time.time()
                
                # Try F5 key first
                subprocess.run(
                    ["xdotool", "key", "F5"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                self.log("Page refreshed via F5")
                return True
            except Exception as e:
                # If xdotool fails, reload the page by restarting browser
                self.log(f"F5 refresh failed ({e}), restarting browser...", 'warning')
                self.restart_browser()
                return True
        else:
            # Browser not running, restart it
            self.restart_browser()
            return True
    
    def restart_browser(self):
        """Restart the browser with the URL - with retry logic"""
        max_restarts = self.config.get("max_browser_restarts", 10)
        
        if self.browser_restart_count >= max_restarts:
            self.log(f"Max browser restarts ({max_restarts}) reached. Waiting before retry...", 'error')
            time.sleep(60)
            self.browser_restart_count = 0
        
        self.close_browser()
        time.sleep(2)  # Give it time to fully close
        
        # Re-apply screen blanking prevention before opening browser
        self.prevent_screen_blanking()
        
        if self.open_url(self.config["url"]):
            self.browser_restart_count = 0
            self.log("Browser restarted successfully")
        else:
            self.browser_restart_count += 1
            self.log(f"Browser restart failed (attempt {self.browser_restart_count})", 'warning')
            time.sleep(5)
    
    def wait_for_x_server(self, max_wait=30):
        """Wait for X server to be ready"""
        display = os.environ.get('DISPLAY', ':0')
        waited = 0
        while waited < max_wait:
            try:
                result = subprocess.run(
                    ["xset", "q"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                if result.returncode == 0:
                    self.log("X server is ready")
                    return True
            except Exception:
                pass
            
            time.sleep(1)
            waited += 1
            if waited % 5 == 0:
                self.log(f"Waiting for X server... ({waited}/{max_wait}s)", 'warning')
        
        self.log("X server not ready after waiting", 'error')
        return False
    
    def find_browser(self):
        """Find the browser executable"""
        browsers = ["chromium-browser", "chromium", "google-chrome", "chrome"]
        for browser in browsers:
            try:
                result = subprocess.run(
                    ["which", browser],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                if result.returncode == 0:
                    return browser
            except Exception:
                continue
        return None
    
    def fix_chromium_exit_status(self):
        """Force Chromium to think it exited cleanly - prevents 'Chromium didn't shut down correctly' nag bar"""
        try:
            # Find user-data-dir from kiosk flags
            user_data_dir = None
            for flag in self.config.get("kiosk_flags", []):
                if flag.startswith("--user-data-dir="):
                    user_data_dir = flag.split("=", 1)[1]
                    break
            
            # Default to the standard location if not specified
            if not user_data_dir:
                user_data_dir = "/tmp/chromium-ssl-bypass"
            
            pref_file = Path(user_data_dir) / "Default" / "Preferences"
            
            # Create directory structure if it doesn't exist
            pref_file.parent.mkdir(parents=True, exist_ok=True)
            
            # Read existing preferences or create new
            prefs = {}
            if pref_file.exists():
                try:
                    with open(pref_file, 'r') as f:
                        prefs = json.load(f)
                except (json.JSONDecodeError, IOError):
                    prefs = {}
            
            # Set exit status to clean
            if "profile" not in prefs:
                prefs["profile"] = {}
            prefs["profile"]["exited_cleanly"] = True
            prefs["profile"]["exit_type"] = "Normal"
            
            # Also set in session state if it exists
            if "session" not in prefs:
                prefs["session"] = {}
            prefs["session"]["restore_on_startup"] = 0  # Don't restore sessions
            
            # Write back
            with open(pref_file, 'w') as f:
                json.dump(prefs, f)
            
            self.log("Chromium exit status fixed (exited cleanly)")
        except Exception as e:
            # Silently fail - this is a nice-to-have, not critical
            pass
    
    def check_url_connectivity(self, url):
        """Check if URL is reachable before opening browser - includes DNS check"""
        try:
            from urllib.parse import urlparse
            
            # Parse URL to get hostname
            parsed = urlparse(url)
            hostname = parsed.hostname
            
            if not hostname:
                self.log(f"Invalid URL (no hostname): {url}", 'error')
                return False
            
            # First check DNS resolution
            try:
                import socket
                socket.gethostbyname(hostname)
                self.log(f"DNS resolution successful for {hostname}")
            except socket.gaierror as e:
                self.log(f"DNS resolution failed for {hostname}: {e}", 'error')
                self.log("This will cause 'DNS probe finished nxdomain' error in browser", 'error')
                return False
            except Exception as e:
                self.log(f"DNS check error: {e}", 'warning')
            
            # Create SSL context that ignores certificate errors if configured
            if self.config.get("ignore_ssl_errors", True):
                ssl_context = ssl.create_default_context()
                ssl_context.check_hostname = False
                ssl_context.verify_mode = ssl.CERT_NONE
            else:
                ssl_context = None
            
            # Try to connect
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            try:
                with urllib.request.urlopen(req, timeout=10, context=ssl_context) as response:
                    return response.status in [200, 301, 302, 303, 307, 308]
            except urllib.error.HTTPError as e:
                # HTTP error but connection works
                return e.code < 500
            except (urllib.error.URLError, Exception) as e:
                # Don't log every failure - only log if it's a persistent issue
                return False
        except Exception as e:
            return False
    
    def find_ethernet_interface(self):
        """Find the ethernet interface name"""
        interfaces = ["eth0", "enp1s0", "enx", "enp2s0"]  # Common ethernet names
        for iface in interfaces:
            if os.path.exists(f"/sys/class/net/{iface}"):
                return iface
        # Try to find any ethernet interface
        if os.path.exists("/sys/class/net"):
            for iface in os.listdir("/sys/class/net"):
                if iface.startswith("eth") or iface.startswith("en"):
                    # Check if it's not a WiFi interface
                    if not iface.startswith("wlan") and not iface.startswith("wlp"):
                        return iface
        return None
    
    def find_wifi_interface(self):
        """Find the WiFi interface name - prefer configured failover interface"""
        # Use configured failover interface if available
        if self.config.get("network_failover_enabled", False):
            configured_interface = self.config.get("failover_wifi_interface", "")
            if configured_interface and os.path.exists(f"/sys/class/net/{configured_interface}"):
                return configured_interface
        
        # Fallback to auto-detection
        interfaces = ["wlan0", "wlp1s0", "wlp2s0"]  # Common WiFi names
        for iface in interfaces:
            if os.path.exists(f"/sys/class/net/{iface}"):
                return iface
        # Try to find any WiFi interface
        if os.path.exists("/sys/class/net"):
            for iface in os.listdir("/sys/class/net"):
                if iface.startswith("wlan") or iface.startswith("wlp"):
                    return iface
        return None
    
    def force_network_failover(self):
        """
        If LAN is acting up but technically 'connected', 
        force it down to trigger the WiFi failover.
        Only works if network failover is enabled in config.
        """
        if not self.config.get("network_failover_enabled", False):
            self.log("Network failover not enabled in config, skipping", 'warning')
            return
        
        self.log("Connectivity lost on primary port. Forcing network failover...", 'warning')
        self.network_failover_triggered = True
        
        eth_interface = self.find_ethernet_interface()
        wifi_interface = self.find_wifi_interface()
        failover_ssid = self.config.get("failover_wifi_ssid", "")
        
        if not eth_interface:
            self.log("No ethernet interface found, skipping failover", 'warning')
            return
        
        if not wifi_interface:
            self.log("No WiFi interface found, cannot failover", 'error')
            return
        
        if failover_ssid:
            self.log(f"Switching to failover WiFi network: {failover_ssid}", 'info')
        
        try:
            # Try NetworkManager first (modern Pi OS)
            if subprocess.run(["which", "nmcli"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                self.log(f"Using NetworkManager to disconnect {eth_interface}...", 'info')
                subprocess.run(
                    ["sudo", "nmcli", "device", "disconnect", eth_interface],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False
                )
                # Ensure WiFi is connected
                subprocess.run(
                    ["sudo", "nmcli", "device", "connect", wifi_interface],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False
                )
            else:
                # Fallback to traditional networking
                self.log(f"Using traditional networking to bring down {eth_interface}...", 'info')
                subprocess.run(
                    ["sudo", "ifdown", eth_interface],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False
                )
                # Bring WiFi up
                subprocess.run(
                    ["sudo", "ifup", wifi_interface],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False
                )
            
            self.log(f"Network failover triggered: {eth_interface} -> {wifi_interface}", 'warning')
            self.log("Waiting for WiFi to establish connection...", 'info')
            time.sleep(5)
            
            # Verify WiFi is working
            if self.check_url_connectivity(self.config.get("url", "")):
                self.log("WiFi failover successful - connectivity restored", 'info')
            else:
                self.log("WiFi failover completed but connectivity not yet restored", 'warning')
                
        except Exception as e:
            self.log(f"Error during network failover: {e}", 'error')
    
    def open_url(self, url):
        """Open a URL in kiosk mode with error handling and connection verification"""
        self.close_browser()
        
        # Wait for X server to be ready
        if not self.wait_for_x_server():
            self.log("X server not available, cannot open browser", 'error')
            return False
        
        # Set display and XAUTHORITY (critical for X server authentication)
        display = os.environ.get('DISPLAY', ':0')
        os.environ['DISPLAY'] = display
        
        # Set XAUTHORITY if not already set - required for Chromium to authenticate with X server
        if 'XAUTHORITY' not in os.environ:
            # Try common locations
            username = os.environ.get('USER', os.environ.get('USERNAME', 'pi'))
            xauth_paths = [
                f"/home/{username}/.Xauthority",
                os.path.expanduser("~/.Xauthority"),
                "/root/.Xauthority"
            ]
            for xauth_path in xauth_paths:
                if os.path.exists(xauth_path):
                    os.environ['XAUTHORITY'] = xauth_path
                    self.log(f"Set XAUTHORITY={xauth_path}")
                    break
            else:
                # If not found, try to detect from X server
                try:
                    result = subprocess.run(
                        ["xauth", "list"],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        timeout=2
                    )
                    if result.returncode == 0:
                        # Xauth works, try to find the file
                        xauth_file = os.path.expanduser("~/.Xauthority")
                        if os.path.exists(xauth_file):
                            os.environ['XAUTHORITY'] = xauth_file
                            self.log(f"Set XAUTHORITY={xauth_file} (detected)")
                except Exception:
                    pass
        
        # Log X server environment for debugging
        self.log(f"X Server Environment: DISPLAY={os.environ.get('DISPLAY')}, XAUTHORITY={os.environ.get('XAUTHORITY', 'NOT SET')}")
        
        # Verify X server is actually working
        try:
            subprocess.run(
                ["xset", "q"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=True
            )
        except Exception as e:
            self.log(f"X server verification failed: {e}", 'error')
            return False
        
        # Ensure screen blanking is disabled before opening
        self.prevent_screen_blanking()
        
        # Find browser executable
        browser_cmd = self.find_browser()
        if not browser_cmd:
            self.log("No browser found. Please install chromium-browser or chromium", 'error')
            return False
        
        # Update config with found browser
        if browser_cmd != self.config.get("browser"):
            self.log(f"Using browser: {browser_cmd} (instead of {self.config.get('browser')})", 'warning')
        
        # Check URL connectivity before opening browser (includes DNS check)
        max_retries = self.config.get("max_connection_retries", 3)
        retry_delay = self.config.get("connection_retry_delay", 5)
        
        url_reachable = False
        dns_failed = False
        
        for attempt in range(max_retries):
            if self.check_url_connectivity(url):
                url_reachable = True
                self.connection_failures = 0
                break
            else:
                # Check if it's a DNS failure specifically
                try:
                    from urllib.parse import urlparse
                    import socket
                    parsed = urlparse(url)
                    hostname = parsed.hostname
                    socket.gethostbyname(hostname)
                except socket.gaierror:
                    dns_failed = True
                    self.log(f"DNS resolution failed for {hostname} - will show DNS error page", 'error')
                    break  # Don't retry if DNS fails
                except Exception:
                    pass
                
                self.log(f"URL not reachable, retrying ({attempt + 1}/{max_retries})...", 'warning')
                if attempt < max_retries - 1:
                    time.sleep(retry_delay)
        
        if dns_failed:
            self.connection_failures += 1
            self.log(f"DNS resolution failed - browser will show 'DNS probe finished nxdomain' error", 'error')
            self.log("Check your network connection and URL configuration", 'error')
            # Still open browser so user can see the error
        elif not url_reachable:
            self.connection_failures += 1
            self.log(f"URL not reachable after {max_retries} attempts, opening browser anyway (may show error)", 'warning')
        else:
            self.log(f"URL connectivity verified: {url}")
        
        # Build browser command with clean flag list
        kiosk_flags = self.config["kiosk_flags"].copy()
        
        # If certificates are installed, use clean secure flags
        # Otherwise, add SSL bypass flags if configured
        if self.config.get("cert_installed", False):
            # Certificates installed - use clean, secure flag list
            # Remove any SSL bypass flags that might be in the base config
            kiosk_flags = [f for f in kiosk_flags if not any(
                f.startswith(bypass) for bypass in [
                    "--ignore-certificate-errors",
                    "--ignore-ssl-errors",
                    "--allow-running-insecure-content",
                    "--unsafely-treat-insecure-origin-as-secure",
                    "--disable-web-security"
                ]
            )]
            self.log("Using clean flag list (certificates installed)")
        elif self.config.get("ignore_ssl_errors", True):
            # No certs installed, but ignore SSL errors requested - add bypass flags
            ssl_flags = [
                "--ignore-certificate-errors",
                "--ignore-ssl-errors",
                "--ignore-certificate-errors-spki-list",
                "--allow-running-insecure-content",
                "--unsafely-treat-insecure-origin-as-secure",
                "--disable-web-security"
            ]
            # Add flags that aren't already in the list
            for flag in ssl_flags:
                flag_name = flag.split("=")[0] if "=" in flag else flag
                if not any(f.startswith(flag_name) for f in kiosk_flags):
                    kiosk_flags.append(flag)
            self.log("Using SSL bypass flags (no certificates installed)")
        else:
            # Standard SSL validation
            self.log("Using standard SSL validation")
        
        # Fix "Exited Cleanly" nag bar - force Chromium to think it exited cleanly
        self.fix_chromium_exit_status()
        
        cmd = [browser_cmd] + kiosk_flags + [url]
        
        # Create environment with X server vars explicitly
        env = os.environ.copy()
        env['DISPLAY'] = os.environ.get('DISPLAY', ':0')
        if 'XAUTHORITY' in os.environ:
            env['XAUTHORITY'] = os.environ['XAUTHORITY']
        
        try:
            self.log(f"Launching browser: {' '.join(cmd)}")
            self.log(f"Environment: DISPLAY={env.get('DISPLAY')}, XAUTHORITY={env.get('XAUTHORITY', 'NOT SET')}")
            self.log(f"URL: {url}")
            
            # Launch with explicit environment and capture stderr for debugging
            self.browser_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env
            )
            
            # Log any immediate errors
            time.sleep(1)  # Give it a moment to start
            if self.browser_process.poll() is not None:
                # Browser exited immediately - get error
                stdout, stderr = self.browser_process.communicate(timeout=1)
                if stderr:
                    self.log(f"Browser error output: {stderr.decode('utf-8', errors='ignore')}", 'error')
                if stdout:
                    self.log(f"Browser stdout: {stdout.decode('utf-8', errors='ignore')}", 'error')
                self.log(f"Browser exited immediately with code: {self.browser_process.returncode}", 'error')
                return False
            
            # Record launch time (for ignoring early exits)
            self.browser_launch_time = time.time()
            
            # Wait longer to see if it starts successfully (increased from 4s to 8s)
            time.sleep(8)  # Give it more time to load and render
            
            # Only check for immediate exit if browser has been running for at least 15 seconds
            # This prevents false positives during the initial startup phase
            if self.browser_process.poll() is not None:
                exit_code = self.browser_process.returncode
                elapsed = time.time() - self.browser_launch_time
                if elapsed < 15:
                    self.log(f"Browser exited during startup phase ({elapsed:.1f}s) - may be normal, will retry", 'warning')
                    return False
                else:
                    self.log(f"Browser exited after startup (exit code: {exit_code}, ran for {elapsed:.1f}s)", 'error')
                    return False
            
            self.log(f"Browser opened successfully: {url}")
            
            # SSL errors should be bypassed by flags - no need for xdotool
            # The combination of --ignore-certificate-errors and --disable-web-security
            # should prevent SSL warnings from appearing
            
            return True
        except FileNotFoundError:
            self.log(f"Error: Browser executable not found: {browser_cmd}", 'error')
            return False
        except Exception as e:
            self.log(f"Error opening browser: {e}", 'error')
            return False
    
    
    
    def run(self):
        """Main loop - display URL with auto-refresh and monitoring"""
        url = self.config.get("url", "http://example.com")
        refresh_interval = self.config.get("refresh_interval", 60)
        
        if not url or url == "http://example.com" or url == "https://example.com":
            self.log("Warning: Using default URL. Please configure your URL.", 'warning')
            self.log(f"Edit config at: {USER_CONFIG_FILE} or {CONFIG_FILE}", 'warning')
        
        self.log("=" * 50)
        self.log("Piview started - Factory Mode")
        self.log(f"URL: {url}")
        self.log(f"Auto-refresh: {refresh_interval} seconds")
        self.log(f"Health check interval: {self.config.get('health_check_interval', 10)} seconds")
        self.log("Press Alt+F4 to close browser (will restart automatically)")
        self.log("Press Ctrl+C to stop Piview")
        self.log("=" * 50)
        
        # Wait for X server to be ready first
        if not self.wait_for_x_server(max_wait=60):
            self.log("X server not available. Will keep retrying...", 'error')
            # Don't exit - keep trying
        else:
            self.log("X server is ready")
        
        # Aggressively prevent screen blanking at start
        for _ in range(3):
            self.prevent_screen_blanking()
            time.sleep(1)
        
        # Log browser control info
        self.log("Browser controls: Press Alt+F4 to close browser, or use /opt/piview/close_browser.sh")
        self.log("Or restart service: sudo systemctl restart piview.service")
        
        # Open browser with retry - more aggressive
        max_retries = 10
        browser_opened = False
        for attempt in range(max_retries):
            if self.open_url(url):
                browser_opened = True
                break
            if attempt < max_retries - 1:
                wait_time = min(5 + attempt, 15)  # Progressive backoff
                self.log(f"Failed to open browser, retrying ({attempt + 1}/{max_retries}) in {wait_time}s...", 'warning')
                time.sleep(wait_time)
                self.prevent_screen_blanking()
                # Re-check X server
                if not self.wait_for_x_server(max_wait=10):
                    self.log("X server lost, waiting longer...", 'warning')
                    time.sleep(10)
            else:
                self.log("Failed to open browser after all retries. Will keep trying in main loop...", 'error')
        
        if not browser_opened:
            self.log("Browser not opened initially, will retry in main loop", 'warning')
        
        # Main loop - refresh periodically and monitor
        last_refresh = time.time()
        consecutive_failures = 0
        
        while self.running:
            time.sleep(1)
            
            # Keep screen alive periodically
            if time.time() - self.last_screen_keepalive >= 30:
                self.keep_screen_alive()
                self.last_screen_keepalive = time.time()
            
            # Check if browser is still running - restart immediately if it died
            # (but ignore exits during first 15s after launch)
            if self.browser_process:
                if self.browser_process.poll() is not None:
                    elapsed = time.time() - self.browser_launch_time if self.browser_launch_time > 0 else 999
                    if elapsed < 15:
                        self.log(f"Browser exited during startup phase ({elapsed:.1f}s) - ignoring (may be normal)", 'info')
                    else:
                        self.log("Browser process died, restarting immediately...", 'warning')
                        consecutive_failures += 1
                        # Restart immediately - don't wait
                        self.restart_browser()
                        last_refresh = time.time()
                        # Reset failure count after successful restart
                        if self.browser_process and self.browser_process.poll() is None:
                            consecutive_failures = 0
                else:
                    consecutive_failures = 0
                    
                    # Periodically check if URL is still reachable
                    if time.time() - self.last_url_check > 60:  # Check every minute
                        url = self.config.get("url", "")
                        if url:
                            if not self.check_url_connectivity(url):
                                self.connection_failures += 1
                                self.log(f"URL connectivity lost, restarting browser (failure #{self.connection_failures})...", 'warning')
                                self.restart_browser()
                                last_refresh = time.time()
                            else:
                                self.connection_failures = 0
                        self.last_url_check = time.time()
            
            # Auto-refresh
            elapsed = time.time() - last_refresh
            if elapsed >= refresh_interval:
                self.log(f"Auto-refreshing page (interval: {refresh_interval}s)...")
                if self.refresh_page():
                    last_refresh = time.time()
                else:
                    self.log("Refresh failed, will retry on next cycle", 'warning')
                    last_refresh = time.time() - (refresh_interval / 2)  # Retry sooner
        
        self.close_browser()
        self.log("Piview stopped")

def main():
    """Entry point"""
    try:
        piview = Piview()
        piview.run()
    except Exception as e:
        print(f"Fatal error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
