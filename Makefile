# Grove Odoocker — Makefile
# Usage: make <target> [env=sandbox|production] [CONFIRM=yes]

.DEFAULT_GOAL := help

# ── Release ──────────────────────────────────────────────────────────────────

## release-prepare version=vX.Y.Z  — Create a local annotated tag ready to push
.PHONY: release-prepare
release-prepare:
	@if [ -z "$(version)" ]; then \
		echo "Usage: make release-prepare version=vX.Y.Z"; \
		exit 1; \
	fi
	@if ! echo "$(version)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "Version must match vX.Y.Z (e.g. v1.2.3)"; \
		exit 1; \
	fi
	git fetch --tags
	@if git rev-parse $(version) >/dev/null 2>&1; then \
		echo "Tag $(version) already exists. Use a new version."; \
		exit 1; \
	fi
	git tag -a $(version) -m "Release $(version)"
	@echo ""
	@echo "Tag $(version) created locally."
	@echo "Push with: git push origin $(version)"
	@echo ""
	@echo "This will trigger the Release workflow:"
	@echo "  verify-image → (sandbox-smoke) → require-approval → deploy-production → post-deploy-smoke → notify"

# ── Terraform ────────────────────────────────────────────────────────────────
# Set env= on the CLI: make tf-plan env=sandbox
TF_DIR ?= infra/terraform/environments/$(env)

## tf-init env=sandbox|production  — Initialize the Terraform backend
.PHONY: tf-init
tf-init:
	terraform -chdir=$(TF_DIR) init -backend-config=backend.hcl

## tf-plan env=sandbox|production  — Show the planned infrastructure changes
.PHONY: tf-plan
tf-plan:
	terraform -chdir=$(TF_DIR) plan

## tf-apply env=sandbox|production [CONFIRM=yes]  — Apply changes (CONFIRM=yes required for production)
.PHONY: tf-apply
tf-apply:
	@if [ "$(env)" = "production" ] && [ "$(CONFIRM)" != "yes" ]; then \
		echo "Refusing to apply to production without CONFIRM=yes"; exit 1; fi
	terraform -chdir=$(TF_DIR) apply -auto-approve

## tf-destroy env=sandbox|production [CONFIRM=yes]  — Tear down (CONFIRM=yes required for production)
.PHONY: tf-destroy
tf-destroy:
	@if [ "$(env)" = "production" ] && [ "$(CONFIRM)" != "yes" ]; then \
		echo "Refusing to destroy production without CONFIRM=yes"; exit 1; fi
	terraform -chdir=$(TF_DIR) destroy -auto-approve

## tf-output env=sandbox|production  — Show outputs from the last apply
.PHONY: tf-output
tf-output:
	terraform -chdir=$(TF_DIR) output

## tf-fmt env=sandbox|production  — Recursively format Terraform files
.PHONY: tf-fmt
tf-fmt:
	terraform -chdir=$(TF_DIR) fmt -recursive

## tf-validate env=sandbox|production  — Validate config without touching the backend
.PHONY: tf-validate
tf-validate:
	terraform -chdir=$(TF_DIR) init -backend=false && terraform -chdir=$(TF_DIR) validate

# ── State-backend (special: bootstraps the grove-tf-state bucket itself) ─────
# Uses LOCAL Terraform backend so it can run before any other env exists.
# Provider credentials flow from 1Password via `op run --env-file=.env.op`
# so they never enter shell scrollback. See README.md in the env dir.
STATE_BACKEND_DIR := infra/terraform/environments/state-backend

## state-backend-init  — Initialize the local TF backend for state-backend
.PHONY: state-backend-init
state-backend-init:
	terraform -chdir=$(STATE_BACKEND_DIR) init

## state-backend-validate  — Validate state-backend config without touching the backend
.PHONY: state-backend-validate
state-backend-validate:
	terraform -chdir=$(STATE_BACKEND_DIR) init -backend=false && terraform -chdir=$(STATE_BACKEND_DIR) validate

## state-backend-plan  — Show planned changes (creds from 1Password via op run)
.PHONY: state-backend-plan
state-backend-plan:
	op run --env-file=$(STATE_BACKEND_DIR)/.env.op -- terraform -chdir=$(STATE_BACKEND_DIR) plan

## state-backend-apply  — Provision grove-tf-state bucket + Spaces key + GH secrets
.PHONY: state-backend-apply
state-backend-apply:
	op run --env-file=$(STATE_BACKEND_DIR)/.env.op -- terraform -chdir=$(STATE_BACKEND_DIR) apply -auto-approve

