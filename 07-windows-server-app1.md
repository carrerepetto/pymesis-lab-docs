---
title: 07-windows-server-app1
description: windows-server
published: 1
date: 2026-09-01T19:26:38.525Z
tags: 
editor: markdown
dateCreated: 2026-08-28T10:27:41.754Z
---

# Project 7 — App Server | app1 | VM | App/DB Admin | Windows Server 2022, IIS, SQL Server 2022 Express |

**Previous:** [Project 6 — Client Workstations (cl1, cl2)](06-windows11-cl1-cl2.md)
**Next:** [Project 8 — Odoo ERP & CRM (odoo1 & db1)](08-ubuntu-odoo1-db1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Deploy APP01, the pymesis.lab application server, as defined in the homelab blueprint: a Windows Server 2022 VM running IIS and SQL Server Express, domain-joined to pymesis.lab, and later secured end-to-end with internal PKI (HTTPS) issued by the lab's own Enterprise Root CA.

## Context

APP01 is the "Microsoft App" role in the blueprint: IIS + SQL Server Express, intended to demonstrate Infrastructure/SysAdmin skills (platform administration, AD integration, PKI) rather than software development. It follows the same build pattern already used for DC01, DC02, and FS01 (same Windows Server 2022 ISO, same VirtIO driver process). At the time of this project, DNS host records (A + PTR) for all lab VMs — Windows and Linux — were also created on DC01, and DNS search-domain configuration was fixed on the Linux VMs so short hostnames resolve correctly across the lab.

## Decisions made and why

- **VM specs per blueprint:** 4 vCPU (host type), 8 GB RAM, two disks — 80 GB system (C:) and 200 GB data (D:) — on `local-zfs`, q35 machine type, VirtIO SCSI Single controller, VirtIO NIC on `vmbr1`, QEMU Guest Agent enabled. Static IP 10.0.20.30 on VLAN20 (flat network for now, no VLAN tag).
- **Windows Server 2022 Standard (Desktop Experience):** GUI edition chosen for consistency with the other Windows servers in the lab and easier IIS/SQL administration.
- **Application data on D:, not C:** Both IIS site content and SQL Server data/log/backup directories were placed on the dedicated 200 GB data disk, keeping the OS disk clean and making backup/restore scoping simpler.
- **SQL Server Express in Mixed Mode:** Windows Authentication for domain admins plus a local `sa` account, so both AD-integrated and SQL-native connections can be tested.
- **A real (if minimal) workload instead of a blank install:** Rather than leaving IIS/SQL empty, a small "intranet" site backed by a SQL Server database was built specifically to practice sysadmin-relevant skills — virtual hosts/bindings, NTFS permissions, IIS Windows Authentication, SQL logins tied to AD, and later HTTPS — while deliberately avoiding actual application development (no custom ASP.NET app), which was judged out of scope for this profile.
- **Reused the existing PKI flow from Odoo instead of IIS's native CSR wizard:** IIS Manager can generate its own CSR, but that method doesn't support Subject Alternative Names (SAN). The lab's Enterprise Root CA (on DC01) was already being used successfully for Odoo via OpenSSL CSR generation + `certreq -submit`, so the same flow was reused for IIS to get a proper multi-SAN certificate (FQDN, short name, and IP).
- **Backups, monitoring, and log-naming corrections were centralized in the tracker rather than left as guesses:** during a later review, prior "pending" items (Restic backup, Zabbix/Wazuh agents) turned out to already be implemented lab-wide, so the task list was corrected against reality instead of being carried forward incorrectly.

## Step by step

### 1. Create the VM in Proxmox
- General: next available VM ID, name `APP01`.
- OS: Windows Server 2022 ISO (same one used for DC01/DC02/FS01), Guest OS type Microsoft Windows, version 2022.
- System: Machine `q35`, BIOS `SeaBIOS`, SCSI Controller `VirtIO SCSI Single`, QEMU Agent enabled.
- Disks: Disk 0 — SCSI 0, `local-zfs`, 80 GB, Discard + SSD emulation enabled; Disk 1 — SCSI 1, `local-zfs`, 200 GB, same options.
- CPU: 1 socket, 4 cores, type `host`.
- Memory: 8192 MiB.
- Network: bridge `vmbr1`, model VirtIO, firewall disabled, no VLAN tag (flat network for now).
- Finished the wizard without starting the VM yet.

### 2. Mount VirtIO drivers before first boot
- Added a second CD/DVD drive (IDE 0) pointing to `virtio-win.iso` on `local` storage, then started the VM.

### 3. Install Windows Server 2022
- Language: English; edition: **Windows Server 2022 Standard (Desktop Experience)**; installation type: Custom (install Windows only).
- Because the 80 GB disk wasn't visible (expected with VirtIO), used **Load driver** → browsed to the VirtIO ISO → `amd64\2k22` → loaded the **Red Hat VirtIO SCSI controller** driver → the disk then appeared and installation proceeded (~15–20 minutes).
- Set the local Administrator password following the lab's password scheme.

### 4. Post-installation basics
- Installed the VirtIO Guest Tools (`virtio-win-guest-tools.exe`) from the mounted ISO and rebooted.
- Renamed the computer to `APP01` via `Rename-Computer -NewName "APP01" -Restart`.
- Initialized and formatted the 200 GB data disk as NTFS, labeled `AppData`, mounted as `D:`.
- Configured a static IP (10.0.20.30/24, gateway 10.0.20.1) and DNS (10.0.20.10, 10.0.20.11) via `New-NetIPAddress` / `Set-DnsClientServerAddress`, and verified connectivity to the gateway and DC01.

### 5. Join the domain
- `Add-Computer -DomainName "pymesis.lab" -Credential (Get-Credential) -OUPath "OU=Servers,DC=pymesis,DC=lab" -Restart`, authenticating as `PYMESIS\Administrador`.
- Verified the computer object from DC01 with `Get-ADComputer -Identity APP01`.

### 6. Install IIS
- First attempted via PowerShell (`Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console, Web-Asp-Net45, ...`), then repeated more deliberately via the **Server Manager "Add Roles and Features" wizard** (GUI), selecting: Common HTTP Features (Default Document, Directory Browsing, HTTP Errors, Static Content), HTTP Logging, Static Content Compression, Request Filtering, and under Application Development: **ASP.NET 4.8**, .NET Extensibility 4.8, ISAPI Extensions, ISAPI Filters, plus the IIS Management Console.
- Verified locally (`http://localhost`) and from another VM (`http://10.0.20.30`), confirming the default IIS page loaded; also confirmed the Windows Firewall rule "World Wide Web Services (HTTP Traffic-In)" needed to be enabled for cross-VM access.

### 7. Install SQL Server Express
- Downloaded the SQL Server 2022 Express installer (`SQL2022-SSEI-Expr.exe`) and chose the **Custom** installation path.
- Feature selection: Database Engine Services, SQL Server Replication, Client Tools Connectivity, SQL Client Connectivity SDK.
- Redirected the installation and shared feature directories to `D:\` instead of the default `C:\`.
- Instance configuration: default instance (`MSSQLSERVER`), so the server is reachable simply as `APP01` or `10.0.20.30`.
- Server configuration: default service accounts (`NT AUTHORITY\NETWORK SERVICE` for the Database Engine, `NT AUTHORITY\LOCAL SERVICE` for SQL Browser), default collation `SQL_Latin1_General_CP1_CI_AS`.
- **Database Engine Configuration:** Mixed Mode authentication with an `sa` password following the lab's scheme; added `APP01\Administrador` and `PYMESIS\Domain Admins` as SQL administrators; redirected Data/Log/Backup directories to `D:\SQLData\Data`, `D:\SQLData\Log`, `D:\SQLData\Backup`.
- Installed **SQL Server Management Studio (SSMS)** separately (not bundled with the Express installer) from `https://aka.ms/ssmsfullsetup`.
- Enabled remote connections (server Properties → Connections) and the TCP/IP protocol via **SQL Server Configuration Manager**, fixing the port to 1433 and restarting the SQL Server service.
- Opened an inbound firewall rule for TCP 1433 (`New-NetFirewallRule -DisplayName "SQL Server 1433" ...`).

### 8. Create DNS records for the Linux fleet (parallel task on DC01)
- Created forward A records on DC01 for `fw1`, `bk1`, `lx1`, `mon1`, `odoo1`, `db1` under the `pymesis.lab` zone, with associated PTR records.
- Created the missing IPv4 Reverse Lookup Zone (`20.0.10.in-addr.arpa`) for the ones that hadn't been auto-created, and added the remaining PTR records for all existing hosts (fw1, dc01, dc02, fs01, app01, lx1, bk1, mon1, odoo1, db1).
- Diagnosed and fixed short-hostname resolution on Linux clients: pinging `fs1` worked as `fs1.pymesis.lab` but not as `fs1` alone. Root cause was a missing DNS **search domain**. Fixed per distro:
  - Netplan-based Ubuntu (lx1, odoo1, db1): added `search: [pymesis.lab]` under `nameservers` in `/etc/netplan/00-installer-config.yaml`, then `netplan apply`.
  - Rocky Linux (mon1) managed by NetworkManager: `nmcli connection modify "System ens18" ipv4.dns-search "pymesis.lab"` + `nmcli connection up`.
  - Debian 13 (bk1) using `systemd-resolved`: added `Domains=pymesis.lab` under `[Resolve]` in `/etc/systemd/resolved.conf`, then restarted the service.

### 9. Build a minimal intranet workload on APP01
- Created `D:\AppData\sites\intranet` and a simple branded `index.html` (via a PowerShell here-string).
- Created a new IIS site `intranet`, bound to `10.0.20.30:80` with host header `intranet.pymesis.lab`; stopped/removed the Default Web Site to avoid port conflicts.
- Granted `IIS_IUSRS` read access on the site folder with `icacls`.
- Added the `intranet` A record (and PTR) on DC01, then verified the site loaded from APP01, from other Windows VMs, and via `curl` from a Linux VM (lx1).
- **Enabled Windows Authentication:** installed the `Web-Windows-Auth` feature, then in IIS Manager for the `intranet` site: disabled Anonymous Authentication and enabled Windows Authentication. Verified that anonymous requests return `401 Unauthorized`, that a domain browser session (`PYMESIS\jsmith`) is prompted for credentials and succeeds, and that `curl` from Linux (which doesn't negotiate Kerberos/NTLM natively) correctly gets `401` even with credentials passed — expected behavior, not a defect.
- **Created the SQL Server side:** a database (`IntranetDB`, data/log files placed under `D:\SQLData\`) with a single `Empleados` table (`Id` int identity PK, `Nombre` nvarchar(100), `Departamento` nvarchar(50), `FechaIngreso` date), populated with 3 sample rows, and verified with `SELECT * FROM Empleados`.
- **Created a domain-based SQL login:** `CREATE LOGIN [PYMESIS\jsmith] FROM WINDOWS` at the server level, `CREATE USER [jsmith] FOR LOGIN [PYMESIS\jsmith]` inside `IntranetDB`, and granted `db_datareader` only. Verified with `EXECUTE AS LOGIN = 'PYMESIS\jsmith'` that `SELECT` succeeds and `INSERT` is denied, confirming read-only access.

### 10. Add HTTPS to the intranet site using the lab's internal CA
This reused the exact flow already proven for Odoo (odoo1), rather than IIS's native (non-SAN) CSR wizard:
1. Installed OpenSSL 4.0.1 manually on APP01 (Windows Server 2022 has no `winget` by default), from `https://slproweb.com/products/Win32OpenSSL.html`, and added it to the system `PATH`.
2. Generated an OpenSSL config file (`C:\Certs\intranet.conf`) defining the certificate subject (`C=IT, ST=Lazio, L=Rome, O=Pymesis, OU=IT, CN=intranet.pymesis.lab`) and a Subject Alternative Name list: `intranet.pymesis.lab`, `app1.pymesis.lab`, `app1`, and IP `10.0.20.30`.
3. Generated the private key and CSR: `openssl req -new -newkey rsa:2048 -nodes -keyout intranet.key -out intranet.csr -config intranet.conf`.
4. Copied the CSR to DC01 over an admin share (`\\dc1\C$\Certs`).
5. On DC01, issued the certificate from the CA using `certreq -submit -attrib "CertificateTemplate:WebServer" intranet.csr intranet.crt` (deliberately not via the `certsrv` web portal, since that path doesn't respect SAN extensions).
6. Copied the resulting `.crt` back to APP01.
7. Converted key + certificate into a PFX bundle with `openssl pkcs12 -export`, then imported it into the Windows certificate store (`Cert:\LocalMachine\My`) with `Import-PfxCertificate`.
8. In IIS Manager, added an HTTPS binding on the `intranet` site: `10.0.20.30:443`, host name `intranet.pymesis.lab`, Require SNI enabled, using the imported certificate.
9. Opened an inbound firewall rule for TCP 443 and ran `iisreset`.
10. Verified from a domain browser that `https://intranet.pymesis.lab` loads with a valid padlock and no certificate warning.
11. Configured HTTP → HTTPS redirection using the **URL Rewrite Module** (confirmed in a later review to already be correctly configured this way, which is the more robust approach compared to IIS's native HTTP Redirect feature).
12. Verified that the CA's root certificate had propagated to APP01's trust store via Group Policy (`Get-ChildItem Cert:\LocalMachine\Root`), confirming `CN=pymesis-DC1-CA, DC=pymesis, DC=lab` was present without needing a manual `gpupdate /force`.

## Problems solved

- **Disk not visible during Windows Setup:** normal VirtIO behavior — resolved by loading the Red Hat VirtIO SCSI controller driver from the mounted `virtio-win.iso` (`amd64\2k22` path) before partitioning.
- **IIS not reachable from other VMs despite loading locally:** caused by the Windows Defender Firewall blocking inbound HTTP; resolved by enabling the "World Wide Web Services (HTTP Traffic-In)" rule.
- **Database created with an unintended lowercase name (`intranetDB` instead of `IntranetDB`):** cosmetic only, since SQL Server's default collation is case-insensitive for object names; left as-is by decision (not renamed) rather than run through `ALTER DATABASE ... MODIFY NAME`.
- **SSMS connection error on first connect to the freshly installed instance:** caused by SSMS 20+ defaulting `Encrypt` to `Mandatory` against a self-signed certificate that Windows doesn't trust. Resolved by setting `Encrypt = Optional` and checking `Trust Server Certificate` in the connection dialog — an accepted trade-off for an internal homelab CA-less instance.
- **Short Linux hostnames not resolving (`ping fs1` failed, `ping fs1.pymesis.lab` worked):** missing DNS search-domain configuration on the Linux clients; fixed per-distro as described in step 8.
- **`winget` unavailable on Windows Server 2022:** OpenSSL had to be installed manually via the standalone Win64 installer instead.
- **OpenSSL not recognized in PowerShell right after installation:** the `PATH` update didn't propagate to the already-open session; resolved by reloading the machine `PATH` into the current session (`$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")`) or opening a fresh PowerShell window.
- **Uncertainty about whether HTTP→HTTPS redirection and the "install HTTP Redirect feature" step were still pending:** cross-checked against another chat session covering the same VM and confirmed the redirection had already been implemented correctly via the URL Rewrite Module, so the task tracker was corrected rather than redoing the work with the native (less robust) HTTP Redirect feature.
- **Task tracker drift versus actual lab state:** a later audit corrected three items that had been marked "pending" but were in fact already done lab-wide: the Restic backup (push-based script scheduled at 2:30 AM on Windows servers, 3:00 AM on Linux servers, targeting bk1) and the Zabbix/Wazuh agents (already installed and active on all servers, including APP01).

## Final result

APP01 is a fully domain-joined Windows Server 2022 application server with:
- Static IP 10.0.20.30 on VLAN20, resolvable both forward and reverse via DC01's DNS.
- IIS with ASP.NET 4.8, hosting an `intranet` site backed by `D:\AppData\sites\intranet`.
- Windows Authentication enforced on the intranet site (anonymous access disabled).
- HTTPS on port 443 using a SAN certificate issued by the lab's Enterprise Root CA (`pymesis-DC1-CA`), with automatic HTTP → HTTPS redirection via URL Rewrite, and the CA root trusted via GPO.
- SQL Server Express (Mixed Mode) running from `D:\`, hosting `IntranetDB` with a sample `Empleados` table, and a domain-based read-only login (`PYMESIS\jsmith` → `db_datareader`).
- Push-based Restic backups to bk1 (scheduled 2:30 AM) and Zabbix/Wazuh monitoring agents installed and active, consistent with the rest of the fleet.

No further configuration items remain pending for APP01.

## Cross references

- DNS host records and search-domain fixes performed here also apply to the wider Linux fleet (lx1, bk1, mon1, odoo1, db1) — see Project 2 (OPNsense/DNS foundations) and the Odoo/PostgreSQL project for db1/odoo1-specific detail.
- The HTTPS/PKI flow (OpenSSL CSR with SAN + `certreq -submit` on DC01) was originally established for Odoo (odoo1) and reused here without modification — see the Odoo HTTPS section for the first implementation of this pattern.
- Backup scheduling (Restic push to bk1) and monitoring agents (Zabbix/Wazuh) follow the fleet-wide standard described in Project 5.1.

---

[← **Previous:** Project 6 — Client Workstations (cl1, cl2)](06-windows11-cl1-cl2.md) | [**Next:** Project 8 — Odoo ERP & CRM (odoo1 & db1) →](08-ubuntu-odoo1-db1.md)