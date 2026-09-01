---
title: 16-ansible-implementation-lx1
description: ansible
published: 1
date: 2026-09-01T17:38:30.494Z
tags: 
editor: markdown
dateCreated: 2026-08-30T12:07:15.345Z
---

# Project 16 — Ansible Implementation (lx1)

**Previous:** [Project 15 — Kubernetes (k3s1)](15-k3s-single-node-k3s1.md)
**Next:** [Project 17 — Terraform/IaC (lx1)](17-terraform-iac-lx1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Replace the manual, repeated-by-hand "day 2" setup applied to every new VM/LXC (QEMU Guest Agent, `sadmin` ownership, timezone, Zabbix/Wazuh/GLPI agents, Restic backup) with an Ansible baseline role driven by a dynamic Proxmox inventory, with secrets handled via Ansible Vault from the very first commit — and extend it to cover the entire 16-host fleet, Windows included.

## Context

This project follows [Project 15 — K3s Single-Node Installation](15-k3s-single-node-installation.md), the last item on the original roadmap. Ansible was the natural "day 2" companion to Terraform/IaC: Terraform provisions an empty VM/LXC, and everything applied to it afterward (agents, backup, conventions) had until now been done by hand on every one of the fleet's 16 hosts (12 Linux, 4 Windows). This single project ended up covering the full baseline rollout, the fleet-wide Ansible Vault secrets migration, and — near the end — onboarding `vault1` (the HashiCorp Vault host, built separately) back into this same Ansible-managed fleet.

## Decisions Made and Rationale

- **Ansible core first, AWX deferred indefinitely as an evaluate-later option**: standing up AWX is itself a mini Kubernetes/Docker project, and doing it on day one would mean learning that instead of Ansible itself.
- **Dynamic inventory via `community.general.proxmox` from the very first commit, no static-inventory intermediate stage**: a two-phase plan (static first, dynamic once QEMU Guest Agent was confirmed everywhere) was considered and explicitly dropped once it was confirmed the Guest Agent was already active fleet-wide per existing conventions — no reason to build something temporary.
- **Ansible Vault adopted from the first commit, not bolted on later**: consistent with a broader pattern in this project of picking the more production-aligned option at every fork rather than the shortcut — the Proxmox API token itself was the first secret that would otherwise have been hardcoded.
- **Dedicated `ansible@pve` read-only token, mirroring the existing `terraform@pve` pattern**: scoped to `VM.Audit`/`Datastore.Audit`/`Sys.Audit` only — the inventory plugin never needs write access, unlike Terraform's token.
- **Windows hosts (dc1, dc2, fs1, app1) included in the same project rather than deferred**: required adding WinRM support (`ansible.windows` collection) alongside the SSH-based Linux baseline, rather than treating Windows as a separate future effort.
- **HTTPS-only WinRM (port 5986), HTTP/5985 listener and its firewall rule removed**: dc1/dc2 reused their existing auto-issued Domain Controller Authentication certificate; fs1/app1 required a manual `certreq` against the WebServer template.
- **The fleet's two divergent backup styles reconciled into one standard**: a crontab audit across all 12 Linux hosts revealed 4 hosts (lx1, mon1, db1, odoo1) already used a more mature `/usr/local/bin/backup.sh` pattern (env-driven repo, tagging, standard excludes, dump cleanup, pre-backup hooks), while the other 7 used simpler inline `restic` commands directly in crontab with no cleanup step. The mature pattern was adopted as the new baseline standard for all 12, rather than picking the simpler one or inventing a third.
- **`bk1` deliberately excluded from Restic self-backup**: it's the backup destination itself; its own backup will be handled later via `rclone` once NAS hardware (Ugreen DXP4800) arrives for Node 2.
- **Windows scheduled backups kept at 02:30, not unified to Linux's 03:00**: the existing 30-minute stagger between the two operating-system groups was intentional (avoiding a simultaneous-load spike on `bk1` from all 16 hosts at once) and was deliberately preserved rather than "cleaned up" into a single time.
- **Go-live rollout ordered by risk, not alphabetically or by host importance**: `k3s1` first (newest, least entangled with anything else), then `llm1`/`n8n1`/`es1`/`odoo2`, then `glpi1`/`hr1`, and finally the four hosts underpinning everything else (`lx1`, `mon1`, `bk1`, `db1`, `odoo1`) — each host's pre-existing unmanaged crontab lines were manually cleaned before its first real (non-`--check`) run, to avoid duplicate backup jobs.
- **Secrets handled as a staged, auditable process rather than a one-shot migration**: an audit pass across the dynamic inventory (and, separately, Windows PowerShell history) located hardcoded secrets and their file paths first; only confirmed, real, currently-active secrets were migrated into `vault.yml`, rather than vaulting everything the audit's pattern-matching flagged.
- **HashiCorp Vault kept out of scope as a separate future project**: acknowledged from the start as the "phase 2" of secrets management (a dedicated `vault1` host exploring a PKI secrets engine against the existing internal CA), deliberately not pulled into this Ansible project's scope even though Ansible Vault was being built out in parallel.

## Step-by-Step

### Phase 1 — Repo scaffold, Vault, and dynamic inventory

The repo was created at `/opt/ansible/pymesis-infra` on lx1 (`git init`, `.gitignore` for `.vault_pass`/`*.retry`/`*.log`, `ansible.cfg` with `vault_password_file=.vault_pass` and `host_key_checking=False`). On pve1: the `ansible@pve` user/role/token (`AnsibleAudit`: `VM.Audit`, `Datastore.Audit`, `Sys.Audit`) was created with `--privsep 0` (no privilege separation needed for a read-only inventory token). `.vault_pass` was generated via `openssl rand`; the Proxmox token secret was stored encrypted in `group_vars/all/vault.yml`, referenced from the plain `group_vars/all/vars.yml` and `inventory/pve1.proxmox.yml`. Dynamic inventory was confirmed working with `ansible-inventory -i inventory/pve1.proxmox.yml --list`.

### Phase 2 — Baseline role design

The `baseline` role was scoped to exactly the manual steps already documented across every VM in the lab: QEMU Guest Agent, timezone, `sadmin` ownership, Zabbix agent (installed via generic `apt` from the distro repo rather than Zabbix's own `.deb` repo), Wazuh agent, GLPI agent, and full Restic treatment (install, backup script, password file, cron, repo init, optional pre-backup DB dump hook per host).

### Phase 3 — SSH/WinRM bootstrap across the fleet

`sadmin`'s SSH key from lx1 (the Ansible control node — distinct from `app1`, which had previously served as a manual SSH pivot point) was distributed to 10 of the 12 Linux hosts via `ssh-copy-id`; `hr1` and `k3s1` initially rejected key auth (password auth disabled) and were fixed by adding the public key manually through the `app1` pivot. Separately, `dc1`/`dc2`/`fs1`/`app1` were tagged `windows` in Proxmox (so the dynamic inventory groups them automatically via `keyed_groups`), and WinRM was fully configured on all four with HTTPS-only listeners and Server-Authentication certificates. Connectivity was confirmed across all 16 hosts: `win_ping` SUCCESS on the 4 Windows hosts, SSH key auth working on the 12 Linux hosts.

### Phase 4 — Connection config and variable structure

`group_vars/all/vars.yml` set `ansible_user=sadmin`, `ansible_become=true`, `ansible_become_method=sudo`; `group_vars/windows.yml` overrides `ansible_become=false` (WinRM/Administrator doesn't need it). Each of the 12 Linux hosts got its own `host_vars/<host>.yml` with an individually-vaulted `ansible_become_password`, since the sudo password varies per host (unlike the Restic password, later confirmed to be shared fleet-wide).

### Phase 5 — Secrets audit and bash_history cleanup

A secrets-audit pass ran across the dynamic inventory (Linux) and, separately, an adapted PowerShell script (`Get-ChildItem` + `Select-String` over config/script files) across the 4 Windows hosts. After filtering audit noise (OSSEC rule examples, SQL Server IDE docs, Odoo source parameter names, dependency caches), real findings included: live `db_password`/`admin_passwd` values in odoo1's and odoo2's config files (with a copy-paste bug in odoo2's `odoo18.conf`, where `admin_passwd` had been set to the DB password's value), and an active LDAP bind password in mon1's Grafana config. A separate, expanded sweep of `sadmin`'s shell history across all 12 Linux hosts surfaced further live secrets not caught by the file-based audit: a real OPNsense firewall API key/secret pair on `bk1`, a real OpenSearch/Wazuh admin password on `mon1`, and real Medusa secrets (Postgres password, JWT secret, cookie secret) on `es1`. Windows PowerShell history came back clean on all 4 hosts. `sadmin`'s shell history was truncated fleet-wide once the relevant values were captured; root's history was confirmed already clean.

### Phase 6 — Backup standardization and go-live rollout

With the mature `backup.sh` pattern chosen as the fleet standard, the role's template and defaults were rewritten to parametrize backup paths, excludes, dump cleanup, and pre-backup hooks per host, with `host_vars` overrides added for all 12 Linux hosts to match their real existing backup content exactly. `--check --diff` was run clean across all 12 before any real changes. The rollout proceeded host by host in the risk order defined above, uncovering and fixing two categories of real, previously-invisible gaps: hosts where `root` (which runs Ansible's `become:true` tasks) had no SSH identity to `bk1` at all, even though `sadmin` did; and — more seriously — 4 hosts (`k3s1`, `hr1`, `n8n1`, `es1`) where `sadmin` itself had no SSH private key configured, meaning their "existing" scheduled backups had likely never actually run unattended, only ever succeeding when someone answered an interactive password prompt by hand. Both classes of gap were fixed with dedicated setup playbooks generating and authorizing per-account keypairs against `bk1`.

### Phase 7 — Cross-distro support and monitoring fixes

`mon1` (Rocky Linux) required OS-family-aware role logic: `system.yml`'s QEMU Guest Agent task switched to the generic `ansible.builtin.package` module, and `monitoring.yml`/`restic.yml` were split by `ansible_os_family` (Debian vs. RedHat), with new `skip_wazuh_agent`/`skip_glpi_agent` flags for mon1's special status as the Wazuh manager itself. While rolling out the remaining "old style" hosts, a bonus fix surfaced: `odoo1`, `lx1`, and `db1` all had Zabbix agent2 sitting on default, never-configured values (`Server=127.0.0.1`, `Hostname="Zabbix server"`) — meaning they had never actually been reporting to `mon1` until the baseline role corrected it.

### Phase 8 — Windows baseline role

A parallel `windows_baseline` role was built and applied to all 4 Windows hosts: timezone, ensure-running/configure for already-installed Zabbix/Wazuh/GLPI agents (no install logic needed, since all 4 already had them), and a `backup.ps1.j2` template replicating each host's real pre-existing PowerShell backup logic (`dc1`/`dc2`'s `ntdsutil` IFM snapshot step, `app1`'s SQL Server dump loop, `fs1`'s plain file backup), deployed via `community.windows.win_scheduled_task`. The backup repository URL was standardized from a raw IP to the `bk1` hostname, matching the Linux convention.

### Phase 9 — Vaulting and applying real secrets (phase 2)

With the audit's confirmed findings in hand, the OPNsense API key/secret was investigated first and found to be an abandoned manual test rather than the real backup mechanism — the actual OPNsense config backup uses an SSH-key-based SFTP push from `fw1` to `bk1`, which was fixed end-to-end (dedicated keypair, encrypted backup password set, corrected SFTP URL) rather than vaulted. The remaining 11 confirmed real secrets (odoo1 DB+admin, odoo2's odoo17/odoo18 DB+admin with the copy-paste bug corrected, mon1's Grafana LDAP bind and Wazuh/OpenSearch admin password, es1's Medusa Postgres/JWT/cookie secrets) were encrypted with `ansible-vault encrypt_string` and applied host by host via small `apply-secrets-<host>.yml` playbooks using `lineinfile`/config-templating, each verified with a clean `--check --diff` (`changed=0`) confirming the live values already matched before any real write, then applied for real.

