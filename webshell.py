#!/usr/bin/env python3
"""
WebShell — Simple WebSocket-based web terminal.
Serves xterm.js on HTTP and bridges WebSocket to a PTY (bash).
Works behind Tailscale Serve / Tailscale Funnel.
"""

import asyncio
import fcntl
import json
import logging
import os
import pty
import signal
import struct
import subprocess
import sys
import termios
import tty as tty_mod

logging.basicConfig(
    level=logging.DEBUG,
    format="[webshell] %(levelname)s: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("webshell")

# ── Try websockets, auto-install if missing ────────────────────────────────
try:
    import websockets
    from websockets.http import HTTPResponse
    from websockets.server import WebSocketServerProtocol
except ImportError:
    log.info("websockets not found, installing...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "websockets", "-q"])
    import websockets
    from websockets.http import HTTPResponse

HOST = "0.0.0.0"
PORT = int(os.environ.get("WEBSHELL_PORT", "4200"))

log.info(f"WebShell starting on {HOST}:{PORT}")


# ── Static HTML page ──────────────────────────────────────────────────────
INDEX_HTML = r"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>RenderShell Web Terminal</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css" />
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { background: #111; color: #e0e0e0; font-family: system-ui, monospace; }
    #terminal { height: 100vh; width: 100vw; }
    #status { padding: 8px 16px; font-size: 13px; font-family: monospace; border-bottom: 1px solid #333; }
    #status.connecting { background: #1a3a1a; color: #8f8; }
    #status.connected { background: #0a2a0a; color: #4f4; }
    #status.error { background: #3a1a1a; color: #f88; }
    #status.disconnected { background: #2a2a1a; color: #ff8; }
    .term-container { height: calc(100vh - 2px); }
  </style>
</head>
<body>
  <div id="status" class="connecting">⏳ Connecting to WebSocket...</div>
  <div id="terminal" class="term-container"></div>

  <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/xterm-addon-web-links@0.9.0/lib/xterm-addon-web-links.min.js"></script>
  <script>
    (function() {
      var status = document.getElementById('status');
      function setStatus(state, msg) {
        status.className = state;
        status.textContent = msg;
      }

      var term = new Terminal({
        cursorBlink: true,
        cursorStyle: 'block',
        fontSize: 14,
        fontFamily: 'Menlo, Monaco, "Courier New", monospace',
        theme: { background: '#1a1a2e', foreground: '#e0e0e0',
                 cursor: '#00ff00', selectionBackground: '#335566' },
        cols: 80, rows: 24,
        allowTransparency: false,
      });

      var fitAddon = new FitAddon.FitAddon();
      term.loadAddon(fitAddon);
      term.loadAddon(new WebLinksAddon.WebLinksAddon());
      term.open(document.getElementById('terminal'));

      // WebSocket URL (same origin, /ws path)
      var loc = window.location;
      var wsUrl = (loc.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + loc.host + '/ws';

      function connect() {
        setStatus('connecting', '⏳ Connecting to ' + wsUrl + ' ...');
        var ws = new WebSocket(wsUrl);

        ws.onopen = function() {
          setStatus('connected', '✅ Connected — terminal active');
          term.reset();
          term.focus();
          try { fitAddon.fit(); } catch(e) {}
        };

        ws.onmessage = function(ev) {
          if (ev.data instanceof Blob) {
            var reader = new FileReader();
            reader.onload = function() {
              var arr = new Uint8Array(reader.result);
              term.write(arr);
            };
            reader.readAsArrayBuffer(ev.data);
          } else {
            term.write(ev.data);
          }
        };

        ws.onclose = function() {
          setStatus('disconnected', '⚠️ Disconnected — retrying in 3s...');
          term.write('\r\n\x1b[31m[Disconnected — reconnecting]\x1b[0m\r\n');
          setTimeout(connect, 3000);
        };

        ws.onerror = function(err) {
          setStatus('error', '❌ WebSocket error — check console');
          console.error('WebSocket error:', err);
        };

        // Send user input to WebSocket
        term.onData(function(data) {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(data);
          }
        });

        // Send terminal resize events
        term.onResize(function(size) {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({type: 'resize', cols: size.cols, rows: size.rows}));
          }
        });

        // Initial fit
        setTimeout(function() { try { fitAddon.fit(); } catch(e) {} }, 200);
      }

      // Window resize → terminal resize
      window.addEventListener('resize', function() {
        try { fitAddon.fit(); } catch(e) {}
      });

      connect();
    })();
  </script>
</body>
</html>"""


# ── PTY Terminal Server ───────────────────────────────────────────────────
class TerminalServer:
    """Bridges a PTY (bash) to a WebSocket client."""

    def __init__(self):
        self.child_fd = None
        self.child_pid = None
        self.cols = 80
        self.rows = 24

    def set_winsize(self, fd, rows, cols):
        """Set terminal window size on the PTY."""
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
        except OSError as e:
            log.warning(f"set_winsize failed: {e}")

    def spawn_pty(self):
        """Fork a child process with a PTY running bash."""
        pid, fd = pty.fork()
        if pid == 0:  # Child
            try:
                os.setsid()
                self.set_winsize(fd, self.rows, self.cols)
                shell = os.environ.get("SHELL", "/bin/bash")
                os.execvpe(shell, [shell, "--login"], os.environ)
            except Exception as e:
                log.error(f"Child exec failed: {e}")
                os._exit(1)
        else:  # Parent
            self.child_pid = pid
            self.child_fd = fd
            # Set PTY to raw mode
            try:
                tty_mod.setraw(fd)
            except Exception as e:
                log.warning(f"setraw failed: {e}")
            log.info(f"PTY spawned: pid={pid}, fd={fd}")
            return fd

    def read_pty(self):
        """Non-blocking read from PTY."""
        try:
            data = os.read(self.child_fd, 65536)
            return data
        except (OSError, BlockingIOError) as e:
            return b""

    def write_pty(self, data: bytes):
        """Write to PTY."""
        try:
            os.write(self.child_fd, data)
        except OSError as e:
            log.warning(f"write to PTY failed: {e}")

    def cleanup(self):
        """Kill child and close PTY."""
        if self.child_pid:
            try:
                os.kill(self.child_pid, signal.SIGHUP)
                os.waitpid(self.child_pid, 0)
            except (ProcessLookupError, ChildProcessError, OSError):
                pass
            self.child_pid = None
        if self.child_fd:
            try:
                os.close(self.child_fd)
            except OSError:
                pass
            self.child_fd = None


# ── WebSocket Handler ─────────────────────────────────────────────────────
async def handle_ws(websocket):
    """Handle one WebSocket client: bridge PTY ↔ WebSocket."""
    log.info(f"New WebSocket connection from {websocket.remote_address}")
    ts = TerminalServer()

    try:
        ts.spawn_pty()
    except Exception as e:
        log.error(f"Failed to spawn PTY: {e}")
        await websocket.send(f"\r\n\x1b[31mERROR: Failed to spawn terminal: {e}\x1b[0m\r\n".encode())
        return

    loop = asyncio.get_event_loop()

    # ── Reader: PTY → WebSocket ──────────────────────────────────────────
    async def pty_reader():
        while True:
            data = await loop.run_in_executor(None, ts.read_pty)
            if data:
                try:
                    await websocket.send(data)
                except websockets.ConnectionClosed:
                    break
            else:
                await asyncio.sleep(0.01)

    # ── Writer: WebSocket → PTY ──────────────────────────────────────────
    async def ws_reader():
        try:
            async for message in websocket:
                if isinstance(message, str):
                    # Check for JSON resize messages
                    if message.startswith("{"):
                        try:
                            msg = json.loads(message)
                            if msg.get("type") == "resize":
                                ts.cols = msg.get("cols", ts.cols)
                                ts.rows = msg.get("rows", ts.rows)
                                if ts.child_fd is not None:
                                    ts.set_winsize(ts.child_fd, ts.rows, ts.cols)
                                    log.debug(f"Resize: {ts.cols}x{ts.rows}")
                                continue
                        except (json.JSONDecodeError, KeyError):
                            pass
                    # Regular text input
                    ts.write_pty(message.encode("utf-8"))
                elif isinstance(message, bytes):
                    ts.write_pty(message)
        except websockets.ConnectionClosed:
            log.info("WebSocket closed (ws_reader)")
        except Exception as e:
            log.warning(f"ws_reader error: {e}")

    # ── Run both tasks concurrently ──────────────────────────────────────
    try:
        tasks = [asyncio.create_task(pty_reader()), asyncio.create_task(ws_reader())]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
    except Exception as e:
        log.warning(f"Session error: {e}")
    finally:
        ts.cleanup()
        log.info(f"Session ended for {websocket.remote_address}")


# ── HTTP Request Router ───────────────────────────────────────────────────
async def process_request(path, request_headers):
    """Route HTTP requests: serve HTML for /, health for /health, WS for /ws."""
    log.debug(f"HTTP request: {path}")
    if path == "/":
        return HTTPResponse(
            status=200,
            headers={"Content-Type": "text/html; charset=utf-8"},
            body=INDEX_HTML.encode("utf-8"),
        )
    if path == "/health":
        return HTTPResponse(
            status=200,
            headers={"Content-Type": "text/plain"},
            body=b"OK",
        )
    if path == "/ws":
        # Allow WebSocket upgrade to proceed
        return None
    # Everything else is 404
    return HTTPResponse(
        status=404,
        headers={"Content-Type": "text/plain"},
        body=b"Not Found",
    )


# ── Main ──────────────────────────────────────────────────────────────────
async def main():
    log.info(f"Starting server on {HOST}:{PORT}")

    # Handle SIGTERM / SIGINT gracefully
    stop = asyncio.Future()

    def signal_handler():
        log.info("Shutdown signal received")
        stop.set_result(True)

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, signal_handler)
        except NotImplementedError:
            # Windows
            pass

    async with websockets.serve(
        handle_ws,
        HOST,
        PORT,
        process_request=process_request,
        max_size=2**24,
        ping_interval=30,
        ping_timeout=10,
        compression=None,  # Disable compression to simplify
    ):
        log.info(f"✅ WebShell running on http://{HOST}:{PORT}")
        log.info(f"   Web:   http://{HOST}:{PORT}/")
        log.info(f"   WS:    ws://{HOST}:{PORT}/ws")
        log.info(f"   HealtH:GET http://{HOST}:{PORT}/health")
        await stop

    log.info("Server stopped")


if __name__ == "__main__":
    asyncio.run(main())
