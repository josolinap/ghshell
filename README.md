# render_tailscaled + shellinabox

A Render **or GitHub Actions** service that combines:
- **Tailscale exit node** — routes your traffic through Render's (or GH runner's) IP
- **Shellinabox web terminal** — browser-based root shell, accessible via your Tailnet
- **File Browser** — web-based file manager (upload/download/edit files)
- **HTTP status page** — placeholder page on the public URL

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Render Free Web Service OR GitHub Actions Runner    │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  supervisor (PID 1 or managed)               │    │
│  │                                               │    │
│  │  ┌─ tailscaled (userspace networking) ────┐   │    │
│  │  │  ↳ registers as exit node via authkey  │   │    │
│  │  └───────────────────────────────────────┘   │    │
│  │                                               │    │
│  │  ┌─ shellinaboxd (port 4200) ────────────┐   │    │
│  │  │  ↳ web terminal (Tailnet via Serve)   │   │    │
│  │  └───────────────────────────────────────┘   │    │
│  │                                               │    │
│  │  ┌─ File Browser (port 5800) ─────────────┐   │    │
│  │  │  ↳ web file manager (Tailnet via Serve)│   │    │
│  │  └───────────────────────────────────────┘   │    │
│  │                                               │    │
│  │  ┌─ python http.server (port 8080) ──────┐   │    │
│  │  │  ↳ status page (health check)         │   │    │
│  │  └───────────────────────────────────────┘   │    │
│  └──────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
         ↑                          ↑
         │ Tailscale Serve (443)     │ Tailnet only
         │ https://render-shell.     │ (or localhost:8080)
         │   <your-tailnet>.ts.net/  │
```

## Setup

### 1. Generate a Tailscale authkey

Go to https://login.tailscale.com/admin/settings/keys and generate:
- **Reusable**: yes (so it survives restarts)
- **Ephemeral**: no (so the node persists)
- **Tags**: optional (e.g. `tag:exit-node`)

Copy the key — it looks like `tskey-auth-XXXXXXXX-YYYYYYYYYYYYYYYY`.

### 2. Deploy to Render

1. Push this repo to GitHub
2. On Render: **New → Web Service → connect repo**
3. **Environment**: Docker
4. **Instance Type**: Free
5. **Environment Variables**:

| Key | Value | Purpose |
|---|---|---|
| `TAILSCALE_AUTHKEY` | `tskey-auth-XXXX-YYYY` | Auto-registers the node on your Tailnet |
| `ROOT_PASSWORD` | `your-strong-password` | Password for the shellinabox login |
| `TAILSCALE_HOSTNAME` | `render-shell` | (optional) Custom hostname on your Tailnet |

### 3. Approve the exit node

After the first deploy:
1. Go to https://login.tailscale.com/admin/machines
2. Find the new node (`render-shell` or similar)
3. Click the `⚠` icon next to "Exit node" and approve it

### 4. Use the exit node

On any device on your Tailnet:
```bash
# Use the exit node for all traffic
tailscale up --exit-node=render-shell

# Or use it for specific traffic
tailscale up --exit-node=render-shell --exit-node-allow-lan-access=true
```

### 5. Access the web terminal

The shellinabox terminal is **only accessible via your Tailnet** (not the public Render URL):

```
http://render-shell.<your-tailnet>.ts.net:4200
```

Or find the IP:
```bash
tailscale status | grep render-shell
# → 100.x.x.x  render-shell  ...
```

Then open `http://100.x.x.x:4200` in your browser. Login with `root` + your `ROOT_PASSWORD`.

## What's exposed where

| Port | Where | What |
|---|---|---|
| 8080 | Public Render URL (`https://...onrender.com`) | Status page (HTML) |
| 4200 | Tailnet only (`http://render-shell:4200`) | Shellinabox web terminal |
| — | Tailscale | Exit node routing |

The web terminal is **not** on the public Render URL — only the status page is. This is intentional: the terminal should be private.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `TAILSCALE_AUTHKEY` | ✅ yes | — | Tailscale authkey for auto-registration |
| `ROOT_PASSWORD` | ✅ yes | `change-me` | Password for shellinabox login |
| `TAILSCALE_HOSTNAME` | no | `render-exit-node` | Hostname on your Tailnet |
| `TS_VERSION` | no | `1.86.2` | Tailscale version (build arg) |

---

## GitHub Actions Deployment (Alternative to Render)

Run RenderShell on **GitHub Actions runners** instead of Render. This gives you:

| Metric | Render Free | GitHub Actions |
|--------|------------|----------------|
| **RAM/CPU** | 512 MB / 0.1 vCPU | 7 GB / 2 vCPUs |
| **Sleep policy** | After 15 min idle | Up to 6h continuous |
| **Monthly hours** | 750 (max 24/7 for 31d) | 2,000 (free), ∞ (public repo) |
| **Runner OS** | Alpine in Docker | Ubuntu 22.04 LTS |
| **Max session** | Indefinite (with keep-alive) | 6 hours per run |
| **Docker** | ✅ | ✅ (not needed — installs natively) |

### How it works

