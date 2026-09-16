#!/usr/bin/env bash
#
# ============================================================================
#  Airlink Installation One Click Script
#  Made by prime.dev1
# ============================================================================
#
#  One-shot installer / operator console for the Airlink hosting panel.
#
#  Usage (interactive menu):
#      sudo bash airlink-installer.sh
#
#  Usage (curl-pipe-bash):
#      curl -fsSL <raw-url-to-this-file> | sudo bash
#
#  Usage (headless / scriptable, used internally by the web dashboard):
#      sudo bash airlink-installer.sh --action <name> [--flags...]
#
#  This script is idempotent where practical: re-running "Install" on an
#  existing install will offer to update instead of clobbering it, service
#  files are only rewritten if missing, etc.
# ----------------------------------------------------------------------------

set -uo pipefail

# ============================================================================
# Globals / configuration (override any of these with env vars before running)
# ============================================================================
SCRIPT_VERSION="1.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

INSTALL_DIR="${AIRLINK_INSTALL_DIR:-/opt/airlink}"
REPO_URL="${AIRLINK_REPO_URL:-https://github.com/Srccodeusr/Aetherpanel-only-frontend-Made-by-Zensei-.git}"
SERVICE_NAME="${AIRLINK_SERVICE_NAME:-airlink-panel}"
SERVICE_USER="${AIRLINK_SERVICE_USER:-airlink}"
PANEL_PORT="${AIRLINK_PANEL_PORT:-3000}"
DASHBOARD_PORT="${AIRLINK_DASHBOARD_PORT:-7100}"
NODE_MAJOR="${AIRLINK_NODE_MAJOR:-20}"

LOG_DIR="/var/log/airlink-installer"
STATE_DIR="/etc/airlink-installer"
DASHBOARD_DIR="$STATE_DIR/dashboard"
CREDIT_LINE="Airlink Installation One Click Script  |  made by prime.dev1"

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

# ============================================================================
# Styling helpers
# ============================================================================
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
  C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
  C_BLUE="\033[34m"; C_MAGENTA="\033[35m"; C_CYAN="\033[36m"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

banner() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "   █████╗ ██╗██████╗ ██╗     ██╗███╗   ██╗██╗  ██╗"
  echo "  ██╔══██╗██║██╔══██╗██║     ██║████╗  ██║██║ ██╔╝"
  echo "  ███████║██║██████╔╝██║     ██║██╔██╗ ██║█████╔╝ "
  echo "  ██╔══██║██║██╔══██╗██║     ██║██║╚██╗██║██╔═██╗ "
  echo "  ██║  ██║██║██║  ██║███████╗██║██║ ╚████║██║  ██╗"
  echo "  ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝"
  echo -e "${C_RESET}${C_DIM}  ${CREDIT_LINE}  |  v${SCRIPT_VERSION}${C_RESET}"
  echo
}

log()   { echo -e "${C_DIM}[INFO]${C_RESET} $*"; }
step()  { echo -e "${C_BLUE}${C_BOLD}[STEP]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}${C_BOLD}[OK]${C_RESET}   $*"; }
warn()  { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $*"; }
fail()  { echo -e "${C_RED}${C_BOLD}[FAIL]${C_RESET} $*"; }
die()   { fail "$*"; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script needs root. Re-run with: sudo bash $(basename "$SCRIPT_PATH")"
  fi
}

# ============================================================================
# Environment detection
# ============================================================================
PKG_MANAGER=""
detect_pkg_manager() {
  if command -v apt-get &>/dev/null; then PKG_MANAGER="apt"
  elif command -v dnf &>/dev/null; then PKG_MANAGER="dnf"
  elif command -v yum &>/dev/null; then PKG_MANAGER="yum"
  else PKG_MANAGER="unknown"
  fi
  echo "$PKG_MANAGER"
}

is_containerized() {
  # Best-effort container detection (Docker/LXC/Pterodactyl-style node containers)
  [[ -f /.dockerenv ]] && return 0
  grep -qaE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

SERVICE_MANAGER=""
detect_service_manager() {
  # Prefer systemd only if it is genuinely usable (PID 1 is systemd AND
  # systemctl can talk to it). Sandboxed containers frequently ship the
  # systemctl binary without a working systemd, which would otherwise
  # silently fail every enable/start call.
  if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]] && systemctl list-units &>/dev/null; then
    SERVICE_MANAGER="systemd"
  elif command -v supervisorctl &>/dev/null; then
    SERVICE_MANAGER="supervisor"
  else
    SERVICE_MANAGER="none"
  fi
  echo "$SERVICE_MANAGER"
}

