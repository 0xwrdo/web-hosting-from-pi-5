#!/bin/bash

# ============================================================
#  Self-Hosting Setup Script
#  Nginx + Cloudflare Tunnel on Raspberry Pi
#  github.com/YOUR_GITHUB_USERNAME/YOUR_REPO
# ============================================================

set -e

echo ""
echo "======================================"
echo "  Pi Self-Hosting Setup"
echo "  Nginx + Cloudflare Tunnel"
echo "======================================"
echo ""

# --- Pre-checks ---
if [ "$EUID" -eq 0 ]; then
  echo "❌ Don't run this as root. Run as your normal user (e.g. wrdo)."
  exit 1
fi

# --- Inputs ---
read -p "Enter your domain (e.g. raunakkushwaha.tech): " DOMAIN
read -p "Enter your tunnel name (e.g. raunak-pi): " TUNNEL_NAME
read -p "Enter your web folder path (default: /home/$USER/123): " WEB_ROOT
WEB_ROOT=${WEB_ROOT:-/home/$USER/123}

echo ""
echo "Domain:      $DOMAIN"
echo "Tunnel name: $TUNNEL_NAME"
echo "Web root:    $WEB_ROOT"
echo ""
read -p "Looks good? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
  echo "Aborted."
  exit 1
fi

# --- Step 1: Update & install Nginx ---
echo ""
echo "📦 Installing Nginx..."
sudo apt update -y && sudo apt install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
echo "✅ Nginx installed."

# --- Step 2: Install cloudflared ---
echo ""
echo "📦 Installing cloudflared..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
sudo dpkg -i cloudflared-linux-arm64.deb
rm cloudflared-linux-arm64.deb
echo "✅ cloudflared installed."

# --- Step 3: Login to Cloudflare ---
echo ""
echo "🔐 Logging into Cloudflare..."
echo "   A browser link will appear — open it and authorize."
cloudflared tunnel login

# --- Step 4: Create tunnel ---
echo ""
echo "🚇 Creating tunnel: $TUNNEL_NAME..."
cloudflared tunnel create $TUNNEL_NAME
TUNNEL_UUID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
echo "✅ Tunnel UUID: $TUNNEL_UUID"

# --- Step 5: Create web root ---
echo ""
echo "📁 Creating web root at $WEB_ROOT..."
mkdir -p $WEB_ROOT
chmod 755 /home/$USER
chmod 755 $WEB_ROOT

# Create a default index.html if none exists
if [ ! -f "$WEB_ROOT/index.html" ]; then
cat > $WEB_ROOT/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>$DOMAIN</title>
</head>
<body>
    <h1>Hello from $DOMAIN 🎉</h1>
    <p>Hosted on a Raspberry Pi with Nginx + Cloudflare Tunnel.</p>
</body>
</html>
EOF
echo "✅ Default index.html created."
fi

# --- Step 6: Configure Nginx ---
echo ""
echo "⚙️  Configuring Nginx..."
sudo sed -i "s|root /var/www/html;|root $WEB_ROOT;|g" /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl reload nginx
echo "✅ Nginx configured."

# --- Step 7: Create cloudflared config ---
echo ""
echo "⚙️  Writing cloudflared config..."
mkdir -p ~/.cloudflared
cat > ~/.cloudflared/config.yml <<EOF
tunnel: $TUNNEL_UUID
credentials-file: /etc/cloudflared/$TUNNEL_UUID.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:80
  - hostname: www.$DOMAIN
    service: http://localhost:80
  - service: http_status:404
EOF

# --- Step 8: Route DNS ---
echo ""
echo "🌐 Routing DNS..."
cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN
cloudflared tunnel route dns $TUNNEL_NAME www.$DOMAIN
echo "✅ DNS routes created."

# --- Step 9: Install as service ---
echo ""
echo "🔧 Installing cloudflared as system service..."
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/config.yml /etc/cloudflared/
sudo cp ~/.cloudflared/$TUNNEL_UUID.json /etc/cloudflared/
sudo sed -i "s|/home/$USER/.cloudflared|/etc/cloudflared|g" /etc/cloudflared/config.yml
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
echo "✅ cloudflared service installed and running."

# --- Done ---
echo ""
echo "======================================"
echo "  ✅ Setup Complete!"
echo "======================================"
echo ""
echo "  Your site is live at: https://$DOMAIN"
echo "  Web files:            $WEB_ROOT"
echo "  Tunnel name:          $TUNNEL_NAME ($TUNNEL_UUID)"
echo ""
echo "  Upload files with SCP:"
echo "  scp yourfile.html $USER@$(hostname -I | awk '{print $1}'):$WEB_ROOT/"
echo ""
