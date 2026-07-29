#!/usr/bin/env python3
"""
WebShell v2 — HTTP Polling Terminal (no WebSocket).
Uses simple GET/POST polling through xterm.js.
Works through ANY HTTP proxy (Tailscale Serve, Funnel, nginx, etc.).
"""

import asyncio
import fcntl
import json
import logging
import os
import pty
import signal
import struct
import sys
import termios
import time
import tty as tty_mod
from collections import deque

logging.basicConfig(
    level=logging.DEBUG,
    format="[webshell] %(levelname)s: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("webshell")

HOST = "0.0.0.0"
PORT = int(os.environ.get("WEBSHELL_PORT", "4200"))

# ── HTML page with xterm.js (polling-based) ───────────────────────────────
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
    .term-container { height: calc(100vh - 2px); }
  </style>
</head>
<body>
  <div id="status" class="connecting">Starting terminal...</div>
  <div id="terminal" class="term-container"></div>

  <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
  <script>
    (function() {
      var statusEl = document.getElementById('status');
      var lastSeq = 0;
      var polling = false;

      function setStatus(state, msg) {
        statusEl.className = state;
        statusEl.textContent = msg;
      }

      // ── Terminal setup ───────────────────────────────────────────────
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
      term.open(document.getElementById('terminal'));
      try { fitAddon.fit(); } catch(e) {}

      // ── Output poller ────────────────────────────────────────────────
      function pollOutput() {
        if (polling) return;
        polling = true;

        fetch('/output?since=' + lastSeq)
          .then(function(r) { return r.json(); })
          .then(function(data) {
            if (data.data && data.data.length > 0) {
              // Decode base64
              var binary = atob(data.data);
              var arr = new Uint8Array(binary.length);
              for (var i = 0; i < binary.length; i++) {
                arr[i] = binary.charCodeAt(i);
              }
              term.write(arr);
              lastSeq = data.seq;
            }
            setStatus('connected', 'Connected');
          })
          .catch(function(err) {
            setStatus('error', 'Connection error - retrying');
            console.error('Poll error:', err);
          })
          .then(function() {
            polling = false;
            if (!term._disposed) {
              setTimeout(pollOutput, 200);
            }
          });
      }

      // ── Input sender ─────────────────────────────────────────────────
      function sendInput(data) {
        fetch('/input', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({data: data}),
        }).catch(function(err) {
          console.error('Input error:', err);
        });
      }

      // ── Wire up terminal events ──────────────────────────────────────
      term.onData(function(data) {
        sendInput(data);
      });

      term.onResize(function(size) {
        fetch('/resize', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({cols: size.cols, rows: size.rows}),
        }).catch(function(err) {
          console.error('Resize error:', err);
        });
      });

      // ── Start ────────────────────────────────────────────────────────
      setStatus('connecting', 'Starting terminal session...');

      // Initial terminal connection: start the PTY
      fetch('/start', {method: 'POST'})
        .then(function(r) { return r.json(); })
        .then(function(resp) {
          if (resp.status === 'ok') {
            setStatus('connected', 'Connected');
            pollOutput();
          } else {
            setStatus('error', 'Failed to start: ' + (resp.error || 'unknown'));
          }
        })
        .catch(function(err) {
          setStatus('error', 'Failed to connect: ' + err.message);
        });

      // ── Window resize ────────────────────────────────────────────────
      window.addEventListener('resize', function() {
        try { fitAddon.fit(); } catch(e) {}
      });
    })();
  </script>
