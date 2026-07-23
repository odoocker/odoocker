variable "github_token" {
  description = <<-EOT
    GitHub token for the `github` provider used ONLY by this env.

    REQUIRES **Administration: Read and Write** on the target repo — the
    `github_repository_ruleset` resource reads and writes repository rulesets,
    which is an Administration-scoped operation.

    This is a STRICTER scope than the `github_token` used by the `bootstrap` /
    `state-backend` envs (those only need Actions:Secrets + Metadata). Neither
    the `AgenticOS Developer` app installation token nor the existing
    `GoldberryGrove Infra/github_token` fine-grained PAT carries Administration
    (both return 403 on `branches/main/protection`), so this env needs its own
    admin-scoped credential.

    Supply via `TF_VAR_github_token`, injected from 1Password at run time.
    NEVER place it in a tfvars file or commit it.

    Accepted forms:
      - Classic PAT with `repo` scope (includes repo Administration), OR
      - Fine-grained PAT scoped to the repo(s) below with
        **Administration: Read and Write** + **Metadata: Read**.
  EOT
  type        = string
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub org/owner that owns the ruleset-managed repo."
  type        = string
  default     = "Goldberry-Playground"
}

variable "ruleset_repo" {
  description = "Repo name (without owner) whose `main` ruleset we manage."
  type        = string
  default     = "odoocker-goldberrygrove"
}

variable "agenticos_developer_app_id" {
  description = <<-EOT
    Numeric GitHub App ID of the `AgenticOS Developer` app (the agent identity
    that opens and merges PRs). Added as the sole ruleset bypass actor so the
    app can merge its own PRs without a human review click, while every human
    still hits the review gate. GOL-69 Option B (Josh confirmation f2ebfe39).
  EOT
  type        = number
  default     = 4134853
}
