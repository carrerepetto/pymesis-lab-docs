---
title: 02-opnsense-installation
description: opnsense
published: 1
date: 2026-08-28T21:17:07.398Z
tags: 
editor: markdown
dateCreated: 2026-08-27T16:54:33.588Z
---

# Project 2 — OPNsense 26.1.6 Installation (fw1)

**Previous:** [Project 1.1 — Ordered Shutdown Script on Proxmox (pve1)](01-1-ordered-shutdown-script.md)
**Next:** [Project 3 — Windows Server 2022 Installation (dc1, dc2, fs1)](03-windows-server-2022-dc-fs.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Install and configure OPNsense 26.1.6 as `fw1`, the lab's perimeter firewall/router, providing WAN/LAN separation, NAT, remote administrative access, a VPN for off-site access, and IDS/IPS — the first VM created on Node 1, ahead of every other service.

## Context

With `pve1` already installed (see [Project 1](01-proxmox-ve-installation.md)) and its two bridges in place (`vmbr0` WAN, `vmbr1` LAN), `fw1` was the natural starting point of the VM roadmap: every other VM in Node 1 sits behind it. Per the lab blueprint, the internal network was meant to eventually be split into VLAN10 (clients), VLAN20 (servers), and VLAN30 (lab) once the MikroTik CRS310 switch arrived — but at this stage, with a single physical NIC and no managed switch yet, `fw1` had to stand in as the only routing/segmentation point available.

## Decisions Made and Rationale

- **VM sizing and type**: `q35` machine, SeaBIOS, VirtIO SCSI Single controller, 32GB disk (`local-zfs`, discard + SSD emulation enabled), 1 socket / 2 cores (CPU type `host`), 4096MB RAM, Guest OS type "Other" (OPNsense/FreeBSD isn't a first-class option in the Proxmox wizard).
- **NIC order matters**: only the WAN NIC (`vmbr0`, VirtIO, firewall disabled at the Proxmox level — OPNsense handles its own filtering) was added at VM creation time; the LAN NIC (`vmbr1`) was added afterward, before first boot, so the installer's interface assignment step would see both `vtnet0`/`vtnet1` correctly.
- **ZFS stripe pool** for the OPNsense installation itself, consistent with the rest of the lab's ZFS-first approach.
- **LAN network actually ended up as `10.0.20.1/24`, not `10.0.10.1/24`**: the original installer notes called for `10.0.10.1/24` (matching a generic "LAN" concept), but per the blueprint the real server network is VLAN20 (`10.0.20.0/24`). In practice, the LAN interface was configured directly as `10.0.20.1/24` with DHCP `10.0.20.100–200`, making `fw1`'s LAN interface the VLAN20 gateway from day one, and avoiding the need for any static routes between OPNsense and the VMs.
- **Outbound NAT**: left on **Automatic** mode — standard for a single-WAN homelab setup, no manual outbound rules needed.
- **Remote admin access — NAT Port Forwarding with per-service WAN ports (not a blanket WAN rule)**: the original plan was a single WAN rule allowing the admin PC's IP to reach the whole `10.0.20.0/24` network on ports 22/3389. This didn't work because of a routing quirk explained below — the actual solution adopted was NAT Port Forwarding with **one dedicated WAN port per VM/service** (`2210`→`lx1:22`, `2211`→`bk1:22`, `3310`→`dc1:3389`, `3311`→`dc2:3389`, `3320`→`fs1:3389`), explicitly accepted as a **pragmatic, temporary** solution — not the ideal design — until the MikroTik CRS310 arrives and the admin PC can sit on a proper internal/admin VLAN behind OPNsense instead of sharing a broadcast domain with its WAN interface.
- **WAN IP made stable via DHCP reservation on the TP-Link router** (rather than switching OPNsense's WAN to static), since NAT rules reference the symbolic "WAN address" and resolve dynamically — but anything referencing the literal IP (a static route, an alias) still needed manual updates whenever it changed.
- **VPN protocol — WireGuard over OpenVPN**: chosen after clarifying the use case (remote access to the homelab from outside the house, from Windows and Linux devices). WireGuard was preferred for its native OS-level client support, simpler configuration, better performance, and because OPNsense 26.1 ships with it built in (no additional plugin required) — OpenVPN was considered excessive for this use case.
- **IDS/IPS — Suricata in IPS mode on the WAN interface**, using the Hyperscan pattern matcher for performance, with a curated selection of ET Open and abuse.ch rulesets balancing security coverage against homelab-scale performance: `emerging-attack_response`, `emerging-malware`, `emerging-scan`, `emerging-exploit`, `emerging-shellcode`, `emerging-phishing`, `emerging-web_server`, `emerging-web_client`, `emerging-sql` (specifically relevant since `app1` runs SQL Server), `emerging-worm`, plus reputation feeds (`abuse.ch/Feodo Tracker`, `abuse.ch/SSL Fingerprint Blacklist`, `abuse.ch/ThreatFox`, `ET open/drop`, `ET open/tor`). Deliberately **excluded**: `emerging-hunting` (too noisy), `chat`/`voip`/`p2p` sets (not relevant), and `OPNsense-App-detect/*` (deferred). Rules set to auto-update daily at 01:00.
- **Backup strategy — REST API pull from `bk1`, not an OPNsense-side push plugin**: after the built-in `os-sftp-backup` plugin proved unreliable (see Problems Solved), the decision was made to pull the config the same way the rest of the fleet is backed up conceptually — a script running on `bk1` that authenticates against OPNsense's REST API and downloads `config.xml` directly, keeping `fw1`'s config backup independent of any OPNsense-side SSH/plugin quirks. This keeps backups under `bk1`'s control, consistent with the fleet's push/pull backup conventions, stored separately from Restic's own repositories under `/mnt/backups/configs/fw1/opnsense/` (a dedicated `configs/` tree for flat configuration-file backups, as opposed to Restic's repository-based backups).

## Step-by-Step

### Phase 0 — Prepare Proxmox before creating the VM

Confirm `vmbr0` (WAN, bridged to the physical NIC toward the TP-Link) and `vmbr1` (LAN, internal) both exist in *Proxmox → Node → Network*.

### Phase 1 — Download the OPNsense ISO

OPNsense distributes the ISO as `.bz2`; Proxmox doesn't decompress it automatically. Either download the already-decompressed ISO directly, or download the `.bz2` via Proxmox's shell and decompress it with `bzip2 -d`.

### Phase 2 — Create the VM

| Section | Field | Value |
|---|---|---|
| General | Name | `fw1` |
| OS | Guest OS Type | Other |
| System | Machine / BIOS / SCSI Controller | q35 / SeaBIOS / VirtIO SCSI Single |
| Disk | Bus / Storage / Size | SCSI / local-zfs / 32GB (Discard + SSD emulation: YES) |
| CPU | Sockets / Cores / Type | 1 / 2 / host |
| Memory | RAM | 4096 MB |
| Network (NIC 1) | Bridge / Model / Firewall | vmbr0 / VirtIO / NO |

Do not add a second NIC yet — finish creation without "Start after created" checked.

### Phase 3 — Add NIC 2 (LAN) before first boot

`fw1 → Hardware → Add → Network Device`: bridge `vmbr1`, model VirtIO, firewall NO. Confirm `net0 → vmbr0` (WAN) and `net1 → vmbr1` (LAN).

### Phase 4 — Install OPNsense

Boot the VM, log into the live installer (`installer` / `opnsense`), choose ZFS install with a stripe pool on the 32GB virtual disk, let it write the system, then reboot — detaching the ISO first (`fw1 → Hardware → CD/DVD → Edit → "Do not use any media"`).

### Phase 5 — First boot: assign interfaces

From the OPNsense console menu, option **1 — Assign Interfaces**: no VLANs at this stage, WAN = `vtnet0`, LAN = `vtnet1`.

### Phase 6 — Configure the LAN IP

Option **2 — Set interface IP address** on the LAN interface: static IPv4 (no DHCP), DHCP server enabled on LAN for downstream clients, HTTPS enabled for the GUI. *(As noted above, the address actually used ended up being `10.0.20.1/24` with a `10.0.20.100–200` DHCP range, aligning the LAN interface directly with the VLAN20 server network from the blueprint.)*

### Phase 7 — Access the OPNsense GUI

From the admin PC, either spin up a temporary VM on `vmbr1` to get a DHCP address, or assign Proxmox itself an IP on `vmbr1` temporarily to reach the GUI over HTTPS (`root` / `opnsense` initial credentials).

### Phase 8 — Minimal post-install configuration

- **NAT Outbound**: Automatic mode.
- **LAN rule**: OPNsense's installer already creates an implicit `PASS / LAN net → any` rule as a side effect of enabling the LAN DHCP server during setup — this is why internet access worked from `dc1` even before any rule was manually created. The explicit rule documented in the original notes exists mainly to confirm the automatic rule is present and to have it clearly documented, not because it was strictly missing.

### Remote administrative access (SSH/RDP from the admin PC)

The first attempt — a static route on the admin PC pointing `10.0.20.0/24` via OPNsense's WAN IP — failed, because the admin PC and OPNsense's WAN interface shared the same `/22` broadcast domain (`192.168.68.0/22`), so the PC treated OPNsense as a same-subnet neighbor rather than a router, and OPNsense doesn't accept acting as a gateway for inbound traffic on its WAN side without NAT.

**Solution adopted**: NAT Port Forwarding on WAN, with a dedicated WAN port per VM/service (documented as intentionally temporary — see Decisions above):

| VM | Internal IP | WAN Port | Client Command |
|---|---|---|---|
| `lx1` | `10.0.20.40` | `2210` (SSH) | `ssh -p 2210 sadmin@<WAN IP>` |
| `bk1` | `10.0.20.50` | `2211` (SSH) | `ssh -p 2211 sadmin@<WAN IP>` |
| `dc1` | `10.0.20.10` | `3310` (RDP) | `mstsc /v:<WAN IP>:3310` |
| `dc2` | `10.0.20.11` | `3311` (RDP) | `mstsc /v:<WAN IP>:3311` |
| `fs1` | `10.0.20.20` | `3320` (RDP) | `mstsc /v:<WAN IP>:3320` |

Each rule was created under *Firewall → NAT → Port Forward*, with "Add associated filter rule" enabled so the corresponding WAN firewall rule is generated automatically.

### Stabilizing the WAN IP

Since OPNsense's WAN interface receives its address via DHCP from the TP-Link router, a DHCP address reservation was configured on the TP-Link (matching `vtnet0`'s MAC address to a fixed IP, `192.168.68.103`), then `Interfaces → WAN → Release/Renew` applied on OPNsense to pick it up.

### VPN — WireGuard

1. `VPN → WireGuard → Settings` → Enable WireGuard.
2. `VPN → WireGuard → Local → Add`: name `wg0`, listen port `51820`, tunnel address `10.10.10.1/24`, key pair auto-generated by OPNsense.
3. `VPN → WireGuard → Peer generator`: one peer per client device (e.g., `pc-windows` → `10.10.10.2/32`, DNS `10.0.20.10`, Allowed IPs `10.0.20.0/24`; `laptop-linux` similarly), with Endpoint set to the WAN IP (`192.168.68.103`) and port `51820`.
4. Create a WireGuard interface in OPNsense and a WAN firewall rule allowing inbound UDP `51820`.
5. Install the official WireGuard client on Windows/Linux and import the generated peer config.
6. Port-forward UDP `51820` on the TP-Link toward OPNsense's WAN IP.

### IDS/IPS — Suricata

1. `Services → Intrusion Detection → Administration`: Enabled, IPS mode, Promiscuous mode, syslog alerts, Hyperscan pattern matcher, interface WAN.
2. `Services → Intrusion Detection → Administration → Download`: enable the ruleset selection listed under Decisions above, then *Download & Update Rules*.
3. `Services → Intrusion Detection → Schedule`: daily automatic rule updates at 01:00, applied to run every day of the week.
4. Verify the green status indicator confirming Suricata is running.

### Automated configuration backup to bk1

1. Manual baseline: `System → Configuration → Backups → Download configuration` (the `config.xml` file is OPNsense's complete, single-file configuration backup).
2. First attempt — OPNsense's own automated backup: required installing the `os-backup` plugin, then `os-sftp-backup` specifically (the "Automated" tab doesn't appear without it). Configured to push to `sftp://sadmin@bk1/mnt/backups/configs/fw1/opnsense/`, 30 backups retained — this path proved unreliable (see Problems Solved) and was abandoned.
3. **Final approach — REST API pull, run from `bk1`**:
   - Created a dedicated API user `backup_api` in OPNsense (`System → Access → Users`), granted the `System: Configuration: Backups` privilege and added to the `admins` group.
   - Generated an API key/secret for that user.
   - Wrote `/usr/local/bin/backup-opnsense.sh` on `bk1`, calling `https://<fw1 LAN IP>/api/core/backup/download/this` with `curl -u "<key>:<secret>"`, saving the result with a timestamped filename under `/mnt/backups/configs/fw1/opnsense/`, logging success/failure to `/var/log/backup-opnsense.log`, applying `chown sadmin:sadmin` on the saved file, and rotating to keep the last `KEEP=30` files.
   - Scheduled via `sudo crontab -e` on `bk1`: `0 2 * * * /usr/local/bin/backup-opnsense.sh` (daily at 02:00).

## Problems Solved

- **LAN subnet mismatch vs. the blueprint**: the original notes specified `10.0.10.1/24` for OPNsense's LAN, but the blueprint's actual server network is VLAN20 (`10.0.20.0/24`). This was resolved simply by confirming that, in practice, the LAN interface had already been configured as `10.0.20.1/24` with the VMs living directly on that same network — no static routing was needed, since OPNsense's LAN interface *is* the VLAN20 gateway.
- **Static route approach for remote admin access failed**: root cause — the admin PC and OPNsense's WAN interface both lived on the same `192.168.68.0/22` network, so the PC saw OPNsense as a same-subnet peer, not a router; OPNsense by default won't act as a gateway for return traffic entering via its own WAN interface without NAT. Diagnosed step by step (`route print`, `ping` to the WAN IP, `tracert`, and OPNsense's own Diagnostics → Ping) before concluding NAT Port Forwarding was the actual fix — explicitly acknowledged as **not** the ideal long-term design (that would put the admin PC behind OPNsense on its own VLAN once the MikroTik switch arrives), but a reasonable pragmatic step for a homelab at this stage.
- **WAN IP changed after the DHCP reservation was applied** (`192.168.68.53` → `192.168.68.103`): NAT/Port Forward rules didn't need any changes (they reference the symbolic "WAN address"), but the Windows static route and the `mi_pc` firewall alias, which referenced the literal old IP, had to be manually updated — along with the admin PC's own IP, which had also changed (`.52` → `.102`) due to the same DHCP lease cycle.
- **`os-sftp-backup` plugin proved unreliable**: the "Automated" backups tab didn't exist until `os-backup` (and then specifically `os-sftp-backup`) were installed; once installed and configured, the plugin's internal SSH client rejected the ED25519 key (`Load key ".../identity": error in libcrypto: unsupported`) — switching to an RSA 4096 key worked for manual CLI testing, but the plugin itself continued to have limitations, leading to the decision to abandon it in favor of a REST-API-based pull script running from `bk1` instead.
- **`backup_api` insufficient privileges**: the `System: Configuration: Backups` privilege alone wasn't enough to authorize the API's backup-download endpoint (calls kept failing even after the key/secret were confirmed valid). Resolved by adding the `backup_api` user to the `admins` group membership while keeping the same declared privileges — the group membership was what actually granted the needed access, not an additional individual privilege.
- **Backup files owned by `root:root` instead of `sadmin:sadmin`**: since the script runs via `sudo`, files it created were owned by `root`. Fixed by adding an explicit `chown sadmin:sadmin` step at the end of the script, and manually correcting the ownership of files already created before the fix.
- **WireGuard instance created with the wrong tunnel address** (`10.10.10.10/24` instead of the intended `10.10.10.1/24`): caught and corrected before creating any peers.
- **False negatives while testing external VPN access**: while testing from a phone hotspot, the laptop was still connected to home Wi-Fi instead of the hotspot (confirmed via the wrong `SourceAddress` in `Test-NetConnection` output), and separately, `Test-NetConnection -Port 51820` tests TCP connectivity while WireGuard uses UDP — meaning that specific test will always report failure regardless of whether WireGuard actually works, and was disregarded as a diagnostic in favor of an actual `ping` over the tunnel and `wg show` handshake status.
- **Persistent WireGuard handshake failure from a genuinely external network** (peers created and registered on both ends, keys cross-verified as matching on client and server, `AllowedIPs`/`Endpoint` all correct): extensive troubleshooting was carried out — checking `wg show wg0 dump` (confirmed no handshake ever occurred, i.e., `(none) (none)` on both fields), verifying `wg0.conf` held the correct peer public key, ruling out Suricata as the cause (it was already stopped when tested), reviewing OPNsense's automatic/floating firewall rules (which are evaluated *before* the explicit WireGuard WAN rule and could in principle intercept private-network traffic first), and restarting the WireGuard service through the GUI (`VPN → WireGuard → Instances` — the FreeBSD service isn't managed via a standard `rc.d` script the way `service wireguard restart` implies on other systems). **This remained unresolved at the end of this session** — WireGuard silently drops packets it can't authenticate, so the lack of any log entries during failed handshake attempts made this difficult to pin down further with the diagnostics available at the time; flagged as an open item for a future session.

## Final Result

- `fw1` operational as the lab's OPNsense-based perimeter firewall, WAN on `vmbr0`, LAN (`10.0.20.1/24`, VLAN20) on `vmbr1`, NAT Outbound in automatic mode.
- Remote administrative access via NAT Port Forwarding, dedicated WAN ports per VM/service, explicitly documented as a temporary measure pending the MikroTik CRS310 and proper VLAN segmentation.
- WireGuard VPN (`wg0`, `10.10.10.1/24`) configured with peers for a Windows PC and a Linux laptop; internal connectivity confirmed, but a genuine external handshake was still failing at the end of this session (open item).
- Suricata IDS/IPS active on WAN in IPS mode, with a curated ET Open + abuse.ch ruleset selection and daily automatic rule updates.
- Automated daily backup of `fw1`'s `config.xml` to `bk1` via a REST-API pull script and cron, with 30-day rotation.

## Pending

- Full VLAN segmentation (VLAN10/20/30) — blocked on the MikroTik CRS310 switch purchase.
- DDNS (DuckDNS) for a stable public hostname, to replace the raw dynamic WAN IP in VPN/remote-access configuration.
- Resolving the external WireGuard handshake failure.

## Cross-References

- The backup directory convention (`/mnt/backups/configs/<host>/...` for flat configuration-file backups, separate from Restic's own repository structure) established here on `bk1` is the same one referenced in [Project 1](01-proxmox-ve-installation.md)'s backup discussion.
- Full VLAN segmentation, once the MikroTik CRS310 arrives, will require revisiting the NAT Port Forwarding setup documented here.
