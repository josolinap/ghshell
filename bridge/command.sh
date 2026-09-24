#!/usr/bin/env bash
set -euo pipefail
echo "=== HOST ==="
hostname
echo "=== IDENTITY ==="
id
echo "=== TAILSCALE STATUS ==="
sudo tailscale status
echo "=== TAILSCALE IP ==="
sudo tailscale ip -1
sudo tailscale ip -4
echo "=== TAILNET PING/CONNECTIVITY INVENTORY ==="
sudo tailscale ping --c 1 100.100.100.100 || true
echo "=== ROUTES ==="
ip route || true
echo "=== DNS ==="
getent hosts login.tailscale.com || true
