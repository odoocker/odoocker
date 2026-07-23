terraform {
  required_version = ">= 1.6"

  required_providers {
    github = {
      source = "integrations/github"
      # >= 6.2, < 7.0 — resolves to the latest 6.x, which supports the
      # `allowed_merge_methods` argument on the ruleset `pull_request` block
      # (added in 6.3.0). We depend on that so the plan is drift-free against
      # the live ruleset, which restricts merges to squash + rebase.
      version = "~> 6.2"
    }
  }

  # Remote state on the shared DO Spaces `grove-tf-state` bucket (same backend
  # every non-bootstrap env uses). Real values live in backend.hcl (git-ignored).
  # See backend.hcl.example. State is sacred: a corrupted ruleset state re-opens
  # the human-merge gate on prod `main`, so we keep it remote + locked, never local.
  backend "s3" {}
}
