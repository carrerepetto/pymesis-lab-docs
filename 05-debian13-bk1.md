---
title: 05-debian13-bk1
description: debian13
published: 1
date: 2026-09-01T19:25:17.530Z
tags: 
editor: markdown
dateCreated: 2026-08-27T22:39:12.143Z
---

# Project 5 — Backup Server | bk1 | VM | Backup & Storage | Debian 13, Restic 0.17.3 |

**Previous:** [Project 4 — Docker Host (lx1)](04-ubuntu-2204-lx1.md)
**Next:** [Project 5.1 — Restic Backup Policies (bk1)](05-1-restic-backup-policies.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Install Debian 13 ("Trixie") as `bk1` (originally provisioned as `BACKUP01`) on Node 1, dedicated to running the lab's backup infrastructure — Restic and rclone — with a dedicated large disk for backup repositories, separate from the OS disk.

## Context

This VM followed the blueprint slot for `BACKUP01` (VLAN20, `10.0.20.50`), the lab's dedicated backup host for all other VMs. Debian 13 was confirmed as a valid choice even though it may still have been in "testing" phase at the time of download — installation is practically identical to Debian 12, and for a homelab this was judged acceptable. The VM was deliberately built with two separate virtual disks from the start: a small one for the OS and a large one purely for backup repositories, so backup data growth never threatens the base system.

## Decisions Made and Rationale

- **Two separate disks, not one**: a 40GB disk for the OS and a 300GB disk (sized to available space) dedicated entirely to backup storage — mounted independently at `/mnt/backups` — so the backup repository can grow without any risk to the OS partition.
- **Second disk left unpartitioned during Debian installation**: rather than configuring it in the installer's partitioner, the 300GB disk was deliberately skipped during setup and partitioned afterward from the running OS (`fdisk`, `mkfs.ext4`), keeping the installer's guided partitioning simple and limited to the OS disk only.
- **Backup partition mounted via UUID in `/etc/fstab`, with `nofail`**: using the partition's UUID (rather than a device path like `/dev/sdb1`) protects against device ordering changes across reboots; `nofail` ensures the VM still boots even if the backup disk were ever missing or failed to mount.
- **Restic and rclone installed at OS setup time, configured later**: both tools were installed immediately after base configuration, but their actual backup policies, repositories, and schedules were deliberately built out in a dedicated follow-up phase — see [Project 5.1](05-1-restic-backup-policies.md).
- **UFW scoped to SSH and the internal VLAN20 subnet only**: rather than opening specific ports piecemeal, the firewall was configured to allow SSH generally and all traffic from `10.0.20.0/24`, since every service `bk1` needs to reach or be reached by (SSH pulls/pushes from other lab VMs) originates from that subnet.

## Step-by-Step

### Phase 1 — Upload the ISO to Proxmox

```bash
wget -P /var/lib/vz/template/iso/ \
  https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.0-amd64-netinst.iso
```

### Phase 2 — Create the VM in Proxmox

| Field | Value |
|---|---|
| VM ID | 105 |
| Name | BACKUP01 |
| ISO | `debian-13.0-amd64-netinst.iso` |
| Machine / BIOS | `q35` / SeaBIOS |
| SCSI Controller | VirtIO SCSI single, Qemu Agent enabled |
| Disk 1 (OS) | VirtIO Block, `local-lvm`, 40GB, Write back cache, Discard |
| Disk 2 (Backups) | VirtIO Block, `local-lvm`, 300GB, Write back cache, Discard |
| CPU | 1 socket, 2 cores, type `host` |
| RAM | 4096 MB |
| Network | `vmbr0`, VLAN tag 20, model VirtIO |

### Phase 3 — Install Debian 13

Boot the ISO → **Install** (text mode) → language English, keyboard layout matching Santiago's own → hostname `backup01`, domain `homelab.local` → root password set, new user `sysadmin` created → **manual partitioning, OS disk (40GB) only**:

| Partition | Size | Type |
|---|---|---|
| `/boot/efi` | 512 MB | EFI System Partition |
| swap | 4 GB | swap |
| `/` | 35.5 GB | ext4 |

The second 300GB disk was left unpartitioned at this stage. Software selection: SSH server, standard system utilities (no desktop environment). GRUB installed to `/dev/sda`. Reboot and remove the ISO.

### Phase 4 — Post-install base configuration

```bash
ssh sysadmin@<temporary-ip>
su -

apt update && apt upgrade -y
apt install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent

apt install -y \
  curl wget git htop vim \
  net-tools nmap \
  sudo ufw \
  lsb-release ca-certificates

usermod -aG sudo sysadmin
```

Static IP (`/etc/network/interfaces`):
```
auto lo
iface lo inet loopback

auto ens18
iface ens18 inet static
    address 10.0.20.50
    netmask 255.255.255.0
    gateway 10.0.20.1
    dns-nameservers 10.0.20.10 10.0.20.11
```
Applied with `systemctl restart networking`.

### Phase 5 — Prepare the backup disk (sdb)

```bash
lsblk

fdisk /dev/sdb
# n (new partition) → p (primary) → Enter, Enter, Enter (defaults) → w (write)

mkfs.ext4 /dev/sdb1
mkdir -p /mnt/backups
blkid /dev/sdb1
```

Added to `/etc/fstab` (using the UUID from `blkid`):
```
UUID=xxxx-xxxx        /mnt/backups        ext4    defaults,nofail   0   2
```
Mounted and verified with `mount -a` and `df -h`.

### Phase 6 — Install Restic and rclone

```bash
apt install -y restic
curl https://rclone.org/install.sh | bash

restic version
rclone version
```

### Phase 7 — Basic firewall (UFW)

```bash
ufw allow ssh
ufw allow from 10.0.20.0/24
ufw enable
ufw status
```

## Problems Solved

- No disk or partitioning issues were encountered — the guided partitioning screen was double-checked against the plan (boot flag on the `/boot` partition, GRUB target set to `/dev/vda` rather than `/dev/vdb` or a manual target) before writing changes, and confirmed correct on the first pass.

## Final Result

**bk1** — `10.0.20.50` / VLAN20, Debian 13 (Trixie), 2 vCPU, 4GB RAM, VM ID 105 (Node 1).

| Item | Status |
|---|---|
| Debian 13 installed | ✅ |
| Static IP | ✅ `10.0.20.50` |
| OS disk | ✅ `/dev/sda` (40GB) |
| Backup disk | ✅ `/dev/sdb` → `/mnt/backups` (300GB) |
| Restic + rclone installed | ✅ |
| SSH enabled | ✅ |
| QEMU Guest Agent | ✅ |
| UFW firewall | ✅ SSH + `10.0.20.0/24` |

With the base OS and backup disk ready, the actual backup architecture (repositories, SSH keys, scripts, schedules) was built out separately — see [Project 5.1](05-1-restic-backup-policies.md).

## Pending

- Full Restic backup policy configuration (deferred to Project 5.1).
- `rclone` sync of `/mnt/backups` to an offsite NAS — blocked on the Ugreen DXP4800 hardware purchase; `bk1` itself has no backup of its own until this exists.

## Cross-References

- DNS resolution for `bk1` uses `dc1`/`dc2` as configured in [Project 3](03-windows-server-2022-dc-fs.md).
- `bk1` is the backup destination referenced throughout every other project's "Final Result" and "Backups" sections (e.g. [Project 4](04-ubuntu-2204-lx1.md)).

---

[← **Previous:** Project 4 — Docker Host (lx1)](04-ubuntu-2204-lx1.md) | [**Next:** Project 5.1 — Restic Backup Policies (bk1) →](05-1-restic-backup-policies.md)