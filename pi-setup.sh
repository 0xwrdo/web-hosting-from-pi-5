#!/usr/bin/env bash
#
# pi-setup.sh — One-click Raspberry Pi site hosting setup
# Installs & configures: Nginx (multi-site via a dynamic map) + Cloudflare Tunnel
# Re-runnable: detects existing tunnels/config and lets you reuse or replace them.

set -euo pipefail

c_green()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
c_red()    { printf '\033[0;31m%s\033[0m\n' "$1"; }
step() { echo; c_green "==> $1"; }
warn() { c_yellow "  ! $1"; }
err()  { c_red "  ! $1"; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

ask() {
  # ask "prompt" DEFAULT -> echoes answer
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " ans
    echo "${ans:-$default}"
  else
    read -rp "$prompt: " ans
    echo "$ans"
  fi
}

confirm() {
  local ans
  read -rp "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- gather input ----------
step "Basic configuration"
RUN_USER="$(ask "Local user running these services" "$(whoami)")"
HOME_DIR="$(eval echo "~${RUN_USER}")"

echo
echo "You can host ONE site now, or set up the multi-site router so future"
echo "sites are just one line added to a config file (recommended even for"
echo "your first site, since it costs nothing extra now)."
SITES_ROOT="$(ask "Root folder for all sites" "${HOME_DIR}/sites")"

step "First site"
SITE_DOMAIN="$(ask "Domain for this site (e.g. raunakkushwaha.me)" "")"
[[ -n "$SITE_DOMAIN" ]] || { err "Domain is required."; exit 1; }
SITE_SLUG="$(ask "Folder name / slug for this site" "$(echo "$SITE_DOMAIN" | cut -d. -f1)")"
SITE_DIR="${SITES_ROOT}/${SITE_SLUG}"

step "Cloudflare Tunnel configuration"
TUNNEL_NAME="$(ask "Tunnel name to create/reuse" "pi-tunnel")"

# ---------- confirm ----------
echo
c_green "About to set up:"
echo "  User        : ${RUN_USER}"
echo "  Sites root  : ${SITES_ROOT}"
echo "  This site   : ${SITE_DOMAIN} -> ${SITE_DIR}"
echo "  Tunnel      : ${TUNNEL_NAME}"
confirm "Continue?" || { echo "Aborted."; exit 1; }

# ---------- system prep ----------
step "Installing base packages"
sudo apt update
sudo apt install -y curl nginx dnsutils

step "Creating folder structure"
mkdir -p "${SITES_ROOT}" "${SITE_DIR}"
chmod 755 "${HOME_DIR}"
chmod -R 755 "${SITES_ROOT}"

if [[ ! -f "${SITE_DIR}/index.html" ]]; then
  cat > "${SITE_DIR}/index.html" <<'EOF'
<!doctype html>
<html><head><title>Coming soon</title></head>
<body><h1>Upload your site files here.</h1></body></html>
EOF
  warn "Placeholder index.html created at ${SITE_DIR} — upload your real files via scp."
fi

# ---------- nginx: dynamic multi-site router ----------
step "Configuring Nginx (dynamic site map — add future sites with one line)"
SITE_MAP_FILE="/etc/nginx/site-map.conf"
if [[ ! -f "$SITE_MAP_FILE" ]]; then
  sudo touch "$SITE_MAP_FILE"
fi
if ! grep -q "^\s*${SITE_DOMAIN}\b" "$SITE_MAP_FILE" 2>/dev/null; then
  echo "    ${SITE_DOMAIN} ${SITE_DIR};" | sudo tee -a "$SITE_MAP_FILE" > /dev/null
else
  warn "${SITE_DOMAIN} already present in ${SITE_MAP_FILE}, leaving it as-is."
fi

sudo mkdir -p "${SITES_ROOT}/_default"
if [[ ! -f "${SITES_ROOT}/_default/index.html" ]]; then
  echo "<h1>404</h1>" | sudo tee "${SITES_ROOT}/_default/index.html" > /dev/null
fi

sudo tee /etc/nginx/sites-available/default > /dev/null <<EOF
map \$host \$site_root {
    default ${SITES_ROOT}/_default;
    include ${SITE_MAP_FILE};
}

limit_req_zone \$host zone=persite:10m rate=10r/s;

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root \$site_root;
    index index.html;
    server_name _;

    limit_req zone=persite burst=20 nodelay;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

step "Testing Nginx locally"
sleep 1
if curl -sf -o /dev/null http://localhost:80; then
  c_green "  Nginx OK (localhost:80 responded)"
else
  warn "  curl to localhost:80 did not return 200 — check 'sudo systemctl status nginx'"
fi

# ---------- cloudflared install ----------
step "Installing cloudflared"
if ! require_cmd cloudflared; then
  ARCH="$(dpkg --print-architecture)"
  curl -L --output /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
  sudo dpkg -i /tmp/cloudflared.deb
else
  echo "cloudflared already installed, skipping."
fi

# ---------- cloudflared login ----------
step "Cloudflare login"
if [[ ! -f "${HOME_DIR}/.cloudflared/cert.pem" ]]; then
  echo "A browser link will be printed — open it and select the zone for ${SITE_DOMAIN}."
  cloudflared tunnel login
else
  echo "Existing Cloudflare cert found at ~/.cloudflared/cert.pem"
  if ! confirm "Reuse it (No = re-authenticate, needed if it's for the wrong zone)?"; then
    cloudflared tunnel login
  fi
fi

# ---------- tunnel create / reuse, with credential-file sanity check ----------
step "Setting up tunnel '${TUNNEL_NAME}'"
EXISTING_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1}' || true)"

TUNNEL_ID=""
if [[ -n "$EXISTING_ID" ]]; then
  if [[ -f "${HOME_DIR}/.cloudflared/${EXISTING_ID}.json" ]]; then
    echo "Tunnel '${TUNNEL_NAME}' already exists and has valid credentials — reusing it."
    TUNNEL_ID="$EXISTING_ID"
  else
    warn "Tunnel '${TUNNEL_NAME}' exists in Cloudflare but its credentials file is missing on this Pi."
    warn "This happens after a reflash/reinstall. It must be deleted and recreated."
    if confirm "Delete and recreate '${TUNNEL_NAME}' now?"; then
      cloudflared tunnel delete "${TUNNEL_NAME}"
      cloudflared tunnel create "${TUNNEL_NAME}"
      TUNNEL_ID="$(cloudflared tunnel list | awk -v n="$TUNNEL_NAME" '$2==n {print $1}')"
    else
      err "Cannot continue without valid credentials. Re-run and choose a different tunnel name, or fix credentials manually."
      exit 1
    fi
  fi
else
  cloudflared tunnel create "${TUNNEL_NAME}"
  TUNNEL_ID="$(cloudflared tunnel list | awk -v n="$TUNNEL_NAME" '$2==n {print $1}')"
fi

echo "Using tunnel ID: ${TUNNEL_ID}"

# ---------- write config.yml ----------
step "Writing cloudflared config"
mkdir -p "${HOME_DIR}/.cloudflared"
CONFIG_PATH="${HOME_DIR}/.cloudflared/config.yml"

if [[ -f "$CONFIG_PATH" ]]; then
  warn "Existing config.yml found."
  cat "$CONFIG_PATH"
  if ! confirm "Overwrite it with a fresh default (adds ${SITE_DOMAIN} + keeps this as the only entry)?"; then
    warn "Leaving existing config.yml untouched. You'll need to manually add an ingress rule for ${SITE_DOMAIN}:"
    echo "  - hostname: ${SITE_DOMAIN}"
    echo "    service: http://localhost:80"
  else
    cat > "$CONFIG_PATH" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${HOME_DIR}/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${SITE_DOMAIN}
    service: http://localhost:80
  - service: http_status:404
EOF
  fi
else
  cat > "$CONFIG_PATH" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${HOME_DIR}/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${SITE_DOMAIN}
    service: http://localhost:80
  - service: http_status:404
EOF
fi

sudo mkdir -p /etc/cloudflared
sudo cp "$CONFIG_PATH" /etc/cloudflared/config.yml

# ---------- DNS routing ----------
step "Routing DNS for ${SITE_DOMAIN}"
if ! cloudflared tunnel route dns "${TUNNEL_NAME}" "${SITE_DOMAIN}" 2>/tmp/route_err.log; then
  warn "route dns failed — this usually means an existing DNS record (A/AAAA/CNAME) already"
  warn "occupies that hostname. Delete conflicting records for ${SITE_DOMAIN} in the Cloudflare"
  warn "dashboard (DNS -> Records), then re-run:"
  echo "    cloudflared tunnel route dns ${TUNNEL_NAME} ${SITE_DOMAIN}"
  cat /tmp/route_err.log
fi

# ---------- install as service ----------
step "Installing cloudflared as a systemd service"
if systemctl list-unit-files | grep -q '^cloudflared.service'; then
  echo "cloudflared service already installed, restarting with new config."
else
  sudo cloudflared service install
fi
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

sleep 2
step "Checking tunnel status"
if systemctl is-active --quiet cloudflared; then
  c_green "  cloudflared is running."
else
  err "  cloudflared failed to start. Check: sudo systemctl status cloudflared --no-pager"
  sudo systemctl status cloudflared --no-pager || true
fi

# ---------- summary ----------
step "Done"
cat <<EOF

Site root map file : ${SITE_MAP_FILE}
  (add future sites by appending a line like:
     newdomain.com /full/path/to/site;
   then: sudo nginx -s reload   — no restart needed)

This site          : ${SITE_DIR}
  Upload files with:
     scp -r ./your-site/* ${RUN_USER}@<pi-ip>:${SITE_DIR}/

Verify DNS         : dig ${SITE_DOMAIN} +short   (or: curl -s "https://cloudflare-dns.com/dns-query?name=${SITE_DOMAIN}&type=A" -H "accept: application/dns-json")
Verify site        : curl -IL https://${SITE_DOMAIN}

Backups            : nothing is backed up yet — set up a cron job for
                      ${SITES_ROOT} to another disk/off-Pi location.

Credentials        : back these up somewhere off this Pi so a reflash
                      doesn't force you to recreate the tunnel:
                        ~/.cloudflared/cert.pem
                        ~/.cloudflared/${TUNNEL_ID}.json

EOF
c_green "Setup finished."
