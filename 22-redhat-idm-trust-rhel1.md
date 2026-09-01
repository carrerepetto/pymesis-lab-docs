---
title: 22-redhat-idm-trust-rhel1
description: redhat-idm-trust
published: 1
date: 2026-09-01T19:32:15.925Z
tags: 
editor: markdown
dateCreated: 2026-09-01T10:30:47.376Z
---

# Project 22 — Red Hat Tools/Enterprise | rhel1 | VM | Identity (IdM/AD Trust) | RHEL, IdM |

**Previous:** [Project 21 — IBM Db2 (lx1)](21-ibm-db2-lx1.md)
**Next:** Not yet defined

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Bring Red Hat into the lab not as "just another Linux distro" (Rocky is already binary-compatible with RHEL) but for the enterprise tooling Rocky lacks: `subscription-manager`, RHEL System Roles, and — as the project grew — RHEL IdM as a centralized Linux identity layer with a real cross-realm trust to the existing Active Directory domain, letting AD users log into a Linux host with their real domain credentials and no duplicate local account.

## Context

The project started narrowly scoped as a System Roles testbed connected to the existing Ansible project, explicitly to avoid RHEL becoming an isolated distro exercise with no real tie-in to the rest of the lab. It grew substantially once the identity-management angle came up: rather than add a separate `idm1` VM, IdM was installed directly on `rhel1` since IdM/enterprise tooling was the entire reason Red Hat was worth adding in the first place — the System Roles testbed alone could have been done on any distro. The scope was then deliberately expanded to include the AD trust from the start, rather than IdM standalone first, explicitly choosing the more valuable, realistic version of the exercise for the CV over the safer minimal one.

## Decisions Made and Rationale

