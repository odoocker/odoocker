# ADR 003: Infisical Cloud as OIDC secrets broker

**Status:** Accepted (2026-06-18)
**Context:** OIDC retrofit (Asana `1215643675066258`, due 2026-06-27). Decision record in `vault/wiki/Software/Grove Deployment Decisions.md` and `memory/project_infisical_decision_cloud.md`.

## Decision

Use **Infisical Cloud** (free tier) as the secrets broker for GitHub Actions OIDC federation. CI workflows fetch secrets at run time via Infisical's OIDC machine-identity flow instead of reading them from GH Secrets.

## Context

Today four workflows (`sandbox-deploy`, `sandbox-reaper`, `terraform-drift`, `release`) authenticate to DigitalOcean using a long-lived `DIGITALOCEAN_TOKEN` stored in GH Secrets. The token is:

- Long-lived (rotated only on manual ceremony)
- Readable by any workflow in the repo
- Replicated to every runner the workflow lands on
- Exfiltrable through repo admin access OR a compromised third-party Action in the pipeline

A GH Secrets leak (via repo admin, malicious Action, or token exfil) compromises DigitalOcean.

## Alternatives considered

| Option | Why not |
|---|---|
| **HashiCorp Vault on a DO droplet** | Adds 1 droplet + 2 stateful services (Vault + Postgres) to maintain. Single droplet means no HA; single encryption key on disk means droplet compromise = secrets compromise. For a solo-dev op, running a secrets manager that's less reliable than what it replaces is net-negative. |
| **OpenBao self-hosted** | Same operational profile as Vault. MPL-2.0 (cleaner OSS story) but smaller community/docs. |
| **1Password Service Account** | Not real OIDC — uses a long-lived `OP_SERVICE_ACCOUNT_TOKEN` in GH Secrets. Trades one long-lived secret for another. |
| **1Password Credential Broker** | Architecturally right (real workload identity federation) but private beta as of 2026-06-15. Beta posture incompatible with running production CI on it. Worth piloting when GA. |
| **DigitalOcean-native OIDC** | Does not exist. DO has no federation story for its REST API (only DOKS SSO, which is for cluster auth, not API tokens). |
| **Defer indefinitely** | The "GH Secrets leak compromises DO" surface is real; closing it is worth the move. |

## What this wins

A GitHub Secrets leak no longer compromises DigitalOcean. CI runs fetch the DO token via OIDC, the token only exists in the runner's process for that single run, and Infisical's audit log records every fetch.

## What this does not win

- **Droplet-compromise resistance.** The DO token still lives in Infisical's KV with KMS-backed encryption — better than env-var-key self-host, but a compromised Infisical workload could still read it. Cloud's KMS backing materially improves this vs self-host on a single droplet.
- **Upstream credential lifetime.** Infisical brokers the DO token; it doesn't shorten the DO token's own lifetime. Native DO OIDC federation would be required for that, and it doesn't exist.
- **1Password root-of-trust hardening.** 1Password remains the bootstrap-time root (Infisical seeds from there). Compromise of 1Password compromises everything.

## Architecture

```
1Password  ──(op run)──►  scripts/infisical-seed.sh  ──(infisical CLI)──►  Infisical Cloud
                                                                              │
                                                                              ▼
                                                              GH Actions OIDC trust policy
                                                              (repository + workflow_ref + ref)
                                                                              │
                                                                              ▼
                                                                     CI workflow run

During hybrid window (Phase 2): Infisical → one-way sync DOWN → GH Secrets (fallback only)
```

**Trust policy** (every machine identity in Infisical): `repository + workflow_ref + ref` with hardcoded literal values. Never bind `actor` (breaks bots, weak boundary).

**Identity scoping:**
- **Per-workflow identity** for workflows touching a prod credential: `release.yml`, `sandbox-deploy.yml`
- **Shared per-repo identity** for low-value / read-only workflows: `terraform-drift.yml`, `sandbox-reaper.yml`, `preview-up.yml`, `preview-down.yml`

## Migration plan

Phased, with Infisical as source-of-truth from day one and one-way sync DOWN to GH Secrets during the hybrid window. Rotation happens in Infisical only; the GH Secrets fallback updates itself.

| Phase | Deliverable |
|---|---|
| 1 | This PR — `scripts/infisical-seed.sh` + `.env.infisical-seed.op.example` + `make infisical-seed`. Additive; no workflows change. |
| 2 | Wire Infisical's GitHub integration in the Infisical UI for one-way sync DOWN to GH Secrets. |
| 3 | Retrofit `terraform-drift.yml` (lowest stakes — failure = drift check didn't run). |
| 4 | Retrofit `sandbox-reaper.yml`. |
| 5 | Retrofit `sandbox-deploy.yml`. |
| 6 | Retrofit `release.yml`. |
| 7 | Stop trigger: 2 weeks green across all retrofitted workflows OR 30-day calendar cap. Delete GH Secrets, retire sync. |

## Fork-PR risk model

GitHub by-design refuses to mint `id-token` on `pull_request` runs from a fork. The OIDC retrofit does NOT expand the fork-PR attack surface vs the current model. The real fork-PR risks (independent of this ADR):

1. Repo/org Actions settings around fork-PR token scope must remain restrictive — verified 2026-06-18.
2. No workflow should migrate from `pull_request` to `pull_request_target` without an explicit threat-model review.

See `memory/feedback_oidc_fork_pr_misconception.md` for full reasoning.

## Open follow-ups

- Spaces workflow keys (`grove-tf-state-rw`) currently live only in TF state. Add `1password_item` resources to `state-backend/main.tf` so they're retrievable from 1Password for re-seeds without `terraform output`.
- HA: not pursued. An Infisical outage blocks new deploys for 20-60 min; running services keep their secrets on disk. 1Password remains the practiced fallback.
