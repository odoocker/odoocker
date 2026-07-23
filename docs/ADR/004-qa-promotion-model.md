# ADR 004: QA promotion model — per-repo `qa` branches + manifest + AgenticOS-routed failure triage

**Status:** Accepted (2026-06-25)
**Context:** Grove deployment pipeline across 3 repos (this one, `grove-sites`, `grove-odoo-modules`). Forced by the 2026-06-24/25 incident where QA pulled a week-old frontend `:latest` image while Josh's local OrbStack ran current code — multi-repo coordination broke down because nothing was the single source of truth for "what combo is in QA."

## Decision

Adopt a per-repo `qa` branch model where each upstream repo publishes immutable SHA-tagged images on every `qa` push, and `odoocker-goldberrygrove` holds a **release manifest** (`infra/release-manifest.yaml`) that pins which specific SHAs are deployed to the QA environment. Promotion to prod happens by merging `qa → main` in odoocker (which carries the validated manifest values to main).

Automated smoke tests gate promotion. Failures route to AgenticOS Dev Agent via a Paperclip routine webhook for `diagnose + draft PR` triage. Human reviews the draft PR and decides whether to merge.

## Context

Three repos contribute to any QA deploy:

| Repo | Produces | Deploy mechanism |
|---|---|---|
| `grove-sites` | 4 frontend Docker images (hub, goldberry, ggg, nursery) — matrix-built from one commit | GHCR pull via compose |
| `odoocker-goldberrygrove` | grove-odoo Docker image + the orchestration (TF env, compose, workflows) | GHCR pull via compose; TF apply for infra |
| `grove-odoo-modules` | Custom Odoo addons (no image — git ref consumed by git-sync) | git-sync at runtime |

