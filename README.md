# Self-Host a Website with Nginx + Cloudflare Tunnel

Three setup scripts that serve a website from a Raspberry Pi or Linux machine **without port forwarding or a static IP**. Visitors reach Cloudflare, which forwards traffic through an encrypted outbound tunnel to Nginx on your machine.

```
Visitor -> Cloudflare -> encrypted tunnel (cloudflared) -> Nginx -> your site folder
```

## Before you start

- A domain added to a **free Cloudflare account**, with nameservers updated at your registrar (status: Active).
- A Raspberry Pi (4/5, Raspberry Pi OS Lite) or a Linux desktop/server (Debian/Ubuntu, Fedora, Arch).
- Internet access and a user with `sudo`.

Run every script as a **normal user**, not root and not with `sudo`.

## Which script should I use?

| Script | Best for | Questions | Defaults |
|---|---|---|---|
| `setup.sh` | Raspberry Pi, full control | Many | Few |
| `setup-desktop.sh` | Linux desktop/server | Domain, and optional edits | `/site`, `site-tunnel`, port `8080` |
| `setup-min.sh` | Fastest setup on any machine | Domain only | Everything |

### `setup.sh` — Raspberry Pi, fully interactive

Asks for domain, optional www, Pi username, site folder, tunnel name, Nginx port, Pi IP and your Windows site folder.

It installs Nginx and cloudflared, creates an Nginx site, logs in to Cloudflare, creates or reuses the tunnel (and asks before deleting an existing one), routes DNS, writes the config and starts the service. At the end it runs `curl -I` and status checks.

It also prints a separate **copy-your-site** block with the `scp` command for your Windows PC and the commands to run on the Pi, and saves them to `~/upload-commands.txt`.

```bash
chmod +x setup.sh && ./setup.sh
```

### `setup-desktop.sh` — Linux desktop, defaults you can accept

Works on apt, dnf and pacman systems. Press Enter to accept defaults:

- Site folder: `/site`, with a default "Your site is live" page
- Tunnel name: `site-tunnel`
- Nginx port: `8080` (localhost only, so it won't clash with other services)
- If the tunnel already exists, it is **deleted and recreated** automatically

```bash
chmod +x setup-desktop.sh && ./setup-desktop.sh
```

### `setup-min.sh` — domain only

Asks only for your domain (or take it as an argument). Everything else is fixed: folder `/site`, port `8080`, tunnel named after the domain, `www` included, existing tunnel recreated.

```bash
chmod +x setup-min.sh && ./setup-min.sh example.com
```

## The one manual step

All scripts need a Cloudflare login the first time. A URL is printed; open it in a browser, pick your domain and authorize. If `~/.cloudflared/cert.pem` already exists, the login is reused.

## Uploading your site

Put your files in the site folder (`/site` by default, or whatever you chose).

From a Windows PC, in PowerShell:

```powershell
scp -r "C:\path\to\your-site" user@PI_IP:/home/user/
```

Then on the Pi, move the files into the site folder:

```bash
cp -r ~/your-site/. /site/ && rm -rf ~/your-site
chmod -R a+rX /site
```

Use real values, not placeholders like `<pi-ip>`. Then open `https://your-domain` in an incognito window.

## Useful commands

```bash
curl -I http://localhost:8080            # is Nginx serving? (use port 80 with setup.sh defaults)
sudo systemctl status cloudflared nginx  # service status
sudo journalctl -u cloudflared -n 50     # tunnel logs
cloudflared tunnel list                  # list tunnels
sudo nginx -t && sudo systemctl reload nginx
```

## Troubleshooting

- **"tunnel with name already exists" / DNS record exists:** `setup-desktop.sh` and `setup-min.sh` handle this by recreating the tunnel. Manually: `cloudflared tunnel delete NAME`, create again, then `cloudflared tunnel route dns --overwrite-dns NAME your-domain`.
- **403 or 404 from Nginx:** the folder isn't readable. Run `chmod -R a+rX /site`. If the folder is under `/home`, every parent directory also needs `o+x`.
- **CSS not loading:** use `href="style.css"` when the file is in the same folder, and hard refresh with `Ctrl+Shift+R`.
- **Site works locally but not by domain:** check that the domain is Active in Cloudflare and `cloudflared` is running.
- **Old domain still in pages:** `grep -rl "old-domain" /site`.

## Notes

- Keep the tunnel credentials file (`~/.cloudflared/<ID>.json`) secret.
- A home connection is a single point of failure. For anything customers depend on, consider a UPS and uptime monitoring.
- These scripts have not been tested on every distro. If one fails, check the output before re-running.
