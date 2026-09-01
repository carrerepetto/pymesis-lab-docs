---
title: 20-oracle-xe-sandbox-ora1
description: oracle-xe-sandbox
published: 1
date: 2026-09-01T19:31:33.397Z
tags: 
editor: markdown
dateCreated: 2026-08-31T11:37:38.616Z
---

# Project 20 — Oracle XE Sandbox | ora1 | VM | DBA | Rocky Linux 9.7, Oracle XE 21c |

**Previous:** [Project 19 — HashiCorp Vault (vault1)](19-hashicorp-vault-vault1.md)
**Next:** [Project 21 — IBM Db2 (lx1)](21-ibm-db2-lx1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Stand up an isolated Oracle Database XE sandbox (`ora1`) to keep Oracle DBA skills fresh without adding risk to anything productive in the lab — load the standard HR sample schema, and practice a real RMAN backup/restore cycle integrated with Restic (the same pattern already used for `pg_dump` on `db1`) and the fleet's standard monitoring agents.

## Context

This project was explicitly framed from the start as low-risk, high-skill-value practice, not something that needed to connect to anything else in the homelab. It ended up being the most demanding troubleshooting session of the project series: two full rounds of VM provisioning (a cloud-init/Terraform attempt that was ultimately abandoned, followed by manual ISO installation), and a long chain of Oracle-on-a-non-certified-distro issues before the database would even start. The extra difficulty came entirely from environmental mismatches (firmware, CPU flags, an OS Oracle doesn't officially support) rather than from anything about RMAN or the HR schema themselves — which was, after all, the actual point of the sandbox.

## Decisions Made and Rationale

- **Full VM, not LXC** — Oracle XE needs kernel-level SysV IPC/shared-memory tuning and expects to manage resources as if it owns the host; this is the same class of requirement that already forced full VMs for `harbor1`/`k3s1`.
- **Rocky Linux 9, not Ubuntu/Debian** — Oracle XE only officially supports RHEL/OL; Rocky (already used for `mon1`) gives real compatibility with Oracle's documentation and RPMs instead of fighting the installer on an unsupported distro.
- **Naming/sizing**: `ora1`, VMID 121, 4 vCPU / 6GB RAM / 60GB disk. IP was changed from the first proposal (`10.0.20.97`, next sequential slot) to `10.0.20.73` at Santiago's request, to group it in the DB slot alongside `db1` and the future `db2` (IBM DB2) rather than following pure sequential order — Rocky 9 here is explicitly scoped as just the OS base for Oracle XE, a separate concern from the still-pending standalone RHEL project.
- **Attempted the "more pro" path first**: download Rocky's official GenericCloud qcow2 image, import it as a Proxmox template (VMID 9000), and provision `ora1` via Terraform (`pymesis-infra`) with cloud-init — consistent with `glpi1`/`vault1`, and reusable for future Rocky-based VMs.
- **Abandoned the cloud-init/Terraform approach entirely** after a long, unresolved chain of boot/console/keyboard issues (see Problems Solved) — explicitly decided, when asked directly, that continuing to debug a stack of accidental complexity (GenericCloud + OVMF + noVNC + cloud-init networking) added zero value toward the sandbox's actual goal (RMAN/Zabbix/Restic practice), and reverted to plain manual ISO installation — the same proven method already used for `dc1`/`app1`/`fs1`.
- **`cpu = host` instead of `qemu64`** — chosen once identified as the actual root cause of an early kernel panic, and kept as the standing choice for future VMs on this single-node lab (no cross-host migration to worry about, so passing the full physical CPU feature set is strictly better than a generic profile).
- **Manual Oracle prerequisite setup instead of installing `oracle-database-preinstall-21c` from an added Oracle Linux repo** — that meta-package doesn't exist for OL9 at all (Oracle XE 21c predates OL9 being mainstream), so the repo add was a dead end; prerequisites (users, groups, sysctl, limits, THP) were configured by hand to match exactly what that package would have done.
- **`CV_ASSUME_DISTID=OL7`** — the actual fix that let Oracle's Cluster Verification Utility accept Rocky Linux as a valid distro; documented as the standard, well-known workaround for installing on RHEL clones rather than a lab-specific hack.
- **`-emConfiguration NONE`** for the database creation, deliberately skipping Oracle's EM Express web console — not needed for this sandbox's RMAN-focused purpose, and it was the direct cause of a persistent (and ultimately false) port-5500-in-use failure.
- **`start_on_boot` / `on_boot` set to `false` across the entire fleet** (not just `ora1`) — once the inconsistency surfaced during this project's Terraform work, it was generalized into a lab-wide policy ("nothing auto-starts") applied to every Terraform-managed resource and every `qm`/`pct`-managed VM/LXC not yet under Terraform.
- **ARCHIVELOG mode enabled** on the XE instance — Oracle XE ships in NOARCHIVELOG by default, which silently blocks hot RMAN backups; enabling it was treated as the correct, production-realistic choice for a sandbox whose whole purpose is practicing RMAN, rather than working around it with cold backups only.
- **RMAN backup staged to a host-named local directory** (`/opt/oracle/backups/ora1`, corrected from an initial `/opt/oracle/backups/rman` at Santiago's request) — enforcing the fleet's existing naming convention (name the backup staging path after the host, not the technology) before Restic picks it up, same pattern as `pg_dump` on `db1` and the Raft snapshot on `vault1`.

## Step-by-Step

### Phase 1 — Cloud-init/Terraform attempt (ultimately reverted)

- Downloaded Rocky 9's GenericCloud qcow2 image on `pve1`, imported it as Proxmox template VMID 9000 (`qm importdisk`/`qm template`), and wrote `ora1.tf` cloning that template with `initialization` (static IP `10.0.20.73/24`, DNS, `sadmin` via cloud-init `user_account` — which *does* work on VMs, unlike the LXC limitation already hit with `vault1`).
- `terraform plan` surfaced two issues before applying: the `initialization` block defaulted to `datastore_id = "local-lvm"` (not the lab's actual `local-zfs`) since it hadn't been set explicitly, and an unrelated drift on `vault1` (`start_on_boot false → true`) that turned out to be Santiago's own deliberate manual change from the GUI — clarified as intentional rather than accidental drift before applying.
- That exchange led to a fleet-wide decision to standardize `start_on_boot`/`on_boot = false` everywhere. Applying it surfaced a real Terraform quirk: LXC resources use `start_on_boot`, but VM resources use a differently-named `on_boot` — an inconsistency in the `bpg/proxmox` provider itself, not a mistake. Fixed by correcting `ora1.tf` to use the right argument name, and separately cleaned up a duplicate-declaration syntax error introduced in `glpi1.tf`/`vault1.tf` while editing them for the same change.
- Applied `ora1.tf`; the VM was created but `qemu-guest-agent` never responded (expected — GenericCloud images don't ship it preinstalled), so the console was checked directly.
- Diagnosed a boot hang at "Probing EDD... ok" — a known SeaBIOS issue with GenericCloud RHEL/Rocky images, which are built for UEFI boot on real clouds (AWS/GCP/Azure) rather than legacy BIOS. Switched the VM to `bios = "ovmf"` / `machine = "q35"` with an `efi_disk` block, which Terraform applied as an in-place update rather than a destroy+create.
- Hit a second wall after the firmware switch: the noVNC console rendered corrupted/glitched output, and neither mouse clicks, the on-screen virtual keyboard, nor `qm sendkey` could reliably interact with the GRUB/UEFI boot menu. Diagnosed the video corruption as a known `std` display + OVMF/q35 rendering issue; switching Display to VirtIO-GPU produced a clean Plymouth boot (four penguins, confirming the kernel was loading correctly this time), but the VM then never came up on the network — cloud-init's `ip_config` never applied, and with no password set for `sadmin` (SSH-key-only), there was no way to log in at the console to diagnose why.
- At that point, explicitly asked whether to keep debugging or make a decision — chose to abandon the cloud-init/Terraform path entirely rather than continue. Removed `ora1.tf` and the Terraform state entry (`terraform state rm`, chosen over `terraform destroy` specifically because the VM's inconsistent state made destroy's dependency on a live QEMU agent response risky), destroyed the VM and the now-unneeded template 9000, and cleaned up the downloaded cloud image.

### Phase 2 — Manual installation from ISO

- Created VM 121 by hand with `qm create` (SeaBIOS default this time — fine for a normal Anaconda installer, since the EDD-probing bug was specific to the GenericCloud image, not BIOS/legacy boot in general), booted from the already-uploaded Rocky 9.7 minimal ISO.
- Hit a kernel panic partway into the installer — root-caused to the VM's CPU type (`qemu64`), a generic profile that lacks instruction sets (SSE4.2, POPCNT, etc.) that RHEL9/Rocky9 kernels require (x86-64-v2 baseline). Fixed with `qm set 121 --cpu host`, after which the installer booted cleanly.
- Completed the Anaconda install: static network (`10.0.20.73/24`, gateway `10.0.20.1`, DNS `10.0.20.10`, hostname `ora1.pymesis.lab`), automatic partitioning on the 60GB disk, `sadmin` created as an administrator with a password (no SSH key available at install time, unlike the cloud-init path), root password set with SSH root login left to be disabled afterward.
- Confirmed a clean boot to the `ora1 login:` prompt and successful SSH from `lx1` — the entire prior cloud-init/OVMF ordeal was two isolated, unrelated bugs (SeaBIOS+GenericCloud, then CPU type), both now resolved by simply not using that path.
- Detached the installer ISO from the virtual CD-ROM and applied the fleet's standard SSH hardening (`passwd -l root`, `PermitRootLogin no`), verified by confirming a direct `ssh root@10.0.20.73` was rejected — deliberately left `PasswordAuthentication yes` for now, since `sadmin` had no SSH key loaded from the manual install (flagged as a follow-up to add a key and disable password auth later, for full consistency with the rest of the fleet).

### Phase 3 — Oracle XE prerequisites and installation

- Confirmed `oracle-database-preinstall-21c` isn't available in Rocky's AppStream repos (expected — it's OL-specific) and manually replicated everything that package would normally configure: dependency packages, the `oracle`/`oinstall`/`dba` user and groups, Oracle's standard `sysctl` kernel parameters, user resource limits, and disabling Transparent Huge Pages via `grubby` (requiring a reboot to take effect, done before touching the XE installer itself).
- Downloaded and installed the Oracle XE 21c RPM (built for OL8, binary-compatible with Rocky). The dependency-checked `dnf install` failed since the formally-named `oracle-database-preinstall-21c` package wasn't present even though its actual prerequisites were satisfied by hand — worked around initially with `rpm -ivh --nodeps`, which surfaced a deeper problem: the post-install Java installer (OUI) crashed with `NoClassDefFoundError`/`UnsatisfiedLinkError` because the missing preinstall package also normally sets `LD_LIBRARY_PATH` for Oracle's native installer library, which was never set.
- Attempted to add Oracle Linux 9's repo just to install the real `oracle-database-preinstall-21c` package — this itself turned out to be a dead end, since that meta-package was never published for OL9 at all (Oracle XE 21c predates OL9 as a mainstream target). Abandoned that route and instead set the required environment variables directly via a `/etc/profile.d/oracle-xe.sh` script (`ORACLE_HOME`, `LD_LIBRARY_PATH`, `PATH`), reinstalled the RPM cleanly (this time via `dnf`, with the dependency actually satisfied in substance if not in RPM's formal bookkeeping), and re-ran `/etc/init.d/oracle-xe-21c configure`.
- Hit and resolved, one after another: `sudo -E` failing to propagate the new environment variables to the actual configure process (root-caused to `su oracle -c` not sourcing `/etc/profile.d/` without a login shell — fixed with `sudo -i` for a real root login shell instead); a missing `libnsl.so.1` legacy compatibility library that RHEL9/Rocky9 doesn't install by default (`dnf install -y libnsl`); a persistent EM Express port-5500 "in use" failure during `dbca` that turned out to be a false positive (`ss`, `lsof`, and a review of active sockets all confirmed nothing was actually listening there) — resolved not by chasing the phantom conflict but by explicitly excluding EM Express from the database creation (`-emConfiguration NONE`) since it wasn't needed for this sandbox anyway; and a broken `/opt/oracle/homes/OraDBHome21cXE` reference (a directory left behind by earlier failed attempts, which needed to be removed before the correct symlink to the real `$ORACLE_HOME` could be created — the first symlink attempt silently nested itself *inside* the stale directory instead of replacing it).
- Reconstructed the exact `dbca` invocation by reading `/etc/init.d/oracle-xe-21c` directly (grepping for `dbca`, then for each variable it references) rather than guessing parameters, after the wrapper script's own `configure` kept failing in ways that needed the real command line to diagnose.
- Hit a `NullPointerException` inside `dbca -silent` that took three iterations to fully resolve: first suspected (and ruled out) a missing `-totalMemory` value; then found and fixed a missing `/etc/oraInst.loc` (needed by CVU to locate the Oracle inventory) — necessary but not sufficient; then, reading the actual DBCA trace log directly rather than the generic on-screen summary, found the real root cause: Oracle's Cluster Verification Utility doesn't recognize "Rocky Linux" in its list of certified distributions and falls into a null-cascade inside `StorageUtil`'s static initialization. Fixed with the well-documented `CV_ASSUME_DISTID=OL7` workaround for installing on RHEL clones, exported before invoking `dbca` as the `oracle` user (a `locale`/`LANG` theory was also checked and ruled out along the way, since it initially looked structurally similar).
- With that fix, `dbca` completed successfully — SID `XE`, PDB `XEPDB1` — with one benign, well-known `ORA-29283` warning during a non-critical QOPATCH metadata step. Verified the instance directly via `sqlplus / as sysdba` (run correctly as the `oracle` OS user, after an initial attempt as `root` failed on Oracle's OS-authentication requirement).

### Phase 4 — Fleet-standard agents

- **QEMU Guest Agent**: installed and enabled inside the VM (the package itself, `agent { enabled = true }` in Terraform not applicable since this VM ended up fully outside Terraform — corrected after an initial suggestion assumed otherwise).
- **Zabbix Agent 2**: installed from the official 7.0 RHEL9 repo (no workarounds needed here, unlike Oracle), configured to point at `mon1` (`10.0.20.60`), hostname `ora1`.
- **Wazuh Agent**: installed from the official repo with `WAZUH_MANAGER` pre-set, confirmed all five internal processes active.
- **GLPI Agent**: first download attempt 404'd on a guessed RPM filename (turned out to be `.noarch.rpm`, not `.x86_64.rpm`, since GLPI Agent is pure Perl); switched to the officially-recommended Perl installer script instead of the raw RPM (avoiding the same class of dependency headaches already suffered with Oracle), which also required installing `perl` first (absent on this genuinely minimal Rocky install, unlike the other Debian-based LXCs in the fleet where a minimal Perl ships by default). Installed cleanly, confirmed the target server registered correctly, and forced an immediate check-in with `--force` rather than waiting for the agent's randomized first-run delay.

### Phase 5 — Restic + RMAN backup

- Generated a dedicated SSH keypair for backups (root on `ora1` → `sadmin` on `bk1`), following the same pattern as `vault1`/`db1`, and initialized a Restic repo at `sftp:sadmin@bk1:/mnt/backups/repos/ora1`.
- Wrote `/root/backup-ora1.sh`: RMAN takes a compressed backup set of the database plus archived logs and a current controlfile backup to a local staging directory, then Restic backs up that staging directory (never the live datafiles) and applies the fleet-standard retention (`--keep-daily 7 --keep-weekly 4 --prune`). Corrected the staging path from an initial `/opt/oracle/backups/rman` to `/opt/oracle/backups/ora1` at Santiago's request, to keep the convention of naming backup paths after the host, not the technology.
- Hit and fixed a classic `sudo cat > file` redirection bug (the redirection runs as the unprivileged shell, not under `sudo`) by switching to `sudo tee`.
- The first manual test run failed with `ORA-01034: ORACLE not available` — the instance had never been configured to start automatically (only the listener was a systemd service; the database itself depended on the `/etc/oratab` `Y` flag plus a manual `dbstart`/`dbshut`, which had never run since a reboot). Fixed by correcting the `oratab` entry and wrapping `dbstart`/`dbshut` in a proper `oracle-xe.service` systemd unit, enabled at boot — consistent with how the rest of the fleet's services are managed.
- The second test run failed because Oracle XE runs in `NOARCHIVELOG` mode by default, which blocks both `BACKUP ... PLUS ARCHIVELOG` and any RMAN hot backup of an open database. Enabled `ARCHIVELOG` mode (`SHUTDOWN IMMEDIATE` → `STARTUP MOUNT` → `ALTER DATABASE ARCHIVELOG` → `ALTER DATABASE OPEN`) — treated as the correct fix for a sandbox meant to practice realistic RMAN usage, not an obstacle to route around.
- With that resolved, the full script ran clean end-to-end: RMAN backed up all three containers (CDB root, `XEPDB1`, `pdbseed`) plus a controlfile autobackup; Restic uploaded and compressed it (19 MiB → 295 KiB) and applied retention. Added the fleet-standard 3 AM cron entry.

### Phase 6 — Disaster-recovery validation

- Deliberately simulated data loss to validate the backup actually works, rather than declaring the project done on a green backup log alone: closed `XEPDB1`, deleted its `users01.dbf` datafile, and confirmed the expected `ORA-01157` failure when attempting to reopen the PDB.
- Ran `RESTORE DATAFILE 12` / `RECOVER DATAFILE 12` via RMAN against the backup just taken, then reopened the PDB successfully (`READ WRITE`) — validating the full cycle: backup → simulated damage → detection → restore → recover → open.

### Phase 7 — HR sample schema

- Downloaded Oracle's official `db-sample-schemas` repository — first attempt used a guessed tag (`v21c`) that doesn't exist; found and used the correct tag (`v21.1`) instead.
- Hit a `__SUB__CWD__` path-substitution bug of its own making: running the `sed` replacement from *inside* `human_resources/` (rather than its parent directory) caused every generated path to duplicate the folder name (`.../human_resources/human_resources/...`), since the installer scripts already append that subdirectory internally. Fixed by re-extracting cleanly and running the substitution from the parent directory instead.
- Hit a connection-string confusion caused by an earlier, unrelated discovery mid-project: the listener had ended up running on port 1522, not the Oracle-standard 1521, from an earlier `netca` reconfiguration during the DB-creation troubleshooting — resolved by connecting on the correct port instead of assuming the default.
- First HR install attempt left the `HR` user only partially created (`SP2-0137`/`ORA-01031` errors) because two required parameters (log path, connect string) were left blank at an interactive prompt, breaking internal script variable substitution. Cleaned up the partial user (`DROP USER hr CASCADE`) and re-ran the installer passing all six parameters explicitly on the command line instead of relying on interactive prompts.
- Final install completed cleanly: all 7 HR tables, the `EMP_DETAILS_VIEW`, indexes, triggers, and procedures created and populated without errors. Verified with row counts: 107 employees, 27 departments — the standard, expected numbers for Oracle's HR sample data.

### Phase 8 — Post-close monitoring gap (agents installed but not reporting)

Raised by Santiago after the project was otherwise considered complete: agents were installed and running, but `ora1` wasn't showing up as active in Zabbix, GLPI, or Wazuh.

- Diagnosed methodically rather than assuming a single common cause: confirmed outbound HTTPS to `glpi1` and outbound to `mon1`'s Zabbix trapper port both worked, which ruled out a fully-blocking local firewall, DNS, or clock skew as one shared root cause — the three services turned out to have three different, unrelated explanations.
- **Zabbix**: the local `firewalld` only allowed `cockpit`/`dhcpv6-client`/`ssh` inbound — since this host's Zabbix template uses passive checks (server-initiated, port 10050), the agent was running but unreachable from `mon1`. Fixed by opening `10050/tcp` in `firewalld`.
- **GLPI**: the manually-ISO-installed Rocky system had never imported `pymesis-DC01-CA`'s root certificate (unlike the other VMs, which picked it up via cloud-init, GPO, or an earlier manual step) — the agent's HTTPS check-in was failing TLS verification silently. Fixed by importing the CA cert into the system trust store (`update-ca-trust extract`). A second, unrelated issue then surfaced right after — the GLPI agent couldn't write to its own state directory (`/var/lib/glpi-agent`) — fixed with corrected ownership/permissions and forcing a `sudo`-run check-in (the earlier `--force` test had been run without `sudo`, mismatching the service's root ownership).
- **Wazuh**: turned out to be a false alarm — the agent had already connected successfully; the earlier `tail` of `ossec.log` simply landed after a midnight log rotation and never showed a fresh connection event, giving the appearance of no activity when the agent was in fact already registered and reporting.

## Problems Solved

- SeaBIOS hung indefinitely at "Probing EDD" with Rocky's GenericCloud image — a known incompatibility between BIOS-legacy disk probing and cloud images built for UEFI boot on real cloud providers; the underlying fix (switch to OVMF/q35) worked, but a subsequent chain of noVNC display-corruption and keyboard-capture issues (traced to the `std` display adapter under q35/OVMF) made the console unusable regardless, and was the deciding factor in abandoning the cloud-init path entirely rather than continuing to chase display bugs.
- Cloud-init never applied the static IP configuration on the one successful OVMF boot achieved — never root-caused, since the whole approach was abandoned before further diagnosis, but flagged clearly as a separate networking-layer failure from the firmware issue.
- The `bpg/proxmox` Terraform provider uses different argument names for the same concept on VMs (`on_boot`) versus LXCs (`start_on_boot`) — caught via a plan error and fixed per-resource-type, then generalized into copying the correct convention to every Terraform-managed host in the fleet.
- A VM kernel panic during Anaconda boot was caused by the `qemu64` CPU profile lacking instruction sets RHEL9/Rocky9 kernels require — fixed with `cpu = host`, unrelated to any of the prior firmware/console issues (a good example of one VM surfacing two entirely independent classes of bug).
- Oracle XE's RPM formally depends on `oracle-database-preinstall-21c`, a package that both (a) isn't in Rocky's default repos and (b) was never published for OL9 at all — installing with `--nodeps` "succeeded" but left the Java-based installer unable to find its native library (`LD_LIBRARY_PATH` never set), which the missing package would normally have configured; fixed by setting the environment manually and understanding that `sudo -E` doesn't propagate into a `su -c` subshell without a login shell (`sudo -i` was needed instead).
- A missing legacy `libnsl.so.1` library (removed by default on RHEL9/Rocky9) silently blocked the Oracle configure script — a hard requirement of the old-style installer, unrelated to environment variables.
- `dbca` reported EM Express port 5500 as in use when nothing was actually listening there — a stale internal check rather than a real conflict; resolved by skipping EM Express entirely (`-emConfiguration NONE`) rather than chasing a phantom process.
- A broken `/opt/oracle/homes/OraDBHome21cXE` symlink target (left over from earlier failed install attempts) caused `dbca`'s network configuration step to fail — the first fix attempt itself failed silently because `ln -sfn` nested the new symlink *inside* a stale real directory instead of replacing it; resolved by removing the stale directory first.
- `dbca -silent` threw a `NullPointerException` that took three rounds of investigation to fully diagnose: ruled out missing memory sizing and a missing `/etc/oraInst.loc` (both real gaps, both fixed, neither sufficient alone) before finding the actual cause by reading the raw DBCA trace log directly — Oracle's Cluster Verification Utility doesn't recognize Rocky Linux as a certified distribution, causing a null cascade; fixed with the documented `CV_ASSUME_DISTID=OL7` workaround.
- The RMAN backup script failed with `ORA-01034` after a reboot because only the listener, not the database instance itself, had been wired into systemd — fixed with a proper `oracle-xe.service` unit wrapping `dbstart`/`dbshut`, and a corrected `/etc/oratab` autostart flag.
- The RMAN backup script then failed a second time because Oracle XE ships in `NOARCHIVELOG` mode by default, which blocks hot backups with archivelog inclusion — fixed by properly enabling `ARCHIVELOG` mode, treated as the correct production-realistic fix rather than a workaround.
- `sudo cat > /root/file` silently failed to write as root, because the output redirection runs under the calling user's shell, not under `sudo` — fixed with `sudo tee` (same class of mistake already documented elsewhere in the lab's Ansible work).
- The HR sample schema installer's `__SUB__CWD__` substitution was run from the wrong directory, duplicating a path segment in every generated script reference — fixed by re-running the substitution from the schema's parent directory instead of from inside `human_resources/`.
- The HR installer partially created the `HR` user and then failed on `GRANT` statements because two parameters were left blank at an interactive prompt, breaking internal `DEFINE` variable substitution — fixed by dropping the partial user and re-running with all parameters passed explicitly on the command line.
- Agents were installed and running correctly but appeared inactive in all three monitoring tools for three unrelated reasons: `firewalld` blocking inbound Zabbix passive checks (10050), a missing internal CA certificate causing silent TLS failures for GLPI's HTTPS check-in (an artifact of the manual-ISO install path never receiving the CA the other VMs got via cloud-init/GPO), and a Wazuh false alarm caused by reading a freshly-rotated log file that simply hadn't logged a new connection event since the agent was already connected.

## Final Result

- **VM**: `ora1` (Rocky Linux 9.7, VMID 121, `10.0.20.73`, `cpu=host`), installed manually from ISO — outside Terraform, by deliberate decision after the cloud-init approach was abandoned. SSH root login disabled; `sadmin` currently password-authenticated (SSH-key hardening flagged as a follow-up).
- **Database**: Oracle XE 21c, SID `XE`, PDB `XEPDB1`, running in `ARCHIVELOG` mode, with the standard HR sample schema loaded (107 employees, 27 departments) as practice data.
- **Fleet-standard agents**: QEMU Guest Agent, Zabbix Agent 2, Wazuh Agent, and GLPI Agent all installed, running, and — after resolving three separate post-close issues (firewall, CA trust, log-rotation confusion) — actually visible and reporting in each respective console.
- **Backup**: RMAN (compressed backup set + archivelogs + controlfile autobackup) staged locally, then packaged and shipped to `bk1` by Restic via a dedicated SSH key, with fleet-standard retention and a 3 AM cron entry.
- **Disaster recovery validated end-to-end**: a deliberately deleted datafile was successfully restored and recovered via RMAN from the automated backup, and the PDB reopened cleanly.
- **Fleet-wide side effect**: the `start_on_boot`/`on_boot = false` policy, first identified as inconsistent during this project's Terraform work, was standardized across every VM and LXC in the lab, both Terraform-managed and manually-managed.

## Pending

- `sadmin` on `ora1` is still password-authenticated over SSH rather than key-only, unlike the rest of the fleet — flagged during the initial hardening pass, not yet closed.
- The root cause of cloud-init never applying the static IP on the one OVMF boot that got far enough to reach Plymouth was never diagnosed — moot for this project since the whole approach was abandoned, but worth knowing if cloud-init/Terraform is ever retried for a future Rocky VM.
- Oracle-related project decisions (RHEL as its own future project, distinct from this Rocky-based sandbox) remain on the roadmap as previously scoped.

## Cross-References

- Project 8 — Odoo/PostgreSQL (odoo1/db1), whose `pg_dump`-then-Restic backup pattern this project's RMAN-then-Restic script directly follows.
- Project 19 — HashiCorp Vault (vault1), whose Restic/dedicated-SSH-key backup pattern (and `start_on_boot` naming-convention discovery) this project reused and extended fleet-wide.
- Project 17 — Terraform/IaC (lx1), the repo the abandoned `ora1.tf` briefly lived in.
- Project 10 — GLPI (glpi1), the inventory server `ora1`'s GLPI Agent reports to.
- Project 9 / 9.1 — Monitoring stack, Zabbix/Wazuh (mon1), the server side of `ora1`'s agents.
- Project 5 / 5.1 — Backups, Restic (bk1), the destination for `ora1`'s RMAN backups.
- Project 21 — IBM DB2 (lx1), the next sandbox database project.

---

[← **Previous:** Project 19 — HashiCorp Vault (vault1)](19-hashicorp-vault-vault1.md) | [**Next:** Project 21 — IBM Db2 (lx1) →](21-ibm-db2-lx1.md)