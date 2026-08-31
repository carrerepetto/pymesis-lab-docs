---
title: 21-ibm-db2-lx1
description: ibm-db2
published: 1
date: 2026-08-31T11:39:52.494Z
tags: 
editor: markdown
dateCreated: 2026-08-31T11:39:52.494Z
---

# Project 21 — IBM Db2 (lx1)

**Previous:** [Project 20 — Oracle XE Sandbox (ora1)](20-oracle-xe-sandbox-ora1.md)
**Next:** [Project 22 — Red Hat tools (rhel1)]()

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Stand up IBM Db2 Community Edition as a Docker container on `lx1` (no dedicated VM/LXC), load real sample data, connect it with a small client application to practice the driver/connector layer, and practice native Db2 backup/restore — the same category of exercise as the RMAN work on `ora1`, but for a second database engine, integrated into the fleet's existing Restic backup pattern.

## Context

This project follows the same "sandbox, no dedicated infrastructure" pattern established for the Oracle XE project, but scoped even lighter: since Db2 Community Edition runs well in Docker and `lx1` already runs Docker CE + Compose (Harbor and other containers), there was no need to provision a new VM or LXC at all. The project also served as the first real test of extending `lx1`'s existing Ansible-managed backup pipeline to cover a new, non-trivial multi-step backup (versus the simpler single-command dumps already handled for other Dockerized services on that host).

## Decisions Made and Rationale

- **Docker container on `lx1`, not a dedicated VM/LXC** — Db2 Community Edition runs fine containerized, and `lx1` already has Docker CE + Compose in place; provisioning new infrastructure would be unnecessary overhead for a sandbox exercise.
- **Registry updated to `icr.io/db2_community/db2`, not the legacy `ibmcom/db2`** — flagged proactively before any commands were run, since IBM migrated the image off Docker Hub to its own registry.
- **`DBNAME=SAMPLE` in the `.env`**, so Db2 creates its bundled sample database automatically on first container startup — chosen so the "sample table for the client app" part of the scope would have real data to query without hand-building a schema, mirroring the reuse of Oracle's HR schema in the previous project.
- **Python for the client application** (via `ibm_db`), rather than Node or another language — chosen specifically because the same script/language could be reused later for the backup automation, minimizing what needs to be maintained.
- **Client app runs on `lx1` outside the container**, connecting over the container's exposed `50000:50000` TCP port, rather than living inside the same container as the database — deliberately chosen to simulate a more realistic scenario (an external application connecting to a containerized database) rather than a same-container shortcut.
- **Consolidated on Db2's own auto-created `/database/backup` directory** (singular) instead of a separately hand-created `/database/backups` (plural) — once it was noticed that the container's entrypoint had already created its own backup folder with correct ownership, the manually-created duplicate was removed rather than keeping both.
- **No separate Restic repository or cron job for Db2** — Santiago pushed back directly on the idea of segregating backups by the software/project running on a host; Db2's backup was folded into `lx1`'s single existing Restic repo and single daily backup script, consistent with how Portainer, WikiJS, Gitea, and Uptime Kuma are already backed up together under one host-level backup, since a real disaster recovery scenario restores the whole host's context together, not one service in isolation.
- **A dedicated pre-backup script (`backup_db2.sh`), not an inline one-liner** — chosen because Db2's backup needs several distinct steps (native backup inside the container, extracting the file out via `docker cp`, purging old backups inside the container volume), following the same shape already used for `mon1` (`mysqldump`) and `db1` (`pg_dump`) via the role's `restic_pre_backup_cmd`/`restic_pre_backup_desc` hooks.
- **The new script versioned in the Ansible repo from day one** (`roles/baseline/files/backup_db2.sh`), rather than left as a standalone file on `lx1` — explicitly chosen to avoid repeating a piece of technical debt discovered along the way: existing pre-backup scripts like `dump_glpi.sh` predate Ansible management entirely and aren't deployed by the role at all, they're just referenced by path and assumed to already exist on the host. Rather than continue that pattern for a brand-new script, the decision was to add a proper deployment task to `roles/baseline/tasks/restic.yml` so `backup_db2.sh` is reproducible and survives a host rebuild.
- **No new fleet-standard monitoring agents for Db2 itself** — since Db2 runs as a container on `lx1` (not its own VM/LXC), `lx1` already has Zabbix/Wazuh/GLPI agents covering the host; a Db2-specific Zabbix check (e.g., container-up monitoring) was left as an open decision rather than assumed necessary, deferred in favor of closing out backup/restore first.