## state-backend-output  — Show outputs (bucket name, endpoint, synced GH secret names)
.PHONY: state-backend-output
state-backend-output:
	terraform -chdir=$(STATE_BACKEND_DIR) output

## state-backend-destroy CONFIRM=yes  — Tear down. WARNING: wipes all envs' TF state.
.PHONY: state-backend-destroy
state-backend-destroy:
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "Refusing to destroy state-backend without CONFIRM=yes"; \
		echo "WARNING: destroying grove-tf-state invalidates the state of bootstrap, sandbox, and production envs."; \
		echo "You will also need to remove the prevent_destroy lifecycle block first — see README."; \
		exit 1; fi
	op run --env-file=$(STATE_BACKEND_DIR)/.env.op -- terraform -chdir=$(STATE_BACKEND_DIR) destroy

# ── Infisical (Phase 1 of OIDC retrofit) ─────────────────────────────────────

INFISICAL_SEED_ENV ?= .env.infisical-seed.op

## infisical-seed  — Seed Infisical Cloud project with current secrets (idempotent)
.PHONY: infisical-seed
infisical-seed:
	@if [ ! -f $(INFISICAL_SEED_ENV) ]; then \
		echo "ERROR: $(INFISICAL_SEED_ENV) not found."; \
		echo "  Copy from .env.infisical-seed.op.example and fill in op:// refs."; \
		exit 1; \
	fi
	op run --env-file=$(INFISICAL_SEED_ENV) -- ./scripts/infisical-seed.sh

## infisical-admin-bootstrap  — One-shot: create the tf-infisical-admin
##   machine identity + Universal Auth + Client Secret + store in 1Password.
##   Required before applying the infisical-identities/ TF env.
.PHONY: infisical-admin-bootstrap
infisical-admin-bootstrap:
	./scripts/infisical-admin-bootstrap.sh

## infisical-add-workflow-identity name=NAME workflow=FILE.yml
##   Create a per-workflow OIDC machine identity in Infisical to spec
##   (gh-oidc-odoocker-<name>, OIDC Auth bound to repo+workflow_ref+ref,
##   Viewer role on grove-odoocker). Idempotent — re-run is safe.
##
##   Companion to the infisical-identities/ TF env. Use this for ad-hoc
##   creation; use TF for fleet-managed identities. They DO NOT share
##   state — see scripts/infisical-add-workflow-identity.sh header for
##   the drift relationship + terraform import recipe.
.PHONY: infisical-add-workflow-identity
infisical-add-workflow-identity:
	@if [ -z "$(name)" ] || [ -z "$(workflow)" ]; then \
		echo "Usage: make infisical-add-workflow-identity name=NAME workflow=FILE.yml"; \
		exit 1; \
	fi
	./scripts/infisical-add-workflow-identity.sh --name "$(name)" --workflow "$(workflow)"

# ── infisical-identities TF env (per-workflow OIDC identities) ───────────────

INFISICAL_IDENTITIES_DIR = infra/terraform/environments/infisical-identities

## infisical-identities-init     — terraform init for the infisical-identities env
##   Auto-copies backend.hcl.example → backend.hcl on first run (git-ignored).
.PHONY: infisical-identities-init
infisical-identities-init:
	@if [ ! -f $(INFISICAL_IDENTITIES_DIR)/backend.hcl ]; then \
		echo "  → copying $(INFISICAL_IDENTITIES_DIR)/backend.hcl.example → backend.hcl"; \
		cp $(INFISICAL_IDENTITIES_DIR)/backend.hcl.example $(INFISICAL_IDENTITIES_DIR)/backend.hcl; \
	fi
	op run --env-file=$(INFISICAL_IDENTITIES_DIR)/.env.op -- \
		terraform -chdir=$(INFISICAL_IDENTITIES_DIR) init -backend-config=backend.hcl

## infisical-identities-plan     — terraform plan for the infisical-identities env
.PHONY: infisical-identities-plan
infisical-identities-plan:
	op run --env-file=$(INFISICAL_IDENTITIES_DIR)/.env.op -- \
		terraform -chdir=$(INFISICAL_IDENTITIES_DIR) plan

