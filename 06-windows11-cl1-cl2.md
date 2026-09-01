---
title: 06-windows11-cl1-cl2
description: windows11
published: 1
date: 2026-09-01T19:26:13.948Z
tags: 
editor: markdown
dateCreated: 2026-08-28T10:24:49.193Z
---

# Project 6 — Client Workstations | cl1, cl2 | VM | Domain Clients | Windows 11 Pro |

**Previous:** [Project 5.1 — Restic Backup Policies (bk1)](05-1-restic-backup-policies.md)
**Next:** [Project 7 — App Server (app1)](07-windows-server-app1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Install Windows 11 Pro on two workstation VMs, `cl1` and `cl2` (originally provisioned as `CLIENT01`/`CLIENT02`), and join both to the `pymesis.lab` domain — providing the lab's first client-side endpoints, distinct from the server VMs built so far.

## Context

`cl1`/`cl2` are blueprint VMs assigned to Node 2 (the second mini PC, not yet acquired at the time), but were built ahead of schedule on Node 1 to keep making progress, with the explicit understanding they'd be migrated later. Windows 11 Pro was required specifically (not Home) since domain join is a Pro-tier feature. The blueprint calls for these clients to live on VLAN10 via DHCP once the MikroTik CRS310 switch exists to create that VLAN; until then, they run on the same flat, untagged network as the server VMs.

## Decisions Made and Rationale

- **Built on Node 1 ahead of the blueprint's Node 2 assignment, with a planned future migration**: rather than waiting for the second GMKtec K8 Plus to arrive, both clients were created now on Node 1 to keep momentum, accepting that they'll need to move to Node 2 once it exists.
- **OOBE `BYPASSNRO` used to skip the "connect to the internet" requirement during first-run setup**: rather than requiring internet access during initial Windows configuration (or creating a Microsoft account), the trick of opening a command prompt via `Shift+F10` during OOBE and running `OOBE\BYPASSNRO` was used to reach the offline/domain-join setup path directly.
- **"Set up for work or school" → "Join a domain instead" chosen over a Microsoft personal account**: consistent with the lab's identity model — every machine authenticates against `pymesis.lab`, not a personal Microsoft account.
- **A temporary local account (`admin.local`) created during setup, later superseded by domain join**: needed to get through initial setup before the domain-join step could run.
- **Static IP evaluated but DHCP kept, once the real VLAN10 addressing was clarified**: the blueprint originally called for DHCP on VLAN10; a later fleet-alignment pass confirmed VLAN10 is `10.0.10.0/24`, with its DHCP scope actually served from `dc1` and relayed across VLANs via an OPNsense DHCP relay, rather than a per-client static assignment — so DHCP was kept as the final approach rather than switching to static addressing.
- **`cl1`/`cl2` deliberately excluded from Restic backups, and from Zabbix/Wazuh/Uptime Kuma monitoring**: judged during a fleet-alignment review to be the more realistic modeling choice for workstations — in real environments, corporate endpoints are typically monitored and managed by dedicated tools (Microsoft Intune, Defender for Endpoint, SCCM), not by server-oriented tools like Zabbix or Wazuh, and are not part of the server backup rotation. This also keeps `mon1`'s dashboards focused on servers and avoids diluting its resources on endpoint noise. If endpoint-security monitoring is simulated later, the natural path identified is a Wazuh agent on `cl1`/`cl2` specifically for that purpose — not a current priority.
- **Hybrid Azure AD Join and Intune/MDM identified as a future evaluation path, not pursued yet**: a Microsoft 365 30-day trial was floated as a way to experiment with hybrid identity (Entra ID Free + AD Connect) for `cl1`/`cl2`, but left as a documented pending item rather than implemented in this session.

## Step-by-Step

### Phase 1 — Download the Windows 11 ISO

Downloaded from Microsoft's official site (`Download Windows 11 Disk Image (ISO) for x64 devices`) and uploaded to Proxmox via `Datacenter → local → ISO Images → Upload`.

### Phase 2 — Create the VM in Proxmox

| Field | Value |
|---|---|
| VM ID | 201 (`cl1`) / 202 (`cl2`) |
| Name | CLIENT01 / CLIENT02 |
| ISO | `Windows11.iso` |
| OS Type | Microsoft Windows, version 11/2022/2025 |
| Machine / BIOS | `q35` / SeaBIOS |
| SCSI Controller | VirtIO SCSI Single, Qemu Agent enabled |
| Disk | SCSI, `local-zfs`, 60GB, Discard + SSD emulation enabled |
| CPU | 1 socket, 2 cores, type `host` |
| RAM | 4096 MB |
| Network | `vmbr1`, VirtIO, Firewall disabled |

"Start after created" was left unchecked, since VirtIO storage drivers needed to be attached before first boot.

### Phase 3 — Attach VirtIO drivers before booting

Windows 11 has no native VirtIO drivers, so the driver ISO was downloaded and mounted as a second optical drive before installation:
```bash
wget https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso \
  -O /var/lib/vz/template/iso/virtio-win.iso
```
Added via Hardware → Add → CD/DVD Drive (IDE, next available slot) → `virtio-win.iso`.

### Phase 4 — Install Windows 11

Boot the VM → language/region/keyboard as preferred → **Windows 11 Pro** edition (required for domain join) → "I don't have a product key" → **Custom: Install Windows only (advanced)**.

At the disk selection screen, no disk appears until the VirtIO storage driver is loaded manually: **Load driver** → Browse to the VirtIO CD → `vioscsi\w11\amd64` → select the driver → the 60GB disk appears → select it and continue. Installation copies files and reboots several times (~10–15 min).

### Phase 5 — Initial setup (OOBE)

Region and keyboard as preferred. For network connectivity during OOBE: if the VirtIO network driver loaded and Windows detects a network, connect normally; otherwise, open a command prompt with `Shift+F10` and run:
```
OOBE\BYPASSNRO
```
This reboots and allows continuing without an internet connection. Account setup: **"Set up for work or school"** → **"Join a domain instead"** → temporary local account `admin.local` created with a password matching the lab's password scheme. Privacy screens configured with unneeded options disabled.

### Phase 6 — Install remaining VirtIO drivers and QEMU Guest Agent

From the desktop, via the mounted VirtIO CD:
```
virtio-win-gt-x64.msi        # installs all remaining VirtIO drivers at once
virtio-win-guest-tools.exe   # if available
```
(This installer also includes the QEMU Guest Agent, `guest-agent\qemu-ga-x86_64.msi`, which lets Proxmox see the VM's IP and take consistent snapshots.) Reboot afterward.

### Phase 7 — Networking

DHCP on the flat network was kept (later confirmed as the correct final approach once VLAN10's DHCP relay design was clarified — see Decisions above), resolving DNS via `dc1` (`10.0.20.10`) and `dc2` (`10.0.20.11`), gateway `10.0.20.1` (`fw1`).

### Phase 8 — Join the pymesis.lab domain

Right-click **This PC → Properties → Rename this PC (advanced) → Computer Name tab → Change...** → computer name `CLIENT01` (or `CLIENT02`) → Member of: **Domain** → `pymesis.lab` → credentials `PYMESIS\Administrator` → confirmation message "Welcome to the pymesis.lab domain" → restart.

### Phase 9 — Verify in Active Directory

On `dc1`, **Active Directory Users and Computers** → Computers → confirmed `CLIENT01`/`CLIENT02` listed; moved into the workstations OU where one exists.

Phases 1–9 were repeated identically for `cl2`, changing only the VM ID, name, and computer name.

## Problems Solved

- No installation-specific problems were reported for this session — the process completed cleanly on the first pass for both VMs, aided by the `OOBE\BYPASSNRO` trick to avoid the internet-connectivity requirement during setup.

## Final Result

**cl1 / cl2** — Windows 11 Pro, 2 vCPU, 4GB RAM, 60GB disk, VM IDs 201/202, currently running on Node 1's flat network (pending eventual migration to Node 2 and VLAN10 once the MikroTik CRS310 arrives).

| Item | Status |
|---|---|
| Windows 11 Pro installed | ✅ both VMs |
| VirtIO drivers + QEMU Guest Agent | ✅ |
| Joined to `pymesis.lab` domain | ✅ |
| Networking | DHCP, resolved via `dc1`/`dc2`, gateway `fw1` |
| GPOs applied (from `dc1`) | ✅ drive mapping (`G:` General, `S:` Software from `fs1`), corporate wallpaper, BGInfo via NETLOGON, Windows Defender configuration |
| Restic backup | ❌ deliberately excluded (workstations, not servers) |
| Zabbix / Wazuh / Uptime Kuma monitoring | ❌ deliberately excluded (endpoint monitoring modeled as out of scope for these tools) |

## Pending

- Migration to Node 2 once the second GMKtec K8 Plus is acquired.
- Migration from the flat network to real VLAN10 once the MikroTik CRS310 switch arrives.
- Hybrid Azure AD Join evaluation (Entra ID Free + AD Connect), potentially via a Microsoft 365 30-day trial for Intune/MDM experimentation — not started.
- Whether to eventually add a Wazuh agent to `cl1`/`cl2` for endpoint-security simulation specifically (not general server-style monitoring) remains an open, low-priority idea.

## Cross-References

- Domain join relies on `dc1`/`dc2` from [Project 3](03-windows-server-2022-dc-fs.md); drive mappings point to shares on `fs1`, also from Project 3.
- VLAN10's actual addressing (`10.0.10.0/24`, DHCP scope on `dc1`, OPNsense relay) and the decision to exclude `cl1`/`cl2` from backup and monitoring were clarified in a later fleet-wide alignment pass, alongside similar conventions documented in [Project 5.1](05-1-restic-backup-policies.md).

---

[← **Previous:** Project 5.1 — Restic Backup Policies (bk1)](05-1-restic-backup-policies.md) | [**Next:** Project 7 — App Server (app1) →](07-windows-server-app1.md)