### Phase 10 — GLPI Agent install mechanism fix

The role's GLPI Agent install task used an outdated `.deb` URL naming pattern that 404'd on 3 hosts. Production agents, it turned out, had actually been installed via the Perl `linux-installer.pl` all along, not a `.deb` package — the task was rewritten to match, and a second, deeper bug was found in the process: the role's config task was editing `glpi-agent.cfg`'s `server` line directly, but the agent doesn't read its server from there at all — it reads from an auto-generated `/etc/glpi-agent/conf.d/00-install.cfg`, created only when `--server` is passed to the installer itself. Fixed by passing `--server` directly to the installer command instead of post-configuring a file the agent never actually consults.

### Phase 11 — vault1 onboarding

`vault1` (built manually and separately, exploring HashiCorp Vault) had never been onboarded into this Ansible project, unlike every other host in the fleet — a gap identified and closed near the end of this project. Its pre-existing Restic repository and password were reused rather than overwritten (the same class of near-miss already caught once with `glpi1`), its manual daily backup cron was removed to avoid a competing job, and it was kept on the fleet-standard weekly cadence rather than extending the role to support a per-host schedule for one exception. Rolling this host out also surfaced a real, previously-latent role bug: the Wazuh apt-repository task doesn't use `signed-by`, so a host that already had Wazuh manually configured with `signed-by` (as vault1 was) hit a hard `apt` conflict between the two source lines for the same repo. A Zabbix `UserParameter` check (`vault.sealed`) and a High-severity trigger were also added after the first real backup run failed silently because Vault itself was sealed (Shamir seal, no auto-unseal) — a gap that otherwise would have failed unnoticed until the backup was actually needed.

