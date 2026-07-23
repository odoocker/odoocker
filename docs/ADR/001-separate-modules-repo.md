# ADR-001: Separate Repository for Custom Odoo Modules

**Status:** Accepted
**Date:** 2026-04-01

## Context

Custom Odoo modules were previously stored in `odoo/custom-addons/` within the odoocker infrastructure repo. This coupled module development with infrastructure changes, requiring a full Docker image rebuild to deploy module updates.

## Decision

Move custom modules to a dedicated repository (`grove-odoo-modules`) and deploy them via the existing git-sync sidecar container.

## Consequences

**Benefits:**
- Module updates deploy without Docker image rebuilds (zero-downtime)
- Separate CI pipelines — infrastructure and module code evolve independently
- Clear ownership boundary: infrastructure team vs. module developers
- GitHub webhook triggers instant sync (< 5 seconds vs. minutes for a rebuild)

**Trade-offs:**
- Two repos to manage instead of one
- Local development requires both repos cloned side-by-side (mitigated by bind mount in compose override)
- Module dependencies on infrastructure (e.g., pip packages) still require an image rebuild

**Local dev workflow:**
- `docker-compose.override.local.yml` bind-mounts `../grove-odoo-modules` to `/workspace/current`
- Changes are instant — no git-sync container needed locally