ensure_service_manager() {
  detect_service_manager >/dev/null
  if [[ "$SERVICE_MANAGER" == "none" ]]; then
    warn "No usable service manager detected (no live systemd, no supervisor)."
    step "Installing supervisor as the process manager (works inside containers/VPS without systemd)..."
    install_packages supervisor
    if [[ "$PKG_MANAGER" == "apt" ]]; then
      mkdir -p /etc/supervisor/conf.d
      systemctl_or_service_start supervisor 2>/dev/null || service supervisor start 2>/dev/null || supervisord -c /etc/supervisor/supervisord.conf &>/dev/null &
    fi
    SERVICE_MANAGER="supervisor"
  fi
  ok "Service manager: ${C_BOLD}${SERVICE_MANAGER}${C_RESET}"
}

systemctl_or_service_start() {
  systemctl start "$1" 2>/dev/null || service "$1" start 2>/dev/null
}

# ============================================================================
# Package installation
# ============================================================================
install_packages() {
  local pkgs=("$@")
  detect_pkg_manager >/dev/null
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >>"$LOG_DIR/apt.log" 2>&1
      apt-get install -y "${pkgs[@]}" >>"$LOG_DIR/apt.log" 2>&1
      ;;
    dnf) dnf install -y "${pkgs[@]}" >>"$LOG_DIR/dnf.log" 2>&1 ;;
    yum) yum install -y "${pkgs[@]}" >>"$LOG_DIR/yum.log" 2>&1 ;;
    *) die "Unsupported package manager. Install manually: ${pkgs[*]}" ;;
  esac
}

install_node() {
  if command -v node &>/dev/null && [[ "$(node -v | sed 's/^v//;s/\..*//')" -ge "$NODE_MAJOR" ]]; then
    ok "Node.js $(node -v) already present"
    return
  fi
  step "Installing Node.js ${NODE_MAJOR}.x..."
  case "$PKG_MANAGER" in
    apt)
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >>"$LOG_DIR/node.log" 2>&1
      install_packages nodejs
      ;;
    dnf|yum)
      curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >>"$LOG_DIR/node.log" 2>&1
      install_packages nodejs
      ;;
  esac
  command -v node &>/dev/null && ok "Node.js $(node -v) installed" || die "Node.js install failed, check $LOG_DIR/node.log"
}

install_dependencies() {
  step "Installing base dependencies (curl, git, build tools, python3, whiptail)..."
  case "$PKG_MANAGER" in
    apt)  install_packages curl git build-essential python3 unzip whiptail ufw ;;
    dnf)  install_packages curl git gcc gcc-c++ make python3 unzip newt firewalld ;;
    yum)  install_packages curl git gcc gcc-c++ make python3 unzip newt firewalld ;;
  esac
  ok "Base dependencies installed"
  install_node
}

open_firewall_port() {
  local port="$1"
  if command -v ufw &>/dev/null && ufw status &>/dev/null; then
    ufw allow "${port}/tcp" &>/dev/null && ok "Opened port ${port}/tcp (ufw)"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --add-port="${port}/tcp" --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    ok "Opened port ${port}/tcp (firewalld)"
  else
    warn "No local firewall tool detected — if the panel/dashboard isn't reachable, open port ${port} in your VPS provider's network/firewall settings (and in Pterodactyl's port allocations, if this runs inside a Pterodactyl node)."
  fi
}

get_public_ip() {
  curl -fsSL --max-time 4 https://ifconfig.me 2>/dev/null \
    || curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null \
    || echo "YOUR_SERVER_IP"
}

# ============================================================================
# Service (systemd / supervisor) abstraction
# ============================================================================
create_service_user() {
  if ! id -u "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null
    ok "Created system user '${SERVICE_USER}'"
  fi
}

# create_service <name> <working_dir> <exec_command> <run_as_user>
create_service() {
  local name="$1" workdir="$2" exec_cmd="$3" run_user="${4:-root}"
  detect_service_manager >/dev/null
  case "$SERVICE_MANAGER" in
    systemd)
      cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${name} (Airlink)
After=network.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${workdir}
ExecStart=${exec_cmd}
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable "${name}" &>/dev/null
      ;;
    supervisor)
      mkdir -p /etc/supervisor/conf.d
      cat > "/etc/supervisor/conf.d/${name}.conf" <<EOF
