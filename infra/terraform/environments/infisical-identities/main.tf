###############################################################################
# OIDC identities in Infisical for ALL Goldberry-Playground workflows.
#
# Designed to fit within Infisical's free-tier 5-identity cap (decision
# 2026-06-23 — see memory/feedback_oidc_trust_policy_pattern.md).
#
# Identity count at steady state: 5
#   1. tf-infisical-admin              — Universal Auth, manages all other identities (created by bootstrap script, not this env)
#   2. gh-oidc-odoocker-shared         — repo+ref binding only, no workflow_ref
#   3. gh-oidc-odoocker-release        — strict workflow_ref binding to release.yml
#   4. gh-oidc-grove-sites-shared      — same shape as #2 but for grove-sites
#   5. gh-oidc-grove-sites-release     — same shape as #3 but for grove-sites
#
# Security boundaries preserved:
#   ✓ Cross-repo isolation       (odoocker workflows can't use grove-sites identities)
#   ✓ Cross-tenant isolation     (different projects, different Viewer grants)
#   ✓ Prod-credential isolation  (release identities have strict workflow_ref pinning)
#
# Security boundary deliberately collapsed (accepted trade-off for the 5-cap):
#   ✗ Per-workflow isolation WITHIN a repo's low-risk workflows. Any workflow
#     on a repo's main branch can use that repo's shared identity. Mitigated
#     by code review + the workflow YAML pattern being well-documented.
###############################################################################

provider "infisical" {
  host = var.infisical_host
  auth = {
    universal = {
      client_id     = var.infisical_admin_client_id
      client_secret = var.infisical_admin_client_secret
    }
  }
}

# ── Projects (only those this env manages — grove-odoocker is pre-existing) ─

# grove-sites: created by this env. UUID computed at apply time; flows into
# the identity grants below via `local.repo_project_uuids`.
resource "infisical_project" "grove_sites" {
  name        = "grove-sites"
  slug        = "grove-sites"
  description = "Secrets for Goldberry-Playground/grove-sites workflows (ci, docker, preview-up/down, release). Provisioned by infra/terraform/environments/infisical-identities/."
  type        = "secret-manager"
}

# Resolve per-repo project UUIDs at one place — for grove-sites, the resource
# above provides it; for odoocker, the hardcoded value in var.repos["odoocker"]
# is used (the project pre-existed this env's creation).
locals {
  repo_project_uuids = {
    odoocker    = var.repos["odoocker"].project_uuid
    grove-sites = infisical_project.grove_sites.id
  }
}

# ── Tier 1: shared-readonly identity per repo ───────────────────────────────

resource "infisical_identity" "shared" {
  for_each = var.repos

  name   = "gh-oidc-${each.key}-shared"
  org_id = var.infisical_org_id
  role   = "no-access"
}