Before this ADR, there was no synchronizing layer between them. `:latest` floated independently in each repo; the QA env pulled whatever `:latest` happened to point at when the deploy ran. The 2026-06-24/25 incident exposed the failure mode: a frontend image from `grove-sites` main last built on 2026-06-17 (because subsequent commits to grove-sites main only touched workflow files, which the Docker workflow's path filter excluded) was pulled by a QA deploy a week later; the QA env didn't match Josh's local OrbStack at all.

The deeper symptom: there was no single artifact that answered "what code is in QA right now?" and therefore no audit trail when QA found a bug.

## Alternatives considered

| Option | Why not |
|---|---|
| **Model A — per-repo `qa` branches + floating `:qa` image tag** | Race conditions when multiple repos move in the same window. No record of "which combo was tested together." The 2026-06-24 incident is the exact failure mode this still allows. |
| **Model C — per-PR preview environments for all 3 repos** | Over-engineering for solo-dev. `grove-sites` already has `preview-up.yml` for per-PR previews; layering C on top of B for grove-sites is a reasonable LATER addition. Building per-PR preview infra for the other 2 repos is months of work that doesn't address the multi-repo coordination problem. |
| **Webhook from upstream → odoocker auto-bump** | Too noisy. Every grove-sites qa push would auto-bump odoocker's manifest. Batched human-gated bumps (the chosen Option B for the bump trigger) preserve agency and let multiple upstream changes land in one QA cycle. |
| **Auto-merge after smoke pass** | Risk of false-negative smoke + silent prod break. The smoke test catches obvious breakage; subtle visual or UX bugs need human eyes. Auto-merge removes the eyes. |
| **Open `qa-broken` GH issue + `@claude` mention via Claude Code Action** | Works, but bypasses the existing AgenticOS / Paperclip platform (already operational, already has the Dev Agent role configured, already has the GitHub App with PR-write permissions). Using Paperclip's routine webhook keeps work-routing logic in the AgenticOS platform where the rest of the agent-orchestration lives. |
| **No automated failure triage; manual debug only** | The 2026-06-24 session showed how much time goes into "what does the failure log say, where do I SSH, what's the env state." Automating the first-pass triage saves the agent-equivalent cost on every QA failure; humans focus on the "do I accept the proposed fix" decision. |
| **Auto-fix without draft-PR gate** | One catastrophic auto-merge is worse than 100 manual reviews. Draft PR + human merge is the right safety boundary for agent-authored prod changes. |

## What this wins

- **Multi-repo deploy state is auditable.** The manifest file in odoocker's `qa` branch IS the answer to "what's in QA right now." Same file in `main` IS the answer to "what's in prod." Git history of the manifest IS the deploy timeline.
- **Promotion is intentional.** Three gates (manifest bump PR review, smoke test pass, manual qa→main PR with checklist) catch different failure modes.
- **Failure triage happens automatically without bypassing safety.** Dev Agent investigates, drafts a PR, posts findings. Human merges or rejects.
- **Bisecting QA failures is trivial.** Manifest git history shows every combo tested; binary search across manifest commits finds the regression-introducing upstream SHA.
- **Per-source granularity matches unit of intent.** When Josh says "test this grove-sites work," he means all 4 frontends from the same commit, not 4 separate decisions — the 3-entry manifest matches that.

## What this does not win

- **Doesn't reduce time-to-deploy.** Per-repo gates add steps. A QA cycle is ~5 actions (push to upstream qa, build completes, bump manifest, merge PR, deploy fires) instead of 1 (push to main).
- **Doesn't handle multiple concurrent QA cycles.** Single shared QA env today. If a second tester wants to validate a different combo while the first is still in flight, they have to wait or destroy. Per-PR preview envs (deferred) are the long-term answer.
- **Doesn't prevent upstream-repo image-build failures.** If `grove-sites:qa` push fails to build, the manifest can't pin a SHA from that commit — but neither could a floating `:qa` tag, so this isn't a regression.
- **Doesn't shorten the cross-repo coordination latency.** Three repos in the loop = three places to push, three build cycles. Inherent to the multi-repo split (decided in [ADR 001](./001-separate-modules-repo.md) and downstream).
- **Doesn't define a hotfix path.** Hotfix that bypasses QA is intentionally out of scope for v1 — will be designed when first incident demands it.

## Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│ UPSTREAM REPOS — each has a long-lived `qa` branch                     │
│                                                                        │
│   grove-sites:qa            push → matrix build → GHCR                 │
│       └─ grove-hub:sha-<commit>                                        │
│       └─ grove-goldberry:sha-<commit>                                  │
│       └─ grove-ggg:sha-<commit>                                        │
│       └─ grove-nursery:sha-<commit>                                    │
│       (NO floating :qa tag — manifest is the only thing that pins)    │
│                                                                        │
│   odoocker:qa (this repo)   push → docker-odoo build → GHCR           │
│       └─ grove-odoo:sha-<commit>                                       │
│                                                                        │
│   grove-odoo-modules:qa     push → (no build; git ref is the artifact)│
└───────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌───────────────────────────────────────────────────────────────────────┐
│ ODOOCKER (this repo) — orchestrates the QA combo                       │
│                                                                        │
│   scripts/bump-qa-manifest.sh                                          │
│     reads latest :sha-<commit> from each upstream qa branch            │
│     writes infra/release-manifest.yaml                                 │
│     opens PR to odoocker:qa                                            │
│                                                                        │
│   Human reviews the manifest diff PR + merges                          │
│                                                                        │
│   qa-deploy.yml fires on push to odoocker:qa                           │
│     reads release-manifest.yaml                                        │
│     templates SHAs into compose env vars                              │
│     TF apply → droplet + cloud-init → grove-ready sentinel             │
│                                                                        │
│   qa-smoke.yml runs against the deployed URLs                          │
└───────────────────────────────────────────────────────────────────────┘
                                  │
                  ┌───────────────┴───────────────┐
                  ▼                               ▼
      [ smoke pass ✅ ]                  [ smoke fail 🚨 ]
                  │                               │
                  ▼                               ▼
   Discord post: "QA ready"     Discord post: "smoke failed"
                  │                               │
                  │                               ├─► GH issue opened
                  │                               │   (audit trail; label qa-broken)
                  │                               │
                  │                               └─► Paperclip routine webhook fired
                  │                                   (CF Access service token in headers,
                  │                                    HMAC-signed body)
                  │                                   │
                  │                                   ▼
                  │                            Paperclip creates run → issue
                  │                            assigned to Dev Agent
                  │                                   │
                  │                                   ▼
                  │                            Dev Agent heartbeat picks up
                  │                            brainstorm(Claude) → execute(Codex)
                  │                                   │
                  │                                   ▼
                  │                            Draft PR back to relevant repo
                  │                            via AgenticOS Developer App's
                  │                            installation token
                  │                                   │
                  ▼                                   ▼
   Human opens qa→main promotion PRs       Human reviews draft PR
   (per-repo, manual, with checklist)       marks ready + merges
   → main branches updated                  → next qa cycle iterates
   → main pushes trigger :latest publish
   → (future M4) prod deploy
```

## Branch semantics

| Branch | Purpose | Image tag produced | Deploy target |
|---|---|---|---|
| Any feature branch | Work in progress | None (per-PR build only, no publish) | grove-sites: per-PR preview droplet (existing). Others: no preview yet. |
| `qa` (each repo) | Code under QA validation | `:sha-<commit>` only — no floating tag | odoocker `qa` push triggers `qa-deploy.yml` |
| `main` (each repo) | Validated code | `:sha-<commit>` + `:latest` | odoocker `main` push triggers prod deploy (when M4 ships) |

The manifest pins by `:sha-<commit>` exclusively. `:latest` is preserved for backward compatibility with anything that pulls "latest" manually, but production deploys read SHAs from the manifest, not `:latest`.

## CF Access integration (the one real wrinkle)

Paperclip runs on the AgenticOS droplet behind Cloudflare Access (Google SSO). A GitHub Actions runner POSTing to a Paperclip routine webhook URL gets a 302 to `cloudflareaccess.com/login` instead of reaching Paperclip — not a network error, an Access gate.

**Solution:** a Cloudflare Access service token, terraformed alongside Paperclip's Access app:

```hcl
resource "cloudflare_zero_trust_access_service_token" "qa_triage" {
  account_id           = var.cloudflare_account_id
  name                 = "odoocker-qa-triage"
  min_days_for_renewal = 30
}

resource "cloudflare_zero_trust_access_policy" "qa_triage_svc" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.paperclip.id
  name           = "Allow odoocker-qa-triage service token"
  precedence     = 1
  decision       = "non_identity"
  include { service_token = [cloudflare_zero_trust_access_service_token.qa_triage.id] }
}
```

The workflow sends `CF-Access-Client-Id` + `CF-Access-Client-Secret` headers alongside the HMAC-signed body. Cloudflare validates the token (gate pass); Paperclip validates HMAC (auth). Two independent gates, both pass = work created.

## Secrets inventory (Infisical `grove-odoocker/prod`)

| Secret | Purpose | Source |
|---|---|---|
| `PAPERCLIP_QA_TRIAGE_WEBHOOK_URL` | Routine's public webhook URL | Paperclip API response when routine trigger created |
| `PAPERCLIP_QA_TRIAGE_WEBHOOK_SECRET` | HMAC signing secret | Same response |
| `PAPERCLIP_QA_TRIAGE_CF_CLIENT_ID` | CF Access service token public ID | TF output of `cloudflare_zero_trust_access_service_token.qa_triage` |
| `PAPERCLIP_QA_TRIAGE_CF_CLIENT_SECRET` | CF Access service token secret | Same TF output |

## Branch protection rules

Same ruleset across all 3 repos. Terraformed via the `github` provider (the AgenticOS-side TF env already houses cross-repo policy, so it owns this too — gives a single place to read "what protects what").

**`main` branch:**

| Rule | On? |
|---|---|
| Require PR before merging | yes |
| Require status checks to pass | yes — **minimal set only**: lint + type check + build. Trivy / Backend smoke test deliberately NOT required (they're slow + can flake and would block legitimate fix-PR velocity) |
| Block force-push | yes |
| Block deletion | yes |
| Required reviewers count | 0 (solo dev today; flip to ≥1 when team grows) |
| Allow admin override | yes (this is the hotfix path — see below) |
| Required signed commits | no (incompatible with Docker-sandbox agent commits per `feedback_1password_ssh_in_docker`) |

**`qa` branch:** Same ruleset (same rationale). Required-checks list is the lighter set; admin override is for "I need to re-run a smoke iteration fast" velocity.

The minimal-required-checks call is informed by the 2026-06-24/25 session, where heavy required checks blocked fix-PRs and we admin-overrode ~8 times. The right answer isn't weaker protection; it's "don't require slow/flaky checks as MERGE BLOCKERS, but DO require them as visible signals."

## Concurrency model

Single shared QA env. Serial QA cycles. The 5-person QA team is read-only browsers — they consume the env, don't operate it. State conflict between testers is limited to Odoo admin (rare) since frontend browsing is per-session.

Three concurrency rules make the serial model robust:

1. **One bump PR in flight at a time.** `scripts/bump-qa-manifest.sh` checks for an open PR with label `qa-manifest-bump` before opening a new one. Refuses with a pointer to the existing PR if one exists. Prevents the "two stacked bumps land back-to-back, second cancels first's deploy" failure mode.
2. **`qa-deploy.yml` uses `concurrency.cancel-in-progress: true`** (already set). Newer pushes supersede older deploys. Added: cancel step destroys the in-flight droplet on cancellation so no half-provisioned droplets accrue cost.
3. **`qa-smoke.yml` only runs on `qa-deploy.yml` SUCCESS** (via `workflow_run` trigger with conclusion filter). No smoke results from never-finished deploys.

**Explicit non-decision:** no per-tester locking mechanism. The Discord deploy post is the social-layer signal — testers coordinate among themselves. When the team scale (or collision frequency) demands it, the answer is per-PR preview envs, not env locking.

## Bug inflow channel

Testers don't touch GitHub. The flow:

1. `qa-deploy` posts URLs to a dedicated Discord channel, message becomes a thread anchor.
2. Bot/automation marks the post with a reaction (`⏳` queued → `🧪` ready for tests).
3. Testers reply in-thread with bug reports (free-form text + screenshot) or `✅` reactions on areas they've validated.
4. Josh translates bug-report messages into GH issues on the appropriate repo. (Possibly automated later — a Discord-bot-to-GH-issue bridge — but manual for v1.)
5. "Looks good, promote" is a social-layer signal in the thread; no formal vote, no required reviewer count.

Dev Agent stays strict: **auto-triage fires only on smoke-test failures**, not on tester-reported bugs. Tester bugs are usually subjective ("the spacing looks off") and require human judgment about scope + priority before any fix attempt.

## Hotfix path

When prod breaks (post-M4), the documented hotfix path is **admin override on main**, not a dedicated `hotfix/` branch model. Rationale: the QA team isn't on-call; the validation gate that the qa→main flow provides is irrelevant at 3am.

A short `docs/runbook/HOTFIX.md` documents the ceremony:

1. Decide it's actually a hotfix (broken vs degraded vs annoying).
2. Branch off `main`, write the minimal fix.
3. Open PR to `main`, label `hotfix`, body explicitly says "BYPASSES QA — prod incident #N".
4. Admin-merge, overriding the QA-bypass status check.
5. Wait for prod deploy + verify the bleeding stopped.
6. File a post-incident GH issue describing why QA was bypassed + what we'd do differently.
7. Post to the QA Discord channel that the QA cycle was skipped (so testers know the deployed state changed without their validation).

Dev Agent triage does NOT fire on hotfix PRs — the hotfix moment wants zero friction; agent-in-the-loop adds cognitive overhead at the worst time. Post-incident agent analysis is where the value is.

## Data lifecycle

| Aspect | Decision |
|---|---|
| **Seed data** | Grove-specific dataset in the `grove-odoo-modules` repo as an Odoo data module (`grove_qa_seed`). Init-on-fresh-DB only. Loaded by an init container in compose that exits after seeding. Maintained as real Grove products evolve. |
| **Persistence within a cycle** | Postgres data persists for the lifetime of the droplet. Multiple testers see each other's test orders (5-person team finds this useful for spot-checking each other's work). |
| **Reset trigger** | Every deploy wipes the DB. Manifest bump = fresh Postgres = canonical seed. Eliminates "is this bug from THIS deploy or leftover from yesterday?" ambiguity. |

Ghost blog content: `GHOST_KEY_GOLDBERRY` continues to point at LIVE `blog.goldberrygrove.farm` (read-only); QA testers see real blog content without risk of polluting prod.

## `grove-odoo-modules` wiring

The manifest's `grove-odoo-modules: sha-XXX` value flows into the running container as the git-sync ref:

```
manifest → bump-qa-manifest.sh → TF_VAR_gitsync_ref
       → cloud-init.yaml.tpl writes GITSYNC_REF=sha-XXX to /etc/grove/.env
       → docker compose passes GITSYNC_REF to git-sync sidecar
       → git-sync clones https://github.com/Goldberry-Playground/grove-odoo-modules at sha-XXX
       → exits (GITSYNC_ONE_TIME=true; no continuous polling in QA)
       → Odoo reads /workspace/current/* as addons
```

`GITSYNC_ONE_TIME=true` is the key — prevents drift over the cycle. The pinned SHA stays pinned until the next manifest bump.

**git-sync auth:** uses the AgenticOS Developer App's installation token (the same one Dev Agent uses for PR-back). No additional GitHub PAT to manage. Token is short-lived (installation tokens expire hourly); the app handles renewal.

## Observability

Three layers, each with a real tool rather than the "SSH and look" pattern:

| Layer | Tool | Why |
|---|---|---|
| **Container/cloud-init logs** | Loki (centralized aggregator) | Queryable by URL/time/container without SSH. Hosted via Grafana Cloud free tier (50GB / 14d) or self-hosted Loki — decide at implementation time. Labels: `env=qa|prod|local`, `service=<container_name>`. |
| **Droplet + container metrics** | Prometheus + Grafana + cadvisor + node-exporter, all in compose on the droplet | Self-contained, no external dependency. ~200MB more RAM — **probably bumps droplet from `s-2vcpu-4gb` to `s-4vcpu-8gb`** (~$48/mo vs current $24/mo). Grafana exposed at `grafana.qa.gatheringatthegrove.com` via new Caddy vhost. |
| **Frontend user-visible errors** | Sentry on each Next.js frontend | DSN injected at build time. Each tenant a separate Sentry project. Source maps uploaded for decoded stack traces. Tester bug reports gain "Sentry event ID" context automatically. |

Secrets (Sentry DSN, Grafana credentials, Loki tokens) follow the existing Infisical pattern from [ADR 003](./003-infisical-secrets-broker.md).

Observability is intentionally NOT a phase-1 deliverable — it's significant work (~1-2 days) and the basic SSH path works for the immediate need. Land it after the core QA pipeline is validated.

## Smoke test scope

`qa-smoke.yml` runs at **Tier 2**: HTTP probe + content matcher per URL.

```
For each of [qa, goldberry.qa, ggg.qa, nursery.qa, odoo.qa] .gatheringatthegrove.com:
  1. Assert HTTP 2xx
  2. Assert response size > N bytes (catch 2xx error pages)
  3. Assert tenant-specific marker string present in response body:
     - hub: "Gather at the Grove"
     - goldberry: "Goldberry Grove Farm"
     - ggg: "GGG Woodworking"
     - nursery: "At The Grove Nursery"
     - odoo: "<title>Odoo</title>" or login form marker
```

**Failure threshold:** any-assertion-fail = smoke-fail. Real transients handled at the curl level (`--retry 2 --retry-delay 3`); smoke-level is strict.

**Tier graduation roadmap:**
- **Tier 3** (next PR series after Tier 2 ships): also parse hub HTML for CSS/JS chunk URLs and probe those (would have caught the "stale `:latest` so assets 404" failure mode from 2026-06-24/25).
- **Tier 4** (Playwright/headless): deferred. When you want to reduce tester load OR add visual regression diffs, this is the answer.

Markers inline in the workflow YAML for v1; factor out to `infra/qa-smoke-checks.yaml` when the list grows past ~10 entries.

## Bump script edge cases

**Upstream build failed:** script refuses to bump if any source's qa HEAD doesn't have a corresponding image build. Hard-fails with a pointer to the upstream workflow that needs to be fixed.

```
ERROR: grove-sites qa HEAD (sha-abc1234) has no image build.
  Check: https://github.com/Goldberry-Playground/grove-sites/actions
  Then re-run: make bump-qa-manifest
```

Escape hatch: `--force-stale-grove-sites` (and equivalents) for the rare case where you intentionally want to test new grove-odoo against last-week's grove-sites. Documented in `--help`, never the default.

**Two bumps in flight:** check for an open PR with label `qa-manifest-bump` before opening a new one. Refuse if one exists. Operator closes/merges the existing one first.

**WIP commits at qa HEAD:** no explicit skip logic for v1. Discipline-only ("don't bump when you're mid-WIP"). Add a `WIP:` / `draft:` prefix skip later if it becomes a real problem.

## Sequencing dependencies

This design only fully lights up when these are all true:

1. **AgenticOS Developer App installed on `Goldberry-Playground` org with `odoocker-goldberrygrove` in selected repos.** Without this, Dev Agent's PR-back fails. Verified at design time: app exists (#4134853, per `wiki/Software/AgenticOS.md`), org install scope needs explicit confirmation per-repo.
2. **AgenticOS token-broker + Dev Agent GitHub-auth rollout complete** (AgenticOS Asana #204). Until this lands, Dev Agent surfaces findings as Paperclip-side comments only; PR-back doesn't happen.
3. **`agent-house-rules.md` updated to specify "open PRs as drafts; human marks ready."** Current rules say "always branch + PR" but don't constrain draft vs ready. The draft-PR contract is the safety boundary for this design; it must be explicit.
4. **CF Access service token provisioned + 4 secrets seeded in Infisical `grove-odoocker/prod`.**

Until all 4 are true, the smoke-failure path partially degrades: GH audit issue still opens (always works), Paperclip routine fires (works once CF access token is in place), but agent action stops at "post findings" instead of "draft PR" (requires #1 + #2 + #3).

## Implementation phases

Phases 1-5 are the **MVP** that lets the QA pipeline work end-to-end (commits to qa branch → SHA-pinned deploy → smoke gate → human promotion). Phases 6-10 are the **AgenticOS integration** that adds the agent-driven failure triage. Phases 11-13 are the **hardening** layer (observability + Tier 3 smoke + production deploy). Per [2026-06-25 priority pivot](#priority-pivot), hardening is deferred until a prod version of the website exists.

### MVP — Phase 1 through 5 (odoocker-internal, plus minimal upstream-repo work)

| Phase | Deliverable | Repo(s) |
|---|---|---|
| 1 | Per-repo `qa` branch created + branch protection ruleset (terraformed via `github` provider) | all 3 |
| 2 | Image build workflow modified to publish `:sha-<commit>` on `qa` push (path filters preserved) | grove-sites, odoocker |
| 3 | `infra/release-manifest.yaml` + parser in `qa-deploy.yml` (3 entries, branch-as-env) | odoocker |
| 4 | `scripts/bump-qa-manifest.sh` + `make bump-qa-manifest` target. Includes refusal-on-broken-build + open-PR-in-flight check | odoocker |
| 5a | `qa-smoke.yml` workflow — Tier 2 (HTTP + content marker per URL) + Discord post | odoocker |
| 5b | Grove seed module (`grove_qa_seed`) defining fixture products | grove-odoo-modules |
| 5c | git-sync sidecar wired to manifest's `GITSYNC_REF` with `GITSYNC_ONE_TIME=true` | odoocker |

### AgenticOS integration — Phase 6 through 10

| Phase | Deliverable | Repo(s) |
|---|---|---|
| 6 | CF Access service token TF + secret seeding to Infisical | AgenticOS-side TF env |
| 7 | Paperclip routine created (via dashboard or API), webhook URL + secret seeded | manual / AgenticOS-side |
| 8 | Smoke-failure step in `qa-smoke.yml` fires routine webhook + opens GH issue with `qa-broken` label | odoocker |
| 9 | `agent-house-rules.md` line added: "Open PRs as drafts; human marks ready" | AgenticOS-side |
| 10 | End-to-end test: induce a smoke failure, verify Dev Agent opens a draft PR back via App's installation token | all |

### Hardening — Phase 11+ (deferred per priority pivot)

| Phase | Deliverable |
|---|---|
| 11 | Observability stack: Loki shipping + on-droplet Prometheus/Grafana + Sentry on frontends. Droplet size bump to `s-4vcpu-8gb`. |
| 12 | Smoke Tier 3: HTML parse + asset-chain probe (would have caught the stale-`:latest` failure mode from 2026-06-24/25). |
| 13 | Production deploy pipeline (M4): main pushes → prod deploy. Reuses the manifest mechanism on the `main` branch's manifest value. |
| 14 | `docs/runbook/HOTFIX.md` written. Required before any prod incident. |
| 15+ | Pain-driven additions: per-PR preview envs for odoocker + grove-odoo-modules, `make promote-qa` Option β, narrowly-scoped agent auto-merge, multi-tester concurrent envs, Discord→GH bug bridge bot. |

## Priority pivot

Recorded 2026-06-25 mid-design: before hardening (phases 11+), the immediate priority is **getting the QA website previews actually deploying + serving correctly in DigitalOcean** so the team can triage the cross-component integrations:

- Odoo ↔ headless frontends (REST API consumption via `ODOO_API_URL`)
- Ghost blog ↔ headless frontends (Content API consumption via `GHOST_KEY_GOLDBERRY`)
- nginx/Caddy routing across all tenant subdomains
- git-sync delivering modules into the running Odoo

Hardening this design (Loki, Prometheus, Sentry, Tier 3 smoke, etc.) only justifies its cost AFTER prod exists. Until then, ship Phase 1-5 (MVP) + Phase 6-10 (AgenticOS) and let real usage surface the next priorities.

## Open follow-ups

Items NOT closed by this ADR's design walk; landing them is the next ADR's job (or "decide when pain warrants"):

- **GH-issues sync routine (AgenticOS Asana Step 9) collision.** When that ships, the `qa-broken` audit issues would also get synced + routed to Dev Agent unless explicitly excluded. Either the sync excludes `qa-broken` OR the audit issue uses a different label and the sync ignores it. Decide when Step 9 lands.
- **Per-PR preview envs for odoocker + grove-odoo-modules.** Pain-driven add. `grove-sites` already has previews via `preview-up.yml`; the others don't.
- **`make promote-qa` Option β.** Opens all 3 promotion PRs in one shot. Skip until manual α gets tedious.
- **Full auto-merge for narrowly-scoped fix patterns.** "If smoke failure is HTTP 502 on tenant URL and agent's diagnosis matches port-mismatch signature, allow auto-merge." Defer until trust + pattern library exists.
- **WIP-skip in bump script.** Add a `WIP:` / `draft:` commit prefix skip when accidentally bumping mid-WIP becomes a real problem.
- **Discord-bug-report → GH-issue bridge bot.** Currently Josh translates Discord bug reports into GH issues by hand. A bot that watches the QA channel for messages starting with 🐛 and creates GH issues from them — useful at higher tester volume.
- **Multi-tester concurrent envs.** Single shared env today is fine for 5 read-only testers. Triggers a redesign at team growth OR when shared-env collision becomes painful.