### Phase 12 — Closing out the Windows hosts

The final blocker to a full 16/16 close-out was `app1`'s scheduled backup task appearing to hang indefinitely. After ruling out a genuinely stuck process, the real cause matched the earlier Linux `root`-to-`bk1` gap exactly: `PYMESIS\Administrator` (the account the Scheduled Task runs as) had no SSH key authorized on `bk1` at all, so `restic` was correctly, silently waiting on an interactive password prompt that WinRM's non-interactive session could never satisfy. A dedicated `setup_admin_bk1_access.yml` playbook generated and authorized a keypair for `Administrator` on all 4 Windows hosts — `dc1`, `dc2`, and `fs1` turned out to have the exact same latent gap, simply not yet triggered by a real unattended run.

## Problems Solved

- **`group_vars`/`host_vars` were resolving from the wrong directory, causing a long "Missing sudo password" debugging session**: Ansible resolves these relative to the playbook (or inventory) being run, not the repo root — since playbooks live in `playbooks/`, the variable directories had to move to `playbooks/group_vars/` and `playbooks/host_vars/`. Ad-hoc `ansible`/`ansible-inventory` commands had masked the bug the whole time, since they resolve relative to the current working directory instead.
- **A near-miss caught by discipline, not luck**: the first real `--check --diff` run against `glpi1` revealed it already had its own genuinely different Restic password and its own production dump script — running the role for real without `--check` first would have overwritten a working password file and broken access to an already-initialized backup repository.
- **Assumed per-host Restic password turned out to be fleet-wide**: an ad-hoc `slurp` across all 12 Linux hosts confirmed the real Restic password was identical everywhere (unlike the sudo/become password, which genuinely does vary per host) — the vaulted variable was corrected accordingly.
- **A stale path bug survived a hostname rename**: `hr1`'s cron still referenced `/mnt/backups/hr1` instead of the standardized `/mnt/backups/repos/hr1`, left over from before the `harbor1` → `hr1` rename — fixed automatically once the repo URL became a shared computed variable instead of a hardcoded per-host string.
- **`root` had no SSH identity to `bk1` at all on the newer hosts**: `k3s1`'s first real go-live run failed for reasons that took a long detour through SSH multiplexing, `command` vs. `shell` module behavior, and async/poll settings before the real cause surfaced — `root` (which executes `become:true` tasks) simply had no keypair, known_hosts entry, or `BatchMode` configuration for `bk1` at all, unlike `sadmin`. Fixed with a dedicated keypair generated for `root`, authorized against `bk1`'s existing `sadmin` account.
- **Four hosts' "existing" scheduled backups had likely never actually run unattended**: `sadmin` had no SSH private key whatsoever on `k3s1`, `hr1`, `n8n1`, and `es1` — meaning any snapshot that did exist was almost certainly the result of someone manually answering an interactive password prompt, not a working cron job.
- **Ad-hoc commands silently failed to find `ansible.cfg` when run from inside `playbooks/`**: fixed by exporting `ANSIBLE_CONFIG` persistently in `~/.bashrc` rather than requiring every future session to `cd` back to the repo root first.
- **The entire repository had never actually been committed to git**, despite earlier having been referred to as already pushed — it existed only on lx1's local filesystem, with no history and no off-host copy. An initial commit was made and pushed to Gitea over HTTPS (Gitea's internal SSH port wasn't exposed on this host), with `.gitignore` confirmed to correctly exclude `.vault_pass` before committing, so no secret was leaked in the process.
- **A previously-vaulted secret was wrong from the start**: `vault_wazuh_opensearch_admin_password` had actually been vaulted with the literal value `"admin"` (the username, not the password). Since OpenSearch/Filebeat keystores are write-only by design, the real original password was unrecoverable — resolved by generating a new one and resetting it via `wazuh-passwords-tool.sh`, which cascaded correctly to the Filebeat keystore.
- **A monitoring role file had silently lost tasks at some point**: `roles/baseline/tasks/monitoring.yml` was missing its Wazuh-agent and GLPI-agent installation tasks entirely (the same category of loss later also found in a handlers file) — restored, though harmless in practice since every already-live host already had those agents installed manually beforehand.
- **A previously "successful" Restic backup run on `vault1` had actually failed silently**: Vault was sealed (no auto-unseal configured, likely from an unrelated service restart), causing the pre-backup snapshot step to fail with a 503 that aborted the backup cleanly but without alerting anyone — a gap that would only have been noticed the day the backup was actually needed. Fixed by manually unsealing and adding a dedicated Zabbix check for seal status going forward.
- **`app1`'s (and, once checked, `dc1`/`dc2`/`fs1`'s) scheduled Windows backup appeared to hang indefinitely**: correctly diagnosed, after ruling out a genuinely stuck process via Task Manager, as `PYMESIS\Administrator` having no SSH key authorized on `bk1` — the exact same class of gap already fixed for Linux's `root`, just not yet discovered on the Windows side. Fixed with a dedicated setup playbook mirroring the Linux one.

