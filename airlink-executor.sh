#!/usr/bin/env bash
#
# Airlink Panel Executor
# -----------------------------------------------------------------------
# Installs, runs, updates and manages AirlinkLabs' Airlink Panel
# (https://github.com/AirlinkLabs/panel) on any VPS or container —
# auto-detects systemd / supervisor / pm2, falls back to a plain
# background process when none are available (codesandbox, Codespaces,
# bare containers, etc).
#
# made by prime.dev1
# -----------------------------------------------------------------------

set -uo pipefail

# ---------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------
PANEL_DIR=""
PANEL_PORT="3000"
INIT_SYSTEM=""
PKG_MANAGER=""
SUDO=""
IS_CONTAINER=false
SERVICE_NAME="airlink-panel"
REPO_URL="https://github.com/AirlinkLabs/panel.git"
CONFIG_FILE="${HOME}/.airlink-executor.conf"
NODE_MIN_MAJOR=18

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; RESET='\033[0m'

info() { echo -e "${BLUE}[*]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[X]${RESET} $*"; }

# ---------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------
load_config() { [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"; }

save_config() {
    cat > "$CONFIG_FILE" <<EOF
PANEL_DIR="${PANEL_DIR}"
PANEL_PORT="${PANEL_PORT}"
EOF
}

# ---------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------
require_root_or_sudo() {
    if [ "$EUID" -eq 0 ]; then
        SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        SUDO=""
        warn "Not root and no sudo available — system package installs may fail. Continuing with user-level steps only."
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk"
    elif command -v pacman >/dev/null 2>&1; then PKG_MANAGER="pacman"
    else PKG_MANAGER="unknown"
    fi
}

detect_environment() {
    IS_CONTAINER=false
    [ -f /.dockerenv ] && IS_CONTAINER=true
    if grep -qaE '(docker|containerd|lxc|kubepods)' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
    fi
    [ -n "${CODESPACES:-}" ] && IS_CONTAINER=true
    [ -n "${CODESANDBOX_SSE:-}" ] && IS_CONTAINER=true

    local pid1
    pid1=$(ps -p 1 -o comm= 2>/dev/null || echo "")
    if [ "$pid1" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v supervisorctl >/dev/null 2>&1; then
        INIT_SYSTEM="supervisor"
    elif command -v pm2 >/dev/null 2>&1; then
        INIT_SYSTEM="pm2"
    else
        INIT_SYSTEM="none"
    fi
    info "Environment: $([ "$IS_CONTAINER" = true ] && echo "container" || echo "bare-metal/VPS") | init: ${INIT_SYSTEM} | pkg mgr: ${PKG_MANAGER}"
}

ensure_process_manager() {
    if [ "$INIT_SYSTEM" = "none" ]; then
        info "No systemd or supervisor detected — installing pm2 as a universal process manager..."
        if npm install -g pm2 >/dev/null 2>&1; then
            INIT_SYSTEM="pm2"
            ok "pm2 installed."
        else
            warn "Could not install pm2 (no permission?). Falling back to a plain background process — it will not survive a reboot."
        fi
    fi
}

# ---------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------
check_node() {
    command -v node >/dev/null 2>&1 || return 1
    local major
    major=$(node -v | sed 's/^v//' | cut -d. -f1)
    [ "$major" -ge "$NODE_MIN_MAJOR" ]
}

install_node() {
    if check_node; then
        ok "Node.js $(node -v) already satisfies v${NODE_MIN_MAJOR}+."
        return
    fi
    info "Installing Node.js ${NODE_MIN_MAJOR}.x..."
    case "$PKG_MANAGER" in
        apt)
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN_MAJOR}.x" | $SUDO bash -
            $SUDO apt-get install -y nodejs
            ;;
        dnf)
            curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MIN_MAJOR}.x" | $SUDO bash -
            $SUDO dnf install -y nodejs
            ;;
        yum)
            curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MIN_MAJOR}.x" | $SUDO bash -
            $SUDO yum install -y nodejs
            ;;
        apk) $SUDO apk add --no-cache nodejs npm ;;
        pacman) $SUDO pacman -Sy --noconfirm nodejs npm ;;
        *) err "Unsupported package manager — install Node.js ${NODE_MIN_MAJOR}+ manually."; exit 1 ;;
    esac
}

