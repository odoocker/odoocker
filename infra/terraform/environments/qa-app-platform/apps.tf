###############################################################################
# App Platform apps — Level 3 QA Phase 2.
#
# Each of the 4 frontends (hub, goldberry, ggg, nursery) lives as its own
# digitalocean_app resource so a broken deploy in one tenant can't cascade
# to the others (App Platform's concurrency model is per-app, not per-spec).
#
# Image source: GHCR (grove-sites CI publishes on push to main). App Platform
# redeploys on tag change via `deploy_on_push`, so a `latest` retag from
# grove-sites CI is enough to trigger a rollout -- no rebuild inside App
# Platform, no ~5-min compile per push. Same pattern as the monolith QA env
# which uses these images with a compose HUB_TAG env.
#
# Domain routing: each app gets its own <name>.qa-l3.<apex> vanity host.
# App Platform issues + rotates the cert; we don't manage cert lifecycles
# here. The DNS CNAME lives inside the DO-managed qa-l3 zone (which was
# delegated from Cloudflare via main.tf's `cloudflare_record.qa_ns`).
#
# Phase 2 landing plan:
#   - PoC: hub only (this file, initial commit).
#   - Then: goldberry / ggg / nursery, one PR each -- copy the hub resource
#     and swap tenant-specific bits (image, port, ODOO_URL scoping,
#     GHOST_URL, secrets). Bundling all 4 in one PR is possible but the
#     failure surface for a first-time App Platform apply is unknown; one
#     PR at a time makes rollback surgical.
###############################################################################

# ── Hub (proof-of-concept for the Phase 2 pattern) ─────────────────────────
#
# gatheringatthegrove.com's Level 3 QA equivalent: hub.qa-l3.gatheringatthegrove.com.
# Reads from the L3 Odoo droplet (odoo.qa-l3.*) over its public URL --
# App Platform apps and DO Droplets do NOT share a private network by default,
# so all Odoo/Ghost fetches go over TLS on the public internet. Rate-limit
# and latency implications live inside grove-sites' KeyDB cache TTL config,
# not here.
#
# HUB_GHOST_URL points at a stub for now because L3 has no Ghost instance
# (Phase C's per-tenant Ghost landed on the MONOLITH QA droplet only --
# whether L3 adds Ghost as public-facing droplets or a managed service is
# tracked as a separate follow-up). Journal pages render empty state until
# the follow-up ships. Cart / product / storefront pages work fully.

resource "digitalocean_app" "hub" {
  spec {
    name   = "grove-hub-qa"
    region = "nyc"

    service {
      name               = "hub"
      instance_size_slug = "apps-s-1vcpu-0.5gb"
      instance_count     = 1
      http_port          = 3000

      # Pull the prebuilt image from GHCR. grove-sites CI publishes on push to
      # main; a tag rotation there triggers this app's redeploy automatically.
      image {
        registry_type = "GHCR"
        registry      = "goldberry-playground"
        repository    = "grove-hub"
        tag           = var.hub_image_tag
        deploy_on_push {
          enabled = true
        }
      }

      health_check {
        http_path             = "/"
        initial_delay_seconds = 30
        period_seconds        = 30
        timeout_seconds       = 5
        success_threshold     = 1
        failure_threshold     = 3
      }

      # Hub's marketplace.ts reads process.env.GROVE_ODOO_URL. Level 3 Odoo
      # is on its own droplet with a public URL; the app pulls over TLS.
      env {
        key   = "GROVE_ODOO_URL"
        value = "https://odoo.${local.qa_zone}"
        scope = "RUN_AND_BUILD_TIME"
      }

      # Hub's journal (apps/hub/app/journal/*.tsx) uses HUB_GHOST_URL +
      # HUB_GHOST_CONTENT_API_KEY. No Ghost in L3 yet -- stub URL + stub
      # key satisfy grove-sites' requireEnv() but the /journal fetch will
      # 404, and the page renders empty-state.
      env {
        key   = "HUB_GHOST_URL"
        value = "https://qa-stub.example.com"
        scope = "RUN_AND_BUILD_TIME"
      }

      env {
        key   = "HUB_GHOST_CONTENT_API_KEY"
        value = "qa-stub-no-ghost-key-yet"
        scope = "RUN_AND_BUILD_TIME"
      }

      # Signed webhook secret so grove-sites' /api/revalidate can be poked by
      # Odoo / Ghost when their content changes. Rotates whenever this TF
      # applies with a new var value. Sensitive: never printed by outputs.
      # GENERAL, not SECRET, for the same drift reason as ODOO_API_KEY on
      # the tenant apps (provider issues #869/#514: SECRET envs re-diff on
      # every plan and would page the nightly drift alert).
      env {
        key   = "GROVE_REVALIDATE_SECRET"
        value = var.grove_revalidate_secret
        scope = "RUN_AND_BUILD_TIME"
      }

      env {
        key   = "NEXT_TELEMETRY_DISABLED"
        value = "1"
        scope = "RUN_AND_BUILD_TIME"
      }

      # Client-visible QA banner so operators poking around L3 don't confuse
      # it with prod. NEXT_PUBLIC_ prefix is inlined into the client bundle
      # at build time -- App Platform surfaces this from BUILD_TIME scope.
      env {
        key   = "NEXT_PUBLIC_QA_BANNER"
        value = "QA (Level 3)"
        scope = "BUILD_TIME"
      }
    }

    # Custom domain. App Platform provisions a LE cert + writes a CNAME into
    # the DO-managed qa-l3 zone pointing at the app's default URL. No manual
    # digitalocean_record needed.
    domain {
      name = "hub.${local.qa_zone}"
      type = "PRIMARY"
      zone = digitalocean_domain.qa.name
    }

    # Alerts fire into DO's built-in email channel by default. If we want
    # Discord routing, that's a separate wiring step through Keep (which
    # already runs in the L3 obs droplet).
    alert {
      rule = "DEPLOYMENT_FAILED"
    }
    alert {
      rule = "DOMAIN_FAILED"
    }
  }
}