[program:${name}]
directory=${workdir}
command=${exec_cmd}
autostart=true
autorestart=true
user=${run_user}
stdout_logfile=${LOG_DIR}/${name}.out.log
stderr_logfile=${LOG_DIR}/${name}.err.log
environment=NODE_ENV="production"
EOF
      supervisorctl reread &>/dev/null
      supervisorctl update &>/dev/null
      ;;
    *) die "No service manager available to register '${name}'" ;;
  esac
  ok "Service '${name}' registered under ${SERVICE_MANAGER}"
}

service_action() {
  local name="$1" action="$2"
  detect_service_manager >/dev/null
  case "$SERVICE_MANAGER" in
    systemd)    systemctl "${action}" "${name}" ;;
    supervisor) supervisorctl "${action}" "${name}" ;;
    *) die "No service manager available" ;;
  esac
}

# ============================================================================
# Core actions
# ============================================================================

action_install_panel() {
  step "Installing the Airlink panel..."
  install_dependencies
  ensure_service_manager
  create_service_user

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    warn "An install already exists at ${INSTALL_DIR}."
    action_update_panel
    return
  fi

  step "Cloning repository..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" >>"$LOG_DIR/git.log" 2>&1 \
    || die "git clone failed, see $LOG_DIR/git.log"
  ok "Repository cloned to ${INSTALL_DIR}"

  cd "$INSTALL_DIR" || die "Could not enter $INSTALL_DIR"

  if [[ -f .env.example && ! -f .env ]]; then
    cp .env.example .env
    ok ".env created from .env.example"
  elif [[ ! -f .env ]]; then
    touch .env
  fi
  grep -q '^PORT=' .env 2>/dev/null || echo "PORT=${PANEL_PORT}" >> .env

  step "Installing npm packages (this can take a while)..."
  npm install >>"$LOG_DIR/npm-install.log" 2>&1 || die "npm install failed, see $LOG_DIR/npm-install.log"
  ok "npm packages installed"

  if node -e "process.exit(require('./package.json').scripts && require('./package.json').scripts.build ? 0 : 1)" 2>/dev/null; then
    step "Running build..."
    npm run build >>"$LOG_DIR/npm-build.log" 2>&1 || warn "Build step failed/nonexistent, continuing (see $LOG_DIR/npm-build.log)"
  fi

  local start_script
  start_script=$(node -e "const s=require('./package.json').scripts||{}; console.log(s.start ? 'start' : (s.dev ? 'dev' : ''))" 2>/dev/null)
  [[ -z "$start_script" ]] && start_script="start"

  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR" 2>/dev/null

  create_service "$SERVICE_NAME" "$INSTALL_DIR" "$(command -v npm) run ${start_script}" "$SERVICE_USER"
  service_action "$SERVICE_NAME" restart 2>/dev/null || service_action "$SERVICE_NAME" start

  open_firewall_port "$PANEL_PORT"
  local ip; ip="$(get_public_ip)"
  ok "Panel installed and running."
  echo -e "${C_GREEN}${C_BOLD}  -> Open: http://${ip}:${PANEL_PORT}${C_RESET}"
}

action_update_panel() {
  step "Updating the Airlink panel at ${INSTALL_DIR}..."
  [[ -d "$INSTALL_DIR/.git" ]] || die "No existing install found at ${INSTALL_DIR}. Run Install first."
  cd "$INSTALL_DIR" || die "Could not enter $INSTALL_DIR"

  if [[ -n "$(git status --porcelain)" ]]; then
    warn "Local changes detected — stashing them before updating (git stash)."
    git stash push -u -m "airlink-installer autostash" >>"$LOG_DIR/git.log" 2>&1
  fi

  git fetch --all >>"$LOG_DIR/git.log" 2>&1
  git pull >>"$LOG_DIR/git.log" 2>&1 || die "git pull failed, see $LOG_DIR/git.log"
  ok "Repository updated"

  step "Reinstalling npm packages..."
  npm install >>"$LOG_DIR/npm-install.log" 2>&1 || die "npm install failed, see $LOG_DIR/npm-install.log"

  if node -e "process.exit(require('./package.json').scripts && require('./package.json').scripts.build ? 0 : 1)" 2>/dev/null; then
    step "Rebuilding..."
    npm run build >>"$LOG_DIR/npm-build.log" 2>&1 || warn "Build step failed/nonexistent, continuing"
  fi

  ensure_service_manager
  step "Restarting service..."
  service_action "$SERVICE_NAME" restart || warn "Could not restart automatically — restart it manually."
  ok "Panel updated and restarted."
}