install_dependencies() {
    info "Installing base packages (git, curl, unzip, openssl, build tools)..."
    case "$PKG_MANAGER" in
        apt)    $SUDO apt-get update -y && $SUDO apt-get install -y git curl unzip ca-certificates openssl build-essential ;;
        dnf)    $SUDO dnf install -y git curl unzip ca-certificates openssl gcc-c++ make ;;
        yum)    $SUDO yum install -y git curl unzip ca-certificates openssl gcc-c++ make ;;
        apk)    $SUDO apk add --no-cache git curl unzip ca-certificates openssl build-base ;;
        pacman) $SUDO pacman -Sy --noconfirm git curl unzip ca-certificates openssl base-devel ;;
        *) warn "Unknown package manager — make sure git, curl and build tools are installed manually." ;;
    esac
    install_node
    if ! command -v pnpm >/dev/null 2>&1; then
        info "Installing pnpm..."
        npm install -g pnpm
    fi
}

# ---------------------------------------------------------------------
# .env helpers
# ---------------------------------------------------------------------
set_env_var() {
    local key="$1" value="$2" file="${3:-${PANEL_DIR}/.env}"
    touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

configure_database() {
    echo ""
    echo "  1) Local SQLite (simplest — good for testing/small setups)"
    echo "  2) External MySQL"
    read -rp "Database backend [1-2]: " db_choice
    case "$db_choice" in
        2) configure_external_mysql ;;
        *) set_env_var "DATABASE_URL" "file:./storage/database.db" ;;
    esac
}

configure_external_mysql() {
    if [ -z "$PANEL_DIR" ]; then
        err "Panel directory not set yet — install the panel first."
        return 1
    fi
    read -rp "MySQL host [127.0.0.1]: " m_host; m_host=${m_host:-127.0.0.1}
    read -rp "MySQL port [3306]: " m_port; m_port=${m_port:-3306}
    read -rp "MySQL database name: " m_db
    read -rp "MySQL user: " m_user
    read -rsp "MySQL password: " m_pass; echo
    local db_url="mysql://${m_user}:${m_pass}@${m_host}:${m_port}/${m_db}"
    set_env_var "DATABASE_URL" "$db_url"
    ok "External MySQL configured in .env."
}

run_migrations() {
    info "Running database migrations..."
    if pnpm run migrate:deploy; then
        ok "Migrations applied."
        return 0
    fi
    warn "Migration failed — this is usually a database connectivity issue."
    read -rp "Configure an external MySQL database and retry? [y/N]: " retry
    if [[ "$retry" =~ ^[Yy]$ ]]; then
        configure_external_mysql
        if pnpm run migrate:deploy; then
            ok "Migrations applied after reconfiguring the database."
            return 0
        fi
        err "Migrations still failing. Check DATABASE_URL in ${PANEL_DIR}/.env and your database server logs."
        return 1
    fi
    err "Skipping — the panel will not run correctly until migrations succeed."
    return 1
}

