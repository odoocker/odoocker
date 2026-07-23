# `github-rulesets` — codified GitHub branch rulesets

Implements **GOL-69 Option B** (Josh confirmation `f2ebfe39`) via **GOL-87**:
add the `AgenticOS Developer` app (ID `4134853`) as the *only* bypass actor on
the `odoocker-goldberrygrove` `main` branch ruleset, so agent-authored PRs
squash-merge with **no human review click** — while keeping every substantive
guardrail intact.

This kills the recurring protected-`main` `REVIEW_REQUIRED` human-merge gate
permanently, with **no new identity and no new secret**.

## What this manages

One resource: `github_repository_ruleset.main`, the pre-existing click-ops
ruleset **`main-branch-protection`** (id `15851626`) on
`Goldberry-Playground/odoocker-goldberrygrove`. It was created in the GitHub UI,
so the first apply must `import` it (an `import {}` block is already wired in
`main.tf` — Terraform imports on the next `plan`/`apply`).

The resource is a faithful transcription of the live ruleset as of
2026-07-05; the **only intended change** is the added `bypass_actors` block.

### CEO guardrails (all three hold in this code)

1. **All 3 required CI checks stay required** for everyone, including the
   bypassing app — `required_status_checks` keeps `Validate Docker Compose
   (Grove)`, `Validate Nginx Config`, `Lint Python (Odoo Modules)`, with
   `strict_required_status_checks_policy = true`. A red PR is still blocked.
2. **Codified, not click-ops.** The bypass lives in
   `github_repository_ruleset.bypass_actors`, imported into remote state —
   auditable, reversible, re-appliable.
3. **Narrowly scoped.** Exactly one bypass actor: `actor_type = "Integration"`,
   `actor_id = 4134853`, `bypass_mode = "always"`. No "anyone with write access"
   bypass — humans still hit the review gate.

## Credential requirement (⚠ read before you run)

The `github` provider here needs a token with **Administration: Read and Write**
on `odoocker-goldberrygrove`. This is stricter than the `bootstrap` /
`state-backend` PAT (Actions:Secrets + Metadata only).

Verified 2026-07-05 — neither existing credential is sufficient:

| Credential | `branches/main/protection` read | Verdict |
|---|---|---|
| `AgenticOS Developer` app installation token | `403` | no Administration |
| `GoldberryGrove Infra/github_token` (fine-grained PAT) | `403` | no Administration |

So this env is **blocked on an admin-scoped GitHub credential** until one is
provisioned (a classic PAT with `repo`, or a fine-grained PAT with
Administration:R/W on the repo, stored in 1Password and injected as
`TF_VAR_github_token`). Per CEO guardrail #2, do **not** fall back to a manual
console toggle of the ruleset.

## Run order (once the admin credential exists)

```sh
cd infra/terraform/environments/github-rulesets
cp backend.hcl.example backend.hcl                       # git-ignored
export AWS_ACCESS_KEY_ID=…   AWS_SECRET_ACCESS_KEY=…      # grove-tf-state RW
terraform init -backend-config=backend.hcl

# github_token injected from 1Password, never a tfvars file:
op run --env-file ./op.env -- terraform plan
```

**Gate before apply (guardrail #4):** the plan must import the ruleset and then
show it changing in exactly one way — the added `bypass_actors` entry for app
`4134853`. If the plan proposes removing/altering any rule or required check,
**stop** and fix the transcription; do not apply.

```sh
op run --env-file ./op.env -- terraform apply
```

## End-to-end proof (per GOL-87 "Done when")

1. Open a throwaway `AgenticOS Developer`-authored PR touching a `.noop` on `main`.
2. Confirm the app squash-merges its own PR with no human click; capture the SHA.
3. Confirm a PR with a **failing** required check is still blocked (guardrail #1).
4. Delete the `.noop`.

## Rollback

Delete the `bypass_actors` block (or the whole resource) and `terraform apply`
— reverts to the human-merge gate. Nothing else changes.

## Scope note — AgenticOS

`EngineeringMoonBear/AgenticOS` has a single ruleset (`ClaudeLimits`, id
`16479528`) whose `enforcement` is **`disabled`** — it imposes no active
merge gate. There is therefore nothing to bypass there, so this env manages
only the odoocker ruleset. If AgenticOS ever activates a `main` review gate,
add a second `github_repository_ruleset` resource here mirroring this one.
