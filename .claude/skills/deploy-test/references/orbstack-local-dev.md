# OrbStack Local Development Guide

## Why OrbStack for Grove

OrbStack is a lightweight Docker runtime for macOS that replaces Docker Desktop.
It provides superior performance, lower memory usage, and native macOS networking.

## OrbStack vs Docker Desktop

| Feature | OrbStack | Docker Desktop |
|---------|----------|----------------|
| Memory idle | ~200 MB | ~2 GB |
| Container startup | < 1s | 2-5s |
| File sync (VirtioFS) | Native, fast | gRPC-FUSE, slower |
| Linux VM shell | `orb` command | N/A |
| Kubernetes | Built-in, toggle on/off | Built-in, always running |
| Port forwarding | Automatic | Automatic |
| DNS for containers | `<name>.orb.local` | N/A |
| Cost | Free for personal | Free, paid for business |

## Docker Context

OrbStack installs as a Docker context. Verify it's active:

```bash
docker context ls
# Should show: orbstack *

# If not active:
docker context use orbstack
```

## Container DNS (OrbStack Exclusive)

OrbStack provides automatic DNS resolution for containers:

```bash
# Access containers by name (no port mapping needed for inter-container)
# Format: <container-name>.orb.local

# This is in ADDITION to localhost port mapping
# Both work simultaneously:
curl http://localhost:8069          # Via port mapping
curl http://odoo.orb.local:8069    # Via OrbStack DNS (if container named "odoo")
```

## Linux VM Access

```bash
# Drop into the OrbStack Linux VM
orb

# Inside the VM you can:
# - Inspect Docker internals
# - Check file mount performance
# - Debug networking issues
# - Run Linux-specific tools

# Run a command without entering the shell
orb uname -a
```

## Resource Management

```bash
# Check OrbStack status
orbctl status

# OrbStack respects compose resource limits:
# docker-compose.override.production.yml sets:
#   odoo: memory 2G limit, 512M reservation
#   postgres: memory 2G limit, 256M reservation
# These are enforced by OrbStack's Linux VM

# For local dev (override.local.yml):
# No resource limits — OrbStack dynamically allocates
```

## Performance Tips for Grove Stack

1. **Volume mounts are fast** — OrbStack uses VirtioFS, so mounting
   `./odoo/extra-addons` and `./odoo/custom-addons` doesn't have the
   performance penalty of older Docker Desktop setups.

2. **Build caching works** — OrbStack preserves Docker build cache between
   restarts. First build is slow, subsequent builds are fast.

3. **PostgreSQL shared_buffers** — The `shm_size: '1536mb'` in
   `docker-compose.yml` works correctly with OrbStack (Docker Desktop
   sometimes had issues with large shm_size).

4. **Ghost SQLite** — Each Ghost instance uses SQLite, not PostgreSQL.
   The volume mounts (`ghost-goldberry-data`, etc.) are fast with VirtioFS.

## Kubernetes Mode (Optional)

For testing Kubernetes deployments before moving to DO Kubernetes:

```bash
# Enable Kubernetes in OrbStack
# Settings → Kubernetes → Enable

# Verify
kubectl cluster-info
# Shows: orbstack context

# Key OrbStack K8s advantages:
# - LoadBalancer services get real IPs (no MetalLB needed)
# - Wildcard DNS: *.k8s.orb.local
# - Pod IPs accessible from macOS
# - cluster.local DNS works from host

# Example: Test a service via K8s
kubectl create deployment odoo --image=odoo:19 --port=8069
kubectl expose deployment odoo --type=LoadBalancer --port=8069
# Access: http://odoo.default.svc.cluster.local:8069
```

## Troubleshooting OrbStack

### Containers won't start

```bash
# Check OrbStack is running
orbctl status

# Restart OrbStack
orbctl stop && orbctl start

# Check Docker daemon
docker info
```

### Port conflicts

```bash
# Check what's using a port
lsof -i :8069
lsof -i :5432

# OrbStack doesn't require stopping other services for port mapping
# But if another process holds the port, Docker can't bind
```

### Slow file operations

```bash
# VirtioFS should be fast, but verify:
time docker compose exec odoo ls -la /usr/lib/python3/dist-packages/odoo/addons/ | wc -l

# If slow, check if you're using the correct Docker context:
docker context ls  # Should show orbstack *
```

### Reset everything

```bash
# Soft reset (keeps images)
docker compose down -v
docker system prune -f

# Hard reset (removes everything)
docker system prune -af --volumes

# Nuclear: Reset OrbStack entirely
# OrbStack → Settings → Reset
```
