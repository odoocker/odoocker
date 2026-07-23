# === Infisical provider auth (sensitive — injected via op run from 1Password) ===

variable "infisical_admin_client_id" {
  description = "Universal Auth Client ID for the tf-infisical-admin identity. From 1Password GoldberryGrove Infra / infisical_admin_client_id."
  type        = string
  sensitive   = true
}

variable "infisical_admin_client_secret" {
  description = "Universal Auth Client Secret for the tf-infisical-admin identity. From 1Password GoldberryGrove Infra / infisical_admin_client_secret."
  type        = string
  sensitive   = true
}

# === Layout (have defaults; override only if migrating orgs) ===

variable "infisical_host" {
  description = "Infisical API host. Use https://app.infisical.com (US), https://eu.infisical.com (EU), or your self-hosted URL."
  type        = string
  default     = "https://app.infisical.com"
}

variable "infisical_org_id" {
  description = "Goldberry Grove Infisical Cloud org UUID. Routing identifier (not a secret)."
  type        = string
  default     = "952236a8-4ed4-45c0-81e8-5157b48557a2"
}

# === Two-tier identity model — see main.tf header for rationale ===

variable "access_token_ttl_seconds" {
  description = "Lifetime of the access token Infisical issues after a successful OIDC exchange."
  type        = number
  default     = 600
}

variable "access_token_max_ttl_seconds" {
  description = "Hard cap on token refresh chain length."
  type        = number
  default     = 1800
}

# === The repos this env manages OIDC identities for ===

# Single source of truth: for each repo, declare its github coordinates +
# which workflows are prod-credential (strict per-workflow identity each)
# vs which workflows are low-risk (one SHARED identity for all of them).
#
# Identity-count math under the free-tier 5-identity cap:
#   - tf-infisical-admin                              = 1 (out of band, this env doesn't manage it)
#   - 1 shared identity per repo                       = N
#   - 1 prod identity per (repo × prod_workflow)       = M
#   Total = 1 + N + M
#
# For Grove today: N=2, M=2  →  1 + 2 + 2 = 5  (exactly at the cap)
#   - tf-infisical-admin
#   - gh-oidc-odoocker-shared
#   - gh-oidc-odoocker-release
#   - gh-oidc-grove-sites-shared
#   - gh-oidc-grove-sites-release
#
# Adding a 3rd repo, or splitting any low-risk workflow to its own identity,
# requires an Infisical Pro upgrade ($10-30/mo at time of writing).
variable "repos" {
  description = "Per-repo OIDC identity config. Each repo gets ONE shared-readonly identity + N strict per-workflow identities for prod-credential workflows."
  type = map(object({
    github_repo_full_name     = string
    github_branch             = string
    project_uuid              = string
    prod_credential_workflows = map(string)
    shared_readonly_workflows = list(string)
  }))
  default = {
    odoocker = {
      github_repo_full_name = "Goldberry-Playground/odoocker-goldberrygrove"
      github_branch         = "main"
      # Hardcoded — project already exists (created 2026-06-23 in UI before this env)
      project_uuid = "850603f8-e175-4c38-9038-97a1e69d72e6"
      prod_credential_workflows = {
        "release" = "release.yml"
      }
      shared_readonly_workflows = [
        "terraform-drift.yml",
        "sandbox-reaper.yml",
        "sandbox-deploy.yml",
        "docker-odoo.yml",
      ]
    }
    grove-sites = {
      github_repo_full_name = "Goldberry-Playground/grove-sites"
      github_branch         = "main"
      # Empty string sentinel — the grove-sites project is CREATED by this
      # TF env via the infisical_project resource. The actual UUID is computed
      # at apply time; main.tf wires it through local.repo_project_uuids.
      project_uuid = ""
      # grove-sites release.yml has no prod-credential exposure yet — M4
      # (production droplet) doesn't exist, so the workflow just tags +
      # pushes frontend images to GHCR. Folded into the shared identity
      # until M4 lands, at which point we either upgrade Infisical (~$10/mo
      # Pro tier) for the strict-isolation slot or rebalance by removing
      # another identity. Decision recorded 2026-06-23 after the first
      # apply hit the free-tier 5-identity cap.
      prod_credential_workflows = {}
      shared_readonly_workflows = [
        "ci.yml",
        "docker.yml",
        "preview-up.yml",
        "preview-down.yml",
        "release.yml",
      ]
    }
  }
}
