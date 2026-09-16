# Airlink Installation One Click Script
*by prime.dev1*

## Run it

```bash
sudo bash airlink-installer.sh
```

or as a curl-pipe-bash one-liner once it's hosted somewhere:

```bash
curl -fsSL <your-raw-url>/airlink-installer.sh | sudo bash
```

That drops you into a menu (uses `whiptail` for a boxed button-style menu if
available, plain numbered menu otherwise): Install Panel, Update Panel, Add
Node, Connect Cloudflared, Admin User Setup, service status/restart, and
**Launch Web Dashboard** — which starts a local browser GUI.

## The web GUI

Choosing "Launch Web Dashboard" starts a small built-in web server (Python
stdlib only, no extra installs) and prints a URL like:

```
http://YOUR_SERVER_IP:7100
```

Open that in a browser. It's a dark, modern dashboard with a button per
action; clicking one pops a modal (with input fields where needed — e.g.
pasting the node command or Cloudflare token), runs the real script on the
VPS in the background, and streams the live log with a parsed step list
until it finishes. It tries to open the port automatically via `ufw` /
`firewalld`; if that's not available in your environment (common inside
sandboxed containers), open/forward the port yourself in your VPS
provider's network panel (or Pterodactyl's port allocations, if this runs
inside a Pterodactyl-hosted node).

## What it auto-detects

- **Package manager**: apt / dnf / yum.
- **Service manager**: uses `systemd` only if it's actually live (checks for
  a real `/run/systemd/system` and a responsive `systemctl`), otherwise
  falls back to `supervisor` — installing it if missing. This is what makes
  it work unmodified both on a normal VPS and inside a systemd-less
  sandbox/container.

## Two spots you'll likely want to tune for your exact fork

I don't have access to your Airlink codebase's internal CLI, so I built
these two actions to be safe-but-generic and flagged where to adjust:

1. **`action_add_node()`** — assumes the panel gives you a full shell
   command to paste (matching how you described Cloudflared already
   working: "paste token as full command or bare token"). If it instead
   hands out a bare token, edit the `NODE_FALLBACK_TEMPLATE` variable near
   the top of that function to match your panel's real node-agent install
   syntax.
2. **`action_admin_setup()`** — writes `ADMIN_USERNAME` / `ADMIN_EMAIL` /
   `ADMIN_PASSWORD` into `.env`, then looks for an npm script named
   `seed:admin` or `seed` in `package.json` and runs it. If your fork uses a
   different bootstrap command (or a one-off CLI script) to actually create
   the admin row in the DB, swap that in.

Everything else (install, update, service registration, Cloudflared,
dashboard) should work as-is against a standard Node.js app with `start`
(or `dev`) in `package.json`.

## Config

All the defaults are overridable via env vars before running, e.g.:

```bash
AIRLINK_INSTALL_DIR=/opt/airlink \
AIRLINK_REPO_URL=https://github.com/Srccodeusr/Aetherpanel-only-frontend-Made-by-Zensei-.git \
AIRLINK_PANEL_PORT=3000 \
AIRLINK_DASHBOARD_PORT=7100 \
sudo -E bash airlink-installer.sh
```
