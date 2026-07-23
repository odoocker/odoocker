# Ghost CMS in QA

QA runs one Ghost instance per tenant (goldberry / ggg / nursery). Each has
its own SQLite database inside its container's volume and is reachable only
from inside the Docker network — storefronts fetch posts server-side via the
Content API, so there's no public HTTPS endpoint for Ghost, no Caddy vhost,
and no cert to worry about.

Landed in Phase C on 2026-07-01 (Asana #97). Before that, QA had zero Ghost
containers and storefronts either pulled from prod `goldberrygrove.farm`
(coupling QA to prod) or fetched from a stub URL that always failed.

## What's in the compose

`infra/terraform/environments/qa/compose/docker-compose.qa.yml` defines:

| Service | Internal URL | Volume |
|---|---|---|
| `ghost-goldberry` | `http://ghost-goldberry:2368` | `ghost-goldberry-data` |
| `ghost-ggg` | `http://ghost-ggg:2369` | `ghost-ggg-data` |
| `ghost-nursery` | `http://ghost-nursery:2370` | `ghost-nursery-data` |

Volumes are **ephemeral** — content resets on droplet recreate. That's
intentional for QA; when we need durability, follow the pattern in
[`docs/ADR/005-qa-cert-resilience-stack.md`](./ADR/005-qa-cert-resilience-stack.md)
and mount them onto the persistent block volume that already hosts
`caddy-data`.

## Bootstrap — automatic since task 97d (2026-07-02)

Fresh Ghost containers boot with no admin user and no API keys. Cloud-init
now handles the whole seed automatically after `docker compose up`:

1. `/opt/grove/qa-ghost-autoseed.sh` (written by cloud-init from
   `scripts/qa-ghost-autoseed.sh`) waits up to 120s per Ghost container
2. Runs `/opt/grove/ghost-bootstrap.js` INSIDE each ghost container via
   `docker compose exec -T ... node` — the ghost:5 image ships node 18+,
   so there's no dependency on any other repo or image
3. Writes `GHOST_KEY_{GOLDBERRY,GGG,NURSERY}` into `/etc/grove/.env`
4. Recreates the 4 storefronts so they pick the keys up

**Keys never leave the droplet.** They're only valid for the Ghosts on
that droplet, and both die together on recreate — so nothing gets pushed
to Infisical. The per-droplet Ghost admin password is generated once and
stored at `/etc/grove/.ghost-admin-pass` (0600); read it over SSH if you
need to log into a Ghost admin UI.

The seed is **non-fatal by design**: if it fails, the deploy still
completes (the sentinel gates on hub serving, which doesn't need Ghost),
`/blog` pages render empty state, and the log is at
`/var/log/grove-ghost-seed.log`.

## Manual re-run / fallback

Safe to re-run any time — Ghost setup is skipped when already done, and
the integration lookup is name-based so re-runs upsert the SAME keys:

```bash
ssh -i ~/.ssh/grove-qa-admin root@<droplet_ip> \
  'bash /opt/grove/qa-ghost-autoseed.sh'
```

(The older `scripts/setup-all-ghosts.sh` + push-to-Infisical flow is
retired for QA — it also assumed a `/workspace/current` git-sync mount
that the QA droplet never had. Kept in-tree only as a reference for
local-compose seeding.)

## Verify

```bash
# Storefronts should now render real /blog pages
curl -sI https://goldberry.qa.gatheringatthegrove.com/blog | head -3
curl -sI https://ggg.qa.gatheringatthegrove.com/blog | head -3
curl -sI https://nursery.qa.gatheringatthegrove.com/blog | head -3
```

Expect HTTP 200. If a `/blog` page renders "no posts," the key wiring is
fine but the Ghost has no published posts yet — log into
`http://ghost-goldberry:2368/ghost/` via an SSH tunnel and publish a test
post:

```bash
ssh -i ~/.ssh/grove-qa-admin -L 2368:ghost-goldberry:2368 root@<droplet_ip>
# Then browse http://localhost:2368/ghost/ on your laptop.
```

## Idempotency

The autoseed is safe to re-run: Ghost setup is skipped when already done,
the integration lookup is name-based (re-runs return the SAME keys), and
the `.env` write is an upsert. Storefront recreation via `docker compose
up -d` only touches services whose config changed — the rest of the stack
is untouched.

## Hub's editorial feed

The hub's journal pages (`apps/hub/app/journal/*.tsx`) pull from
`ghost-goldberry` in QA too, so hub's editorial content is testable without
touching prod. In prod (post-Level-3), hub will point at a dedicated
editorial Ghost — see ADR-007 Phase 6.