</body>
</html>"""


# ── PTY Terminal Manager ──────────────────────────────────────────────────
class PTYManager:
    """Manages a single PTY session with output buffering."""

    def __init__(self):
        self.pid = None
        self.fd = None
        self.cols = 80
        self.rows = 24
        self.output_buffer = deque()  # list of (seq, data_bytes)
        self.seq = 0
        self.lock = asyncio.Lock()
        self._reader_task = None

    def set_winsize(self, fd, rows, cols):
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
        except OSError:
            pass

    def spawn(self):
        """Spawn a new PTY with bash."""
        if self.pid:
            self.cleanup()

        pid, fd = pty.fork()
        if pid == 0:  # Child
            try:
                os.setsid()
                self.set_winsize(fd, self.rows, self.cols)
                # Use --norc --noprofile to avoid any bashrc issues
                os.execvpe("/bin/bash", ["/bin/bash", "--norc", "--noprofile"], os.environ)
            except Exception as e:
                log.error(f"Child exec failed: {e}")
                os._exit(1)
        else:  # Parent
            self.pid = pid
            self.fd = fd
            try:
                tty_mod.setraw(fd)
            except Exception:
                pass
            log.info(f"PTY spawned: pid={pid}, fd={fd}")
            return fd

    def read_nonblock(self):
        """Non-blocking read from PTY, appends to buffer."""
        if self.fd is None:
            return b""
        try:
            data = os.read(self.fd, 65536)
            if data:
                self.seq += len(data)
                self.output_buffer.append((self.seq, data))
                # Trim buffer to max 1MB
                total = sum(len(d) for _, d in self.output_buffer)
                while total > 1048576 and len(self.output_buffer) > 1:
                    _, popped = self.output_buffer.popleft()
                    total -= len(popped)
            return data
        except (OSError, BlockingIOError):
            return b""

    def write(self, data: bytes):
        """Write to PTY."""
        if self.fd is None:
            return
        try:
            os.write(self.fd, data)
        except OSError as e:
            log.warning(f"PTY write failed: {e}")

    def get_output_since(self, since_seq: int):
        """Get all output data since a given sequence number."""
        result = b""
        final_seq = since_seq
        for seq, data in self.output_buffer:
            if seq > since_seq:
                result += data
                final_seq = seq
        return final_seq, result

    def cleanup(self):
        """Kill child and close PTY."""
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGHUP)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError, OSError):
                pass
            self.pid = None
        if self.fd:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        self.output_buffer.clear()
        log.info("PTY cleaned up")


# ── Global State ──────────────────────────────────────────────────────────
pty_mgr = PTYManager()
pty_mgr.spawn()  # Pre-spawn PTY on startup


# ── Simple Async HTTP Server ─────────────────────────────────────────────
async def handle_http(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Handle a single HTTP request."""
    try:
        request_line = await asyncio.wait_for(reader.readline(), timeout=10)
        if not request_line:
            writer.close()
            return

        request_str = request_line.decode("utf-8", errors="replace").strip()
        if not request_str:
            writer.close()
            return

        parts = request_str.split(" ")
        if len(parts) < 2:
            writer.close()
            return

        method = parts[0]
        path = parts[1]
        path_only = path.split("?")[0]  # Strip query params
        query = {}
        if "?" in path:
            qs = path.split("?")[1]
            for param in qs.split("&"):
                if "=" in param:
                    k, v = param.split("=", 1)
                    query[k] = v

        # Read headers and determine content length
        content_length = 0
        while True:
            header_line = await asyncio.wait_for(reader.readline(), timeout=5)
            header_str = header_line.decode("utf-8", errors="replace").strip()
            if not header_str:
                break
            if header_str.lower().startswith("content-length:"):
                content_length = int(header_str.split(":")[1].strip())

        # Read body if present
        body = b""
        if content_length > 0:
            body = await asyncio.wait_for(reader.readexactly(content_length), timeout=10)

        # ── Route handling ──────────────────────────────────────────────
        status = 200
        resp_headers = {
            "Content-Type": "text/plain",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "Expires": "0",
        }
        resp_body = b""

        if path_only == "/":
            resp_headers["Content-Type"] = "text/html; charset=utf-8"
            resp_body = INDEX_HTML.encode("utf-8")

        elif path_only == "/health":
            resp_body = b"OK"

        elif path_only == "/start":
            # Ensure PTY is running
            if pty_mgr.pid is None or pty_mgr.fd is None:
                try:
                    pty_mgr.spawn()
                    resp_body = json.dumps({"status": "ok"}).encode()
                except Exception as e:
                    resp_body = json.dumps({"status": "error", "error": str(e)}).encode()
            else:
                resp_body = json.dumps({"status": "ok"}).encode()

        elif path_only == "/output":
            since = int(query.get("since", "0"))
            final_seq, data = pty_mgr.get_output_since(since)
            # Base64 encode binary data for safe JSON transport
            import base64
            encoded = base64.b64encode(data).decode()
            resp_headers["Content-Type"] = "application/json"
            resp_body = json.dumps({"seq": final_seq, "data": encoded}).encode()

        elif path_only == "/input":
            if method == "POST" and body:
                try:
                    payload = json.loads(body.decode("utf-8"))
                    data = payload.get("data", "")
                    pty_mgr.write(data.encode("utf-8"))
                    resp_body = b'{"status":"ok"}'
                except (json.JSONDecodeError, KeyError) as e:
                    resp_body = json.dumps({"status": "error", "error": str(e)}).encode()
            else:
                resp_body = b'{"status":"error","error":"no data"}'

        elif path_only == "/resize":
            if method == "POST" and body:
                try:
                    payload = json.loads(body.decode("utf-8"))
                    pty_mgr.cols = int(payload.get("cols", pty_mgr.cols))
                    pty_mgr.rows = int(payload.get("rows", pty_mgr.rows))
                    if pty_mgr.fd:
                        pty_mgr.set_winsize(pty_mgr.fd, pty_mgr.rows, pty_mgr.cols)
                    resp_body = b'{"status":"ok"}'
                except (json.JSONDecodeError, KeyError, ValueError) as e:
                    resp_body = json.dumps({"status": "error", "error": str(e)}).encode()
            else:
                resp_body = b'{"status":"error","error":"no data"}'

        elif path_only == "/debug":
            resp_headers["Content-Type"] = "application/json"
            debug_info = {
                "pid": pty_mgr.pid,
                "fd": pty_mgr.fd is not None,
                "cols": pty_mgr.cols,
                "rows": pty_mgr.rows,
                "buffer_size": len(pty_mgr.output_buffer),
                "total_seq": pty_mgr.seq,
                "alive": pty_mgr.pid is not None,
            }
            # Check if process is alive
            if pty_mgr.pid:
                try:
                    os.kill(pty_mgr.pid, 0)
                    debug_info["process_alive"] = True
                except OSError:
                    debug_info["process_alive"] = False
            resp_body = json.dumps(debug_info).encode()

        else:
            status = 404
            resp_body = b"Not Found"

        # Build and send response
        status_text = {200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"}
        resp_line = f"HTTP/1.1 {status} {status_text.get(status, 'Unknown')}\r\n"
        resp_bytes = resp_line.encode()

        for key, value in resp_headers.items():
            resp_bytes += f"{key}: {value}\r\n".encode()
        resp_bytes += f"Content-Length: {len(resp_body)}\r\n".encode()
        resp_bytes += b"Connection: close\r\n"
        resp_bytes += b"\r\n"
        resp_bytes += resp_body

        writer.write(resp_bytes)
        await writer.drain()

    except Exception as e:
        log.error(f"HTTP handler error: {e}")
        try:
            writer.write(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 2\r\n\r\n{}")
            await writer.drain()
        except Exception:
            pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def pty_reader_background():
    """Background task: continuously read from PTY to fill buffer."""
    while True:
        try:
            pty_mgr.read_nonblock()
        except Exception as e:
            log.error(f"PTY reader error: {e}")
        await asyncio.sleep(0.01)  # 10ms polling for fresh output


async def main():
    log.info(f"WebShell v2 starting on {HOST}:{PORT}")

    stop = asyncio.Future()

    def signal_handler():
        log.info("Shutdown signal received")
        stop.set_result(True)

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, signal_handler)
        except NotImplementedError:
            pass

    # Start background PTY reader
    asyncio.create_task(pty_reader_background())

    server = await asyncio.start_server(handle_http, HOST, PORT)
    addr = server.sockets[0].getsockname()
    log.info(f"✅ WebShell v2 running on http://{addr[0]}:{addr[1]}")
    log.info(f"   Polling terminal — no WebSocket required")

    async with server:
        await stop

    pty_mgr.cleanup()
    log.info("Server stopped")


if __name__ == "__main__":
    asyncio.run(main())
