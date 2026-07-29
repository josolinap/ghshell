#!/bin/bash
# =============================================================================
# RenderShell — GitHub Actions Runner Setup Script (MINIMAL)
# =============================================================================
# Installs and configures on a GitHub Actions Ubuntu runner:
#   - Tailscale (userspace networking, exit node)
#   - TTYD (web terminal on port 4200, replaces shellinabox)
#   - HTTP status page (on port 8080)
#
# Environment variables (set by the workflow from GitHub Secrets):
#   TAILSCALE_AUTHKEY     — required, reusable auth key
#   ROOT_PASSWORD         — required, password for root SSH login
#   TAILSCALE_HOSTNAME    — optional, default: render-shell
# =============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup]${NC} $*" >&2; }

# GitHub Actions runner runs as non-root → use sudo
SUDO=''
if [ "$(id -u)" != "0" ]; then
    SUDO='sudo'
fi

HOSTNAME="${TAILSCALE_HOSTNAME:-render-shell}"

log "🚀 RenderShell setup starting on $(hostname)"
log "Target hostname: ${HOSTNAME}"

# ── Validate secrets ─────────────────────────────────────────────────────────
if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    err "TAILSCALE_AUTHKEY is not set!"
    exit 1
fi
if [ -z "${ROOT_PASSWORD:-}" ]; then
    warn "ROOT_PASSWORD not set — using 'change-me'"
    ROOT_PASSWORD="change-me"
fi

# ── 1. Install Tailscale ────────────────────────────────────────────────────
log "📡 Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
log "Tailscale $(tailscale --version 2>&1 | head -1)"

# ── 2. Install system packages ──────────────────────────────────────────────
log "📦 Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
    supervisor \
    python3 \
    curl \
    vim \
    nano \
    htop \
    2>&1 | tail -1

# Install ttyd (web terminal) — try apt first, fall back to binary download
if ! command -v ttyd &>/dev/null; then
    # Try apt first, then download static binary
    $SUDO apt-get install -y -qq ttyd 2>/dev/null && log "ttyd installed via apt" || {
        log "apt ttyd not available, downloading binary..."
        $SUDO wget -q -O /usr/bin/ttyd \
            https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64
        $SUDO chmod +x /usr/bin/ttyd
        log "ttyd binary downloaded"
    }
fi

log "Packages installed. ttyd: $(ttyd --version 2>&1 || true)"

# ── 3. Configure SSH ────────────────────────────────────────────────────────
log "🔐 Configuring SSH (root + password)..."
echo "root:${ROOT_PASSWORD}" | $SUDO chpasswd

# Allow root login with password (system sshd already on port 22)
$SUDO sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
$SUDO sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Restart system SSH to pick up changes
$SUDO systemctl restart sshd 2>/dev/null || $SUDO service ssh restart 2>/dev/null || true

log "SSH configured for root login on port 22"

# ── 4. Create status page ───────────────────────────────────────────────────
log "🌐 Creating HTTP status page..."
$SUDO mkdir -p /workspace