## Final Result

- All 16 hosts of the pymesis.lab fleet (12 Linux, 4 Windows) are managed by this Ansible project's baseline roles, each with a real, verified, unattended Restic backup running on schedule — not merely a role that claims to configure one.
- A working dynamic Proxmox inventory (`community.general.proxmox`) replaces any static host list, with a dedicated read-only `ansible@pve` token.
- Ansible Vault protects every credential this project touches: the Proxmox API token, per-host `sudo` passwords, and 11 confirmed real application/service secrets (Odoo, Grafana, Wazuh/OpenSearch, Medusa) — each vaulted, applied, and verified with a clean `--check --diff` before any real change.
- The OPNsense firewall's own configuration backup was fixed as a side effect of the secrets audit, moving from an abandoned API-key experiment to a working SSH-key-based SFTP push.
- `vault1` (the separately-built HashiCorp Vault host) is now onboarded into the same fleet-wide Ansible management, including a new Zabbix check catching Vault's sealed state going forward.
- The repository is committed and pushed to Gitea (`https://gitea.pymesis.lab/admin/ansible-pymesis-infra`).

## Pending

- `docker_host` and `db_server` role variants proposed at the project's outset were never built — only the fleet-wide `baseline`/`windows_baseline` roles exist; role specialization by host type remains open.
- `N8N_ENCRYPTION_KEY` and the Gitea Personal Access Token were not captured by this project's secrets audit, since both live inside Docker containers/volumes rather than host files — a separate Docker-focused secrets pass is still needed.
- Rotating the abandoned OPNsense API key/secret pair found in `bk1`'s shell history (the user account itself was deleted, but formal key rotation as a hygiene step wasn't separately tracked).
- HashiCorp Vault as its own project (PKI secrets engine against `pymesis-DC01-CA`) continues independently — this project only onboarded the resulting `vault1` host into fleet-wide Ansible management, it didn't build out Vault's own capabilities.
- AWX remains deliberately unevaluated, to be revisited only if the project's scope grows enough to justify it.

## Cross-References

- Builds on the Proxmox API token pattern established in the Terraform/IaC project (`terraform@pve`), reused here as `ansible@pve` with read-only scope.
- The `bk1` backup-destination and `RESTIC_PASSWORD_FILE`/repository-path conventions referenced throughout this project are the same lab-wide standard used in Projects 10–15.
- `vault1`'s onboarding here is a late cross-link to the separate HashiCorp Vault project (indexed later in the lab as its own item) — the two projects' documentation should be read together for the full picture of the lab's secrets-management story.
- The lab index lists Ansible Vault Implementation as a separate, later project — in practice, Ansible Vault was integrated from this project's first commit and its secrets-migration work (the bulk of this document's Phases 5 and 9) was carried out entirely within this same session; any distinct Ansible Vault project documentation should be treated as a continuation or refinement of what's already covered here, not a separate starting point.

---

[← **Previous:** Project 15 — Kubernetes (k3s1)](15-k3s-single-node-k3s1.md) | [**Next:** Project 17 — Terraform/IaC (lx1) →](17-terraform-iac-lx1.md)