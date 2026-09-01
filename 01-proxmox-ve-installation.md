---
title: 01-proxmox-ve-installation
description: proxmox-ve
published: 1
date: 2026-09-01T17:18:35.082Z
tags: 
editor: markdown
dateCreated: 2026-08-27T16:52:28.360Z
---

# Project 1 — Proxmox VE 8.4.1 Installation (node1)

**Previous:** — (first project in the lab)
**Next:** [Project 1.1 — Ordered Shutdown Script (pve1)](01-1-ordered-shutdown-script.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Install and bring Proxmox VE 8.4.1 into production as the base hypervisor for Node 1 of the pymesis.lab homelab, laying down the stable 24/7 infrastructure on top of which the rest of the lab's VMs and LXCs would be progressively installed.

## Context

This was the starting point of the entire lab. At the time, only one GMKtec K8 Plus mini PC (64GB RAM, 1TB NVMe) was available — the rest of the planned hardware (a second mini PC, Ugreen DXP4800 NAS, MikroTik CRS310 switch, UniFi U7 Pro AP, APC UPS) hadn't been purchased yet. Internet connectivity came through a TP-Link X3000-5G router on `192.168.68.1/24`.

Before starting, a blueprint/roadmap was defined with two planned nodes:

- **Node 1 — Stable 24/7 infrastructure** (the one built in this project): FW01, DC01, DC02, FS01, BACKUP01, LINUX01.
- **Node 2 — Heavy workloads / labs** (pending hardware): APP01, ODOO01, ODOO-DB01, MON01, KALI, VULN, CLIENT01/CLIENT02.

*(Note: several of these roles were later renamed following the lab's short-naming convention — e.g., LINUX01 → `lx1`, BACKUP01 → `bk1` — see the [lab conventions](00-pymesis-lab-index.md).)*

## Decisions Made and Rationale

- **ZFS RAID0 filesystem** on the single 1TB NVMe available, with `ashift=12` (optimal alignment for SSD/NVMe), `compress=on`, `checksum=sha256`, and `copies=1`. RAID0 was the only option with a single physical disk (no redundancy possible); ZFS was still preferred for its snapshot and checksum capabilities.
- **UEFI + Secure Boot disabled**: Proxmox doesn't require Secure Boot, and disabling it simplifies loading unsigned modules/drivers (relevant later for OVMF/UEFI on guest VMs).
- **AMD-V/SVM and IOMMU enabled in BIOS**: hardware virtualization is mandatory, and IOMMU was enabled from the start to leave the door open for PCI device passthrough later if needed.
- **Two separate network bridges from the initial design**: `vmbr0` as WAN (physical uplink to the TP-Link router, Proxmox's management IP) and `vmbr1` as the internal LAN for VMs — a deliberate separation between the hypervisor's management network and the server/VM network, even knowing that with a single physical NIC `vmbr1` would initially work only as an internal bridge (no physical uplink) until the MikroTik CRS310 switch arrived with a second NIC.
- **Repositories**: the Enterprise repos (PVE and Ceph, which require a paid subscription) were disabled, and the `pve-no-subscription` repo was enabled — suitable for homelab use without a commercial license.

## Step-by-Step

### Phase 1 — Pre-installation preparation

1. Download the Proxmox VE 8.4.1 ISO from the official site.
2. Create a bootable USB in **DD Image** mode (not ISO mode) — using `dd` on Linux/Mac or Rufus/Balena Etcher on Windows.

### Phase 2 — BIOS/UEFI (GMKtec K8 Plus)

Enter with `DEL` or `F2` on boot and configure:

| Parameter | Value |
|---|---|
| CPU AMD-V / SVM | Enabled (on this model, under *Advanced → CPU Configuration → SVM Mode*) |
| IOMMU Virtualization | Enabled |
| Secure Boot | Disabled |
| Boot Mode | UEFI |
| Boot Order | USB first |

### Phase 3 — Proxmox VE Installation

1. Boot from USB → *Install Proxmox VE (Graphical)* → accept EULA.
2. **Disk/filesystem**: ZFS (RAID0) on the 1TB NVMe; under *Options*: `ashift=12`, `compress=on`, `checksum=sha256`, `copies=1`.
3. **Localization**: country, timezone, and keyboard as applicable.
4. **Password & email** for root.
5. **Network** (critical step): hostname `pve1.pymesis.lab`, IP `192.168.68.10/24`, gateway `192.168.68.1`, DNS `1.1.1.1`.
6. Install, wait ~5-10 minutes, remove the USB on reboot.

### Phase 4 — Post-installation

1. Access the WebUI at `https://192.168.68.10:8006` (user `root`), ignoring the browser's SSL warning for the self-signed certificate.
2. Verify version: `pveversion` → should show `pve-manager/8.4.1`.
3. Disable the Enterprise repos by commenting out the corresponding line in `/etc/apt/sources.list.d/pve-enterprise.list` and `/etc/apt/sources.list.d/ceph.list`.
4. Enable the no-subscription repo in `/etc/apt/sources.list.d/pve-no-subscription.list`:
   ```
   deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
   ```
5. Fully update the system: `apt update && apt full-upgrade -y && reboot`.

### Phase 5 — Configure network (vmbr0 + vmbr1)

From *Datacenter → pve1 → Network → Create → Linux Bridge*:

- **`vmbr0`** (already exists post-install): IP `192.168.68.10/24`, gateway `192.168.68.1`, bridged over the main physical NIC (`enp3s0`) — WAN/uplink role to the TP-Link router.
- **`vmbr1`** (new): no IP, no gateway, no physical bridge assigned yet — internal LAN role between VMs. It remains a purely internal bridge until the MikroTik CRS310 switch arrives and a second physical NIC is assigned to it.

Apply with `ifreload -a` or reboot from the WebUI.

### Phase 6 — Final verification

```bash
ip a
brctl show
pvesh get /nodes/pve1/status
zpool status
```

Confirm in the WebUI: `pve1` shows *Online*, `local` storage (ZFS) is available, no errors in the *Summary*.

## Problems Solved and Later Decisions

Once Node 1 already had its first VMs installed and configured (`fw1`, `dc1`, `dc2`, `fs1`, `app1`, `lx1`, `odoo1`, `db1`, `mon1`, `bk1`, `cl1`, `cl2`), the need arose to define the Proxmox host's own backup policy — which ended up being part of this same project:

- **Backup vs. Snapshot**: both options were evaluated. A ZFS *snapshot* is a fast restore point but lives on the same pool/node and doesn't replace a real backup; a *backup* (`vzdump`) produces an exportable file (`.vma.zst`) that can be restored on any Proxmox node. **Decision**: use scheduled monthly `vzdump` as the primary host-level backup mechanism, keeping ZFS snapshots as a manual complement before major changes on a specific VM.
- **Prerequisite — QEMU Guest Agent**: to enable *hot* backups (`snapshot` mode, no downtime), the QEMU Guest Agent was confirmed/installed on all VMs (the `qemu-guest-agent` package on Linux, VirtIO Guest Tools on Windows, a native option on OPNsense).
- **UI confusion — storage "Content" field**: when creating the backup storage (`Datacenter → Storage → Add → Directory`, id `backup-local`, path `/var/lib/vz/backups`), there was initial confusion thinking the *Content* field was free text; it's actually a dropdown, and "Backup" is already correctly selected with nothing to type.
- **"Keep all backups" enabled by default**: this flag overrides any retention limit and would eventually fill up the NVMe. Fixed by unchecking it and setting `Keep Last: 2` (or `Keep Monthly: 2`), so the oldest backup is automatically removed once the third monthly backup runs.
- **"Backup Now" button inactive**: this was because the button only becomes active once a backup *job* exists under `Datacenter → Backup`. The correct flow is to create the job first (even with a monthly schedule) and then use "Run now" on that job, or alternatively trigger a one-off backup from each VM individually (`pve1 → [VM] → Backup → Backup Now`) without needing a prior job.
- **Timezone correction**: `America/Bogota` had initially been assumed as the VMs' timezone; this was corrected to the lab's actual timezone, `Europe/Rome`, applied consistently across all VMs/LXCs.
- **Deliberate exclusion of `cl1`/`cl2` from automatic backup**: as Windows 11 Pro workstations with no critical infrastructure role, they were excluded from the monthly `vzdump` job (they're also excluded from Zabbix, Wazuh, and Uptime Kuma for the same reason, per the lab's general notes).

## Final Result

- Proxmox VE 8.4.1 installed and operational on ZFS RAID0, with `vmbr0` (WAN/management) and `vmbr1` (internal LAN) configured.
- Repositories switched to no-subscription, system fully updated.
- `backup-local` storage (`/var/lib/vz/backups`) created to host `vzdump` backups.
- Monthly `vzdump` backup job created and active: *snapshot* mode, ZSTD compression, scheduled for the first Sunday of every month at 02:00 (`sun *-1..7 2:00`), retaining 2 copies per VM, covering VMs `100, 101, 102, 103, 104, 105, 108, 109, 110, 111`, and excluding `cl1`/`cl2`.
- QEMU Guest Agent confirmed active on all VMs.
- `Europe/Rome` timezone confirmed across all lab VMs.

## Cross-References

- The management sub-interface for `pve1` on VLAN20 (`10.0.20.9`), needed for the hypervisor itself to manage Docker hosts on that VLAN, was resolved as part of [Project 1.1 — Ordered Shutdown Script](01-1-ordered-shutdown-script.md).
- "Start at boot" (`onboot`) behavior and VM/LXC boot order were also addressed in Project 1.1, as the counterpart to shutdown order.

---

← **Previous:** — (first project in the lab) | [**Next:** Project 1.1 — Ordered Shutdown Script (pve1) →](01-1-ordered-shutdown-script.md)