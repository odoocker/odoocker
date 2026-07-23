# Infisical Identities — Terraform

Declaratively manages the OIDC machine identities in Infisical Cloud that Goldberry-Playground's GitHub Actions workflows use to fetch secrets via workload identity federation (no long-lived secrets in GH Secrets).

Scoped to fit Infisical's **free-tier 5-identity cap** (decision 2026-06-23 — see `memory/feedback_oidc_trust_policy_pattern.md`).

Lives alongside the other TF envs in `infra/terraform/environments/`. Same `op run --env-file=.env.op --` credential injection pattern; state in the shared `grove-tf-state` Spaces bucket.

## The 5-identity allocation (1 admin + 4 OIDC)

Infisical's free-tier cap is **5 identities total — admin counts toward the cap** (confirmed empirically 2026-06-23 by hitting the cap on the first apply). So 4 OIDC slots available.

| # | Identity | Where it's created | Trust policy | Project access | Used by |
|---|---|---|---|---|---|
| 1 | `tf-infisical-admin` | `scripts/infisical-admin-bootstrap.sh` | Universal Auth (admin) | Admin on grove-odoocker + grove-sites | TF env, scripts, one-time seeds |
| 2 | `gh-oidc-odoocker-shared` | This env | `repo=odoocker:ref=main`, no `workflow_ref` | Viewer on grove-odoocker | terraform-drift, sandbox-reaper, sandbox-deploy, docker-odoo |
| 3 | `gh-oidc-odoocker-release` | This env | `repo=odoocker:ref=main` + `workflow_ref=release.yml` | Viewer on grove-odoocker | release.yml (prod CD — actual prod SSH key access) |
| 4 | `gh-oidc-grove-sites-shared` | This env | `repo=grove-sites:ref=main`, no `workflow_ref` | Viewer on grove-sites | ci, docker, preview-up, preview-down, **release.yml** |

**Exactly 5 total. Zero spare.** Adding a 3rd repo OR splitting grove-sites release.yml off into its own strict identity (which becomes meaningful when M4 ships and grove-sites release actually deploys to a prod droplet) requires an Infisical Pro upgrade (~$10/mo).

**Why grove-sites release.yml uses the shared identity:** M4 (production droplet) doesn't exist yet, so grove-sites release.yml just tags + pushes frontend images to GHCR. No prod SSH key, no actual production-deployment access. Strict isolation is theoretical today. When M4 lands, revisit (delete a different identity OR upgrade).

## Security boundaries preserved

| Boundary | Preserved? | Mechanism |
|---|---|---|
| Cross-repo (odoocker ↔ grove-sites) | ✅ | Trust policies bind to specific repo |
| Cross-tenant (grove-odoocker secrets ↔ grove-sites secrets) | ✅ | Separate projects + per-project Viewer grants |
| Prod-credential isolation (release ↔ everything else) | ✅ | Strict `workflow_ref` binding on release identities |
| Per-workflow isolation WITHIN a repo (low-risk workflows) | ❌ | Shared identity per repo — accepted trade-off for the 5-cap |

## What this env creates

- **`infisical_project.grove_sites`** — the grove-sites project itself (grove-odoocker is pre-existing, referenced by hardcoded UUID)
- **Per repo (×2)**: one `infisical_identity` + one `infisical_identity_oidc_auth` + one `infisical_project_identity` for the shared-readonly identity
- **Per (repo × prod workflow) (×2)**: same 3 resources, with strict workflow_ref binding

= 1 project resource + 6 shared resources (2 repos × 3) + 3 prod resources (1 prod workflow × 3) = **10 resources** on first apply.

## Prerequisites

