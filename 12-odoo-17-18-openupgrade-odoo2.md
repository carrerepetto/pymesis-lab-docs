---
title: 12-odoo-17-18-openupgrade-odoo2
description: odoo-17-18-openupgrade
published: 1
date: 2026-09-01T19:28:39.606Z
tags: 
editor: markdown
dateCreated: 2026-08-29T20:05:35.844Z
---

# Project 12 — ERP Migration | odoo2 | LXC | ERP Admin | Ubuntu 24.04, Odoo 17→18, OpenUpgrade |

**Previous:** [Project 11 — Registry + CI/CD (hr1)](11-harbor-cicd-hr1.md)
**Next:** [Project 13 — Medusa eShop (es1)](13-medusa-eshop-es1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Build a safe, repeatable staging environment to practice a real-world Odoo major-version upgrade (17 → 18) using the official OCA OpenUpgrade toolchain, without touching the production Odoo instance (odoo1/db1). The exercise doubles as a documented Standard Operating Procedure (SOP) for future Odoo migrations in the lab or elsewhere.

## Context

This project follows [Project 10 — GLPI Installation](10-glpi-installation.md). At this point in the lab's timeline, odoo1 (production Odoo, VMID/IP not covered here) and db1 (PostgreSQL, 10.0.20.71) were already running. The goal was to introduce a second, isolated Odoo instance dedicated purely to migration practice, reusing the existing PostgreSQL server instead of standing up a redundant database host.

## Decisions Taken and Why

| Decision | Reasoning |
|---|---|
| **No separate DB2 LXC** | Reused db1 (10.0.20.71) for both Odoo instances instead of provisioning a second PostgreSQL host — avoids unnecessary resource duplication in a homelab context |
| **New database (`odoo17`) instead of a clone of `odoo_prod`** | Keeps the migration exercise fully isolated from production data from the start |
| **Two parallel Python venvs on the same LXC (venv17, venv18)** | Lets Odoo 17 CE and the post-migration Odoo 18 coexist without destroying the pre-migration environment, so rollback/comparison stays possible |
| **Python 3.11 (via deadsnakes) for venv17** | Odoo 17 was not fully validated against Python 3.12 (Ubuntu 24.04's default) — older `gevent`/`greenlet` versions have known compilation issues |
| **Python 3.12 for venv18** | OpenUpgrade's 18.0 branch is compatible with 3.12, so no need for deadsnakes on that venv |
| **Different XML-RPC ports per version (8069 for Odoo 17, 8070 for Odoo 18)** | Allows both services to be defined without port conflicts, even though they aren't meant to run simultaneously in normal operation |
| **In-place migration (OpenUpgrade transforms the same `odoo17` database)** | Matches how OpenUpgrade is actually designed to work — it upgrades the schema in place rather than producing a separate output database |
| **Explicit pre-migration snapshot (`odoo17_premigration`)** | Preserves an intact "before" state for comparison and rollback, independent of the in-place transformation |
| **`ALTER ROLE odoo17 CREATEDB`** | Required for the app role to clone its own database for the snapshot step; explicitly flagged as looser than a production-appropriate setup, where the clone/snapshot step should be run by an admin role, not the application role |
| **Restic backup + Zabbix/Wazuh agents added to odoo2** | Keeps the new host aligned with the lab-wide backup and monitoring conventions established in earlier projects |

## Step-by-Step

### 1. Environment specification
- LXC, Ubuntu 24.04, 2 vCPU, 4 GB RAM, 40 GB disk, VMID 114, IP 10.0.20.72/24
- Database: new `odoo17` database on db1 (10.0.20.71), owned by a new `odoo17` role
- Admin user: `sadmin`, timezone `Europe/Rome` — consistent with lab-wide conventions

### 2. LXC provisioning
Created via `pct create` with `unprivileged 1`, `nesting=1`, `onboot 1`, bridged to `vmbr1` on VLAN20. Basic hardening: timezone set, `sadmin` user created with sudo.

### 3. Database preparation on db1
Created the `odoo17` role and `odoo17` database via `psql`. Added a `pg_hba.conf` entry restricting the new role to its own database and IP, then reloaded PostgreSQL.

### 4. Odoo 17 CE installation (venv17)
- Installed Python 3.11 via the deadsnakes PPA plus system build dependencies (`libxml2-dev`, `libxslt1-dev`, `libldap2-dev`, etc.)
- Installed the specific patched-Qt `wkhtmltopdf` release required by Odoo
- Created a dedicated `odoo` system user and directory layout (`/opt/odoo/{venv17,venv18,logs,custom-addons}`)
- Cloned `odoo/odoo` branch `17.0`, created `venv17`, installed `requirements.txt`
- Wrote `/etc/odoo17.conf` pointing at db1 and the `odoo17` database, port 8069
- Created and enabled the `odoo17.service` systemd unit

### 5. Populating test data
Initialized the `odoo17` database via CLI with real modules (`base, sale_management, purchase, stock, account`) instead of a wizard, to get relational data (orders, stock moves, journal entries) that would meaningfully exercise OpenUpgrade's migration scripts. Loaded a handful of manual test records (customers, products, a confirmed sales order, an invoice).

### 6. Pre-migration snapshot
Stopped the Odoo 17 service, cloned `odoo17` to `odoo17_premigration` via `createdb -T`, restarted the service. This produced an untouched "before" copy for later comparison and potential rollback.

### 7. OpenUpgrade installation (venv18)
- Cloned `OCA/OpenUpgrade` branch `18.0` — discovered mid-project that this repo is **no longer a full Odoo fork** with its own `odoo-bin`, but a pure addon package (`openupgrade_framework` + `openupgrade_scripts`) meant to sit on top of a real Odoo 18 core
- Cloned `odoo/odoo` branch `18.0` separately as the actual core
- Created `venv18` with Python 3.12, installed both the core's and OpenUpgrade's `requirements.txt`
- Wrote `/etc/odoo18.conf` pointing at the same `odoo17` database (in-place migration), port 8070, with `addons_path` covering the core plus the OpenUpgrade module's **parent** directory (not the module subfolders directly — Odoo expects `addons_path` entries to contain module folders as immediate subdirectories)
- Added `server_wide_modules = base,openupgrade_framework` per OCA's documented recommendation

### 8. Running the migration
Stopped `odoo17.service`, then ran `odoo-bin` from the Odoo 18 core with:
```
--upgrade-path=/opt/odoo/openupgrade18/openupgrade_scripts/scripts -u all --stop-after-init
```
The correct `--upgrade-path` target turned out to be the `scripts/` subdirectory inside `openupgrade_scripts` (organized by module name), not the module root.

### 9. Validating the migration
- Created and enabled `odoo18.service` (without `-u all`/`--stop-after-init`, which are one-off migration flags, not part of normal service startup)
- Logged into `http://10.0.20.72:8070`, confirmed login, data visibility, and version `18.0` under Settings → Technical Information
- Ran a row-count comparison of key transactional tables (`res_partner`, `sale_order`, `stock_move`, `account_move`) between `odoo17_premigration` and the migrated `odoo17`

### 10. Backup and monitoring integration
- Installed `postgresql-client` and `restic` on odoo2 (not present by default on an app-only LXC)
- Set up a dump script + Restic push job to bk1 (10.0.20.50), scheduled via cron with `RESTIC_PASSWORD_FILE` for non-interactive authentication
- Generated a passphrase-less SSH keypair and copied it to bk1 for unattended cron execution
- Installed and configured the Zabbix agent (pointing to mon1, 10.0.20.60) and the Wazuh agent, following the same pattern used for previous hosts
- Installed the GLPI Agent (1.18) pointed at `glpi1.pymesis.lab`, after copying the internal CA certificate, so odoo2 appears in GLPI's dynamic inventory
- Mid-project, backup repository paths were reorganized lab-wide from `/mnt/backups/<vm>` to `/mnt/backups/repos/<vm>` on bk1; the odoo2 cron and Restic repo were realigned to the new path and validated with a manual `backup` + `snapshots` run

## Problems Resolved

| Problem | Root Cause | Fix |
|---|---|---|
| `no pg_hba.conf entry for host ... database "template1"/"postgres"` (multiple occurrences) | Each PostgreSQL client operation (initial connection check, `CREATE DATABASE ... TEMPLATE`) touches a different maintenance database (`postgres`, `template1`), each requiring its own `pg_hba.conf` entry | Added targeted entries per maintenance database and origin IP; noted for later that a single broader `host all <role> <ip> scram-sha-256` line is functionally equivalent in this lab's threat model, since real isolation comes from PostgreSQL `GRANT`s, not the `pg_hba.conf` database column |
| `createdb: command not found` on odoo2 | The app LXC only ships the Python driver (`psycopg2`), not PostgreSQL client tools | Installed `postgresql-client` |
| `permission denied to create database` | The `odoo17` role owned its database but lacked the `CREATEDB` role attribute needed to clone it | `ALTER ROLE odoo17 CREATEDB` on db1 (flagged as broader than ideal for production) |
| `python3.12-venv`/`python3.12-dev` missing | Ubuntu splits the venv module and dev headers from the base interpreter package | Installed both packages explicitly before creating venv18 and compiling `psycopg2`/`python-ldap` |
| `odoo-bin: No such file` in the OpenUpgrade clone | OCA's OpenUpgrade repository structure changed — it's now an addon package, not a standalone Odoo fork | Cloned the real `odoo/odoo` 18.0 core separately and pointed `odoo-bin` there, using OpenUpgrade only via `addons_path`/`--upgrade-path` |
| Silent-looking failure — `pip install` appeared to hang/stop with no visible error | The `requirements.txt` install had actually been interrupted partway (confirmed by a missing `babel` module) | Re-ran the install to completion and verified the exit code and key packages individually |
| Migration command exited instantly with no output | `addons_path` pointed directly at the OpenUpgrade module folders instead of their parent directory — Odoo couldn't resolve `odoo.addons.openupgrade_framework` | Corrected `addons_path` to include the parent directory containing both module folders |
| `ERROR: update or delete on table "res_partner" violates foreign key constraint` during migration | OpenUpgrade's demo-data cleanup tried to delete generic/duplicate contact records that were referenced by the test sales/purchase/invoice data created earlier | Non-fatal — PostgreSQL correctly protected in-use partners; migration completed and all transactional row counts matched exactly (`res_partner` dropped from 42 to 19, consistent with legitimate de-duplication of unused demo contacts) |
| `restic: command not found` | Restic client not installed by default on odoo2 | Installed via `apt` |
| Restic repository initialized with a different password than the one later saved to `/etc/restic_password` | The first `init` was run interactively before the password file existed | Deleted the empty repo on bk1 and re-initialized using the password file, so cron runs non-interactively |
| Cron jobs would have prompted for an SSH password | No existing SSH trust between odoo2 and bk1 | Generated a passphrase-less ed25519 keypair for `sadmin` and copied it to bk1 with `ssh-copy-id`; verified with a password-less test connection |
| Backup repository path mismatch after a lab-wide path reorganization | The Restic repo was initialized at `/mnt/backups/odoo2`, but the crontab was later updated to reference `/mnt/backups/repos/odoo2` without moving the underlying data | Confirmed the actual repo location on bk1 matched the new convention (already migrated alongside glpi1 and hr1), then validated with a manual `backup` + `snapshots` run against the correct path |
| Odoo 17 systemd service failed to start on odoo2 | `systemctl enable --now odoo17` was run before the corresponding `pg_hba.conf` entry had been reloaded on db1 | Reload PostgreSQL (`systemctl reload postgresql`) *after* any `pg_hba.conf` change, before starting/restarting the dependent Odoo service |

## Final Result

Odoo 17 → 18 migration completed and validated end-to-end on isolated staging infrastructure, with zero data loss in transactional tables (`sale_order`, `stock_move`, `account_move` counts identical pre/post-migration). Both Odoo 17 (disabled, kept for rollback/comparison) and Odoo 18 (active) services are installed on odoo2, alongside Restic backups, Zabbix/Wazuh monitoring, and GLPI inventory — bringing odoo2 to full parity with the rest of the lab's operational conventions.

**Resulting SOP** (documented for reuse):
1. Backup/clone the pre-migration database
2. Install the target Odoo version in a separate venv
3. Run `--upgrade-path` + `-u all --stop-after-init`
4. Validate logs for `ERROR`/`CRITICAL` (ignoring expected transient OpenUpgrade warnings)
5. Bring up the new service and compare data integrity via transactional row counts
6. Keep the old version's service installed but disabled, as a rollback path

## Cross References

- Builds on: [Project 8 — Ubuntu 24.04 Installation (odoo1, db1)](08-ubuntu-24-04-installation.md) for the shared PostgreSQL host
- Builds on: [Project 10 — GLPI Installation](10-glpi-installation.md) for the dynamic inventory pattern applied here
- Backup pattern consistent with: [Project 5.1 — Restic Configuration](05-1-restic-configuration.md)
- Related fleet-wide reorganization: backup repository paths standardized to `/mnt/backups/repos/<vm>` (also applied to glpi1 and hr1)

---

[← **Previous:** Project 11 — Registry + CI/CD (hr1)](11-harbor-cicd-hr1.md) | [**Next:** Project 13 — Medusa eShop (es1) →](13-medusa-eshop-es1.md)