- **New VM, not `convert2rhel` on an existing Rocky host** — a clean build was judged more consistent with treating this as its own testbed rather than mutating an existing production-adjacent VM.
- **Correlative production numbering (VMID 122, `10.0.20.97`), not sandbox 2xx numbering** — corrected directly: since this host was intended to remain permanent in the lab (not a disposable exercise like `tf-test1`), it belongs in the same 1xx/production numbering as the rest of the fleet, and by extension in the `pymesis-infra` Terraform repo from day one rather than `pymesis-sandbox`, avoiding a later migration.
- **A standing principle stated explicitly at the start of this project**: the intention going forward is to use whatever technology is already available and working in the lab to enrich each new project (e.g., provisioning everything through Terraform now that it exists) — but if that path becomes disproportionately complex, as happened with `ora1`, falling back to a proven simpler alternative (manual ISO install) after a genuine attempt is an acceptable outcome, not a failure to route around.
- **Manual ISO installation, not Kickstart** — matching the already-proven `ora1` pattern; Kickstart was considered but judged excessive setup effort for a single testbed VM.
- **RHEL 9.8 DVD ISO, not the Boot ISO**, for install reliability without a live network dependency during Anaconda.
- **`bios=ovmf`/`machine=q35`, `cpu=host`, `virtio-scsi-single`** — the same known-good VM profile already established (and hard-won) on `ora1`, applied proactively this time rather than rediscovered through trial and error.
- **Registered against the free Red Hat Developer Subscription**, confirmed to have Simple Content Access enabled (making `subscription-manager attach --auto` a no-op) — the only viable path to RHEL entitlements for a homelab, and explicitly called out as a manual, non-automatable checkpoint.
- **`fedora.linux_system_roles` from public Galaxy, not `redhat.rhel_system_roles` from Automation Hub** — the certified Red Hat collection requires an Ansible Automation Platform subscription not covered by the Developer Subscription; the public-Galaxy upstream project it's derived from is functionally equivalent and installable for free.
- **Installed `rhel-system-roles` as an RPM directly on `rhel1` was explicitly rejected as the wrong path**, even though it "works" — it bundles its own standalone `ansible-core` inside the managed node, disconnected from `lx1`'s real control-node repo and inventory, defeating the point of practicing this from the existing Ansible control node.
- **IdM installed with `--no-dns` (no `--setup-dns`)** — a deliberate design constraint to protect the rest of the fleet: `dc1` stays the sole DNS source for the lab; IdM is a Kerberos/LDAP client only, never a DNS replacement, so this project could not become a source of resolution problems for anything else running.
- **`sadmin`'s local account and NOPASSWD sudo were never touched or replaced during IdM enrollment** — IdM/AD-trust authentication is explicitly additive, not a replacement, specifically to eliminate any risk of an SSH/Ansible lockout on this host.
- **`linux.pymesis.lab` as the IdM domain/realm, a separate subdomain from the AD domain (`pymesis.lab`)** rather than sharing the same namespace — following Red Hat's documented pattern for AD-trust setups, avoiding DNS zone ambiguity between the two realms.
- **NetBIOS name `LINUX` for the IdM realm** (the installer's default, accepted deliberately) — matches the `linux.pymesis.lab` domain and avoids future ambiguity with AD's own NetBIOS name (`PYMESIS`) once the trust exists.
- **Directory Manager and admin passwords stored in `vault1`'s KV v2 engine** (`kv/rhel1/idm`) rather than left in a note or terminal history — putting the earlier Vault project to immediate practical use rather than treating it as a standalone exercise.
- **firewalld ports opened via firewalld's predefined service groups** (`freeipa-ldap`, `freeipa-ldaps`, `freeipa-4`, later `samba`/`samba-dc`) **rather than raw port lists** — cleaner and less error-prone than manually enumerating every port IdM/Samba need.
- **Final, explicit standing decision on identity architecture for the whole fleet**, reached collaboratively at the end of the project: `sadmin` stays local on every host as the automation/break-glass account used by Ansible/Terraform/Restic, and is never replaced by a unified domain account — IdM/AD-trust user accounts are strictly an additive layer for human/interactive login and centralized sudo policy, mirroring exactly how AD already coexists with each Windows host's local `Administrator` rather than replacing it. Explicitly rejected: creating a domain-based `sadmin`-equivalent account to phase out the local one everywhere — judged as introducing a single point of failure (an IdM outage would lock out the entire fleet) in exchange for no real benefit.
- **Root keeps a set password (local console/emergency use only) with `PermitRootLogin no` blocking SSH** — reconfirmed as the standing fleet policy during this project's identity-architecture discussion, deliberately choosing not to go further and disable the root account at the console/PAM level too, since that would remove the one true emergency path (physical/Proxmox console access) without a meaningful security benefit.

## Step-by-Step

### Phase 1 — VM provisioning

- Created `rhel1.tf` in `pymesis-infra` (production repo, not sandbox) — VMID 122, `10.0.20.97`, 2 vCPU/4GB RAM/40GB disk, `cpu=host`, `bios=ovmf`+`machine=q35`, `virtio-scsi-single` disk controller (fixing an initial iothread warning the provider raised with the default `virtio-scsi-pci` controller).
- Installed RHEL 9.8 manually from the DVD ISO via Anaconda: hostname `rhel1.pymesis.lab`, static IP `10.0.20.97/24` (gateway `10.0.20.1`, DNS `10.0.20.10`), timezone `Europe/Rome`, `sadmin` as an admin user, automatic partitioning. Also downloaded `virtio-win-1.9.49.iso` for future Windows-VM use via Terraform, unrelated to this Linux build.
- Applied the fleet's standard hardening: `sadmin` with NOPASSWD sudo and SSH key access, `PermitRootLogin no` (service still named `sshd` on RHEL, unlike some other distros' naming quirks).
- Registered the host via `subscription-manager register` against the Red Hat Developer Subscription; confirmed Simple Content Access made `attach --auto` unnecessary. `qemu-guest-agent` came pre-installed with the DVD ISO, only needing `systemctl enable` plus `agent.enabled=true` in the Terraform resource.
- Registered the `10.0.20.97` DNS entry manually on `dc1`.

### Phase 2 — Fleet onboarding via Ansible (and real `baseline` role bugs found)

`rhel1` was the first RedHat-family host provisioned entirely from scratch through the `baseline` role (`mon1`, the only prior Rocky host, had its agents installed manually before the role existed) — this surfaced several real, previously-latent bugs rather than just confirming the role worked:

- The dynamic Proxmox inventory correctly grouped it under `proxmox_all_qemu`/`linux`/`redhat`/`terraform`.
- **Zabbix**: the role's repo RPM URL was hardcoded to Rocky's path — split into separate Rocky vs. RHEL tasks by `ansible_distribution`, since RHEL's official repo path differs (`/zabbix/7.0/rhel/9/...` vs. `/rocky/9/...`).
- **EPEL**: had no RHEL path at all — `epel-release` isn't an installable repo package on registered RHEL the way it is on Rocky. Added a RHEL-specific task pulling the RPM directly from `dl.fedoraproject.org` with `disable_gpg_check: true`, plus a new CodeReady Builder (CRB) enablement step via `community.general.rhsm_repository` (RHEL-only, no equivalent needed on Rocky).
- **Wazuh and GLPI Agent**: their install tasks were hardcoded to `ansible_os_family == "Debian"` only — added RedHat-specific package/repo tasks and removed the Debian-only restriction from the shared config/enrollment/service-active tasks so both families are now genuinely covered, not just Debian with RedHat bolted on incompletely.
- The CA cert was imported via `update-ca-trust` (the RHEL/EL equivalent of Debian's `update-ca-certificates`), root→`bk1` SSH access was set up via `setup_root_bk1_access.yml` (needed `rhel1` added to that playbook's previously-hardcoded host list), and Zabbix Agent 2, Wazuh Agent, GLPI Agent, and Restic were all confirmed installed, configured, and active (`failed=0`).
- Noted, but left as non-blocking cleanup: `roles/baseline/tasks/monitoring.yml` had two leftover duplicate Wazuh tasks still carrying the old Debian-only condition — removed once found.

### Phase 3 — RHEL System Roles setup on the control node

- Confirmed installing `rhel-system-roles` as an RPM directly on `rhel1` technically works but was the wrong approach for this exercise, since it runs its own bundled `ansible-core`, disconnected from `lx1`'s real control-node setup.
- Confirmed `redhat.rhel_system_roles` (the Red Hat-certified collection) isn't installable from public Galaxy at all — it requires an Automation Hub / AAP subscription. Installed the free public-Galaxy equivalent, `fedora.linux_system_roles`, on `lx1` instead — functionally the same roles, since Red Hat's certified version derives from this upstream project.
- As a side effect, installing it upgraded `community.general` to 11.4.9, incidentally resolving a long-standing "does not support Ansible version 2.17.14" warning that had been appearing on every playbook run since well before this project.

### Phase 4 — Validating four RHEL System Roles (each with a real bug found and fixed)