1. **Infisical Cloud org exists** — `952236a8-4ed4-45c0-81e8-5157b48557a2` (created 2026-06-18)
2. **grove-odoocker project exists** — `850603f8-e175-4c38-9038-97a1e69d72e6` (created in UI 2026-06-23, has live Phase-1 seeded secrets that we don't want TF to manage)
3. **`tf-infisical-admin` identity exists with Admin role on grove-odoocker** — created by `make infisical-admin-bootstrap`. Client ID + Secret in 1Password.
4. **No other identities exist** — Josh deleted all stale identities on 2026-06-23 to start clean within the 5-cap.
5. **`grove-tf-state` Spaces bucket exists** — provisioned by `state-backend/` TF env.
6. **Bootstrap Spaces keys in 1Password** — `spaces_bootstrap_access_key_id` + `spaces_bootstrap_secret_key`.

## First apply

```bash
cd infra/terraform/environments/infisical-identities

cp backend.hcl.example backend.hcl   # backend.hcl is git-ignored

# From repo root, via Makefile (recommended):
make infisical-identities-init
make infisical-identities-plan        # review: 13 new resources expected
make infisical-identities-apply
make infisical-identities-output      # prints all identity UUIDs as JSON
```

Expected output: `Apply complete! Resources: 13 added, 0 changed, 0 destroyed.`

## After first apply — what's still needed

1. **Grant tf-infisical-admin Admin on grove-sites** (this env creates the project but the admin grant for tf-infisical-admin uses user-login auth via the bootstrap script). Re-run:
   ```
   make infisical-admin-bootstrap identity_id=<tf-infisical-admin-uuid> \
     INFISICAL_ADMIN_PROJECT_IDS=850603f8-e175-4c38-9038-97a1e69d72e6,<grove-sites-uuid-from-output>
   ```
2. **Seed grove-sites/prod secrets** — `make infisical-seed` once `.env.infisical-seed.op` is pointed at the grove-sites project (currently pointed at grove-odoocker). The 10 secrets the preview-up workflow needs (DIGITALOCEAN_TOKEN, DO_SPACES_*, ADMIN_IP_CIDR, PREVIEW_SSH_*, GHOST_KEY_*, DISCORD_OPS_WEBHOOK_URL) per the bootstrap-secret-name-alignment PR.
3. **Update each workflow YAML** to reference its identity UUID:
   - odoocker workflows on the shared identity → `INFISICAL_IDENTITY_ID = shared_identity_ids.odoocker`
   - odoocker release → `INFISICAL_IDENTITY_ID = prod_workflow_identity_ids["odoocker--release"]`
   - grove-sites shared workflows → `shared_identity_ids["grove-sites"]`
   - grove-sites release → `prod_workflow_identity_ids["grove-sites--release"]`

## Reading the outputs

```bash
make infisical-identities-output
```

Yields:
```json
{
  "shared_identity_ids": {
    "odoocker":    "<uuid>",
    "grove-sites": "<uuid>"
  },
  "prod_workflow_identity_ids": {
    "odoocker--release":    "<uuid>",
    "grove-sites--release": "<uuid>"
  },
  "shared_consumers": {
    "odoocker":    ["terraform-drift.yml", "sandbox-reaper.yml", "sandbox-deploy.yml", "docker-odoo.yml"],
    "grove-sites": ["ci.yml", "docker.yml", "preview-up.yml", "preview-down.yml"]
  },
  "grove_sites_project_uuid": "<uuid>",
  "grove_sites_project_slug": "grove-sites"
}
```

## Adding a workflow

| Adding... | Cost | How |
|---|---|---|
| A low-risk workflow to an existing repo | **0 identity slots** | Edit `var.repos[<repo>].shared_readonly_workflows` (informational only); update the workflow YAML to reference the existing shared identity's UUID |
| A prod-credential workflow to an existing repo | **1 identity slot** (must have spare) | Edit `var.repos[<repo>].prod_credential_workflows`; `make infisical-identities-apply` |
| A new repo entirely | **2 identity slots** (must have 2 spare) | Add an entry to `var.repos`; `make infisical-identities-apply` |

Today: 0 spare slots. Any addition above triggers a Pro upgrade.

## Caveats

### Trust policy literals matter

Renaming a workflow file (e.g., `release.yml` → `cd.yml`) breaks the strict identity's `workflow_ref` binding until this TF env is updated. The shared identity isn't affected by workflow renames (no `workflow_ref` claim).

### Secrets in tfstate

The Infisical provider's auth credentials and the trust-policy literals live in `terraform.tfstate`. State file is in the `grove-tf-state` Spaces bucket.

### Drift relationship with the script

`scripts/infisical-add-workflow-identity.sh` can also create identities (companion to this TF env). They DO NOT share state — if you use the script to create an identity then later add the same workflow to this env's `var.repos`, `terraform apply` will fail at create-time (name collision). Pick one tool per identity.

## Related

- `scripts/infisical-admin-bootstrap.sh` — creates tf-infisical-admin (the one identity this env doesn't manage)
- `scripts/infisical-add-workflow-identity.sh` — ad-hoc identity creation (alternative to this env for one-offs)
- `docs/ADR/003-infisical-secrets-broker.md` — broader architecture decision record
- `memory/feedback_oidc_trust_policy_pattern.md` — trust-policy pattern + two-tier rationale
- `memory/project_infisical_decision_cloud.md` — Cloud vs self-host decision
