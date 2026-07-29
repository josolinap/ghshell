#!/bin/bash
# =============================================================================
# RenderShell — GitHub Actions Runner Setup Script
# =============================================================================
# Installs and configures the full RenderShell stack on a GitHub Actions
# Ubuntu runner:
#   - Tailscale (userspace networking)
#   - Shellinabox (web terminal on port 4200)
#   - File Browser (web file manager on port 5800)
#   - SSH daemon (for shellinabox auth)
#   - HTTP status page (on port 8080)
#
# All services are managed by supervisord.
#
# Environment variables (set by the workflow from GitHub Secrets):
#   TAILSCALE_AUTHKEY     — required, reusable auth key
#   ROOT_PASSWORD         — required, password for root login
#   FILEBROWSER_PASSWORD  — required, password for file browser admin
#   TAILSCALE_HOSTNAME    — optional, default: render-shell
# =============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m' # No Color
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup]${NC} $*" >&2; }

# GitHub Actions runner runs as non-root → use sudo for system ops
SUDO=''
if [ "$(id -u)" != "0" ]; then
    SUDO='sudo'
    log "Running as non-root — using sudo for system operations"
fi

HOSTNAME="${TAILSCALE_HOSTNAME:-render-shell}"

log "🚀 RenderShell setup starting on $(hostname)"
log "Target hostname: ${HOSTNAME}"

# ── Validate required secrets ───────────────────────────────────────────────
if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    err "TAILSCALE_AUTHKEY is not set! Add it as a GitHub secret."
    exit 1
fi
if [ -z "${ROOT_PASSWORD:-}" ]; then
    warn "ROOT_PASSWORD not set — using default 'change-me'"
    ROOT_PASSWORD="change-me"
fi
if [ -z "${FILEBROWSER_PASSWORD:-}" ]; then
    warn "FILEBROWSER_PASSWORD not set — using default 'admin'"
    FILEBROWSER_PASSWORD="admin"
fi

# ── 1. Install Tailscale ───────────────────────────────────────────────────
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
    ca-certificates \
    supervisor \
    python3 \
    openssh-server \
    curl \
    git \
    vim \
    nano \
    htop \
    bash \
    coreutils \
    findutils \
    grep \
    tar \
    gzip \
    unzip \
    wget \
    shellinabox \
    2>&1 | tail -1

log "Packages installed. shellinabox version: $(shellinaboxd --version 2>&1 || true)"

# ── 3. Install File Browser ────────────────────────────────────────────────
log "📁 Installing File Browser..."
if ! command -v filebrowser &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

# Initialize filebrowser database
$SUDO filebrowser config init --database /etc/filebrowser.db 2>/dev/null || true
$SUDO filebrowser config set --database /etc/filebrowser.db \
    --address 0.0.0.0 \
    --port 5800 \
    --root /root 2>/dev/null || true
$SUDO filebrowser users add --database /etc/filebrowser.db \
    admin "${FILEBROWSER_PASSWORD}" \
    --perm.admin 2>/dev/null || \
$SUDO filebrowser users update admin \
    --password "${FILEBROWSER_PASSWORD}" \
    --database /etc/filebrowser.db 2>/dev/null || true

log "File Browser installed: $(filebrowser version 2>&1)"

# ── 4. Configure SSH ────────────────────────────────────────────────────────
log "🔐 Configuring SSH..."
echo "root:${ROOT_PASSWORD}" | $SUDO chpasswd

# Ensure SSH allows root login with passwords
$SUDO sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
$SUDO sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
$SUDO sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
$SUDO sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config

# Generate host keys if missing
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    $SUDO ssh-keygen -A 2>/dev/null
fi

$SUDO mkdir -p /run/sshd

log "SSH configured for root login"

# ── 5. Create status page ───────────────────────────────────────────────────
log "🌐 Creating HTTP status page..."
$SUDO mkdir -p /workspace

