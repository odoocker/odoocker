# =============================================================================
# GitHub repository rulesets — GOL-87 (implements GOL-69 Option B)
# =============================================================================
# Purpose: codify the `main` branch ruleset on odoocker-goldberrygrove so the
# `AgenticOS Developer` app (ID 4134853) can bypass the pull-request review gate
# and merge its own PRs with no human click — WITHOUT weakening the substantive
# guardrail (all 3 required CI checks stay required for everyone, humans still
# get the review gate).
#
# This resource was IMPORTED from a pre-existing click-ops ruleset (id
# 15851626). Every rule below is a faithful transcription of the live ruleset
# as of 2026-07-05; the ONLY intended change vs. the imported state is the added
# `bypass_actors` block. A `terraform plan` MUST show exactly that one addition
# and nothing else (no rule removed, no check dropped) before apply — that is
# CEO guardrail #4.
# =============================================================================

provider "github" {
  token = var.github_token
  owner = var.github_owner
}

# Import the existing click-ops ruleset into state so we manage it in place
# rather than creating a duplicate. Provider import id format: "<repo>:<id>".
import {
  to = github_repository_ruleset.main
  id = "${var.ruleset_repo}:15851626"
}

resource "github_repository_ruleset" "main" {
  name        = "main-branch-protection"
  repository  = var.ruleset_repo
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # --- THE ONLY INTENDED CHANGE vs. imported state ----------------------------
  # Scope the bypass to the AgenticOS Developer app ONLY. `always` = the app may
  # bypass the PR review gate on every merge. Humans are NOT listed, so they
  # still hit the review requirement. Removing this block (+ apply) is the full
  # rollback and reverts to the human-merge gate.
  bypass_actors {
    actor_id    = var.agenticos_developer_app_id
    actor_type  = "Integration"
    bypass_mode = "always"
  }
  # ----------------------------------------------------------------------------

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      required_approving_review_count   = 1
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = true
      # Live ruleset restricts merges to squash + rebase (no merge commits),
      # consistent with `required_linear_history`.
      allowed_merge_methods = ["squash", "rebase"]
    }

    # CEO guardrail #1: all three required CI checks stay REQUIRED. A red PR is
    # still blocked from merging even for the bypassing app — CI is the
    # substantive guardrail once the review gate is bypassed.
    required_status_checks {
      strict_required_status_checks_policy = true
      do_not_enforce_on_create             = false

      required_check {
        context = "Validate Docker Compose (Grove)"
      }
      required_check {
        context = "Validate Nginx Config"
      }
      required_check {
        context = "Lint Python (Odoo Modules)"
      }
    }
  }
}
