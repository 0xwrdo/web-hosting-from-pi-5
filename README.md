# 🌐 Self-Hosting My Website on Raspberry Pi 5 — No Port Forwarding

## What I Built

I set up my personal website [raunakkushwaha.tech](https://raunakkushwaha.tech) running entirely from a **Raspberry Pi 5** at home — no port forwarding, no static IP, no paid hosting.

---

## Stack

- **Hardware**: Raspberry Pi 5
- **OS**: Raspberry Pi OS Lite
- **Web Server**: Nginx
- **Tunnel**: Cloudflare Tunnel (cloudflared)
- **Domain**: raunakkushwaha.tech (registered on get.tech)
- **SSL**: Automatic HTTPS via Cloudflare (free)

---

## How It Works

```
Visitor → raunakkushwaha.tech
        → Cloudflare's network
        → Encrypted tunnel (cloudflared)
        → Raspberry Pi 5 (Nginx on port 80)
        → /home/wrdo/123/index.html
```

Cloudflare Tunnel creates an outbound connection from the Pi to Cloudflare. Incoming traffic is routed through that tunnel — no ports need to be opened on the router, and my home IP stays hidden.

---

## Prerequisites

Before running the setup, make sure you have:

- [ ] Raspberry Pi 4 or 5 running **Raspberry Pi OS Lite** (Bookworm)
- [ ] Pi connected to the internet via Ethernet or Wi-Fi
- [ ] A domain name added to **Cloudflare** (free plan) with nameservers updated at your registrar
- [ ] SSH access to your Pi
- [ ] `curl` installed (`sudo apt install curl -y`)

---

## Quick Setup (One-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO/main/setup.sh | bash
```

> ⚠️ Replace `YOUR_GITHUB_USERNAME` and `YOUR_REPO` with your actual GitHub details after uploading.

Or manually clone and run:

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPO.git
cd YOUR_REPO
chmod +x setup.sh
./setup.sh
```

The `setup.sh` script will:
1. Install Nginx and cloudflared
2. Prompt you for your Cloudflare tunnel name and domain
3. Create the config files automatically
4. Install cloudflared as a systemd service
5. Set correct permissions on the web directory

---

## What I Did (Step by Step)

1. Registered `raunakkushwaha.tech` on get.tech
2. Added the domain to Cloudflare (free plan) and updated nameservers at get.tech
3. Installed `cloudflared` on the Pi (ARM64 .deb package)
4. Authenticated with `cloudflared tunnel login`
5. Created a tunnel: `cloudflared tunnel create raunak-pi`
6. Wrote a `config.yml` pointing to `http://localhost:80`
7. Routed DNS: `cloudflared tunnel route dns raunak-pi raunakkushwaha.tech`
8. Copied config to `/etc/cloudflared/` and installed as a systemd service
9. Configured Nginx root to `/home/wrdo/123/`
10. Fixed file permissions (`chmod 755` on home and project folder)
11. Uploaded `index.html` and `style.css` via SCP from Windows

---

## Key Lessons Learned

- `sudo cloudflared service install` needs the config in `/etc/cloudflared/`, not `~/.cloudflared/`, because root doesn't expand `~` to your user home
- Nginx serving from a home directory requires `chmod 755` on the home folder itself, not just the project folder
- CSS `href="../style.css"` goes *up* a directory — use `href="style.css"` when both files are in the same folder
- SCP destination needs a colon: `user@ip:/path/`, not `user@ip/path/`
- Always hard refresh (`Ctrl+Shift+R`) or use incognito when testing CSS changes

---

## Current Site

A minimal personal webpage with:
- Dark background
- Centered heading
- Spinning CSS loader animation

Served 24/7 from my Pi at home. ⚡

---

## What's Next

- [ ] Add more pages (projects, about)
- [ ] Set up a photo/video gallery
- [ ] Add WireGuard VPN for remote SSH access
- [ ] Try hosting Nextcloud or Jellyfin on the same Pi

---

*Built and self-hosted by Raunak Kushwaha — [@wrdogamer4141](https://youtube.com/@wrdogamer4141)*
