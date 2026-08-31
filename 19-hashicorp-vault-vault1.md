---
title: 19-hashicorp-vault-vault1
description: hashicorp-vault
published: 1
date: 2026-08-31T11:16:26.789Z
tags: 
editor: markdown
dateCreated: 2026-08-31T11:15:59.641Z
---

# Project 19 — HashiCorp Vault (vault1)

**Previous:** [Project 18 — Ansible Vault Secrets Audit & Migration (lx1, fleet-wide)](18-ansible-vault-secrets-lx1.md)
**Next:** [Project 20 — Oracle XE Sandbox (ora1)]()

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Stand up HashiCorp Vault as its own service (`vault1`), with real dynamic secrets management: a KV v2 engine as the base case, and — as the CV-relevant centerpiece — a PKI intermediate engine issuing short-lived certificates dynamically, chained to the lab's existing `pymesis-DC01-CA` instead of acting as its own root. Close with machine-to-machine auth (AppRole) so other pieces of the homelab can eventually request certs and secrets without manual intervention.

## Context

Every certificate in the lab up to this point had been issued by hand from `pymesis-DC01-CA` (AD CS) via `certreq`/`certsrv`. This project's PKI value proposition is specifically to keep that CA as the root of trust while letting Vault issue short-TTL certs dynamically underneath it as a subordinate CA — the harder, more realistic path compared to letting Vault be its own root. The project also folds in a security decision this host needed regardless of Vault (SSH hardening) and, later, a retrofit to bring `vault1` under the same Ansible-managed monitoring/backup baseline as the rest of the fleet, since it was originally built by hand in parallel with the Ansible rollout.

## Decisions Made and Rationale

