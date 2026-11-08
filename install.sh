#!/usr/bin/env bash
#
# MrSkyEshan - Pterodactyl All-in-One Installer
# Menu:
#   1) Install Pterodactyl Panel
#   2) Install Pterodactyl Wings (Node)
#   3) Cloudflare (install cloudflared / setup tunnel)
#   5) About Me
#
set -uo pipefail

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*"; }

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  err "Please run as root:  sudo bash install.sh"
  exit 1
fi

# ---------- Detect distro ----------
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VER="${VERSION_ID:-}"
    DISTRO_NAME="${PRETTY_NAME:-$ID}"
  else
    DISTRO_ID="unknown"; DISTRO_VER=""; DISTRO_NAME="unknown"
  fi
}

# ---------- Common helpers ----------
require_cmd() { command -v "$1" >/dev/null 2>&1; }

install_base_deps() {
  info "Installing base dependencies (curl, wget, git, openssl, ca-certificates)..."
  if [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget git openssl ca-certificates gnupg lsb-release >/dev/null 2>&1
  elif [[ "$DISTRO_ID" == "centos" || "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "almalinux" || "$DISTRO_ID" == "rocky" ]]; then
    dnf install -y curl wget git openssl ca-certificates >/dev/null 2>&1 || \
    yum install -y curl wget git openssl ca-certificates >/dev/null 2>&1
  else
    warn "Unknown distro; please ensure curl/wget/git are installed."
  fi
}

# ---------- Prompt helpers (non-empty, FQDN format) ----------
ask_required() {
  local prompt="$1" var
  while true; do
    read -r -p "$prompt" var
    if [[ -n "$var" ]]; then echo "$var"; return 0; fi
    err "This field is required."
  done
}

ask_fqdn() {
  local prompt="$1" var
  while true; do
    read -r -p "$prompt" var
    if [[ "$var" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      echo "$var"; return 0
    fi
    err "Not a valid FQDN (e.g. panel.example.com). Try again."
  done
}

ask_yes_no() {
  local prompt="$1" ans
  while true; do
    read -r -p "$prompt [y/n]: " ans
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)  return 1 ;;
      *) err "Answer y or n." ;;
    esac
  done
}

# =====================================================================
# 1) INSTALL PANEL
# =====================================================================
install_panel() {
  clear
  echo -e "${BOLD}=== Pterodactyl Panel Installation ===${NC}\n"

  local PANEL_FQDN
  PANEL_FQDN=$(ask_fqdn "Enter Panel FQDN (e.g. panel.example.com): ")

  local ADMIN_EMAIL ADMIN_USER ADMIN_PASS ADMIN_FNAME ADMIN_LNAME
  read -r -p "Admin email: " ADMIN_EMAIL
  [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@${PANEL_FQDN}"

  ADMIN_USER=$(ask_required "Admin username: ")
  ADMIN_FNAME=$(ask_required "Admin first name: ")
  ADMIN_LNAME=$(ask_required "Admin last name: ")

  # Generate a password automatically
  ADMIN_PASS="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-16)"

  echo ""
  info "Firewall: allowing HTTP (80) and HTTPS (443)..."
  if require_cmd ufw; then
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  elif require_cmd firewall-cmd; then
    firewall-cmd --permanent --add-service=http  >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    warn "No ufw/firewalld detected; skipping firewall rules."
  fi

  echo ""
  warn "Telemetry / anonymous data notice:"
  echo "  This installer sends NO telemetry data."
  echo "  Pterodactyl itself has no telemetry; no data leaves this server."
  echo ""
  if ! ask_yes_no "Continue with Panel installation?"; then
    warn "Cancelled."; return 1
  fi

  info "Installing base dependencies..."
  install_base_deps

  # Use the official community installer in non-interactive mode.
  # It supports PANEL + automatic Let's Encrypt SSL via env vars.
  info "Downloading official pterodactyl-installer..."
  local INSTALLER_DIR="/root/pterodactyl-installer"
  rm -rf "$INSTALLER_DIR"
  if ! git clone -q https://github.com/pterodactyl-installer/pterodactyl-installer.git "$INSTALLER_DIR"; then
    err "Failed to download pterodactyl-installer. Check internet/DNS."
    return 1
  fi
  cd "$INSTALLER_DIR" || return 1

  # Non-interactive env — see installer docs for full list
  export FQDN="$PANEL_FQDN"
  export SSL_CERTBOT_EMAIL="$ADMIN_EMAIL"
  export SSL_CERTBOT_AGREE="true"
  export ASSUME_SSL="true"             # use Let's Encrypt
  export CONFIGURE_LETSENCRYPT="true"
  export CONFIGURE_FIREWALL="true"
  export CONFIGURE_DB="true"
  export CREATE_DB_USER="true"
  export DB_NAME="panel"
  export DB_USER="pterodactyl"
  export DB_PASSWORD="$(openssl rand -hex 16)"
  export INSTALL_PANEL="true"
  export INSTALL_WINGS="false"

  info "Running Panel installer (this can take several minutes)..."
  if bash install.sh --install-panel 2>&1 | tee /tmp/panel-install.log; then
    ok "Panel core installed."
  else
    err "Panel installer reported an error. See /tmp/panel-install.log"
    err "Please check the provided info again (FQDN, email, DNS, ports)."
    return 1
  fi

  # Create admin user via artisan (installer usually prompts; we do it non-interactively)
  info "Creating admin user..."
  cd /var/www/pterodactyl || { err "Panel directory missing."; return 1; }

  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$ADMIN_FNAME" \
    --name-last="$ADMIN_LNAME" \
    --password="$ADMIN_PASS" \
    --admin=1 >/dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    err "Could not create admin user automatically."
    err "Run manually: cd /var/www/pterodactyl && php artisan p:user:make"
  fi

  # Clear caches
  php artisan optimize:clear >/dev/null 2>&1 || true

  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}  PANEL INSTALLED SUCCESSFULLY${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo -e " Panel URL : ${BOLD}https://${PANEL_FQDN}${NC}"
  echo -e " Admin user: ${BOLD}${ADMIN_USER}${NC}"
  echo -e " Admin pass: ${BOLD}${ADMIN_PASS}${NC}"
  echo -e " Admin mail: ${BOLD}${ADMIN_EMAIL}${NC}"
  echo -e " Name      : ${ADMIN_FNAME} ${ADMIN_LNAME}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  read -r -p "Press Enter to return to menu..."
}

# =====================================================================
# 2) INSTALL WINGS (NODE)
# =====================================================================
install_wings() {
  clear
  echo -e "${BOLD}=== Pterodactyl Wings (Node) Installation ===${NC}\n"
  echo -e "${YELLOW}NOTE:${NC} This menu does NOT support auto-configuration."
  echo "      Wings requires a node configuration created in the Panel"
  echo "      (Admin -> Nodes -> Create Node) before it can connect."
  echo ""
  echo "Manual steps you will need:"
  echo "  1. In Panel: Admin -> Nodes -> Create Node, get the config."
  echo "  2. Save it to /etc/pterodactyl/config.yml on this node."
  echo "  3. Start Wings:  systemctl start wings"
  echo ""

  if ! ask_yes_no "Continue with Wings installation?"; then
    warn "Cancelled."; return 1
  fi

  info "Installing base dependencies..."
  install_base_deps

  info "Downloading pterodactyl-installer..."
  local INSTALLER_DIR="/root/pterodactyl-installer"
  rm -rf "$INSTALLER_DIR"
  if ! git clone -q https://github.com/pterodactyl-installer/pterodactyl-installer.git "$INSTALLER_DIR"; then
    err "Failed to download installer."
    return 1
  fi
  cd "$INSTALLER_DIR" || return 1

  export INSTALL_PANEL="false"
  export INSTALL_WINGS="true"
  export CONFIGURE_FIREWALL="true"

  info "Running Wings installer..."
  if bash install.sh --install-wings 2>&1 | tee /tmp/wings-install.log; then
    ok "Wings installed."
  else
    err "Wings installer reported an error. See /tmp/wings-install.log"
    return 1
  fi

  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}  WINGS INSTALLED${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo " Next steps:"
  echo "  - Copy the node config from Panel into /etc/pterodactyl/config.yml"
  echo "  - systemctl enable --now wings"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  read -r -p "Press Enter to return to menu..."
}

# =====================================================================
# 3) CLOUDFLARE
# =====================================================================
install_cloudflared() {
  info "Installing cloudflared..."

  if require_cmd cloudflared; then
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -n1)"
    return 0
  fi

  case "$DISTRO_ID" in
    ubuntu|debian)
      mkdir -p /usr/share/keyrings
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
        > /etc/apt/sources.list.d/cloudflared.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y cloudflared >/dev/null 2>&1
      ;;
    centos|rhel|almalinux|rocky)
      curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo \
        -o /etc/yum.repos.d/cloudflared.repo
      dnf install -y cloudflared >/dev/null 2>&1 || yum install -y cloudflared >/dev/null 2>&1
      ;;
    *)
      warn "Unknown distro, trying generic .deb/.rpm download..."
      local ARCH
      ARCH=$(uname -m)
      [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
      [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
      local URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
      curl -fsSL "$URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
      ;;
  esac

  if require_cmd cloudflared; then
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -n1)"
  else
    err "cloudflared installation failed."
    return 1
  fi
}

setup_cloudflare_tunnel() {
  info "Setting up Cloudflare Tunnel..."

  if ! require_cmd cloudflared; then
    err "cloudflared is not installed. Please run option 1 first."
    return 1
  fi

  local TOKEN
  while true; do
    read -r -s -p "Please Input Ur tunnel Token: " TOKEN
    echo ""
    [[ -n "$TOKEN" ]] && break
    err "Token cannot be empty."
  done

  info "Installing tunnel as system service with provided token..."
  if cloudflared service install "$TOKEN" >/dev/null 2>&1; then
    ok "Tunnel service installed."
  else
    # Fallback: older syntax
    warn "Falling back to legacy tunnel install syntax..."
    if cloudflared service install <<< "$TOKEN" >/dev/null 2>&1; then
      ok "Tunnel service installed (legacy)."
    else
      err "Failed to install tunnel service."
      return 1
    fi
  fi

  if systemctl is-active --quiet cloudflared; then
    ok "Tunnel is successfully enabled and running."
  else
    systemctl enable --now cloudflared >/dev/null 2>&1 || true
    sleep 2
    if systemctl is-active --quiet cloudflared; then
      ok "Tunnel is successfully enabled and running."
    else
      err "Tunnel service did not start. Check: journalctl -u cloudflared -e"
      return 1
    fi
  fi

  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}  CLOUDFLARE TUNNEL ENABLED${NC}"
  echo -e "${GREEN}========================================${NC}"
  read -r -p "Press Enter to return to Cloudflare menu..."
}

