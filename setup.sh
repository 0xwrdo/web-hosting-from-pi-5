#!/usr/bin/env bash
#
# setup.sh — Raspberry Pi 5 self-hosting setup
# Sets up: portfolio (Nginx), private drive (Filestash + OnlyOffice), movies (Jellyfin)
# All three exposed via a single Cloudflare Tunnel with multiple ingress rules.
#
# Run on a fresh Raspberry Pi OS Lite (Bookworm) install. Re-runnable, but not
# fully idempotent for the Docker containers (it will error if they already exist —
# remove them first with `docker rm -f <name>` if you want to redo a step).

set -euo pipefail

# ---------- helpers ----------
c_green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
c_red() { printf '\033[0;31m%s\033[0m\n' "$1"; }
step() { echo; c_green "==> $1"; }
warn() { c_yellow "  ! $1"; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

zone_of() {
  # last two labels of a domain, e.g. drive.example.tech -> example.tech
  echo "$1" | awk -F. '{ n=NF; print $(n-1)"."$n }'
}

# ---------- gather input ----------
step "Configuration"
read -rp "Portfolio domain (e.g. raunakkushwaha.me): " PORTFOLIO_DOMAIN
read -rp "Drive domain (e.g. drive.raunakkushwaha.tech): " DRIVE_DOMAIN
read -rp "Movies domain (e.g. movies.raunakkushwaha.tech): " MOVIES_DOMAIN
read -rp "Cloudflare tunnel name to create/use (e.g. raunak-pi): " TUNNEL_NAME
read -rp "Local user running these services [default: $(whoami)]: " RUN_USER
RUN_USER="${RUN_USER:-$(whoami)}"
HOME_DIR="$(eval echo "~${RUN_USER}")"

PORTFOLIO_ROOT="${HOME_DIR}/123"
SERVER_ROOT="${HOME_DIR}/1234"
DRIVE_DIR="${SERVER_ROOT}/drive"
FILESTASH_STATE_DIR="${SERVER_ROOT}/filestash-state"
MOVIES_DIR="${SERVER_ROOT}/movies"

echo
c_green "This will set up:"
echo "  Portfolio -> ${PORTFOLIO_DOMAIN}  (Nginx, port 80, root ${PORTFOLIO_ROOT})"
echo "  Drive     -> ${DRIVE_DOMAIN}      (Filestash, port 8080; OnlyOffice, port 8081)"
echo "  Movies    -> ${MOVIES_DOMAIN}     (Jellyfin, port 8096)"
echo "  Tunnel    -> ${TUNNEL_NAME}"
read -rp "Continue? [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ---------- system prep ----------
step "Installing base packages"
sudo apt update
sudo apt install -y curl nginx

step "Creating folder structure"
mkdir -p "${PORTFOLIO_ROOT}" "${DRIVE_DIR}" "${FILESTASH_STATE_DIR}" "${MOVIES_DIR}"

# ---------- cloudflared ----------
step "Installing cloudflared"
if ! require_cmd cloudflared; then
  curl -L --output /tmp/cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
  sudo dpkg -i /tmp/cloudflared.deb
else
  echo "cloudflared already installed, skipping."
fi

step "Creating tunnel (or reusing an existing one with this name)"
if ! cloudflared tunnel list 2>/dev/null | grep -q " ${TUNNEL_NAME} "; then
  cloudflared tunnel login
  cloudflared tunnel create "${TUNNEL_NAME}"
else
  echo "Tunnel '${TUNNEL_NAME}' already exists, skipping creation."
fi

TUNNEL_ID="$(cloudflared tunnel list | awk -v name="${TUNNEL_NAME}" '$2==name {print $1}')"
CRED_FILE="${HOME_DIR}/.cloudflared/${TUNNEL_ID}.json"

step "Writing cloudflared config"
mkdir -p "${HOME_DIR}/.cloudflared"
cat > "${HOME_DIR}/.cloudflared/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${PORTFOLIO_DOMAIN}
    service: http://localhost:80
  - hostname: ${DRIVE_DOMAIN}
    service: http://localhost:8080
  - hostname: ${MOVIES_DOMAIN}
    service: http://localhost:8096
  - service: http_status:404
EOF

sudo mkdir -p /etc/cloudflared
sudo cp "${HOME_DIR}/.cloudflared/config.yml" /etc/cloudflared/config.yml

step "Routing DNS for each hostname"
# cloudflared's cert.pem is zone-scoped: `tunnel login` authorizes it for whichever
# zone you pick in the browser. We re-run login once per distinct zone so each
# `route dns` call lands in the right zone instead of silently creating a bad record.
declare -A SEEN_ZONES
for HOSTNAME in "${PORTFOLIO_DOMAIN}" "${DRIVE_DOMAIN}" "${MOVIES_DOMAIN}"; do
  ZONE="$(zone_of "${HOSTNAME}")"
  if [[ -z "${SEEN_ZONES[${ZONE}]:-}" ]]; then
    echo
    warn "About to authorize for zone: ${ZONE}"
    echo "A browser tab will open — make sure you select the '${ZONE}' zone."
    read -rp "Press Enter to continue..."
    cloudflared tunnel login
    SEEN_ZONES[${ZONE}]=1
  fi
  cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}" || \
    warn "route dns failed for ${HOSTNAME} — check it's not already routed, and that the cert is scoped to ${ZONE}."
