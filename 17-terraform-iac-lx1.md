---
title: 17-terraform-iac-lx1
description: terraform-iac
published: 1
date: 2026-09-01T17:40:35.651Z
tags: 
editor: markdown
dateCreated: 2026-08-30T19:11:30.705Z
---

# Project 17 — Terraform/IaC (lx1)

**Previous:** [Project 16 — Ansible (lx1)](16-ansible-implementation-lx1.md)
**Next:** [Project 18 — Ansible Vault (lx1)](18-ansible-vault-secrets-lx1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Introduce Infrastructure as Code into pymesis.lab by standing up Terraform on lx1, managed through the `bpg/proxmox` provider. Demonstrate the full IaC lifecycle in a way that is realistic for a portfolio: import an existing production resource (brownfield) and provision, verify, and destroy a brand-new resource (greenfield) — without touching any of the lab's other existing production services.

## Context

By this point in the homelab buildout, GLPI, Harbor + CI/CD, the Odoo 17→18 migration, the LLM automation stack, and the eShop had all been configured directly on their respective VMs/LXCs. Terraform/IaC and K3s remained the two open items on the roadmap. Given a sysadmin/network/DB-admin background rather than a DevOps one, this project was deliberately used to build IaC skills that would otherwise not come up in day-to-day work.

## Decisions Made and Rationale

- Provider: `bpg/proxmox`, chosen over the older Telmate provider for being more actively maintained and for native LXC + cloud-init support.
- Scope: Terraform manages the **lifecycle** of VMs/LXCs (create, destroy, define specs) only — internal configuration remains Ansible's responsibility once introduced.
- Realistic portfolio approach: rather than re-creating all 13 existing VMs/LXCs (risking the current state), the plan was to (1) provision everything new from this point forward through Terraform, and (2) import 1–2 existing resources as an exercise in "import + manage," the flow real-world migrations typically use.
- Runs on lx1, which already hosted Git and Docker; the Terraform binary was added there.
- Authentication via a dedicated Proxmox API token (`terraform@pve`) bound to a custom least-privilege role, instead of `root@pam` with a password.
- State kept local initially (`/opt/terraform/pymesis-infra/terraform.tfstate`), acceptable for a single operator, and folded into lx1's existing Restic backup.
- New dedicated Gitea repository (`terraform-pymesis-infra`), versioned from day one.
- Chosen resources: `glpi1` (VMID 112) as the brownfield import exercise; `tf-test1`, a lightweight Debian 12 LXC, as the greenfield create/destroy exercise.
- Post-incident decision (see Problems Solved): production and sandbox resources were split into two fully isolated repositories, state files, and Proxmox tokens, so that a mistake in one can never affect the other.
- A VMID/IP numbering convention was formalized: `1xx` VMIDs and `10.0.20.1–99` addresses are reserved for permanent production resources; `2xx` VMIDs and `10.0.20.100–199` addresses are reserved for anything disposable managed through the sandbox. Mapping rule for staging mirrors of an existing service: `200 + last two digits of the original VMID` (and the equivalent `+100` offset for the IP); generic sandbox resources with no production "parent" simply take the next free number in that range. This is safe on VLAN20 because DHCP is scoped to VLAN10, not VLAN20.

## Step-by-Step

### Phase 1 — Dedicated Proxmox user and token

From the pve1 shell (or Datacenter → Permissions in the GUI):

```bash
# Create a role with the minimum privileges needed to manage VMs/LXCs
pveum role add TerraformProv -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.*"

# Create the user and its API token
pveum user add terraform@pve --comment "Terraform automation"
pveum aclmod / -user terraform@pve -role TerraformProv
pveum user token add terraform@pve provider-token --privsep 0
```

The token secret is shown only once and is never pasted into chat — it goes straight into a git-ignored `.tfvars` file.

### Phase 2 — Install Terraform on lx1 and set up the repo

Install the binary via HashiCorp's apt repository:

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
terraform version
```

Repository layout for `pymesis-infra`:

```
pymesis-infra/
├── providers.tf
├── variables.tf
├── terraform.tfvars   # gitignored — holds the API token
├── glpi1.tf           # imported resource
├── tf-test1.tf        # new resource
└── .gitignore
```

`providers.tf` pins the provider version and points it at the Proxmox API:

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = false
}
```

`variables.tf` declares the endpoint and the sensitive API token variable, populated from a git-ignored `terraform.tfvars`.

### Phase 3 — `terraform init` and import of glpi1

After `terraform init`, the `glpi1` resource had to be written out in full **before** it could be associated with the existing container:

```hcl
resource "proxmox_virtual_environment_container" "glpi1" {
  vm_id     = 112
  node_name = "pve1"

  initialization {
    hostname = "glpi1"
    ip_config {
      ipv4 {
        address = "10.0.20.80/24"
        gateway = "10.0.20.1"
      }
    }
  }

  cpu { cores = 2 }
  memory { dedicated = 3072; swap = 512 }
  disk { datastore_id = "local-lvm"; size = 20 }
  network_interface { name = "eth0"; bridge = "vmbr1" }
  unprivileged = true
  features { nesting = true }
  started  = true
  on_boot  = true
}
```

```bash
terraform import proxmox_virtual_environment_container.glpi1 pve1/112
```

The first `terraform import` attempt failed with a TLS error: pve1's default self-signed certificate had been issued for its pre-migration IP (`192.168.68.10`) and was never replaced with one from the internal CA, unlike every other lab service. This was fixed by generating a CSR with the correct SANs (FQDN, old and new IP, localhost), signing it via DC1 (`certreq`), and installing the resulting cert/key at Proxmox's fixed panel paths (`/etc/pve/local/pve-ssl.{key,pem}`), then restarting `pveproxy`.

With the import successful, `terraform plan` was used iteratively to drive the `.tf` file to match the real container and eliminate drift:

| Issue found | Fix |
|---|---|
| `on_boot` is not a valid argument in this provider | Renamed to `start_on_boot` |
| `datastore_id` assumed `local-lvm` | Actual storage is `local-zfs` (this one forced a destroy+recreate until corrected) |
| Missing `operating_system` block | Added with `type = "debian"` and `template_file_id` (also forced a replacement until present) |
| Cosmetic diffs: `memory.dedicated`, `vlan_id`, `mac_address`, missing `dns` block | Set explicit values matching the real container |
| Undeclared `console` block | Provider would reset it to defaults; declared explicitly (`enabled`, `tty_count`, `type`) to prevent an unwanted change |

One structural issue remained even after all of the above: `template_file_id` is a **write-only** attribute — Proxmox does not retain which template was used to create an existing LXC, so it shows perpetual drift on any imported resource. This is the standard reason to add a `lifecycle` block:

```hcl
lifecycle {
  ignore_changes = [operating_system]
}
```

With that in place, `terraform plan` converged to a single legitimate change (`start_on_boot = false -> true`, correcting real drift) plus harmless client-side `timeout_*` noise. `terraform apply` completed cleanly (`0 added, 1 changed, 0 destroyed`), and the result was committed to the `pymesis-infra` Git repo.

### Phase 4 — Provisioning tf-test1 from scratch (create → verify → destroy)

A second resource, `tf-test1`, was defined as a lightweight Debian 12 LXC (1 vCPU / 512 MB), initially at VMID 118 / `10.0.20.94`, to demonstrate the other half of the IaC lifecycle: a resource Terraform creates, manages, and destroys entirely on its own. `user_account.keys` was set for SSH access, generating a new `id_ed25519` keypair on lx1 since none existed yet for that shell user.

A provider limitation surfaced here: `bpg/proxmox`'s `initialization.user_account` block for LXCs configures the **root** account, not a custom non-root user — unlike full cloud-init VMs. Login therefore had to be via SSH key as root rather than a `sadmin` account.

A second, unrelated issue appeared on `apply`: the Debian 12 template originally used for `glpi1` (`12.7-1`) had since been superseded on disk by `12.12-1`. Updating the reference in `tf-test1.tf` did not require touching `glpi1.tf`, since its `lifecycle.ignore_changes` already shields it from that field.

**Incident:** after `tf-test1` was created and its SSH access verified, `terraform destroy` was run without `-target`. Since `tf-test1` and `glpi1` shared the same state file, the command destroyed **both** — including the production GLPI container. Recovery was possible thanks to a recent Proxmox-level `vzdump` backup (a hypervisor snapshot including installed packages, dated prior to any changes since it was taken): `glpi1` was restored via `pct restore`, then re-imported into a fresh Terraform state.

This incident directly drove two structural fixes:

1. **Split the repositories.** `pymesis-infra` (production) and `pymesis-sandbox` (disposable) became fully separate: separate Git repos, separate local state files, and separate Proxmox API tokens (`terraform@pve` vs `terraform-sandbox@pve`). A `destroy` in one can no longer reach a resource in the other, regardless of whether `-target` is used.
2. **Formalize the VMID/IP numbering convention** described above, and apply it retroactively: `tf-test1` was migrated from VMID 118 / `10.0.20.94` to VMID 200 / `10.0.20.101` via a destroy+recreate (safe, since it is a disposable resource).

Both repositories were pushed to Gitea. Getting there required reconciling divergent histories — the local repos were initialized with a `master` branch while Gitea auto-initialized each new repo with `main` — resolved with `git pull origin main --allow-unrelated-histories` (after setting `pull.rebase false` globally), followed by deleting the leftover `master` branches. A separate, smaller mix-up during sandbox token setup — the sandbox `terraform.tfvars` still held the production token by mistake — was caught by testing the token directly against the Proxmox API with `curl` (noting that bash's history expansion on `!` in the token string requires `set +H` to test correctly) and fixed by regenerating and re-pasting the correct sandbox-specific token.

Once the exercise was complete, `tf-test1` was destroyed cleanly with a plain `terraform destroy` — safe this time, since the sandbox state now only ever contains disposable resources.

## Problems Solved

- pve1's default self-signed certificate failed TLS validation for the Terraform provider because it had been issued for the node's pre-migration IP; solved by issuing a proper certificate from `pymesis-DC01-CA` with the correct SANs.
- An incorrect provider argument (`on_boot` instead of `start_on_boot`) and a wrong storage assumption (`local-lvm` instead of the actual `local-zfs`) both produced a forced destroy+recreate plan; both were caught and corrected before ever running `apply`.
- `template_file_id` is a write-only attribute that always shows drift on imported LXCs; resolved with a `lifecycle { ignore_changes = [operating_system] }` block, the standard pattern for brownfield imports.
- An unscoped `terraform destroy` against a shared state file destroyed production GLPI along with the disposable test resource; recovered via a recent Proxmox `vzdump` backup and a re-import, and prevented from recurring by fully isolating production and sandbox into separate repos, states, and tokens.
- `bpg/proxmox`'s LXC `user_account` block only manages the root account, not custom users (unlike VM cloud-init); worked around with SSH key-based root access instead of assuming a custom user would be created.
- The sandbox `terraform.tfvars` was accidentally left holding the production Proxmox token, causing authentication confusion; corrected by regenerating and carefully re-pasting the sandbox-specific token, verified independently via a direct API call.
- Local and Gitea-initialized repositories had divergent, unrelated Git histories (`master` vs `main`); reconciled with `git pull --allow-unrelated-histories` and `pull.rebase false`, then the old branches were removed.

## Final Result

- Terraform installed and operational on lx1, managing Proxmox resources through the `bpg/proxmox` provider.
- `pymesis-infra` (production): `glpi1` (VMID 112) fully under Terraform management, matching the real container configuration, with `lifecycle.ignore_changes` handling the write-only template field. State kept locally and backed up via Restic.
- `pymesis-sandbox` (isolated): its own dedicated Proxmox token, repository, and state file, used to validate the full create → verify → destroy IaC lifecycle with no risk to production.
- pve1 now has a valid TLS certificate issued by the internal CA, consistent with the rest of the lab's services.
- Both repositories versioned in Gitea (`terraform-pymesis-infra`, `terraform-pymesis-sandbox`), each with a single, clean `main` branch.
- VMID/IP numbering convention documented and in effect: `1xx` / `10.0.20.1–99` for production, `2xx` / `10.0.20.100–199` for sandbox/disposable resources.
- LLM, eShop, Odoo, and Harbor were left untouched throughout, avoiding any drift on production services not yet managed by Terraform.

## Pending

- None for this project's original scope — both the brownfield import and the greenfield create/destroy exercise were completed.
- Standing, longer-term intention (tracked separately, not part of this project's scope): bring more of the fleet under Terraform management going forward, defaulting to Terraform for new VMs/LXCs, and eventually use it to simulate Nodo 2 failover/HA scenarios once a second node is available.

## Cross-References

- [Project 10 — GLPI (glpi1)](10-glpi-glpi1.md) — the resource imported into Terraform in this project.
- [Project 16 — Ansible (lx1)](16-ansible-lx1.md) — intended to take over post-provisioning configuration management for anything Terraform provisions going forward.
- [Project 5.1 — Restic Backup Architecture](05.1-restic-backup-architecture.md) — backs up the local Terraform state file on lx1.
- [Project 15 — K3s Single-Node (k3s1)](15-k3s-single-node-k3s1.md) — `tf-test1` occupying VMID 118 forced a numbering gap when `k3s1` was created at VMID 119, one of the events that prompted the VMID/IP numbering convention formalized in this project.

---

[← **Previous:** Project 16 — Ansible (lx1)](16-ansible-implementation-lx1.md) | [**Next:** Project 18 — Ansible Vault (lx1) →](18-ansible-vault-secrets-lx1.md)