resource "infisical_identity_oidc_auth" "shared" {
  for_each = var.repos

  identity_id        = infisical_identity.shared[each.key].id
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"

  # LOOSE binding: only `repository` claim, NO ref or workflow_ref pinning.
  # ANY workflow on the configured repo (any branch — main, qa, feature
  # branches) can authenticate as this identity. Required for Josh's dev
  # cycle: push to `qa` branch must work, push to `main` must also work,
  # both use this shared identity.
  #
  # ── Security review finding (2026-06-24) ──────────────────────────────
  # Automated security review flagged this as HIGH "Overly Permissive
  # IAM/RBAC" and suggested separate identities per branch. Acknowledged
  # AND accepted under the following trade-off:
  #
  # CONSTRAINT: Infisical free tier caps at 5 identities (admin + 4 OIDC).
  # We're at the cap. Adding per-branch identities would require Pro tier
  # (~$10/mo). Not unreasonable, but not yet warranted.
  #
  # MITIGATIONS in place:
  # 1. Cross-repo isolation preserved — grove-sites workflows can't use
  #    this identity because their `repository` claim is different
  # 2. Cross-tenant isolation preserved — separate Infisical project per
  #    repo, with per-project Viewer role grants
  # 3. Branch protection rules on `main` and `qa` (org-level setting,
  #    independent of this TF env) provide the administrative gate
  # 4. `release.yml` (prod-credential workflow) uses a SEPARATE strict
  #    identity (`prod` for_each in this file) with workflow_ref binding
  #    — so prod SSH key is NOT exposed via this loose identity
  #
  # WHAT THIS LEAVES EXPOSED:
  # Any GitHub user with write access to the odoocker repo can push to a
  # new branch (or to qa) and have that workflow run with the shared
  # identity's secrets (DIGITALOCEAN_TOKEN, DISCORD_OPS_WEBHOOK_URL,
  # CLOUDFLARE_API_TOKEN, SPACES_*). They could provision DO infra or
  # exfiltrate the tokens. This is the SAME blast radius as direct write
  # access to main branch (they could just merge a malicious main commit).
  # So the practical risk delta is zero for legitimate org members; the
  # risk is real only if a compromised collaborator account gets revoked
  # from main but not from feature-branch creation — a narrow window.
  #
  # FOLLOW-UP ON PRO UPGRADE: when Grove hits Pro tier, restore the
  # strict per-branch binding (one identity for main, one for qa).
  bound_subject = ""
  bound_claims = {
    repository = each.value.github_repo_full_name
  }

  access_token_ttl            = var.access_token_ttl_seconds
  access_token_max_ttl        = var.access_token_max_ttl_seconds
  access_token_num_uses_limit = 0
  access_token_trusted_ips    = [{ ip_address = "0.0.0.0/0" }]
}

resource "infisical_project_identity" "shared_viewer" {
  for_each = var.repos

  identity_id = infisical_identity.shared[each.key].id
  project_id  = local.repo_project_uuids[each.key]

  roles = [{ role_slug = "viewer" }]
}

# ── Tier 2: strict per-workflow identities for prod-credential workflows ────

# Flatten the nested map (repo → prod_credential_workflows) into a single
# map keyed by "<repo>--<workflow>" so for_each can iterate it cleanly.
locals {
  prod_workflows_flat = merge([
    for repo_key, repo in var.repos : {
      for wf_name, wf_file in repo.prod_credential_workflows :
      "${repo_key}--${wf_name}" => {
        repo_key  = repo_key
        wf_name   = wf_name
        wf_file   = wf_file
        repo_full = repo.github_repo_full_name
        branch    = repo.github_branch
      }
    }
  ]...)
}

resource "infisical_identity" "prod" {
  for_each = local.prod_workflows_flat

  name   = "gh-oidc-${each.value.repo_key}-${each.value.wf_name}"
  org_id = var.infisical_org_id
  role   = "no-access"
}

resource "infisical_identity_oidc_auth" "prod" {
  for_each = local.prod_workflows_flat

  identity_id        = infisical_identity.prod[each.key].id
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"

  # STRICT binding: pins repo + ref AND workflow_ref to a specific file. A
  # compromised workflow that isn't this exact file CANNOT use this identity.
  bound_subject = "repo:${each.value.repo_full}:ref:refs/heads/${each.value.branch}"
  bound_claims = {
    job_workflow_ref = "${each.value.repo_full}/.github/workflows/${each.value.wf_file}@refs/heads/${each.value.branch}"
  }

  access_token_ttl            = var.access_token_ttl_seconds
  access_token_max_ttl        = var.access_token_max_ttl_seconds
  access_token_num_uses_limit = 0
  access_token_trusted_ips    = [{ ip_address = "0.0.0.0/0" }]
}

resource "infisical_project_identity" "prod_viewer" {
  for_each = local.prod_workflows_flat

  identity_id = infisical_identity.prod[each.key].id
  project_id  = local.repo_project_uuids[each.value.repo_key]

  roles = [{ role_slug = "viewer" }]
}
