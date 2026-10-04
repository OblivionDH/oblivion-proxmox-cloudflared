#!/usr/bin/env bash
# Installs cloudflared on a Proxmox (Debian) host and connects it to a Cloudflare Tunnel.
# Usage:
#   ./install.sh                      # reads token from .env or prompts for it
#   CF_TUNNEL_TOKEN=xxx ./install.sh  # token from environment
#   ./install.sh --force              # remove an existing connector on this host first
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

log()  { echo -e "\e[32m[+]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*"; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (Proxmox shell is root by default)."

# --- 1. Load token -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

if [[ -z "${CF_TUNNEL_TOKEN:-}" ]]; then
  read -rsp "Paste your Cloudflare Tunnel token: " CF_TUNNEL_TOKEN; echo
fi
[[ -n "$CF_TUNNEL_TOKEN" ]] || die "No token provided."
# Accept the full 'cloudflared service install <token>' line if pasted by mistake
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN##* }"

# --- 2. Guard against duplicate connectors -------------------------------------
if systemctl list-unit-files | grep -q '^cloudflared\.service'; then
  if [[ $FORCE -eq 1 ]]; then
    warn "Existing cloudflared service found - removing it (--force)."
    cloudflared service uninstall || true
    systemctl daemon-reload
  else
    die "cloudflared service already installed. Re-run with --force to replace it."
  fi
fi
if pgrep -x cloudflared >/dev/null; then
  warn "Stray cloudflared process found - stopping it to avoid duplicate connectors."
  pkill -x cloudflared || true
fi

# --- 3. Install cloudflared from Cloudflare's apt repo -------------------------
log "Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates >/dev/null

log "Adding Cloudflare apt repository..."
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg -o /usr/share/keyrings/cloudflare-public-v2.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  > /etc/apt/sources.list.d/cloudflared.list

log "Installing cloudflared..."
apt-get update -qq
apt-get install -y -qq cloudflared >/dev/null
log "Installed: $(cloudflared --version | head -n1)"

# --- 4. Register as a systemd service with the tunnel token ---------------------
log "Registering cloudflared service..."
cloudflared service install "$CF_TUNNEL_TOKEN"
systemctl enable --now cloudflared >/dev/null 2>&1 || true

# --- 5. Verify -----------------------------------------------------------------
sleep 5
if systemctl is-active --quiet cloudflared; then
  log "cloudflared is running. Check the dashboard - the tunnel should show 'Healthy'."
else
  journalctl -u cloudflared -n 30 --no-pager
  die "cloudflared failed to start (logs above)."
fi
