---
title: 03-windows-server-2022-dc-fs
description: windows-server
published: 1
date: 2026-09-01T19:23:58.668Z
tags: 
editor: markdown
dateCreated: 2026-08-27T16:55:32.797Z
---

# Project 3 — Windows Server | dc1, dc2, fs1 | VM | AD DS/DNS/DHCP/GPO/ADCS (dc1/dc2), File Server (fs1) | Windows Server 2022 |

**Previous:** [Project 2 — OPNsense (fw1)](02-opnsense-installation.md)
**Next:** [Project 4 — Docker Host (lx1)](04-ubuntu-2204-lx1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Install and configure Windows Server 2022 Standard on three VMs — `dc1` and `dc2` as Active Directory Domain Controllers, and `fs1` as a File Server — establishing the identity and file-sharing backbone of Node 1.

## Context

At this stage the lab was still single-node (only `pve1`, no second GMKtec yet), with `fw1`/OPNsense already operational and VLANs conceptually defined in the blueprint but not yet physically realized — the MikroTik CRS310 switch that would actually create and trunk the VLANs hadn't been purchased yet. This raised an important sequencing question before starting: could the Domain Controllers be installed now, ahead of the switch?

## Decisions Made and Rationale

- **VLAN dependency resolved with a temporary flat bridge**: since VLANs will ultimately be defined and tagged on the MikroTik CRS310 (not on OPNsense) once it arrives, and OPNsense only needs to *know about* VLAN20 to act as its gateway — the interim solution was to create a simple, untagged Proxmox bridge (`vmbr20`) for now, with OPNsense holding IP `10.0.20.1` on it. This let `dc1`/`dc2`/`fs1` be installed and fully configured immediately, on a flat internal network, with a clean migration path later: when the MikroTik arrives, real tagged VLANs replace the flat bridge, but the guest OS network configuration (IPs, gateway) doesn't change at all.
- **VM sizing**: `dc1` (VM ID 201, 4096MB RAM, 2 vCPU, 80GB disk), `dc2` (VM ID 202, 4096MB RAM, 2 vCPU, 60GB disk), `fs1` (VM ID 203, 6144MB RAM, 2 vCPU, 80GB OS disk + a dedicated 200GB data disk). All on `vmbr20`, q35 machine, OVMF (UEFI) BIOS with EFI storage on `local-lvm`, TPM 2.0 enabled (a hard requirement for Windows Server 2022), VirtIO SCSI Single controller, VirtIO Block disk bus, CPU type `host`, memory ballooning disabled (standard practice for servers, to guarantee committed RAM).
- **Windows Server 2022 Standard, Desktop Experience (with GUI), not Server Core**: chosen deliberately during setup — Server Core would be more production-realistic, but Desktop Experience was preferred here for ease of management in a homelab/learning context.
- **DNS resolution order reflects the AD topology**: `dc1` points to itself only (it's the first, authoritative DNS server); `dc2` and `fs1` point to `dc1` first, then to `dc2` — establishing `dc1` as the primary resolver while still providing a fallback.
- **Domain name — `pymesis.lab`, deliberately overriding the original blueprint's `homelab.local`**: partway through the `dc1` promotion wizard, the domain name was typed as `pymesis.lab` instead of the blueprint's documented `homelab.local`. This was caught and explicitly confirmed as an intentional change (not a typo) before proceeding, since renaming an AD domain after creation is highly complex — `pymesis.lab` was validated as a solid choice, since `.lab` avoids the mDNS conflicts that can occur with `.local`, unlike the originally planned name.
- **NTFS permission model**: `Domain Admins` get full control everywhere; department-scoped security groups (`IT`, `HR`) get `Modify` on their own shared folders and on `General`, but only `ReadAndExecute` on `Software`; each user gets exclusive `FullControl` on their own personal folder under `Users`, with inheritance broken (`SetAccessRuleProtection`) so departmental or company-wide permissions don't leak into personal folders.
- **Shares and folder names in English**: the initial folder structure was proposed in Spanish (`Usuarios`, `Departamentos`, etc.) but changed to English (`Users`, `Departments/IT`, `Departments/HR`, `General`, `Software`) partway through, for consistency with the lab's English-language documentation standard.
- **FSRM quotas — hard limits, not soft**: 10GB per user home folder, 50GB per department folder, both configured as hard limits (`-SoftLimit:$false`) rather than advisory soft limits, to actually enforce space usage in a homelab with finite disk.
- **Home Folder over Roaming Profile for personal storage**: AD's `HomeDirectory`/`HomeDrive` attributes were used to map each user's `H:` drive to their personal folder on `fs1` (`\\fs1\Users\<username>`). This only centralizes file storage — the Windows profile itself (desktop, settings) stays local to each PC. A full Roaming Profile (which would centralize the entire profile via `ProfilePath`) was explicitly discussed as an alternative and considered unnecessary overhead for this lab's scale, but the final decision on whether to add it as well was left open at the end of this session.
- **DHCP scope creation deliberately paused, then resolved differently later**: mid-session, while setting up a DHCP scope for VLAN20 on `dc1`, it was correctly identified that OPNsense's own LAN DHCP server (bound to the same flat, not-yet-segmented `vmbr1`/`vmbr20` network) would directly conflict with a second DHCP server on the same broadcast domain. The decision at the time was to defer the DC01 DHCP scope entirely until the MikroTik physically separates VLAN10 from VLAN20 — rather than disabling OPNsense's DHCP, which other VMs still depended on. (As confirmed in a later fleet-status alignment pass, this was ultimately solved differently: DHCP for VLAN10 clients ended up running on `dc1` with a **DHCP Relay configured in OPNsense**, and was confirmed working even before the MikroTik arrived — see Problems Solved below.)

## Step-by-Step

### Phase 1 — Create the 3 VMs in Proxmox

| Field | dc1 | dc2 | fs1 |
|---|---|---|---|
| VM ID | 201 | 202 | 203 |
| RAM | 4096 MB | 4096 MB | 6144 MB |
| vCPU | 2 | 2 | 2 |
| OS disk | 80 GB | 60 GB | 80 GB |
| Extra disk | — | — | 200 GB |
| Network | vmbr20 | vmbr20 | vmbr20 |
| IP | 10.0.20.10 | 10.0.20.11 | 10.0.20.20 |

Common settings across all three: Guest OS Type "Microsoft Windows" (version 2022), machine `q35`, BIOS `OVMF (UEFI)` with EFI storage on `local-lvm`, TPM 2.0 enabled, VirtIO SCSI Single controller, VirtIO Block disk bus with Discard enabled, 1 socket / 2 cores (CPU type `host`), ballooning disabled.

### Phase 2 — Install Windows Server 2022

**Known VirtIO issue**: Windows doesn't detect the VirtIO disk by default. Before installing, download the VirtIO driver ISO on Proxmox (`virtio-win.iso` from the Fedora People mirror) and attach it as a second CD/DVD drive on each VM.

Installation flow (identical for all three VMs): boot from the Windows ISO → English (United States) → **Windows Server 2022 Standard (Desktop Experience)** — important: with GUI, not Core → Custom: Install Windows only (advanced) → at the disk selection screen, **Load driver** → Browse to the VirtIO CD → `amd64\w11` → select **Red Hat VirtIO SCSI controller** → the disk now appears → select it and proceed → wait ~15-20 minutes through several automatic reboots → set the local Administrator password and log in.

### Phase 3 — Base post-install configuration (all 3 VMs)

Before promoting any roles, on each VM:

1. **VirtIO network driver**: Device Manager → the Ethernet Controller shows as unrecognized until the NetKVM driver is installed from the VirtIO CD (`NetKVM\w11\amd64`).
2. **Static IP** (PowerShell, adjusted per VM per the table above):
   ```powershell
   New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress <IP> -PrefixLength 24 -DefaultGateway 10.0.20.1
   Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses <DNS servers per host>
   ```
3. **Rename and restart**: `Rename-Computer -NewName "<DC1|DC2|FS1>" -Restart`.
4. **Windows Update** before promoting any roles (`Install-Module PSWindowsUpdate -Force; Get-WindowsUpdate -Install -AcceptAll -AutoReboot`).

### Phase 4 — Promote dc1 as the primary Domain Controller

With `dc2` and `fs1` powered off for now:

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Install-ADDSForest `
    -DomainName "pymesis.lab" `
    -DomainNetbiosName "PYMESIS" `
    -DomainMode "WinThreshold" `
    -ForestMode "WinThreshold" `
    -InstallDns:$true `
    -Force:$true
```

DNS is installed automatically as part of this step (AD DS depends entirely on DNS — Microsoft folds its installation into the promotion wizard). Verified afterward with `Get-ADDomain`, `Resolve-DnsName pymesis.lab`, and `Get-Service adws,kdc,netlogon,dns`.

### Phase 5 — Promote dc2 as a replica Domain Controller

With `dc1` up and running, and `dc2` network-configured to resolve `dc1` for DNS:

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Install-ADDSDomainController `
    -DomainName "pymesis.lab" `
    -InstallDns:$true `
    -Credential (Get-Credential "PYMESIS\Administrator") `
    -Force:$true
```

Replication verified with `repadmin /replsummary` (target: `0 fails`).

### Phase 6 — Configure fs1 as a File Server

1. Join the domain: `Add-Computer -DomainName "pymesis.lab" -Credential (Get-Credential "PYMESIS\Administrator") -Restart`.
2. Initialize and format the 200GB data disk: `Initialize-Disk`, `New-Partition -DriveLetter D`, `Format-Volume -FileSystem NTFS -NewFileSystemLabel "Datos"`.
3. Install File Server roles: `FS-FileServer`, `FS-Resource-Manager`, `FS-DFS-Namespace`, `FS-DFS-Replication`.
4. Create the folder structure under `D:\Shares\` (`Users`, `Departments\IT`, `Departments\HR`, `General`, `Software`).
5. Create the SMB shares (`Users`, `IT$` and `HR$` hidden, `General`, `Software`) via `New-SmbShare`.
6. Apply NTFS permissions per the model described in Decisions above (`Get-Acl`/`Set-Acl` with `FileSystemAccessRule` objects, one block per folder).
7. Create per-user personal folders under `Users\<username>` with exclusive per-user permissions.
8. Configure FSRM quota templates (`User Quota 10GB`, `Department Quota 50GB`) and apply them to the relevant folders.

### Group Policy and identity structure (on dc1)

- **OU structure**: `pymesis.lab\Pymesis\{Computers\{Servers,Workstations}, Users\{IT,HR}, Groups\{IT,HR}}`.
- **Security groups**: `IT`, `HR`, `HelpDesk` (global security groups under `Groups`).
- **Test users**: `jsmith` (IT), `jdoe` (HR), `bwilson` (HelpDesk, placed under the IT OU), added to their respective groups.
- **Domain password policy**: min length 8, history 10, max age 90 days, min age 1 day, complexity enabled, reversible encryption disabled.
- **Account lockout policy**: 30-minute lockout duration and observation window, threshold 5 failed attempts.
- **GPO — Desktop Policy**: sets a default desktop wallpaper (`img0.jpg`, Fill style) via User Configuration → Administrative Templates → Desktop.
- **GPO — Drive Mapping**: maps `\\fs1\General` as `G:` and `\\fs1\Software` as `S:` via Group Policy Preferences (User Configuration → Preferences → Windows Settings → Drive Maps).
- **Home folders**: configured directly on each user object (`HomeDirectory`/`HomeDrive`) rather than via GPO, mapping `H:` to `\\fs1\Users\<username>`.

## Problems Solved

- **VLAN sequencing question, resolved before starting**: since VLANs will physically be created on the future MikroTik CRS310, not on OPNsense, the plan was clarified as a two-stage migration — install everything now on a flat, untagged bridge (`vmbr20`) with OPNsense as its gateway, and swap in real tagged VLANs later without touching any VM's network configuration.
- **Gateway confusion**: an initial plan had `dc1`/`dc2`/`fs1` pointing their default gateway to `10.0.10.1` (the VLAN10 gateway) instead of `10.0.20.1` (their own subnet's gateway). Corrected with the general rule: the gateway is always the `.1` address of the same subnet the VM lives in.
- **VirtIO disk not detected during Windows setup**: the classic VirtIO issue — Windows Server has no built-in VirtIO drivers, so the installer's disk selection screen shows no drives at all until the "Red Hat VirtIO SCSI controller" driver is manually loaded from the mounted `virtio-win.iso`. In one case, the driver wasn't visible in the Load Driver browser because the ISO hadn't actually been attached as a second CD/DVD drive yet — fixed by attaching it live from the Proxmox Hardware tab (no VM restart needed) and retrying Browse.
- **Domain name mismatch caught mid-wizard**: `pymesis.lab` was typed into the `Install-ADDSForest`/wizard instead of the blueprint's `homelab.local`. Flagged immediately (since renaming an AD domain after creation is very disruptive) and confirmed as an intentional, permanent change rather than continuing on the wrong assumption.
- **Event ID 41 ("Kernel-Power") appearing as Critical in the System log after AD DS promotion reboots**: this is expected and benign — Windows logs any non-clean shutdown as Event ID 41, including the automatic restarts triggered by the AD DS promotion or domain-join wizards themselves, not just real power failures. Confirmed by checking the event timestamp against the known wizard-triggered reboots, then cleared via `Clear-EventLog -LogName System` since it carries no real diagnostic value in a lab with no real auditing needs.
- **DHCP scope conflict on the same flat network**: while creating a DHCP scope for VLAN20 (`10.0.20.100–200`) on `dc1`, it was correctly caught that OPNsense's own LAN DHCP server was already active on the very same broadcast domain (since VLAN10 and VLAN20 weren't physically separated yet, both riding on `vmbr1`/`vmbr20`). Two servers issuing DHCP leases on the same network segment would conflict. The DHCP wizard was cancelled and the scope creation deferred until the MikroTik switch physically separates the VLANs.
- **DHCP ultimately resolved differently, ahead of the MikroTik purchase** (confirmed in a later fleet-status alignment pass): rather than waiting for the switch, a DHCP scope for VLAN10 clients was configured on `dc1` together with a **DHCP Relay configured on OPNsense**, and confirmed working — meaning VLAN10/VLAN20 logical separation was effectively already functioning at the OPNsense level even before the physical MikroTik migration, ahead of what was originally planned in this session.
- **Home Folder vs. Roaming Profile, left as an open decision**: the distinction was clarified in detail (Home Folder centralizes only file storage via a mapped drive; Roaming Profile centralizes the entire Windows profile — desktop, settings, favorites — via `ProfilePath`, at the cost of more network overhead and more fragility if the file server is unavailable), and Home Folder was judged sufficient for this lab's scale — but whether to also layer on Roaming Profiles was left unresolved at the end of this session.

## Final Result

- `dc1` (`10.0.20.10`) — primary Domain Controller for `pymesis.lab`, DNS server, full OU/group/user structure, password and lockout policies, Desktop and Drive Mapping GPOs, home folders configured; DHCP for VLAN10 (with OPNsense relay) added in a later pass.
- `dc2` (`10.0.20.11`) — replica Domain Controller and DNS server, replication with `dc1` confirmed at 0 failures.
- `fs1` (`10.0.20.20`) — File Server with a 200GB NTFS data volume, 5 SMB shares (`Users`, `IT$`, `HR$`, `General`, `Software`), per-group NTFS permissions, FSRM quotas (10GB/user, 50GB/department), and per-user home folders mapped via AD.
- Per-VM Restic backups (`C:\Restic\backup.ps1`, daily at 2:30 AM) confirmed running to `bk1` (`/mnt/backups/repos/dc1`, `dc02`, `fs1`), and Zabbix/Wazuh agents confirmed installed on all three, per the later fleet-status alignment pass.

## Pending

- DFS Namespace — role installed on `fs1` but not yet configured.
- `rclone` backup sync to a NAS — blocked on the Ugreen DXP4800 hardware purchase.
- Decision on whether to add Roaming Profiles in addition to Home Folders.
- Migrating the flat `vmbr20` bridge to real tagged VLANs once the MikroTik CRS310 arrives.

## Cross-References

- The temporary flat-bridge approach here mirrors the same reasoning used for [Project 2](02-opnsense-installation.md)'s remote-access NAT workaround: both are pragmatic stand-ins for the MikroTik CRS310-based VLAN design, explicitly documented as temporary.
- Fleet-wide conventions referenced here (Restic backups to `bk1`, Zabbix/Wazuh agents) are defined in the [Lab Index](00-pymesis-lab-index.md).

---

[← **Previous:** Project 2 — OPNsense (fw1)](02-opnsense-installation.md) | [**Next:** Project 4 — Docker Host (lx1) →](04-ubuntu-2204-lx1.md)