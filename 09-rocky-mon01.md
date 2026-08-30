---
title: 09-rocky-mon01
description: rocky
published: 1
date: 2026-08-30T07:31:40.581Z
tags: 
editor: markdown
dateCreated: 2026-08-28T10:29:30.130Z
---

# Project 9 — Rocky Linux 9.4 Installation (mon1)

**Previous:** [Project 8 — Ubuntu 24.04 Installation (odoo1 & db1)](08-ubuntu-odoo1-db1.md)
**Next:** [Project 10 — GLPI Installation (glpi1)](10-glpi-glpi1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Deploy the pymesis.lab monitoring and security stack on a single VM, **MON01**, as defined in the blueprint: Zabbix (infrastructure monitoring), Grafana (visualization), and Wazuh (SIEM/XDR), all colocated on Rocky Linux 9.4 — then roll out agents to the entire existing fleet, add HTTPS and email alerting, and integrate Grafana with both data sources.

## Context

MON01 is the observability hub for the whole homelab, built after the Windows fleet, LX1, BACKUP01, and the Odoo/PostgreSQL pair already existed — so this project's second half is largely about connecting MON01 to VMs built in earlier projects (installing agents everywhere) rather than building something standalone. It also became the second VM (after ODOO01) to receive HTTPS via the lab's internal CA. A short follow-up incident in a separate session (documented here as **9.1**) revisited MON01 months later when Wazuh login broke again.

## Decisions made and why

- **Rocky Linux 9.4 minimal**, not the newer 9.5 available at the time — perfectly valid for a monitoring server and consistent with when the project started; noted as an easy substitution if a newer ISO were preferred.
- **All three tools (Zabbix, Grafana, Wazuh) colocated on one VM (MON01) rather than split across separate VMs** — explicitly discussed as a best-practice question. For a homelab of this size (under 15 VMs, single administrator), the trade-offs of splitting (used in enterprise environments with separate teams or thousands of agents) don't apply; keeping everything on one VM with Grafana talking to Zabbix over `localhost` was judged the right choice, accepting the one real cost (Wazuh is RAM-hungry) as manageable.
- **Build order: Zabbix → Grafana → Wazuh** — reasoned explicitly: Zabbix collects the data first, Grafana visualizes what Zabbix has, and Wazuh (the heaviest, most complex piece) comes last.
- **MON01 RAM increased from 8 GB to 12 GB after hitting ~90% utilization**, rather than trimming Wazuh/OpenSearch's JVM heap. Investigated the option of capping the indexer's heap at 2 GB, but decided against optimizing prematurely — 12 GB gave comfortable headroom (recall the physical node has 64 GB total) and avoided introducing a variable that could destabilize an already-working stack.
- **Hostname kept as `mon1` rather than being changed to `mon01.pymesis.lab`** — an early suggestion to align it with a stricter FQDN convention was explicitly declined; `mon1` was confirmed correct and consistent with the naming already used for the rest of the fleet (bk1, lx1, odoo1, db1).
- **Zabbix HTTPS placed on port 8443 instead of 443** — 443 was already claimed by the Wazuh dashboard on the same VM; rather than trying to run both services behind one port (e.g., with SNI-based routing), the simpler and more maintainable choice was a dedicated port for each service.
- **Wazuh reinstalled cleanly from scratch (`--uninstall` + fresh install) rather than continuing to patch credential mismatches by hand** — after several rounds of manually resetting `wazuh-wui`/indexer passwords that kept failing to authenticate against each other, a clean reinstall was judged faster and more reliable than continuing to chase drifted credentials across multiple components (Filebeat, the indexer, the dashboard, and the API).
- **No Wazuh agent installed on MON01 itself** — not a workaround but the correct design: the `wazuh-agent` and `wazuh-manager` packages conflict by design (the manager already self-monitors), so MON01 appears in Wazuh as a self-monitored manager node rather than as an agent.
- **Only one Grafana dashboard kept for Wazuh (ID 22382, "WAZUH SIEM XDR") instead of also installing 22448/22453** — those two require the separate Elasticsearch datasource plugin (functionally similar to OpenSearch but a different Grafana data source type), which was judged not worth adding just to get two more panels when 22382 already gave adequate visibility.
- **Zabbix email alerts sent through Microsoft 365 SMTP using an App Password, not the account's normal password** — required once Microsoft blocked the plain SMTP AUTH login due to modern authentication being active on the tenant; using a dedicated app password (rather than disabling MFA or modern auth tenant-wide) kept the account's security posture intact while unblocking Zabbix specifically.
- **FW01 (OPNsense) added to Wazuh via its native plugin rather than as a generic syslog/agent target** — the official OPNsense plugin gives firewall rule hits, Suricata IDS/IPS events, and VPN logs directly in the Wazuh dashboard, which a generic forwarding setup wouldn't provide as cleanly.

## Step by step

### 1. Rocky Linux 9.4 install and initial access
- Installed Rocky Linux 9.4 minimal per the interactive guide (network adapter typically `eth0` under Proxmox q35/VirtIO, verified with `ip link show` rather than assumed).
- Fixed an initial SSH access failure: the session was dropping immediately after the password prompt. Diagnosed via the Proxmox noVNC console — the `sadmin` user existed correctly with `/bin/bash` and `wheel` group membership; the actual cause was simply a mistyped password, confirmed once SSH worked cleanly from within the console session itself.
- Declined a suggestion to rename the host to `mon01.pymesis.lab`, keeping `mon1` as the correct, already-agreed convention.

### 2. Install and configure Zabbix 7.0 Server
- Hit a series of repository/URL issues while adding the official Zabbix repo, worked through in sequence:
  - The Rocky-specific repo path didn't exist; switched to the binary-compatible `rhel/9` path instead of `rocky/9`.
  - A pasted URL had a typo (`e19` instead of `el9`).
  - The exact versioned filename (`zabbix-release-7.0-4.el9.noarch.rpm`) returned 404; listed the actual directory contents and used the real current filename, `zabbix-release-latest.el9.noarch.rpm`.
  - `rpm -Uvh` intermittently failed with "transfer failed" while `curl` succeeded — traced to IPv6 being attempted by `wget`/`rpm` where `curl` used IPv4; forced IPv4 explicitly (`-4`) for all subsequent downloads on this VM, a pattern that recurred throughout the project.
- Installed MariaDB, created the Zabbix database and a database user with its own password (kept intentionally distinct from MariaDB's root password), and configured `zabbix_server.conf` with `DBPassword` (uncommented — a commonly missed step).
- Completed the web-based setup wizard from a browser (not from the MON01 console) and confirmed the dashboard loaded at `http://10.0.20.60/zabbix`.

### 3. Deploy Zabbix agents across the existing fleet
- **Linux (apt-based: LINUX01, BACKUP01 on Debian 13, ODOO01, ODOO-DB01 on Ubuntu 24.04):** added the Zabbix repo via the correct per-OS `.deb` package (`ubuntu22.04` for LINUX01, `ubuntu24.04` for the Odoo pair, `debian13` for BACKUP01), installed `zabbix-agent`, and edited `zabbix_agentd.conf` (`Server`, `ServerActive` = 10.0.20.60; `Hostname` = each VM's name).
- **Windows (DC01, DC02, FS01, APP01):** installed the official MSI, entering the Zabbix server IP, listen port 10050, and each VM's hostname in the wizard; opened the inbound firewall rule for port 10050 via `New-NetFirewallRule`.
- Registered each VM as a host in the Zabbix frontend (`Linux by Zabbix agent` / `Windows by Zabbix agent` templates, grouped under `Linux servers` / `Windows servers`).
- **Diagnosed hosts staying grey (not reporting) even with agents installed and running:** `ufw` was inactive on all Linux VMs (not the cause); `zabbix_get` from MON01 confirmed the agents themselves were reachable and responding. The actual root cause, found last, was that the monitoring template name had been typed manually into the host form instead of selected from the dropdown — once the real template was selected, hosts went green within the expected 1–2 minutes.

### 4. Install and configure Grafana on MON01
- Fixed a typo in the custom Grafana repo file (`gfg.key` instead of `gpg.key`) that was silently breaking GPG verification during install.
- Enabled and started `grafana-server`, opened TCP 3000 in `firewalld`, and completed first login (default `admin`/`admin`, changed immediately).
- Installed the official Zabbix plugin for Grafana and connected it as a datasource (`http://localhost/zabbix/api_jsonrpc.php`), confirming a green "Zabbix API version" response.
- Imported community dashboards for a working baseline: the initially suggested ID (10051) didn't load; three alternatives (12712, 11098, 7362) were tried and all worked, and were organized into a dedicated `pymesis.lab` folder in Grafana for future dashboards to join.

### 5. Install Wazuh 4.11 (single-node: indexer + server + dashboard)
- Downloaded the official `wazuh-install.sh` and `config.yml` (again needing `-4` to force IPv4 after an initial silent download failure).
- Edited `config.yml`'s `nodes` section to point `indexer`, `server`, and `dashboard` at MON01 (10.0.20.60) with node names `node-1` / `wazuh-1` / `dashboard`.
- Hit a certificate-name mismatch (`node1` vs `node-1` — the installer requires an exact match between the config file and the generated certificate names); corrected the config file, regenerated certificates, and re-ran.
- Ran the installer phases in sequence: `--generate-config-files`, `--wazuh-indexer node-1`, `--start-cluster`, `--wazuh-server wazuh-1`, `--wazuh-dashboard dashboard`, opening the relevant firewall ports as each phase's warnings called them out (9200/9300 for the indexer, 1514/1515/1516/55000 for the server, 443 for the dashboard).
- Retrieved the auto-generated `admin` credentials shown at the end of installation and accessed `https://10.0.20.60` past the expected self-signed certificate warning.

### 6. Deploy Wazuh agents across the fleet
- Used the dashboard's **Deploy new agent** wizard (Server management → Endpoints summary) for each VM, which generates the correct install command per OS.
- Deployed to LINUX01, BACKUP01, ODOO01, ODOO-DB01 (Linux/DEB) and DC01, DC02, FS01, APP01 (Windows).
- Fixed a missing `lsb-release` dependency that blocked agent configuration on BACKUP01.
- Fixed a Wazuh agent on BACKUP01 left with a literal, unreplaced `<address>MANAGER_IP</address>` placeholder in `ossec.conf` — corrected manually to `10.0.20.60` and restarted the agent.
- Confirmed all agents appeared active in the dashboard.

### 7. RAM sizing incident on MON01
- Noticed MON01's RAM usage sitting around 90% at 8 GB; increased the VM to 12 GB rather than trimming service memory footprints.
- Verified with `free -h` that the new headroom (~7.7 GB available) was comfortable, and separately clarified that Proxmox's summary bar showing high utilization reflected aggressive Linux disk-cache usage (`buff/cache`), not memory pressure — `available`, not the raw usage bar, is the number that matters.
- A later cross-check (documented in the tracker, not repeated live in this session) confirmed the earlier RAM-pressure reading had in fact been a false positive that cleared after a routine reboot, unrelated to the sizing change.

### 8. Zabbix admin lockout and password recovery
- Resolved a Zabbix frontend lockout by clearing `attempt_failed`/`attempt_clock` directly in the `zabbix` MariaDB database for the `Admin` user, and simultaneously setting a new password.
- Discovered mid-troubleshooting that **Zabbix 7.x switched its password hashing from MD5 to bcrypt** — an MD5-hashed password update had no effect on login; the working fix was writing a known bcrypt hash directly into the `passwd` column and logging in with the corresponding plaintext value, then changing it immediately from the frontend once access was restored.

### 9. HTTPS for the Zabbix frontend using the lab's CA
- Generated the certificate request on **DC01** this time via the native Windows `certreq`/INF-file method (rather than OpenSSL, the approach used for Odoo/APP01), after working through a couple of PowerShell here-string escaping issues that corrupted the INF file on the first attempts.
- Fixed an invalid SAN syntax in the first INF attempt (`[Extensions]` block with `dns=`/`ip=` continuation lines wasn't accepted by `certreq`); switched to the correct `[RequestAttributes]` `SAN="dns=...&dns=...&ipaddress=..."` format.
- Issued the certificate with `certreq -submit -attrib "CertificateTemplate:WebServer"`.
- Hit an extra step not needed in the OpenSSL-based flow used elsewhere: the issued `.cer` had to be explicitly accepted into the local machine certificate store on DC01 (`certreq -accept`) before it could be exported as a `.pfx` with its private key — the first export attempt failed because the cert wasn't yet bound to a private key in the store.
- Transferred the `.pfx` to MON01 via `scp`, extracted the private key with `openssl pkcs12 -nocerts -nodes`, and placed key/cert under `/etc/pki/tls/private/` and `/etc/pki/tls/certs/`.
- Installed `mod_ssl` and added a VirtualHost for Zabbix in Apache — first attempt on port 443 conflicted with the Wazuh dashboard already bound there; resolved by moving Zabbix HTTPS to **port 8443** instead (`Listen 8443` + `<VirtualHost *:8443>`).
- Hit and fixed two more Apache issues along the way: a leftover default `ssl.conf` (with its own `Listen 443` and default vhost) conflicting with the new configuration — disabled by renaming it; and a `sed`-inserted `Listen 8443` directive that landed on the same line as the `VirtualHost` tag instead of its own line — fixed manually.
- Verified `https://10.0.20.60:8443/zabbix` loads (expected red padlock, since the lab's internal CA isn't trusted by default in a browser that hasn't imported it — accepted as a known, optional cosmetic follow-up) while the plain `http://10.0.20.60/zabbix` access continued to work as well.

### 10. Zabbix email alerting via Microsoft 365
- Configured the Email media type in Zabbix (`smtp.office365.com:587`, STARTTLS, `soporte@pymesis.com.ar`).
- Hit an authentication failure ("login denied") caused by Microsoft 365 blocking basic SMTP auth under modern authentication; resolved by generating a dedicated **App Password** for Zabbix (the tenant already had MFA configured across three registered devices) and using that in place of the account's normal password.
- Added the target address as an Admin user media entry (all severities, always active), confirmed the trigger action "Report problems to Zabbix administrators" was enabled, and verified a real test email arrived.

### 11. Integrate Grafana with Wazuh/OpenSearch as a second datasource
- Added an **OpenSearch** datasource in Grafana pointing at `https://10.0.20.60:9200` (TLS verification skipped, basic auth with the Wazuh indexer's `admin` credentials, index pattern `wazuh-alerts-*`, time field `@timestamp`).
- Imported a Wazuh-specific community dashboard (ID **22382**, "WAZUH SIEM XDR") that works with the OpenSearch datasource type; two other candidate dashboards (22448, 22453) required the separate Elasticsearch plugin/datasource type and were deliberately not pursued (see decisions above).
- **Fixed a regression this caused in the existing Zabbix→Grafana integration:** after the Zabbix HTTPS/port-8443 restructuring and a subsequent Admin password reset, Grafana's Zabbix datasource stopped authenticating — traced to (a) the `/zabbix` alias having been temporarily missing from the plain-HTTP Apache vhost after the 8443 work (re-added), and (b) the datasource still holding the pre-reset Zabbix Admin password (updated to match).
- Fixed the imported Zabbix dashboard showing no data by selecting the correct Host/Group variables at the top of the dashboard (`mon1` / `Zabbix servers`) — the dashboard requires an explicit selection rather than defaulting to "all."

### 12. Wazuh dashboard outage caused by an in-GUI HTTPS toggle
- Wazuh's dashboard went fully unreachable ("server is not ready yet", then `ECONNREFUSED` to the indexer in the logs) after toggling an HTTP/HTTPS setting from within Wazuh's own settings GUI.
- Diagnosed the root cause in two layers: first, `opensearch_dashboards.yml` had `server.ssl.enabled: false` while `opensearch_security.cookie.secure: true` remained set — a self-contradictory pair (secure cookies require SSL) that was corrected back to `server.ssl.enabled: true`. Second, and more fundamentally, the dashboard's own internal `.kibana*`/`.opensearch_dashboards*` indices in OpenSearch had become corrupted/duplicated (visible as a repeating "mapping change" loop in the logs and a stray `.kibana_2` conflict) and were preventing the dashboard from ever finishing initialization.
- Resolved by deleting the corrupted `.kibana*` and `.opensearch_dashboards*` indices directly via the indexer's API (`curl -X DELETE`) and restarting the dashboard — the indices regenerated cleanly on the next start, and the dashboard came back fully functional with agents and events visible again.

### 13. Add FW01 and confirm MON01's own place in Wazuh
- Installed the OPNsense Wazuh plugin on FW01 and pointed it at 10.0.20.60; FW01 registered itself automatically in the agent list.
- Attempted to also add a Wazuh **agent** on MON01 itself, which failed with an RPM dependency conflict — `wazuh-agent` and the already-installed `wazuh-manager` package are mutually exclusive by design. Confirmed this is expected: the manager already self-monitors, so no separate agent is needed on MON01.
- Final Wazuh inventory: **mon1** (manager, self-monitored), **fw1** (via OPNsense plugin), Windows agents **dc1, dc2, fs1, app1**, Linux agents **lx1, bk1, odoo1, db1** (CL1/CL2 excluded, confirmed in a later cross-session correction alongside the fleet-wide Restic/Zabbix/Wazuh status review).

## Problems solved

- **SSH login to MON01 failing immediately after the password prompt:** a simple mistyped password, confirmed by successful login from the Proxmox console and then successful SSH from within that same session.
- **Zabbix repo RPM 404s and transfer failures:** worked through a chain of causes — wrong distro path (`rocky/9` vs `rhel/9`), a typo in a pasted URL (`e19`/`el9`), a stale/incorrect exact filename, and finally an IPv4-vs-IPv6 download issue solved by forcing `-4` on `wget`/`curl` — a fix that recurred for Grafana and Wazuh downloads later in the same project.
- **New Zabbix hosts staying grey despite running, reachable agents:** ultimately a manually-typed (rather than selected) template name in the host-creation form; not a firewall or connectivity issue, both of which were checked and ruled out first (`ufw` inactive, `zabbix_get` responding).
- **Grafana `dnf install` failing on a custom repo:** a GPG key URL typo (`gfg.key`).
- **Suggested Grafana dashboard ID (10051) not loading:** simply didn't exist/wasn't compatible; three alternative official IDs were tried and worked.
- **Wazuh installer failing to find a certificate for its indexer node:** a naming mismatch between `config.yml` (`node1`) and the certificate generation step (`node-1`) — the two must match exactly.
- **Wazuh API stuck "Offline" for an extended troubleshooting arc:** progressed through several distinct causes — an IP lockout from failed login attempts (`ERROR3099`, cleared by restarting the manager and removing the API log/internal databases), then a genuine credential mismatch between the dashboard's configured `wazuh-wui` user/password and the indexer's actual current password. Investigation revealed the underlying cause: the installer had been run multiple times, regenerating internal passwords each time, so credentials recorded earlier (in screenshots, in `wazuh-install-files.tar`) no longer matched what the indexer actually had. Rather than keep chasing individual mismatches across the indexer, dashboard config, and API, the cleanest fix was a full `--uninstall` followed by a single clean reinstall, generating one consistent, correct set of credentials at the end.
- **Zabbix Admin frontend lockout:** cleared `attempt_failed`/`attempt_clock` in MariaDB; a subsequent plain password reset attempt had no effect because **Zabbix 7.x uses bcrypt, not MD5**, for password hashes — resolved by writing a valid bcrypt hash directly and logging in with its known plaintext counterpart.
- **BACKUP01 Zabbix agent configuration failing:** a missing `lsb-release` package dependency; installed and reconfigured.
- **BACKUP01 Wazuh agent refusing to connect:** an unreplaced `MANAGER_IP` placeholder literally left in `ossec.conf`; corrected to the real MON01 IP.
- **PowerShell here-string corruption while building the certificate request INF on DC01:** multi-line here-strings with special characters (`$`, backticks) were mangled on the first attempts; rebuilt more carefully with proper escaping, and separately corrected an invalid SAN block syntax (moved from a malformed `[Extensions]`/`_continue_` block to the correct `[RequestAttributes]` `SAN=` line).
- **Certificate export to PFX failing on DC01 ("certificate not found in store"):** the CA-issued `.cer` had never been accepted back into the local machine certificate store, so it had no private key association yet; fixed with `certreq -accept` before exporting.
- **Zabbix HTTPS VirtualHost failing to bind to port 443:** the port was already claimed by the Wazuh dashboard on the same VM; moved to 8443. A follow-up attempt on 8443 also silently failed to bind because the required `Listen 8443` directive was missing from the file entirely, then (after a `sed` fix) ended up concatenated onto the same line as the `VirtualHost` tag rather than on its own line — both fixed by direct manual edit.
- **Leftover default `ssl.conf` fighting for port 443:** Rocky's default `mod_ssl` package ships its own `Listen 443` and default VirtualHost; disabled by renaming the file, which let the intended configuration take over the port cleanly.
- **Grafana's Zabbix datasource breaking after the HTTPS/port migration and an Admin password reset:** two independent regressions — the `/zabbix` Apache alias missing from the plain-HTTP vhost after the 8443 restructuring (re-added), and the datasource still holding the pre-reset password (updated).
- **Imported Zabbix Grafana dashboard showing no data:** required manually selecting the Host/Group filter variables (`mon1`/`Zabbix servers`) at the top of the dashboard rather than assuming an "all hosts" default.
- **Wazuh dashboard completely down after an in-product HTTPS toggle:** diagnosed as a two-layer problem — a self-contradictory SSL/cookie configuration in `opensearch_dashboards.yml`, and underneath that, corrupted `.kibana*`/`.opensearch_dashboards*` indices causing an infinite "mapping change" initialization loop. Fixed by correcting the SSL setting and deleting the corrupted indices to let them regenerate cleanly.
- **Attempting to install a Wazuh agent on MON01 itself:** blocked by an intentional RPM package conflict between `wazuh-agent` and `wazuh-manager` — not a bug, and not needed, since the manager already self-monitors.

## Final result

MON01 (10.0.20.60, Rocky Linux 9.4, 12 GB RAM) runs the complete pymesis.lab observability and security stack:

- **Zabbix 7.0**, monitoring all 8 original fleet VMs (4 Linux, 4 Windows) plus itself (as the default self-monitoring "Zabbix server" host, renamed to `mon1`), reachable over HTTP (`/zabbix`) and HTTPS (`:8443/zabbix`, self-signed by the lab's internal CA), with email alerting configured through Microsoft 365 (App Password) to `soporte@pymesis.com.ar`.
- **Grafana**, with two working datasources — Zabbix (three imported general dashboards organized under a `pymesis.lab` folder) and Wazuh/OpenSearch (the SIEM XDR community dashboard, ID 22382).
- **Wazuh 4.11** (indexer + manager + dashboard, single-node), monitoring the same fleet plus FW01 via its native OPNsense plugin, accessible at `https://10.0.20.60` with self-monitoring on the manager itself (no separate agent, by design).
- Agents deployed lab-wide: Zabbix and Wazuh agents on every server VM (explicitly excluding the CL1/CL2 clients, confirmed later).

Pending items — none urgent, mostly deferred to future hardware or low-priority hardening: SSH key-based authentication (ed25519) with password auth disabled has not been configured (low priority on an internal LAN); MON01 has not yet been migrated to its blueprint-assigned Nodo 2 (awaiting the second physical node).

---

## Project 9.1 — Wazuh admin login failure (follow-up incident)

### Objective
Restore Wazuh dashboard access on MON01 after the previously working `admin` credentials stopped authenticating, weeks after Project 9's initial installation.

### Context
This is a short, standalone follow-up session, revisiting MON01 after it had been stable and in production use. It surfaced the same underlying fragility identified during the original installation (Project 9, step "Wazuh API stuck Offline"): Wazuh's internal component passwords (indexer, dashboard, API) can drift out of sync with each other, and this time it recurred spontaneously rather than as a result of repeated installer runs.

### Decisions made and why
- **Regenerated all internal Wazuh passwords with the official `wazuh-passwords-tool.sh --change-all` rather than attempting another manual, targeted credential fix** — the same category of problem had previously taken an extended, multi-step troubleshooting arc to resolve by hand during the original install; using the official bulk-reset tool was the faster, more reliable path this time.
- **Propagated the new password into the dashboard's OpenSearch keystore explicitly, rather than assuming the password-reset tool alone was sufficient** — the tool's own output had already warned that the dashboard needed a separate manual update, since it authenticates to the indexer using its own dedicated `kibanaserver` account, not the `admin` account being logged in with.

### Step by step
1. Confirmed the login was actually failing (not just visually unclear) by asking for the exact browser-side error.
2. Verified the currently-held admin credentials directly against the indexer with `curl -k -u admin:'<password>' https://10.0.20.60:9200` — bypassing the dashboard entirely to isolate whether the problem was credentials or the dashboard layer. This returned `401`, confirming the held password no longer matched the indexer's actual hash.
3. Regenerated all internal user passwords with the official tool: `sudo /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh --change-all`, which produced a new `admin` password (`T5K+xpatR5rJnkUrKH?*i9CXPyva?qA7`) and confirmed Filebeat had already picked up its share of the change automatically.
4. Propagated the new `kibanaserver` password into the dashboard's keystore (the dashboard authenticates to the indexer as this internal user, not as `admin`):
   ```
   sudo /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore remove opensearch.password
   echo '<new kibanaserver password>' | sudo /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore add opensearch.password --stdin
   sudo /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore list
   ```
5. Restarted the three services in the correct order — indexer, then Filebeat, then dashboard:
   ```
   sudo systemctl restart wazuh-indexer
   sudo systemctl restart filebeat
   sudo systemctl restart wazuh-dashboard
   ```
6. Confirmed the dashboard came up healthy and logged in successfully at `https://10.0.20.60` with `admin` / the newly generated password.

### Problems solved
- **Wazuh dashboard login failing with previously-working credentials:** confirmed via direct indexer authentication that the stored password no longer matched the indexer's current hash — a recurrence of the same credential-drift issue first seen during the original Wazuh install in Project 9.
- **New password alone not being enough to restore login:** regenerating the `admin` password with `--change-all` was necessary but not sufficient — the dashboard authenticates to the indexer internally as `kibanaserver`, a separate account whose new password had to be manually written into the dashboard's OpenSearch keystore before a restart, or the dashboard would keep using its old (now-invalid) cached credential.

### Final result
Wazuh dashboard access on MON01 was restored with a freshly regenerated, verified-working `admin` password. A backup of the pre-reset internal user data was left at `/etc/wazuh-indexer/internalusers-backup` on MON01 for reference (safe to delete once no longer needed). The new admin password is intended to be stored in the lab's password manager or in Vault1, to avoid a repeat of this incident from an out-of-date recorded credential.

---

## Cross references

- The HTTPS/PKI issuance pattern (Enterprise Root CA on DC01) originates from **Project 8 (ODOO01)** and was reused here for the Zabbix frontend, this time via the native Windows `certreq`/INF method rather than OpenSSL.
- Zabbix and Wazuh agents were deployed across every VM documented in **Projects 3–8** (the Windows fleet, LX1, BACKUP01, ODOO01/ODOO-DB01); agent installation details for each of those VMs live in their respective project pages, not repeated here.
- FW01's Wazuh integration (OPNsense plugin) is the monitoring-side counterpart to FW01's own build, documented in Project 2.
- Backup scheduling (Restic push to bk1) follows the fleet-wide standard described in Project 5.1; the credential-drift pattern documented here (Wazuh internal passwords) is a useful reference for any future Wazuh maintenance in the lab.

---

**Previous:** Project 8 — Ubuntu 24.04 (ODOO01/DB01) | **Next:** Project 10 — GLPI (GLPI1)