# ---------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------
install_panel() {
    require_root_or_sudo
    detect_pkg_manager
    install_dependencies

    local default_dir="/var/www/panel"
    if [ "$EUID" -ne 0 ] && [ -z "$SUDO" ]; then
        default_dir="${HOME}/airlink-panel"
    fi
    read -rp "Install directory [${default_dir}]: " dir_in
    PANEL_DIR="${dir_in:-$default_dir}"

    if [ -d "$PANEL_DIR" ] && [ "$(ls -A "$PANEL_DIR" 2>/dev/null)" ]; then
        read -rp "${PANEL_DIR} already exists and is not empty. Remove and reinstall? [y/N]: " wipe
        if [[ "$wipe" =~ ^[Yy]$ ]]; then
            $SUDO rm -rf "$PANEL_DIR"
        else
            err "Aborting install."
            return 1
        fi
    fi

    $SUDO mkdir -p "$(dirname "$PANEL_DIR")"
    info "Cloning Airlink Panel into ${PANEL_DIR}..."
    git clone "$REPO_URL" "$PANEL_DIR" || { err "Clone failed."; return 1; }

    if [ "$EUID" -eq 0 ] && id -u www-data >/dev/null 2>&1; then
        chown -R www-data:www-data "$PANEL_DIR"
    fi
    chmod -R 755 "$PANEL_DIR" 2>/dev/null

    cd "$PANEL_DIR" || return 1
    info "Installing dependencies with pnpm (this can take a few minutes)..."
    pnpm install || { err "pnpm install failed."; return 1; }

    if [ -f example.env ]; then
        cp example.env .env
    elif [ -f .env.example ]; then
        cp .env.example .env
    else
        touch .env
    fi

    read -rp "Port for the panel [3000]: " port_in
    PANEL_PORT="${port_in:-3000}"
    read -rp "Public URL (e.g. https://panel.example.com or http://SERVER_IP:${PANEL_PORT}): " url_in
    local session_secret
    session_secret=$(openssl rand -hex 32 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c64)

    set_env_var "PORT" "$PANEL_PORT"
    set_env_var "URL" "${url_in:-http://localhost:${PANEL_PORT}}"
    set_env_var "SESSION_SECRET" "$session_secret"
    configure_database

    run_migrations || return 1

    info "Building panel (TypeScript + CSS)..."
    pnpm run build || { err "Build failed."; return 1; }

    save_config
    ok "Airlink Panel installed at ${PANEL_DIR}."
    echo "Next: 'Run Panel (Production)' to start it, then 'Create Admin User'."
}

# ---------------------------------------------------------------------
# Service management (systemd / supervisor / pm2 / plain background)
# ---------------------------------------------------------------------
setup_systemd_service() {
    local pnpm_path; pnpm_path=$(command -v pnpm)
    $SUDO tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Airlink Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${PANEL_DIR}
ExecStart=${pnpm_path} run start
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
}

setup_supervisor_service() {
    local pnpm_path conf_dir
    pnpm_path=$(command -v pnpm)
    conf_dir="/etc/supervisor/conf.d"
    [ -d "$conf_dir" ] || conf_dir="/etc/supervisord.d"
    $SUDO mkdir -p "$conf_dir"
    $SUDO tee "${conf_dir}/${SERVICE_NAME}.conf" >/dev/null <<EOF
[program:${SERVICE_NAME}]
directory=${PANEL_DIR}
command=${pnpm_path} run start
autostart=true
autorestart=true
stdout_logfile=/var/log/${SERVICE_NAME}.out.log
stderr_logfile=/var/log/${SERVICE_NAME}.err.log
environment=NODE_ENV="production"
EOF
    $SUDO supervisorctl reread >/dev/null 2>&1
    $SUDO supervisorctl update >/dev/null 2>&1
}

setup_pm2_service() {
    cd "$PANEL_DIR" || return 1
    pm2 delete "$SERVICE_NAME" >/dev/null 2>&1
    pm2 start "pnpm" --name "$SERVICE_NAME" --cwd "$PANEL_DIR" -- run start
    pm2 save
    pm2 startup >/dev/null 2>&1 || true
}

setup_nohup_service() {
    cd "$PANEL_DIR" || return 1
    nohup pnpm run start > "${PANEL_DIR}/panel.log" 2>&1 &
    echo $! > "${PANEL_DIR}/.airlink.pid"
    disown
    ok "Started in background (PID $(cat "${PANEL_DIR}/.airlink.pid")). Logs: ${PANEL_DIR}/panel.log"
}

service_status() {
    case "$INIT_SYSTEM" in
        systemd)    $SUDO systemctl status "$SERVICE_NAME" --no-pager ;;
        supervisor) $SUDO supervisorctl status "$SERVICE_NAME" ;;
        pm2)        pm2 status "$SERVICE_NAME" ;;
        none)
            if [ -f "${PANEL_DIR}/.airlink.pid" ] && kill -0 "$(cat "${PANEL_DIR}/.airlink.pid")" 2>/dev/null; then
                ok "Running (PID $(cat "${PANEL_DIR}/.airlink.pid"))"
            else
                warn "Not running."
            fi
            ;;
    esac
}

