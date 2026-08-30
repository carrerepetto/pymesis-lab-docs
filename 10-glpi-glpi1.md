---
title: 10-glpi-glpi1
description: glpi
published: 1
date: 2026-08-30T07:31:47.801Z
tags: 
editor: markdown
dateCreated: 2026-08-28T21:02:03.427Z
---

# Project 10 — GLPI Installation (glpi1)

**Previous:** [Project 9 — Rocky Linux 9.4 Installation (mon1)](09-rocky-mon01.md)
**Next:** [Project 11 — Harbor and CI/CD Installation (hr1)](11-harbor-cicd-hr1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Add an ITSM/asset-management platform (GLPI) to pymesis.lab, deployed as a lightweight LXC container rather than a full VM, integrated with the existing Active Directory, monitoring, and backup stack — and use it as the first of a new wave of homelab projects chosen deliberately to close gaps against Santiago's professional CV.

## Context

This project opened as a broader planning conversation: with only one physical node (64 GB RAM, ~12 VMs already running), the question was which new projects were worth adding next. After Santiago shared his CV, the selection criteria shifted from generic "interesting homelab ideas" (eShop, a second Odoo instance, Power BI, etc.) to a CV-gap analysis: his background is strong in classic enterprise SysAdmin/DBA/ERP work, but shows no hands-on Kubernetes, Infrastructure as Code, CI/CD, or **ITSM administration** (despite Jira/ServiceNow appearing on the CV as tools *used*, not *administered*). GLPI was chosen as the first project specifically because it's the open-source counterpart to that ITSM gap, and because it comfortably fits current resources as an LXC.

## Decisions made and why

- **LXC container instead of a full VM** — GLPI is a PHP + MySQL application; running it as a full VM would waste RAM/overhead the single-node lab can't spare, especially with several other new projects (Harbor, Odoo migration, LLM, eShop) competing for the same 64 GB.
- **Overall project prioritization: GLPI → Harbor/CI-CD → Odoo 17→18 migration → private LLM → eShop → Terraform → single-node K3s**, with a real multi-node K3s cluster deliberately left in standby until a second physical node and switch arrive — learning K8s orchestration properly needs more than one node, and forcing a single-node cluster now "just for the CV logo" was judged not worth it.
- **MariaDB installed locally inside the GLPI1 LXC rather than provisioning a separate DB2 instance** — GLPI's database load is light enough that a dedicated database VM/LXC would be unjustified overhead.
- **Local authentication first, LDAP against DC1 added as a second phase** — let the application stack stabilize before adding directory integration.
- **HTTPS via Nginx as a reverse proxy in front of Apache**, reusing the exact certificate pattern already established for LX1/ODOO1/APP1 (OpenSSL CSR with SAN, signed via `certreq` against the lab's Enterprise Root CA) rather than inventing a new approach.
- **VLAN tagging convention clarified and confirmed during this project, not previously documented explicitly:** `vmbr1` is a trunk carrying all VLANs; it is *not* configured as a VLAN-aware bridge globally — instead, each individual VM/LXC's network interface carries its own `tag=` (20 for servers, 10 for the CL1/CL2 workstations). This had been the lab's real practice all along but surfaced explicitly here when GLPI1's LXC network config needed the tag added.
- **LDAP kept on plain port 389 temporarily instead of LDAPS (636) while the TLS trust chain was being debugged**, then migrated back to LDAPS once resolved — accepted as a reasonable, temporary trade-off since the traffic stays entirely inside VLAN20, not exposed elsewhere; documented as "production-realistic without over-engineering," consistent with decisions made elsewhere in the lab.
- **LDAP connection to DC1 addressed by FQDN (`dc1.pymesis.lab`) rather than by IP** — required once it became clear that LDAPS certificate validation fails on a CN/SAN mismatch when connecting by IP instead of the name the certificate was actually issued for.
- **All server VMs/LXCs (IT, HelpDesk, HR alike) are imported into GLPI from LDAP, not filtered at import time** — filtering happens afterward via authorization rules, not by restricting who gets imported. HR needs a GLPI account too, just with a different profile (Self-Service, to open tickets) rather than Technician.
- **IT/HelpDesk users deliberately left with both `Technician` and `Self-Service` profiles rather than restricting them to `Technician` only** ("Option A") — a valid, common ITSM pattern letting technicians switch to a personal end-user view when opening their own tickets, chosen over the more restrictive alternative.
- **Backup cron for GLPI1 runs as `root`, not as `sadmin`** — a deliberate departure from the lab's usual `sadmin`-owned cron pattern, made because Restic needs to read GLPI's OAuth key files and session data (owned by `www-data`, unreadable by `sadmin`) — running as root avoids having to loosen GLPI's own file permissions or add `sadmin` to the `www-data` group.
- **Session files under `/var/www/glpi/files/_sessions` explicitly excluded from the Restic backup** — transient data with no recovery value, regenerated automatically on next login.
- **The local `glpi`/`glpi` Super-Admin account was flagged as needing a password change but the decision to actually change it was left to Santiago**, who chose not to change it since day-to-day login goes through LDAP — Claude pushed back once, explicitly framing it as the one real security recommendation of the project (that account is still the highest-privilege account and the first credential any automated scanner tries), then respected the final call.
- **The LDAP "Replicates" entry was corrected to point at DC2 for genuine failover, rather than being left duplicating DC1's own address** (which, as initially configured, provided no redundancy at all).
- **FW1 (OPNsense) deliberately excluded from GLPI Agent-based inventory** — not a gap to fix, but an architectural limitation: GLPI Agent has no official FreeBSD build, so OPNsense simply isn't a supported target for this particular inventory mechanism.

## Step by step

### 1. Create the LXC in Proxmox
- Specified: Debian 12, 2 vCPU, 3 GB RAM, 20 GB disk, hostname `glpi1`, VMID 112, static IP 10.0.20.80 on VLAN20.
- Corrected the storage pool from the initially assumed `local-lvm` to the lab's actual pool, `local-zfs`, after `pct create` failed with "storage does not exist" — confirmed via `pvesm status`.
- Corrected the Debian 12 template filename twice as the exact available version changed (`12.7-1` → `12.12.1` → the real name `12.12-1`, confirmed via `pveam list local`) — the originally-referenced template version was simply no longer available in the repo.
- Added the missing `tag=20` to the LXC's `net0` line once the trunk/per-VM-tagging convention was clarified (see decisions above).
- Bootstrapped the container: installed `sudo` (not present on the minimal Debian template by default — required before `usermod -aG sudo sadmin` would even work), created `sadmin`, set timezone to `Europe/Rome`.

### 2. Install Apache, PHP 8.2, MariaDB, and GLPI 11.0.8
- Installed Apache2, MariaDB, and the full set of PHP extensions GLPI requires (`curl`, `gd`, `imap`, `ldap`, `mysqli`, `xml`, `mbstring`, `bz2`, `intl`, `zip`, `apcu`, `cas`), all available directly from Debian 12's repos (no external PHP repo needed).
- Ran `mysql_secure_installation`, keeping password-based root auth (declined the switch to `unix_socket`) since the setup relies on `mysql -u root -p` in later steps.
- Created the `glpi` database and a dedicated `glpi` MySQL user/password (kept intentionally separate from MariaDB's root password), and enabled `log_bin_trust_function_creators` (required by GLPI for its triggers) — first attempt failed to restart MariaDB due to a typo (`funtion` instead of `function`) in the config line, caught via `journalctl` and corrected.
- Downloaded and extracted GLPI 11.0.8 to `/var/www/glpi`, set ownership to `www-data`.
- Configured an Apache VirtualHost pointing `DocumentRoot` at `/var/www/glpi/public` — noted as a common gotcha for anyone following an older guide, since GLPI 10+ changed the document root from `/glpi` to `/glpi/public`.
- Completed the web installer: accepted the GPL v3 license, resolved a missing `php-bcmath` module flagged by the compatibility check, entered the MySQL connection details, and finished the wizard (which handles removing the install script itself in GLPI 11.x).

### 3. Add HTTPS via Nginx + the lab's internal CA
- Generated a private key and CSR with SAN (`glpi1.pymesis.lab`, `glpi1`, IP 10.0.20.80) via OpenSSL, then issued the certificate through the same `certreq -submit -attrib "CertificateTemplate:WebServer"` flow used for LX1/ODOO1/APP1.
- Reconfigured Apache to listen only on `127.0.0.1:80` (freeing the public port 80/443 for Nginx) and set up Nginx as the HTTPS-terminating reverse proxy in front of it, with an HTTP→HTTPS 301 redirect.
- Fixed a port-binding conflict: binding Nginx to the wildcard `0.0.0.0:80` failed with "Address already in use" even though Apache was correctly restricted to `127.0.0.1:80` — a Linux kernel quirk where a wildcard bind is rejected if the loopback address on that port is already taken. Resolved by binding Nginx explicitly to the container's real IP (`10.0.20.80:80`/`:443`) instead of the wildcard.
- Fixed the CA root certificate silently failing to install into the system trust store (`update-ca-certificates` reporting "0 added") because the file had a `.cer` extension instead of the `.crt` the tool expects; also flagged (and checked) the possibility of a DER-vs-PEM format mismatch, a related common gotcha when certificates come from a Windows CA.
- Updated GLPI's `url_base` configuration value to `https://glpi1.pymesis.lab` and confirmed HTTPS access from a domain client that already trusts the CA via GPO.

### 4. Integrate LDAP authentication against DC1
- Created a dedicated `svc-glpi` service account in a new `Service Accounts` OU in AD (rather than using the domain Administrator account), via `New-ADUser` with an interactively-entered password.
- Configured the LDAP Directory in GLPI (`pymesis-DC1`, Base DN `DC=pymesis,DC=lab`, filter `(objectClass=user)`, login attribute `sAMAccountName`), fixing several initial misconfigurations found during review: the directory left `Active = No`, `Default Server = No`, an authenticated bind enabled but with empty RootDN/password, and a malformed LDAPS URL (IP + port 636 without the `ldaps://` scheme).
- Started on plain LDAP (port 389) as an interim step while resolving TLS issues, confirming a fully green 5/5 test (including a successful bind and a 13-entry search) before proceeding.
- Migrated to LDAPS (636) and debugged a `Bind connection: Authentication failed: Can't contact LDAP server(-1)` error methodically: confirmed the port was reachable (`telnet`), confirmed the TLS handshake itself succeeded via `openssl s_client` (`Verify return code: 0`), and finally traced the actual cause to a hostname-verification mismatch — DC1's certificate is issued for `dc1.pymesis.lab`, not its IP, and `libldap`/PHP enforce strict hostname checking where `openssl s_client` doesn't by default. Fixed by connecting to `ldaps://dc1.pymesis.lab` instead of the IP, after confirming GLPI1 could resolve that name via DC1's DNS.
- Also worked through a related environment gap: `/etc/ldap/ldap.conf` (needed to point the system LDAP library at the CA trust bundle via `TLS_CACERT`) didn't exist because `libldap-common` wasn't installed alongside `php-ldap`; installed it and set the directive.

### 5. Deploy Zabbix and Wazuh agents on GLPI1
- Installed `zabbix-agent2` from the official Debian 12 repo package, set `Server`/`ServerActive`/`Hostname` in `zabbix_agent2.conf`.
- Diagnosed a host staying red (unreachable) in Zabbix despite the agent clearly running: the `Hostname=` change hadn't taken effect because the agent process had started *before* the config edit and kept serving its old in-memory hostname (`Zabbix server`) — resolved with a service restart, after which the host went green.
- Installed the Wazuh agent (`.deb`), hitting the same missing-`lsb-release` dependency issue seen on other Debian/Ubuntu VMs earlier in the lab; also hit a follow-on problem where a subsequent `--reinstall` (run without re-passing the `WAZUH_MANAGER` environment variable) left a literal, unreplaced `<address>MANAGER_IP</address>` placeholder in `ossec.conf` — corrected manually to `10.0.20.60`.

### 6. Set up Restic backups to BK1
- Installed `restic` (not preinstalled on Debian), created `/etc/restic_password`, and initialized a repository at `sftp:sadmin@bk1:/mnt/backups/glpi1`.
- Debugged SSH key-based auth to BK1 failing repeatedly despite `ssh-copy-id` reporting success and file permissions on GLPI1's side looking correct: root cause, found by cross-checking file ownership directly on BK1, was that `/home/sadmin/.ssh/authorized_keys` on BK1 had somehow ended up owned by `root` instead of `sadmin` — `sshd` silently ignores an `authorized_keys` file not owned by the authenticating user, falling back to a password prompt with no explicit error. Fixed with `chown sadmin:sadmin` on the file (and `.ssh` directory) on BK1.
- Hit the identical root-ownership pattern a second time on GLPI1 itself: `/etc/restic_password`, created earlier with `sudo tee`, ended up owned by `root:root`, so `sadmin` couldn't read it even though the file mode looked permissive enough — fixed with `chown sadmin:sadmin`.
- Ran a manual backup once the repo and SSH auth were working; it partially succeeded but reported several `permission denied` errors on GLPI's OAuth key/session files (owned by `www-data`). Resolved by (a) excluding the sessions directory from the backup scope, since it's transient data, and (b) moving the scheduled cron job from `sadmin`'s crontab to `root`'s, since root can read any file on the system without needing to touch GLPI's own file permissions.
- Final cron (root): a MySQL dump at 2:45 AM Sunday, followed by the Restic backup and a `forget --keep-weekly 4 --keep-monthly 6 --prune` retention policy at 3:00 AM — matching the lab-wide weekly Restic pattern.

### 7. Functional GLPI configuration
- Enabled the native inventory engine (Setup → General → Assets) and confirmed the resulting agent check-in endpoint (`/front/inventory.php`).
- Built a 3-level ITIL category hierarchy (Infrastructure/Applications/Workstation, each with sub-categories mapping to the lab's real infrastructure — networking/firewall, virtualization, AD, backup, ERP, database, etc.) — done directly by Santiago and confirmed as more thorough than the initial suggestion.
- Imported all LDAP users (IT, HelpDesk, HR) rather than filtering at import time, then built authorization rules to auto-assign profiles by OU:
  - Debugged a first rule design that would have let a catch-all "Default → Self-Service" rule silently override the IT/HelpDesk-specific rule, because GLPI evaluates *all* matching rules (not just the first one) and a later rule's action can override an earlier one on the same field. Fixed by adding explicit `does not contain OU=IT` (and `OU=HelpDesk`) exclusion conditions to the fallback rule, and confirming rule execution order.
  - Discovered along the way that "HelpDesk" in this AD is a **security group**, not a separate OU — both IT and HelpDesk staff live under the same `OU=IT`, which meant the dedicated HelpDesk-OU rule was harmless but redundant (the IT-OU rule alone already covered both users).
  - Clarified a follow-up observation that IT/HelpDesk users ended up with *both* `Technician` and `Self-Service` profiles rather than only `Technician` — not a bug, but GLPI's normal behavior of accumulating profiles (a system-wide default profile applies to every new user in addition to whatever the LDAP rules assign) — confirmed as the desired outcome (Option A above) rather than something to fix.
- Re-synced already-imported users against the newly created rules (rules don't apply retroactively on their own) and confirmed the expected result: IT/HelpDesk users with Technician + Self-Service, the HR user with Self-Service only.

### 8. Deploy GLPI Agent for dynamic inventory across the fleet
- **Linux (LX1, ODOO1, DB1, MON1, BK1, GLPI1 itself):** used the official Perl installer (`glpi-agent-1.18-linux-installer.pl`) pointed at `https://glpi1.pymesis.lab/front/inventory.php`, run with `--runnow --service` on each VM.
- **Windows (DC1, DC2, FS1, APP1, CL1, CL2):** rather than touching each machine by hand, packaged the deployment as a Group Policy startup script — copied the GLPI Agent MSI to an SMB share on FS1, wrote a small PowerShell wrapper that checks for an existing `GLPI-Agent` service before reinstalling (avoiding redundant reinstalls on every GPO refresh), and linked a new GPO (`Deploy-GLPI-Agent`) running that script at machine startup.
- Confirmed inventory data arriving in GLPI's Assets → Computers view as agents checked in.
- **FW1 excluded by design** (see decisions) — no official GLPI Agent build exists for FreeBSD/OPNsense.
- **Later, in a separate follow-up session (17 August), the same Perl installer was used on a newly-built VM ("vault1")** and initially failed silently (the installer printed its own `--help` text and exited) because an invalid flag, `--no-httpd-trust`, had been passed — not a recognized installer option (the valid form is `--httpd-trust=IP`, with no negated variant). Corrected by rerunning the exact standard command already proven on the rest of the fleet; the agent then installed, ran, and registered `vault1` successfully in GLPI's inventory, with only a harmless informational warning about a missing `usb.ids` file (affects USB device naming detail only, not functionality).

### 9. Final review and close-out (spread across follow-up sessions on 17 Jul, 30 Jul, and 17 Aug)
- Verified the Wazuh agent was in fact reporting correctly to MON01 (confirmed working, had been left unconfirmed after the earlier config fix).
- Verified `/var/www/glpi/install/` had been fully removed (found it still present with content; deleted it — the installer directory left behind is itself a security exposure if not cleared).
- Confirmed the `url_base` database value was correctly set and working.
- Corrected the LDAP "Replicates" entry, which had been pointing at DC1's own IP a second time (providing no real redundancy), to point at DC2 instead, giving GLPI genuine LDAP failover if DC1 goes down.
- Explicitly revisited and confirmed, on request, that "functional GLPI configuration: LDAP profiles, ITIL categories" was indeed fully closed with nothing outstanding.

## Problems solved

- **`pct create` failing with "storage 'local-lvm' does not exist":** the lab's actual Proxmox storage pool for VM/LXC disks is `local-zfs` (ZFS), not LVM-thin; confirmed via `pvesm status` and corrected in the `--rootfs` argument — a fact now known for future LXC/VM builds in this lab.
- **Referenced Debian 12 template version unavailable:** the exact filename changed twice as newer point releases replaced older ones in the repo; resolved each time by checking `pveam list local` for the real, currently-downloaded filename rather than assuming a fixed version string.
- **LXC network connectivity risk from an ambiguous VLAN tagging assumption:** clarified before it caused an outage — `vmbr1` is a trunk, and VLAN membership is set per-VM via a `tag=` attribute, not via a VLAN-aware bridge; added the missing tag to GLPI1's `net0` config accordingly.
- **`sudo: command not found` right after `pct enter`:** the minimal Debian LXC template doesn't ship `sudo`; installed it before attempting to add `sadmin` to the `sudo` group (which would otherwise also fail, since the group itself doesn't exist without the package).
- **MariaDB failing to restart after adding `log_bin_trust_function_creators`:** a typo (`funtion` instead of `function`) in the config line, caught via `journalctl -xeu mariadb` and corrected directly in the config file.
- **GLPI compatibility check flagging a missing PHP module:** `php-bcmath` wasn't in the original install list; installed and restarted Apache to clear the check.
- **Nginx failing to bind to port 80 with "Address already in use" despite Apache being correctly restricted to loopback:** a Linux binding quirk — a wildcard (`0.0.0.0`) bind is rejected if the same port is already bound on `127.0.0.1`. Resolved by binding Nginx to the container's actual IP instead of the wildcard.
- **CA root certificate not installing into the trust store ("0 added, 0 removed"):** the file had a `.cer` extension instead of the `.crt` that `update-ca-certificates` scans for; renamed and re-run, with a DER-vs-PEM format check also flagged as a related possible cause for certificates coming from a Windows CA.
- **LDAP directory test failing before any real connection was attempted:** several basic configuration fields were wrong or empty — `Active` set to No, `Default Server` set to No, an authenticated bind enabled with no RootDN/password filled in, and an LDAPS URL missing the `ldaps://` scheme prefix. All corrected as a set before the first real test attempt.
- **LDAPS bind failing with `Can't contact LDAP server(-1)` despite a working TLS handshake:** methodically isolated to a hostname-verification failure — DC1's certificate doesn't include the DC1 IP as a SAN entry, so PHP/`libldap`'s strict hostname check (unlike `openssl s_client`'s default lenient check) rejected the connection when addressed by IP. Fixed by connecting via the FQDN (`dc1.pymesis.lab`) the certificate was actually issued for, after confirming DNS resolution worked.
- **`/etc/ldap/ldap.conf` missing, blocking the `TLS_CACERT` directive needed for LDAPS trust:** the file is provided by `libldap-common`, a package not installed alongside `php-ldap`; installed it and set the directive.
- **Zabbix host staying red despite a running, correctly-configured agent:** the `Hostname=` config change hadn't been picked up because the agent process had started before the edit and was still serving its old default hostname in memory; fixed with a service restart.
- **Wazuh agent left with an unreplaced `MANAGER_IP` placeholder after a `--reinstall`:** the reinstall didn't re-apply the `WAZUH_MANAGER` environment variable used at first install, so the postinstall script wrote the literal placeholder into `ossec.conf`; corrected manually.
- **SSH key-based authentication to BK1 failing repeatedly despite correct-looking key material and permissions on the client side:** root cause was `authorized_keys` on BK1 being owned by `root` instead of `sadmin` — `sshd` silently falls back to password auth rather than erroring when the file's ownership doesn't match the authenticating user, which made this take an extended, methodical diagnostic pass (comparing keys byte-for-byte, checking directory permission chains) before the actual cause (a `chown`, not a `chmod`, problem) was found.
- **Restic unable to read its own password file (`permission denied`) despite the file existing with seemingly reasonable permissions:** the file had been created with `sudo tee`, leaving it owned by `root:root` and unreadable by `sadmin` even at the `600` mode set — the same root-ownership pattern as the SSH issue above, recurring in a different file.
- **Restic backup partially failing with permission errors on GLPI's OAuth/session files:** those files are owned by `www-data` and unreadable by `sadmin`; resolved by excluding the transient sessions directory from the backup scope and moving the scheduled job to root's crontab, where read access to any file on the system isn't a concern.
- **Authorization rule design initially would have overridden the correct IT/HelpDesk profile assignment:** GLPI evaluates every matching rule (not just the first), so a catch-all "Default → Self-Service" rule with no exclusions matched IT/HelpDesk users too and would have overwritten their `Technician` assignment; fixed by adding explicit OU-exclusion conditions to the fallback rule.
- **Confusion about a "HelpDesk OU" that turned out not to exist:** HelpDesk is a security group in this AD, not a separate organizational unit — both IT and HelpDesk staff sit under the same `OU=IT`, making a dedicated HelpDesk-OU rule harmless but redundant, not broken.
- **IT/HelpDesk users unexpectedly ending up with two profiles instead of one:** not a bug — GLPI accumulates a system-wide default profile (Self-Service, by default) on top of whatever the LDAP rules assign, and this was confirmed as the desired behavior rather than something to correct.
- **A malformed "LDAP Replicate" configuration providing no real redundancy:** it had been set to the same IP as the primary LDAP server (DC1), which is redundant against itself; corrected to point at DC2 for genuine failover.
- **GLPI Agent silently failing to install on a later VM ("vault1") with the installer printing its own help text instead of installing:** caused by an invalid command-line flag (`--no-httpd-trust`, which doesn't exist — the valid option is `--httpd-trust=IP` with no negated form); fixed by rerunning the exact standard install command already proven across the rest of the fleet.

## Final result

GLPI1 (10.0.20.80, Debian 12 LXC, VMID 112) runs GLPI 11.0.8 fully integrated into pymesis.lab:

- **HTTPS** via Nginx reverse-proxying Apache, secured with a SAN certificate from the lab's Enterprise Root CA.
- **LDAPS authentication** against DC1 (`dc1.pymesis.lab:636`), with DC2 configured as a genuine LDAP replicate/failover target, and authorization rules that auto-assign `Technician` to IT/HelpDesk (`OU=IT`) and `Self-Service` to everyone else (HR), validated against real imported users.
- **A 3-level ITIL category structure** mapping to the lab's actual infrastructure, and the native inventory engine enabled.
- **Dynamic inventory via GLPI Agent** deployed lab-wide: manually on the Linux fleet, via a Group Policy startup script on the Windows fleet, and later confirmed working on at least one additional VM (vault1) built after this project closed. FW1 is the one intentional exception, excluded due to OPNsense/FreeBSD having no official GLPI Agent build.
- **Monitoring and backup** consistent with the rest of the lab: Zabbix and Wazuh agents both reporting green to MON01, and a weekly Restic backup (MySQL dump + application files, excluding transient sessions) pushed to BK1, scheduled as root to avoid permission conflicts with GLPI's own file ownership.
- The GLPI installer directory was removed post-setup, and the local `glpi`/`glpi` Super-Admin account's default password was explicitly flagged (though, per Santiago's decision, left unchanged since LDAP is the primary login path).

No outstanding pending items remain for GLPI1 itself.

## Cross references

- The HTTPS/PKI issuance pattern (Enterprise Root CA on DC01, OpenSSL CSR with SAN, `certreq -submit`) originates from **Project 8 (ODOO01)** and was reused here unchanged.
- The root-ownership-breaks-SSH-key-auth pattern uncovered on BK1 is a useful reference for any future VM's Restic/SSH setup — see also **Project 5.1** for the fleet-wide backup architecture this project's cron follows.
- Zabbix and Wazuh agent installation steps mirror the same process documented in **Project 9 (MON01)**.
- The Windows Server/AD/GPO mechanics used for the GLPI Agent rollout build on the Active Directory foundation from **Project 3**.

---

**Previous:** Project 9 — Rocky Linux 9.4 (MON01) | **Next:** Project 11 — Harbor + CI/CD (HR1)
