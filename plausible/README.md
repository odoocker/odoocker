# Grove analytics — self-hosted Plausible

The privacy-first, cookieless half of the `@grove/analytics` dual-writer
(spec §2 RUM). The Next.js frontends POST pageviews + funnel events
(`add_to_cart` → `begin_checkout` → `purchase`) to this instance's `/api/event`;
**OpenObserve RUM** is the other sink (web vitals, sessions, resource timing).

Plausible is cookieless and stores no personal data — so it needs **no consent
banner** and complements OpenObserve RUM's technical signal with a clean,
shareable marketing dashboard (per-tenant traffic + the commerce funnel).

## Stack

```
docker-compose.plausible.yml
├─ plausible            ghcr.io/plausible/community-edition  (app, :8000)
├─ plausible_db         postgres:16-alpine                   (metadata)
└─ plausible_events_db  clickhouse-server:24.12-alpine       (events)
```

Self-contained: its own Postgres (Plausible pins PG 16; Odoo runs 17) + its own
ClickHouse. It joins the shared `gatheratthegrove_internal` network only so Caddy
can proxy `plausible.<domain>` → `plausible:8000`.

### ClickHouse tuning (`clickhouse/*.xml`)

Vendored **verbatim** from the [plausible/community-edition](https://github.com/plausible/community-edition/tree/master/clickhouse)
repo — they trim ClickHouse's logging + memory use so it fits a small droplet
(ClickHouse is the memory-hungry part of this stack). Mounted read-only into
`config.d/` (and the profile override into `users.d/`). Re-pull them if you bump
the ClickHouse image.

## Bring it up

```bash
cp .env.plausible.example .env.plausible
# generate the secrets:
openssl rand -base64 48   # → PLAUSIBLE_SECRET_KEY_BASE
openssl rand -base64 32   # → PLAUSIBLE_TOTP_VAULT_KEY
# set PLAUSIBLE_POSTGRES_PASSWORD + PLAUSIBLE_BASE_URL, then:
docker compose -f docker-compose.plausible.yml --env-file .env.plausible up -d
```

## First-boot setup

1. Temporarily set `PLAUSIBLE_DISABLE_REGISTRATION=false` and restart.
2. Visit `BASE_URL/register` and create the admin account.
3. Set `PLAUSIBLE_DISABLE_REGISTRATION=invite_only` (or `true`) and restart —
   the instance is now closed.
4. **Add a site per tenant** (Plausible only accepts events for registered
   domains). The domain must match each app's `NEXT_PUBLIC_PLAUSIBLE_DOMAIN`:
   - `goldberrygrove.farm` · `woodworkingeorge.com` · `atthegrovenursery.com` · `gatheringatthegrove.com`
5. Point Caddy: `plausible.gatheringatthegrove.com` → `plausible:8000`, and set
   the frontends' `NEXT_PUBLIC_PLAUSIBLE_HOST` to that URL + flip
   `NEXT_PUBLIC_RUM_ENABLED=true`.

## Notes

- **Resource footprint:** ClickHouse wants ~1–2 GB RAM; the CostOps dashboard
  will surface it. This is the tradeoff for a true self-hosted dual-writer
  (vs. Plausible Cloud) — a deliberate call.
- **No events show up?** The domain isn't registered as a site (step 4), or
  `NEXT_PUBLIC_PLAUSIBLE_DOMAIN` doesn't match it exactly.
- **Data retention** lives in ClickHouse (`plausible-event-data` volume); backs
  up with the rest of the droplet volumes.
