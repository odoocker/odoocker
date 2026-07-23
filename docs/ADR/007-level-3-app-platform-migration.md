# ADR 007: Level 3 — migrate QA + prod to DO App Platform + Managed Postgres

**Status:** Accepted (planning)
**Date:** 2026-06-26
**Deciders:** Josh Dunbar
**Implementation target:** start after 2026-06-27 21:30 UTC (LE rate-limit clears + today's PRs validate end-to-end)
**Supersedes none; complements:** [ADR-005](./005-qa-cert-resilience-stack.md) (cert resilience layers stay; some pieces become inert as the new arch eliminates the failure modes they protect against)

## Context

Today's QA env is a single droplet running everything in docker-compose: Caddy + Postgres + Odoo + 4 frontends. Tonight (2026-06-26) we shipped a 4-PR cert resilience stack (PR-A through PR-D, plus 4 supporting PRs) that solved a recurring "deploy stuck for 24h on LE rate limits" problem. The fix worked, but exposed a deeper truth:

**The monolithic-droplet pattern accumulates fragility.** Every cert renewal, every droplet recreate, every compose-file change has ripple effects across all 6 services. Tonight alone surfaced bugs in: cloud-init YAML parsing, odoo entrypoint substitution, Caddyfile site-block syntax, caddy-dns/digitalocean TXT cleanup, LE rate-limit identifier-set semantics, GH Actions push-vs-dispatch anti-recursion, zsh word-splitting in shell loops, BSD-vs-GNU grep portability, and DO provider's hardcoded 1m delete timeout. Each individually fixable, collectively a fragile pile.

The pragmatic question: do we keep stacking resilience layers on the monolith, or restructure the platform shape to remove the failure modes entirely?

This ADR decides: **restructure.** Move frontends to DO App Platform (managed TLS, auto-deploys from GHCR, zero-downtime). Move Postgres to DO Managed Database (backups, HA, private network). Leave Odoo on a small droplet (it's genuinely hard to run on App Platform: persistent filestore + workers + custom modules + odoorc.sh runtime substitution). One Caddy on that droplet, fronting a single host with one cert.

## Decisions

The brainstorm on 2026-06-26 walked 7 design-tree branches. Recorded here in the order asked:

### D1: Scope — QA + prod symmetry

**Decision:** Build the new pattern for QA first, validate ~2 weeks, replicate for prod.

**Why:** Matches the stated pipeline-uniformity goal (`local → QA → prod, same shape`). A QA env that doesn't match prod defeats the point of QA.

**Rejected alternatives:**
- *QA only, prod stays monolithic:* breaks the uniformity goal; tonight's whole exercise was driven by "QA needs to work like prod will."
- *Prod only, QA stays scratch:* "QA is dev-grade, prod is production-grade" is a valid philosophy but not yours.
- *Don't do Level 3:* tonight's PRs structurally solved the cert problem. If Level 3 was *just* about certs, stopping there would be right. But Level 3 is about long-term ops burden, which compound.

### D2: Compute platform — DO App Platform

**Decision:** Frontends run on DO App Platform.

**Why:** Already deep in DO ecosystem (DNS, tokens, Spaces, secrets in 1Password labeled `GoldberryGrove Infra`). App Platform handles TLS for you — eliminates Caddy for the 4 frontends entirely. Auto-deploys from GHCR (no SSH, no compose, no droplet management). Zero-downtime deploys built-in. No new platform to learn.

**Rejected alternatives:**
- *Fly.io:* best-in-class for global edge. Adds a new provider to secrets/auth landscape. Worth it only if you need multi-region — you don't (yet).
- *DO Managed Kubernetes (DOKS):* overkill for 4 small Next.js apps + 1 Odoo. Real value emerges at ~15+ services or strong multi-tenant isolation.
- *Render / Vercel:* would require rebuilding the DO-tightly-coupled secret + DNS plumbing. Not enough savings to justify the rebuild cost.

### D3: Database — DO Managed Postgres

**Decision:** Postgres runs on DO Managed Database. All envs (QA + prod).

**Why:** Backups + point-in-time recovery built-in (critical for prod). Optional HA standby. Connects via private network (no public exposure). Same DO billing, same tokens. Odoo connects via `DATABASE_URL` env var — trivial swap from current docker-compose `postgres` service name.

**Rejected alternatives:**
- *Self-hosted on the Odoo droplet:* cheaper ($0 added) but backups DIY, no HA, scaling means droplet resize. Real ops burden you currently pay invisibly.
- *Hybrid (prod managed, QA self-hosted):* saves $15/mo on QA but breaks pipeline uniformity. Defeats the point.
- *Neon / Supabase:* solid but adds new auth surface + billing. DO Managed PG is good-enough and already in the ecosystem.

### D4: Migration sequencing — parallel cutover

**Decision:** Build new QA env from scratch at `infra/terraform/environments/qa-app-platform/`. Old QA keeps serving while we validate the new shape (~2 weeks). DNS flip is the atomic cutover.

**Why:** Most ops-conservative. If new env breaks during validation, just don't flip DNS. Briefly costs ~2× ($24 old + ~$47 new) for the validation window — acceptable.

**Rejected alternatives:**
- *In-place evolution:* intermediate states are awkward ("half on droplet, half on App Platform, all on same domain"). Real risk of getting stuck halfway.
- *Big-bang rewrite:* no fallback if cutover fails. Only sensible if current env is already broken (it isn't).
- *Side-by-side forever (some tenants on each):* defeats pipeline uniformity.

### D5: Local dev — keep docker-compose

**Decision:** docker-compose stays for local (`make all-up` still works). App Platform is cloud-only (QA + prod).

**Why:** Local doesn't need TLS (Next.js dev mode handles HMR), doesn't need managed PG, doesn't need horizontal scaling. The shape that needs to be uniform is *QA → prod* (workflow, components, images) — not local. Local needs to be FAST (compose up in 30s), and App Platform doesn't deliver that locally.

**Rejected alternatives:**
- *`doctl apps` for local:* limited emulation, slower than compose.
- *Drop docker-compose entirely:* every code save = cloud deploy = slow + $$.

### D6: Budget envelope — tight QA / comfortable prod

**Decision:**

| Env | App Platform | Managed PG | Odoo droplet | Volume | **Total** |
|---|---|---|---|---|---|
| **QA Level 3** | 4 × $5/mo basic = $20/mo | dev tier $15/mo | s-1vcpu-2gb $12/mo | $0.10/mo | **~$47/mo** (2× today's $24) |
| **Prod Level 3** | 4 × $12/mo pro = $48/mo | basic $30/mo | s-2vcpu-4gb $24/mo | $0.10/mo | **~$102/mo** (vs ~$48-96 today) |

**Why:** QA tolerates dev-tier PG (test infra; if it crashes, redeploy). Prod gets real backups via basic-tier. HA standby ($30/mo extra on PG) deferred until traffic warrants it.

**What the doubled cost buys:**
- Managed PG backups + point-in-time recovery (vs DIY snapshots)
- Zero-downtime deploys (vs current compose-up that briefly drops requests)
- Auto-TLS for frontends (vs the cert dance tonight's PRs were unwinding)
- Per-app independent scaling
- Better incident isolation (one frontend dying doesn't take down Odoo)

**Rejected alternatives:**
- *Match today's spend (~$24 QA):* keep PG on droplet, asymmetric to prod, breaks D1.
- *Production-grade everywhere (~$100 QA):* overkill for test infra.
- *Stop at Level 2:* valid if $/mo is the binding constraint; signals "don't do Level 3."

### D7: Trigger — start after today's PRs validate

**Decision:** Wait for tonight's PR cascade (#95-#102) to validate end-to-end. Specifically: after LE rate limit clears ~21:30 UTC 2026-06-27, a fresh qa-deploy fires (via the auto-sync chain from PR-E #99), the persistent volume gets provisioned, certs issue cleanly, all URLs serve 200/303. Then start Level 3 the next day.

**Why:** Tonight's stack is fresh code, never exercised end-to-end. Level 3 is several days of work. Racing two unverified architectures = doubled blast radius. Validate one, then start the next.

**Rejected alternatives:**
- *Start tomorrow morning (don't wait):* parallel cutover means no conflict, but rollback risk if tonight's PRs need fixes.
- *Next week buffer:* lower velocity, lower decision-fatigue mistakes — defensible but slower.
- *Reactive (when current env breaks):* worst case is you NEED Level 3 during an incident.

## Execution plan

Roughly 5-8 PRs over 1-2 weeks of evening work. Sequenced for safety (each PR independently mergeable, no half-states).

### Phase 1: Scaffold the new TF env (~1 PR, 2-3 hr)

- New directory `infra/terraform/environments/qa-app-platform/`
- TF resources:
  - `digitalocean_database_cluster` (Managed Postgres, dev tier, private network)
  - `digitalocean_droplet` (Odoo only, s-1vcpu-2gb) + same long-lived SSH key pattern as current QA
  - `digitalocean_volume` (Caddy /data, same pattern as PR-A)
  - `digitalocean_app` placeholders (one per frontend; spec files come in Phase 2)
  - DNS records pointing at App Platform default URLs initially (cutover later)
- Cloud-init: same patterns as current QA but stripped of frontend services (only postgres-client + caddy + odoo)
- Compose: only `caddy` + `odoo` services; DB connection via env to managed PG

### Phase 2: App Platform specs per frontend (~4 PRs, 1 hr each)

One PR per frontend (hub, goldberry, ggg, nursery). Each adds:
- `infra/terraform/environments/qa-app-platform/apps/<name>.app.yaml` spec
- Service definition pointing at `ghcr.io/goldberry-playground/grove-<name>:latest`
- Env vars sourced from Infisical (same identity pattern as current QA)
- Health check + autodeploy config
- DNS record `<name>.qa.gatheringatthegrove.com` → App Platform's default URL

Independent + small = easy to review + rollback.

### Phase 3: Migration validation (~2 weeks of soaking, no PRs)

- Old QA + new QA env both running
- Verify each new URL serves correctly
- Verify managed PG performance is acceptable (Odoo connection pool, query latency)
- Verify auto-deploys from GHCR work
- Verify TLS auto-renewal (App Platform handles, but watch for surprises)
- Run smoke tests against new URLs
- Document any gotchas in this ADR or follow-up

### Phase 4: DNS cutover (~1 PR, 30 min)

- Update `digitalocean_record.tenant` resources to point at App Platform URLs (currently pointing at old droplet IP)
- TTL is already 1 min; cutover is ~1 min
- Verify all URLs continue serving 200
- Old droplet keeps running for 24h as instant rollback

### Phase 5: Decommission old QA (~1 PR, 1 hr)

- Delete `infra/terraform/environments/qa/` (or rename to `qa-monolith-deprecated/`)
- Rename `qa-app-platform/` → `qa/`
- Update workflows (`qa-deploy.yml`, `chain-after-image-rebuild.yml`, etc.) to target new env
- Tear down old droplet + volume

### Phase 6: Replicate for prod (timeline TBD)

After QA validates for 2-4 weeks, build `infra/terraform/environments/production/` with the same shape:
- Larger instance sizes
- HA-enabled managed PG
- Same App Platform spec files (likely copied + sized up)
- Same migration sequencing: parallel + DNS cutover + decommission

## Consequences

**Positive:**
- Drop ~80% of compose's moving parts (only Caddy + Odoo on the droplet)
- TLS managed by App Platform = no cert dance for 4/5 services
- Managed PG = backups, replicas, easier scaling
- Each frontend deploys independently (faster CI for single-frontend changes)
- Real pipeline uniformity (App Platform spec is declarative; same shape across envs)
- Most of tonight's PR-A/B/C/D resilience layers become INERT (no Caddy for frontends = no cert rate limits to worry about). The Caddy that DOES remain (in front of Odoo) only has ONE identifier — apex of one hostname — easy on rate limits.

**Negative:**
- Higher cost ($24 → $47/mo QA, $48-96 → $102/mo prod)
- DO App Platform lock-in (less portable than docker-compose)
- Different deploy mechanics (App Platform spec.yaml, not docker-compose.yml)
- Less local-dev parity (mitigated by keeping compose for local)
- Multi-week migration project (during which both envs run; doubled cost)

**Open items:**
- KeyDB + MinIO + Ghost (mentioned in odoocker CLAUDE.md as part of full stack): not in QA today, presumably in prod. Need to decide where each runs:
  - KeyDB: DO Managed Redis (~$15/mo basic) OR keep on Odoo droplet
  - MinIO: DO Spaces (object storage, similar API) OR keep on Odoo droplet
  - Ghost: separate App Platform app per tenant OR continue pointing at live `blog.goldberrygrove.farm`
- Odoo's filestore: needs persistent storage. Currently in the named compose volume `odoo-filestore`. On the new tiny Odoo droplet, this still works (anonymous volume). Could later migrate to DO Spaces for cross-droplet portability, but not urgent.
- Custom domain TLS on App Platform: App Platform issues certs for managed `.ondigitalocean.app` URLs automatically. For custom domains (`goldberry.qa.gatheringatthegrove.com`), App Platform issues LE certs too. SAME potential rate-limit class as today, but: only on first issuance + renewal (2x/year), and only for the custom domain hostnames (not the apex). Acceptable.

## References

- ADR-005 (this PR's sibling) — the cert resilience stack tonight's PRs shipped. Some of those layers become inert under Level 3; document the relationship explicitly.
- ADR-004 — QA promotion model. Level 3 doesn't change the promotion model (per-repo qa branches + manifest); it changes the deployment shape underneath.
- [Memory: pipeline-uniformity-goal](../../../../../../../.claude/projects/-Users-joshuadunbar-Documents-Dev-Projects-gather-at-the-grove/memory/project_pipeline_uniformity_goal.md) — the stated motivation behind D1.
- [DO App Platform pricing](https://www.digitalocean.com/pricing/app-platform)
- [DO Managed Database pricing](https://www.digitalocean.com/pricing/databases)
- [App Platform spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/)

---

## Addendum 2026-06-26: observability stack integration (ADR-008 + design spec)

The original ADR-007 above scoped 3 planes (App Platform + Odoo droplet + Managed PG). The merged ADR-008 (OpenObserve + Keep supersedes ADR-004's Phase-11 Loki/Prom/Grafana/Sentry) + the design spec at `docs/specs/2026-06-26-grove-observability-design.md` add **two more planes** that Level 3 must include from Phase 1:

### Updated topology (5 planes, not 3)

| Plane | Runs | Failure-domain rationale |
|---|---|---|
| App Platform | hub + 3 tenant frontends | DO-managed TLS + per-app isolation |
| Tiny Odoo droplet | Odoo + Caddy + **Beyla eBPF sidecar + OTel Collector** | Single cert, persistent /data volume (ADR-005), eBPF needs `privileged: true` + `pid: host` so it can't go on App Platform |
| DO Managed Postgres | shared instance, per-company data | Backups + PITR + private network |
| **Observability droplet (NEW)** | OpenObserve + Keep + Plausible (prod only) | Own failure domain — monitoring outlives an app-plane outage |
| **AgenticOS droplet (existing)** | Self-hosted Healthchecks dead-man's-switch | Separate failure domain ($0 incremental; ~$1/mo block volume per ADR-005 PR-A pattern for Healthchecks' PG) |

### Updated cost estimates

| Env | Previous estimate | + obs droplet | + Healthchecks volume | **Updated total** |
|---|---|---|---|---|
| QA | ~$47/mo | +$12/mo (s-1vcpu-2gb obs droplet) | +$1/mo | **~$60/mo** (vs. ~$47 in original ADR) |
| Prod | ~$102/mo | +$24/mo (s-2vcpu-4gb obs droplet) | (shared AgenticOS, $0 incremental) | **~$126/mo** (vs. ~$102 in original ADR) |

Updated delta over today's spend (~$24/mo monolith): **~2.5× for QA / ~2.6× for prod** (not 2× as originally stated). Still acceptable for the operational-burden reduction; recording the corrected number for honest planning.

### Phase 1 (TF env scaffold) — additional resources

Original Phase 1 listed App Platform placeholders + Managed PG + tiny Odoo droplet + persistent volume. Add to that list:

- `digitalocean_droplet.observability` (s-1vcpu-2gb in QA, s-2vcpu-4gb in prod), tags `env-<env>,project-grove,role-observability`
- `digitalocean_volume` for OpenObserve's Parquet storage if needed (TBD — OpenObserve writes to local FS by default; spec says Parquet-on-MinIO so may not need a separate block volume)
- `digitalocean_firewall.observability` (SSH from admin CIDR + OTLP ingest from Cloudflare-WAF IPs only — never public)
- DNS records for Cloudflare-WAF-protected OTLP ingest subdomain (per spec §1 Tier-2)
- The AgenticOS droplet is **existing** (out of scope for this TF env) but Healthchecks setup + its block volume should be tracked separately

### Phase 2 (App Platform spec per frontend) — observability hooks

In addition to the frontend service definition, each App Platform spec gains:
- `OTEL_EXPORTER_OTLP_ENDPOINT` env var → obs droplet's ingest URL
- `OTEL_SERVICE_NAME` = tenant name; `OTEL_RESOURCE_ATTRIBUTES` includes `service.version=<git_sha>` + `deployment.environment=<env>`
- The frontend code already calls `@grove/analytics` (today a `console.warn` stub; per spec §2 becomes a lazy dual-writer to OpenObserve RUM + Plausible)

### Phase 1.5 (NEW phase between scaffold + app-platform-specs) — bootstrap monitoring

After TF creates the obs droplet but before App Platform apps go live, run the existing `scripts/setup-monitoring.py` against the new env's OpenObserve URL. The script is idempotent (uploads `openobserve/{monitors,alerts,dashboards}.json` + `keep/{workflows,providers}.yml`). Wire it as a new step in `qa-deploy.yml` (currently NOT wired — known gap; spec §6 explicitly calls for it as a post-deploy step).

### Three independent alert paths (resilience design from spec §5)

Level 3 must preserve all three from day one (don't degrade resilience during migration):
1. OpenObserve + Keep → Discord (primary, on obs droplet)
2. DO-native alerts (App Platform `DEPLOYMENT_FAILED`/`DOMAIN_FAILED` + Managed PG/Redis policies) → Discord
3. GitHub Actions external synthetic cron (zero-droplet dependency)

Plus the dead-man's-switch: OpenObserve/Keep curl Healthchecks every 60s; if pings stop, Healthchecks fires Discord independently. This catches "OpenObserve itself is down" — the watcher-of-the-watcher.

### Updated "Open items" resolution

The original ADR-007 listed KeyDB + MinIO + Ghost placement as open. Per spec §2 + §3:
- **MinIO**: OpenObserve uses MinIO for Parquet storage. **Either** keep MinIO on obs droplet (fine for low volume) **or** swap for DO Spaces (S3-compatible; reduces obs droplet RAM but adds ~$5/mo). Decide at Phase 1.5 time based on storage volume.
- **KeyDB**: not relevant to observability stack. BFF caching decision (DO Managed Redis vs droplet KeyDB) is independent of Level 3 / observability.
- **Ghost**: continue pointing frontends at live `blog.goldberrygrove.farm` (per existing pattern). Self-hosted Ghost-per-tenant deferred until tenant blog content actually exists.

### Cross-references

- ADR-008 (`docs/ADR/008-observability-openobserve-supersedes-adr004.md`) — the supersession decision this addendum implements
- `docs/specs/2026-06-26-grove-observability-design.md` — full functional design (synthetic, RUM, APM, resilience, promotion)
- `docs/MONITORING.md` — operator playbook for the already-shipped OpenObserve + Keep stack
- `docker-compose.monitoring.yml` + `scripts/setup-monitoring.py` + `openobserve/*.json` + `keep/*.yml` — config-as-code that the new obs droplet will deploy
