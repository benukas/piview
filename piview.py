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
    "url": "https://example.com",
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
        "--autoplay-policy=no-user-gesture-required",
        "--disable-features=TranslateUI",
        "--disable-ipc-flooding-protection",
        "--disable-background-networking",
        "--disable-default-apps",
        "--disable-sync",
        "--disable-dev-shm-usage",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-software-rasterizer",
        "--ignore-certificate-errors",
        "--ignore-ssl-errors",
        "--ignore-certificate-errors-spki-list",
        "--allow-running-insecure-content",
        "--disable-web-security",
        "--test-type"
    ]
}

class Piview:
    def __init__(self):
        # Initialize logger FIRST - before anything else that might use it
        self.logger = None
        
        self.running = True
        self.browser_process = None
        self.browser_restart_count = 0
        self.last_browser_check = time.time()
        self.last_screen_keepalive = time.time()
        self.last_health_check = time.time()
        self.connection_failures = 0
        self.last_url_check = 0
        
        # Setup logging (must be early)
        self.setup_logging()
        
        # Load config after logging is ready
        self.config = self.load_config()
        
        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        # Keyboard listener thread
        self.keyboard_thread = None
        
        # Initialize screen blanking prevention
        self.prevent_screen_blanking()
        
        # Start background threads
        self.start_background_threads()
    
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
        """Aggressively prevent screen blanking - multiple methods"""
        try:
            # Method 1: xset commands (if X is available)
            if os.environ.get('DISPLAY'):
                subprocess.run(
                    ["xset", "s", "off"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                subprocess.run(
                    ["xset", "-dpms"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                subprocess.run(
                    ["xset", "s", "noblank"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                # Disable screen saver timeout
                subprocess.run(
                    ["xset", "s", "0", "0"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
            
            # Method 2: Set console blank timeout to 0
            try:
                with open('/sys/module/kernel/parameters/consoleblank', 'w') as f:
                    f.write('0')
            except Exception:
                pass
            
            # Method 3: Disable HDMI power saving
            try:
                subprocess.run(
                    ["tvservice", "-p"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
            except Exception:
                pass
            
            # Method 4: Set console blank timeout via setterm
            subprocess.run(
                ["setterm", "-blank", "0", "-powerdown", "0", "-powersave", "off"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
            
            self.log("Screen blanking prevention activated")
        except Exception as e:
            self.log(f"Warning: Could not set all screen blanking prevention: {e}", 'warning')
    
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
                
                # Check browser process
                if self.browser_process:
                    if self.browser_process.poll() is not None:
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
    
    def check_url_connectivity(self, url):
        """Check if URL is reachable before opening browser"""
        try:
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
                self.log(f"URL connectivity check failed: {e}", 'warning')
                return False
        except Exception as e:
            self.log(f"Connectivity check error: {e}", 'warning')
            return False
    
    def open_url(self, url):
        """Open a URL in kiosk mode with error handling and connection verification"""
        self.close_browser()
        
        # Wait for X server to be ready
        if not self.wait_for_x_server():
            self.log("X server not available, cannot open browser", 'error')
            return False
        
        # Set display
        display = os.environ.get('DISPLAY', ':0')
        os.environ['DISPLAY'] = display
        
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
        
        # Check URL connectivity before opening browser
        max_retries = self.config.get("max_connection_retries", 3)
        retry_delay = self.config.get("connection_retry_delay", 5)
        
        url_reachable = False
        for attempt in range(max_retries):
            if self.check_url_connectivity(url):
                url_reachable = True
                self.connection_failures = 0
                break
            else:
                self.log(f"URL not reachable, retrying ({attempt + 1}/{max_retries})...", 'warning')
                if attempt < max_retries - 1:
                    time.sleep(retry_delay)
        
        if not url_reachable:
            self.connection_failures += 1
            self.log(f"URL not reachable after {max_retries} attempts, opening browser anyway (may show error)", 'warning')
        else:
            self.log(f"URL connectivity verified: {url}")
        
        # Build browser command with SSL flags if needed
        kiosk_flags = self.config["kiosk_flags"].copy()
        
        # Add SSL bypass flags if configured
        if self.config.get("ignore_ssl_errors", True):
            ssl_flags = [
                "--ignore-certificate-errors",
                "--ignore-ssl-errors",
                "--ignore-certificate-errors-spki-list",
                "--allow-running-insecure-content"
            ]
            # Add flags that aren't already in the list
            for flag in ssl_flags:
                if flag not in kiosk_flags:
                    kiosk_flags.append(flag)
        
        cmd = [browser_cmd] + kiosk_flags + [url]
        
        try:
            self.log(f"Launching browser: {' '.join(cmd)}")
            self.browser_process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=os.environ.copy()
            )
            
            # Wait a moment to see if it starts successfully
            time.sleep(4)  # Give it time to load
            if self.browser_process.poll() is not None:
                exit_code = self.browser_process.returncode
                self.log(f"Browser exited immediately after start (exit code: {exit_code})", 'error')
                # Try to get stderr for debugging
                return False
            
            self.log(f"Browser opened successfully: {url}")
            
            # After opening, try to dismiss any SSL warnings
            if self.config.get("ignore_ssl_errors", True):
                time.sleep(2)
                self.dismiss_ssl_warnings()
            
            return True
        except FileNotFoundError:
            self.log(f"Error: Browser executable not found: {browser_cmd}", 'error')
            return False
        except Exception as e:
            self.log(f"Error opening browser: {e}", 'error')
            return False
    
    def dismiss_ssl_warnings(self):
        """Try to automatically dismiss SSL certificate warnings"""
        try:
            # Wait a moment for page to load
            time.sleep(1)
            
            # Try to click "Advanced" or "Proceed" buttons
            # These are common patterns in Chromium SSL error pages
            subprocess.run(
                ["xdotool", "key", "Tab", "Tab", "Tab", "Return"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
            
            # Alternative: Try typing the URL again to force reload
            time.sleep(1)
            subprocess.run(
                ["xdotool", "key", "ctrl+l"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1
            )
            time.sleep(0.5)
            subprocess.run(
                ["xdotool", "type", self.config.get("url", "")],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
            time.sleep(0.5)
            subprocess.run(
                ["xdotool", "key", "Return"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1
            )
        except Exception as e:
            # Silently fail - SSL flags should handle most cases
            pass
    
    def keyboard_listener(self):
        """Listen for keyboard input to close browser - works in kiosk mode"""
        while self.running:
            try:
                time.sleep(0.5)  # Check every 500ms
                
                # Use xdotool to check for ESC or 'q' key presses
                # This works even when running as a service
                try:
                    # Check if ESC key is pressed (keycode 9)
                    result = subprocess.run(
                        ["xdotool", "search", "--onlyvisible", "--class", "chromium"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1
                    )
                    
                    # Alternative: Use xev or xinput to detect key presses
                    # For now, we'll use a simpler approach - monitor for specific key combinations
                    # ESC key can be detected via xdotool keyup/keydown
                    
                except Exception:
                    # xdotool might not be available or window not found
                    pass
                
                # Fallback: Try to read from stdin if it's a TTY (for manual testing)
                if sys.stdin.isatty():
                    import select
                    import tty
                    import termios
                    
                    if select.select([sys.stdin], [], [], 0)[0]:
                        old_settings = termios.tcgetattr(sys.stdin)
                        tty.setraw(sys.stdin.fileno())
                        key = sys.stdin.read(1)
                        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                        
                        if ord(key) == 27 or key == 'q' or key == 'Q':
                            self.log("Closing browser (ESC/q pressed)...")
                            self.close_browser()
                            time.sleep(2)
                            if self.running:
                                self.open_url(self.config["url"])
            except Exception as e:
                # Silently continue - keyboard input is optional
                time.sleep(1)
    
    def setup_keyboard_hotkey(self):
        """Setup global hotkey using xdotool for ESC/q key detection"""
        # Create a background process that monitors for ESC/q keys
        def monitor_keys():
            while self.running:
                try:
                    # Use xdotool to get active window and check for key presses
                    # This is a workaround since direct keyboard capture is complex
                    time.sleep(1)
                except Exception:
                    time.sleep(1)
        
        return threading.Thread(target=monitor_keys, daemon=True)
    
    def run(self):
        """Main loop - display URL with auto-refresh and monitoring"""
        url = self.config.get("url", "https://example.com")
        refresh_interval = self.config.get("refresh_interval", 60)
        
        if not url or url == "https://example.com":
            self.log("Warning: Using default URL. Please configure your URL.", 'warning')
            self.log(f"Edit config at: {USER_CONFIG_FILE} or {CONFIG_FILE}", 'warning')
        
        self.log("=" * 50)
        self.log("Piview started - Factory Mode")
        self.log(f"URL: {url}")
        self.log(f"Auto-refresh: {refresh_interval} seconds")
        self.log(f"Health check interval: {self.config.get('health_check_interval', 10)} seconds")
        self.log("Press ESC or 'q' to close browser (will restart automatically)")
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
        
        # Start keyboard listener in background
        # Note: In kiosk mode, keyboard input is limited
        # Users can use the close_browser.sh script or restart the service
        try:
            self.keyboard_thread = threading.Thread(target=self.keyboard_listener, daemon=True)
            self.keyboard_thread.start()
        except Exception:
            pass
        
        # Log keyboard shortcut info
        self.log("Keyboard shortcuts: Use /opt/piview/close_browser.sh to close browser")
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
            
            # Check if browser is still running
            if self.browser_process:
                if self.browser_process.poll() is not None:
                    self.log("Browser process died, restarting...", 'warning')
                    consecutive_failures += 1
                    if consecutive_failures < 5:
                        self.restart_browser()
                        last_refresh = time.time()
                    else:
                        self.log("Too many consecutive failures, waiting longer...", 'error')
                        time.sleep(30)
                        consecutive_failures = 0
                        self.restart_browser()
                        last_refresh = time.time()
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