$SUDO tee /workspace/index.html > /dev/null << 'HTML'
<!DOCTYPE html>
<html><head><title>RenderShell (GitHub Actions)</title>
<style>
body{font-family:system-ui,sans-serif;max-width:700px;margin:50px auto;padding:0 20px;color:#333;background:#fafafa}
.card{background:#fff;padding:20px;border-radius:8px;margin:15px 0;border:1px solid #e0e0e0}
h1{color:#1a1a1a;border-bottom:3px solid #2ea44f;padding-bottom:10px}
a{color:#1976d2;text-decoration:none}
code{background:#e8e8e8;padding:2px 6px;border-radius:3px}
.badge{display:inline-block;background:#2ea44f;color:#fff;padding:2px 10px;border-radius:12px;font-size:0.8em}
.footer{margin-top:30px;font-size:0.85em;color:#666}
</style></head>
<body>
<h1>🖥️ RenderShell <span class="badge">GitHub Actions</span></h1>
<div class="card">
<h3>📡 Web Terminal (ttyd)</h3>
<p><code>https://${HOSTNAME}.&lt;your-tailnet&gt;.ts.net/</code></p>
<p>Login: <code>root</code> / your ROOT_PASSWORD</p>
</div>
<div class="card">
<h3>🔗 SSH Access</h3>
<p><code>ssh root@&lt;tailscale-ip&gt;</code> (password: your ROOT_PASSWORD)</p>
</div>
<div class="card">
<h3>⚡ System</h3>
<pre id="sysinfo">Loading...</pre>
</div>
<script>
fetch('/sysinfo').then(r=>r.text()).then(t=>document.getElementById('sysinfo').textContent=t).catch(()=>{});
</script>
<div class="footer">RenderShell on GitHub Actions | 6-hour session</div>
</body></html>
HTML

$SUDO tee /workspace/sysinfo > /dev/null << 'SCRIPT'
#!/bin/bash
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo "CPU: $(nproc) cores"
echo "Memory: $(free -h | awk '/^Mem:/{print $3 "/" $2}')"
echo "Disk: $(df -h / | awk 'NR==2{print $3 "/" $2}')"
echo "Tailscale: $(tailscale status 2>/dev/null | head -3 || echo 'connecting...')"
SCRIPT
$SUDO chmod +x /workspace/sysinfo

log "Status page created"

# ── 5. Generate supervisord config ─────────────────────────────────────────
log "⚙️  Generating supervisord config..."
$SUDO mkdir -p /etc/supervisor/conf.d

$SUDO tee /etc/supervisor/conf.d/render-shell.conf > /dev/null << 'SUPERVISOR'
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
loglevel=info
pidfile=/tmp/supervisord.pid

[unix_http_server]
file=/tmp/supervisor.sock

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[program:ttyd]
command=/usr/bin/ttyd -p 4200 -c root:PASSWORD_HERE bash
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=5
stopsignal=TERM
stopasgroup=true
killasgroup=true
priority=10

[program:http-server]
command=python3 -m http.server 8080 --bind 0.0.0.0 --directory /workspace
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3
priority=20
SUPERVISOR

# Replace password placeholder with actual value
$SUDO sed -i "s/PASSWORD_HERE/${ROOT_PASSWORD}/g" /etc/supervisor/conf.d/render-shell.conf

log "Supervisor config generated"

# ── 6. Start Tailscale ─────────────────────────────────────────────────────
log "🔗 Starting Tailscale (userspace mode)..."
$SUDO mkdir -p /var/run/tailscale

$SUDO nohup tailscaled --state=mem: --socket=/var/run/tailscale/tailscaled.sock \
    --tun=userspace-networking > /tmp/tailscaled.log 2>&1 &
TAILSCALED_PID=$!
echo $TAILSCALED_PID | $SUDO tee /tmp/tailscaled.pid > /dev/null

# Wait for socket
for i in $(seq 1 15); do
    if [ -S /var/run/tailscale/tailscaled.sock ]; then
        break
    fi
    sleep 1
done

# Authenticate
$SUDO tailscale up \
    --auth-key="${TAILSCALE_AUTHKEY}" \
    --advertise-exit-node \
    --accept-routes \
    --reset \
    --hostname="${HOSTNAME}" 2>&1

log "✅ Tailscale authenticated"
TAILSCALE_IP=$($SUDO tailscale ip -4 2>/dev/null || echo "waiting...")
log "   Tailscale IP: ${TAILSCALE_IP}"

# ── 7. Start supervisord services ──────────────────────────────────────────
log "🚀 Starting services via supervisord..."
$SUDO /usr/bin/supervisord -c /etc/supervisor/conf.d/render-shell.conf &
echo $! | $SUDO tee /tmp/supervisord.pid > /dev/null

# ── 8. Wait for services to start ──────────────────────────────────────────
log "⏳ Waiting for services to be ready..."
for i in $(seq 1 10); do
    READY=true
    for port in 4200 8080; do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            READY=false
        fi
    done
    $READY && break
    sleep 2
done

# ── 9. Verify ──────────────────────────────────────────────────────────────
log "═══════════════════════════════════════════════════════"
log "🔍 Verifying services..."
log "═══════════════════════════════════════════════════════"

for port in 4200 8080; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        log "  ✅ Port ${port} — listening"
    else
        warn "  ⚠️  Port ${port} — NOT listening"
    fi
done

log ""
log "✅ RenderShell setup complete!"
log ""
log "   📡 Web Terminal:  https://${HOSTNAME}.<your-tailnet>.ts.net/  (login: root / ROOT_PASSWORD)"
log "   📊 Status:        http://localhost:8080"
log "   🔗 SSH:          ssh root@${TAILSCALE_IP}"
log ""
log "   The workflow will configure Tailscale Serve in the next step."
