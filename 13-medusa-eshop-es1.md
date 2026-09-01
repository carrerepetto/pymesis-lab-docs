---
title: 13-medusa-eshop-es2
description: medusa-eshop
published: 1
date: 2026-09-01T19:29:00.772Z
tags: 
editor: markdown
dateCreated: 2026-08-29T20:07:19.406Z
---

# Project 13 — Medusa eShop | es1 | LXC | eCommerce | Ubuntu 24.04, Medusa.js v2, Node.js, PostgreSQL, Redis |

**Previous:** [Project 12 — ERP Migration (odoo2)](12-odoo-17-18-openupgrade-odoo2.md)
**Next:** [Project 14 — Private LLM & n8n (llm1, n8n1)](14-private-llm-llm1.md)

[← Back to Lab Index](00-pymesis-lab-index.md)

## Objective

Stand up a headless e-commerce stack — API backend and storefront as separate services — as the lab's first real application to travel end-to-end through the CI/CD pipeline built in Project 11: source push, Gitea Actions build, Harbor registry, production deployment, rather than a one-off proof of concept.

## Context

At this stage GLPI, Harbor+CI/CD, the Odoo 17→18 migration, and the private LLM stack were already running. eShop was the next item on the roadmap, chosen specifically as the vehicle to exercise the CI/CD pipeline against a real multi-image application, instead of the throwaway demo repo that had been used earlier just to validate that the pipeline worked at all.

## Decisions Made and Rationale

- **Medusa.js v2 chosen over PrestaShop or Saleor**: the lab already has plenty of LAMP-pattern experience (GLPI, the legacy IIS+SQL intranet) — a PrestaShop install would repeat that stack without adding anything new. Medusa is Node.js/TypeScript + PostgreSQL + Redis, with a headless architecture (API backend fully separate from the storefront) — this gives CV exposure to an ecosystem not otherwise covered, and matches the "API-first" pattern most requested in modern infra roles today. Saleor was considered and rejected as heavier for no proportional benefit (Django + GraphQL + Celery + Redis).
- **Headless architecture, including the separate Next.js storefront**: a backend/API cleanly separated from its frontend is a far more natural fit for future Kubernetes orchestration (multiple pods and services, independent scaling) than a LAMP monolith would be — this deliberately positions es1 as the first realistic candidate to migrate from Docker Compose to K3s manifests.
- **LXC with `nesting=1,keyctl=1`**: required for Docker to run correctly inside the container, the same combination already used for `llm1`.
- **Own PostgreSQL instance on es1, not a reuse of db1**: keeps the e-commerce database fully decoupled from the Odoo database host.
- **Custom Dockerfile through Gitea Actions + Harbor, instead of the public `medusajs/medusa` image**: since this was the first real application to go through CI/CD, building a proprietary image via the existing build→push→deploy flow kept the workflow consistent with the rest of the lab, rather than depending on a generic upstream image that may need extra seed/migration steps of its own.
- **New `~/apps/` convention, alongside the existing `~/docker/`**: `~/docker/` was already used on lx1 for third-party Compose stacks; `~/apps/` was introduced specifically for projects with real first-party source code, like es1, to keep the two concerns visually and organizationally distinct.
- **Reused the existing Harbor `pymesis` project and `robot$gitea-ci` account**: no new Harbor project or robot account was created for es1 — its two images (`es1-backend`, `es1-storefront`) simply push into the project and credentials already established in Project 11.
- **Postgres client-side pool raised to `max: 50`**: Medusa v2 is modular, and its database migration runs ~20+ module migrations in parallel (product, order, customer, cart, region, promotion, etc.), each requesting its own connection from the client-side Knex pool. That pool's low default max was being exhausted well before Postgres's own `max_connections: 100` limit, and this was confirmed with `docker stats` before touching any config, to rule out a CPU/RAM bottleneck first.
- **`docker image prune` in the CI workflow scoped to `--filter "label!=keep=true"`**: an unscoped prune step (and, separately, a manual disk-cleanup prune) repeatedly deleted the custom `pymesis-ci-base:latest` runner image, since Docker considered it "unused" between the ephemeral containers each job spins up. Tagging that image with `--label keep=true` at build time makes it permanently exempt from automated cleanup.

## Step-by-Step

### Phase 1 — Create the LXC in Proxmox

| Field | Value |
|---|---|
| VMID | 116 |
| Hostname | eshop1 (later renamed es1) |
| Type | LXC, Ubuntu 24.04 |
| Resources | 4 vCPU, 6GB RAM, 30GB disk (`local-zfs`) |
| Network | vmbr1, `tag=20` (VLAN20 trunk), IP 10.0.20.92/24 |
| Features | `nesting=1,keyctl=1` (Docker-in-LXC requirement, same as `llm1`), `onboot=1` |

