# Airlink Panel Executor

An interactive bash menu for installing, running, and managing [Airlink Panel](https://github.com/AirlinkLabs/panel) on any VPS or container.

Made by **prime.dev1**

## Requirements

- Linux with one of: `apt`, `dnf`, `yum`, `apk`, `pacman`
- Root, or a user with `sudo` — the script still runs without either, but system-level package installs will be skipped
- Internet access (to pull Node.js, pnpm, the Airlink repo, and optionally cloudflared)

## Usage

```bash
chmod +x airlink-executor.sh
sudo ./airlink-executor.sh
```

You'll land on a numbered menu. Re-run the script any time — it remembers your panel directory and port in `~/.airlink-executor.conf`.

## Menu options

| # | Option | What it does |
|---|--------|---------------|
| 1 | Install Panel | Installs Node.js 18+, pnpm, git and build tools; clones `AirlinkLabs/panel`; prompts for port, public URL, and database; generates a session secret; runs migrations; builds the panel |
| 2 | Run Panel (Production) | Builds the panel and starts it as a managed background service |
| 3 | Run Panel (Development) | Runs the panel in the foreground with `NODE_ENV=development` (Ctrl+C to stop) |
| 4 | Update Panel | `git pull`, reinstalls dependencies, re-runs migrations, rebuilds, restarts the service |
| 5 | Connect Cloudflared | Installs `cloudflared` if missing, then sets up a quick tunnel (instant temp URL) or a named tunnel (your own token) |
| 6 | Create Admin User | See [Admin user](#admin-user) below |
| 7 | Configure External MySQL | Prompts for host/port/user/password/database and writes `DATABASE_URL` into `.env` |
| 8 | Service Status | Shows whether the panel is running, using whichever process manager was detected |
| 9 | Restart Service | Restarts the panel |
| 10 | Stop Service | Stops the panel |
| 11 | View Logs | Tails the panel's logs |
| 12 | Open Firewall Port | Opens the configured port via `ufw` or `firewalld` |

## Environment detection

On startup, the script checks — in order — for **systemd**, then **supervisor**, then **pm2**. If none of those are present (common in CodeSandbox, GitHub Codespaces, and other bare containers), it automatically installs pm2 as a universal fallback so the panel still survives as a managed background process. If pm2 can't be installed either (no permissions), it falls back to a plain `nohup` background process.

Package management is auto-detected across `apt`, `dnf`, `yum`, `apk`, and `pacman`, so the same script works on Debian/Ubuntu, Fedora/RHEL/CentOS, Alpine, and Arch-based hosts.

## Database

- Default: local SQLite (`file:./storage/database.db`) — simplest option, good for testing or small setups.
- External MySQL can be configured at install time, any time from the menu (option 7), or the script will offer it automatically if a migration fails.

## Admin user

Airlink has no CLI command for creating an admin. Instead, **the first account registered through the web UI is automatically made admin.** Option 6 checks `package.json` for an admin-related script (in case a future version adds one) and runs it if found; otherwise it just points you to the panel's URL to register that first account.

## Credits

Airlink Panel installer executor — made by **prime.dev1**.