A GitHub Actions workflow spins up the full stack on `ubuntu-latest`, connects to your
Tailnet, and exposes both the web terminal and file browser via **Tailscale Serve**:
- `https://render-shell.<your-tailnet>.ts.net/` — web terminal (shellinabox)
- `https://render-shell.<your-tailnet>.ts.net/files` — file browser

Trigger manually or via scheduled cron (06/12/18 UTC) — 3 runs covers 18 hours/day.

### Setup

#### 1. Fork or push this repo to GitHub

```bash
# Create a new repo on GitHub, then:
git remote add origin git@github.com:your-user/render-shell.git
git push -u origin main
```

#### 2. Generate a Tailscale authkey

Go to https://login.tailscale.com/admin/settings/keys and generate:
- **Reusable**: yes (survives restarts across different runner IPs)
- **Ephemeral**: no (node persists in your tailnet)
- **Tags**: optional (e.g. `tag:exit-node`)

Copy the key — it looks like `tskey-auth-XXXXXXXX-YYYYYYYYYYYYYYYY`.

#### 3. Add GitHub secrets

Go to your repo **Settings → Secrets and variables → Actions** and add:

| Secret | Value | Purpose |
|--------|-------|---------|
| `TAILSCALE_AUTHKEY` | `tskey-auth-XXXX-YYYY` | Auto-registers the node on your Tailnet |
| `ROOT_PASSWORD` | `your-strong-password` | Password for root shell + SSH login |
| `FILEBROWSER_PASSWORD` | `your-filebrowser-password` | Password for file browser admin login |

#### 4. Start a session

**Manual:** Go to **Actions → RenderShell → Run workflow** → set duration → Run.

**Scheduled:** Runs automatically at 06:00, 12:00, and 18:00 UTC daily.

#### 5. Approve the exit node

After the first run:
1. Go to https://login.tailscale.com/admin/machines
2. Find the new node (`render-shell`)
3. Click the `⚠` icon next to "Exit node" and approve it

#### 6. Connect

On any device on your Tailnet:
```bash
# All traffic through RenderShell
tailscale up --exit-node=render-shell

# Or just use terminal/file browser:
# Open in browser:
#   https://render-shell.<your-tailnet>.ts.net/        # web terminal
#   https://render-shell.<your-tailnet>.ts.net/files    # file browser
```

### What's exposed

| Service | Port | Access | Auth |
|---------|------|--------|------|
| Web Terminal | 4200 → 443 (Serve) | Tailnet only | root + ROOT_PASSWORD |
| File Browser | 5800 → 443/files (Serve) | Tailnet only | admin + FILEBROWSER_PASSWORD |
| SSH | 22 | localhost only | root + ROOT_PASSWORD |
| Status page | 8080 | localhost | none |

### Workflow details

- **Max runtime**: 6 hours per run (configurable via `duration_hours` input)
- **Trigger**: `workflow_dispatch` (manual) + `schedule` (cron)
- **Files**: `.github/workflows/render-shell.yml` + `setup-github-actions.sh`
- **Arch**: Installs natively on the runner (no Docker-in-Docker) — faster boot, simpler

### Limitation: 6-hour max session

GitHub Actions has a 6-hour limit for `workflow_dispatch` jobs on free/paid plans.
For 24/7 coverage, the three daily cron runs overlap to cover most of the day:
```
06:00 ────────── 12:00 UTC  (6h)
         12:00 ────────── 18:00 UTC  (6h)
                  18:00 ────────── 00:00 UTC  (6h)
```
The 00:00–06:00 gap is covered by the overlap buffer (each run starts while the
previous one is still active for ~1 minute).

---

## Free tier limitations

## Customization

### Auto-login (no password prompt)

Edit `supervisord.conf`, change the shellinabox command:
```
-s /:LOGIN    →   -s /:root
```
⚠ Anyone on your Tailnet gets a root shell without a password.

### Different shellinabox theme

Edit `supervisord.conf`:
```
--css=/etc/shellinabox/options-enabled/00+Black-on-White.css
```
Available themes in `/etc/shellinabox/options-enabled/`.

### Keep container awake (prevents sleep)

Add a self-ping cron job in the Dockerfile:
```dockerfile
RUN echo '*/10 * * * * wget -q -O- http://localhost:8080 >/dev/null' > /etc/crontabs/root
RUN apk add --no-cache dcron
# Add to supervisord.conf: [program:cron] command=crond -f
```
⚠ Burns your 750 free hours faster.

## Troubleshooting

**"tailscale up" fails in logs**
- Check that `TAILSCALE_AUTHKEY` is set correctly in Render env vars
- Check that the authkey hasn't expired (reusable keys last 90 days)
- Check Render logs for the exact error

**Web terminal not reachable at `http://render-shell:4200`**
- Verify the node is online: `tailscale status | grep render-shell`
- Userspace networking doesn't expose ports to the Tailnet directly — you may need to use `tailscale serve` or `tailscale funnel` to expose 4200

**Exit node not routing traffic**
- Approve the exit node in https://login.tailscale.com/admin/machines
- On the client: `tailscale up --exit-node=render-shell`
- Check: `curl https://api.ipify.org` should show Render's IP, not yours

**Container sleeps and drops the exit node**
- This is expected on free tier (15 min inactivity)
- Either upgrade to paid tier, or add a self-ping (see above)
