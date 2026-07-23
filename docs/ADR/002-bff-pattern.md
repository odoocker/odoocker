# ADR-002: Backend-for-Frontend Pattern with Next.js

**Status:** Accepted
**Date:** 2026-04-01

## Context

Three custom React websites need to consume data from Odoo (e-commerce, inventory, CRM) and Ghost CMS (blog content). Direct browser-to-Odoo calls would expose the Odoo API publicly, require complex CORS configuration, and prevent server-side caching.

## Decision

Each brand website is a Next.js app whose API routes serve as a Backend-for-Frontend (BFF). The BFF makes server-to-server calls to Odoo and Ghost, caches responses in KeyDB, and returns optimized payloads to the browser.

Three separate Next.js apps (one per brand) share a common `@grove/api-client` package via Turborepo.

## Consequences

**Benefits:**
- Odoo API never exposed to the public internet (BFF calls are server-to-server)
- No CORS complexity — same-origin requests from browser to Next.js
- Server-side caching in KeyDB reduces Odoo load
- ISR/SSG for Ghost blog content (near-zero latency for blog pages)
- Independent deployments per brand

**Trade-offs:**
- Three Next.js containers add ~300MB RAM each to the droplet
- Shared API client package requires Turborepo coordination
- One more hop in the request chain (browser → Next.js → Odoo)