Base post-install steps matched the lab-wide convention: timezone `Europe/Rome`, `sadmin` user with sudo. Docker CE, the Compose plugin, and `containerd.io` were installed via the standard upstream repository, and `sadmin` was added to the `docker` group.

### Phase 2 — Scaffold the Medusa project (in `es1`)

Node.js 20 was installed on es1. A temporary, throwaway Postgres container (`es1-scaffold-pg`) was started purely so `create-medusa-app` could run its initial migrations — this was explicitly not the production database. The scaffold was generated with `npx create-medusa-app@latest`, choosing to also install the Next.js Starter Storefront (rather than backend-only), specifically to get the full headless architecture that motivated choosing Medusa in the first place. An initial admin user was created and the dev server (`medusa develop`) was briefly validated before moving on to containerization; it was then stopped, since the real flow going forward would be build → image → Harbor → production container, not a manually-run dev server.

### Phase 3 — Git repository and Dockerfiles

A Gitea repository `es1` was initialized under `~/apps/es1` (distinct from `~/docker/`, per the new convention above). Once the scaffold was inspected, the project turned out to be a **Turborepo monorepo** (`apps/backend/`, `apps/storefront/`) rather than the flat single-`package.json` project initially assumed — this required two separate multi-stage Dockerfiles, one per deployable image, instead of the single generic Dockerfile drafted at the start. The lab's internal CA certificate was installed on es1 so HTTPS Git operations against Gitea would succeed.

### Phase 4 — Gitea Actions workflow

Harbor credentials were stored as Gitea repository secrets (`HARBOR_USERNAME`, `HARBOR_PASSWORD`) rather than hardcoded in the workflow file. `.gitea/workflows/build.yml` was written with two jobs, `build-backend` and `build-storefront`, each logging into `hr1.pymesis.lab` and pushing into the existing `pymesis` project. The Docker build context had to be set to the **monorepo root**, not the app subfolder, so `npm ci` could resolve the shared root lockfile; each Dockerfile is still referenced explicitly with `-f`.

### Phase 5 — Backend production deployment

The scaffold Postgres container was removed. A production `docker-compose.yml` was written in `~/docker/es1/` (deliberately separate from the `~/apps/es1/` source tree), with persistent Postgres and Redis containers and the backend image pulled from Harbor. `medusa db:migrate` was run against the real database, followed by creation of the production admin user. The backend's response on port 9000 was verified against real (not scaffold) data before moving on.

### Phase 6 — Storefront production deployment

A Medusa Publishable API Key, generated from the now-live Admin dashboard once a store existed, was wired in as a build-arg (`NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY`) and a matching Gitea secret (`MEDUSA_PUBLISHABLE_KEY`) — required because Next.js bakes `NEXT_PUBLIC_*` variables in at build time, not runtime. The previously-paused `build-storefront` job was reactivated once the key existed, and the storefront service was added to the production `docker-compose.yml`, depending on the backend.

### Phase 7 — HTTPS exposure (Nginx)

Nginx was configured on es1 with path-based routing under `https://es1.pymesis.lab`, using an internal CA-issued certificate — the same pattern already used for GLPI and Harbor:

- `/app`, `/admin`, `/store`, `/auth` → backend (`127.0.0.1:9000`)
- `/` (everything else) → storefront (`127.0.0.1:8000`)

### Phase 8 — Monitoring and backup

Zabbix, Wazuh, and GLPI agents were installed on es1, matching the fleet-wide pattern from previous hosts. A Restic backup was configured: a cron-driven `pg_dump` (via `docker exec`, since Postgres runs inside a container rather than natively) of the Medusa database plus the production `docker-compose.yml`, pushed weekly to `bk1` under the lab-wide standardized path `/mnt/backups/repos/es1`.

## Problems Solved

