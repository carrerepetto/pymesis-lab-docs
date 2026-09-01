---
title: 08-ubuntu-odoo1-db1
description: ubuntu-24.04
published: 1
date: 2026-09-01T17:24:40.280Z
tags: 
editor: markdown
dateCreated: 2026-08-28T10:28:38.865Z
---

# Project 8 — Ubuntu 24.04 (odoo1 / db1)

**Previous:** [Project 7 — App Server (app1)](07-windows-server-app1.md)
**Next:** [Project 9 — Monitoring/SecOps (mon1)](09-rocky-mon01.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Deploy the pymesis.lab ERP stack as defined in the blueprint: two Ubuntu Server 24.04 VMs — **ODOO-DB01** (PostgreSQL 16 backend) and **ODOO01** (Odoo 19 Community application server behind an Nginx reverse proxy) — then secure ODOO01 with HTTPS issued by the lab's own internal CA, and extend it with a curated set of OCA community modules.

## Context

This is the first "Nodo 2" workload in the blueprint (physically still running on the Nodo 1 hardware until the second GMKtec arrives). It follows the VM-build pattern already used for the Windows fleet and for LX1, and it establishes the lab's PKI pattern (OpenSSL CSR + SAN + `certreq -submit` on DC01) that was later reused as-is for APP01 (Project 7). The two VMs were built together since ODOO01 depends on ODOO-DB01 for its database.

## Decisions made and why

- **VM specs per blueprint:** ODOO-DB01 — VM ID 106, 60 GB OS disk + 200 GB data disk, IP 10.0.20.71; ODOO01 — VM ID 107, 80 GB OS disk + 150 GB data disk, IP 10.0.20.70. Both q35, VirtIO SCSI Single, 4 cores (host type), 8 GB RAM — consistent with the rest of the lab's VM template.
- **PostgreSQL 16 from the official postgresql.org repository, not Ubuntu's default (PG14):** needed for Odoo 19 compatibility and to standardize on the latest stable major version.
- **Odoo 19 Community instead of 17/18 as originally planned:** the initial assumption (Odoo 19 didn't exist yet) was wrong and corrected via a web search — Odoo 19 had in fact been released and was the recommended version for new deployments as of mid-2026, so the plan was updated to install it directly.
- **Nginx as a reverse proxy in front of Odoo, rather than exposing port 8069 directly:** standard practice reasons were discussed and agreed — hides the backend port, allows the standard port 80/443, offloads static file serving from Odoo, and centralizes future TLS termination. Documented explicitly as "Nginx is the building's doorman, Odoo is the office inside."
- **Standardized timezone as `America/Bogota` across the whole homelab, not `Europe/Rome`:** despite Santiago being physically in Rome, the rest of the lab's infrastructure was already set to Bogotá time, so consistency across the fleet was prioritized over matching physical location — corrected from an initial typo-driven suggestion of `Europe/Rome`.
- **HTTPS deferred initially, then implemented as a shared lab-wide PKI project:** the first pass concluded HTTP was acceptable for an internal-only homelab and that setting up Active Directory Certificate Services (ADCS) as an Enterprise Root CA was worth doing once, for the whole lab, rather than per-VM. When the time came, ODOO01 became the first VM to get HTTPS via this new CA, establishing the pattern (OpenSSL CSR with SAN, signed via `certreq -submit` rather than the `certsrv` web portal, which doesn't honor SAN) that Project 7 (APP01) later reused unchanged.
- **Country/locality fields in the CSR corrected to Italy (Lazio/Roma)** instead of the lab's default Colombia/Bogotá — these are cosmetic Subject fields, but Santiago's actual location was used for accuracy since it doesn't affect the certificate's function (only the CN and SAN matter for validation).
- **SAN limited to the certificate's real, resolvable hostname (`odoo1.pymesis.lab`) only** — an initial attempt included both `odoo1` and a non-existent `odoo01` variant "just in case"; this was dropped once it was pointed out that a name absent from DNS provides no value in a SAN.
- **OCA module selection was validated against actual Odoo 19.0 branch availability before installing anything**, rather than assuming all requested modules were ready. Several originally requested modules (`web_m2x_options`, `web_widget_many2many_tags_multi_selection`, `base_tier_validation`, `account_invoice_report_grouped_by_picking`, `mail_tracking` in its OCA form) turned out to have no stable 19.0 branch and were deliberately dropped rather than installed from an incompatible branch.
- **Native Odoo 19 Community modules used instead of OCA equivalents where Odoo 19 already ships the functionality:** `l10n_ar`/`l10n_it` localizations and `stock_barcode` were left as Odoo's built-in versions rather than installed from OCA, avoiding duplicate/conflicting modules.
- **`board` (Odoo's native dashboard module) installed to partially compensate for Community's lack of an Enterprise-style dashboard**, instead of purchasing Enterprise or building a custom one — judged the right trade-off for a homelab.
- **Boot-time service cleanup (`cloud-init`, `systemd-networkd-wait-online`) was investigated for the whole Ubuntu fleet but only applied where actually needed:** the slow-boot symptom turned out to be present on LX1, not ODOO01/DB01, so no changes were made to services that weren't causing the problem, avoiding unnecessary hardening work.

## Step by step

### 1. Create both VMs in Proxmox
- **ODOO-DB01:** VM ID 106, 60 GB system disk + 200 GB data disk, static IP 10.0.20.71.
- **ODOO01:** VM ID 107, 80 GB system disk + 150 GB data disk, static IP 10.0.20.70.
- Both: q35 machine type, VirtIO SCSI Single controller, 4 cores (type `host`), 8 GB RAM, VLAN20.

### 2. Install Ubuntu Server 24.04 (both VMs)
- Manual network configuration on VLAN20, with DNS pointing to DC01/DC02.
- OpenSSH enabled during install.
- User created as `sadmin` (not the originally planned `admin`), with hostnames `db1` and `odoo1` — these became the standardized conventions for the rest of the Linux fleet going forward, confirmed and locked in during this project.

### 3. Post-install basics
- Installed `qemu-guest-agent` on both VMs.
- Mounted the dedicated data disks: `/var/lib/postgresql` on ODOO-DB01, `/opt/odoo` on ODOO01.
- Fixed a permissions issue: `sadmin` wasn't initially in the `sudo` group, which blocked all `sudo` commands over SSH. Resolved via the Proxmox noVNC console: logged in as `root` directly and ran `usermod -aG sudo sadmin`.

### 4. DNS and connectivity
- Created A/PTR records on DC01 for `db1` (10.0.20.71) and `odoo1` (10.0.20.70).
- Verified name resolution and SSH connectivity between the two VMs and from DC01.

### 5. Install and configure PostgreSQL 16 on ODOO-DB01
- Installed from the **official postgresql.org repository** (not Ubuntu's bundled PG14).
- Tuned `postgresql.conf` for an 8 GB RAM VM: `shared_buffers = 2GB`, `effective_cache_size = 6GB`, `listen_addresses = '*'`, and the lab-standard timezone `America/Bogota` (see decision above).
- Created role `odoo` (`CREATEDB`, `LOGIN`, not superuser) and database `odoo_prod` (owner `odoo`, `UTF8` encoding), and set a password for the `postgres` superuser.
- Configured `pg_hba.conf` to allow connections from ODOO01 (10.0.20.70) using `scram-sha-256`, initially scoped to `odoo_prod` only and later widened to `all` databases (needed because Odoo also queries the `postgres` maintenance database at startup).
- Verified remote connectivity from ODOO01 with `psql -h 10.0.20.71 -U odoo -d odoo_prod -W`, confirming SSL/TLS was active on the connection.
- Left `ufw` inactive on ODOO-DB01 by decision — access control is handled by `pg_hba.conf`, which is more specific than a host firewall; `ufw` was deferred to the point where the network gets segmented with the MikroTik switch.

### 6. Install Odoo 19 Community on ODOO01
- Corrected the version target from "17/18" to **Odoo 19 Community** after confirming via web search that it existed and was the current recommended release.
- Set up the runtime structure under `/opt/odoo` (`odoo-server`, `custom-addons`, `data`, `venv`), owned by an `odoo` system user.
- Cloned Odoo 19 from GitHub (`--depth 1 --branch 19.0`) into `/opt/odoo/odoo-server`.
- Created a Python virtualenv (`/opt/odoo/venv`) and installed `requirements.txt` plus `passlib` (a missing dependency needed for the database initialization step).
- Configured `/etc/odoo/odoo.conf` with `db_host`, `db_port`, `db_user`, `db_password` pointing at ODOO-DB01, `addons_path`, and `http_interface` (the Odoo 19 parameter name — the older `xmlrpc_interface` no longer applies and caused a conflict when both were present).
- Initialized the `odoo_prod` database's schema with `odoo-bin -c /etc/odoo/odoo.conf -d odoo_prod --init base --stop-after-init`, run explicitly through the virtualenv's Python interpreter.
- Set up `systemd` service management for Odoo (port 8069 for HTTP, 8072 for longpolling) and confirmed a clean startup log (`Worker WorkerHTTP alive`).

### 7. Configure Nginx as a reverse proxy on ODOO01
- Wrote a virtualhost with `upstream odoo` (127.0.0.1:8069) and `upstream odoo-longpolling` (127.0.0.1:8072), proxy headers, and a large `client_max_body_size` for Odoo's typical attachment sizes.
- Fixed two typos found during review before deploying: `cliente_max_body_size` → `client_max_body_size`, and `X-Content-Type-Optiones` → `X-Content-Type-Options`.
- Set `http_interface = 127.0.0.1` in `odoo.conf` (Odoo now only listens locally; Nginx is the only public-facing entry point) and validated the configuration with `nginx -t` before reload.
- Verified end-to-end access on port 80 without specifying `:8069`, confirming the reverse-proxy chain: browser → Nginx (0.0.0.0:80) → Odoo (127.0.0.1:8069).
- Documented for reference why a reverse proxy is used here: it hides the backend port, exposes the standard HTTP/HTTPS ports, offloads static content, centralizes future TLS, and provides a single entry point for multiple future services.

### 8. Deploy internal PKI (ADCS on DC01) and HTTPS on ODOO01 — the pattern later reused for APP01
- **Phase A — ADCS on DC01:** installed the Certification Authority and Web Enrollment role services, configured as an **Enterprise Root CA** (`pymesis-DC01-CA`), confirmed automatic trust distribution to domain-joined Windows clients via GPO. Fixed a `404` on `/certsrv` caused by the Web Enrollment role service not being installed, by installing it explicitly (`Install-WindowsFeature ADCS-Web-Enrollment` + `Install-AdcsWebEnrollment -Force`).
- **Phase B — Certificate for ODOO01 (first attempt, no SAN):**
  - Generated a private key and CSR on ODOO01 with OpenSSL, subject fields corrected to reflect Italy (`C=IT, ST=Lazio, L=Roma`) instead of the lab-default Colombia.
  - Transferred the CSR to DC01 via `scp` (chosen over manual copy-paste, since transcribing cryptographic material from a screenshot risks corrupting it) and issued it from `certsrv` with the Base64-encoded format needed by Nginx.
  - Copied the `.crt` and the CA root (`pymesis-ca.crt`) back to ODOO01, installed the CA root into the system trust store (`/usr/local/share/ca-certificates/` + `update-ca-certificates`) — initially failed silently (`0 added, 0 removed`) because the file was placed in the wrong directory (`/etc/nginx/ssl/`) first.
  - Verified the key/certificate pair matched via MD5 hash comparison of their moduli.
  - Configured the Nginx virtualhost for HTTPS on port 443 with an HTTP→HTTPS 301 redirect, TLS 1.2/1.3, and security headers (HSTS, X-Frame-Options, X-Content-Type-Options).
- **Fixing the "Not secure" browser warning — regenerating the certificate with SAN:**
  - Diagnosed that the certificate had no Subject Alternative Name extension (`openssl x509 ... | grep "Subject Alternative"` returned nothing), which modern browsers require regardless of a valid CN and trust chain.
  - Generated a new CSR with an explicit SAN config file (`san.cnf`), limited to the certificate's actual, resolvable name — `odoo1.pymesis.lab` and IP `10.0.20.70` — after an initial attempt that also included a non-existent `odoo01.pymesis.lab` was corrected.
  - Enabled the CA to honor SAN attributes on incoming requests (`certutil -setreg policy\EditFlags +EDITF_ATTRIBSUBJECTALTNAME2` + restarting `certsvc` on DC01) and issued the certificate via `certreq -submit -attrib "CertificateTemplate:WebServer"` — the `certsrv` web portal path does not respect SAN and was avoided.
  - Verified the SAN was present (`certutil -dump ... | findstr "DNS"` → `DNS Name=odoo1.pymesis.lab`) before shipping the certificate back to ODOO01, replacing the old one, and reloading Nginx.
  - Confirmed final result: `https://odoo1.pymesis.lab` loads with a valid padlock and no browser warnings from a domain-joined client.
- **Cross-VM trust confirmed:** the CA root distributes automatically via GPO to Windows domain members (verified `gpupdate /force` propagation to DC01, DC02, FS1, APP01); Linux members (ODOO01, DB01) needed the manual `update-ca-certificates` step instead.

### 9. Add usability improvements inside Odoo
- Installed the built-in `board` module (Community's closest equivalent to Enterprise's dashboard) via terminal (`odoo-bin --init board --stop-after-init`), after confirming there is no separate "Enterprise dashboard" that can simply be toggled on — the two editions differ in available modules, not a switchable UI mode.
- Set the user's default landing app (Preferences → Home Action) to Dashboards instead of Discuss, Odoo Community's default startup screen.

### 10. Install a curated set of OCA (Odoo Community Association) modules
- Cross-checked every requested module against actual Odoo 19.0 branch availability on GitHub before installing anything, since OCA repositories migrate to new Odoo versions gradually and unevenly.
- **Confirmed for 19.0 and installed:** `report_xlsx` (reporting-engine), `web_environment_ribbon`, `web_responsive`, `web_dialog_size`, `web_search_with_and` (web), `auditlog`, `password_security`, `base_cron_exclusion` (server-tools), `account_financial_report` (account-financial-reporting), `account_reconcile_oca` (account-reconcile), `account_statement_import_camt` and `account_statement_import_csv` (bank-statement-import), `queue_job` (queue), `mis_builder` (mis-builder), `partner_firstname` (partner-contact), `mail_tracking` (social), and `zxs_entp_theme` (installed manually from the Odoo Market ZIP, not GitHub).
- **Fixed a missing dependency:** `account_financial_report` required `date_range`, which turned out to live in `OCA/server-ux` (not `server-tools`, where it was initially — incorrectly — assumed to be); cloned that repo and added it to `addons_path`.
- **Discarded — no stable 19.0 branch found:** `web_m2x_options`, `web_widget_many2many_tags_multi_selection`, `base_tier_validation`, `account_invoice_report_grouped_by_picking`, and the OCA form of `mail_tracking`'s more advanced dependents. `disable_odoo_online` was dropped as obsolete since Odoo v11.
- **Localization and barcode functionality left native:** `l10n_ar`/`l10n_it` and `stock_barcode` ship with Odoo 19 Community, so the OCA equivalents were not installed to avoid duplication/conflicts.

## Problems solved

- **`sadmin` had no sudo rights, blocking all remote administration:** fixed via the Proxmox console by logging in as `root` and running `usermod -aG sudo sadmin`.
- **PostgreSQL reported `active (exited)` and appeared broken, but the real problem was a `postgresql.conf` typo:** `TimeZone = "Euorpe/Rome"` (misspelled) caused PostgreSQL to fail to start with `FATAL: invalid value for parameter "TimeZone"`. Fixed by correcting the timezone to the lab standard, `America/Bogota`.
- **Multi-line `psql -c` commands silently failed to execute:** pasting a multi-line command produced an open-quote prompt (`postgres'#`) that never actually ran, giving the false impression nothing had happened. Resolved by running each statement as a single line.
- **`pg_hba.conf` rule for ODOO01 appeared correct but connections were still refused:** root cause traced step by step — first a `reload` was insufficient and a full `restart` was needed; then `listen_addresses = '*'` wasn't actually in effect because the PostgreSQL process itself wasn't running (masked by the misleading `active (exited)` systemd state); the underlying cause was a malformed CIDR further down in the same file (`10.0.20./24` missing the trailing `0`), which caused `FATAL: could not load pg_hba.conf` and silently prevented the whole file — including the correct ODOO01 rule — from loading.
- **General misunderstanding of `active (exited)` on PostgreSQL/Ubuntu:** clarified with a durable diagnostic table — `systemctl status` alone is not conclusive; the reliable checks are `ss -tlnp | grep 5432` (is anything actually listening) and `pg_lsclusters` (does it report `online`). This became a documented reference for future PostgreSQL troubleshooting in the lab.
- **Odoo failed to connect to PostgreSQL with `no pg_hba.conf entry for host ..., database "postgres"`:** Odoo also connects to the `postgres` maintenance database at startup, not only `odoo_prod`; the `pg_hba.conf` rule was widened from `odoo_prod` only to `all` databases for the `odoo` role.
- **Odoo then failed with `fe_sendauth: no password supplied`:** `db_password` was missing from `odoo.conf`; added and confirmed against the `odoo` PostgreSQL role's password.
- **Odoo appeared to work, then completely disappeared after the Nginx/systemd changes (`status=203/EXEC`, later `odoo-bin: No such file or directory`):** investigation revealed that Odoo had never actually been fully installed from git in the prior session — `/opt/odoo` was empty and owned by `root`. The service had apparently been running from some other, since-lost state. Resolved by rebuilding cleanly: fixing ownership, re-cloning the `19.0` branch, recreating the virtualenv, reinstalling `requirements.txt` (plus the missing `babel` and `passlib` packages), and reinitializing the database.
- **`custom-addons` directory warning ("invalid addons directory"):** traced to the actual directory existing but appearing empty of modules — not a real error, just Odoo warning about an unused, empty addons path; later cleaned up by removing the unused entry from `addons_path`.
- **Odoo unreachable on the network despite running:** `http_interface` (Odoo 19's correct parameter name) and the deprecated `xmlrpc_interface` were both present and conflicting in `odoo.conf`; removed the deprecated one and set `http_interface = 0.0.0.0` (later `127.0.0.1` once Nginx took over as the public entry point).
- **`ir_module_module does not exist` on first web access:** the database had never been initialized with the `base` module; run manually via `odoo-bin --init base --stop-after-init` (needed to stop the running service first, since both processes competed for port 8069, and needed the virtualenv's Python binary called explicitly rather than the system one).
- **Nginx `502 Bad Gateway`:** Odoo's systemd unit referenced a virtualenv Python path (`/opt/odoo/venv/bin/python`) that didn't exist yet, consistent with the incomplete original installation described above; resolved once the venv was properly (re)created.
- **HTTPS certificate showed `NET::ERR_CERT_COMMON_NAME_INVALID` / "Not secure" despite a correct, trusted CN:** root cause was the certificate lacking a SAN extension, which modern browsers require independently of the legacy CN field. Regenerated the CSR with an explicit `subjectAltName`, and additionally had to enable the CA to honor SAN attributes on submitted requests (disabled by default on Windows CAs) before reissuing.
- **CA root certificate not trusted on ODOO01 despite copying it (`0 added, 0 removed`):** the file had been placed in `/etc/nginx/ssl/` instead of the OS trust-store staging directory `/usr/local/share/ca-certificates/`; corrected and re-ran `update-ca-certificates`.
- **OCA module install failures for several requested modules:** rather than force-install from an incompatible branch, each module was checked against its actual OCA GitHub branch list; several were confirmed to simply not have a 19.0 port yet and were deliberately excluded, with native Odoo 19 equivalents used where available.
- **Missing `date_range` dependency for `account_financial_report`:** initially assumed to be part of `server-tools` (already cloned) but not found there; correctly traced to the `OCA/server-ux` repository, cloned, and added to `addons_path`.
- **Slow VM boot (perceived as an Odoo/ODOO01 issue, later corrected to be an LX1 issue):** the long boot delay and `cloud-init ... DataSourceNone` message were investigated and fixed on **LX1**, not ODOO01/DB01 as first assumed — the fix (`systemd-networkd-wait-online` disabled/masked, `cloud-init` disabled) was checked against ODOO01, DB01, BK1, and MON1 but none of them exhibited the symptom, so no changes were made there.
- **Confusion between IIS's "URL Rewrite Module" (used on APP01) and its native "HTTP Redirect" feature:** clarified that they are functionally equivalent (both produce a 301 HTTP→HTTPS redirect) but technically distinct; documented that using URL Rewrite alone is sufficient and installing the native HTTP Redirect feature afterward would be redundant — this was purely an APP01/Project 7 clarification triggered while reviewing ODOO01's already-complete Nginx-based redirect.

## Final result

ODOO-DB01 (db1, 10.0.20.71) is running PostgreSQL 16 from the official repository, tuned for 8 GB RAM, hosting the `odoo_prod` database under a dedicated, non-superuser `odoo` role, reachable only from ODOO01 over `scram-sha-256` authentication with SSL/TLS.

ODOO01 (odoo1, 10.0.20.70) is running Odoo 19 Community behind an Nginx reverse proxy, publicly reachable on port 80 (redirecting to) 443, secured with a SAN-correct HTTPS certificate issued by the lab's own Enterprise Root CA (`pymesis-DC01-CA`) — the first VM in the lab to get this treatment, establishing the certificate-issuance pattern later reused verbatim for APP01. The Odoo instance runs the `board` dashboard module plus a curated, version-verified set of OCA community modules (financial reporting, audit logging, password security, bank statement import, queue jobs, multi-currency reporting via mis_builder, contact name-splitting, email tracking, and a purchased theme), alongside CRM, Sales, and Invoicing modules added afterward. Both VMs have Restic backups pushing to bk1 and Zabbix/Wazuh monitoring agents installed and active, consistent with the rest of the fleet.

The only remaining pending item — not urgent — is installing the lab's CA root certificate (`pymesis-ca.crt`) on LX1, MON1, and BK1, deferred until any of those VMs actually needs to trust an internally-issued HTTPS certificate.

## Cross references

- The HTTPS/PKI flow established here (Enterprise Root CA on DC01, OpenSSL CSR with SAN, issuance via `certreq -submit` rather than the `certsrv` portal) was reused without modification for **Project 7 (APP01)**.
- The `sadmin` username and `dbX`/`odooX`-style short hostname conventions confirmed during this project became the standard applied across the rest of the Linux fleet — see the DNS host-record work in Project 7's context section.
- Backup scheduling (Restic push to bk1) and monitoring agents (Zabbix/Wazuh) follow the fleet-wide standard described in Project 5.1.
- The boot-time `cloud-init`/`systemd-networkd-wait-online` cleanup investigated here was actually applied to LX1 — see Project 4 (Ubuntu 22.04 / lx1) for that fix's details.

---

[← **Previous:** Project 7 — App Server (app1)](07-windows-server-app1.md) | [**Next:** Project 9 — Monitoring/SecOps (mon1) →](09-rocky-mon01.md)