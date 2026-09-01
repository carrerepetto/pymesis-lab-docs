---
title: 15-k3s-single-node-k3s1
description: k3s-single-node
published: 1
date: 2026-09-01T19:29:45.812Z
tags: 
editor: markdown
dateCreated: 2026-08-30T07:07:05.103Z
---

# Project 15 — Kubernetes | k3s1 | VM | Platform Admin (K8s) | Ubuntu 24.04, K3s v1.36.2 |

**Previous:** [Project 14 — Private LLM & n8n (llm1,n8n1)](14-private-llm-llm1.md)
**Next:** [Project 16 — Ansible (lx1)](16-ansible-implementation-lx1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Deploy a single-node K3s cluster as the lab's introduction to Kubernetes — the last of the original roadmap's core skill gaps (Kubernetes, IaC, CI/CD) — with a web-accessible Dashboard, monitoring, and backup aligned to the rest of the lab, while deliberately scoping out multi-node HA until Node 2 hardware arrives.

## Context

At this point GLPI, Harbor+CI/CD, the Odoo 17→18 migration, the private LLM stack, eShop, and Terraform/IaC (with its infra/sandbox repo split following the earlier `destroy` incident) were all complete — K3s was the final item on the original roadmap list.

## Decisions Made and Rationale

- **Full VM instead of LXC**: the same reasoning already applied to Harbor applies here — containerd needs overlayfs and full cgroups v2, plus kernel module access that an unprivileged LXC doesn't expose reliably even with `nesting=1,keyctl=1`. Running K8s nested inside containers isn't representative of any real environment, and tends to surface odd storage-driver bugs; a full VM was chosen so the skill built here reflects real-world practice and holds up on a CV.
- **Single-node `server` mode (control plane + kubelet + containerd combined)**, with no separate agent — appropriate for one node; the plan explicitly notes that a second `server`/`agent` joins later for real HA once Node 2 arrives.
- **Ubuntu 24.04 cloud-image + cloud-init**, matching the same provisioning pattern already used for `harbor1`/`odoo1`, rather than a manual ISO install.
- **VMID/IP adjusted to avoid colliding with Terraform's sandbox test VM**: the first proposed VMID 118 / IP 10.0.20.94 turned out to already be taken by `tf-test1` (Terraform's sandbox test VM) — deliberately checked before creating anything, since Terraform sandbox runs are expected to reuse that VMID/IP range for disposable test infrastructure.
- **Kubernetes Dashboard (official) instead of Rancher**: Rancher is much heavier and not justified for a single node; the official Dashboard gives the same web-based administration experience for this scope. `kubectl` from app1 was also kept available in parallel, since many sysadmins end up using both a CLI and a web view day to day.
- **NodePort + Nginx reverse proxy instead of exposing the Dashboard's NodePort directly**: same HTTPS-with-internal-CA pattern used everywhere else in the lab (GLPI, Harbor), rather than requiring users to remember and trust a random high port.
- **Traefik (K3s's bundled default ingress controller) disabled**: Traefik binds ports 80/443 on the host via its own LoadBalancer/ServiceLB, which collided directly with Nginx's intent to own those same ports for the reverse-proxy pattern. Since the only current use case is the Dashboard via Nginx (no other in-cluster ingress needed yet), disabling Traefik at install time was judged the cleanest fix — accepting the trade-off that a real in-cluster ingress controller would need to be reconsidered later if actual applications are deployed onto K3s.
- **Restic backup scoped to etcd snapshots + config, not pod data**: for a single-node lab cluster, pod/PV data isn't meaningfully "highly available" regardless of backup strategy — what actually matters to preserve is the cluster's state (etcd) and the manually-applied manifests/certs, so the backup was scoped accordingly rather than attempting a broader (and less useful) volume-level backup.
- **Scope deliberately closed at "VM + K3s + Dashboard + monitoring + backup"**: explicitly confirmed as the full intended scope for this project — no application workloads were deployed onto the cluster, and multi-node scheduling/HA is intentionally deferred to when Node 2 is available.

## Step-by-Step

### Phase 1 — Create the VM in Proxmox

| Field | Value |
|---|---|
| VMID | 119 (118/10.0.20.94 rejected — already used by Terraform's `tf-test1` sandbox VM) |
| Hostname | k3s1 |
| Type | Full VM, Ubuntu 24.04 (cloud-image + cloud-init) |
| Resources | 4 vCPU, 8GB RAM, 60GB disk |
| Network | vmbr1, `tag=20`, IP 10.0.20.95/24, gateway 10.0.20.1 |
| DNS | 10.0.20.10 (pymesis.lab) |
| Storage | local-zfs |

Provisioned via `qm create` + `qm importdisk` from the Ubuntu Noble cloud image, resized to 60GB, with static networking and DNS set through cloud-init (`qm set --ipconfig0`, `--nameserver`, `--searchdomain`).

### Phase 2 — Install K3s

Base setup matched the lab convention: timezone `Europe/Rome`, hostname `k3s1`. K3s was installed via the official `get.k3s.io` script in `server` mode (control plane, kubelet, and containerd all in one, no separate agent needed for a single node), with `--write-kubeconfig-mode 644` and `--tls-san` flags for both the DNS name and the IP, so `kubectl` wouldn't reject the API server's certificate when connecting from outside localhost. Node readiness was confirmed with `kubectl get nodes`.

### Phase 3 — Kubernetes Dashboard

The official Dashboard (v2.7.0) was applied via its recommended manifest, followed by a dedicated `admin-user` ServiceAccount bound to the `cluster-admin` ClusterRole (Dashboard login is token-based; there's no native LDAP integration). The Dashboard service was patched to `NodePort` for external access, and a login token generated with `kubectl -n kubernetes-dashboard create token admin-user` (default 1-hour expiry, regenerated as needed).

### Phase 4 — HTTPS with the internal CA

A private key and CSR with SANs (`k3s1.pymesis.lab`, `k3s1`, `10.0.20.95`) were generated, submitted to `pymesis-DC01-CA` for a WebServer-template certificate, and installed. Nginx was configured to terminate HTTPS and reverse-proxy to the Dashboard's NodePort over `https://127.0.0.1:<port>` (the Dashboard serves its own self-signed TLS internally, so the proxy target uses `https://`, not `http://`, with `proxy_ssl_verify off` for that last internal hop). The lab's CA root was installed in the VM's trust store.

### Phase 5 — Monitoring, inventory, and backup

Zabbix and Wazuh agents were installed following the fleet-wide pattern. The GLPI Agent (1.18) was added as well, flagged by the user as a step not to forget this time. A Restic backup was set up scoped to what actually matters for a K8s cluster: a cron-driven `k3s etcd-snapshot save`, plus the `/etc/rancher/k3s` and `/etc/ssl/k3s1` directories, pushed weekly to `bk1` under the lab-wide standardized path `/mnt/backups/repos/k3s1`, using the established `RESTIC_PASSWORD_FILE`-based cron pattern (flagged proactively by the user as the convention to reuse, since it had been omitted from the first draft of the cron).

## Problems Solved

- **`qm set --sshkeys` silently failed because `/root/.ssh/authorized_keys.pub` didn't exist on pve1**: since that command failed, neither the `ciuser` nor the `sshkeys` cloud-init settings were actually applied, leaving the VM with no configured user or key at all after its first boot. Resolved by locating the actual existing key on pve1 (`id_rsa.pub`) and re-applying it with `qm set`, followed by a full `qm stop`/`qm start` — a plain reapply without a full restart doesn't work, since cloud-init only processes user-data on an instance it still considers "not yet initialized."
- **SSH access worked from pve1 but not from the user's usual Windows PC (`app1`)**: the deployed public key (`id_rsa.pub`) only had a matching private key on pve1; the Windows machine had no corresponding private key at all, hence the outright authentication rejection (not a routing or timeout issue, which confirmed the SSH service itself was reachable and correctly configured). Resolved by generating a new keypair on `app1` (the user's actual daily workstation) and appending its public key to the same `authorized_keys` file passed to cloud-init, so both pve1 and app1 retain access without disturbing the working pve1 key.
- **404 and a red padlock when first accessing the Dashboard via Nginx**: diagnosed as two separate problems rather than assumed to be one. The underlying cause for the 404 was that K3s's bundled Traefik ingress controller had already claimed host ports 80/443 via its ServiceLB before Nginx could bind them — confirmed with `ss -tlnp` and by inspecting the certificate Nginx was actually serving (`openssl s_client`), which turned out to be Traefik's own default self-signed cert, not the one issued for k3s1. Resolved by reinstalling K3s with `--disable traefik`, freeing the ports for Nginx exclusively (this also reset the cluster/etcd, requiring the Dashboard deployment to be redone from scratch, on a cluster with no other workloads to lose).
- **Certificate presented correctly (verified with `openssl s_client`, issued by the internal CA, valid dates) but Chrome still showed "Not Secure"**: root-caused, rather than assumed, as mixed content — the Dashboard's WebSocket connections for live logs/exec were falling back to `ws://` because Nginx's reverse-proxy block lacked the `Upgrade`/`Connection` headers needed for a proper WebSocket upgrade, the same category of issue already seen with Open WebUI and n8n. Fixed by adding `proxy_http_version 1.1` plus `Upgrade`/`Connection` headers to the `location /` block, confirmed resolved once the padlock turned green after a hard refresh.
- **Console text in the Proxmox noVNC viewer appeared oversized/low-resolution compared to other VMs (e.g. lx1)**: initially suspected to be a Proxmox-side display type/memory setting (`vga std` vs `qxl`), but comparing `qm config` for both VMs showed neither had any explicit VGA override, and lx1's GRUB config was completely stock — ruling out a Proxmox-side cause. Correctly re-diagnosed, after comparing the screenshots more carefully, as the opposite of the initial assumption: k3s1 was stuck in generic low-resolution text mode (fbcon not picking up KMS from the `virtio-gpu`/`bochs-drm` driver), rather than having a resolution that was merely different by design. Left open at the end of the session pending inspection of `dmesg` for DRM/framebuffer driver load messages, to confirm whether the `--vga std` change applied earlier during troubleshooting had itself interfered with KMS auto-detection.
- **`sadmin`'s VM login password was not recoverable**: unlike VMIDs and IPs, an interactively-typed `passwd sadmin` value was never shared in the session and so was never recorded anywhere. Clarified that this wasn't an oversight to fix but an expected consequence of how the password was set — with SSH key-based access already working from both pve1 and app1, the practical resolution was simply to reset it directly with `sudo passwd sadmin` from an active session (or via the Proxmox console if no session was available), rather than trying to recover the original value.

## Final Result

- `k3s1` (10.0.20.95) — single-node K3s cluster (control plane + kubelet + containerd combined), Traefik disabled in favor of Nginx as the HTTPS front door.
- Kubernetes Dashboard v2.7.0 reachable at `https://k3s1.pymesis.lab`, token-based `cluster-admin` login, valid certificate from the internal CA, WebSocket-dependent features (live logs/exec) working correctly through the reverse proxy.
- Zabbix, Wazuh, and GLPI agents installed and confirmed reporting.
- Weekly Restic backup covering etcd snapshots, `/etc/rancher/k3s`, and `/etc/ssl/k3s1`, using the standardized `/mnt/backups/repos/k3s1` path and `RESTIC_PASSWORD_FILE` cron pattern.
- Project scope deliberately closed here — no application workloads deployed, single-node only, by design — completing the full original roadmap (GLPI, Harbor+CI/CD, Odoo 17→18, LLM, eShop, Terraform/IaC, K3s single-node).

## Pending

- Console framebuffer/resolution issue on k3s1's Proxmox noVNC console — root cause (KMS driver detection) identified but not yet confirmed or fixed at the close of this session.
- Multi-node K3s (a second `server`/`agent` for real HA) deferred until Node 2 hardware arrives.
- Reconsidering an in-cluster ingress controller (Traefik on an alternate port, or Nginx Ingress) if real application workloads are deployed onto K3s in the future.

## Cross-References

- The LXC-vs-VM reasoning here directly mirrors the decision already made for Harbor in Project 11 — both needed full containerd/overlayfs support that an LXC doesn't reliably provide.
- VMID/IP collision-checking against Terraform's sandbox VMs (`tf-test1`) reflects the two-repo (infra/sandbox) split adopted after the `destroy` incident described in the Terraform/IaC project.
- HTTPS-via-internal-CA and WebSocket-upgrade-header patterns are the same ones established for GLPI (Project 10), Harbor (Project 11), and later reused for Open WebUI and n8n (Project 14).
- Backup path convention (`/mnt/backups/repos/<hostname>`, `RESTIC_PASSWORD_FILE`-based cron) is the same lab-wide standard referenced throughout Projects 13–14.

---

[← **Previous:** Project 14 — Private LLM & n8n (llm1,n8n1)](14-private-llm-llm1.md) | [**Next:** Project 16 — Ansible (lx1) →](16-ansible-implementation-lx1.md)