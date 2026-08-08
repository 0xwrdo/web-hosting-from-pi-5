# 🌐 Self-Hosting My Infrastructure on Raspberry Pi 5 — No Port Forwarding

## What I Built

What started as just my personal website has grown into a small home-hosted infrastructure running on a single **Raspberry Pi 5** — no port forwarding, no static IP, no paid hosting. Everything is exposed to the internet through **Cloudflare Tunnel**, split across two domains by purpose:

| Domain | Purpose | Service |
|---|---|---|
| `raunakkushwaha.me` | Public portfolio site | Nginx |
| `drive.raunakkushwaha.tech` | Private personal file drive | Filestash (Docker) + OnlyOffice preview |
| `movies.raunakkushwaha.tech` | Private movie streaming server | Jellyfin |

The private services (`drive`, `movies`) sit behind two layers of auth: their own app-level login, plus a Cloudflare Access email allowlist in front of the tunnel itself.

> Older versions of this repo covered only the `raunakkushwaha.tech` portfolio site on a single tunnel. That domain now serves the private drive + movies, and the portfolio moved to `raunakkushwaha.me`.

---

## Architecture

```
                         ┌──────────────────────────┐
Visitor ──────────────▶  │   Cloudflare Network      │
                         │  (+ Access, for private   │
                         │   hostnames only)         │
                         └──────────────┬────────────┘
                                        │ encrypted tunnel (cloudflared)
                                        ▼
                         ┌──────────────────────────────────┐
                         │        Raspberry Pi 5              │
                         │  cloudflared (single tunnel,        │
                         │  multiple ingress rules)             │
                         ├──────────────┬───────────┬─────────┤
                         │  Nginx :80   │ Filestash  │ Jellyfin │
                         │  (portfolio) │  :8080     │  :8096   │
                         │              │  + OnlyOffice :8081   │
                         └──────────────┴───────────┴─────────┘
```

One cloudflared tunnel (`raunak-pi-me`) routes all three hostnames to their respective local ports via `ingress` rules — no separate tunnel per service.

---

## Stack

- **Hardware**: Raspberry Pi 5
- **OS**: Raspberry Pi OS Lite (Debian Bookworm, ARM64)
- **Tunnel**: Cloudflare Tunnel (`cloudflared`), single tunnel / multi-hostname ingress
- **Portfolio**: Nginx
- **Private drive**: [Filestash](https://github.com/mickael-kerjean/filestash) (Docker) — chosen over Filebrowser, which was flagged as archived/unmaintained
- **Document preview**: OnlyOffice Docs Community Edition (Docker), integrated with Filestash via WOPI
- **Media server**: Jellyfin (native install, not Docker)
- **Access control**: Cloudflare Access (email allowlist) in front of both private hostnames, on top of each app's own login

---

## How It Works

```
Visitor → <hostname>
        → Cloudflare's network (+ Access check for private hostnames)
        → Encrypted tunnel (cloudflared)
        → Raspberry Pi 5 → matching local port (80 / 8080 / 8096)
```

Cloudflare Tunnel creates an outbound-only connection from the Pi to Cloudflare, so no ports are opened on the router and the home IP stays hidden. A single `cloudflared` service handles all three hostnames through one `config.yml` with multiple `ingress` rules.

---

## Setup Overview

1. Register/point each domain's nameservers at Cloudflare (free plan), added as separate zones for `.me` and `.tech`.
2. Install `cloudflared`, authenticate with `cloudflared tunnel login`, create **one** tunnel and route DNS for each hostname to it.
3. Write a single `config.yml` with an `ingress` rule per hostname → local port, copy it to `/etc/cloudflared/`, install as a systemd service.
4. Set up each backend service:
   - **Nginx** serving the portfolio's static files, root pointed at the site folder, correct permissions (`chmod 755`) on the home directory.
   - **Filestash** in Docker, with *separate* host folders for its internal app state vs. actual served files (mounting both to the same folder pollutes the drive with Filestash's own state/config/db).
   - **OnlyOffice Docs** in Docker for inline document preview inside Filestash, connected via WOPI.
   - **Jellyfin** installed natively via its official install script, media library pointed at the movies folder.
5. Lock down the private hostnames with **Cloudflare Access** (Zero Trust → Access → Applications → self-hosted app → policy allowing only your email), in addition to each app's own login.

Full command reference and config snippets live in the setup notes / `setup.sh` in this repo — update them if your ports, tunnel name, or paths differ.

---

## Key Lessons Learned

- `sudo cloudflared service install` needs its config in `/etc/cloudflared/`, not `~/.cloudflared/` — root doesn't expand `~` to your user home. Edit the home directory copy, then `cp` it over and restart the service.
- **cloudflared's `cert.pem` is zone-scoped.** `cloudflared tunnel login` authorizes your local cert for whichever Cloudflare zone you pick in the browser. Running `tunnel route dns` for a hostname in a *different* zone than the active cert doesn't fail loudly — it can silently create a malformed nested DNS record. If you manage multiple zones on one tunnel, keep the cert for each zone backed up separately and swap the correct one into place before routing DNS for that zone.
- Running two separate `cloudflared` tunnels (one per domain) caused conflicts — consolidating to **one tunnel with multiple ingress rules** is simpler and avoids running two systemd services.
- Docker volumes: don't mount the same host folder for an app's internal state *and* its user-facing file storage — use two separate folders.
- Actively maintained tooling matters for anything internet-facing — a candidate that turned out to be archived with no further security fixes was dropped in favor of a maintained alternative.
- When wiring two containers together (e.g. an office/document server and a file manager), check whether one side enforces a security feature (like JWT signing) the other side can't configure — you may need to explicitly disable it on one side rather than assume they'll "just work" together, and revisit that decision if the setup is ever exposed more broadly.
- Nginx serving from a home directory requires `chmod 755` on the home folder itself, not just the project folder.
- SCP destination needs a colon: `user@ip:/path/`, not `user@ip/path/`.
- Two-layer auth (app login + Cloudflare Access) is worth the setup time for anything private-facing — Access blocks unauthorized traffic before it even reaches the Pi.
- Always hard refresh (`Ctrl+Shift+R`) or use incognito when testing frontend/CSS changes.

---

## Security Notes

- Private services (drive, movies) are meant to sit behind **both** their own login and a Cloudflare Access email allowlist. If you're replicating this setup, double-check the Access policy is actually saved with your email before treating a service as locked down — an unsaved/empty policy leaves it protected only by the app's own login.
- Any internal-only service (e.g. a document server used solely by another container on the same host) should stay out of the tunnel's `ingress` list unless it specifically needs to be public.
- Admin passwords, JWT secrets, and tunnel credential files are **not** included in this repo — generate your own strong secrets and keep them in a password manager, not in version control.

---

## Current Status

- ✅ Portfolio (`raunakkushwaha.me`) — live
- ✅ Private drive (`drive.raunakkushwaha.tech`) — live, file upload/download and document preview working
- 🔄 Movie server (`movies.raunakkushwaha.tech`) — in progress (tunnel routing + Cloudflare Access being finalized)

## What's Next

- [ ] Finish Cloudflare Access lock-down on both private hostnames
- [ ] Finish and verify movie server tunnel routing
- [ ] Normalize all services to run in Docker for consistency
- [ ] Add more pages to the portfolio (projects, about, gallery)
- [ ] WireGuard VPN for remote SSH access
- [ ] Automate the cert-swapping workaround for multi-zone DNS routing

---

*Built and self-hosted by Raunak Kushwaha — [@wrdogamer4141](https://youtube.com/@wrdogamer4141)*
