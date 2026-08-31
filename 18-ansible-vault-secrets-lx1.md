---
title: 18-ansible-vault-secrets-lx1
description: ansible-vault-secrets
published: 1
date: 2026-08-31T11:16:59.953Z
tags: 
editor: markdown
dateCreated: 2026-08-30T19:13:21.297Z
---

# Project 18 — Ansible Vault Secrets Audit & Migration (lx1, fleet-wide)

**Previous:** [Project 17 — Terraform/IaC (lx1)](17-terraform-iac-lx1.md)
**Next:** [Project 19 — HashiCorp Vault (vault1)](19-hashicorp-vault-vault1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Locate every plaintext secret hardcoded across the pymesis.lab fleet, migrate the real ones into Ansible Vault, and close the exposure vectors uncovered along the way — turning application credentials into vaulted variables consumed by Ansible instead of values sitting in config files or shell history.

## Context

Ansible Vault was already in use for `ansible_become_password` since Project 16, but a number of application-level secrets (Odoo, Grafana LDAP, Wazuh/OpenSearch, the Medusa e-commerce stack) were still hardcoded in plaintext across config files, and nobody had ever swept the fleet for other exposed credentials. This project runs that sweep, formalizes the naming/vaulting pattern for application secrets, and fixes several unrelated issues (a stale role bug, a broken backup mechanism, a lost admin password) that surfaced during the audit.

## Decisions Made and Rationale

- Split the work into two phases — **Phase 1** (locate and encrypt values into Vault) and **Phase 2** (make the actual config files consume the vaulted variables) — run sequentially rather than together, to keep each change small and independently verifiable.
- Audited via Ansible: a `grep -rlEI` sweep of `/etc /opt /home` on Linux hosts and a `Select-String` sweep on Windows hosts, rather than inspecting each host by hand.
- Adopted a `vault_<host>_<varname>` naming convention for every new secret, consistent with the `ansible_become_password` pattern already in use.
- Did **not** vault the OPNsense API key found in `.bash_history` — confirmed it had no real automation consumer, so it was deleted at the source instead of migrated.
- Used `lineinfile` (not full Jinja2 templates) to inject vaulted values into existing config files, matching the pattern the role already uses elsewhere (e.g. the Wazuh manager IP).
- For the decommissioned `odoo17` instance, applied the vaulted value to its config file for consistency with Vault, but deliberately did **not** restart or re-enable the service.
- Used the official `wazuh-passwords-tool.sh` to reset a mis-vaulted OpenSearch admin password rather than trying to recover the original, since the Filebeat/OpenSearch keystores are write-only by design.
- Verified every Phase 2 change with `--check --diff` before applying for real, and only proceeded once the diff was empty or clearly limited to the intended correction.

## Step-by-Step

### Phase 1 — Secrets audit (Linux + Windows)

- Initial plan assumed Windows would need a separate manual pass; dropped once WinRM was confirmed already working on all 4 Windows hosts (`dc1`, `dc2`, `fs1`, `app1`) — unified into a single playbook covering both OS families.
- First run used `hosts: all:!windows`, which was too broad and pulled in `fw1`, `cl1`, `cl2`, `pve1` — narrowed the scope to `all:!windows:!firewall:!client`.
- Windows tasks initially failed with `ssh: connect... port 22` because the playbook lived at the repo root instead of `playbooks/`, so it never loaded `group_vars/host_vars` and defaulted to SSH — fixed by moving the playbook alongside `group_vars/`.
- Ad-hoc `win_stat` calls with a Windows path failed (`parse_kv` mangling backslashes) — switched to `win_shell` for raw diagnostic commands.
- Final playbook: per-host `grep`/`Select-String`, results saved to a per-host file, `fetch`-ed to `lx1`, then consolidated.
- Consolidation on `localhost` failed with `sudo: a password is required` because `group_vars/all/vars.yml` sets `ansible_become=true` globally and a play-level `become: false` didn't override that precedence — resolved by running the final `cat` concatenation manually, outside Ansible, for this one-off step.
- Filtered heavy false-positive noise from the raw results: IIS/.NET manifest tokens (`PublicKeyToken=`), `node_modules`, pip caches, Ansible collection test files, Python venvs, OCA test fixtures, and function signatures like `def get(password=None)`.

### Phase 1 — Real secrets found and vaulted

| Host | Variable(s) | Source |
|---|---|---|
| odoo1 | `vault_odoo1_db_password`, `vault_odoo1_admin_passwd` | `/etc/odoo/odoo.conf` |
| odoo2 | `vault_odoo17_db_password`, `vault_odoo17_admin_passwd`, `vault_odoo18_db_password`, `vault_odoo18_admin_passwd` | `/etc/odoo17.conf`, `/etc/odoo18.conf` |
| mon1 | `vault_grafana_ldap_bind_password`, `vault_wazuh_opensearch_admin_password` | `/etc/grafana/ldap.toml`; OpenSearch admin (no static file) |
| es1 | `vault_medusa_postgres_password`, `vault_medusa_jwt_secret`, `vault_medusa_cookie_secret` | `docker-compose.yml` |

A config bug was caught before vaulting: `odoo18.conf`'s `admin_passwd` was a copy-paste of its `db_password` — corrected to a distinct value prior to `ansible-vault encrypt_string`.

False alarms resolved without action: GLPI-agent `.cfg` files were fully commented out on every host; the `wazuh-install.sh` `adminPassword="wazuh"` string is an installer script variable, not a live credential.

### Phase 1 — Shell history hygiene

Initial `.bash_history` grep on `bk1`, `lx1`, and `odoo1` turned up every host's `ansible_become_password`, the shared Restic password, and an OPNsense API key/secret — all in plaintext. Rather than assume only those three hosts were affected, the check was escalated to a full fleet sweep: `sadmin` and `root` history on all Linux hosts, plus PowerShell's PSReadLine history on the 4 Windows hosts.

- Root history: clean on all 12 Linux hosts, no action needed.
- Windows PSReadLine history: clean on all 4 hosts.
- `sadmin` history: truncated via a dedicated Ansible playbook on the 11 managed Linux hosts (`pve1` excluded, out of scope), followed by `history -c && history -w` in the active local session to stop bash from rewriting the file with the old in-memory history on logout.

### Phase 1 — OPNsense findings

The `key=`/`secret=` pair in `bk1`'s history turned out to be a one-off manual exploration of the OPNsense REST API, with no real automation consumer — the `backup_api` user was deleted in OPNsense rather than rotated.

Investigating the actual backup mechanism (OPNsense pushes its config to `bk1` via SFTP) surfaced two real issues: the "SSH private key" field in OPNsense actually held a **public** key (mismatched pair), and "Configuration file is encrypted" was unset, meaning config XML backups landed on `bk1` unencrypted. Fixed by generating a dedicated `ed25519` keypair for this one function, installing the public half on `bk1`, pasting the private half into OPNsense, correcting the SFTP URL (a single `/` after the host resolves relative to the user's home — needed a double `//` for an absolute path), and setting an Encrypt Password on the OPNsense backup job.

### Phase 1 — GLPI Agent role bug

`--check --diff` on `odoo1`, `odoo2`, and `es1` surfaced `'glpi_agent_version' is undefined` — a variable referenced in three places in `roles/baseline/tasks/monitoring.yml` but never defined anywhere (a leftover "fill in later" placeholder; `mon1` was unaffected because it has `skip_glpi_agent: true`).

Adding a default (`glpi_agent_version: "1.19"`) only got partway — the role's install task assumed a generic `.deb` package that no longer exists in current GLPI Agent releases. Checking how agents were actually installed in production revealed the real method: the Perl `linux-installer.pl` script with a `--server` flag, which auto-generates `/etc/glpi-agent/conf.d/00-install.cfg` — not the `agent.cfg` file the role's `lineinfile` task was editing. Rewrote the install task to download and run the installer (`--install --no-question --silent --server=...`), made it idempotent via `creates: /usr/bin/glpi-agent`, removed the now-incorrect `lineinfile` task, defined `glpi_server_fqdn` as a role default, and pinned `glpi_agent_version` to `1.18` to match what was already running in production. Verified clean on all three affected hosts afterward.

### Phase 1 — OpenSearch/Wazuh admin password recovery

The value already vaulted for `vault_wazuh_opensearch_admin_password` turned out to be `admin` — the **username**, misread from a `wazuh-passwords-tool.sh -au admin -ap '...'` command in shell history, not the actual password. Neither that value nor the `-ap` value recorded in history authenticated against the indexer (both returned `401`); an earlier test against `localhost` had returned nothing at all because the indexer only binds to `10.0.20.60:9200`, not `127.0.0.1`.

Since the Filebeat and OpenSearch keystores are write-only, recovery wasn't an option — reset the password cleanly instead, using the official `wazuh-passwords-tool.sh -u admin -p <new-password>` against the security admin certificate. The tool updated Filebeat's keystore automatically as part of the reset. Verified the new password with a `200` from `_cluster/health`, restarted `wazuh-manager`, `wazuh-dashboard`, and `filebeat`, then vaulted the corrected value in place of the erroneous one.

### Phase 2 — Applying vaulted secrets to configs

- **odoo1**: `lineinfile` on `/etc/odoo/odoo.conf` for `db_password` and `admin_passwd`, with a restart handler. `--check --diff` showed only a cosmetic whitespace diff on `admin_passwd`; applied, then confirmed via `odoo-server.log` (clean DB reconnect, 126 modules loaded) and an internal `curl` (`303 SEE OTHER`, Odoo's normal login redirect).
- **odoo2**: two instances. `odoo18` (active) got the same treatment as odoo1, with a restart handler. `odoo17` (`disabled`, decommissioned mid-migration) had its config file updated for consistency with Vault, but with **no** restart handler attached. `--check --diff` returned `changed=0` on all four values; applied without disruption.
- **mon1**: `bind_password` in `ldap.toml` applied via `lineinfile` (`changed=0` — real value already matched); the OpenSearch admin password had already been corrected in the prior step. Confirmed `grafana-server`, `wazuh-manager`, `wazuh-dashboard`, and `filebeat` all active after the earlier restarts.
- **es1**: `docker-compose.yml` needed 4 lines touched — `POSTGRES_PASSWORD`, the same password embedded inside `DATABASE_URL`, `JWT_SECRET`, and `COOKIE_SECRET` — via backref-based `lineinfile`, with a `docker compose up -d` handler that only fires on real change. `--check --diff` returned `changed=0` on all four; applied with zero disruption to the running e-commerce stack.

## Problems Solved

- Assumed WinRM would need a manual Windows pass — it was already working fleet-wide, so the Linux/Windows split was dropped in favor of one unified playbook.
- Running the audit playbook from the repo root instead of `playbooks/` caused Windows tasks to fall back to SSH because `group_vars/host_vars` never loaded — fixed by relocating the playbook.
- `win_stat` mangled Windows paths via `parse_kv`'s backslash escaping — worked around with `win_shell` for raw commands.
- The `localhost` consolidation play failed on `sudo: a password is required` because a global `ansible_become=true` in `group_vars/all` outranked a play-level `become: false` — handled the one-off `cat` manually instead of fighting variable precedence.
- A `cat > file << EOF` heredoc (meant to append) used `>` instead of `>>` and wiped `roles/baseline/defaults/main.yml`, deleting pre-existing variables (`skip_wazuh_agent`, `restic_backup_paths`, etc.) — rebuilt the file with all original content plus the new variable, and switched to `repr()`-based inspection before any further scripted file edits to avoid blind-match failures.
- Python `str_replace`-style patches repeatedly failed to match a block due to an unaccounted blank line between two tasks — solved by dumping exact `repr()` output of the surrounding lines before constructing the replacement string.
- The GLPI Agent install task targeted a `.deb` naming convention that no longer exists and edited the wrong config file for server registration — corrected the install method (Perl installer + `--server`) and removed the task that was silently writing to the wrong file.
- The OpenSearch admin password had been vaulted as a username by mistake, and the real value was unrecoverable from a write-only keystore — resolved by resetting it cleanly through the official tool rather than attempting recovery.
- The OPNsense→bk1 SFTP backup was broken by a mismatched key pair (a public key pasted into the private-key field) and a relative-path URL bug — fixed with a dedicated keypair and a corrected double-slash path.

## Final Result

- **Ansible Vault**: 11 real secrets identified, encrypted, and applied across 4 hosts (odoo1, odoo2 ×2, mon1 ×2, es1 ×3), each verified live immediately after being applied.
- **Shell history hygiene**: `sadmin`'s `.bash_history` cleared on all managed Linux hosts; `root` history and Windows PSReadLine history confirmed clean fleet-wide.
- **OPNsense**: unused `backup_api` user and its API key removed; the real SFTP config backup to `bk1` fixed with a dedicated keypair and now encrypted at rest via OPNsense's Encrypt Password.
- **roles/baseline**: GLPI Agent installation corrected to the real installer method and registration mechanism, with `glpi_agent_version` and `glpi_server_fqdn` properly defined as role defaults.
- **Wazuh/OpenSearch**: admin password rotated to a known-good value via the official tool, replacing an incorrectly-vaulted placeholder, and verified functional end-to-end.
- **Applied secrets**: Odoo (odoo1, and odoo2's active `odoo18` instance) reconnected to its database without downtime; Grafana LDAP bind unaffected; the Medusa e-commerce stack on `es1` recreated with zero configuration drift.

## Pending

- HashiCorp Vault (`vault1`) — planned as its own follow-on project, per the original two-phase plan (Ansible Vault first, HashiCorp Vault separately).
- `mon1`'s Grafana LDAP `bind_password` (`grafana`) is weak — it matches the username. Flagged for future hardening, not addressed in this sprint.
- Historical unencrypted OPNsense config backups already sitting in `bk1:/mnt/backups/configs/fw1/opnsense` predate the Encrypt Password fix and remain in plaintext — optional manual cleanup.
- Docker-based secrets for `n8n1` (`N8N_ENCRYPTION_KEY`) and the Gitea PAT on `lx1` were not caught by the filesystem-based audit, since they live inside container volumes/env files rather than the host filesystem — flagged as a follow-up audit (`docker inspect`, review of each stack's `docker-compose.yml`/`.env`).

## Cross-References

- Project 16 — Ansible (lx1), where `ansible_become_password` was first vaulted, establishing the baseline pattern this project extends.
- Project 8 — Odoo/PostgreSQL (odoo1/db1)
- Project 12 — Odoo 17→18 migration (odoo2)
- Project 9 / 9.1 — Monitoring stack, Wazuh (mon1)
- Project 13 — eShop Medusa (es1)
- Project 2 — OPNsense
- Project 5 / 5.1 — Backups, Restic (bk1)
- Project 19 — HashiCorp Vault (vault1), the planned continuation
