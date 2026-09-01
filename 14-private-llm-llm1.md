---
title: 14-private-llm-llm1
description: private-llm
published: 1
date: 2026-09-01T19:29:23.576Z
tags: 
editor: markdown
dateCreated: 2026-08-30T07:05:24.984Z
---

# Project 14 — Private LLM & n8n | llm1, n8n1 | LXC | LLM/Automation | Ollama, Open WebUI, n8n |

**Previous:** [Project 13 — Medusa eShop (es1)](13-medusa-eshop-es1.md)
**Next:** [Project 15 — Kubernetes (k3s1)](15-k3s-single-node-k3s1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Deploy a private, self-hosted LLM chat stack (Ollama + Open WebUI) as a local alternative to public AI assistants, then extend it with a Retrieval-Augmented Generation (RAG) pipeline that keeps the model's knowledge of the lab's own documentation (WikiJS pages, Gitea repos) automatically up to date — without manual re-uploads.

## Context

At this stage GLPI, Harbor+CI/CD, and the Odoo 17→18 migration were already running. Private LLM was the next roadmap item. What started as a single-VM project (llm1) grew, over the course of the session, into a second project (n8n1, general-purpose workflow automation) once manual RAG updates proved too limited — this document covers both, since the automation LXC was deployed specifically to serve llm1's RAG pipeline, even though it was explicitly scoped as its own reusable piece of lab infrastructure rather than a sub-component of llm1.

## Decisions Made and Rationale

- **Llama 3.2 3B chosen over Qwen2.5 7B for the initial model**: with only Node 1 available (no GPU, CPU-only inference) and Node 2 hardware not yet purchased, the lighter 3B model was preferred for responsiveness; Qwen2.5 7B was kept as a documented future upgrade once Node 2 arrives.
- **LXC with `nesting=1,keyctl=1`**: same Docker-in-LXC requirement pattern as later reused for `es1`.
- **Both Ollama and Open WebUI bound to `127.0.0.1` only**: Nginx sits in front with HTTPS, the same reverse-proxy pattern already used for GLPI.
- **CPU/RAM sizing revisited live, based on observed load**: the initial 4 vCPU / 12GB spec was raised to 8 vCPU / 8GB after observing that 4 cores caused self-contention during inference (all threads competing for the same 4 physical cores) rather than genuine benefit, while RAM usage stayed comfortably under 4GB with the 3B model — confirmed by first ruling out a real problem (checking whether other VMs slowed down during inference) before committing to the change, and accepted as reasonable in a single-node homelab where the user rarely runs heavy work on multiple VMs simultaneously.
- **Ollama's data volume deliberately excluded from backup, Open WebUI's volume kept**: the downloaded model can be re-pulled in minutes and isn't worth backing up; chats, RAG configuration, and knowledge collections in Open WebUI's volume are irreplaceable and are backed up.
- **RAG built in two stages — Option A (manual) before Option B (automated)**: starting with a manual "Knowledge Collection" upload validated that the RAG flow itself (question → retrieval → grounded answer) worked before investing in automation — a deliberate walk-before-run sequencing.
- **n8n scoped as its own project, not a sub-component of llm1**: even though the RAG automation workflow was the trigger for building it, n8n was already an independent "Automation" gap on the lab's roadmap (reusable later for things like Zabbix-alert-to-GLPI-ticket workflows) — bundling it inside llm1 would have artificially tied general-purpose infrastructure to one use case.
- **Event-driven RAG sync over cron polling**: rather than a periodic script pulling from WikiJS/Gitea on a schedule, the chosen design reacts to real events — a Gitea instance-wide System Webhook on push, and WikiJS's Git Storage Target feature pushing page changes into a dedicated Gitea repo — so context updates in seconds rather than being stale for a polling interval.
- **Separate Knowledge Collections (`gitea-docs`, `wiki-docs`) instead of one merged collection**: improves retrieval precision, letting the model draw from the right type of context depending on the question, at the cost of a small amount of extra routing logic in the workflow.
- **Gitea System Webhook (instance-wide) instead of one webhook per repository**: a single webhook configured once at `Site Administration → Webhooks → System Webhooks` covers every existing and future repo automatically — critical given the stated intent to eventually document every VM/LXC in Gitea-hosted markdown.
- **WikiJS's own Git Storage Target used instead of a native WikiJS webhook**: WikiJS turned out not to expose a generic page-event webhook in its admin panel; pushing WikiJS's content into a dedicated `wiki-content` Gitea repo let the existing Gitea System Webhook pick it up "for free" — the originally planned second n8n workflow (`wikijs-sync-rag` with its own webhook) was abandoned mid-build once this was realized, and later deleted to avoid confusion.
- **Sync state (content hashes + Open WebUI file IDs) stored as a JSON file in n8n's own persistent volume**, rather than a separate database — judged sufficient for this document volume, avoiding unnecessary infrastructure.
- **n8n's encryption key backed up as a file alongside the data dump, inside the same Restic repository**: n8n encrypts stored credentials (Gitea/WikiJS/Open WebUI tokens) with this key; without it, a restored data volume alone is useless for those credentials. Restic's own repository-level encryption at rest was judged sufficient to carry the key safely alongside the data, rather than requiring a fully separate storage location.

## Step-by-Step

### Phase 1 — llm1: create the LXC in Proxmox

| Field | Value (final) |
|---|---|
| VMID | 115 |
| Hostname | llm1 |
| Type | LXC, Ubuntu 24.04 |
| Resources | 8 vCPU, 8GB RAM (started at 4 vCPU/12GB, revised after load testing) |
| Network | vmbr1, IP 10.0.20.91/24 |
| Features | `nesting=1,keyctl=1`, `onboot=1` |

Base post-install matched the lab convention: timezone `Europe/Rome`, `sadmin` user with sudo.

### Phase 2 — llm1: Docker CE, Ollama, Open WebUI

Docker CE, the Compose plugin, and `containerd.io` were installed via the standard upstream repository. A `~/docker/llm1/docker-compose.yml` was written with two services — `ollama` (official image, volume for `/root/.ollama`) and `open-webui` (official image, `OLLAMA_BASE_URL` pointed at the `ollama` service, `WEBUI_AUTH=true`) — both published only to `127.0.0.1`. `llama3.2:3b` (~2GB) was pulled and smoke-tested directly against Ollama before adding Nginx in front.

### Phase 3 — llm1: Nginx + HTTPS

A private key and CSR with SANs (`llm1.pymesis.lab`, `llm1`, `10.0.20.91`) were generated, submitted to `pymesis-DC01-CA` for a WebServer-template certificate, and installed. Nginx was configured as a reverse proxy to `127.0.0.1:8080` (Open WebUI), redirecting port 80 to HTTPS. `proxy_http_version 1.1` plus `Upgrade`/`Connection` headers were included from the start — Open WebUI streams model responses over WebSockets, and omitting these makes the chat appear to hang with no real-time text. The lab's internal CA root was installed in the LXC's trust store.

### Phase 4 — llm1: monitoring and backup

Zabbix and Wazuh agents were installed following the fleet-wide pattern. A Restic backup was set up with a Docker-volume dump script (`docker run` + `tar`, matching the pattern already used on lx1), scheduled for Sunday via cron. The script was revised once to exclude the Ollama volume — the model is trivially re-downloadable — keeping only Open WebUI's volume (chats, RAG state, configuration) in the backup.

### Phase 5 — llm1: RAG, Option A (manual Knowledge Collection)

Documentation exported from WikiJS (as Markdown) and README files pulled from Gitea repos were manually uploaded into a `pymesis-infra` Knowledge Collection in Open WebUI's Workspace, letting the model retrieve grounded context on request (triggered in chat with `#` + collection name). This validated the RAG flow itself before any automation was built.

### Phase 6 — n8n1: create the LXC in Proxmox

| Field | Value |
|---|---|
| VMID | 117 |
| Hostname | n8n1 |
| Type | LXC, Ubuntu 24.04 |
| Resources | 2 vCPU, 2GB RAM, 20GB disk (`local-zfs`) |
| Network | vmbr1, `tag=20`, IP 10.0.20.93/24 |
| Features | `nesting=1,keyctl=1`, `onboot=1` |

(IP sequencing note: `.90` harbor1, `.91` llm1, `.92` es1, `.93` n8n1 — purely creation order, not a functional grouping, except for the earlier intentional `.70`/`.71`/`.72` ERP block.)

### Phase 7 — n8n1: Docker CE and n8n

Docker CE was installed identically to llm1. A 32-byte encryption key was generated (`openssl rand -hex 32`) and stored in `.env` (`N8N_ENCRYPTION_KEY`) — flagged as critical to preserve outside of n8n1 itself, since it decrypts all stored credentials. The `docker-compose.yml` set `N8N_HOST`/`WEBHOOK_URL` to the final HTTPS domain (`n8n1.pymesis.lab`) rather than leaving the default `localhost`, since incoming webhooks from Gitea/WikiJS need to resolve and validate against the real domain.

### Phase 8 — n8n1: Nginx + HTTPS

Same certificate-issuance and reverse-proxy pattern as llm1, again with `proxy_http_version 1.1` and `Upgrade`/`Connection` headers — n8n's workflow editor also relies on WebSockets for live execution status.

### Phase 9 — n8n1: monitoring and backup

Zabbix and Wazuh agents installed following the fleet-wide pattern, using the standardized path `/mnt/backups/repos/n8n1` on bk1 and a `RESTIC_PASSWORD_FILE`-based cron (per the user's own established convention, applied without alteration). Unlike llm1, nothing in n8n's data volume was excluded — workflows, encrypted credentials, and execution history are all irreplaceable. The dump script was extended to also copy `.env` (containing the encryption key) into the same backed-up directory, so a full restore carries both the data and the key needed to decrypt it, without changing the Restic command itself.

### Phase 10 — GLPI agent backfill

Five hosts created after GLPI's dynamic inventory was configured (harbor1, odoo2, llm1, es1, n8n1) had never received the GLPI Agent. It was installed on all five in one pass (same 1.18 installer, same `--server=https://glpi1.pymesis.lab/front/inventory.php` pattern), after confirming each host already trusted the internal CA.

### Phase 11 — RAG automation architecture and credentials

Three credentials were generated and stored in n8n: an Open WebUI API key (profile → Settings → Account), a WikiJS read-only API token, and a Gitea read-only personal access token. The design settled on: two separate Knowledge Collections (`gitea-docs`, `wiki-docs`); a single Gitea instance-wide System Webhook (`Site Administration → Webhooks → System Webhooks`, target `https://n8n1.pymesis.lab/webhook/gitea-push`, push events, `main` branch filter); and sync state (content hashes + Open WebUI file IDs) persisted as `/home/node/.n8n/rag-state.json` inside n8n's own volume.

### Phase 12 — `gitea-sync-rag` workflow

Built node by node in the n8n editor: a Webhook Trigger receives Gitea's push payload; a Code node filters `.md`/`.txt` files from `commits[].added`/`modified`; an HTTP Request node fetches each file's raw content from Gitea's API; a Code node computes a SHA-256 hash and compares it against the stored state to decide if the file is new or changed; an IF node short-circuits unchanged files; two HTTP Request nodes add or update the file in Open WebUI depending on whether it was already tracked; a final Code node persists the updated hash and file ID back to `rag-state.json`. First tested end-to-end using a real repo (`homelab-docs`) rather than a disposable dummy, since documenting every VM/LXC in that repo was already the plan.

### Phase 13 — WikiJS integration and the `wikijs-sync-rag` false start

A first attempt to give WikiJS its own webhook-driven workflow (`wikijs-sync-rag`) was abandoned once it became clear WikiJS's admin panel has no generic page-event webhook. The design pivoted to WikiJS's built-in **Git Storage Target** feature: WikiJS pushes page changes as commits into a dedicated `wiki-content` Gitea repository, which the existing Gitea-wide System Webhook already covers with zero extra configuration. `gitea-sync-rag`'s filtering logic (Node 2) was extended to route by repository name — `admin/wiki-content` → `wiki-docs` collection, everything else → `gitea-docs` — with both upload nodes referencing the resulting `collectionId` dynamically instead of a hardcoded UUID. The half-built `wikijs-sync-rag` workflow, left with no live connection to anything, was deleted once the pivot was confirmed working, to avoid confusion.

## Problems Solved

- **`permission denied` connecting to the Docker socket on first `docker compose up`**: `usermod -aG docker sadmin` had been applied, but group membership only loads at login, not live. Fixed with `newgrp docker` for the current shell, or a full session re-login where that wasn't sufficient (observed with `pct enter` from the Proxmox console).
- **CPU pegged at 100% across all cores during inference, initially perceived as a possible problem**: expected behavior for CPU-only LLM inference with no GPU — confirmed as benign by checking that usage dropped back to near-zero between prompts (via `docker stats`) rather than staying elevated at rest, which would have signaled a real issue (a restart loop, a runaway container).
- **IP-numbering pattern confusion**: `llm1` landing at `.91` right after `harbor1` at `.90` was mistaken for an intentional relationship (echoing the earlier deliberate `.70`/`.71` odoo1/db1 pairing). Clarified that only that ERP block was a deliberate functional grouping; everything from `glpi1` onward was simple sequential numbering by creation order, with no technical relationship implied.
- **Backup volume-name mismatch risk flagged proactively**: the dump script assumed a volume name (`llm1_ollama_data`) derived from the Compose project directory name — verified against `docker volume ls` before trusting it in the cron, rather than assuming it would always match.
- **YAML syntax error after adding `NODE_EXTRA_CA_CERTS` to WikiJS's compose file**: the existing `environment:` block used map style (`KEY: value`), but the new line was added in list style (`- KEY=value`) — YAML doesn't allow mixing the two styles within the same block. Fixed by rewriting the new line in map style to match the rest of the block.
- **Critical incident — WikiJS lost all page content after `docker compose up -d --force-recreate`**: WikiJS's original compose file never set `DB_FILEPATH`, so its SQLite database lived in the container's writable layer instead of the mounted `/wiki/data` volume. `--force-recreate` destroyed that layer along with the database. Investigation confirmed: the running container was stopped immediately to prevent the setup wizard from overwriting anything further; the persistent volume was inspected and found to contain only `cache/`, `content/` (empty, 4.0K), and `uploads/` — no `.sqlite` file anywhere; no old container remained to recover from; and no Restic backup existed under any plausible repository name for WikiJS specifically. A promising lead — an existing `wikijs_wikijs_data` archive already being captured by lx1's general Restic script, including one from two days before the incident — turned out to be a dead end on inspection: that dump had only ever captured the same three empty-of-database folders, since the root cause (database outside the mounted volume) predated this session entirely. The content was confirmed permanently and completely lost, with no path to partial recovery. This was addressed head-on and transparently with the user, without minimizing the mistake or the loss.
- **Root cause fixed before any reconstruction began**: `DB_FILEPATH: /wiki/data/db.sqlite` was added to the compose file (in the correct map-style syntax) so the database lives inside the persistent volume going forward; a fresh `--force-recreate` was then safe, since no prior database existed to lose. WikiJS's dump was confirmed to already be included in lx1's existing weekly Restic script (alongside Portainer, Gitea, and Uptime Kuma volumes) — no new backup infrastructure was needed, only the underlying content location needed correcting.
- **`SSL certificate ... unable to get local issuer certificate` when WikiJS tried to sync to Gitea over HTTPS**: same recurring pattern as Gitea and n8n — the WikiJS container doesn't trust the internal CA by default. Fixed with `NODE_EXTRA_CA_CERTS` for WikiJS's own Node.js-level HTTP calls.
- **The same certificate error persisted specifically for WikiJS's Git push/pull operations, even after `NODE_EXTRA_CA_CERTS` was set**: WikiJS's Git Storage Target shells out to the system `git` binary rather than using Node's HTTP client, and `git` has its own independent certificate verification mechanism unaffected by `NODE_EXTRA_CA_CERTS`. Fixed by additionally setting `GIT_SSL_CAINFO` pointing at the same mounted CA file.
- **`403 Forbidden` when WikiJS attempted its first push to the `wiki-content` repo**: the token pasted into WikiJS's Git Storage Target was the same one already generated for n8n's Gitea read access (`repo:read` only) — insufficient scope for a push. Fixed by generating a dedicated token with read-and-write repository access, with a note to name future tokens clearly (`wikijs-git-write`, `n8n-gitea-read`, etc.) to avoid this kind of mix-up as more integrations are added.
- **Confusion over whether WikiJS needed its own webhook configured toward n8n**: clarified that the connection was never WikiJS-to-n8n directly — Gitea's instance-wide System Webhook already covers any push to any repo, including `wiki-content`, so once WikiJS successfully pushes there, the existing pipeline picks it up automatically with no WikiJS-side webhook configuration at all.
- **n8n HTTP Request node returned `400 - We could not find what you're looking for`**: the node's URL field contained the dynamic `collectionId` expression as literal text (`{{ ... }}` sent verbatim) rather than being evaluated, because the field was left in "Fixed" mode instead of "Expression" mode. Fixed by toggling the field to Expression mode via its `fx` icon, after which the UUID resolved correctly.
- **`400 - Duplicate content detected` on a later test run**: the file had, in fact, already been uploaded successfully in an earlier test run (executed node-by-node with "Execute step" rather than end-to-end), which doesn't always persist workflow state the same way a full run does — so `rag-state.json` didn't know the file was already tracked, and the workflow attempted a fresh `/file/add` that Open WebUI correctly rejected as a duplicate by content hash. Resolved by deleting the duplicate entry from Open WebUI and re-running the workflow end-to-end so state persistence completed correctly.
- **Binary file content silently failing to reach a later node in the workflow**: n8n's Code nodes don't automatically forward binary data between nodes unless explicitly reassigned in the returned item — an earlier draft of the hashing node computed the hash correctly but dropped the binary payload needed by the following upload node. Fixed by explicitly including `binary: $input.first().binary` in the node's return value.
- **New `~/homelab-docs` documentation repo initially cloned directly under `~/docker/`**: that directory is a specific convention for services with a real `docker-compose.yml`; a plain Git documentation repo doesn't fit there and risks confusing future service inventories. Resolved by introducing a separate `~/repos/` convention for cloned Git repositories that aren't Compose-managed services, and relocating the repo there.

## Final Result

- `llm1` (10.0.20.91) — Ollama + Open WebUI running Llama 3.2 3B, resource-tuned to 8 vCPU/8GB RAM based on observed load, HTTPS via the internal CA, Zabbix/Wazuh/GLPI monitoring, weekly Restic backup of Open WebUI's data (Ollama's model volume deliberately excluded), and a working manual RAG Knowledge Collection.
- `n8n1` (10.0.20.93) — n8n running in Docker behind Nginx/HTTPS, with monitoring, and a Restic backup covering both its data volume and its encryption key, using the user's standardized `RESTIC_PASSWORD_FILE` cron pattern.
- Fully automated, event-driven RAG pipeline: any push to any Gitea repository (including WikiJS's own content, delivered via its Git Storage Target into a dedicated `wiki-content` repo) is picked up by a single Gitea-wide System Webhook, routed by `gitea-sync-rag` in n8n to the correct Open WebUI Knowledge Collection (`gitea-docs` or `wiki-docs`) based on origin, with idempotent, hash-based change detection.
- A serious, fully-owned incident: WikiJS's entire wiki content was permanently lost due to its database living outside the mounted volume, discovered only once a routine `--force-recreate` destroyed the container's writable layer. The root cause was fixed (`DB_FILEPATH` inside the volume, plus `GIT_SSL_CAINFO` for its Git integration), WikiJS's backup was confirmed correctly wired into lx1's existing Restic script going forward, and the incident is documented as a standing lesson for the lab: always verify where an application's database actually lives before any destructive container operation, even for services that predate the current working session.
- Five previously-uncovered hosts (harbor1, odoo2, llm1, es1, n8n1) brought into GLPI's dynamic inventory.

## Pending

- Qwen2.5 7B upgrade for llm1, deferred until Node 2 hardware arrives.
- WikiJS content reconstruction — the wiki was reinstalled clean but its prior content was not yet rebuilt at the close of this session.
- Whether to move `~/docker/demo-harbor-ci/` to the new `~/repos/` convention was raised but left undecided at the end of this session.

## Cross-References

- Reverse-proxy and internal-CA HTTPS pattern consistent with GLPI (Project 10) and reused again for `es1` (Project 13).
- Backup path convention (`/mnt/backups/repos/<hostname>`, `RESTIC_PASSWORD_FILE`-based cron) is the same lab-wide standard referenced in Project 13.
- The Gitea Actions CI/CD runner used for Harbor (Project 11) is a separate mechanism from n8n's Gitea System Webhook — both listen to Gitea events, but for different purposes (image builds vs. RAG sync).
- The WikiJS data-loss incident is directly relevant to any future work involving `--force-recreate` on long-running containers that predate documented backup coverage — worth a deliberate audit pass across the rest of lx1's older services (Gitea, Portainer, Uptime Kuma) to confirm none share the same gap.

---

[← **Previous:** Project 13 — Medusa eShop (es1)](13-medusa-eshop-es1.md) | [**Next:** Project 15 — Kubernetes (k3s1) →](15-k3s-single-node-k3s1.md)