done

step "Installing cloudflared as a systemd service"
sudo cloudflared service install
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

# ---------- nginx (portfolio) ----------
step "Configuring Nginx for the portfolio site"
sudo tee /etc/nginx/sites-available/default > /dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root ${PORTFOLIO_ROOT};
    index index.html;
    server_name _;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
chmod 755 "${HOME_DIR}"
sudo systemctl restart nginx

if [[ ! -f "${PORTFOLIO_ROOT}/index.html" ]]; then
  cat > "${PORTFOLIO_ROOT}/index.html" <<'EOF'
<!doctype html>
<html><head><title>Coming soon</title></head>
<body><h1>Upload your site files here.</h1></body></html>
EOF
  warn "Placeholder index.html created at ${PORTFOLIO_ROOT} — upload your real site files via scp."
fi

# ---------- docker ----------
step "Installing Docker"
if ! require_cmd docker; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "${RUN_USER}"
  warn "Added ${RUN_USER} to the docker group — you'll need to log out/in (or run 'newgrp docker') before the next docker commands work without sudo."
else
  echo "Docker already installed, skipping."
fi

# ---------- filestash ----------
step "Setting up Filestash (private drive)"
if docker ps -a --format '{{.Names}}' | grep -q '^filestash$'; then
  echo "Container 'filestash' already exists, skipping."
else
  sudo docker run -d \
    --name filestash \
    --restart unless-stopped \
    -p 8080:8334 \
    -v "${FILESTASH_STATE_DIR}:/app/data/state/" \
    -v "${DRIVE_DIR}:/srv/drive" \
    machines/filestash
fi

# ---------- onlyoffice ----------
step "Setting up OnlyOffice (document preview for the drive)"
if docker ps -a --format '{{.Names}}' | grep -q '^onlyoffice$'; then
  echo "Container 'onlyoffice' already exists, skipping."
else
  sudo docker run -d \
    --name onlyoffice \
    --restart unless-stopped \
    -p 8081:80 \
    onlyoffice/documentserver

  echo "Waiting for OnlyOffice to finish starting up..."
  for i in $(seq 1 30); do
    if curl -sf http://localhost:8081/healthcheck >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  step "Disabling OnlyOffice JWT enforcement (required for Filestash WOPI integration)"
  ONLYOFFICE_ID="$(sudo docker ps -qf name=onlyoffice)"
  sudo docker exec "${ONLYOFFICE_ID}" bash -c \
    "/var/www/onlyoffice/documentserver/npm/json -I -f /etc/onlyoffice/documentserver/local.json -e 'this.services.CoAuthoring.token.enable.request.inbox=false; this.services.CoAuthoring.token.enable.request.outbox=false; this.services.CoAuthoring.token.enable.browser=false;'"
  sudo docker restart onlyoffice
fi

# ---------- jellyfin ----------
step "Installing Jellyfin (movies)"
if ! require_cmd jellyfin; then
  curl https://repo.jellyfin.org/install-debuntu.sh | sudo bash
else
  echo "Jellyfin already installed, skipping."
fi

# ---------- Filestash admin secret ----------
step "Filestash admin credentials"
echo "Filestash sets its admin username/password through its own first-run web UI,"
echo "not via docker flags — you'll enter this manually at http://<pi-ip>:8080/admin"
echo
read -rp "Enter a Filestash admin password now (leave blank to generate a strong one): " FS_PASS
if [[ -z "${FS_PASS}" ]]; then
  FS_PASS="$(openssl rand -base64 16)"
  echo
  c_yellow "Generated password (save this now — it will not be shown again):"
  echo "  ${FS_PASS}"
else
  echo
  c_yellow "Use this password when Filestash's admin setup screen asks for one."
fi
echo "Recommended Filestash admin config (set in the web UI):"
echo "  Storage Backend: LOCAL, path = /srv/drive"
echo "  Authentication Middleware: LOCAL (not PASSTHROUGH)"
echo "  Office section -> Filestash Server: http://<pi-lan-ip>:8080"
echo "  Office section -> Office Server:    http://<pi-lan-ip>:8081"

# ---------- summary ----------
step "Done — manual steps still required"
cat <<EOF

1. Upload your portfolio files into: ${PORTFOLIO_ROOT}
   scp -r ./site/* ${RUN_USER}@<pi-ip>:${PORTFOLIO_ROOT}/

2. Finish Filestash setup in the browser at http://<pi-ip>:8080
   (admin credentials, storage backend, and Office integration — see above)

3. In the Cloudflare dashboard, go to Zero Trust -> Access -> Applications
   and add self-hosted applications for:
     - ${DRIVE_DOMAIN}
     - ${MOVIES_DOMAIN}
   with a policy allowing only your email. This is NOT scriptable from here —
   do it manually, and don't treat either service as secured until it's saved.

4. Add movies into: ${MOVIES_DIR}
   scp -r ./movies/* ${RUN_USER}@<pi-ip>:${MOVIES_DIR}/
   Then open Jellyfin's setup wizard at http://<pi-ip>:8096 and point its
   Movies library at ${MOVIES_DIR}.

5. Check service status any time with:
   systemctl status cloudflared --no-pager
   sudo docker ps
   systemctl status jellyfin --no-pager

EOF
c_green "Setup script finished."