## Step-by-Step

### Phase 1 — Container setup

- Created `~/docker/db2/` on `lx1` with a `.env` (`DB2INSTANCE`, `DB2INST1_PASSWORD`, `DBNAME=SAMPLE`, `LICENSE=accept`) and a `docker-compose.yml` (image `icr.io/db2_community/db2:latest`, `privileged: true`, `shm_size: 1g`, port `50000:50000`, a named volume mounted at `/database`) — matching the resource footprint (~4 cores / 8–16GB RAM / 100GB DB cap) the Community Edition already self-limits to, well within `lx1`'s headroom.
- `.env` was initially created without `DB2INST1_PASSWORD` set — the container still completed setup successfully (instance, SAMPLE database created), so rather than recreate the container, the OS-level `db2inst1` password was set directly after the fact with `docker exec ... chpasswd`, and the `.env` file updated afterward purely for documentation consistency (the running container doesn't re-read `.env` unless recreated).
- Verified connectivity via `docker exec ... db2 connect to sample`, both using the already-authenticated OS session and explicitly with `user ... using '<password>'` to confirm real credential-based auth would work the way the client app would use it.

### Phase 2 — Sample data

- Discovered that Db2's entrypoint only ran `CREATE DATABASE SAMPLE` (an empty database) — it never ran `db2sampl`, the separate utility that actually creates and populates the classic sample tables (`EMPLOYEE`, `DEPARTMENT`, `PROJECT`, etc.), Db2's rough equivalent of Oracle's HR schema.
- First `db2sampl` attempt failed because it defaults to *creating* SAMPLE from scratch and aborts if the database already exists — resolved with the `-force` flag, which tells it to populate the existing (empty) database instead.
- Verified via `LIST TABLES`: ~50 objects populated, then confirmed `EMPLOYEE` returned real rows with a sample query.

### Phase 3 — Client application

- Set up a Python virtual environment (`~/docker/db2/app/venv`) and installed `ibm_db`, which bundles the ODBC/CLI driver — no separate Db2 client install needed on the host.
- Wrote `query_employees.py`, connecting over TCP to `localhost:50000` (from outside the container, deliberately, to simulate a real external client) and printing the top employees by salary from the `EMPLOYEE` table. Flagged explicitly at this point: the password is hardcoded in the example for simplicity, and would need to move to an environment variable before this code is ever pushed to Gitea.
- Recovered from an accidental `rm -f` that deleted both a stray extra file and the freshly-created script (caused by mistakenly repeating the filename in the `nano` invocation) — no real loss since the file was small, but corrected the working directory in the process, since the script had been created in the wrong path relative to the virtualenv.
- Hit and fixed a formatting bug: `ibm_db` returns `DECIMAL` columns (like `SALARY`) as strings, not floats, so a `:.2f` format spec failed until the value was explicitly cast to `float()` first.
- Confirmed the app worked end-to-end: container → TCP connection → query → formatted output.

### Phase 4 — Native backup/restore drill

- Ran a first online backup attempt (`db2 backup db sample to /database/backups`) which failed twice in sequence: first with an invalid-path error because the target directory didn't exist yet, then with a permission error when trying to create it directly as `db2inst1` — root-caused to `/database` (the Docker volume mount point) being owned by a different user/UID than `db2inst1`. Resolved by creating the directory as the container's default (root) user via `docker exec` without `su`, then explicitly `chown`ing it to `db2inst1:db2iadm1` before retrying.
- Backup succeeded (~184MB for the fully-populated SAMPLE database), landing in the manually-created directory — at which point it was noticed that Db2's own container entrypoint had already created a separate `/database/backup` (singular) directory during initial setup, with correct ownership already in place; flagged as a cleanup item to address after the restore drill, rather than blocking on it immediately.
- Ran a full, non-cosmetic disaster-recovery drill, matching the `ora1` pattern: recorded the "before" state (42 rows in `EMPLOYEE`, plus the full query output as a detailed reference), forced all connections closed and dropped the SAMPLE database entirely (a real drop, not a softer simulated failure), confirmed the drop actually took effect (`db2 connect` failed with `SQL1013N`, database not found), then restored from the backup taken earlier (`db2 restore db sample from ... taken at <timestamp>`).
- Verified the restore matched the "before" state exactly: same row count (42), same top-10-by-salary ordering and values — confirming the full backup → disaster → restore cycle worked without data loss.

### Phase 5 — Cleanup and backup automation

- Consolidated the two backup directories, per Santiago's explicit request to keep the host tidy: moved the existing backup file from the manually-created `/database/backups` into Db2's own auto-created `/database/backup`, and removed the now-empty duplicate directory. All future backups (manual or scripted) target the single, correctly-owned directory going forward.
- Discussed and settled the Restic integration approach directly with Santiago: rather than a separate Restic repository, cron job, or backup script for Db2, folded it into `lx1`'s single existing host-level Restic repo and backup script — consistent with how every other Dockerized service on `lx1` (Portainer, WikiJS, Gitea, Uptime Kuma) is already backed up together under one repo, each exporting its own dump to `/opt/docker_dumps/<service>` before the shared backup runs.
- Confirmed `lx1`'s `/usr/local/bin/backup.sh` carries an explicit "Generated by Ansible (role: baseline) — do not edit manually" warning — avoided editing the generated file directly (which a future `ansible-playbook` run would silently overwrite) and instead worked in the actual Ansible source.
- Investigated how the existing `mon1`/`db1` pre-backup hooks (`restic_pre_backup_cmd`/`restic_pre_backup_desc`) are wired, and specifically how `dump_glpi.sh` gets onto `glpi1` — discovered that `roles/baseline/` has no `files/` directory and `restic.yml` has no task that deploys pre-backup scripts at all, meaning `dump_glpi.sh` and similar scripts are files that predate Ansible management and are simply assumed to already exist on their hosts; the role only ever references their path.
- Rather than repeat that gap for a brand-new script, wrote `backup_db2.sh` (native `db2 backup` inside the container → locate the newest resulting file → `docker cp` it out to `/opt/docker_dumps/db2/` → purge older backups inside the container's own volume → purge stale local copies in the dump directory, since Restic itself retains the real history) and added it to `roles/baseline/files/`, plus a new Ansible task in `roles/baseline/tasks/restic.yml` to actually deploy custom pre-backup scripts to `/opt/scripts/` — closing the gap for future scripts of this kind, not just this one.
- Added `restic_pre_backup_script: backup_db2.sh` and the existing-style `restic_pre_backup_cmd`/`restic_pre_backup_desc` variables to `host_vars/lx1.yml`.
- Ran `ansible-playbook site.yml --limit lx1 --check --diff` first, confirmed the diff showed only the expected additions (new script file, the pre-backup hook wired into the generated `backup.sh`) with nothing else on `lx1` touched, then applied for real.
- Verified end-to-end by running the full `backup.sh` manually (simulating the Sunday 3 AM cron): confirmed via `grep` on the backup log that the Db2 step ran with no `ERROR: pre-backup failed` line, confirmed the extracted backup file existed locally in `/opt/docker_dumps/db2/`, and confirmed — via `restic ls` against the actual remote snapshot on `bk1` — that the Db2 backup file was genuinely included in the uploaded snapshot, not just staged locally.

## Problems Solved

- The image reference IBM published under (`ibmcom/db2` on Docker Hub) has moved to `icr.io/db2_community/db2` on IBM's own registry — flagged proactively before writing any Compose file, avoiding a pull failure from stale documentation/memory.
- `docker compose logs -f` appeared to hang, but was actually suspended by an accidental `Ctrl+Z` (`^A^Z`) rather than genuinely stuck — the container itself kept running fine in the background; cleared with `kill %1`.
- The `.env` was missing `DB2INST1_PASSWORD` at container creation time, leaving the OS-level `db2inst1` account without the intended password — resolved after the fact with `chpasswd` rather than recreating the container, since the setup had already completed successfully.
- `db2 list tables`/`db2 select ...` failed with `SQL1024N` (no database connection) when run in a separate `docker exec` from the one used to `connect` — root-caused to each `docker exec` opening an independent shell session, with Db2's connection state not persisting across them; fixed by chaining `connect` and the query together in a single command.
- The SAMPLE database existed but had zero tables — the container's entrypoint only creates the empty database, not the populated sample schema; running `db2sampl` fixed this, but only after retrying with `-force` once it was clear the utility refuses to recreate a database that already exists.
- `db2 backup db sample to /database/backups` failed twice: first because the target directory didn't exist, then with a permission error when creating it as `db2inst1` — root-caused to `/database`'s root ownership as the Docker volume mount point; fixed by creating the directory as the container's default root user, then explicitly `chown`ing it to `db2inst1:db2iadm1`.
- An accidental `rm -f` with a duplicated filename in the command deleted both a stray file and the just-created Python script — no real setback (small file, quickly recreated), but also surfaced a working-directory mismatch (the file had been created outside the virtualenv's directory) that was corrected at the same time.
- `ibm_db`'s Python driver returns `DECIMAL` columns as strings rather than floats, breaking a `:.2f` format specifier until the value was explicitly cast with `float()`.
- Discovered two separate, redundant local backup directories (`/database/backups`, manually created, versus Db2's own auto-created `/database/backup`) — consolidated into the one Db2 creates and owns correctly by default, at Santiago's explicit request for a tidy host.
- Investigating how existing pre-backup scripts (`dump_glpi.sh`, etc.) get onto their hosts revealed they are **not** actually deployed by the Ansible role at all — a pre-existing gap (scripts assumed present, created before Ansible management began) rather than something broken by this project — addressed for the new script by adding a proper deployment task to the role instead of repeating the same undocumented-file pattern.

## Final Result

- **Container**: Db2 Community Edition running on `lx1` via Docker Compose (`icr.io/db2_community/db2:latest`), SAMPLE database populated with the standard Db2 sample schema (`EMPLOYEE`, `DEPARTMENT`, `PROJECT`, and the rest).
- **Client application**: `query_employees.py` (Python, `ibm_db`), running on the host and connecting over TCP to the containerized database, printing formatted salary data from `EMPLOYEE`.
- **Backup/restore validated end-to-end**: a full disaster-recovery drill (record state → force-drop the database → confirm the drop → restore from a native Db2 backup) confirmed identical data (42 rows, matching detail) before and after.
- **Backup fully automated and integrated into the fleet's existing pipeline**: a dedicated, Ansible-managed `backup_db2.sh` pre-backup hook (native backup → extract from container → prune old copies) runs as part of `lx1`'s single unified `backup.sh`, with the resulting Db2 backup file confirmed present in the same Restic repository and snapshot as the rest of `lx1`'s Dockerized services — no separate repo, script, or cron job for Db2.
- **Ansible role improvement (side effect)**: `roles/baseline/tasks/restic.yml` now has a generic task for deploying custom pre-backup scripts to `/opt/scripts/`, closing a gap that previously left scripts like `dump_glpi.sh` undeployed/unmanaged by the role.

## Pending

- No dedicated Zabbix check for the Db2 container itself (e.g., verifying `db2server` stays up) — left as an open decision, deferred once backup/restore automation was prioritized and closed first; `lx1`'s existing generic Docker monitoring in `mon1` may already cover this adequately.
- The client application's database password is still hardcoded in `query_employees.py` — flagged explicitly as needing to move to an environment variable before the code is pushed to Gitea.

## Cross-References

- Project 20 — Oracle XE Sandbox (ora1), whose RMAN backup/restore-drill pattern and disaster-recovery methodology this project directly mirrors for a second database engine.
- Project 16 — Ansible (lx1), whose `baseline` role and `host_vars`/pre-backup-hook conventions (`restic_pre_backup_cmd`/`restic_pre_backup_desc`) this project extended with a new, properly role-managed script.
- Project 4 — Ubuntu 22.04 + Docker + Nginx (lx1), the host and Docker Compose environment this project's container runs on, alongside Portainer, WikiJS, Gitea, and Uptime Kuma.
- Project 5 / 5.1 — Backups, Restic (bk1), the shared repository this project's backup was folded into rather than kept separate.
- Project 22 — Red Hat tools (rhel1), the next project in the series.
