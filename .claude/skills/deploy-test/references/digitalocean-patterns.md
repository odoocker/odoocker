# DigitalOcean Patterns for Grove Ecosystem

## doctl Quick Reference

```bash
# Authentication
doctl auth init                          # Interactive login
doctl auth whoami                        # Verify auth
doctl account get                        # Account info

# Droplets
doctl compute droplet list               # List droplets
doctl compute droplet get <id>           # Droplet details
doctl compute droplet actions <id>       # Recent actions

# Firewalls
doctl compute firewall list
doctl compute firewall create \
  --name grove-fw \
  --inbound-rules "protocol:tcp,ports:80,address:0.0.0.0/0 protocol:tcp,ports:443,address:0.0.0.0/0 protocol:tcp,ports:22,address:<your-ip>/32" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0"

# Domains
doctl compute domain list
doctl compute domain records list <domain>
doctl compute domain records create <domain> --record-type A --record-name @ --record-data <ip>
doctl compute domain records create <domain> --record-type A --record-name blog --record-data <ip>

# Snapshots / Backups
doctl compute droplet-action snapshot <droplet-id> --snapshot-name "grove-$(date +%Y%m%d)"
doctl compute snapshot list
```

## Droplet Sizing Guide

| Workload | Droplet Size | Notes |
|----------|-------------|-------|
| Dev/Testing | s-2vcpu-2gb ($18/mo) | Minimum for Odoo + PG |
| Small Production | s-2vcpu-4gb ($24/mo) | 3 Ghost + Odoo + PG |
| **Recommended** | **s-4vcpu-8gb ($48/mo)** | **Comfortable for full stack** |
| High Traffic | s-8vcpu-16gb ($96/mo) | Multiple Odoo workers |

## Deployment via GitHub Actions + SSH

The recommended deployment pattern for droplet-based hosting:

```yaml
# Pattern: SSH into droplet, pull code, restart services
- uses: appleboy/ssh-action@v1
  with:
    host: ${{ secrets.DROPLET_IP }}
    username: ${{ secrets.DROPLET_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /opt/grove
      git pull origin main
      docker compose ... build --pull
      docker compose ... up -d
```

## Backup Strategy

```bash
# Database backup (run on droplet)
docker compose exec postgres pg_dump -U odoo -Fc gatheratthegrove > backup_$(date +%Y%m%d).dump

# Upload to Spaces
doctl compute cdn flush <cdn-id>
s3cmd put backup_*.dump s3://grove-backups/db/

# Ghost content backup
for ghost in goldberry ggg nursery; do
  docker compose cp ghost-${ghost}:/var/lib/ghost/content ./backups/ghost-${ghost}/
done

# Full droplet snapshot (weekly)
doctl compute droplet-action snapshot <droplet-id> --snapshot-name "grove-weekly-$(date +%Y%m%d)"
```

## Monitoring

```bash
# Quick health check script (save as /opt/grove/healthcheck.sh)
#!/bin/bash
set -e

echo "=== Grove Health Check ==="

# Odoo
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/web/login)
echo "Odoo: $HTTP_CODE"

# Postgres
docker compose exec -T postgres pg_isready -U odoo && echo "Postgres: OK" || echo "Postgres: FAIL"

# Ghost instances
for port in 2368 2369 2370; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$port)
  echo "Ghost :$port: $CODE"
done

# Disk usage
echo "Disk: $(df -h / | tail -1 | awk '{print $5}') used"

# Memory
echo "Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"

# Docker
echo "Containers: $(docker ps --format '{{.Names}} {{.Status}}' | wc -l) running"
```

## Security Hardening

```bash
# On the droplet:

# 1. Disable root SSH login (after creating deploy user)
adduser deploy
usermod -aG docker deploy
# Add SSH key to /home/deploy/.ssh/authorized_keys
# Edit /etc/ssh/sshd_config: PermitRootLogin no

# 2. Enable unattended upgrades
apt install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# 3. Set up fail2ban
apt install fail2ban
systemctl enable fail2ban

# 4. Firewall (ufw as backup to DO firewall)
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```
