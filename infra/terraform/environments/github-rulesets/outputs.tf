output "ruleset_id" {
  description = "Numeric id of the managed `main` ruleset."
  value       = github_repository_ruleset.main.ruleset_id
}

output "bypass_actor_app_id" {
  description = "The single app allowed to bypass the review gate (should be 4134853 = AgenticOS Developer)."
  value       = var.agenticos_developer_app_id
}

output "required_status_checks" {
  description = "The CI checks that stay required for everyone, including the bypassing app (guardrail #1)."
  value = [
    "Validate Docker Compose (Grove)",
    "Validate Nginx Config",
    "Lint Python (Odoo Modules)",
  ]
}
