---
title: 05-1-restic-backup-policies
description: restic-backup
published: 1
date: 2026-09-01T19:25:49.185Z
tags: 
editor: markdown
dateCreated: 2026-08-27T22:40:07.657Z
---

# Project 5.1 — Restic Backup Policies | bk1 | Config | Backup Configuration | Restic |

**Previous:** [Project 5 — Backup Server (bk1)](05-debian13-bk1.md)
**Next:** [Project 6 — Client Workstations (cl1, cl2)](06-windows11-cl1-cl2.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Design and roll out a fleet-wide backup strategy centered on `bk1`, covering every VM in the lab (Linux and Windows) with Restic, plus a separate mechanism for `fw1` (OPNsense) and Proxmox itself — and, in a later hardening pass, upgrade every backup from a plain "copy of live files" into something that actually supports a real disaster-recovery restore (consistent database dumps, AD-safe snapshots, captured Docker volumes), at a frequency that matches how often a homelab actually changes.

## Context

This work followed directly from [Project 5](05-debian13-bk1.md) (bk1's base OS and disk setup) and unfolded in two distinct phases, weeks apart:

1. **Initial rollout** (late June): building the actual Restic repositories, SSH trust, and per-VM backup scripts across the whole fleet, one VM at a time.
2. **Disaster-recovery hardening** (early-to-mid July): after all fleet VMs had their own documentation written up, a review against each server's real configuration revealed that several backups — while running successfully — would not actually produce a usable restore in a real disaster (live copies of locked database files, uncaptured Docker volumes, an AD database read while in use). This phase fixed those gaps and, separately, right-sized the backup frequency for a homelab that doesn't change daily.

## Decisions Made and Rationale

### Initial architecture

- **Pull-style from `bk1` was the original plan, but was abandoned in favor of push-style from each VM**: the first design had `bk1` connecting out via SSH to every Linux VM and pulling their data. This was reversed during the rollout — each VM (Linux and Windows) ended up running its own local backup script on its own local scheduler (cron / Task Scheduler) and pushing its data to `bk1` via SFTP. This is simpler to reason about per-VM and matches how the fleet's documentation was ultimately structured (one backup script per server, documented alongside that server's own project).
- **Windows backups use Restic directly over SFTP, not a REST Server**: a Restic REST Server on `bk1` (with per-VM `htpasswd` credentials) was considered and partially scaffolded, but deliberately dropped once it became clear plain Restic already supports SFTP repositories natively over the SSH access `bk1` already provides. Introducing a second backup mechanism (REST Server, extra port, extra auth store) was judged unnecessary complexity for a homelab — "no complicar con otra herramienta lo que ya resuelve la que tenemos" was the explicit reasoning, so SFTP was chosen instead. Proxmox Backup Server (PBS) was also considered for whole-VM snapshots but not pursued in favor of native `vzdump`.
- **SSH config aliases used on both Linux and Windows to avoid PowerShell quoting issues**: rather than passing a raw SSH command string via `-o sftp.command="..."` (which broke due to PowerShell's quote handling), an SSH config file (`~/.ssh/config` on Linux, `$env:USERPROFILE\.ssh\config` on Windows) defines a `Host bk1` alias with its `HostName`, `User`, and `IdentityFile`, so Restic's SFTP backend can simply reference `sftp:bk1:/path` cleanly on every OS.
- **Restic's encryption password is independent of any OS credential**: clarified explicitly during setup — it's the key Restic uses to encrypt data client-side before it ever reaches `bk1`; `bk1` never needs to know it, only whoever restores does. This is distinct from SSH credentials used purely for transport.
- **Restic password file world-readable at `/etc/restic_password` (Linux) rather than root-only at `/root/.restic_password`**: the initial design stored the password under `/root/`, but this broke `sadmin`-owned scripts and cron jobs that couldn't read it. It was moved to `/etc/restic_password` (mode 644) so that both root-run cron jobs and the `sadmin` user could read it without needing `sudo` inside the scripts themselves.
- **Repository and hostname naming standardized to the short form** (`dc1`, `dc2`, `fs1`, `app1`, `lx1`, `odoo1`, `db1`, `mon1`), not the original blueprint's longer names (`dc01`, `app01`, `backup01`, etc.) — matching the short-hostname convention adopted lab-wide (see [Project 4](04-ubuntu-2204-lx1.md)'s `lx1` rename). Old long-named repositories were removed once this was caught.
- **DC1/DC2 Task Scheduler runs as `PYMESIS\Administrator`, not `SYSTEM`**: initially registered under the `SYSTEM` account like every other Windows VM, but this caused SQL Server Express backups on `app1` to fail silently (`SYSTEM` lacks SQL Server permissions) and caused a hung/duplicate-running task on `dc1` the following night. Both were fixed by re-registering the scheduled task with explicit `PYMESIS\Administrator` credentials, which resolved both issues.
- **`fw1` (OPNsense) and Proxmox itself are deliberately outside the Restic architecture**: OPNsense has its own native configuration export (`config.xml` via the REST API), so a dedicated script (`backup-opnsense.sh`) downloads it daily and retains the last 30 copies — no Restic involved. Proxmox VM-level backups are handled by its own native `vzdump`, covering every VM except `cl1`/`cl2`, storing to local Proxmox storage — deliberately layered *alongside* Restic (file-level backups) rather than replacing it, since the two serve different restore scenarios (whole-VM snapshot vs. targeted file/data restore).
- **`bk1` has no backup of itself**: judged pointless to back up the backup server onto its own disk. The real fix — offsite replication via `rclone` to a NAS — is deferred until the Ugreen DXP4800 hardware arrives.

### Disaster-recovery hardening (later pass)

- **Frequency reduced from daily to weekly across the fleet**: with 7-day retention and daily backups, the schedule didn't match a homelab that doesn't change day-to-day. All Linux cron and Windows Task Scheduler jobs were moved from daily to weekly (Sundays), and Restic retention was changed from `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` to `--keep-weekly 4 --keep-monthly 6` (no daily tier, since none are generated). `fw1`'s OPNsense config backup was deliberately left daily, since it's lightweight (a few KB) and captures any manual config change made mid-week.
- **Live-file copies replaced with consistent dumps/snapshots wherever a database or AD store was involved** — copying an in-use database file or `ntds.dit` risks a corrupt or inconsistent backup:
  - **`db1` (PostgreSQL)**: `pg_dump odoo_prod` to a file first; the file (not the live `/var/lib/postgresql` directory) is what Restic backs up. The script aborts (`exit 1`) if the dump fails, so a broken dump never silently ships an incomplete backup.
  - **`mon1` (MariaDB/Zabbix)**: `mysqldump zabbix` to a file first, same reasoning; `/var/ossec/etc` (Wazuh config) and `/var/lib/grafana` (dashboards) were added to the path, since they live outside `/etc /home /opt /var/log`. Wazuh's OpenSearch index (~4GB) was deliberately excluded as reconstructable and not worth the space.
  - **`lx1` (Docker host)**: each named Docker volume (`portainer_data`, `wikijs_data`, `gitea_data`, `uptime_data`) is tarred via a disposable `alpine` container (`docker run --rm -v <vol>:/data ... tar czf ...`) before the Restic backup runs, since the volumes live under `/var/lib/docker/volumes/` — outside the backed-up paths entirely. Without this, a disk failure would have silently lost all four services' data even though the backup job reported success.
  - **`dc1`/`dc2` (AD DS)**: a true `wbadmin` System State backup wasn't usable because Windows refuses to write it to the same volume being backed up, and both DCs only have `C:\`. Adding a second disk was judged unnecessary. Instead, `ntdsutil ifm` (Install From Media) is used to generate a consistent NTDS + SYSVOL snapshot via VSS on the same volume, which Restic then backs up — accepted as sufficient for a homelab's AD DS + DNS scope, with the explicit caveat that it isn't a full System State (no complete registry, no COM+) and could be upgraded to `wbadmin` later if a second disk is ever added.
  - **`app1` (IIS/SQL)**: `C:\Certs\` (SSL cert/key material) and IIS's `applicationHost.config` were added to the backup, alongside the existing dynamic per-database SQL Server dump.
- **`chown sadmin:sadmin` used instead of `chown root:root` for dump/scratch directories on Linux VMs**: since `root` is inactive on the lab's Ubuntu/Debian hosts and `sadmin` (a member of the root group, using `sudo` to escalate) is the operative account everywhere else, ownership of any directory a script creates was standardized to `sadmin:sadmin` for consistency — even though the backup script itself still runs via root's crontab, since root can write anywhere regardless of directory ownership.
- **A `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WebCache` read warning on `dc1`/`dc2` was diagnosed and excluded, not treated as a real failure**: adding `C:\Windows\System32\config` to capture registry hives also pulled in a `SYSTEM`-profile browser-cache database that's permanently locked while the OS runs. Restic's "Warning: at least one source file could not be read" for this path was confirmed harmless (the file is disposable cache, irrelevant to an AD restore) and the path was added to `--exclude` to keep the backup log clean going forward.

## Step-by-Step

### Phase 1 — Repository and directory structure on bk1

```bash
mkdir -p /mnt/backups/{repos,logs,scripts}
mkdir -p /mnt/backups/repos/{dc1,dc2,fs1,app1,lx1,odoo1,db1,mon1}
```

### Phase 2 — SSH trust between bk1 and every VM

On `bk1`:
```bash
ssh-keygen -t ed25519 -C "backup01-restic" -f /root/.ssh/backup_key -N ""
cat /root/.ssh/backup_key.pub
```
That public key was authorized (`authorized_keys`) on each Linux VM's `sadmin` user, and — in the reverse direction, once the architecture flipped to push-style — each Windows VM generated its own key pair (`C:\Restic\backup_key`) which was authorized on `bk1`'s `sadmin` account instead.

SSH config alias on every Linux VM (`/root/.ssh/config`) and every Windows VM (`$env:USERPROFILE\.ssh\config`):
```
Host bk1
    HostName 10.0.20.50
    User sadmin
    IdentityFile <backup_key path for that OS>
    StrictHostKeyChecking no
```

### Phase 3 — Restic repository initialization

Password file:
```bash
echo "<restic-encryption-password>" | sudo tee /etc/restic_password > /dev/null
sudo chmod 644 /etc/restic_password
```

Repos initialized per VM (Linux, from `bk1`, then per-VM on Windows once flipped to push):
```bash
for vm in dc1 dc2 fs1 app1 lx1 odoo1 db1 mon1; do
  restic init --repo /mnt/backups/repos/$vm --password-file /etc/restic_password
done
```

### Phase 4 — Per-VM backup scripts (final, post-hardening state)

**Linux VMs** — `/usr/local/bin/backup.sh`, run by root's crontab, weekly (`0 3 * * 0`):

`mon1` (Zabbix/Grafana/Wazuh):
```bash
#!/bin/bash
export RESTIC_REPOSITORY="sftp:bk1:/mnt/backups/repos/mon1"
export RESTIC_PASSWORD_FILE="/etc/restic_password"
DUMP_DIR="/opt/backup_dumps"; DATE=$(date +%F)

mysqldump zabbix > "$DUMP_DIR/zabbix_${DATE}.sql"

restic backup --tag "mon1" --tag "auto" \
  /etc /home /opt /var/log /var/ossec/etc /var/lib/grafana \
  --exclude /var/log/journal --exclude /proc --exclude /sys --exclude /dev --exclude /run

find "$DUMP_DIR" -name "*.sql" -mtime +2 -delete
restic forget --keep-weekly 4 --keep-monthly 6 --prune
```

`lx1` (Docker host) — volumes dumped before the main backup:
```bash
for vol in portainer_data wikijs_data gitea_data uptime_data; do
  docker run --rm -v ${vol}:/data -v /opt/docker_dumps:/backup alpine \
    tar czf /backup/${vol}_$(date +%F).tar.gz -C /data .
done
# then: restic backup /etc /home /opt /var/log ...
```

`db1` (PostgreSQL) — dump replaces the live directory entirely:
```bash
sudo -u postgres pg_dump odoo_prod > "/opt/backup_dumps/odoo_prod_$(date +%F).sql"
if [ $? -ne 0 ]; then exit 1; fi
restic backup /etc /home /opt /var/log --tag "db1" --tag "auto"
```

`odoo1` — path already sufficient (`/opt/odoo/data` filestore covers the attachments); only cron frequency and retention were adjusted.

**Windows VMs** — `C:\Restic\backup.ps1`, run via Task Scheduler, weekly (`-Weekly -DaysOfWeek Sunday -At "02:30AM"`), as `PYMESIS\Administrator`:

`dc1`/`dc2` — IFM snapshot generated before the backup:
```powershell
$IFMDir = "C:\IFM"
if (Test-Path $IFMDir) { Remove-Item $IFMDir -Recurse -Force }
$ifmCmds = "activate instance ntds`r`nifm`r`ncreate sysvol full $IFMDir`r`nquit`r`nquit`r`n"
$ifmCmds | ntdsutil

restic --repo $REPO --password-file $PASSFILE backup --tag "dc1" --tag "auto" `
  "$IFMDir" "C:\Windows\System32\config" `
  --exclude "C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WebCache"

restic --repo $REPO --password-file $PASSFILE forget --keep-weekly 4 --keep-monthly 6 --prune
```

`fs1` — `D:\Shares` + `C:\Windows\System32\config`; frequency/retention only.

`app1` — dynamic per-database SQL Server dump plus `C:\Certs` and IIS config:
```powershell
$Databases = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE database_id > 4"
foreach ($db in $Databases) {
  Invoke-Sqlcmd -Query "BACKUP DATABASE [$($db.name)] TO DISK='$DumpDir\$($db.name).bak' WITH FORMAT"
}
restic backup --tag "app1" --tag "auto" `
  "C:\inetpub" "D:\AppData" "C:\Restic\sqldumps" "C:\Certs" "C:\Windows\System32\inetsrv\config"
```

### Phase 5 — FW1 and Proxmox (outside Restic)

`fw1`: `/mnt/backups/scripts/backup-opnsense.sh` on `bk1`, downloading OPNsense's `config.xml` via its REST API daily at 2:00 AM, retaining the last 30 copies.

Proxmox: native `vzdump` configured from the Datacenter UI, covering every Node 1 VM except `cl1`/`cl2`, storing to local Proxmox storage (`backup-local`).

## Problems Solved

- **`kex_exchange_identification: Connection reset by peer` connecting to `mon1`**: SSH was actually running, but the connection dropped with `exceeded LoginGraceTime` — the key hadn't been authorized yet on `mon1`, so SSH waited for a password that was never supplied and timed out. Fixed by manually pasting the public key into `mon1`'s `authorized_keys`.
- **`sudo echo "..." > /root/.restic_password` silently failed to write**: `sudo` only elevates the command before the redirection, not the shell doing the redirecting, so the write itself still ran as the unprivileged user. Fixed with `echo "..." | sudo tee /root/.restic_password > /dev/null`.
- **Restic repo init "succeeded" per the loop's own echo, but repos were actually empty/corrupt**: the `sadmin` user couldn't read `/root/.restic_password` at all, so every `restic init` call failed silently while the script's own `echo "Repo initialized"` still printed. Fixed by moving the password file to `/etc/restic_password` (644) and re-initializing all repos from scratch.
- **`chmod +x` "not working"**: turned out to be a literal typo (a stray space between `+` and `x`); using the exact syntax `chmod +x file` resolved it.
- **PowerShell mangling the SFTP command string** (`Could not resolve hostname restic`, later `Could not resolve hostname bk1`/`backup01` mismatches): passing `-o sftp.command="ssh -i ... sadmin@..."` directly broke due to PowerShell's quote handling, and separately, an SSH config alias was initially written with the wrong hostname (`backup01` instead of the VM's real short name `bk1`, and `app01` instead of `app1`, and `repos/app01` instead of `repos/app1`) — the whole fleet had already standardized on short hostnames. Fixed by correcting the SSH config alias to match the real short hostnames/repo names consistently.
- **`Rename-Item` and "restic not recognized" during Windows Restic installation**: `Rename-Item` failed because `restic.exe` already existed from a prior attempt (fixed with `-Force`, or removing first), and the freshly-updated PATH environment variable wasn't picked up by the already-open PowerShell session (fixed by reloading `$env:Path` from the Machine scope in the same session, or opening a new window).
- **`permission denied` writing to `/mnt/backups/repos/app1` from Windows over SFTP**: the directory existed but wasn't owned by `sadmin`. Fixed with `sudo chown -R sadmin:sadmin /mnt/backups/` and `chmod -R 755`.
- **`app1`'s scheduled backup silently failing, and `dc1`'s backup found "already running" the next night**: both traced to the scheduled task running as `SYSTEM`, which lacks SQL Server Express permissions (for `app1`) and which left a previous run hung on `dc1`. Both fixed by re-registering the Task Scheduler entry to run as `PYMESIS\Administrator` with explicit credentials.
- **`fs1`'s backup completing successfully but missing the actual shared data**: the original script only backed up `C:\Windows\System32\config` — `D:\Shares` (the whole point of a file server backup) had been left out. Corrected by rewriting the script to include both paths.
- **Restic warning "at least one source file could not be read" on `dc1`/`dc2`** — see Decisions above; diagnosed as a locked, disposable `WebCache` file under the registry-hive path, not an AD-related failure, and excluded explicitly.

