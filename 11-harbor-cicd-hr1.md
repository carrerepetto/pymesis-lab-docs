---
title: 11-harbor-cicd-hr1
description: harbor
published: 1
date: 2026-08-30T07:24:46.364Z
tags: 
editor: markdown
dateCreated: 2026-08-29T20:03:53.115Z
---

# Project 11 — Harbor + CI/CD Installation (hr1)

**Previous:** [Project 10 — GLPI Installation (glpi1)](10-glpi-glpi1.md)
**Next:** [Project 12 — Odoo 17→18 OpenUpgrade (odoo2)](12-odoo-17-18-openupgrade-odoo2.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Deploy a private container registry (Harbor) with integrated vulnerability scanning (Trivy), and wire it into a full CI/CD pipeline using Gitea Actions, so that container images built from source in Gitea are automatically built, scanned, and pushed to a private registry — without introducing any new tooling beyond what the lab already runs.

## Context / Why it was done

This project is a direct continuation of the pymesis.lab homelab buildout, following the same conventions established in earlier projects (single node, `sadmin` user, `Europe/Rome` timezone, HTTPS via the internal CA `pymesis-DC01-CA`, Zabbix + Wazuh monitoring, weekly Restic backups to `bk1`). At this point GLPI (Project 10) was already closed, and Gitea was already running on `lx1` as part of the Docker host stack (Project 4).

The goal was to close a real gap in the homelab's skill roadmap: hands-on CI/CD and container registry/supply-chain security, reusing existing infrastructure (Gitea on `lx1`) instead of adding unnecessary new components.

## Architecture / Design Decisions (and the "why")

**Full VM instead of LXC for the registry host.**
Harbor requires Docker + Docker Compose, running several containers (core, registry, Trivy scanner, database, Redis, jobservice, nginx). Running Docker inside an LXC can produce unreliable overlayfs/nesting behavior for production-like workloads. Unlike GLPI (simple PHP + MySQL, which worked fine in an LXC), Harbor's Docker-in-container footprint justified a full VM.

**CI/CD via Gitea Actions instead of a new tool (e.g. Woodpecker).**
Gitea (running since Project 4) already supports Gitea Actions natively from v1.19+, with GitHub Actions-compatible workflow syntax. Reusing it meant zero new VMs and no extra moving parts, at the cost of a slightly less mature ecosystem than a dedicated CI tool — an acceptable trade-off for a homelab focused on demonstrating the full pipeline rather than evaluating CI platforms.

**Specs decided for the VM:**

| Item | Value |
|---|---|
| Type | Full VM (not LXC) |
| Hostname | `hr1` (renamed from initial `harbor1` to follow the lab's short-name convention) |
| OS | Ubuntu 24.04 (cloud image + cloud-init) |
| VMID | 113 |
| Resources | 4 vCPU, 6 GB RAM, 60 GB disk (registry + Trivy DB grow over time) |
| IP | 10.0.20.90 (VLAN20, tag=20) |
| Stack | Docker CE + Compose + Harbor 2.15.1 + Trivy (bundled scanner) |
| HTTPS | Nginx reverse proxy (bundled with Harbor), cert issued by `pymesis-DC01-CA` |
| CI runner | Gitea Runner (Docker container) on `lx1`, targeting `hr1` as the registry |
| Monitoring | Zabbix Agent 2 + Wazuh agent |
| Backup | Restic to `bk1`, weekly, Postgres dump + config + TLS material |
| Admin | `sadmin`, `Europe/Rome` |

**Separate Docker host from `lx1`, deliberately not consolidated.**
`hr1` runs its own independent Docker daemon rather than joining the existing `lx1` (Portainer/Gitea/WikiJS/Uptime Kuma) host. Reasoning:
- **Isolation of trust**: Harbor holds registry credentials and CI robot accounts — the point of trust for the entire build→push→deploy chain. Keeping it off the general-purpose apps host mirrors how a real environment would separate the registry from general workloads.
- **Resource contention**: Trivy scans are RAM-heavy; sharing `lx1`'s existing 4 GB allocation with Gitea/WikiJS would create contention.
- **Portfolio value**: demonstrating two Docker hosts with distinct roles (general apps vs. registry/supply-chain) is more representative of a real infrastructure than consolidating everything onto one host.

**Provisioning method: cloud image + cloud-init.**
Instead of a traditional ISO install, `hr1` was provisioned from Canonical's official Ubuntu 24.04 cloud image (a pre-installed disk image meant for cloud/virtualization platforms). `qm importdisk` imports that disk directly as the VM's disk — there is no installer step. Hostname, static IP, user, and SSH keys are instead injected at first boot by **cloud-init**, reading parameters written to a small virtual disk (`--ide2 local-zfs:cloudinit`) via `qm set`. This is the same provisioning technique used by real cloud providers, and was chosen deliberately as a stepping stone toward the later Terraform project (Project 17), which automates this exact flow end-to-end.

## Step by step (installation and configuration)

### Stage 1 — Create the VM in Proxmox

Download the Ubuntu 24.04 cloud image (once per node):

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

Create the VM (final corrected form — using the real `local-zfs` storage pool, not `local-lvm`, and tagging VLAN 20 on the `vmbr1` trunk):

```bash
qm create 113 \
  --name hr1 \
  --memory 6144 \
  --cores 4 \
  --net0 virtio,bridge=vmbr1,tag=20 \
  --scsihw virtio-scsi-pci \
  --ostype l26

qm importdisk 113 /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img local-zfs

qm set 113 --scsi0 local-zfs:vm-113-disk-0
qm set 113 --boot order=scsi0
qm set 113 --ide2 local-zfs:cloudinit
qm resize 113 scsi0 60G
```

Configure cloud-init (static network, user, SSH):

```bash
qm set 113 --ipconfig0 ip=10.0.20.90/24,gw=10.0.20.1
qm set 113 --nameserver 10.0.20.10
qm set 113 --ciuser sadmin
qm set 113 --cipassword 'CHANGE_THIS_PASSWORD'
qm set 113 --sshkeys ~/.ssh/authorized_keys
qm set 113 --onboot 1
qm set 113 --agent enabled=1
qm start 113
```

Once booted:

```bash
sudo timedatectl set-timezone Europe/Rome
sudo apt update && sudo apt upgrade -y
```

### Stage 2 — Docker CE + Docker Compose + Harbor 2.15.1

Install Docker CE:

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker sadmin
```

Download the Harbor installer:

```bash
cd /opt
wget https://github.com/goharbor/harbor/releases/download/v2.15.1/harbor-online-installer-v2.15.1.tgz
tar -xzf harbor-online-installer-v2.15.1.tgz
cd harbor
cp harbor.yml.tmpl harbor.yml
```

> Note: the installer was initially extracted under `/tmp/harbor`, then moved to `/opt/harbor` for persistence — `/tmp` is cleared on many distros at boot, which would silently break the running installation on next reboot.

Generate the TLS certificate signed by the internal CA (same pattern as `glpi1`):

```bash
sudo mkdir -p /etc/ssl/hr1
cd /etc/ssl/hr1

sudo tee hr1.cnf > /dev/null <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = hr1.pymesis.lab
O = pymesis.lab

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = hr1.pymesis.lab
DNS.2 = hr1
IP.1 = 10.0.20.90
EOF

sudo openssl req -new -newkey rsa:2048 -nodes \
  -keyout hr1.key -out hr1.csr -config hr1.cnf -extensions req_ext
```

Issued from `dc1` (same procedure as `glpi1`):

```powershell
certreq -submit -attrib "CertificateTemplate:WebServer" hr1.csr hr1.cer
```

`hr1.cer` and `pymesis-ca.crt` were copied back to `/etc/ssl/hr1/` on the VM.

Edit `harbor.yml`:

```yaml
hostname: hr1.pymesis.lab

https:
  port: 443
  certificate: /etc/ssl/hr1/hr1.cer
  private_key: /etc/ssl/hr1/hr1.key

harbor_admin_password: CHANGE_THIS_PASSWORD

database:
  password: CHANGE_THIS_DB_PASSWORD

data_volume: /data
```

```bash
sudo mkdir -p /data
cd /opt/harbor
sudo ./install.sh --with-trivy
```

A successful run ends with:

```
✔ ----Harbor has been installed and started successfully.----
```

### Stage 3 — Trust store, login, project, and robot account

Install the CA root in the host's trust store (needed for `docker login`/`docker push` against `hr1` to succeed, both locally and from any other host that will push):

```bash
sudo cp /etc/ssl/hr1/pymesis-ca.crt /usr/local/share/ca-certificates/pymesis-ca.crt
sudo update-ca-certificates
```

Verify all containers are up:

```bash
sudo docker compose -f /opt/harbor/docker-compose.yml ps
```

`harbor-core`, `harbor-db`, `registry`, `harbor-jobservice`, `trivy-adapter`, `redis`, `nginx`, `harbor-portal`, etc. should all show `Up (healthy)`.

Logged into `https://hr1.pymesis.lab` as `admin`, then:

- **Projects → New Project** → name `pymesis`, Private, "scan images on push" enabled (Trivy).
- **Robot Accounts → New Robot Account** (inside project `pymesis`) → name `gitea-ci`, project-level, permissions `push` + `pull` only, 1-year expiration.

Harbor's generated Docker login format:

```bash
docker login hr1.pymesis.lab -u 'robot$gitea-ci' -p '<TOKEN>'
```

> Note: the actual robot account username Harbor generates was `robot$gitea-ci`, not `robot$pymesis+gitea-ci` as initially assumed — this needs to be verified directly in the Harbor UI, since the exact format depends on the Harbor version/configuration.

### Stage 4 — Gitea Actions + Gitea Runner (formerly act_runner)

> Note: the `act_runner` project was renamed to **Gitea Runner** (`gitea/runner` image) — documentation and defaults referencing `act_runner` are outdated for this version.

Enable Actions in Gitea (running in Docker on `lx1`):

```bash
docker exec -it gitea sh -c 'cat >> /data/gitea/conf/app.ini <<EOF
[actions]
ENABLED = true
EOF'
docker restart gitea
```

Copy the runner registration token from **Site Administration → Actions → Runners** in the Gitea UI.

Build a custom runner image that includes CA trust and the Docker CLI (the official `gitea/runner` image is Alpine-based and does not ship `ca-certificates` by default):

```bash
mkdir -p ~/docker/gitea-runner
cd ~/docker/gitea-runner
cp /usr/local/share/ca-certificates/pymesis-ca.crt .

cat > Dockerfile <<'EOF'
FROM gitea/runner:2.0.1
RUN apk add --no-cache ca-certificates
COPY pymesis-ca.crt /usr/local/share/ca-certificates/pymesis-ca.crt
RUN update-ca-certificates
EOF
```

`docker-compose.yml`:

```yaml
services:
  gitea-runner:
    build: .
    container_name: gitea-runner
    restart: unless-stopped
    environment:
      GITEA_INSTANCE_URL: "https://gitea.pymesis.lab"
      GITEA_RUNNER_REGISTRATION_TOKEN: "<REGISTRATION_TOKEN>"
      GITEA_RUNNER_NAME: "lx1-runner"
      GITEA_RUNNER_LABELS: "ubuntu-latest:docker://pymesis-ci-base:latest"
      CONFIG_FILE: /data/config.yaml
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
```

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

Expected: `runner: lx1-runner, with version: v2.0.1, with labels: [ubuntu-latest], declare successfully`.

Build a custom job-execution image (`pymesis-ci-base`), since the default `node:20-bullseye` job image also lacks CA trust and the Docker CLI needed for `docker login`/`build`/`push` inside the workflow:

```bash
mkdir -p ~/docker/gitea-runner/ci-base
cp /usr/local/share/ca-certificates/pymesis-ca.crt ci-base/

cat > ci-base/Dockerfile <<'EOF'
FROM node:20-bullseye

RUN apt-get update && \
    apt-get install -y ca-certificates curl gnupg && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

COPY pymesis-ca.crt /usr/local/share/ca-certificates/pymesis-ca.crt
RUN update-ca-certificates
EOF

cd ~/docker/gitea-runner/ci-base
docker build -t pymesis-ci-base:latest .
```

Trust the CA at the **Docker daemon level** on `lx1` (independent from both the runner image and the OS trust store — Docker resolves per-registry trust from `/etc/docker/certs.d/`):

```bash
sudo mkdir -p /etc/docker/certs.d/hr1.pymesis.lab
sudo cp /usr/local/share/ca-certificates/pymesis-ca.crt /etc/docker/certs.d/hr1.pymesis.lab/ca.crt
```

Load the robot account credentials as Gitea repo secrets (**Settings → Actions → Secrets**):

| Name | Value |
|---|---|
| `HARBOR_USER` | `robot$gitea-ci` |
| `HARBOR_TOKEN` | token generated when creating the robot account |

Demo repo (`demo-harbor-ci`) — minimal Python/Flask app used to trigger the first build:

`app.py`:
```python
from flask import Flask
app = Flask(__name__)

@app.route("/")
def hello():
    return "Hello from pymesis.lab — build via Gitea Actions + Harbor\n"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

`requirements.txt`:
```
flask==3.0.3
```

`Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 5000
CMD ["python", "app.py"]
```

`.gitea/workflows/build.yml`:
```yaml
name: build-and-push
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Login to Harbor
        run: echo "${{ secrets.HARBOR_TOKEN }}" | docker login hr1.pymesis.lab -u '${{ secrets.HARBOR_USER }}' --password-stdin

      - name: Build image
        run: |
          docker build -t hr1.pymesis.lab/pymesis/demo:${{ gitea.sha }} .
          docker tag hr1.pymesis.lab/pymesis/demo:${{ gitea.sha }} hr1.pymesis.lab/pymesis/demo:latest

      - name: Push to Harbor
        run: |
          docker push hr1.pymesis.lab/pymesis/demo:${{ gitea.sha }}
          docker push hr1.pymesis.lab/pymesis/demo:latest
```

```bash
git init
git add .
git commit -m "Initial demo: build and push to Harbor via Gitea Actions"
git branch -M main
git remote add origin https://gitea.pymesis.lab/admin/demo-harbor-ci.git
git push -u origin main
```

### Stage 5 — Monitoring + Backup for `hr1`

Zabbix Agent 2 (Ubuntu repo, not Debian):

```bash
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-2+ubuntu24.04_all.deb
sudo dpkg -i zabbix-release_7.0-2+ubuntu24.04_all.deb

sudo apt update
sudo apt install -y zabbix-agent2

sudo sed -i 's/^Server=.*/Server=10.0.20.60/' /etc/zabbix/zabbix_agent2.conf
sudo sed -i 's/^ServerActive=.*/ServerActive=10.0.20.60/' /etc/zabbix/zabbix_agent2.conf
sudo sed -i 's/^Hostname=.*/Hostname=hr1/' /etc/zabbix/zabbix_agent2.conf
sudo systemctl enable --now zabbix-agent2
```

Wazuh agent:

```bash
curl -so wazuh-agent.deb https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_<version>_amd64.deb
sudo WAZUH_MANAGER='10.0.20.60' dpkg -i ./wazuh-agent.deb
sudo systemctl daemon-reload
sudo systemctl enable --now wazuh-agent
```

Restic backup — what's kept: not the images themselves (rebuildable from Gitea via CI), but the **configuration and database** (projects, users, robot accounts, policies), plus `/data` to avoid losing the registry contents if CI is unavailable at restore time:

```bash
sudo mkdir -p /opt/docker_dumps
sudo chown sadmin:sadmin /opt/docker_dumps

sudo tee /opt/docker_dumps/dump_harbor.sh > /dev/null <<'EOF'
#!/bin/bash
cd /opt/harbor
docker compose exec -T harbor-db pg_dumpall -U postgres > /opt/docker_dumps/harbor_db_$(date +%F).sql
find /opt/docker_dumps -name "harbor_db_*.sql" -mtime +7 -delete
EOF
sudo chmod +x /opt/docker_dumps/dump_harbor.sh
sudo chown sadmin:sadmin /opt/docker_dumps/dump_harbor.sh
```

Cron (Sunday, following the fleet-wide backup convention; repo path follows the standard `sftp:sadmin@bk1:/mnt/backups/repos/<hostname>` convention):

```bash
sudo crontab -u sadmin -e
```
```
45 2 * * 0 /opt/docker_dumps/dump_harbor.sh
0 3 * * 0 restic -r sftp:sadmin@10.0.20.50:/mnt/backups/repos/hr1 backup \
  /etc/ssl/hr1 /opt/harbor/harbor.yml /opt/docker_dumps /data --tag hr1
0 3 * * 0 restic -r sftp:sadmin@10.0.20.50:/mnt/backups/repos/hr1 forget --keep-weekly 4 --keep-monthly 6 --prune
```

```bash
restic -r sftp:sadmin@10.0.20.50:/mnt/backups/repos/hr1 init
```

The `gitea-runner` project directory (compose, Dockerfile, `ci-base/`, `data/config.yaml`, `data/.runner`) lives entirely under `/home/sadmin/`, which is already covered by `lx1`'s general Restic backup path (`/etc /home /opt /var/log`) — no dedicated backup entry was needed for it, since it uses a bind mount (`./data:/data`) rather than a named Docker volume.

## Problems encountered and how they were resolved

- **Storage pool / VLAN mismatch in the initial `qm create` command**: the first draft used `local-lvm` (nonexistent on this node — the real pool is `local-zfs`) and omitted the VLAN tag on `vmbr1` (a trunk requiring an explicit `tag=20`). Corrected before creating the VM; the partially-created VM was destroyed and recreated (`qm stop 113; qm destroy 113 --purge`).

- **SSH host key warning after VM recreate**: destroying and recreating VMID 113 generated a new SSH host key, which the Windows management client still had cached under the old fingerprint — expected behavior, not a security incident. Resolved with `ssh-keygen -R 10.0.20.90` followed by a fresh connection.

- **SSH key injection resolved on the wrong host**: `qm set 113 --sshkeys ~/.ssh/authorized_keys` was run on the Proxmox host (`pve1`), so it injected `root@pve1`'s public key rather than the Windows management client's key — `ssh` was rejected with `Permission denied (publickey)`. Diagnosed via console login (password) and `ssh -v` to compare fingerprints. Resolved by manually pasting the correct Windows-generated `id_ed25519.pub` into `hr1`'s `~/.ssh/authorized_keys`.

- **Typo corrupting the injected key**: the key type was mistakenly written as `ssh-e25519` instead of `ssh-ed25519`, causing `sshd` to silently discard the line. Found via `ssh-keygen -lf ~/.ssh/authorized_keys` (fingerprint mismatch/no output) and fixed by rewriting the file cleanly with the exact key from `id_ed25519.pub`.

- **`install.sh` path confusion**: the Harbor installer extracts into a `harbor/` subdirectory of wherever `tar -xzf` was run, so referencing `/tmp/harbor/harbor/...` was a duplicated path — the real path was `/tmp/harbor/` (later moved to `/opt/harbor/` for persistence, since `/tmp` clears on reboot on many distros).

- **VM rename (`harbor1` → `hr1`) left stale references**: after adopting the fleet's short-name convention, the certificate CN/SAN, `harbor.yml` hostname/cert paths, the Gitea workflow, and the Docker daemon's per-registry trust directory all still referenced `harbor1.pymesis.lab`. All of these had to be regenerated/corrected consistently before the install would succeed with the right identity.

- **`gitea-runner` image (Alpine) lacked `ca-certificates`**: `docker cp` of the CA into the running container failed because the target directory didn't exist, and even after creating it, the fix didn't survive container recreation. Solved durably by building a custom Dockerfile extending `gitea/runner` with `ca-certificates` installed and the CA copied in at build time.

- **Runner labels silently overridden**: `generate-config` produced a `config.yaml` with its own default `labels:` list (pointing at `docker.gitea.com/runner-images`), which took precedence over the `GITEA_RUNNER_LABELS` environment variable, causing the runner to keep using the official upstream image instead of the custom `pymesis-ci-base`. Fixed by editing `config.yaml` directly and leaving only the intended label.

- **`act_runner` binary name confusion**: the project's binary was renamed to `gitea-runner` (not `act_runner`, and not a nameless `runner`), which caused `generate-config` invocations with the wrong `--entrypoint` to hang waiting for interactive input. Resolved by inspecting the image's actual entrypoint script (`/usr/local/bin/run.sh`) to find the correct binary name.

- **Job container had no CA trust or Docker CLI**: the ephemeral container used to run workflow steps (`node:20-bullseye`, later `pymesis-ci-base`) is separate from the runner's own container and does not inherit its CA trust. `git fetch` against `gitea.pymesis.lab` failed with `server certificate verification failed`. Solved with the custom `pymesis-ci-base` image (CA + Docker CLI baked in).

- **Docker daemon-level TLS trust is separate from the OS trust store**: after fixing the job image, `docker login` against `hr1.pymesis.lab` still failed with `x509: certificate signed by unknown authority` — because commands run through the mounted `/var/run/docker.sock` are actually executed by `lx1`'s **host** Docker daemon, which has its own certificate trust mechanism per registry (`/etc/docker/certs.d/<registry>/ca.crt`), independent of both the container's and the OS's trust stores. Fixed by placing the CA there on `lx1`.

- **Robot account username mismatch**: the assumed format `robot$pymesis+gitea-ci` returned `unauthorized`; the actual username Harbor generated was `robot$gitea-ci`. Confirmed by checking the exact string in the Harbor UI and updating the `HARBOR_USER` Gitea secret accordingly.

- **Workflow file created outside the git repository**: `.gitea/workflows/build.yml` was initially created while the shell was in `~` (home) rather than inside the cloned repo directory, so `git add` failed with `not a git repository`. Fixed by moving the file into the correct repo path before committing.

- **Post-reboot "connection refused"**: after manually powering the VM off and back on, Harbor was briefly unreachable in the browser. Root cause was simply the healthcheck startup sequence (DB → core → jobservice → nginx) not yet complete — not a configuration issue. Docker itself was already enabled to start on boot (`systemctl is-enabled docker` → `enabled`), and all containers came up `healthy` within ~30–40 seconds. No further action was required.

## Final result / objectives achieved

Harbor + CI/CD closed as fully functional and verified end-to-end:

- Private container registry (`hr1.pymesis.lab`) with TLS issued by the internal CA (`pymesis-DC01-CA`).
- Automatic vulnerability scanning on push via the bundled Trivy scanner (verified working — a real scan against `python:3.12-slim` returned 174 findings, 6 fixable, confirming the pipeline surfaces genuine supply-chain security data rather than a passthrough).
- A dedicated robot account (`robot$gitea-ci`) scoped to push/pull only on the `pymesis` project — no automated process uses the `admin` account.
- Gitea Actions CI/CD pipeline (`checkout → login → build → push`) running on a custom-built runner and job image, fully working end-to-end.
- Dual monitoring (Zabbix Agent 2 + Wazuh) and weekly Restic backup (config, TLS material, Postgres dump, `/data`), verified with a real snapshot in the corrected repository path.

This closes the Harbor + CI/CD project scope. It stands as one of the more troubleshooting-heavy projects in the lab (TLS trust resolved independently at three separate layers — OS trust store, runner image, and Docker daemon — plus runner labeling and credential mismatches), which itself is useful evidence of real-world CI/CD debugging experience.

## Cross-references

- [Project 4 — Ubuntu 22.04 + Docker + Nginx (`lx1`)](./04-lx1-docker.md): hosts Gitea and the Gitea Runner container that drives this pipeline.
- [Project 5.1 — Restic backup architecture](./05-1-restic-architecture.md): fleet-wide backup conventions applied to `hr1`.
- [Project 10 — GLPI (ITSM)](./10-glpi.md): source of the certificate-issuance and agent-installation patterns reused here.
- [Project 13 — eShop (Medusa, `es1`)](./13-eshop-medusa.md) and [Project 15 — K3s (`k3s1`)](./15-k3s.md): later projects that can push/pull images through this registry.
- [Project 17 — Terraform/IaC](./17-terraform.md): automates the same cloud-image + cloud-init VM provisioning pattern used manually here.