service_stop() {
    case "$INIT_SYSTEM" in
        systemd)    $SUDO systemctl stop "$SERVICE_NAME" ;;
        supervisor) $SUDO supervisorctl stop "$SERVICE_NAME" ;;
        pm2)        pm2 stop "$SERVICE_NAME" ;;
        none)
            if [ -f "${PANEL_DIR}/.airlink.pid" ]; then
                kill "$(cat "${PANEL_DIR}/.airlink.pid")" 2>/dev/null
                rm -f "${PANEL_DIR}/.airlink.pid"
            fi
            ;;
    esac
    ok "Stop signal sent."
}

service_restart() {
    case "$INIT_SYSTEM" in
        systemd)    $SUDO systemctl restart "$SERVICE_NAME" ;;
        supervisor) $SUDO supervisorctl restart "$SERVICE_NAME" ;;
        pm2)        pm2 restart "$SERVICE_NAME" ;;
        none)       service_stop; setup_nohup_service ;;
    esac
}

service_logs() {
    case "$INIT_SYSTEM" in
        systemd)    $SUDO journalctl -u "$SERVICE_NAME" -f ;;
        supervisor) $SUDO tail -f "/var/log/${SERVICE_NAME}.out.log" ;;
        pm2)        pm2 logs "$SERVICE_NAME" ;;
        none)       tail -f "${PANEL_DIR}/panel.log" ;;
    esac
}

# ---------------------------------------------------------------------
# Run / Update
# ---------------------------------------------------------------------
run_panel() {
    local mode="$1"
    if [ -z "$PANEL_DIR" ] || [ ! -d "$PANEL_DIR" ]; then
        err "Panel not found. Run 'Install Panel' first."
        return 1
    fi
    cd "$PANEL_DIR" || return 1

    if [ "$mode" = "dev" ]; then
        if grep -q '"dev"[[:space:]]*:' package.json 2>/dev/null; then
            info "Starting panel in development mode (Ctrl+C to stop)..."
            NODE_ENV=development pnpm run dev
        else
            warn "No 'dev' script in package.json — falling back to 'start' with NODE_ENV=development."
            NODE_ENV=development pnpm run start
        fi
        return
    fi

    info "Building panel..."
    pnpm run build || { err "Build failed."; return 1; }

    ensure_process_manager
    case "$INIT_SYSTEM" in
        systemd)
            setup_systemd_service
            $SUDO systemctl restart "$SERVICE_NAME"
            ok "Running via systemd. Tail logs: journalctl -u ${SERVICE_NAME} -f"
            ;;
        supervisor)
            setup_supervisor_service
            $SUDO supervisorctl restart "$SERVICE_NAME"
            ok "Running via supervisor."
            ;;
        pm2)
            setup_pm2_service
            ok "Running via pm2. Check status: pm2 status"
            ;;
        none)
            setup_nohup_service
            ;;
    esac
}

update_panel() {
    if [ -z "$PANEL_DIR" ] || [ ! -d "$PANEL_DIR" ]; then
        err "Panel not installed yet."
        return 1
    fi
    cd "$PANEL_DIR" || return 1
    info "Pulling latest changes..."
    git pull || { err "git pull failed — check for local modifications."; return 1; }
    pnpm install
    run_migrations
    info "Rebuilding..."
    pnpm run build
    info "Restarting service..."
    service_restart
    ok "Panel updated."
}

# ---------------------------------------------------------------------
# Cloudflared
# ---------------------------------------------------------------------
install_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then return 0; fi
    info "Installing cloudflared..."
    local arch cf_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) cf_arch="amd64" ;;
        aarch64|arm64) cf_arch="arm64" ;;
        armv7l) cf_arch="arm" ;;
        *) err "Unsupported architecture: $arch"; return 1 ;;
    esac
    curl -fsSL -o /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
        || { err "cloudflared download failed."; return 1; }
    chmod +x /tmp/cloudflared
    $SUDO mv /tmp/cloudflared /usr/local/bin/cloudflared
}