- **`create-medusa-app` failed / database connection errors caused by a `#` in the password**: the chosen password contained `#`, which bash treats as a comment start when the string is unquoted, and which URL parsers separately treat as a fragment delimiter even once the shell-level quoting is correct. Fixed in the short term by wrapping the connection URL in single quotes and, for the URL-parser issue specifically, URL-encoding `#` as `%23`; the lasting fix was to avoid shell-special characters (`#`, `$`, `` ` ``, spaces) in any password destined for scripts, env vars, or cron going forward.
- **Git commit/push failed on the very first scaffold push**: Git identity (`user.email`/`user.name`) had never been configured, so the commit silently failed, leaving nothing for `git branch -M main` or `git push` to act on. Fixed by configuring Git identity and retrying.
- **Corrupted `Dockerfile` after pasting a heredoc over SSH**: terminal echo/autocomplete interference during a large pasted block left stray characters at the top of the file. Caught by inspecting with `cat`, and the file was simply recreated cleanly.
- **Generic Dockerfile didn't match the generated project structure**: `create-medusa-app` produces a Turborepo monorepo, not a flat single-package project, so the original single Dockerfile assuming `dist/index.js` output was wrong. Replaced with two dedicated multi-stage Dockerfiles, one per app.
- **`npm ci` failed in CI with no lockfile found**: the Docker build context was scoped to the app subfolder (`./apps/backend`), but the npm workspaces lockfile lives at the monorepo root. Fixed by changing the build context to the repo root and referencing each Dockerfile with `-f`.
- **Backend production stage failed `npm ci` (no lockfile in `.medusa/server`)**: `medusa build`'s output directory doesn't generate its own `package-lock.json`. Fixed by using `npm install --omit=dev` instead of `npm ci` in that stage only.
- **Storefront build failed on a missing Publishable API Key**: Next.js bakes `NEXT_PUBLIC_*` vars in at build time, but the key can only be generated from a live backend Admin with a store already created — a genuine chicken-and-egg dependency. Resolved by deliberately pausing the storefront build job in the workflow until the backend was deployed and the key existed, then reactivating it with the key wired in as both a build-arg and a Gitea secret.
- **Harbor (hr1) went completely down mid-project**: investigation traced this back to Harbor having originally been installed under `/tmp` rather than a persistent path — Ubuntu's periodic `/tmp` cleanup wiped it after a VM reboot unrelated to this project. Rebuilt `harbor.yml` under `/opt/harbor`, reusing the existing certificates and the untouched `/data` volume; this incident is documented as a standing lesson for the lab: never install a persistent service under `/tmp` (see Project 11).
- **Harbor admin login failed after the reinstall**: `harbor.yml`'s `harbor_admin_password` and `database.password` fields only take effect on first database initialization — reinstalling against the pre-existing `/data` volume left the original credentials in place and silently ignored the new file. Diagnosed via `docker compose logs core`, and ultimately resolved by keeping the original passwords consistent on both sides rather than rotating them mid-incident.
- **Harbor's `core` service stuck in a restart loop after a Postgres password change**: Harbor's installer writes the Postgres password once into a `.env`-style file (`common/config/core/env`); a `#` in that password was silently truncated there exactly as it had been in bash, so `core` was authenticating with a different (truncated) password than the one actually set in Postgres. Fixed by removing `#` from both the Postgres and Harbor admin passwords, updating both sides to match, and re-running the installer to regenerate the environment files.
- **A robot account credential was exposed in plaintext**: the `docker login` output was captured verbatim in `~/.bash_history` on hr1 during the reinstall. Flagged for rotation (accepted as low-risk in a homelab context), and the local history buffer was cleared with `history -c && history -w`.
- **Gitea Actions pipeline runs completing instantly with "0s" and no real execution**: the Gitea Actions runner container on lx1 had stopped, for the same reboot-related reason as the Harbor incident, and was never automatically picked back up. Fixed by bringing the runner back up with `docker compose up -d`, confirming its label mapping (`ubuntu-latest` → `pymesis-ci-base:latest`) was still intact, and re-triggering the pipeline with an empty commit.
- **`pymesis-ci-base:latest` kept getting deleted**: both a manual `docker system prune -af` (run to free disk space) and, later, an automated cleanup step added to the workflow considered the custom base image "unused" between ephemeral job containers and removed it. Fixed by rebuilding the image with `docker build --label keep=true` and scoping the cleanup step's filter to `--filter "label!=keep=true"`, making it permanently exempt.
- **lx1 ran out of disk space mid-build** (`no space left on device`): several failed build attempts had left uncleaned Docker build-cache layers, on top of images from other lab services already running on the same host. Diagnosed with `docker system df`, freed with `docker builder prune`/`docker system prune`, and lx1's disk was also resized from 29GB to 88GB via `qm resize` plus `growpart`/`pvresize`/`lvextend`, for lasting headroom rather than a one-time fix.
- **`KnexTimeoutError` during database migration**: Medusa v2's modular migration opens many parallel connections, and the client-side Knex pool's low default `max` was exhausted well before Postgres's own `max_connections: 100` — confirmed by first ruling out CPU/RAM as the bottleneck via `docker stats` before touching any configuration. Fixed by raising `databaseDriverOptions.pool.max` to `50` in `medusa-config.ts`.
- **A duplicate `max` key survived a merge**: a parallel session had independently applied the same pool fix with a different value (`max: 20`); resolving the resulting Git merge conflict by hand in a text editor removed only the conflict markers, leaving both keys present. Since JS/TS object literals silently let the later key win with no syntax error, the pool was effectively still `20` until this was caught and the duplicate removed, keeping `max: 50`.
- **Backend TypeScript build failed after that same merge**: the merge/edit history had also dropped the non-null assertions (`!`) on `storeCors`, `adminCors`, and `authCors`, which strict TypeScript requires since `process.env.X` is typed as possibly `undefined`. Fixed by restoring the `!` assertions.
- **Local repository divergence caused a rejected push**: a stray, outdated `~/es1` clone — created by accident and distinct from the actual working copy at `~/apps/es1` — had been worked in during one session, causing the two local histories to diverge. Diagnosed by comparing `git remote -v` and `git log` between both directories, confirmed `~/apps/es1` was authoritative and already up to date, and deleted the orphaned `~/es1` copy to prevent a repeat.
- **Storefront build failed with `UNABLE_TO_VERIFY_LEAF_SIGNATURE`**: Next.js's static generation fetches the real backend over HTTPS during the build, and while the internal CA had been installed at the OS level (`update-ca-certificates`), Node.js maintains its own separate certificate store that ignores the OS trust store entirely. Fixed by setting `NODE_EXTRA_CA_CERTS` to point at the installed CA file, in both the build and production stages — the running storefront also needs it at runtime for its own server-side fetches to the backend.
- **Storefront runtime error: `Cannot find module './check-env-variables'`**: the production Dockerfile stage copied `next.config.js` but not the auxiliary `check-env-variables.js` file it depends on. Fixed by adding the missing file to the production `COPY` step.
- **Storefront runtime error: missing `ansi-colors` module**: in an npm workspaces monorepo, some dependencies get hoisted up to the root `node_modules`, and reinstalling dependencies from scratch inside an isolated production stage couldn't resolve them. Fixed by copying the already-built `node_modules` directly from the build stage into production instead of reinstalling.
- **Storefront failed its own startup environment-variable check despite a successful build**: `check-env-variables.js` re-validates `NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY` at server start, not only at build time, so the value already baked into the client bundle wasn't sufficient on its own. Fixed by also adding the same key as a runtime environment variable in the production `docker-compose.yml`.

## Final Result

- `es1` (10.0.20.92) — Medusa v2 backend, PostgreSQL, and Redis running in production containers, backend image built and pulled from Harbor, database migrated and seeded, admin user created and confirmed reachable.
- Next.js storefront running alongside the backend, built with a real Publishable API Key, serving the storefront at `https://es1.pymesis.lab/` with the Medusa Admin still reachable at `/app` — both confirmed working through Nginx's path-based routing over HTTPS with the internal CA certificate.
- Full Gitea Actions → Harbor pipeline validated end-to-end for a real multi-image application: both `es1-backend` and `es1-storefront` build and push cleanly on every push to `main`.
- Zabbix, Wazuh, and GLPI agents installed and confirmed reporting; weekly Restic backup of the Postgres dump and the production compose file configured and pushed to `bk1` at `/mnt/backups/repos/es1`.
- As a side effect of this project, an unrelated Harbor outage (Project 11) was discovered and fully resolved, including rotating the exposed robot-account credential and moving Harbor's install directory to a persistent path.

## Pending

- None — the project closed complete: backend, storefront, HTTPS, CI/CD, monitoring, and backup are all functioning end-to-end.

## Cross-References

- CI/CD pipeline built in [Project 11 — Harbor and CI/CD Installation](11-harbor-cicd-installation.md): es1 reused the existing `pymesis` Harbor project and `robot$gitea-ci` account, and this project's troubleshooting incidentally fixed a `/tmp`-installation outage in that same host.
- Backup pattern consistent with [Project 5.1 — Restic Configuration](05-1-restic-configuration.md), using the lab-wide standardized path `/mnt/backups/repos/<vm>`.
- Positions es1 as the first realistic migration candidate for Project 15 — K3s Single-Node Installation, given its clean separation between backend and frontend services.

---

[← **Previous:** Project 12 — ERP Migration (odoo2)](12-odoo-17-18-openupgrade-odoo2.md) | [**Next:** Project 14 — Private LLM & n8n (llm1, n8n1) →](14-private-llm-llm1.md)