- **timesync** (`rhel-system-roles-timesync.yml`, targeting `rhel1` against `dc1`/`dc2` as NTP servers): found a real fleet issue, not a role bug — `chronyd` on `rhel1` stayed stuck unsynced against both domain controllers because `dc1` (confirmed via `netdom query fsmo` to hold all 5 FSMO roles) had never itself been configured with an external NTP source. Fixed by configuring `dc1`'s Windows Time service with a real external peer list (`w32tm /config /manualpeerlist:...`) and forcing a resync; confirmed both DCs synced afterward.
- **firewall** (`rhel-system-roles-firewall.yml`): the first run simply declared `rhel1`'s existing clean `firewalld` state, surfacing one version-drift issue (this role version uses `runtime: true`, not the `immediate: true` seen in older documentation). Used as an opportunity for a real second objective: found via `nc -zv` that Zabbix Agent 2 was unreachable from outside despite listening locally (`10050/tcp` blocked — the same class of gap already hit on `ora1`), swapped `cockpit`'s zone entry for its literal port, and restricted SSH to only `lx1` (`10.0.20.40`) via a rich rule instead of the generic `ssh` service entry. Hit and fixed a module-semantics bug along the way: `state: absent` only removes an entire zone or a custom service/ipset definition, not a service entry from an existing zone — the correct state for that is `disabled`.
- **network** (`rhel-system-roles-network.yml`) — treated as the highest-risk role of the four, since a misconfiguration here could cut SSH entirely; the Proxmox console was kept open as a mandatory safety net before running it. Declared `rhel1`'s actual NetworkManager profile, and in the process found a real gap in the live config (`dns_search pymesis.lab` was missing from a full `nmcli -f all con show` dump) and added it. Discovered a genuine module limitation: unlike `firewall`'s clean diff, this role's underlying `nmcli` reapply always reports `changed=1` even when every declared value already matches reality — there's no way to get a clean `changed=0` confirmation from it. Applied anyway once every field was manually verified correct; the result was a non-disruptive "connection reapplied" rather than a full interface down/up cycle, with no SSH interruption.
- **logging** (`rhel-system-roles-logging.yml`, forwarding `rhel1`'s journal to `mon1:514/tcp`): hit a version-drift naming issue (this role version calls the output type `forwards`, not `remote` as older documentation uses). Built a plain TCP:514 rsyslog receiver on `mon1` (confirmed RHEL/EL9 family, not Debian as initially assumed), storing logs split by host/program. Two real issues found and fixed: SELinux silently blocked the receiver config because a manual `scp`+`mv` had left it with the wrong context (`user_tmp_t` instead of `syslog_conf_t`) — fixed with `restorecon`, and adopted as a new standing habit (always `restorecon` after manually copying files into `/etc/` on an SELinux-enforcing RHEL/EL host, since the failure mode is silent); and an earlier "no firewalld" assumption about `mon1` turned out to be a false negative from a swallowed error — `mon1` does run `firewalld`, and `514/tcp` had never actually been opened, fixed with `firewall-cmd`. Verified the full pipeline end-to-end with test messages landing correctly on `mon1`, split by host and program.

### Phase 5 — Process/repo hygiene improvements adopted during this project

- Adopted a new standing convention going forward: commit and push to Gitea after any significant Ansible/Terraform change, in the same working session — not deferred to "later."
- Fixed the Ansible repo's git identity (had been auto-detecting as `sadmin@lx1.pymesis.lab`) and removed two stray empty files (`playbooks/{` and `{`) that had accumulated at the repo root.
- Closed a gap where `mon1`'s rsyslog receiver (built manually via SSH during Phase 4) broke the "everything through Ansible/Terraform" convention: wrote `playbooks/mon1-rsyslog-receiver.yml` (deploying the config via `ansible.builtin.copy`, which sidesteps the earlier SELinux mislabeling issue by design, creating `/var/log/remote/`, and opening `514/tcp` via `ansible.posix.firewalld`). `--check --diff` caught real drift left over from the manual setup (the file was owned by `sadmin`/uid 1000 instead of root, and the directory was `0755` instead of the intended `0750`) — applied for real and re-tested the full pipeline successfully, bringing the entire `rhel1`↔`mon1` logging path under version control.
- Did a Terraform repo hygiene pass: `terraform plan` on `rhel1.tf` came back clean ("No changes"), but `git status` surfaced a real backlog — `rhel1.tf` itself untracked, a complete and already-correct `vault1.tf` also untracked, a legitimate `glpi1.tf` modification (the `start_on_boot=false` fix matching the fleet-wide policy), and a stray `terraform.tfstate.<timestamp>.backup` file that `.gitignore`'s `*.tfstate.backup` pattern didn't actually match (needed the literal `terraform.tfstate.*.backup` pattern added instead). All committed and pushed together, leaving both the Ansible and Terraform repos with a clean `git status`.

### Phase 6 — IdM installation on `rhel1`

- Installed IdM server software and ran `ipa-server-install` with `--no-dns` — realm `LINUX.PYMESIS.LAB`, domain `linux.pymesis.lab`, NetBIOS name `LINUX`. Installation completed successfully; Directory Manager and admin passwords stored in `vault1`'s KV v2 engine.
- Opened IdM's required firewall ports via the same `fedora.linux_system_roles.firewall` role already validated in Phase 4, using firewalld's `freeipa-ldap`/`freeipa-ldaps`/`freeipa-4` predefined service groups (the last of which bundles HTTP/HTTPS/Kerberos/kpasswd) rather than raw ports — explicitly confirmed port 53 (bind), which the installer's summary mentions, was not needed since DNS setup had been deliberately skipped. `--check --diff` confirmed a clean, purely additive change; applied for real.
- Verified the full stack end-to-end: `kinit admin` obtained a Kerberos ticket, and `ipa user-find admin` confirmed LDAP responded correctly with the expected admin user details — IdM was fully functional standalone on `rhel1`, with SSH access confirmed intact throughout.
- Committed and pushed the firewall playbook change.

### Phase 7 — AD trust preparation (manual DNS records)

- Since `--no-dns` meant IdM never created its own DNS records, manually loaded the 13 SRV/TXT/URI/A records IPA's installer had generated (left in a system-records file) into `dc1`'s `linux.pymesis.lab` zone via DNS Manager.
- All SRV/TXT/A records loaded successfully. The 4 URI records could not be created at all — this Windows Server DNS Manager version has no URI record type in its GUI, `dnscmd` doesn't support URI as an RRType, and PowerShell's `Add-DnsServerResourceRecord` both lacks a `-Uri` parameter and rejects the generic `-Type 256` workaround. Accepted as non-blocking, since URI records are a newer/optional discovery mechanism that `sssd`/`realmd`/trust setup don't actually depend on (the SRV+TXT records they do rely on were all in place) — verified via `dig` from `rhel1` that Kerberos/LDAP SRV and TXT records, plus the `ipa-ca` A record, all resolved correctly.

### Phase 8 — Establishing the AD trust

- Installed `ipa-server-trust-ad` + `samba-client` and ran `ipa-adtrust-install --netbios-name=LINUX`, which configured Samba/Winbind and added the IPA-side trust objects.
- This required 6 additional `_msdcs` SRV records under `linux.pymesis.lab` (nested under `dc._msdcs` and `Default-First-Site-Name._sites.dc._msdcs`) — the same manual-DNS-loading pattern as Phase 7. Hit a DNS Manager GUI limitation where the "Domain" field in the SRV record wizard can't take nested subdomains directly, requiring the domain-node hierarchy to be created manually first via "New Domain..." before records could be added inside each node.
- Made and caught a naming mistake on the first pass: created the protocol nodes as `tcp`/`udp` instead of the required `_tcp`/`_udp` (missing underscore) — confirmed the discrepancy via `dig` (only the underscored form resolved), deleted the 4 wrong nodes, and recreated them correctly. All 6 `_msdcs` records confirmed resolving via `dig` afterward.
- Opened the Samba/AD-trust firewall ports via the `samba`/`samba-dc` firewalld predefined services (covering the SMB/NetBIOS/Kerberos/LDAP/GC port ranges plus the dynamic RPC range in one clean step, rather than a raw port list) — `--check --diff` clean, applied for real.
- Ran `ipa trust-add --type=ad pymesis.lab --admin Administrator --password`, which initially failed with "Connection refused" — root-caused to `httpd` on `rhel1` having been down for over 13 hours (since a batch of restarts from the earlier firewall/Terraform changes). The specific cause: `mod_ssl`'s passphrase reader (`ipa-httpd-pwdreader`) failed to decrypt `httpd.key` because it looked for the passphrase file under the `ipa-ca.linux.pymesis.lab-443-RSA` vhost name, but only the `rhel1.linux.pymesis.lab-443-RSA`-named file existed on disk — both vhosts actually share the same underlying key/passphrase, just under different certificate SANs. Confirmed the existing passphrase file was correct via `openssl rsa -check`, and fixed by copying it to the missing filename — `httpd` restarted successfully.
- Re-ran `ipa trust-add`, which succeeded: "Trust status: Established and verified," correctly showing the trusting forest, NetBIOS name `PYMESIS`, and matching domain SID — the core trust objective was achieved.

### Phase 9 — Validating real cross-realm login

- Confirmed AD identities resolve correctly on `rhel1` via SSSD: both `administrator@pymesis.lab` and `bwilson@pymesis.lab` returned correct auto-mapped UIDs (in the `1899000000+` range) and correct AD group memberships (Domain Admins, HelpDesk, Domain Users, etc.) via `id`/`getent`.
- Tested a real SSH login as an AD user: `ssh bwilson@pymesis.lab@rhel1` succeeded on the first attempt using `bwilson`'s actual AD password — no HBAC adjustment was needed, since IdM's default HBAC rules already permitted it.
- Found one remaining gap: the user's home directory hadn't been auto-created on first login. Fixed with `authselect enable-feature with-mkhomedir` plus enabling `oddjobd.service` (the informational message `authselect` returned about needing `pam_oddjob_mkhomedir` wasn't an error, just a reminder of the second required step). Re-tested `bwilson`'s login and confirmed the home directory (`/home/pymesis.lab/bwilson`) was created correctly with proper skeleton files and ownership.

### Phase 10 — Closing the identity-architecture question fleet-wide

With the technical trust proven end-to-end, a broader question was raised directly: does it make sense to centralize Linux identity via IdM across the whole fleet, and should that eventually replace the local `sadmin` account? Worked through explicitly, arriving at a standing decision:

- Confirmed the existing `sadmin`/root policy (NOPASSWD sudo + SSH key for `sadmin`; `PermitRootLogin no` for root, which keeps root's password intact for local/console emergency use only, not a full account lockout) is already correct and should not change.
- The recommendation, accepted as final: `sadmin` stays local everywhere as the automation/break-glass account (used by Ansible, Terraform, and Restic) and is never phased out — mirroring exactly how AD already coexists with each Windows host's local `Administrator` account rather than replacing it. IdM/AD-trust domain accounts are strictly an additive layer for human/interactive login and centralized sudo policy (via HBAC/sudo rules in IPA), not a wholesale identity migration.
- The reasoning made explicit: if IdM itself ever has a problem (the `httpd` outage earlier in this same project — 13+ hours down, unnoticed — is the concrete example used), a fleet that depended on domain accounts as its *only* access path would be locked out everywhere at once. Keeping `sadmin` local avoids that single point of failure while still gaining IdM's convenience and audit benefits.
- Explicitly agreed that creating a domain-based `sadmin`-equivalent account to eventually stop using the local one is not worth doing — the local account isn't legacy debt to be retired, it's the deliberate safety net.

## Problems Solved

- `rhel-system-roles` installed as an RPM directly on the managed node technically works but bundles its own isolated `ansible-core`, disconnected from the real control node — corrected before it became the working approach, in favor of `fedora.linux_system_roles` installed properly on `lx1`.
- `redhat.rhel_system_roles` isn't available from public Galaxy at all (it requires an Automation Hub/AAP subscription) — resolved by using the equivalent free upstream collection.
- The `baseline` Ansible role had several latent RedHat-family gaps never previously exercised (Zabbix repo URL hardcoded to Rocky's path, no EPEL/CRB path for RHEL at all, Wazuh/GLPI install tasks restricted to Debian only) — all found and fixed by being the first host to actually provision a RedHat-family host from scratch through the role.
- `chronyd` on `rhel1` never synchronized against either domain controller — traced to `dc1` itself never having an external NTP source configured, a real fleet-wide time-sync gap rather than a `rhel1`-specific problem, fixed at the source.
- A firewall module semantics mistake (`state: absent` used to try to remove a single service from a zone) failed silently in intent — the correct state for that operation is `disabled`, not `absent` (which only removes an entire zone or custom service/ipset definition).
- The `network` System Role's underlying `nmcli` reapply always reports `changed=1` even when nothing actually differs — no clean `changed=0` confirmation is possible with this role version; worked around by manually verifying every field before applying, given this is the highest-blast-radius role of the four.
- The `logging` role uses different terminology (`forwards`) across versions than older documentation (`remote`) — caught by testing rather than trusting stale docs.
- A manually `scp`+`mv`'d rsyslog config on `mon1` silently failed to load because of an incorrect SELinux context (`user_tmp_t` instead of `syslog_conf_t`) — fixed with `restorecon`, and generalized into a standing habit for any future manual file copy into `/etc/` on SELinux-enforcing hosts.
- An earlier "mon1 has no firewalld" assumption was a false negative from a swallowed error in an early check — `mon1` does run firewalld, and the real fix was simply opening the needed port.
- `.gitignore`'s `*.tfstate.backup` pattern didn't actually match Terraform's real backup filename format (`terraform.tfstate.<timestamp>.backup`) — fixed with the correct literal pattern.
- Nested DNS SRV records (`_msdcs`, `_sites`) couldn't be entered directly through Windows DNS Manager's record wizard — worked around by manually building the domain-node hierarchy first, then adding records inside each node.
- A DNS node-naming mistake (`tcp`/`udp` instead of `_tcp`/`_udp`) silently produced non-resolving records — caught via `dig` rather than assumed correct, and corrected.
- `ipa trust-add` failed with "Connection refused" due to `httpd` having been down on `rhel1` for over 13 hours without anyone noticing — root-caused to `mod_ssl`'s passphrase reader looking for a passphrase file under the wrong vhost-based filename (`ipa-ca...` vs. the existing `rhel1...`, both sharing the same actual key/passphrase) — fixed by copying the existing file to the expected name.
- A new AD user's first SSH login didn't create a home directory — fixed by enabling the `with-mkhomedir` `authselect` feature and starting `oddjobd`, the two components actually required together for this to work.

## Final Result

- **VM**: `rhel1` (VMID 122, `10.0.20.97`), RHEL 9.8, registered via the Red Hat Developer Subscription, fully onboarded into the fleet's Ansible `baseline` role (agents, hardening, backup all active) and Terraform-managed from day one in the production repo.
- **`baseline` Ansible role**: made genuinely RedHat-family-aware for the first time (Zabbix repo, EPEL/CRB, Wazuh/GLPI install tasks), fixing latent gaps that would have blocked every future RedHat-family host, not just this one.
- **RHEL System Roles validated with real fleet impact, not just syntax exercises**: `timesync` (fixed a genuine fleet-wide NTP gap on `dc1`), `firewall` (closed a Zabbix reachability gap and tightened SSH access), `network` (declared and corrected the live NetworkManager profile), `logging` (built a working, SELinux-correct, firewalled rsyslog pipeline from `rhel1` to `mon1`).
- **IdM server**: fully functional on `rhel1`, own domain (`linux.pymesis.lab`), coexisting cleanly with `dc1`'s DNS authority and never touching `sadmin`'s access.
- **AD trust**: established and verified between IdM (`linux.pymesis.lab`) and the lab's existing AD (`pymesis.lab`) — AD users resolve correctly via SSSD, and a real AD user (`bwilson`) can SSH into `rhel1` with their actual AD password, home directory auto-created, no duplicate local account.
- **Fleet-wide process/hygiene improvements**: a standing "commit+push same session" convention adopted; the `mon1` rsyslog receiver brought under Ansible management; a `.gitignore` gap and untracked Terraform files cleaned up.
- **Standing identity-architecture decision for the whole fleet**: `sadmin` remains local and permanent everywhere; IdM/AD-trust is additive for human access only, never a replacement — explicitly closing the "should we migrate everything to domain accounts" question with a documented "no."

## Pending

- Progressive enrollment of more Linux hosts into the IdM/AD-trust setup, explicitly starting with `ora1` next since it's a different distro (Rocky) and would validate the cross-distro case raised at the start of the project.
- Wazuh's root cause for not appearing correctly in earlier post-`ora1` monitoring checks was flagged in passing during this project as still under investigation from a prior project, not something this project resolved.
- Full documentation of the `rhel1`/IdM/trust build on WikiJS (this document) and eventual publication on Gitea/public GitHub, as previously planned for every completed project.

## Cross-References

- Project 19 — HashiCorp Vault (vault1), used directly in this project to store the IdM Directory Manager/admin credentials in its KV v2 engine.
- Project 20 — Oracle XE Sandbox (ora1), whose VM-profile fixes (`bios=ovmf`/`machine=q35`, `cpu=host`) and manual-ISO-install pattern were reused here proactively, and which is the next planned candidate for IdM/AD-trust enrollment.
- Project 16 — Ansible (lx1), whose `baseline` role received its first real RedHat-family fixes as a direct result of this project, and whose control node hosts the new `fedora.linux_system_roles` collection.
- Project 17 — Terraform/IaC (lx1), the repo `rhel1.tf` was added to, and where a repo-hygiene pass (untracked files, `.gitignore` fix) was done as part of this project.
- Project 9 / 9.1 — Monitoring stack, Zabbix/Wazuh (mon1), the receiving end of `rhel1`'s new rsyslog forwarding pipeline and destination for its Zabbix/Wazuh agents.
- Project 18 — Ansible Vault Secrets Audit & Migration, whose secrets-hygiene principles (never a bare credential in a script or terminal history) this project extended to the new IdM admin credentials.

---

[← **Previous:** Project 21 — IBM Db2 (lx1)](21-ibm-db2-lx1.md) | **Next:** Not yet defined



