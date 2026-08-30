---
---

---
title: 00-pymesis-lab-index
description: index
published: 1
date: 2026-08-30T12:16:03.905Z
tags: 
editor: markdown
dateCreated: 2026-08-27T16:50:59.053Z
---

# pymesis.lab — Homelab / Mini Datacenter

## Lab Objective

pymesis.lab is a professional-grade homelab built to close skill gaps in areas where prior experience (15+ years in sysadmin, AMS, ERP, and database administration) was weaker: **Kubernetes/K8s, Infrastructure as Code (Terraform/Ansible), and CI/CD**. The stated goal isn't just "having servers running" — it's documenting every technical decision, every problem solved, and the reasoning behind it, so the result serves both as skills evidence for a public GitHub portfolio/CV and as useful study material for junior and senior profiles alike.

## General Architecture

- **Internal domain:** `pymesis.lab` (NetBIOS: `PYMESIS`)
- **Node 1 (`pve1`):** GMKtec K8 Plus, 64GB RAM, 1TB NVMe — Proxmox VE 8.4.1, ZFS RAID0 filesystem. Hosts all the lab's stable 24/7 infrastructure.
- **Node 2:** planned, pending additional hardware purchase (second mini PC, Ugreen DXP4800 NAS, MikroTik CRS310 switch, UniFi U7 Pro AP, APC UPS).
- **Upstream physical network:** TP-Link X3000-5G router, `192.168.68.1/24`.
- **Internal segmentation (VLANs over `vmbr1`, VLAN-aware trunk):**
  - VLAN10 — Clients (`10.0.10.0/24`)
  - VLAN20 — Servers (`10.0.20.0/24`)
  - VLAN30 — Security (`10.0.30.0/24`)
- **VLAN20 IP convention:** each service category gets a fixed "tens" slot (`.1` firewall, `.10` identity/AD, `.20` file services, `.30` apps/SQL, `.40` Docker/IaC, `.50` backup, `.60` monitoring, `.70+` ERP/DB, `.80` ITSM, `.90+` registry/CI-CD/LLM/eShop/automation/K8s/secrets).

## Cross-Cutting Lab Conventions

- Standard Linux admin user: `sadmin` (NOPASSWD sudo, SSH key-based access). `root` keeps a password for local console/emergency use only; `PermitRootLogin no` blocks remote SSH access.
- `Europe/Rome` timezone on all VMs/LXCs; QEMU Guest Agent active on all VMs.
- Short naming convention for VMs/LXCs (`lx1`, `hr1`, `es1`, etc.) unless the name is already an acronym or can't reasonably be shortened.
- No VM/LXC auto-starts on host boot (`onboot=0`), except where explicitly documented otherwise.
- Backups: push-based architecture — each VM/LXC sends its own backups to `bk1` (Restic), while at the Proxmox host level `vzdump` performs monthly hot snapshots.

## Project Index

The lab's path follows the actual chronological installation order. Each document includes links to the previous and next project so the full sequence can be followed end to end.

| # | Project | Host(s) |
|---|---|---|
| 1 | [Proxmox VE 8.4.1 Installation](01-proxmox-ve-installation.md) | node1 |
| 1.1 | [Ordered Shutdown Script on Proxmox](01-1-ordered-shutdown-script.md) | pve1 |
| 2 | [OPNsense 26.1.6 Installation](02-opnsense-installation.md) | fw1 |
| 3 | [Windows Server 2022 Installation](03-windows-server-2022-dc-fs.md) | dc1, dc2, fs1 |
| 4 | [Ubuntu 22.04 Installation](04-ubuntu-2204-lx1.md) | lx1 |
| 5 | [Debian 13.3.0 Installation](05-debian13-bk1.md) | bk1 |
| 5.1 | [Restic Configuration](05-1-restic-backup-policies.md) | bk1 |
| 6 | [Windows 11 Pro Installation](06-windows11-cl1-cl2.md) | cl1, cl2 |
| 7 | [Windows Server Installation for app1](07-windows-server-app1.md) | app1 |
| 8 | [Ubuntu 24.04 Installation](08-ubuntu-odoo1-db1.md) | odoo1, db1 |
| 9 | [Rocky 9.4 Installation](09-rocky-mon01.md) | mon1 |
| 10 | [GLPI Installation](10-glpi-glpi1.md) | glpi1 |
| 11 | [Harbor and CI/CD Installation](11-harbor-cicd-hr1.md) | hr1 |
| 12 | [Odoo 17 → 18 Migration with OpenUpgrade](12-odoo-17-18-openupgrade-odoo2.md) | odoo2 |
| 13 | [Medusa eShop Installation](13-medusa-eshop-es1.md) | es1 |
| 14 | [Private LLM & N8N Installation](14-private-llm-llm1.md) | llm1, n8n |
| 15 | [K3s Single-Node Installation](15-k3s-single-node-k3s1.md) | k3s1 |
| 16 | [Ansible Implementation](16-ansible-implementation-lx1.md) | lx1 |
| 17 | [Terraform/IaC Implementation]() | lx1 |
| 18 | [Ansible Vault Implementation]() | lx1 |
| 19 | [HashiCorp Vault with Dynamic PKI]() | vault1 |
| 20 | [Oracle XE Sandbox (RMAN + Restic)]() | ora1 |
| 21 | [IBM DB2 on Docker]() | lx1 |
| 22 | [Red Hat Tools/Enterprise Installation]() | rhel1 |

*(Links will be completed progressively as each project is documented.)*