$SUDO tee /workspace/index.html > /dev/null << 'HTML'
<!DOCTYPE html>
<html><head><title>RenderShell (GitHub Actions)</title>
<style>
body{font-family:system-ui,sans-serif;max-width:700px;margin:50px auto;padding:0 20px;color:#333;background:#fafafa}
.card{background:#fff;padding:20px;border-radius:8px;margin:15px 0;border:1px solid #e0e0e0;box-shadow:0 1px 3px rgba(0,0,0,0.1)}
h1{color:#1a1a1a;border-bottom:3px solid #2ea44f;padding-bottom:10px}
a{color:#1976d2;text-decoration:none;font-weight:500}
a:hover{text-decoration:underline}
code{background:#e8e8e8;padding:2px 6px;border-radius:3px;font-size:0.9em}
.footer{margin-top:30px;font-size:0.85em;color:#666}
.badge{display:inline-block;background:#2ea44f;color:#fff;padding:2px 10px;border-radius:12px;font-size:0.8em}
</style></head>
<body>
<h1>🖥️ RenderShell <span class="badge">GitHub Actions</span></h1>
<div class="card">
<h3>📡 Web Terminal (shellinabox)</h3>
<p>Access via Tailscale: <code>https://render-shell.&lt;your-tailnet&gt;.ts.net/</code></p>
</div>
<div class="card">
<h3>📁 File Browser</h3>
<p>Access via Tailscale: <code>https://render-shell.&lt;your-tailnet&gt;.ts.net/files</code></p>
<p>Login: <code>admin</code> / your <code>FILEBROWSER_PASSWORD</code></p>
</div>
<div class="card">
<h3>🔗 Tailscale Exit Node</h3>
<p>Active. Approve the exit node in Tailscale admin console.</p>
</div>
<div class="card">
<h3>⚡ System</h3>
<pre id="sysinfo">Loading...</pre>
</div>
<script>
fetch('/sysinfo').then(r=>r.text()).then(t=>document.getElementById('sysinfo').textContent=t).catch(()=>{});
</script>
<div class="footer">
RenderShell running on GitHub Actions | <span id="uptime"></span>
</div>
</body></html>
HTML

# Simple system info endpoint
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

# ── 6. Generate supervisord config ─────────────────────────────────────────
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

[program:sshd]
command=/usr/sbin/sshd -D -e -o ListenAddress=127.0.0.1
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3
priority=10

[program:shellinabox]
command=/usr/bin/shellinaboxd --disable-ssl --no-beep -s /:SSH:127.0.0.1:22 -p 4200
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3
stopsignal=TERM
stopasgroup=true
killasgroup=true
priority=20

[program:filebrowser]
command=/usr/local/bin/filebrowser --database /etc/filebrowser.db
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3
priority=25

[program:http-server]
command=python3 -m http.server 8080 --bind 0.0.0.0 --directory /workspace
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
startretries=3
priority=30
SUPERVISOR

log "Supervisor config generated"

# ── 7. Start Tailscale ─────────────────────────────────────────────────────
log "🔗 Starting Tailscale (userspace mode)..."
# Ensure socket directory exists
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

# ── 8. Start services via supervisord ──────────────────────────────────────
log "🚀 Starting all services via supervisord..."
$SUDO /usr/bin/supervisord -c /etc/supervisor/conf.d/render-shell.conf &
SUPERVISORD_PID=$!
echo $SUPERVISORD_PID | $SUDO tee /tmp/supervisord.pid > /dev/null

# Wait for services to be ready
sleep 3

# ── 9. Verify everything is running ─────────────────────────────────────────
log "═══════════════════════════════════════════════════════"
log "🔍 Verifying services..."
log "═══════════════════════════════════════════════════════"

check_port() {
    local port=$1 name=$2
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        log "  ✅ ${name} — listening on :${port}"
    else
        warn "  ⚠️  ${name} — NOT listening on :${port}"
    fi
}

sleep 2
check_port 4200 "Shellinabox"
check_port 5800 "File Browser"
check_port 8080 "HTTP Status"
check_port 22   "SSH"

log ""
log "✅ RenderShell setup complete!"
log ""
log "   📡 Web Terminal:  will be at https://${HOSTNAME}.<your-tailnet>.ts.net/"
log "   📁 File Browser:  will be at https://${HOSTNAME}.<your-tailnet>.ts.net/files"
log "   📊 Status:        http://localhost:8080"
log ""
log "   The workflow will configure Tailscale Serve in the next step."