- **LXC, not VM** — Vault has no requirement (like Docker's overlayfs or K3s) that would force a full VM; using one here would be over-engineering. Migration path if ever needed is Vault's own `raft snapshot save`/restore mechanism, not disk cloning.
- **`disable_mlock = true`**, justified rather than just convenient: the LXC's `120.conf` shows `swap: 0` — there is no swap partition for secrets to leak into, so `mlock()`'s protection is redundant here. Attempting `lxc.cap.keep` to grant `IPC_LOCK` was tried first and abandoned once it broke the container's boot (see Problems Solved).
- **Provisioned via Terraform** (`pymesis-infra`, following the `glpi1.tf` pattern) rather than by hand — consistent with treating Vault as a production service, not a sandbox, and with the project's broader "everything new is born in IaC" trajectory.
- **VMID 120, IP 10.0.20.96** — chose the next clean IP in sequence (after `n8n1` at `.93` and `k3s1` at `.95`) over reusing the `.94` slot freed by `tf-test1`, to avoid an IP with mixed history.
- **TLS from the internal CA, not Vault's self-signed default** — consistent with `glpi1`/`odoo1`/`k3s1`, Vault's auto-generated self-signed cert at install time is discarded in favor of one issued by `pymesis-DC01-CA`.
- **Shamir seal (5 shares / threshold 3), not auto-unseal** — even though one person holds all 5 shares in this lab, the mechanism is kept real (not collapsed to 1-of-1) since it's a genuine CV talking point. Auto-unseal via an external KMS was explicitly rejected later as unnecessary complexity for a single-node homelab.
- **PKI: Vault as an intermediate CA under `pymesis-DC01-CA`**, not as its own root — the harder, more realistic option, explicitly chosen over the simpler "Vault as root" path.
- **PKI role TTL: 30 days max**, deliberately short — the entire point of dynamic PKI versus the 1–10 year certs issued by hand elsewhere in the lab.
- **AppRole for machine-to-machine auth**, scoped with a narrow policy (only `pki_int/issue/pymesis-lab` and `pki_int/cert/ca_chain` — no `sys/`, no PKI engine management).
- **Create `sadmin` + disable root SSH login on `vault1`**, going a step further than the rest of the fleet's convention: not just consistency, but because a host holding secrets and an intermediate CA is the worst place in the lab to allow direct root SSH login (no audit trail, no sudo choke point if the key is ever compromised).
- **Did not retrofit `sadmin`/root-lockdown to the rest of the fleet immediately** — flagged as the future first real Ansible playbook (once a second node justifies starting that project), rather than a rushed host-by-host sweep; explicitly called out the risk that `bk1`'s Restic backups authenticate as root over SSH, so blanket-disabling root login without checking that first could break backups fleet-wide.
- **Dedicated AppRole for the backup script** (`vault1-backup`, read-only on `sys/storage/raft/snapshot`), separate from the PKI AppRole and never using the root token in a script on disk.
- **Retrofit under the Ansible `baseline` role rather than leave the manual backup in place** — once the gap was noticed (Vault was the only host with an out-of-band cron instead of the fleet-standard Ansible-managed backup), the manual `/root/backup-vault1.sh` + crontab entry was migrated into `roles/baseline`, reusing the existing AppRole/SSH-key rather than recreating them.
- **Weekly backup cadence, matching the rest of the fleet**, rather than keeping the daily cadence set up by hand — decided the Raft snapshot doesn't change often enough to justify the extra complexity of a per-host cron override in the role.
- **Fixed the Wazuh APT-repo conflict by aligning `vault1` to the role's method, not by patching the shared role** — since the role's `signed-by`-less repo definition already worked cleanly on 15 other hosts, and the conflict was specific to `vault1` having been configured by hand first.
- **Added a Zabbix check for `vault.sealed`** rather than leaving the "Vault reseals itself on any restart, since there's no auto-unseal" risk as silent technical debt.

## Step-by-Step

### Phase 1 — Provisioning (Terraform)

- Wrote `vault1.tf` following the `glpi1.tf` pattern (`template_file_id` with `lifecycle { ignore_changes = [operating_system] }`, explicit console, `local-zfs` storage, `unprivileged = true`).
- `terraform plan`/`apply` created LXC 120, resolving `vault1.pymesis.lab` via DNS (a template addition made independently of the original file).
- Noted upfront: the `bpg/proxmox` provider's `initialization.user_account` block for LXC only configures `root`, never a non-root user — a known limitation already hit with `tf-test1`. Every LXC born from this Terraform repo starts as root+key only, requiring a manual post-provisioning step to add `sadmin`.

### Phase 2 — Vault installation

- Attempted `lxc.cap.keep: sys_resource ipc_lock` in `/etc/pve/lxc/120.conf` to grant `IPC_LOCK` for `mlock()` — this broke the container's boot entirely, because `lxc.cap.keep` is exclusive, not additive: it strips every capability except the ones listed, including ones needed for basic container startup (networking, cgroups, systemd init).
- Reverted that change and confirmed `swap: 0` in the LXC config, making `disable_mlock = true` a justified decision rather than a shortcut (no swap exists for secrets to leak into).
- Installed via the official HashiCorp apt repo. First attempt failed on two independent issues: `sudo` wasn't available (already logged in as root) and the codename variable used (`UBUNTU_CODENAME`) returned empty on this Debian host — resolved by dropping `sudo` and confirming the codename manually.
- A second failure (`gnupg`/`curl` 404s, then `NO_PUBKEY` on `apt update`) traced back to a single root cause: the LXC template's package index was frozen at an older Debian point release, so the very first `apt install` 404'd, which meant `gpg` was never installed, which meant the keyring file was never created — a chained failure from one stale index, resolved once `apt update` refreshed it.
- Discarded Vault's auto-generated self-signed cert at `/opt/vault/tls`, issuing a real one from `pymesis-DC01-CA` for `vault1.pymesis.lab` (SAN: `vault1.pymesis.lab`, `vault1`, `10.0.20.96`) instead, matching the rest of the fleet's convention.
- Wrote `/etc/vault.d/vault.hcl` (Raft storage, TLS listener, `disable_mlock` as a top-level directive — not nested inside `listener`, a mistake caught before it was applied — and a `node_id` pre-set for a future HA cluster even though only one node exists today).
- First `systemctl start` failed silently in the visible journal; root-caused by comparing the `.hcl`'s configured path (`vault1.crt`) against the actual file the CA had produced (`vault1.cer`) — a naming mismatch, not a certificate problem. Renaming resolved it; Vault came up `active (running)` with TLS and Raft storage ready.

### Phase 3 — Init, unseal, KV v2

- `vault operator init` initially failed with a TLS trust error (`certificate signed by unknown authority`) — the Vault CLI on `vault1` didn't yet trust `pymesis-DC01-CA` at the OS level. Resolved by copying the CA cert into the system trust store and running `update-ca-certificates`.
- Ran init/unseal for real: 5 Shamir shares, threshold 3, `Initial Root Token` and unseal keys captured to a file that was deleted with `shred -u` immediately after being recorded elsewhere — confirmed explicitly before continuing.
- Enabled KV v2 at `kv/` and wrote a test secret. `jq` wasn't installed on the host — installed it as a quick fix, useful for all future JSON output from Vault.

### Phase 4 — PKI intermediate under `pymesis-DC01-CA`

- Enabled `pki_int`, generated an intermediate CSR (`vault write pki_int/intermediate/generate/internal`). The first attempt actually succeeded in generating the key/CSR, but the output pipe to `jq` failed because `jq` wasn't yet installed at that point in the sequence — re-running generated a fresh key/CSR pair, which was expected and not a problem since nothing had been signed yet.
- Submitted the CSR to `pymesis-DC01-CA` via `certreq -submit -attrib "CertificateTemplate:SubCA"` from a Windows host with RSAT — the lab's first cert issuance using a Subordinate CA template rather than the Web Server template used for every prior host cert. Confirmed the template was already enabled on the CA (`certsrv.msc` → Certificate Templates).
- Hit and resolved a double-Base64-encoding mistake: `certreq -submit` already returns PEM by default, but running `certutil -encode` on that output a second time wrapped it again — caught by noticing the decoded content started with the literal string `-----BEGIN CERTIFICATE-----` re-encoded as Base64, rather than the certificate itself. Used the original `.cer` file directly instead.
- Hit a `set-signed` failure that turned out to be an unset `VAULT_ADDR` in the new SSH session — the certificate itself and the intermediate/root bundle were both correct; the CLI was simply falling back to `127.0.0.1:8200`, which the cert (issued for `vault1.pymesis.lab`/`10.0.20.96`) doesn't validate against.
- `pki_int/intermediate/set-signed` succeeded, returning `imported_issuers` with two IDs and the full chain via `pki_int/cert/ca_chain` — confirmed as the most delicate step in the project, closed cleanly.
- Created the `pymesis-lab` PKI role (`allowed_domains="pymesis.lab"`, `allow_subdomains=true`, `max_ttl="720h"`) and issued a test cert for `test1.pymesis.lab` on the first try — a deliberate contrast against the multi-step manual `certreq`/Windows process just used for the intermediate itself.
- Enabled AppRole, wrote a narrow-scope policy (`pymesis-lab-pki.hcl`, only issuance and CA-chain reads), and created the AppRole tied to it (`token_ttl=1h`).
- Configured AIA/CRL URLs (`pki_int/config/urls`) so certs self-describe where to find the issuer and revocation list. Verified with a fresh test cert (`openssl x509 ... | grep -A2 'Authority Information'`) rather than assuming the earlier warning meant it hadn't taken effect.

### Phase 5 — Access hardening (sadmin, root SSH lockdown)

- Confirmed the Terraform-provisioned LXC had only `root`+SSH key, no `sadmin` — a known provider limitation, not an oversight specific to this host.
- Created `sadmin` (`useradd -m -s /bin/bash`, `passwd -l` to keep it key-only) and granted full passwordless sudo via `/etc/sudoers.d/sadmin` (`NOPASSWD:ALL`) — necessary because the locked password would otherwise make any interactive `sudo` prompt unresolvable.
- Validated the new sudoers file with `visudo -c` before disabling root SSH — deliberately, since a syntax error discovered only after `PermitRootLogin no` takes effect would leave the host with no way in.
- Set `PermitRootLogin no` and restarted `sshd`. Verified: `sadmin` + `sudo whoami` returns `root` without a password prompt; a direct `ssh root@10.0.20.96` now prompts for a (non-existent) password, confirming the lockdown took effect.
- Explicitly decided **not** to roll this hardening out fleet-wide immediately — flagged the real risk that `bk1`'s Restic pull authenticates against every Linux host as `root` over SSH, so a blind sweep could break backups across 8 VMs at once. Left it as the standard for new Terraform builds and a deliberate future audit task (a natural first Ansible/AWX playbook).

### Phase 6 — Monitoring & backup agents

- Corrected the initial task list: `qemu-guest-agent` doesn't apply — that's QEMU/KVM VM-specific, and `vault1` is an LXC sharing the host kernel directly (confirmed by checking that no other LXC in the fleet has it installed).
- **Zabbix Agent 2**: installed from the official Zabbix repo (matching the fleet's version, 7.0.29). First attempt failed on plain permission errors (`sadmin` isn't `root`, needed `sudo` on every step). Configured `Server`/`ServerActive=10.0.20.60`, `Hostname=vault1`; confirmed active.
- **Wazuh Agent**: installed via the official repo with `WAZUH_MANAGER='10.0.20.60'` pre-set at install time to avoid a manual `ossec.conf` edit; confirmed active (4.14.7, matching `ora1`).
- **GLPI Agent**: first download attempt 404'd because the `linux-installer.pl` script isn't hosted at a fixed `master`-branch URL — it ships as a versioned release asset. Located and used the correct URL for version 1.18 (matching the rest of the fleet) instead of guessing at `master`. Installed and confirmed inventory reached `glpi1`; separately fixed a missed `--tag=vault1` (added via `sed` after confirming the exact line with `grep`) and left the harmless `usb.ids not found` warning unresolved by design (not worth the extra package for a footprint-minimal LXC with no USB to inventory).
- Addressed a direct question about why Perl was needed for GLPI Agent: it's a hard requirement of the agent itself (written in Perl), not a side effect of the chosen install method — and unlike the earlier Rocky/`ora1` case (where installing Perl pulled in a large dependency tree), Debian ships a minimal Perl by default for its own tooling, so no extra footprint was added here.

### Phase 7 — Restic backup (initial manual setup)

- Generated a dedicated, passphrase-less SSH keypair for root on `vault1` (`id_ed25519_backup`) — separate from any interactive-login key — and installed the public half in `sadmin`'s `authorized_keys` on `bk1`, following the same `sftp:sadmin@bk1:/mnt/backups/repos/<hostname>` pattern as every other host.
- First connection attempt fell back to password auth (prompted twice) because SSH only auto-tries default key paths (`id_rsa`, `id_ed25519`), not the custom-named key — fixed with an explicit `/root/.ssh/config` entry (`IdentityFile`, `IdentitiesOnly yes`) for the `bk1` host alias.
- Installed Restic, set a unique (not reused) repo password in `/etc/restic_password`, and initialized the remote repo on `bk1` via `sftp`.
- Recognized upfront that the Raft snapshot step needs an authenticated Vault token, and that the root token must never live in a script on disk — created a narrow policy (`sys/storage/raft/snapshot`, read-only) and a dedicated `vault1-backup` AppRole (`token_ttl=15m`, `token_max_ttl=30m`) before writing the backup script.
- Hit and resolved two `sudo`/environment issues in sequence: `sudo -E` preserves the *calling* user's environment (so it kept resolving `sadmin`'s `HOME`/token path instead of root's), and once fixed with `sudo -i`, discovered the `HOME`-dependent `.vault-token` path had been the actual cause of the earlier 403s (not a permissions problem).
- Wrote and manually ran `/root/backup-vault1.sh` (AppRole login → Raft snapshot → explicit `vault token revoke -self` → `restic backup` of the snapshot plus `/etc/vault.d` → `restic forget` with the fleet-standard weekly/monthly retention). Confirmed a clean run before adding the crontab entry (3 AM daily, matching the rest of the Linux fleet at the time).

### Phase 8 — Retrofit into the Ansible baseline role

Raised directly by Santiago after finishing an unrelated project: `vault1`'s backup lived outside Ansible's fleet-wide `baseline` role, unlike every other of the 16 managed hosts. Retrofit plan and execution:

- Confirmed `vault1` already appears cleanly in the dynamic Proxmox inventory (`proxmox_all_lxc` group) and responds to `ansible ... -m ping`, with no conflict from the Terraform-applied `security`/`terraform` tags.
- Inspected `host_vars/db1.yml`, `host_vars/mon1.yml`, and `host_vars/lx1.yml` as templates before writing anything for `vault1` — specifically to get the exact variable names (`restic_pre_backup_script`, `restic_pre_backup_cmd`, `restic_pre_backup_desc`) right the first time, rather than guessing and having the role silently ignore a misnamed variable (an explicitly named recurrence of the near-miss already hit with `glpi1`'s Restic password).
- Confirmed the *existing* Restic repo/password had to be reused, not regenerated — fetched the live value from `vault1` and encrypted it with `ansible-vault encrypt_string` as `vault_restic_password_vault1`, kept isolated in `host_vars/vault1.yml` rather than touching the shared `group_vars/all/vars.yml`.
- Confirmed the role's default `restic_backup_paths` (`/etc`, `/home`, `/opt`, `/var/log`) already covers `/etc/vault.d` and `/opt/backup_dumps` with no override needed.
- Decided to move to **weekly** cadence (matching the role's hardcoded schedule) rather than special-case a daily override in the role for this one host.
- Wrote a trimmed `backup_vault1.sh` (AppRole login → Raft snapshot → token revoke only — the role's own `restic backup`/`forget` tasks handle the rest) in `roles/baseline/files/`, reusing the existing AppRole credentials and SSH key rather than recreating them.
- Debugged an `ansible-vault encrypt_string` failure caused by running the command from `playbooks/` instead of the repo root (where `.vault_pass` and `ansible.cfg` actually live), then a second failure from passing `--vault-password-file` redundantly alongside the config file's own setting.
- Debugged an `ansible vault1 -m debug ...` ad-hoc test that returned `VARIABLE IS NOT DEFINED!` — not a real problem with the file, but a real difference in how Ansible resolves `host_vars/`: ad-hoc commands only look next to the inventory file (repo root), while `ansible-playbook` (running from `playbooks/`) resolves `host_vars/` relative to the playbook — so the ad-hoc test method itself was invalid for this repo's layout, not the file.
- Ran `ansible-playbook site.yml --limit vault1 --check --diff` and reviewed the full diff line by line before applying. Confirmed as safe: agents already installed (no reinstall), the Restic password diff was cosmetic (a trailing newline only), the deployed backup script matched what was already on disk, and GLPI Agent's unconditional re-download wasn't destructive.
- Caught a real problem in that same diff before applying: the role's cron task only *adds* its weekly entry, it doesn't remove the pre-existing daily manual one — applying as-is would have left two cron jobs writing to the same Restic repo concurrently, risking a lock error or repo corruption. Removed the old crontab entry manually first, re-ran `--check --diff` to confirm a clean diff, then applied for real.
- The real apply failed partway through on a Wazuh APT conflict (`Conflicting values set for option Signed-By`) — two `sources.list.d` entries for the same repo, one from the manual setup (with `signed-by=`) and one the role added (without it), because the role's `apt_repository` task compares the literal repo string and never recognized the manual entry as "already present." Root-caused as specific to `vault1` (the only host where Wazuh had been configured by hand *before* Ansible ever touched it) rather than a bug worth fixing in the shared role, since it had already run cleanly on 15 other hosts. Resolved by removing the manually-created `wazuh.list` and letting the role recreate its own version from scratch.
- Re-ran the full playbook against `vault1` to completion (`failed=0`), then verified: the existing Restic repo/snapshot (`367f4215`) was untouched, and the new weekly cron entry was the only one present.
- A follow-up manual backup run (to validate the new role-managed script end-to-end) failed silently in a way that only showed up in the log: **Vault was sealed** (`503 Vault is sealed`). Root-caused to the lack of auto-unseal — any restart of the LXC or the Vault process reseals it, and it stays sealed until 3 of 5 Shamir keys are supplied by hand. Unsealed manually, then noticed and separately investigated an unexpected `HA Mode: standby` with no active node right after unseal — confirmed transient (Raft elects an active node within seconds) rather than a deeper storage problem, before re-running the backup, which then completed cleanly (`EXIT_CODE=0`, new snapshot `2770c416`).
- Closed the "silent backup failure if Vault reseals" gap with a Zabbix `UserParameter` (`vault.sealed`, returning `0`/sealed-false, `1`/sealed-true, or `2`/unreachable, via `curl` against `/v1/sys/seal-status`) and a High-severity trigger (`last(/vault1/vault.sealed)<>0`) configured through the Zabbix frontend, verified showing live data before considering the project closed.

## Problems Solved

- `lxc.cap.keep` for `IPC_LOCK` broke the container's boot entirely, because the directive is exclusive rather than additive — abandoned in favor of a justified `disable_mlock = true`, backed by the fact that the LXC has `swap: 0`.
- Vault package install failed twice in sequence from one root cause: a stale package index in the LXC template caused 404s on `gnupg`/`curl`, which meant the GPG keyring was never created, which then caused `NO_PUBKEY` on `apt update` — resolved once the index itself was refreshed.
- Vault's TLS listener failed to start because `vault.hcl` referenced `vault1.crt` while the actual file the CA had produced was named `vault1.cer` — a naming mismatch, not a certificate defect.
- `vault operator init` failed with a TLS trust error because the OS trust store on `vault1` didn't yet include `pymesis-DC01-CA` — fixed by importing the CA cert with `update-ca-certificates`.
- The intermediate CA certificate was accidentally double-Base64-encoded by re-running `certutil -encode` on output that was already PEM from `certreq -submit` — caught by inspecting the decoded content and using the original `.cer` file instead.
- `pki_int/intermediate/set-signed` failed because `VAULT_ADDR` wasn't exported in a fresh SSH session — a certificate issued for `vault1.pymesis.lab` doesn't validate against the CLI's default `127.0.0.1` target.
- GLPI Agent's installer URL 404'd because the `linux-installer.pl` script isn't hosted at a fixed path in the repo — it's a versioned release asset, requiring the exact release-tagged URL rather than a guessed `master`-branch path.
- Two separate `sudo`/environment bugs blocked the AppRole/backup-policy setup: `sudo -E` preserved `sadmin`'s environment (wrong `HOME`, wrong token path) instead of root's, requiring a real `sudo -i` session instead.
- SSH to `bk1` silently fell back to password auth because the custom-named backup key (`id_ed25519_backup`) isn't one of SSH's auto-tried default paths — fixed with an explicit per-host `~/.ssh/config` entry.
- An `ansible-vault encrypt_string` attempt failed from the wrong working directory (`playbooks/` instead of the repo root where `.vault_pass` lives), then a second attempt failed from passing a redundant `--vault-password-file` flag alongside the config already set in `ansible.cfg`.
- An `ansible ... -m debug` ad-hoc smoke test falsely reported a variable as undefined — not a real bug, but a mismatch between how ad-hoc commands and `ansible-playbook` resolve `host_vars/` relative to different base directories in this repo's layout.
- Applying the Ansible role as-is would have left two concurrent cron jobs writing to the same Restic repo (the role only adds its entry, never removes a pre-existing manual one) — caught in the `--check --diff` review and fixed by removing the old crontab line first.
- The real `ansible-playbook` apply broke on a Wazuh APT repository conflict, because the manually-created `sources.list.d` entry (with `signed-by=`) and the role's own entry (without it) were both present and disagreed on signing — resolved by removing the manual file and letting the role own it fully, rather than patching a role that worked correctly on 15 other hosts.
- A post-migration verification run of the new Ansible-managed backup script failed silently because Vault had resealed itself after some prior restart — root-caused to the lack of auto-unseal (an accepted trade-off for this project) rather than a defect in the backup script or the AppRole.

## Final Result

- **Provisioning**: `vault1` (LXC 120, `10.0.20.96`, VLAN20) declared and managed in `pymesis-infra` Terraform.
- **Vault core**: Raft-integrated storage, TLS via `pymesis-DC01-CA`, Shamir seal (5 shares / threshold 3), `disable_mlock` documented and justified by the container's lack of swap.
- **Secrets engines**: KV v2 at `kv/`; `pki_int` as a real intermediate CA under `pymesis-DC01-CA` (imported issuer chain, AIA/CRL configured and verified), with a `pymesis-lab` role issuing 30-day-max dynamic certs.
- **Auth**: two scoped AppRoles — one for PKI cert issuance, one dedicated to the backup script — each with a narrow policy and no dependency on the root token.
- **Access hardening**: `sadmin` with passwordless sudo, `PermitRootLogin no`, verified end-to-end; documented as the standard for future Terraform-provisioned hosts, not yet retrofitted fleet-wide.
- **Monitoring/backup, now fully Ansible-managed**: Zabbix Agent 2, Wazuh Agent, and GLPI Agent all reporting; Restic backing up the Raft snapshot plus `/etc/vault.d` to `bk1` on the fleet-standard weekly cadence, via the same `baseline` role and mechanism used by the other 15 managed hosts — no cron drift or manual scripts left in place.
- **Operational safety net**: a Zabbix `vault.sealed` item and High-severity trigger, so a future reseal (LXC restart, service crash) surfaces as an alert instead of a silently-failing weekly backup.

## Pending

- Fleet-wide retrofit of the `sadmin` + root-SSH-lockdown standard is deliberately deferred — flagged as a future Ansible/AWX playbook, contingent on first reviewing how `bk1`'s Restic pull authenticates against each host's root account, to avoid breaking backups.
- No auto-unseal mechanism — accepted trade-off to avoid introducing an external KMS dependency for a single-node homelab; mitigated (not eliminated) by the new Zabbix `vault.sealed` alert.
- Ansible/AWX itself remains a separate, postponed mini-project — intentionally deferred until either all other planned projects are done or a second Proxmox node exists.

## Cross-References

- Project 16 — Ansible (lx1), whose `baseline` role `vault1` was ultimately retrofitted into.
- Project 18 — Ansible Vault Secrets Audit & Migration, the fleet-wide secrets-hygiene work this project's AppRole/Vault core complements.
- Project 5 / 5.1 — Backups, Restic (bk1), the destination for `vault1`'s Raft snapshots.
- Project 17 — Terraform/IaC (lx1), the repo `vault1.tf` was added to.
- Project 10 — GLPI (glpi1), the inventory server `vault1`'s GLPI Agent reports to.
- Project 9 / 9.1 — Monitoring stack, Zabbix/Wazuh (mon1), the server side of `vault1`'s agents.
