# Docker Compose Command Reference for Grove

## Compose File Layering

Always layer compose files in this order:

```bash
BASE="docker-compose.yml"
GROVE="docker-compose.override.grove.yml"
LOCAL="docker-compose.override.local.yml"
SANDBOX="docker-compose.override.sandbox.yml"
PROD="docker-compose.override.production.yml"
```

## Environment Shortcuts

### Local (Odoo + Postgres only)
```bash
docker compose -f docker-compose.yml -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d
```

### Local with Grove (full stack)
```bash
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.local.yml \
  --profile odoo --profile postgres --profile nginx up -d
```

### Sandbox/QA
```bash
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.sandbox.yml \
  --profile odoo --profile postgres --profile nginx up -d
```

### Production
```bash
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  --profile odoo --profile postgres --profile nginx --profile proxy --profile acme up -d
```

### Production with all optional services
```bash
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  --profile odoo --profile postgres --profile nginx --profile proxy --profile acme \
  --profile keydb --profile minio --profile pgadmin --profile git-sync up -d
```

## Common Operations

```bash
# View running containers
docker compose ps

# View logs (follow)
docker compose logs -f odoo
docker compose logs -f postgres
docker compose logs -f ghost-goldberry ghost-ggg ghost-nursery

# Restart a single service
docker compose restart odoo

# Rebuild a single service
docker compose build odoo
docker compose up -d --no-deps odoo

# Shell into a container
docker compose exec odoo bash
docker compose exec postgres psql -U odoo

# Run Odoo scaffold (create new module)
docker compose exec odoo odoo scaffold my_module /usr/lib/python3/dist-packages/odoo/custom-addons/

# Update Odoo modules
docker compose exec odoo odoo -u my_module --stop-after-init

# Initialize Odoo with specific modules
docker compose exec odoo odoo -i base,sale,purchase --stop-after-init
```

## Profile Reference

| Profile | Services | When to Use |
|---------|----------|-------------|
| `odoo` | Odoo | Always |
| `postgres` | PostgreSQL | Always (unless using managed DB) |
| `nginx` | Inner Nginx | When testing proxy chain |
| `proxy` | nginx-proxy | Production (auto-routes domains) |
| `acme` | Let's Encrypt companion | Production (auto TLS) |
| `keydb` | KeyDB (Redis) | When USE_REDIS=true |
| `minio` | MinIO (S3) | When USE_S3=true |
| `pgadmin` | pgAdmin 4 | When USE_PGADMIN=true |
| `git-sync` | Custom modules sync | When USE_CUSTOM_MODULES_SYNC=true |

## Database Operations

```bash
# Create a database dump
docker compose exec postgres pg_dump -U odoo -Fc gatheratthegrove > dump.backup

# Restore a database dump
docker compose exec -T postgres pg_restore -U odoo -d gatheratthegrove --clean --if-exists < dump.backup

# Create a fresh database
docker compose exec postgres createdb -U odoo grove_dev

# Drop a database (careful!)
docker compose exec postgres dropdb -U odoo grove_dev

# List databases
docker compose exec postgres psql -U odoo -l
```

## Volume Management

```bash
# List volumes
docker volume ls | grep grove

# Backup a volume
docker run --rm -v gatheratthegrove_pg-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/pg-data-backup.tar.gz -C /data .

# Restore a volume
docker run --rm -v gatheratthegrove_pg-data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/pg-data-backup.tar.gz -C /data
```