# action_add_node [<pasted_command>]
# The panel's "Create Node" screen generates a one-line install/link command
# for the machine that will run that node. Paste that exact command here.
# NOTE: adjust NODE_FALLBACK_TEMPLATE below if your panel version instead
# hands out a bare token rather than a full command.
NODE_FALLBACK_TEMPLATE='echo "Got only a token, not a full command. Edit NODE_FALLBACK_TEMPLATE in this script to match your panel'"'"'s actual node-agent install syntax for: %s"'

action_add_node() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    echo
    echo -e "${C_CYAN}${C_BOLD}Add Node${C_RESET}"
    echo "  1. In the Airlink panel admin, go to: Nodes -> Create Node"
    echo "  2. Copy the install command it gives you"
    echo "  3. Paste it below and press Enter"
    echo
    read -r -p "Paste the node command here: " cmd
  fi
  [[ -z "$cmd" ]] && die "No command provided."

  if [[ "$cmd" != *" "* && "$cmd" != *"curl"* && "$cmd" != *"wget"* ]]; then
    # Looks like a bare token rather than a full shell command
    step "Input looks like a bare token — building install command from template..."
    # shellcheck disable=SC2059
    cmd=$(printf "$NODE_FALLBACK_TEMPLATE" "$cmd")
  fi

  step "Running node install command..."
  echo -e "${C_DIM}\$ ${cmd}${C_RESET}"
  eval "$cmd"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    ok "Node command finished successfully."
  else
    fail "Node command exited with status ${rc}. Check the output above."
  fi
  return $rc
}

# action_setup_cloudflared [<token_or_full_command>]
action_setup_cloudflared() {
  local input="${1:-}"
  ensure_service_manager

  if ! command -v cloudflared &>/dev/null; then
    step "Installing cloudflared..."
    local arch; arch="$(uname -m)"
    local cf_arch="amd64"
    case "$arch" in
      x86_64) cf_arch="amd64" ;;
      aarch64|arm64) cf_arch="arm64" ;;
      armv7l) cf_arch="arm" ;;
    esac
    case "$PKG_MANAGER" in
      apt)
        curl -fsSL -o /usr/local/bin/cloudflared \
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
          >>"$LOG_DIR/cloudflared.log" 2>&1
        chmod +x /usr/local/bin/cloudflared
        ;;
      dnf|yum)
        curl -fsSL -o /usr/local/bin/cloudflared \
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
          >>"$LOG_DIR/cloudflared.log" 2>&1
        chmod +x /usr/local/bin/cloudflared
        ;;
    esac
    command -v cloudflared &>/dev/null || die "cloudflared install failed, see $LOG_DIR/cloudflared.log"
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"
  else
    ok "cloudflared already installed"
  fi

  if [[ -z "$input" ]]; then
    echo
    echo -e "${C_CYAN}${C_BOLD}Connect Cloudflared${C_RESET}"
    echo "  Paste either the full 'cloudflared service install <token>' command"
    echo "  from your Cloudflare Zero Trust tunnel page, or just the bare token."
    echo
    read -r -p "Paste token or full command: " input
  fi
  [[ -z "$input" ]] && die "No token/command provided."

  local token="$input"
  if [[ "$input" == *"cloudflared"* ]]; then
    token="$(echo "$input" | grep -oE '[A-Za-z0-9+/_=-]{50,}' | tail -1)"
    [[ -z "$token" ]] && token="$input"
  fi

  case "$SERVICE_MANAGER" in
    systemd)
      step "Installing cloudflared as a systemd service..."
      cloudflared service install "$token" >>"$LOG_DIR/cloudflared.log" 2>&1
      systemctl enable cloudflared &>/dev/null
      systemctl restart cloudflared
      ;;
    supervisor)
      step "Registering cloudflared under supervisor..."
      cat > /etc/supervisor/conf.d/cloudflared.conf <<EOF
[program:cloudflared]
command=/usr/local/bin/cloudflared tunnel run --token ${token}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/cloudflared.out.log
stderr_logfile=${LOG_DIR}/cloudflared.err.log
EOF
      supervisorctl reread &>/dev/null
      supervisorctl update &>/dev/null
      supervisorctl restart cloudflared &>/dev/null
      ;;
  esac
  ok "Cloudflared tunnel connected."
}

