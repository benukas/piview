#!/usr/bin/env python3
"""
Piview URL Manager - Simple web interface for managing URLs
Run this to easily add/remove/edit URLs without editing JSON manually
"""

import json
import http.server
import socketserver
import urllib.parse
from pathlib import Path

CONFIG_FILE = Path.home() / ".piview" / "config.json"
PORT = 8080

class URLManagerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        """Handle GET requests"""
        if self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(self.get_index_html().encode())
        elif self.path == '/api/config':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            config = self.load_config()
            self.wfile.write(json.dumps(config).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        """Handle POST requests"""
        if self.path == '/api/save':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode())
            
            config = self.load_config()
            config['urls'] = [url.strip() for url in data.get('urls', []) if url.strip()]
            config['display_time'] = int(data.get('display_time', 30))
            
            self.save_config(config)
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'success'}).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def load_config(self):
        """Load configuration"""
        if not CONFIG_FILE.exists():
            return {
                "urls": [],
                "display_time": 30,
                "browser": "chromium-browser"
            }
        try:
            with open(CONFIG_FILE, 'r') as f:
                return json.load(f)
        except:
            return {
                "urls": [],
                "display_time": 30,
                "browser": "chromium-browser"
            }
    
    def save_config(self, config):
        """Save configuration"""
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)
    
    def get_index_html(self):
        """Generate HTML interface"""
        config = self.load_config()
        urls_html = '\n'.join([f'<div class="url-item"><input type="text" class="url-input" value="{url}" placeholder="https://example.com"><button class="remove-btn" onclick="removeUrl(this)">Remove</button></div>' for url in config.get('urls', [])])
        
        return f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Piview URL Manager</title>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #000;
            color: #fff;
            padding: 20px;
            min-height: 100vh;
        }}
        .container {{
            max-width: 800px;
            margin: 0 auto;
        }}
        h1 {{
            margin-bottom: 30px;
            color: #fff;
        }}
        .section {{
            background: #111;
            padding: 20px;
            border-radius: 8px;
            margin-bottom: 20px;
        }}
        .url-list {{
            margin-bottom: 20px;
        }}
        .url-item {{
            display: flex;
            gap: 10px;
            margin-bottom: 10px;
        }}
        .url-input {{
            flex: 1;
            padding: 10px;
            background: #222;
            border: 1px solid #333;
            color: #fff;
            border-radius: 4px;
            font-size: 14px;
        }}
        .url-input:focus {{
            outline: none;
            border-color: #555;
        }}
        .remove-btn {{
            padding: 10px 20px;
            background: #d32f2f;
            color: #fff;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
        }}
        .remove-btn:hover {{
            background: #b71c1c;
        }}
        .add-btn {{
            padding: 10px 20px;
            background: #1976d2;
            color: #fff;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
            margin-bottom: 20px;
        }}
        .add-btn:hover {{
            background: #1565c0;
        }}
        .time-input {{
            padding: 10px;
            background: #222;
            border: 1px solid #333;
            color: #fff;
            border-radius: 4px;
            font-size: 14px;
            width: 150px;
        }}
        .save-btn {{
            padding: 15px 30px;
            background: #388e3c;
            color: #fff;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
            font-weight: bold;
            width: 100%;
        }}
        .save-btn:hover {{
            background: #2e7d32;
        }}
        .save-btn:disabled {{
            background: #555;
            cursor: not-allowed;
        }}
        .status {{
            margin-top: 20px;
            padding: 10px;
            border-radius: 4px;
            display: none;
        }}
        .status.success {{
            background: #2e7d32;
            display: block;
        }}
        .status.error {{
            background: #d32f2f;
            display: block;
        }}
        label {{
            display: block;
            margin-bottom: 10px;
            color: #ccc;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Piview URL Manager</h1>
        
        <div class="section">
            <h2>Web Pages</h2>
            <button class="add-btn" onclick="addUrl()">+ Add URL</button>
            <div class="url-list" id="urlList">
                {urls_html}
            </div>
        </div>
        
        <div class="section">
            <label>
                Display Time (seconds per page):
                <input type="number" class="time-input" id="displayTime" value="{config.get('display_time', 30)}" min="5" max="300">
            </label>
        </div>
        
        <button class="save-btn" onclick="saveConfig()">Save Configuration</button>
        
        <div class="status" id="status"></div>
    </div>
    
    <script>
        function addUrl() {{
            const urlList = document.getElementById('urlList');
            const div = document.createElement('div');
            div.className = 'url-item';
            div.innerHTML = '<input type="text" class="url-input" placeholder="https://example.com"><button class="remove-btn" onclick="removeUrl(this)">Remove</button>';
            urlList.appendChild(div);
        }}
        
        function removeUrl(btn) {{
            btn.parentElement.remove();
        }}
        
        async function saveConfig() {{
            const saveBtn = document.getElementById('status').previousElementSibling;
            const status = document.getElementById('status');
            
            saveBtn.disabled = true;
            status.className = 'status';
            
            const urlInputs = document.querySelectorAll('.url-input');
            const urls = Array.from(urlInputs).map(input => input.value).filter(url => url.trim());
            const displayTime = parseInt(document.getElementById('displayTime').value) || 30;
            
            try {{
                const response = await fetch('/api/save', {{
                    method: 'POST',
                    headers: {{
                        'Content-Type': 'application/json'
                    }},
                    body: JSON.stringify({{
                        urls: urls,
                        display_time: displayTime
                    }})
                }});
                
                if (response.ok) {{
                    status.className = 'status success';
                    status.textContent = 'Configuration saved successfully! Piview will reload on next cycle.';
                    setTimeout(() => {{
                        status.className = 'status';
                    }}, 3000);
                }} else {{
                    throw new Error('Failed to save');
                }}
            }} catch (error) {{
                status.className = 'status error';
                status.textContent = 'Error saving configuration: ' + error.message;
            }} finally {{
                saveBtn.disabled = false;
            }}
        }}
        
        // Load config on page load
        window.addEventListener('load', async () => {{
            try {{
                const response = await fetch('/api/config');
                const config = await response.json();
                
                const urlList = document.getElementById('urlList');
                urlList.innerHTML = '';
                
                config.urls.forEach(url => {{
                    const div = document.createElement('div');
                    div.className = 'url-item';
                    div.innerHTML = `<input type="text" class="url-input" value="${{url}}" placeholder="https://example.com"><button class="remove-btn" onclick="removeUrl(this)">Remove</button>`;
                    urlList.appendChild(div);
                }});
                
                document.getElementById('displayTime').value = config.display_time || 30;
            }} catch (error) {{
                console.error('Error loading config:', error);
            }}
        }});
    </script>
</body>
</html>'''

def main():
    """Start the URL manager server"""
    with socketserver.TCPServer(("", PORT), URLManagerHandler) as httpd:
        print(f"Piview URL Manager running on http://localhost:{PORT}")
        print("Press Ctrl+C to stop")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down URL Manager...")

if __name__ == "__main__":
    main()
