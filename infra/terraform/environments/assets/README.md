# Grove Assets — shared Spaces bucket + CDN

Shared infrastructure for frontend marketing/brand assets (hero images, illustrations, background photography). Distinct from every other TF env in this repo because it serves ALL environments (local dev + QA monolith + QA Level 3 + future prod).

## What this manages

| Resource | Purpose |
|---|---|
| `digitalocean_spaces_bucket.assets` | Bucket named `grove-assets` (public-read) |
| `digitalocean_spaces_key.assets_rw` | Operator key for uploads (via `scripts/upload-assets.sh`) |
| `aws_s3_bucket_cors_configuration.assets` | CORS scoped to frontend hostnames only |
| `digitalocean_cdn.assets` | DO CDN fronting the bucket at `assets.gatheringatthegrove.com` |
| `cloudflare_record.assets` | Cloudflare-proxied CNAME → CDN endpoint |

## Bucket layout

```
grove-assets/
├── hub/          # hub site brand imagery
├── goldberry/    # Goldberry Grove farm imagery
├── ggg/          # GGG woodshop imagery
├── nursery/      # At The Grove Nursery imagery
└── shared/       # Grove logo, favicons, anything cross-tenant
```

Prefixes aren't hard-coded — the bucket accepts anything. `var.tenant_prefixes` just documents the convention.

## What lives here vs. NOT

**Lives here:**
- Hero images, brand illustrations, background photography
- Marketing/editorial imagery not tied to a specific product or blog post
- Anything referenced by frontend markup via `NEXT_PUBLIC_ASSETS_URL`

**Doesn't:**
- **Product photos** → Odoo (`${ODOO_URL}${imageUrl}` pattern)
- **Blog post images** → Ghost (Content API returns URLs)
- **OpenObserve Parquet** → obs droplet MinIO (or DO Spaces `grove-openobserve` if migrated)
- **TF remote state** → `grove-tf-state` bucket

## Cost

- Spaces bucket: **$5/mo** for the first 250 GiB + $0.02/GiB outbound above 1 TiB
- CDN: included with Spaces (no separate charge)
- Cloudflare CNAME: free (existing zone)

Total: **~$5/mo baseline**, scaling with actual usage.

## Applying

```bash
# One-time init
cp backend.hcl.example backend.hcl
cd $PWD  # ensure you're in this directory
op run --env-file=.env.op -- terraform init -backend-config=backend.hcl

# Standard workflow
op run --env-file=.env.op -- terraform plan
op run --env-file=.env.op -- terraform apply
```

After apply, capture the operator key + secret from outputs and push into 1Password:

```bash
op run --env-file=.env.op -- terraform output -raw operator_access_key_id | \
  op item edit "GoldberryGrove Infra" grove_assets_access_key_id[password]=-
op run --env-file=.env.op -- terraform output -raw operator_secret_key | \
  op item edit "GoldberryGrove Infra" grove_assets_secret_key[password]=-
```

## Wiring into frontends

Every `apps/<tenant>` app gets:

```
NEXT_PUBLIC_ASSETS_URL=https://assets.gatheringatthegrove.com
```

Then in code:

```tsx
<Image src={`${process.env.NEXT_PUBLIC_ASSETS_URL}/goldberry/hero-orchard.jpg`} ... />
```

## Uploading

Use `scripts/upload-assets.sh` (in the odoocker repo root):

```bash
scripts/upload-assets.sh goldberry ~/Downloads/new-hero-photo.jpg
# → uploaded to grove-assets/goldberry/new-hero-photo.jpg
# → served at https://assets.gatheringatthegrove.com/goldberry/new-hero-photo.jpg
# → CDN cache purged for that path
```

See `docs/ASSETS.md` for the full workflow.
