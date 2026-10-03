#!/bin/sh
set -e

# Unset Kubernetes env vars (some hosts leak them; they confuse tailscaled)
unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP

# If ROOT_PASSWORD is set at runtime, update the password.
if [ -n "${ROOT_PASSWORD}" ] && [ "${ROOT_PASSWORD}" != "change-me" ]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd
    echo "[entrypoint] root password updated from ROOT_PASSWORD env var"
else
    echo "[entrypoint] WARNING: ROOT_PASSWORD not set — using default 'change-me'"
fi

# Validate TAILSCALE_AUTHKEY
if [ -z "${TAILSCALE_AUTHKEY}" ]; then
    echo "[entrypoint] WARNING: TAILSCALE_AUTHKEY not set — node will not register"
fi

# Ensure sshd privilege separation directory exists
mkdir -p /run/sshd

# Set friendly hostname (Render overrides at infra level, but we try anyway)
hostname render-shell 2>/dev/null || true

# Set a friendly PS1 prompt so the shell shows "render-shell" not the ugly container ID
# This goes in /etc/profile so it applies to all login shells
cat > /etc/profile.d/render-shell.sh << 'PROFILE'
# Friendly prompt — shows "render-shell" instead of the ugly container hostname
export PS1='render-shell:\w# '
# Aliases for convenience
alias ll='ls -la'
alias la='ls -la'
alias ..='cd ..'
alias ...='cd ../..'
PROFILE

# Custom motd for a nicer login experience
cat > /etc/motd << 'MOTD'

   ╔══════════════════════════════════════════╗
   ║     Render Shell — Alpine + Tailscale    ║
   ╚══════════════════════════════════════════╝

   Web terminal:  https://render-exit-node.curl-trench.ts.net/

   ⚠  Files are NOT persistent — use git or external storage
   ⚠  Container sleeps after 15 min inactivity (free tier)
   ⚠  512MB RAM / 0.1 CPU limit

MOTD

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/services.conf