# action_admin_setup [<username>] [<email>] [<password>]
action_admin_setup() {
  local username="${1:-}" email="${2:-}" password="${3:-}"
  echo
  echo -e "${C_CYAN}${C_BOLD}Admin User Setup${C_RESET}"
  [[ -z "$username" ]] && read -r -p "Admin username: " username
  [[ -z "$email" ]] && read -r -p "Admin email: " email
  if [[ -z "$password" ]]; then
    read -r -s -p "Admin password: " password; echo
  fi
  [[ -z "$username" || -z "$email" || -z "$password" ]] && die "Username, email and password are all required."

  [[ -d "$INSTALL_DIR" ]] || die "Panel isn't installed at ${INSTALL_DIR} yet — run Install first."
  cd "$INSTALL_DIR" || die "Could not enter $INSTALL_DIR"

  {
    grep -q '^ADMIN_USERNAME=' .env 2>/dev/null && sed -i "s/^ADMIN_USERNAME=.*/ADMIN_USERNAME=${username}/" .env || echo "ADMIN_USERNAME=${username}" >> .env
    grep -q '^ADMIN_EMAIL=' .env 2>/dev/null && sed -i "s/^ADMIN_EMAIL=.*/ADMIN_EMAIL=${email}/" .env || echo "ADMIN_EMAIL=${email}" >> .env
    grep -q '^ADMIN_PASSWORD=' .env 2>/dev/null && sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${password}/" .env || echo "ADMIN_PASSWORD=${password}" >> .env
  }
  ok "Admin credentials written to .env"

  local seed_script
  seed_script=$(node -e "const s=require('./package.json').scripts||{}; console.log(s['seed:admin'] ? 'seed:admin' : (s.seed ? 'seed' : ''))" 2>/dev/null)
  if [[ -n "$seed_script" ]]; then
    step "Running 'npm run ${seed_script}' to create the admin account..."
    npm run "$seed_script" >>"$LOG_DIR/admin-seed.log" 2>&1 && ok "Admin account created." \
      || warn "Seed script failed — check $LOG_DIR/admin-seed.log. Credentials are still saved in .env."
  else
    warn "No seed/admin npm script found in package.json — credentials are saved in .env for the app to pick up on next start. If your fork uses a different bootstrap command, edit action_admin_setup() in this script."
  fi

  step "Restarting service so changes take effect..."
  service_action "$SERVICE_NAME" restart 2>/dev/null || warn "Restart it manually to apply the new admin credentials."
  ok "Admin setup complete."
}

action_service_status() {
  detect_service_manager >/dev/null
  echo
  case "$SERVICE_MANAGER" in
    systemd)    systemctl status "$SERVICE_NAME" --no-pager 2>&1 | head -20 ;;
    supervisor) supervisorctl status "$SERVICE_NAME" 2>&1 ;;
    *) warn "No service manager detected." ;;
  esac
  echo
}

