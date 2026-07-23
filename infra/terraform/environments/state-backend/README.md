# state-backend — bootstraps the shared TF state bucket

This env exists for **one reason**: to break the chicken-and-egg of "Terraform
needs a Spaces bucket for its state, but the bucket needs to be created by
Terraform."

It uses a **local backend** so it can be applied before any other TF env
exists. Every other env in this repo (`bootstrap/`, `sandbox/`,
`production/`, and any future env) uses the bucket this env creates as its
S3 remote backend.

Apply it **once**, rarely touch it again.

## What it manages

| Resource | Notes |
|---|---|
| `digitalocean_spaces_bucket.tf_state` | The bucket (`grove-tf-state` by default). `prevent_destroy = true` because nuking it wipes every other env's state. |
| `digitalocean_spaces_key.tf_state_rw` | Bucket-scoped read/write access key. Created via the DO REST API (using `var.do_token`); outputs an S3-style access_key + secret_key. |
| `github_actions_secret.state_backend["SPACES_ACCESS_KEY_ID"]` | Synced to odoocker repo. |
| `github_actions_secret.state_backend["SPACES_SECRET_ACCESS_KEY"]` | Synced to odoocker repo. The workflows that need these (`terraform-drift.yml`, `sandbox-deploy.yml`) read them as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars. |

## Prerequisites (one-time setup)

Four credentials need to exist in 1Password under
**Goldberry Grove - Admin → GoldberryGrove Infra**:

| Field | What it is | How to create |
|---|---|---|
| `do_token` (concealed) | DO API token with `spaces` (read, update) + `spaces_key` (create, create_credentials, read, update, delete) scopes | DO Cloud Panel → API → Tokens → Generate New Token → **Fully Scoped Access** → tick those 7 scopes |
| `github_token` (concealed) | GitHub PAT — either classic with `repo` scope, OR fine-grained scoped to `Goldberry-Playground/odoocker-goldberrygrove` with **Actions: Secrets — Read and Write** + **Metadata: Read** | github.com/settings/personal-access-tokens/new → "Fine-grained" → repository access: only `odoocker-goldberrygrove` |
| `spaces_bootstrap_access_key_id` (concealed) | "Plumbing" Spaces access key, used by the DO Terraform provider for bucket-level operations | DO Cloud Panel → API → Spaces Keys → Generate New Key → name `tf-provider-auth` → **All Buckets / Full Access** |
| `spaces_bootstrap_secret_key` (concealed) | Companion secret to the above (DO shows it once at key generation) | Same flow as above; copy both fields from the one-time secret display before closing the dialog |

The `do_token` and `github_token` likely already exist in your `GoldberryGrove Infra` item.
The two `spaces_bootstrap_*` fields are new — see "Why two Spaces keys" below.

## Why two Spaces keys

This env ends up managing **two** Spaces access keys with different lifecycles:

| Key | Source | Used by | Why it has to exist separately |
|---|---|---|---|
| **Bootstrap / plumbing** (`spaces_bootstrap_*`) | Manually generated in DO Cloud Panel, stored in 1Password | The DO Terraform provider itself — for bucket-level operations (`digitalocean_spaces_bucket` create/refresh/lifecycle) | The DO provider's `digitalocean_spaces_bucket` resource talks the S3 protocol, not the DO REST API. It needs Spaces creds to even create the bucket — chicken-and-egg if you try to provision them in the same apply. So it's manually pre-created, long-lived, and account-wide. |
| **Workflow-scoped** (`grove-tf-state-rw`) | Created BY this Terraform env (`digitalocean_spaces_key` resource, via the DO REST API + do_token) | GitHub Actions workflows on odoocker (`terraform-drift.yml`, `sandbox-deploy.yml`) as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars | Bucket-scoped, least-privilege, lifecycle managed by Terraform, rotates by re-applying. Workflow consumers never see the bootstrap key. |