# ── Tenant storefronts ──────────────────────────────────────────────────────
#
# Same shape as the hub PoC above (validated 2026-07-02: GHCR pull worked,
# app ACTIVE + HTTP 200 within ~2 min of apply), stamped out per tenant via
# for_each. The original plan was one PR per tenant to keep first-apply risk
# surgical -- the hub PoC retired that risk, so all three land together.
#
# Env-var shape mirrors the monolith QA compose (environments/qa/compose/
# docker-compose.qa.yml): tenants read ODOO_URL (not the hub's
# GROVE_ODOO_URL) and their tenant.secrets.ts requireEnv() throws on
# empty values in production, so Ghost/Odoo-key placeholders use the same
# qa-stub-* sentinels. Ghost stays stubbed until the L3 Ghost story lands
# (per-tenant droplet Ghost is monolith-QA-only for now -- see docs/GHOST.md).
#
# All three tenant images listen on container port 3001 (ENV PORT=3001 in
# each Dockerfile); only the hub differs (3000).

locals {
  tenant_apps = {
    goldberry = { image = "grove-goldberry" }
    ggg       = { image = "grove-ggg" }
    nursery   = { image = "grove-nursery" }
  }
}

resource "digitalocean_app" "tenant" {
  for_each = local.tenant_apps

  spec {
    name   = "grove-${each.key}-qa"
    region = "nyc"

    service {
      name               = each.key
      instance_size_slug = "apps-s-1vcpu-0.5gb"
      instance_count     = 1
      http_port          = 3001

      image {
        registry_type = "GHCR"
        registry      = "goldberry-playground"
        repository    = each.value.image
        tag           = var.tenant_image_tag
        deploy_on_push {
          enabled = true
        }
      }

      health_check {
        http_path             = "/"
        initial_delay_seconds = 30
        period_seconds        = 30
        timeout_seconds       = 5
        success_threshold     = 1
        failure_threshold     = 3
      }

      env {
        key   = "ODOO_URL"
        value = "https://odoo.${local.qa_zone}"
        scope = "RUN_AND_BUILD_TIME"
      }

      # Real per-tenant bearer key (global-scope res.users.apikeys on the
      # QA Odoo). Deliberately GENERAL, not SECRET: DO returns SECRET envs
      # encrypted, so the provider re-diffs them on every plan (upstream
      # digitalocean provider issues #869/#514, still open at 2.92) --
      # which would fire the nightly drift alert forever. The value lives
      # in TF state regardless of type; state stays in the Spaces backend,
      # never in the repo (see Grove Secrets Handling Policy). Keys are
      # revocable in Odoo (Settings -> Users -> API Keys).
      env {
        key   = "ODOO_API_KEY"
        value = var.odoo_api_keys[each.key]
        scope = "RUN_AND_BUILD_TIME"
      }

      env {
        key   = "GHOST_URL"
        value = "https://qa-stub.example.com"
        scope = "RUN_AND_BUILD_TIME"
      }

      env {
        key   = "GHOST_CONTENT_KEY"
        value = "qa-stub-no-ghost-key-yet"
        scope = "RUN_AND_BUILD_TIME"
      }

      env {
        key   = "NEXT_TELEMETRY_DISABLED"
        value = "1"
        scope = "RUN_AND_BUILD_TIME"
      }

      env {
        key   = "NEXT_PUBLIC_QA_BANNER"
        value = "QA (Level 3)"
        scope = "BUILD_TIME"
      }
    }

    domain {
      name = "${each.key}.${local.qa_zone}"
      type = "PRIMARY"
      zone = digitalocean_domain.qa.name
    }

    alert {
      rule = "DEPLOYMENT_FAILED"
    }
    alert {
      rule = "DOMAIN_FAILED"
    }
  }
}