connect_cloudflared() {
    install_cloudflared || return 1
    echo ""
    echo "  1) Quick tunnel (instant temporary URL, no account needed)"
    echo "  2) Named tunnel (token from your Cloudflare Zero Trust dashboard)"
    read -rp "Choose [1-2]: " cf_choice
    case "$cf_choice" in
        2)
            read -rp "Paste your Cloudflare tunnel token: " cf_token
            if [ "$INIT_SYSTEM" = "systemd" ]; then
                $SUDO cloudflared service install "$cf_token"
                $SUDO systemctl restart cloudflared
                ok "cloudflared installed as a systemd service."
            else
                nohup cloudflared tunnel run --token "$cf_token" > "${HOME}/cloudflared.log" 2>&1 &
                disown
                ok "cloudflared running in background. Logs: ${HOME}/cloudflared.log"
            fi
            ;;
        *)
            info "Starting a quick tunnel to localhost:${PANEL_PORT}. Your temporary URL will appear below (Ctrl+C to stop)."
            cloudflared tunnel --url "http://localhost:${PANEL_PORT}"
            ;;
    esac
}

# ---------------------------------------------------------------------
# Admin user
# ---------------------------------------------------------------------
create_admin_user() {
    if [ -z "$PANEL_DIR" ] || [ ! -d "$PANEL_DIR" ]; then
        err "Panel not installed yet."
        return 1
    fi
    cd "$PANEL_DIR" || return 1
    local candidate
    candidate=$(grep -ioE '"[a-z:_-]*admin[a-z:_-]*"[[:space:]]*:' package.json 2>/dev/null | head -n1 | tr -d '":' | xargs)
    if [ -n "$candidate" ]; then
        info "Found script '${candidate}' in package.json — running it (follow its prompts):"
        pnpm run "$candidate"
    else
        info "Airlink has no CLI command for this — the first account registered through the web UI is automatically made admin."
        echo "Open http://localhost:${PANEL_PORT} (or your configured domain) and register that first account."
    fi
}

# ---------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------
open_firewall_port() {
    local port="${PANEL_PORT}"
    if command -v ufw >/dev/null 2>&1; then
        $SUDO ufw allow "${port}/tcp"
        ok "Allowed port ${port} through ufw."
    elif command -v firewall-cmd >/dev/null 2>&1; then
        $SUDO firewall-cmd --add-port="${port}/tcp" --permanent
        $SUDO firewall-cmd --reload
        ok "Allowed port ${port} through firewalld."
    else
        warn "No supported firewall tool found (ufw/firewalld) — open port ${port} manually if needed."
    fi
}

# ---------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}========================================${RESET}"
    echo -e "${CYAN}${BOLD}        AIRLINK PANEL EXECUTOR${RESET}"
    echo -e "${MAGENTA}            made by prime.dev1${RESET}"
    echo -e "${CYAN}${BOLD}========================================${RESET}"
    echo -e " Dir: ${PANEL_DIR:-not set}   Init: ${INIT_SYSTEM}   Port: ${PANEL_PORT}"
    echo ""
}

main_menu() {
    while true; do
        print_banner
        echo "  1) Install Panel"
        echo "  2) Run Panel (Production)"
        echo "  3) Run Panel (Development)"
        echo "  4) Update Panel"
        echo "  5) Connect Cloudflared"
        echo "  6) Create Admin User"
        echo "  7) Configure External MySQL"
        echo "  8) Service Status"
        echo "  9) Restart Service"
        echo " 10) Stop Service"
        echo " 11) View Logs"
        echo " 12) Open Firewall Port"
        echo "  0) Exit"
        echo ""
        read -rp "Select an option: " choice
        echo ""
        case "$choice" in
            1) install_panel ;;
            2) run_panel prod ;;
            3) run_panel dev ;;
            4) update_panel ;;
            5) connect_cloudflared ;;
            6) create_admin_user ;;
            7) configure_external_mysql ;;
            8) service_status ;;
            9) service_restart ;;
            10) service_stop ;;
            11) service_logs ;;
            12) open_firewall_port ;;
            0) echo "Bye."; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
        echo ""
        read -rp "Press Enter to return to the menu..." _
    done
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------
main() {
    require_root_or_sudo
    detect_pkg_manager
    detect_environment
    load_config
    main_menu
}

main "$@"
