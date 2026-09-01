---
title: 01-1-ordered-shutdown-script
description: shutdown
published: 1
date: 2026-09-01T17:18:24.138Z
tags: 
editor: markdown
dateCreated: 2026-08-27T16:53:35.022Z
---

# Project 1.1 — Ordered Shutdown Script on Proxmox (pve1)

**Previous:** [Project 1 — Proxmox VE 8.4.1 (pve1)](01-proxmox-ve-installation.md)
**Next:** [Project 2 — OPNsense (fw1)](02-opnsense-installation.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Build, from `pve1`, an interactive script that allows the homelab to be shut down safely and in order — acting as a software "Smart UPS" stand-in until a physical UPS is available — offering three modes: shut down a single VM/LXC, shut down all of them in parallel, or shut them all down in dependency order followed by the Proxmox host itself.

## Context

At this point the lab didn't yet have a UPS (an APC Back-UPS Pro 1500VA, planned for later), so a power outage meant manually shutting everything down VM by VM. A best-practices question also came up: whether it's worth manually stopping services or database engines (PostgreSQL on `db1`, MariaDB on `glpi1`, SQL Server Express on `app1`, Odoo on `odoo1`/`odoo2`) before shutting down the OS, or whether a normal OS shutdown is enough.

## Decisions Made and Rationale

**On stopping services/databases before OS shutdown:**

A normal OS shutdown is enough in the vast majority of cases, because `systemd` (Linux) and the SCM (Windows) stop services in reverse startup order while respecting dependencies, and modern engines (PostgreSQL, MariaDB, SQL Server) have an `ExecStop`/equivalent that performs a clean stop with a checkpoint before closing — as long as the service is managed by systemd/SCM (not running loose via `nohup`), the shutdown timeout is enough for the checkpoint (systemd's default `TimeoutStopSec=90s` is more than enough at this homelab's scale), and there are no long-running hung transactions. The real exception found was **Docker**: by default it only gives 10 seconds of grace before killing a container, which is short compared to everything else — hence the decision to add an explicit pre-stop step with more headroom for the hosts running Docker stacks (`lx1`, `hr1` — formerly `harbor1` — and `llm1`).

**On the shutdown script itself:**

- Uses `qm shutdown` (not `qm stop`) for VMs — triggers a real shutdown inside the OS via the QEMU Guest Agent, equivalent to pressing the power button, not cutting the power.
- Uses `pct shutdown` for LXCs — `qm shutdown` doesn't work for containers. The script includes a `resolve_type_and_id()` function that automatically detects whether a name corresponds to a VM (`qm list`) or an LXC (`pct list`), so the user doesn't need to specify the type each time.
- **Docker pre-stop**: before the OS shutdown on `lx1`, `hr1`, and `llm1`, the script SSHes in and runs `sudo docker stop -t 30 $(docker ps -q)` (30s grace per container). This is "best effort": if the SSH connection fails, it's logged but the script proceeds with the normal OS shutdown without blocking the process.
- **Defined shutdown order** (mode 3, all in order + shut down the host): `cl1`/`cl2` first (workstations — this way, if someone is logged in, the Windows shutdown notice gives them time) → `odoo2` → `glpi1` → `hr1` → `llm1` → `lx1` → `app1` → `odoo1` → `fs1` → `mon1` → `bk1` → `db1` → `dc2` → `dc1`. The logic: `odoo1` shuts down before `db1` because it depends on it, and the Domain Controllers are left for last in case anything still needs DNS/Kerberos resolution while the rest shuts down.
- **Timeout without automatic force**: if a VM/LXC doesn't confirm shutdown within the timeout (120s by default), the script warns and asks whether to proceed before bringing down the host — deliberately not performing an automatic forced `qm stop`, leaving the decision to force or investigate what's stuck in the user's hands.
- **Security of the SSH access used by the script**: instead of reusing `pve1`'s `root` account with full access to `sadmin` on the Docker hosts, a **dedicated key + forced command + scoped sudoers** scheme was implemented, so that if that key were ever leaked or the script had a bug, the only thing it could do is stop Docker containers — nothing else (no shell, no other commands, no generic sudo).

## Step-by-Step

### 1. Initial version of the script

First version of `pymesis-shutdown.sh`, designed for `pve1`, with a 3-option menu (single VM / all in parallel / all in order + shut down host), using `qm shutdown` with the dependency order defined above.

### 2. VM vs. LXC correction and Docker addition

After confirming the actual VM inventory (`fw1, dc1, dc2, fs1, lx1, bk1, cl1, cl2, app1, odoo1, db1, mon1, hr1`) and LXC inventory (`glpi1, odoo2, llm1, es1`), the script was updated to:

- Automatically detect VM/LXC type (`resolve_type_and_id()`).
- Add the Docker pre-stop (30s grace) on `lx1`, `hr1`, `llm1`.

### 3. Hardening the script's SSH access (dedicated key + forced command)

**a. Generate a dedicated SSH key on `pve1`** (do not reuse root's key):
```bash
ssh-keygen -t ed25519 -f /root/.ssh/pymesis_shutdown -N "" -C "pve1-shutdown-script"
```

**b. On each Docker host (`lx1`, `hr1`, `llm1`), create a fixed script that performs the stop:**
```bash
sudo tee /usr/local/bin/docker-graceful-stop.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONTAINERS=$(docker ps -q)
if [[ -n "$CONTAINERS" ]]; then
  docker stop -t 30 $CONTAINERS
fi
EOF
sudo chmod 750 /usr/local/bin/docker-graceful-stop.sh
sudo chown root:sadmin /usr/local/bin/docker-graceful-stop.sh
```

**c. Scoped sudoers — this script only, no password:**
```bash
echo 'sadmin ALL=(root) NOPASSWD: /usr/local/bin/docker-graceful-stop.sh' | sudo tee /etc/sudoers.d/pymesis-shutdown
sudo chmod 440 /etc/sudoers.d/pymesis-shutdown
sudo visudo -c
```

**d. Install the public key with a forced command in `~sadmin/.ssh/authorized_keys`:**
```bash
mkdir -p ~sadmin/.ssh
cat >> ~sadmin/.ssh/authorized_keys << 'EOF'
command="sudo /usr/local/bin/docker-graceful-stop.sh",no-pty,no-agent-forwarding,no-X11-forwarding <public key AAAA...>
EOF
chmod 700 ~sadmin/.ssh
chmod 600 ~sadmin/.ssh/authorized_keys
chown -R sadmin:sadmin ~sadmin/.ssh
```

The `command=` directive is the key part: no matter what command is sent over SSH with that key, the server always runs `sudo /usr/local/bin/docker-graceful-stop.sh` and nothing else; the other options (`no-pty`, `no-agent-forwarding`, `no-X11-forwarding`) close off any other use of that session.

**e. Test from `pve1`:**
```bash
ssh -i /root/.ssh/pymesis_shutdown sadmin@10.0.20.40   # lx1
ssh -i /root/.ssh/pymesis_shutdown sadmin@10.0.20.90   # hr1
ssh -i /root/.ssh/pymesis_shutdown sadmin@10.0.20.91   # llm1
```

Steps b–d were repeated on all three hosts, and the script was updated to use this dedicated key with `BatchMode=yes` (fails fast if anything goes wrong, instead of hanging waiting for a password).

### 4. Auditing and defining a symmetric boot order

After confirming the shutdown worked, the `onboot` flag on each VM/LXC was audited, and (as a proposal, using Proxmox's native `--startup order=N,up=Xs` mechanism) a boot order mirroring the shutdown order was defined: `fw1` first → `dc1`/`dc2` → `db1` → `fs1`/`mon1`/`bk1`/`app1`/`odoo1` → `hr1`/`llm1`/`glpi1`/`lx1`/`odoo2`/`es1`, leaving `cl1`/`cl2` on manual (`onboot=0`).

## Problems Solved

- **Initial LXC vs. VM confusion**: the first version of the script assumed everything was handled with `qm shutdown`. This was corrected after confirming the actual inventory (LXCs: `glpi1`, `odoo2`, `llm1`, `es1`) and adding automatic type detection instead of requiring the user to specify it.
- **`Connection timed out` when testing SSH to `10.0.20.40` (`lx1`)**: root cause — `pve1` only lived on the physical/management network (`192.168.68.10`), while `lx1`, `hr1`, and `llm1` live on VLAN20 (`10.0.20.0/24`), a separate network the VMs reach because `vmbr1` tags traffic per VM, but the host `pve1` itself had no interface on that VLAN. **Solution applied**: add a `vmbr1.20` sub-interface on `pve1` with IP `10.0.20.9/24` (taking advantage of `vmbr1` already being `bridge-vlan-aware yes` with `bridge-vids 2-4094`, so there was no need to touch the firewall or the physical switch — it's internal bridge traffic). It was applied with `ifreload -a`, after weighing the risk of losing SSH management access if something went wrong (as an alternative, the more surgical `ifup vmbr1.20` was considered to avoid reloading the entire network config, given the lack of a physical/BMC console as a fallback). This IP (`10.0.20.9`) ended up becoming `pve1`'s permanent management IP within VLAN20.
- **`PTY allocation request failed on channel 0` message when testing the connection**: not an error — this is expected given `no-pty` in `authorized_keys`. The SSH client requests an interactive terminal by default, the server rejects it but still runs the forced command (`docker-graceful-stop.sh`) before closing the connection.
- **Real production test**: the first test against `lx1` was not a simulation — it actually stopped the Docker containers running at the time (Portainer, WikiJS, Gitea, Uptime Kuma, Nginx, the Gitea Actions runner). Status was verified with `docker ps -a` and containers were brought back up with `docker compose up -d` in each subfolder under `~/docker/`.
- **"Odd" behavior after restarting Node 1**: after a full shutdown/startup cycle, it was observed that the LXCs started up on their own while most VMs stayed off. Cause: each VM/LXC has an individual `onboot` flag ("Start at boot") independent of the rest; the LXC creation wizard in Proxmox has it checked by default in several versions, while the VM wizard has it unchecked by default — which is why `glpi1`, `odoo2`, `llm1`, and `es1` inherited `onboot=1` without it being explicitly requested, while among the VMs only `hr1` had it enabled.

## Final Result

- `pymesis-shutdown.sh` script operational on `pve1`, with 3 usage modes, automatic VM/LXC detection, extended-grace Docker pre-stop (30s) on the hosts that need it, and a timeout with manual confirmation before forcing any shutdown.
- The script's SSH access hardened via dedicated key + forced command + scoped sudoers on `lx1`, `hr1`, and `llm1` — blast radius reduced to "stop Docker containers," nothing more.
- `pve1`'s management interface extended into VLAN20 (`10.0.20.9/24`) over `vmbr1.20`, allowing the hypervisor itself to directly manage hosts on that VLAN without depending on the firewall.
- `onboot` audit completed and a symmetric boot-order proposal documented (applying it with real VMIDs/CTIDs was left as an open task at the end of this session).

## Cross-References

- This project depends directly on [Project 1 — Proxmox VE Installation](01-proxmox-ve-installation.md), which it builds on.
- The `sadmin` + restricted-SSH-key access convention used here is the same one later generalized as the lab's standard (see conventions in the [lab index](00-pymesis-lab-index.md)).

---

[← **Previous:** Project 1 — Proxmox VE 8.4.1 (pve1)](01-proxmox-ve-installation.md) | [**Next:** Project 2 — OPNsense (fw1) →](02-opnsense-installation.md)