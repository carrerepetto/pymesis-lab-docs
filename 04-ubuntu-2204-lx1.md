---
title: 04-ubuntu-2204-lx1
description: ubuntu-2204
published: 1
date: 2026-09-01T17:11:17.545Z
tags: 
editor: markdown
dateCreated: 2026-08-27T22:38:04.620Z
---

# Project 4 — Ubuntu 22.04 Installation (lx1)

**Previous:** [Project 3 — Windows Server (dc1, dc2, fs1)](03-windows-server-2022-dc-fs.md)
**Next:** [Project 5 — Backup Server (bk1)](05-debian13-bk1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Install Ubuntu Server 22.04 as `lx1` (originally provisioned as `LINUX01`) on Node 1, then turn it into the lab's general-purpose Linux/Docker host: a Docker + Docker Compose engine fronted by an Nginx reverse proxy, hosting Portainer, WikiJS, Gitea, and Uptime Kuma, all published over HTTPS with certificates issued by the lab's internal CA.

## Context

This VM followed the blueprint slot for `LINUX01` (VLAN20, `10.0.20.40`), intended from the start as a Docker/Nginx host rather than a role-specific server. The VM was installed and given a static IP and Docker/Nginx packages first; the actual containerized services (Portainer, WikiJS, Gitea, Uptime Kuma) were deferred and only configured once every other Node 1 VM (`dc1`, `dc2`, `fs1`, `app1`, `bk1`, `mon1`, `odoo1`/`db1`, `cl1`/`cl2`) was already complete — at that point `lx1` was the last piece needed to close out Node 1 before moving on to `fw1` (VPN/IDS-IPS).

## Decisions Made and Rationale

- **Hostname changed from `linux01` to `lx1`, deliberately**: during installation the server name was set to `linux01` per the original blueprint terminology, but was later intentionally shortened to `lx1` for consistency with the short-hostname convention used across the rest of the lab. Confirmed as intentional, not an error, when it showed up on a reboot login screen.
- **Static IP via Netplan, not the installer's DHCP**: the installer was left on DHCP just to complete setup, then switched to a static Netplan config (`10.0.20.40/24`, gateway `10.0.20.1`) with DNS pointed at `dc1` (`10.0.20.10`) first and `dc2` (`10.0.20.11`) second — matching the DNS resolution order convention used on the Windows Server VMs.
- **Docker and Nginx installed early, configured late**: both packages were installed right after the base OS setup, but deliberately left unconfigured (no containers, no reverse proxy) until there were actual services to run and virtual hosts to define — configuring Nginx before any service exists was judged to be premature work.
- **Portainer container run standalone via `docker run`, not Compose**: unlike WikiJS, Gitea, and Uptime Kuma (each with its own `docker-compose.yml` under `~/docker/<service>/`), Portainer was launched directly with `docker run` since it's a single self-contained container with no dependent services.
- **SQLite as the backing database for WikiJS**: chosen to avoid standing up a separate database container for a homelab-scale wiki.
- **One shared internal CA certificate for all four services**: a single CSR was generated for `lx1` with Subject Alternative Names covering `lx1.pymesis.lab`, `portainer.pymesis.lab`, `wiki.pymesis.lab`, `gitea.pymesis.lab`, and `uptime.pymesis.lab`, signed once by the lab's AD CS (`pymesis-DC01-CA`) — rather than issuing a separate certificate per virtual host.
- **Uptime Kuma monitors tuned per service instead of forcing HTTPS everywhere**: rather than treating every monitor uniformly, each one was matched to how its target actually behaves — Ping for hosts with no relevant web endpoint (`dc1`, `OPNsense`, `Wazuh`), HTTP instead of HTTPS for Grafana, and added accepted status codes (`401`, `302`) plus "Ignore TLS/SSL error" for services that require authentication or use the internal CA (Zabbix, Wazuh, the intranet on `app1`).

## Step-by-Step

### Phase 1 — Create the VM in Proxmox

| Field | Value |
|---|---|
| VM ID | 106 |
| Name | LINUX01 (hostname later set to `lx1`) |
| ISO | `ubuntu-22.04.5-live-server-amd64.iso` |
| Machine / BIOS | `q35` / SeaBIOS |
| SCSI Controller | VirtIO SCSI single, Qemu Agent enabled |
| Disk | `scsi0`, `local-lvm`, 60GB, cache Write back, Discard enabled |
| CPU | 1 socket, 2 cores, type `x86-64-v2-AES` |
| RAM | 4096 MB |
| Network | `vmbr0`, VLAN tag 20, model VirtIO |

### Phase 2 — Install Ubuntu Server 22.04

Boot the ISO → **Try or Install Ubuntu Server** → language English, keyboard layout Spanish → install type **Ubuntu Server** (not minimized) → network interface `ens18` left on DHCP for now → storage: use the entire 60GB disk, set up as an LVM group → profile: name Santiago, server name `linux01`, username `sadmin` → **Install OpenSSH server** enabled, no SSH keys imported → no featured snaps selected → reboot, removing the ISO when prompted.

### Phase 3 — Post-install base configuration

1. Update the system: `sudo apt update && sudo apt upgrade -y`
2. Install the QEMU Guest Agent:
   ```bash
   sudo apt install -y qemu-guest-agent
   sudo systemctl enable --now qemu-guest-agent
   ```
3. Static IP via Netplan (`/etc/netplan/00-installer-config.yaml`):
   ```yaml
   network:
     version: 2
     ethernets:
       ens18:
         dhcp4: false
         addresses:
           - 10.0.20.40/24
         routes:
           - to: default
             via: 10.0.20.1
         nameservers:
           addresses:
             - 10.0.20.10   # DC01
             - 10.0.20.11   # DC02
           search:
             - pymesis.lab
   ```
   Apply with `sudo netplan apply`, verify with `ip a` and `ping 10.0.20.10`.
4. Set hostname to `lx1`:
   ```bash
   sudo hostnamectl set-hostname lx1
   sudo nano /etc/hosts   # add: 10.0.20.40  lx1.pymesis.lab  lx1
   ```
5. Set the system timezone with `timedatectl set-timezone` (adjusted to the lab's actual local zone).

### Phase 4 — Install Docker

```bash
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker sadmin
sudo docker run hello-world
```

### Phase 5 — Install Nginx and take the base snapshot

```bash
sudo apt install -y nginx
sudo systemctl enable --now nginx
```

Verified from a browser at `http://10.0.20.40`. With the base OS, Docker, and Nginx all confirmed working, a clean Proxmox snapshot was taken (`post-install-base`, RAM included).

### Phase 6 — Deploy Docker services (Portainer, WikiJS, Gitea, Uptime Kuma)

**Portainer** (standalone container):
```bash
sudo docker volume create portainer_data
sudo docker run -d \
  --name portainer \
  --restart=always \
  -p 9000:9000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest \
  --no-setup-token
```

**WikiJS** (`~/docker/wikijs/docker-compose.yml`):
```yaml
services:
  wikijs:
    image: ghcr.io/requarks/wiki:2
    container_name: wikijs
    restart: always
    environment:
      DB_TYPE: sqlite
    volumes:
      - wikijs_data:/wiki/data
    ports:
      - "3000:3000"
volumes:
  wikijs_data:
```

**Gitea** (`~/docker/gitea/docker-compose.yml`):
```yaml
services:
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    restart: always
    environment:
      - USER_UID=1000
      - USER_GID=1000
    volumes:
      - gitea_data:/data
    ports:
      - "3001:3000"
      - "2222:22"
volumes:
  gitea_data:
```

**Uptime Kuma** (`~/docker/uptimekuma/docker-compose.yml`):
```yaml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: always
    volumes:
      - uptime_data:/app/data
    ports:
      - "3002:3001"
volumes:
  uptime_data:
```

Each was brought up with `sudo docker compose up -d` in its own directory, verified with `sudo docker ps`, and set up through its respective first-run web wizard (admin account creation for each).

### Phase 7 — Nginx reverse proxy (HTTP first)

One virtual host per service under `/etc/nginx/sites-available/`, each proxying to its container's local port:

| Domain | Proxies to |
|---|---|
| `portainer.pymesis.lab` | `localhost:9000` |
| `wiki.pymesis.lab` | `localhost:3000` |
| `gitea.pymesis.lab` | `localhost:3001` |
| `uptime.pymesis.lab` | `localhost:3002` |

Example (Portainer):
```nginx
server {
    listen 80;
    server_name portainer.pymesis.lab;

    location / {
        proxy_pass http://localhost:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Each site was symlinked into `sites-enabled/`, validated with `sudo nginx -t`, and reloaded with `sudo systemctl reload nginx`. Four DNS A records were added on `dc1` (`portainer`, `wiki`, `gitea`, `uptime`, all pointing to `10.0.20.40`) to resolve the domains.

### Phase 8 — HTTPS with the internal CA (AD CS)

1. Generate a CSR with SANs for all four domains plus `lx1.pymesis.lab` (`/etc/ssl/lx1-san.cnf`), then:
   ```bash
   sudo openssl req -new -newkey rsa:2048 -nodes \
     -keyout /etc/ssl/lx1.key \
     -out /etc/ssl/lx1.csr \
     -config /etc/ssl/lx1-san.cnf
   ```
2. Copy the CSR to `dc1` and sign it there with the internal CA:
   ```powershell
   certreq -submit -attrib "CertificateTemplate:WebServer" C:\temp\lx1.csr C:\temp\lx1.crt
   ```
3. Copy the resulting `lx1.crt` back to `lx1` (`/etc/ssl/lx1.crt`).
4. Update each of the four Nginx virtual hosts to redirect port 80 to 443 and serve HTTPS with `ssl_certificate /etc/ssl/lx1.crt` / `ssl_certificate_key /etc/ssl/lx1.key`.
5. Validate (`sudo nginx -t`) and reload — all four services confirmed reachable over HTTPS.

### Phase 9 — Snapshot and Uptime Kuma monitoring

A second Proxmox snapshot (`post-docker-nginx-https`) was taken once HTTPS was confirmed working on all four services.

Monitors were then added in Uptime Kuma for the whole homelab fleet, adjusting type and settings per target as needed (see Problems Solved). A final snapshot (`lx1-completo`) was taken once every monitor showed green.

### Phase 10 — Backups

Confirmed as part of a later fleet-wide alignment pass:

| Item | Value |
|---|---|
| Script | `/usr/local/bin/backup.sh` |
| Schedule | Daily cron at 3:00 AM (Linux VMs; Windows VMs run at 2:30 AM) |
| Destination | `bk1` via Restic over SFTP (`10.0.20.50`) |
| Repository | `/mnt/backups/repos/lx1` |
| SSH key | `/root/.ssh/backup_key` (ed25519) |

## Problems Solved

- **Portainer "Setup token" required and rejected**: recent Portainer versions require pasting a one-time setup token from the container logs (`sudo docker logs portainer 2>&1 | grep -i "token"`) before creating the admin user. The token was initially pasted incomplete/truncated into the web form and the "Create user" button did nothing. Resolved by stopping and recreating the container with the `--no-setup-token` flag, which skips the token requirement entirely and lets the admin account be created directly.
- **`cloud-init ... DataSourceNone` message on boot, mistaken for an error**: after a reboot, the console showed `cloud-init v.26.1 running 'modules:final'... DataSourceNone`. Confirmed as expected and harmless — cloud-init simply found no external data source (normal for a Proxmox VM installed from an ISO rather than a cloud image) and exited without doing anything; the VM was booting cleanly and waiting at login.
- **All Uptime Kuma monitors showing Down after HTTPS was enabled**: the internal CA's root certificate wasn't trusted anywhere yet. Fixed in two layers:
  1. **System-level trust**: the CA root certificate had to be located on `dc1` first (distinguishing the actual `.crt` root certificate in `C:\Windows\System32\certsrv\CertEnroll\` from a similarly-named `.crl` revocation list file found first by mistake), copied to `lx1`, and installed with `sudo update-ca-certificates` — which fixed trust for the four Docker services proxied through Nginx (Portainer, WikiJS, Gitea, Uptime Kuma itself) once their containers were restarted.
  2. **Uptime Kuma's own certificate store**: even after the system-wide fix, monitors targeting *other* hosts on the internal CA (Zabbix, Wazuh, the app1 intranet, OPNsense) still failed, since Uptime Kuma validates TLS independently of the OS trust store. Resolved per-monitor by enabling **"Ignore TLS/SSL error"**.
- **Intranet monitor (app1/IIS) still down after ignoring TLS errors**: IIS was correctly responding but with a `401 Unauthorized` (Windows Authentication challenge), which Uptime Kuma treats as a failure by default. Fixed by adding `401` to that monitor's **Accepted Status Codes**.
- **Zabbix, Wazuh, and OPNsense monitors still down**: Zabbix and Wazuh needed `302` and `401` added to Accepted Status Codes (redirects to login, auth challenges) in addition to "Ignore TLS/SSL error". OPNsense and Wazuh continued to time out even after those changes, because OPNsense blocks HTTPS connections from the LAN to its own management interface by policy, and Wazuh behaved similarly in this setup — both were switched from HTTP(s) monitors to simple **Ping** monitors instead, which was judged sufficient host-liveness checking for the homelab. Zabbix was kept as an HTTPS monitor once its status codes were corrected. After these adjustments, every monitor in the dashboard showed green.

## Final Result

**lx1** — `10.0.20.40` / `lx1.pymesis.lab`, Ubuntu 22.04 LTS, 2 vCPU, 4GB RAM, 60GB disk (VM ID 106).

| Service | Status |
|---|---|
| Docker + Compose plugin | ✅ |
| Portainer | ✅ HTTPS — `portainer.pymesis.lab` |
| WikiJS | ✅ HTTPS — `wiki.pymesis.lab` |
| Gitea | ✅ HTTPS — `gitea.pymesis.lab` |
| Uptime Kuma | ✅ HTTPS — `uptime.pymesis.lab` |
| Nginx reverse proxy | ✅ |
| Internal CA certificate (SAN, all 4 domains) | ✅ |
| Uptime Kuma fleet-wide monitoring | ✅ all monitors green |
| Restic backup to `bk1` (daily, 3:00 AM) | ✅ |
| Proxmox snapshots | `post-install-base`, `post-docker-nginx-https`, `lx1-completo` |

With `lx1` complete, Node 1 was fully closed out except for `fw1`'s pending VPN/IDS-IPS work.

## Pending

- `rclone` sync to a NAS — blocked on the Ugreen DXP4800 hardware purchase (affects the whole fleet, not just `lx1`).
- Connecting Gitea as a stack source for Portainer (optional).
- Documenting the homelab's own content inside WikiJS.

## Cross-References

- DNS records for `lx1` and its four service subdomains were added on `dc1`, per [Project 3](03-windows-server-2022-dc-fs.md)'s DNS server.
- The HTTPS certificate for `lx1` was signed by the same `pymesis-DC01-CA` (AD CS on `dc1`) used for other lab services (Odoo, the app1 intranet).
- Backup conventions (Restic to `bk1`, per-OS schedule) mirror the fleet-wide pattern defined in the [Lab Index](00-pymesis-lab-index.md) and first documented in [Project 3](03-windows-server-2022-dc-fs.md).

---

[← **Previous:** Project 3 — Windows Server (dc1, dc2, fs1)](03-windows-server-2022-dc-fs.md)) | [**Next:** Project 5 — Backup Server (bk1) →](05-debian13-bk1.md)