# Identity UUIDs — copy these into the corresponding workflow YAMLs as the
# INFISICAL_IDENTITY_ID env var.
#
#   make infisical-identities-output
# or directly:
#   op run --env-file=.env.op -- terraform -chdir=infra/terraform/environments/infisical-identities output
#
# Not sensitive — these are routing identifiers, not credentials.

output "shared_identity_ids" {
  description = "Map of repo short-name → shared-readonly identity UUID. ALL low-risk workflows in that repo hardcode this same value. Today: {odoocker: <uuid>, grove-sites: <uuid>}."
  value = {
    for k, _ in var.repos :
    k => infisical_identity.shared[k].id
  }
}

output "prod_workflow_identity_ids" {
  description = "Map of '<repo>--<workflow>' → strict per-workflow identity UUID for prod-credential workflows. Each value is hardcoded into the specific workflow's INFISICAL_IDENTITY_ID."
  value = {
    for k, _ in local.prod_workflows_flat :
    k => infisical_identity.prod[k].id
  }
}

output "shared_consumers" {
  description = "Per-repo list of workflows expected to use that repo's shared identity (informational; not enforced at the trust-policy level)."
  value = {
    for k, repo in var.repos :
    k => repo.shared_readonly_workflows
  }
}

output "grove_sites_project_uuid" {
  description = "UUID of the grove-sites Infisical project created by this env. Use this when seeding grove-sites/prod secrets via Infisical CLI or the seed script."
  value       = infisical_project.grove_sites.id
}

output "grove_sites_project_slug" {
  description = "Slug of the grove-sites Infisical project (for Infisical/secrets-action calls in workflows — the GH Action takes slug, not UUID)."
  value       = infisical_project.grove_sites.slug
}