cloudflare_menu() {
  while true; do
    clear
    echo -e "${BOLD}=== Cloudflare Menu ===${NC}"
    echo "  1) Install cloudflared on my machine"
    echo "  2) Setup Cloudflare Tunnel (input tunnel token)"
    echo "  0) Back to main menu"
    echo ""
    read -r -p "Select: " choice
    case "$choice" in
      1) install_cloudflared; read -r -p "Press Enter..." _ ;;
      2) setup_cloudflare_tunnel ;;
      0) return ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

# =====================================================================
# 5) ABOUT ME
# =====================================================================
about_me() {
  clear
  echo -e "${BOLD}About Me${NC}"
  echo "----------------------------------------"
  echo " MrSkyEshan"
  echo " Pterodactyl All-in-One Installer"
  echo ""
  echo " Features:"
  echo "   1) Install Pterodactyl Panel (auto admin user + SSL)"
  echo "   2) Install Pterodactyl Wings (Node)"
  echo "   3) Cloudflare (install cloudflared / setup tunnel)"
  echo "   5) About Me (this screen)"
  echo ""
  echo " Notes:"
  echo "   - Run as root."
  echo "   - No telemetry is collected by this script."
  echo "   - Review the code before running on production."
  echo "----------------------------------------"
  read -r -p "Press Enter to return..."
}

# =====================================================================
# MAIN MENU
# =====================================================================
main_menu() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "=========================================="
    echo "   MrSkyEshan - Pterodactyl Installer"
    echo "=========================================="
    echo -e "${NC}"
    echo "  1) Install Pterodactyl Panel"
    echo "  2) Install Pterodactyl Wings (Node)"
    echo "  3) Cloudflare (install / tunnel)"
    echo "  5) About Me"
    echo "  0) Exit"
    echo ""
    read -r -p "Select an option: " choice
    case "$choice" in
      1) install_panel ;;
      2) install_wings ;;
      3) cloudflare_menu ;;
      5) about_me ;;
      0) echo "Bye."; exit 0 ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

# ---------- Entry ----------
detect_distro
main_menu