## Final Result

Fleet-wide backup coverage, as of the hardening pass:

| VM | Repo | What's captured | Schedule | Runs as |
|---|---|---|---|---|
| `dc1` | `repos/dc1` | IFM (NTDS+SYSVOL), registry hives | Weekly, Sun 2:30 AM | `PYMESIS\Administrator` |
| `dc2` | `repos/dc2` | IFM (NTDS+SYSVOL), registry hives | Weekly, Sun 2:30 AM | `PYMESIS\Administrator` |
| `fs1` | `repos/fs1` | `D:\Shares`, registry hives | Weekly, Sun 2:30 AM | `PYMESIS\Administrator` |
| `app1` | `repos/app1` | `C:\inetpub`, `D:\AppData`, per-DB SQL dumps, `C:\Certs`, IIS config | Weekly, Sun 2:30 AM | `PYMESIS\Administrator` |
| `lx1` | `repos/lx1` | `/etc /home /opt /var/log` + Docker volume tarballs (Portainer, WikiJS, Gitea, Uptime Kuma) | Weekly, Sun 3:00 AM | root cron |
| `mon1` | `repos/mon1` | `/etc /home /opt /var/log` + Zabbix MariaDB dump, Wazuh config, Grafana | Weekly, Sun 3:00 AM | root cron |
| `odoo1` | `repos/odoo1` | `/etc /home /opt /var/log` (includes Odoo filestore) | Weekly, Sun 3:00 AM | root cron |
| `db1` | `repos/db1` | `/etc /home /opt /var/log` + PostgreSQL `pg_dump` | Weekly, Sun 3:00 AM | root cron |
| `fw1` | — (own mechanism) | OPNsense `config.xml` via REST API, 30 copies kept | Daily, 2:00 AM | `bk1` cron |
| Proxmox VMs (except `cl1`/`cl2`) | — (own mechanism) | Whole-VM `vzdump` snapshots | Native Proxmox schedule | Proxmox host |

Retention (Restic): `--keep-weekly 4 --keep-monthly 6`, no daily tier. Restic encryption password files: `/etc/restic_password` (Linux), `C:\Restic\restic_password.txt` (Windows).

## Pending

- `bk1` itself has no backup — deferred until the offsite `rclone` sync to the Ugreen DXP4800 NAS exists.
- `rclone` sync of `/mnt/backups` → NAS, to complete the 3-2-1 backup rule — blocked on that same hardware purchase.

## Cross-References

- Built directly on the disk and OS setup from [Project 5](05-debian13-bk1.md).
- Backup destinations and schedules referenced here are cited in each individual server's own project doc (e.g. [Project 3](03-windows-server-2022-dc-fs.md) for `dc1`/`dc2`/`fs1`, [Project 4](04-ubuntu-2204-lx1.md) for `lx1`).
- The short-hostname convention this project standardized on (`lx1`, `bk1`, `app1`, etc.) originates from the rename documented in [Project 4](04-ubuntu-2204-lx1.md).

---

[← **Previous:** Project 5 — Backup Server (bk1)](05-debian13-bk1.md) | [**Next:** Project 6 — Client Workstations (cl1, cl2) →](06-windows11-cl1-cl2.md)