# ============================================================================
# Web dashboard (sleek browser GUI with buttons, served on DASHBOARD_PORT)
# ============================================================================
write_dashboard_assets() {
  mkdir -p "$DASHBOARD_DIR"
  cat > "$DASHBOARD_DIR/dashboard.py" <<'PYEOF'
#!/usr/bin/env python3
"""Airlink Installation One Click Script - web dashboard (stdlib only)."""
import json, os, subprocess, time, uuid, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT_PATH = "__SCRIPT_PATH__"
LOG_DIR = "__LOG_DIR__"
PORT = __DASHBOARD_PORT__

os.makedirs(LOG_DIR, exist_ok=True)
RUNS = {}
LOCK = threading.Lock()

ACTIONS = {
    "install_panel":     [],
    "update_panel":      [],
    "add_node":          ["command"],
    "setup_cloudflared": ["token"],
    "admin_setup":       ["username", "email", "password"],
    "service_status":    [],
}

def start_run(action, params):
    run_id = uuid.uuid4().hex[:12]
    log_path = os.path.join(LOG_DIR, f"dash-{action}-{run_id}.log")
    args = ["bash", SCRIPT_PATH, "--action", action, "--headless"]
    for key in ACTIONS.get(action, []):
        args.append(params.get(key, ""))
    with LOCK:
        RUNS[run_id] = {"log": log_path, "done": False, "rc": None, "action": action}

    def _run():
        with open(log_path, "w") as f:
            proc = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT, text=True)
            rc = proc.wait()
        with LOCK:
            RUNS[run_id]["done"] = True
            RUNS[run_id]["rc"] = rc

    threading.Thread(target=_run, daemon=True).start()
    return run_id

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Airlink Installer</title>
<style>
:root{--bg:#0b0f19;--panel:#121828;--card:#161e33;--accent:#6d5bff;--accent2:#00d4b5;
--text:#e7e9f5;--muted:#8992ab;--good:#2fd47b;--bad:#ff5d6c;--warn:#ffb020;}
*{box-sizing:border-box}
body{margin:0;font-family:'Segoe UI',system-ui,-apple-system,sans-serif;background:
radial-gradient(1200px 600px at 10% -10%, #1b2340 0%, var(--bg) 60%);color:var(--text);min-height:100vh;}
header{padding:28px 24px 12px;text-align:center}
header h1{margin:0;font-size:26px;letter-spacing:.5px;background:linear-gradient(90deg,var(--accent),var(--accent2));
-webkit-background-clip:text;background-clip:text;color:transparent}
header p{margin:6px 0 0;color:var(--muted);font-size:13px}
.grid{max-width:960px;margin:20px auto;padding:0 20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}
.card{background:linear-gradient(180deg,var(--card),var(--panel));border:1px solid #232c46;border-radius:16px;
padding:20px;cursor:pointer;transition:transform .15s, box-shadow .15s;position:relative;overflow:hidden}
.card:hover{transform:translateY(-3px);box-shadow:0 10px 30px rgba(109,91,255,.25);border-color:var(--accent)}
.card .emoji{font-size:28px}
.card h3{margin:10px 0 4px;font-size:16px}
.card p{margin:0;color:var(--muted);font-size:12.5px;line-height:1.4}
.status{max-width:960px;margin:0 auto 40px;padding:0 20px;color:var(--muted);font-size:13px;text-align:center}
.overlay{position:fixed;inset:0;background:rgba(5,7,15,.72);backdrop-filter:blur(3px);display:none;
align-items:center;justify-content:center;padding:20px;z-index:10}
.modal{background:var(--panel);border:1px solid #2a3358;border-radius:16px;max-width:560px;width:100%;
padding:22px;max-height:82vh;overflow:auto}
.modal h2{margin-top:0;font-size:18px}
.modal input,.modal textarea{width:100%;background:#0d1220;border:1px solid #2a3358;border-radius:10px;
color:var(--text);padding:10px 12px;margin:6px 0 14px;font-size:14px}
.modal textarea{min-height:80px;font-family:monospace}
.row{display:flex;gap:10px;justify-content:flex-end}
button{background:linear-gradient(90deg,var(--accent),#8f7dff);border:none;color:white;padding:10px 18px;
border-radius:10px;font-weight:600;cursor:pointer;font-size:14px}
button.secondary{background:#232c46}
button:disabled{opacity:.5;cursor:not-allowed}
pre#log{background:#070a12;border-radius:10px;padding:12px;font-size:12px;max-height:280px;overflow:auto;
white-space:pre-wrap;border:1px solid #232c46}
.steps{margin:10px 0;font-size:13px}
.steps div{padding:3px 0;color:var(--muted)}
.steps .ok{color:var(--good)} .steps .fail{color:var(--bad)} .steps .step{color:var(--accent2)}
footer{text-align:center;color:#5b6padding: 20px 0 40px;color:var(--muted);font-size:12px;padding-bottom:30px}
</style></head>
<body>
<header>
<h1>&#128225; Airlink Control Panel</h1>
<p>Airlink Installation One Click Script &mdash; made by prime.dev1</p>
</header>
<div class="grid" id="grid"></div>
<div class="status" id="hint">Loading status...</div>

<div class="overlay" id="overlay">
  <div class="modal" id="modal"></div>
</div>

<footer>Served locally on port __DASHBOARD_PORT__ &middot; forward/allow this port to reach it remotely</footer>

<script>
const CARDS = [
  {id:"install_panel", emoji:"&#128230;", title:"Install Panel", desc:"Installs dependencies, clones the repo, builds, and registers the service.", fields:[]},
  {id:"update_panel", emoji:"&#128260;", title:"Update Panel", desc:"Pulls latest changes, reinstalls packages, rebuilds, restarts service.", fields:[]},
  {id:"add_node", emoji:"&#127760;", title:"Add Node", desc:"Paste the install command from the panel's Create Node screen.", fields:[{name:"command",label:"Node command (from panel)",type:"textarea"}]},
  {id:"setup_cloudflared", emoji:"&#9729;", title:"Connect Cloudflared", desc:"Installs cloudflared and connects your tunnel.", fields:[{name:"token",label:"Token or full 'cloudflared service install ...' command",type:"textarea"}]},
  {id:"admin_setup", emoji:"&#128100;", title:"Admin User Setup", desc:"Create or reset the panel's admin account.", fields:[{name:"username",label:"Username",type:"text"},{name:"email",label:"Email",type:"text"},{name:"password",label:"Password",type:"password"}]},
  {id:"service_status", emoji:"&#128202;", title:"Service Status", desc:"Show the current status of the panel service.", fields:[]},
];

const grid = document.getElementById('grid');
CARDS.forEach(c=>{
  const el = document.createElement('div');
  el.className='card';
  el.innerHTML = `<div class="emoji">${c.emoji}</div><h3>${c.title}</h3><p>${c.desc}</p>`;
  el.onclick=()=>openModal(c);
  grid.appendChild(el);
});

document.getElementById('hint').textContent = 'Pick an action above. Each one runs on this VPS and streams its progress below.';

function openModal(card){
  const overlay = document.getElementById('overlay');
  const modal = document.getElementById('modal');
  let fieldsHtml = card.fields.map(f=>{
    const tag = f.type==='textarea' ? 'textarea' : 'input';
    const typeAttr = f.type==='textarea' ? '' : `type="${f.type}"`;
    return `<label>${f.label}</label><${tag} id="f_${f.name}" ${typeAttr}></${tag}>`;
  }).join('');
  modal.innerHTML = `
    <h2>${card.emoji} ${card.title}</h2>
    <p style="color:var(--muted);font-size:13px">${card.desc}</p>
    ${fieldsHtml}
    <div class="steps" id="steps"></div>
    <pre id="log" style="display:none"></pre>
    <div class="row">
      <button class="secondary" onclick="closeModal()">Close</button>
      <button id="runBtn" onclick='runAction(${JSON.stringify(card)})'>Run</button>
    </div>`;
  overlay.style.display='flex';
}
function closeModal(){ document.getElementById('overlay').style.display='none'; }

async function runAction(card){
  const params = {};
  card.fields.forEach(f=>{ params[f.name] = document.getElementById('f_'+f.name).value; });
  document.getElementById('runBtn').disabled = true;
  document.getElementById('log').style.display='block';
  const res = await fetch('/api/action', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({action: card.id, params})});
  const data = await res.json();
  poll(data.run_id);
}

async function poll(runId){
  const logEl = document.getElementById('log');
  const stepsEl = document.getElementById('steps');
  const timer = setInterval(async ()=>{
    const res = await fetch('/api/logs/'+runId);
    const data = await res.json();
    logEl.textContent = data.log;
    logEl.scrollTop = logEl.scrollHeight;
    stepsEl.innerHTML = data.log.split('\\n').filter(l=>l.match(/\\[(STEP|OK|FAIL|WARN)\\]/)).map(l=>{
      const cls = l.includes('[OK]') ? 'ok' : l.includes('[FAIL]') ? 'fail' : 'step';
      return `<div class="${cls}">${l.replace(/\\x1b\\[[0-9;]*m/g,'')}</div>`;
    }).join('');
    if(data.done){
      clearInterval(timer);
      document.getElementById('runBtn').disabled = false;
      document.getElementById('runBtn').textContent = data.rc === 0 ? 'Done ✔' : 'Failed ✖';
    }
  }, 1000);
}
</script>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path == "":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/logs/"):
            run_id = self.path.split("/")[-1]
            with LOCK:
                run = RUNS.get(run_id)
            if not run:
                self._json({"error": "unknown run"}, 404); return
            content = ""
            if os.path.exists(run["log"]):
                with open(run["log"], errors="ignore") as f:
                    content = f.read()[-8000:]
            self._json({"log": content, "done": run["done"], "rc": run["rc"]})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/api/action":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            action = body.get("action")
            params = body.get("params", {})
            if action not in ACTIONS:
                self._json({"error": "unknown action"}, 400); return
            run_id = start_run(action, params)
            self._json({"run_id": run_id})
        else:
            self._json({"error": "not found"}, 404)

if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Airlink dashboard listening on 0.0.0.0:{PORT}")
    server.serve_forever()
PYEOF

  sed -i "s#__SCRIPT_PATH__#${SCRIPT_PATH}#g; s#__LOG_DIR__#${LOG_DIR}#g; s#__DASHBOARD_PORT__#${DASHBOARD_PORT}#g" "$DASHBOARD_DIR/dashboard.py"
}

launch_dashboard() {
  write_dashboard_assets
  open_firewall_port "$DASHBOARD_PORT"

  if pgrep -f "dashboard.py" &>/dev/null; then
    warn "Dashboard already appears to be running."
  else
    nohup python3 "$DASHBOARD_DIR/dashboard.py" >>"$LOG_DIR/dashboard.log" 2>&1 &
    disown
    sleep 1
  fi

  local ip; ip="$(get_public_ip)"
  echo
  ok "Web dashboard is live."
  echo -e "${C_GREEN}${C_BOLD}  -> Open: http://${ip}:${DASHBOARD_PORT}${C_RESET}"
  echo -e "${C_DIM}  If that doesn't load, forward/allow port ${DASHBOARD_PORT} in your VPS provider's"
  echo -e "  network panel (or Pterodactyl's port allocations if this is a Pterodactyl node), then retry.${C_RESET}"
  echo
}

stop_dashboard() {
  pkill -f "dashboard.py" 2>/dev/null && ok "Dashboard stopped." || warn "Dashboard wasn't running."
}

# ============================================================================
# Menu (whiptail "buttons" if available, plain fallback otherwise)
# ============================================================================
interactive_menu() {
  while true; do
    if command -v whiptail &>/dev/null; then
      CHOICE=$(whiptail --title "Airlink Installation One Click Script — by prime.dev1" \
        --menu "Choose an action:" 20 74 11 \
        "1" "Install Panel" \
        "2" "Update Panel" \
        "3" "Add Node (one-click)" \
        "4" "Connect Cloudflared" \
        "5" "Admin User Setup" \
        "6" "Service status" \
        "7" "Restart panel service" \
        "8" "Launch Web Dashboard (GUI)" \
        "9" "Stop Web Dashboard" \
        "10" "Show detected environment" \
        "0" "Exit" 3>&1 1>&2 2>&3) || { clear; break; }
    else
      banner
      echo " 1) Install Panel"
      echo " 2) Update Panel"
      echo " 3) Add Node (one-click)"
      echo " 4) Connect Cloudflared"
      echo " 5) Admin User Setup"
      echo " 6) Service status"
      echo " 7) Restart panel service"
      echo " 8) Launch Web Dashboard (GUI)"
      echo " 9) Stop Web Dashboard"
      echo "10) Show detected environment"
      echo " 0) Exit"
      read -r -p "Choose: " CHOICE
    fi

    clear
    banner
    case "$CHOICE" in
      1) action_install_panel ;;
      2) action_update_panel ;;
      3) action_add_node ;;
      4) action_setup_cloudflared ;;
      5) action_admin_setup ;;
      6) action_service_status ;;
      7) ensure_service_manager; service_action "$SERVICE_NAME" restart && ok "Restarted." ;;
      8) launch_dashboard ;;
      9) stop_dashboard ;;
      10) detect_pkg_manager >/dev/null; detect_service_manager >/dev/null
          echo "Package manager : $PKG_MANAGER"
          echo "Service manager : $SERVICE_MANAGER"
          echo "Containerized   : $(is_containerized && echo yes || echo no)"
          echo "Install dir     : $INSTALL_DIR"
          ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "Unknown option." ;;
    esac
    echo
    read -r -p "Press Enter to return to the menu..." _
    clear
  done
}

# ============================================================================
# Entry point
# ============================================================================
main() {
  require_root
  detect_pkg_manager >/dev/null
  detect_service_manager >/dev/null

  local mode="interactive"
  local action="" headless="false"
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action) action="$2"; mode="action"; shift 2 ;;
      --headless) headless="true"; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done

  if [[ "$mode" == "action" ]]; then
    case "$action" in
      install_panel)     action_install_panel ;;
      update_panel)      action_update_panel ;;
      add_node)          action_add_node "${args[@]:-}" ;;
      setup_cloudflared) action_setup_cloudflared "${args[@]:-}" ;;
      admin_setup)       action_admin_setup "${args[@]:-}" ;;
      service_status)    action_service_status ;;
      dashboard)         launch_dashboard ;;
      *) die "Unknown action: $action" ;;
    esac
    exit $?
  fi

  clear
  banner
  interactive_menu
}

main "$@"
