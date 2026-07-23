# ADR 005: QA cert resilience stack — persistent Caddy /data + branch-aware ACME + orphan TXT cleanup + multi-issuer fallback

**Status:** Accepted
**Date:** 2026-06-26
**Deciders:** Josh Dunbar
**PRs:** [#95](https://github.com/Goldberry-Playground/odoocker-goldberrygrove/pull/95), [#96](https://github.com/Goldberry-Playground/odoocker-goldberrygrove/pull/96), [#97](https://github.com/Goldberry-Playground/odoocker-goldberrygrove/pull/97), [#98](https://github.com/Goldberry-Playground/odoocker-goldberrygrove/pull/98)

## Context

The QA environment was hitting Let's Encrypt rate limits in a way that completely blocked deploys for 24h at a time. We hit the wall twice on 2026-06-26:

1. **First incident (HTTP-01)**: Caddy was issuing 5 separate certs (one per hostname). LE's "5 duplicate certs per identifier per week" tripped after ~6 deploys. We switched to DNS-01 wildcard in PR #82 to consolidate to one cert.

2. **Second incident (DNS-01 wildcard)**: The combined `{apex, wildcard}` identifier set has its OWN 5/week budget. After ~6 more deploys, that bucket also exhausted. Apex cert blocked until next day.

The root cause both times was the same: **every droplet recreate burned 1 of LE's 5/week budget for whatever identifier set Caddy requested**, because Caddy's `/data` (where it stores certs) lived in an anonymous Docker volume that died with the droplet. Frequent droplet recreates (~6 per evening during active development) are structurally incompatible with LE prod unless certs persist across recreates.

A reverted PR #81 had tried the persistent-volume approach but was abandoned after a code review surfaced 15 issues with the implementation (volume-attach race, fail-fast mount, prevent_destroy semantics, etc.) and PR #82's DNS-01 switch "seemed like the cleaner answer." It wasn't — it just changed the SHAPE of the rate-limit problem.

We also discovered an upstream bug in the `caddy-dns/digitalocean` plugin: its solver-cleanup step fails with `strconv.Atoi: parsing "": invalid syntax`, leaving every `_acme-challenge` TXT record permanently in the zone. By the time we noticed on 2026-06-26, the zone had 23 stale TXTs and LE was rejecting validations with "Incorrect TXT record (and N more) found."

## Decision

Ship a **4-PR cert resilience stack** as defense-in-depth. Each PR addresses a distinct failure mode; together they make "deploy stuck because of cert issues" go from "happens once a week" to "should not happen — and if it does, the deploy STILL completes (with a staging cert)."

### PR-A (#95): Persistent Caddy /data via DO block-storage volume

- New `digitalocean_volume` + `digitalocean_volume_attachment` resources in `infra/terraform/environments/qa/main.tf`
- Cloud-init mounts via native `mounts:` module (not the runcmd dance from the reverted PR #81 — `mounts:` eliminates 4 race-condition bugs by construction)
- Caddy bind-mounts `/mnt/caddy-data:/data` in `docker-compose.qa.yml`
- `scripts/qa-teardown-droplet.sh` pre-detaches the volume before destroying the droplet (avoids stale-attachment race on next apply)
- **No `prevent_destroy`** — operator can deliberately destroy the volume via `terraform destroy -target=...`. The script teardown bypasses TF anyway, so `prevent_destroy` was theater.
- **Tagged with `local.tags`** + **region-prefixed name** for discoverability and multi-region safety

**Impact:** First cert issuance writes to /data; later droplet recreates re-use the cert for ~80 days. Cert request frequency drops ~10×.

### PR-B (#96): Branch-aware ACME endpoint

- New `var.acme_endpoint` (default = LE prod) plumbed through cloud-init → compose env → Caddyfile's `acme_ca {env.ACME_CA}`
- `qa-deploy.yml` gains `workflow_dispatch` input `use_staging_acme: boolean` (default false). When true, terraform apply gets `-var='acme_endpoint=https://acme-staging-v02.api.letsencrypt.org/directory'`
- Validation rule restricts the var to LE prod or staging URL exactly

**Impact:** Operator can iterate freely without burning prod cert budget. Browser warnings on QA URLs when staging is selected — acceptable for internal testing.

### PR-C (#97): Orphan TXT cleanup preflight

- New `scripts/cleanup-acme-txts.sh` — portable bash (uses `printf '%s\n' | while read` instead of `for X in $LIST` to avoid the zsh word-splitting gotcha that bit my ad-hoc fix attempt the same evening)
- Lists every `_acme-challenge` TXT in the zone via DO API + DELETEs each + re-verifies count is 0
- Idempotent (exits 0 silently if zone is already clean)
- New preflight step in `qa-deploy.yml` runs it before TF apply

**Impact:** The `caddy-dns/digitalocean` delete bug becomes inert in our env. We file an upstream issue too, but the workaround means we don't have to wait for an upstream fix.

### PR-D (#98): Caddy multi-issuer fallback

- Caddyfile.tpl's `tls` block now has TWO `issuer acme {}` directives — primary `{env.ACME_CA}` (= var.acme_endpoint via PR-B), fallback hardcoded to LE staging
- On non-retryable failure (e.g. prod 429), Caddy advances to the next issuer automatically

**Impact:** Deploy NEVER gets stuck on cert provisioning. Worst case is a staging cert (browser warning); deploy still completes.

## Alternatives considered

### "Just split the Caddyfile into two site blocks (apex + wildcard) for fresh identifier-set budget"

Would buy a one-time reset (each split block gets its own 5/week from scratch). Doesn't solve the underlying issue — frequent droplet recreates would eat the new budget within days. Rejected as a structural fix; might be useful as a temporary workaround.

### "Use a different ACME provider (ZeroSSL, BuyPass)"

ZeroSSL has 6/3h limits, similar shape. Different DNS plugin would mean a different bug class. Doesn't address the root cause (cert state dying with droplet). Rejected.

### "Move QA to App Platform + managed Postgres + tiny Odoo droplet (Level 3 rethink)"

Drops most of the cert dance because App Platform manages TLS for you. 4 of the 6 containers (the frontends) no longer need Caddy in front of them. BUT: real $/mo implications, multi-day refactor, separate planning session needed. Deferred — not rejected, just not a tonight task.

### "Don't fix it; just accept the 24h rate-limit windows"

Considered for ~30 seconds. Rejected — we deploy frequently enough that a 24h block per cycle is unacceptable.

## Consequences

**Positive:**
- Cert request frequency drops ~10× (volume persistence)
- Operators have an escape hatch for heavy iteration cycles (use_staging_acme)
- Plugin delete bug is inert (TXT cleanup preflight)
- Deploys never get stuck on cert provisioning (multi-issuer fallback)
- All 4 layers compose: if any one fails, the others compensate

**Negative:**
- More TF resources to manage (+2: volume + attachment). Mitigated by `local.tags` + region prefix for discoverability.
- TF state drift if operator manually destroys the volume via DO console. Mitigated by documented `terraform destroy -target=` command.
- Caddyfile is now more complex (multi-issuer block, env-driven ca). Mitigated by inline comments explaining the layering.
- Browser warnings when using staging certs. Operators are internal; acceptable.

**Open items:**
- File upstream issue against `caddy-dns/digitalocean` for the `strconv.Atoi` TXT delete bug. PR-C makes it inert for us but every other operator using the plugin will hit the same wall.
- Reconsider Level 3 (App Platform rethink) as a planning session — this stack solves the cert problem but the broader "QA env is a fragile pile of moving parts" problem remains.

## References

- [LE rate limits documentation](https://letsencrypt.org/docs/rate-limits/)
- [Caddy multi-issuer fallback docs](https://caddyserver.com/docs/caddyfile/options#acme_issuer)
- [Memory: le-rate-limit-identifier-sets](../../../../../../../.claude/projects/-Users-joshuadunbar-Documents-Dev-Projects-gather-at-the-grove/memory/feedback_le_rate_limit_identifier_sets.md) — full failure-mode analysis
- [Memory: caddy-dns-digitalocean-txt-delete-bug](../../../../../../../.claude/projects/-Users-joshuadunbar-Documents-Dev-Projects-gather-at-the-grove/memory/feedback_caddy_dns_digitalocean_txt_delete_bug.md)
- Reverted PR #81 — original persistent-volume attempt; code review surfaced the 15 issues that PR-A (#95) fixed
- PRs #82, #84, #85, #87 — the DNS-01 wildcard journey that turned out to be solving the wrong problem