The bootstrap key is "Terraform's plumbing." The workflow key is "what GitHub Actions reads." Keeping them separate means rotating one never affects the other, and a workflow-secret leak doesn't compromise the provider's ability to manage the bucket.

## Apply

From the **odoocker repo root**:

```bash
# One-time per machine: initialize the (local) backend
make state-backend-init

# Apply. The Makefile target wraps `op run` so secrets flow from 1Password
# into TF_VAR_* env vars without ever materializing in shell history.
make state-backend-apply
```

After apply, the bucket exists, the key is provisioned, and both
`SPACES_ACCESS_KEY_ID` and `SPACES_SECRET_ACCESS_KEY` are set on the
odoocker GitHub repo. Workflows that need them work on the next run.

## Validate

```bash
# Show outputs (bucket name, endpoint, list of synced secret names)
make state-backend-output

# Confirm the GH secrets landed
gh secret list --repo Goldberry-Playground/odoocker-goldberrygrove \
  | grep SPACES_
```

## Destroy

`terraform destroy` will **refuse** to remove the bucket because of the
`prevent_destroy` lifecycle guard. To genuinely wipe everything:

1. Edit `main.tf` and remove the `lifecycle { prevent_destroy = true }`
   block on `digitalocean_spaces_bucket.tf_state`.
2. `terraform apply` (to register the lifecycle change in state).
3. `make state-backend-destroy CONFIRM=yes`.

If you destroy this env without first migrating other envs off this bucket,
**every other env loses its state file**. Their resources stay alive in DO
but Terraform forgets they exist; you'd have to `terraform import` each one.
Don't do this casually.

## What if I lose the local state file?

Every resource this env manages is also visible in:

- **The bucket**: DO Cloud Panel → Spaces (look for `grove-tf-state`)
- **The Spaces key**: DO Cloud Panel → API → Spaces Keys
- **The GH secrets**: odoocker repo → Settings → Secrets and variables → Actions

Recovery: `terraform import` each resource back into the new local state file.
The imports are:

```bash
terraform import digitalocean_spaces_bucket.tf_state grove-tf-state
terraform import digitalocean_spaces_key.tf_state_rw "<access_key_id>,grove-tf-state"
terraform import 'github_actions_secret.state_backend["SPACES_ACCESS_KEY_ID"]' \
  odoocker-goldberrygrove/SPACES_ACCESS_KEY_ID
terraform import 'github_actions_secret.state_backend["SPACES_SECRET_ACCESS_KEY"]' \
  odoocker-goldberrygrove/SPACES_SECRET_ACCESS_KEY
```

(github_actions_secret can't read back the plaintext value, so an import of
a secret with a different plaintext than what was originally written will
on next apply re-write it. That's safe — the workflows just get a new key
in their env.)

## Why local backend (and not, say, a separate-bootstrap bucket)?

Three options were considered:

1. **Local backend** (what this env uses). State file lives on the operator's
   machine, in `.gitignore`. Pros: zero infrastructure prerequisites; cheap to
   re-bootstrap if lost. Cons: state isn't sync'd across operators (Josh is
   solo, so not a concern today).
2. **Bootstrap-of-the-bootstrap** (a *separate* Spaces bucket just to hold
   this env's state). Possible but pushes the problem one level up — and that
   second bucket also has to be created somewhere.
3. **HCP Terraform free tier**. Cloud-hosted state with OIDC. Solid option,
   but introduces a third-party dependency for ~1 KB of state. Worth
   reconsidering if/when the operator count grows beyond Josh.

Option 1 is the right shape for current scale.

## Related

- `infra/terraform/environments/bootstrap/` — preview pipeline secrets +
  preview snapshot bucket. Uses `grove-tf-state` as its backend, so this
  env must be applied **first**.
- `infra/terraform/environments/sandbox/`, `production/` — droplet TF.
  Same deal.
- Grove Deployment Decisions 2026-06-11 (vault) — design context for the
  whole pipeline.
