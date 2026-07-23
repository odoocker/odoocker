# Grove Preview — Terraform env

Per-PR ephemeral preview droplets. Each PR gets a unique host label (`pr-<number>-<5char>`) under `preview.gatheringatthegrove.com`, a fresh droplet, and a snapshot-restored Postgres from `grove-preview-data` Spaces bucket.

## ⚠️ Status: scaffolded but not yet automated

This env was created in odoocker PR #32 (2026-06-24) but has not been deployed since. There is **no `preview-up.yml` workflow yet** — `backend.hcl.example` references one ("the preview-up workflow templates `key` to `preview/pr-<number>.tfstate`") but the workflow doesn't exist.

To use this env today you'd need to:
1. Build the `preview-up.yml` workflow (or `terraform apply` manually with explicit `-var=pr_number=...`)
2. Verify the Caddy image + cert provisioning work end-to-end

A 2026-06-26 audit caught + fixed a latent bug in this env's Caddy image reference (`slothcored/caddy:digitalocean` was a Docker Hub 404; switched to `ghcr.io/goldberry-playground/grove-caddy` to match QA's working image). That was the only **blocker** to preview's first deployment.

## How this env differs from QA

| Dimension | QA | Preview |
|---|---|---|
| Lifecycle | Long-lived, recreated on push to `qa` branch | Per-PR, destroyed when PR closes/merges |
| Caddy `/data` persistence | YES (DO volume per ADR-005) | NO (`volume_size_gb = 0` in modules/droplet — local disk only) |
| Postgres data | Fresh empty per cycle | Snapshot-restored from `grove-preview-data` Spaces bucket |
| URL pattern | `<service>.qa.gatheringatthegrove.com` | `<service>.pr-<N>-<5char>.preview.gatheringatthegrove.com` |
| LE identifier set | Single `{*.qa.*}` reused across cycles (volume-persisted cert) | Unique `{*.pr-<N>-<5char>.preview.*}` per PR |
| Rate-limit exposure | Was a real problem (PR-A volume solves) | Low: each PR has its own identifier set |
| Caddy multi-issuer fallback | YES (per ADR-005 PR-D) | YES (matched by this PR) |
| `cleanup-acme-txts.sh` preflight | YES (in qa-deploy.yml) | NOT INTEGRATED (no preview-up.yml exists yet to host the preflight step) |
| Module adoption (`modules/droplet`) | NO (inline resources) | YES (`module "preview" { source = "../../modules/droplet" }`) |

## What about Level 3?

ADR-007 (Level 3 — App Platform + Managed PG) was scoped to QA + prod. Preview's per-PR lifecycle is different enough that adopting App Platform may not fit:

- App Platform deploys take 3-5 min per app. Preview wants <2 min to bring up a fresh env per PR.
- Per-PR managed Postgres instances would be cost-prohibitive (~$15/mo × N open PRs).
- The snapshot-restore-from-Spaces model is preview-specific and doesn't map cleanly onto Managed PG.

A reasonable end-state: **preview stays on this droplet pattern indefinitely** (the failure modes Level 3 protects against don't apply to per-PR ephemeral previews), while QA + prod migrate to App Platform. The asymmetry is OK because preview's purpose (per-PR isolation + snapshot restore) is fundamentally different from QA's (long-lived integration testing) and prod's (production traffic).

If a future review changes that assessment, document the rationale in a new ADR.

## When preview gets deployed

When the `preview-up.yml` workflow is eventually built, it should mirror `qa-deploy.yml`'s structure:
- Same Infisical OIDC pattern
- Same `cleanup-acme-txts.sh` preflight (preview hits the same caddy-dns/digitalocean delete bug)
- Same image-shape preflight (catches PR #90-class "image built but missing files" failures)
- Variable: `pr_number` (workflow_dispatch input or PR-event-driven)

This is a deferred follow-up, not in scope for any current PR.

## Cross-references

- [`docs/ADR/005`](../../../../docs/ADR/005-qa-cert-resilience-stack.md) — the QA cert resilience pattern (mostly applicable to preview; volume isn't)
- [`docs/ADR/007`](../../../../docs/ADR/007-level-3-app-platform-migration.md) — the QA + prod architectural rethink (preview deliberately excluded)
- [`infra/terraform/environments/qa/README.md`](../qa/README.md) — sister env, fully automated
- [`infra/terraform/environments/production/README.md`](../production/README.md) — sister env, deferred pending Level 3
