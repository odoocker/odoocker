# Grove Assets — how photos and marketing imagery flow

This doc covers the pipeline for **marketing/brand assets** (hero images, background photography, illustrations, favicons). For other kinds of imagery, see the [What lives where](#what-lives-where) section.

## TL;DR

```bash
# Upload a photo you took today
scripts/upload-assets.sh goldberry ~/Downloads/spring-planting.jpg

# → uploaded to grove-assets/goldberry/spring-planting.jpg
# → served at https://assets.gatheringatthegrove.com/goldberry/spring-planting.jpg
# → CDN cache purged (asset serves immediately, not after edge TTL)
```

Frontends fetch via `${process.env.NEXT_PUBLIC_ASSETS_URL}/goldberry/spring-planting.jpg`.

## What lives where

| Content kind | Home | Why |
|---|---|---|
| **Product photos** | Odoo | Products live in Odoo; product images are attached in Odoo's product form. URL pattern: `${ODOO_URL}${imageUrl}`. |
| **Blog post images** | Ghost | Editorial content flows through Ghost; images are uploaded via Ghost admin. Ghost returns the URL in Content API responses. |
| **Marketing / brand imagery** | **Spaces (this doc)** | Everything else — hero backgrounds, illustrations, brand logos. Not tied to products, not editorial. |
| **OpenObserve Parquet** | Obs droplet MinIO | Log/metric/trace storage backend. Not visible to frontends. |
| **TF remote state** | `grove-tf-state` Spaces bucket | Separate concern; different bucket, different access model. |

## Bucket layout

```
grove-assets/
├── hub/          # hub site brand imagery (empty until sourced)
├── goldberry/    # Goldberry Grove farm imagery (currently the most content)
├── ggg/          # GGG woodshop imagery (empty until sourced)
├── nursery/      # At The Grove Nursery imagery
└── shared/       # Grove logo, favicons, anything cross-tenant
```

The prefix is a convention, not a hard constraint. New tenants: add to `TENANTS` in `scripts/upload-assets.sh` + `var.tenant_prefixes` in `infra/terraform/environments/assets/variables.tf`.

## URLs

| Layer | URL | Notes |
|---|---|---|
| Direct bucket (never use in production) | `https://grove-assets.nyc3.digitaloceanspaces.com/goldberry/hero.jpg` | Bypasses CDN + Cloudflare. Bandwidth-billed. |
| DO CDN (rarely use directly) | `https://<cdn-id>.b-cdn.digitaloceanspaces.com/goldberry/hero.jpg` | Cached at DO edge. |
| **Public / production** | `https://assets.gatheringatthegrove.com/goldberry/hero.jpg` | Cloudflare-proxied CNAME → DO CDN → bucket. Use this. |

`NEXT_PUBLIC_ASSETS_URL` in frontend `.env` files should be set to `https://assets.gatheringatthegrove.com`.

## Uploading

### One file

```bash
scripts/upload-assets.sh <tenant> <local-file> [<remote-path>]
```

Examples:

```bash
# Keeps the basename
scripts/upload-assets.sh goldberry ~/Downloads/DSC_0132.jpg
# → grove-assets/goldberry/DSC_0132.jpg

# Rename during upload
scripts/upload-assets.sh goldberry ~/Downloads/DSC_0132.jpg photos/spring-planting-2026.jpg
# → grove-assets/goldberry/photos/spring-planting-2026.jpg
```

### A directory

Pass a trailing slash on the local path:

```bash
scripts/upload-assets.sh nursery ~/Photos/nursery-summer-2026/
# → uploads every file, keeping the directory structure, under grove-assets/nursery/nursery-summer-2026/
```

`s3cmd sync` semantics: existing files with the same MD5 are skipped, new files uploaded, missing files (in the destination) DO NOT get deleted (safe re-runs).

## Cache invalidation

The DO CDN caches each asset at the edge for the TTL configured in `infra/terraform/environments/assets/variables.tf` (default 1hr). After `upload-assets.sh` uploads a file, it also POSTs to DO's cache purge endpoint for that specific path, so the new version serves immediately.

**Manual purge** (rare — the script handles this automatically):

```bash
# Look up the CDN endpoint ID
DO_TOKEN=$(op read "op://Goldberry Grove - Admin/GoldberryGrove Infra/do_token")
curl -sf -H "Authorization: Bearer $DO_TOKEN" \
  https://api.digitalocean.com/v2/cdn/endpoints | jq '.endpoints[] | select(.custom_domain=="assets.gatheringatthegrove.com")'

# Purge specific paths
CDN_ID=<from above>
curl -X DELETE -H "Authorization: Bearer $DO_TOKEN" -H "Content-Type: application/json" \
  --data '{"files":["goldberry/hero.jpg","goldberry/photos/spring.jpg"]}' \
  https://api.digitalocean.com/v2/cdn/endpoints/$CDN_ID/cache
```

## What's public vs. protected

**Everything in this bucket is public.** By design — marketing imagery has no secrets, and public-read ACL removes the need for signed URLs, per-request auth, or CDN token verification. Uploads happen via an authenticated key stored in 1Password; reads are open to anyone with the URL.

If we ever need protected assets (e.g. draft product photos before launch), those should go somewhere else (a separate bucket with different ACLs, or Odoo's protected attachments). Don't erode this bucket's public-only property.

## Cost

| Component | Rate | Estimated |
|---|---|---|
| Spaces bucket | $5/mo base for 250 GiB storage + 1 TiB egress | **~$5/mo** at current scale |
| Overage | $0.02/GiB egress above 1 TiB | Unlikely for marketing assets |
| CDN | included with Spaces | $0 |
| Cloudflare CNAME | included with existing zone | $0 |

Grove currently has ~25 MB in assets across all tenants — the bucket's baseline is 10000× that headroom.

## First-time setup (once, after `terraform apply`)

The TF apply creates operator Spaces keys. Push them into 1Password so `upload-assets.sh` can find them:

```bash
cd infra/terraform/environments/assets
op run --env-file=.env.op -- terraform output -raw operator_access_key_id | \
  op item edit "GoldberryGrove Infra" "grove_assets_access_key_id[password]=-"
op run --env-file=.env.op -- terraform output -raw operator_secret_key | \
  op item edit "GoldberryGrove Infra" "grove_assets_secret_key[password]=-"
```

Verify:

```bash
op read "op://Goldberry Grove - Admin/GoldberryGrove Infra/grove_assets_access_key_id" | wc -c
op read "op://Goldberry Grove - Admin/GoldberryGrove Infra/grove_assets_secret_key" | wc -c
```

Then `scripts/upload-assets.sh` works.

## Migration from grove-sites public/ directories

Existing assets in `apps/*/public/` (per repo audit 2026-07-01):

| App | Size |
|---|---|
| `apps/goldberry/public/` | 22 MB (25 files, mostly `photos/` + `video/`) |
| `apps/nursery/public/` | 1.5 MB (9 files) |
| `apps/ggg/public/` | 0 bytes |
| `apps/hub/public/` | empty |

Run the one-time migration script:

```bash
# Dry run first — shows what would happen
scripts/migrate-existing-assets.sh --dry-run

# Actual upload
scripts/migrate-existing-assets.sh
```

After migration:
1. Verify a few URLs load (e.g. `https://assets.gatheringatthegrove.com/goldberry/photos/some-file.jpg`)
2. In `grove-sites`, refactor image paths from `/path.jpg` to `${process.env.NEXT_PUBLIC_ASSETS_URL}/${tenant}/path.jpg`
3. Delete the migrated files from `grove-sites/apps/*/public/` (keep favicon.ico + web app manifests + other non-image essentials)
4. Commit + PR the grove-sites changes

Every docker image build after that drops by roughly the asset weight.