## infisical-identities-apply    — terraform apply for the infisical-identities env
.PHONY: infisical-identities-apply
infisical-identities-apply:
	op run --env-file=$(INFISICAL_IDENTITIES_DIR)/.env.op -- \
		terraform -chdir=$(INFISICAL_IDENTITIES_DIR) apply

## infisical-identities-output   — show all outputs (identity UUIDs + project UUIDs)
##   Dumps every output as JSON. Output names were renamed in PR #50 (was
##   `workflow_identity_ids`, now `shared_identity_ids` + `prod_workflow_identity_ids`
##   + others); using a name-less `output -json` so this target stays correct
##   across future restructures.
.PHONY: infisical-identities-output
infisical-identities-output:
	op run --env-file=$(INFISICAL_IDENTITIES_DIR)/.env.op -- \
		terraform -chdir=$(INFISICAL_IDENTITIES_DIR) output -json

## infisical-identities-destroy  — terraform destroy (requires CONFIRM=yes)
.PHONY: infisical-identities-destroy
infisical-identities-destroy:
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "Refusing to destroy infisical-identities without CONFIRM=yes"; \
		echo "WARNING: destroying these identities revokes OIDC access for all retrofitted workflows."; \
		echo "  They'd fall back to GH Secrets if the Phase 2 sync is still live; otherwise they'd"; \
		echo "  fail at the OIDC fetch step until re-applied."; \
		exit 1; fi
	op run --env-file=$(INFISICAL_IDENTITIES_DIR)/.env.op -- \
		terraform -chdir=$(INFISICAL_IDENTITIES_DIR) destroy

# ── QA (monolith) — RETIRED 2026-07-04 ──────────────────────────────────────
# The monolith QA droplet stack (TF env, deploy pipeline, fast-iteration SSH
# helpers) was torn down at the accelerated ADR-007 Phase 4+5 cutover. QA now
# lives entirely in infra/terraform/environments/qa-app-platform/ (App
# Platform frontends + Managed PG + Odoo/obs droplets) and serves the plain
# qa.* hostnames. Frontends deploy via grove-sites CI -> GHCR ->
# deploy_on_push; droplets via terraform apply in that env.

# ── QA Level 3 (qa-app-platform) ────────────────────────────────────────────
# Lifecycle for the current QA env. Secrets flow: 1Password (Infisical
# machine identity) -> Infisical (everything else). Requires `op` signed in.

QA_L3_DIR := infra/terraform/environments/qa-app-platform
QA_L3_INFISICAL_PROJECT := 850603f8-e175-4c38-9038-97a1e69d72e6
QA_L3_OP_ITEM := qvkpvg24x2wbsn6owjyvn4vhx4

## qa-l3-up: apply the full Level 3 QA env (droplets re-bootstrap from cloud-init)
.PHONY: qa-l3-up
qa-l3-up:
	@INF_TOKEN="$$(infisical login --method=universal-auth \
		--client-id="$$(op item get $(QA_L3_OP_ITEM) --fields label=infisical_admin_client_id --reveal)" \
		--client-secret="$$(op item get $(QA_L3_OP_ITEM) --fields label=infisical_admin_client_secret --reveal)" \
		--plain)"; \
	infisical run --projectId=$(QA_L3_INFISICAL_PROJECT) --env=prod --token="$$INF_TOKEN" -- bash -c '\
		export AWS_ACCESS_KEY_ID="$$SPACES_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$$SPACES_SECRET_ACCESS_KEY" \
			TF_VAR_do_token="$$DIGITALOCEAN_TOKEN" TF_VAR_cloudflare_api_token="$$CLOUDFLARE_API_TOKEN" \
			TF_VAR_grove_revalidate_secret="$$GROVE_REVALIDATE_SECRET" TF_VAR_odoo_api_keys="$$ODOO_API_KEYS_TF_JSON"; \
		terraform -chdir=$(QA_L3_DIR) init -backend-config=backend.hcl -input=false >/dev/null; \
		terraform -chdir=$(QA_L3_DIR) apply -input=false'

## qa-l3-teardown: destroy compute only (apps + droplets); PG data/DNS/certs survive
.PHONY: qa-l3-teardown
qa-l3-teardown:
	bash scripts/qa-l3-teardown.sh compute

## qa-l3-teardown-all: destroy EVERYTHING incl. Managed PG data + DNS zone
.PHONY: qa-l3-teardown-all
qa-l3-teardown-all:
	bash scripts/qa-l3-teardown.sh all

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo ""
	@echo "Grove Odoocker — Makefile targets"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo ""
