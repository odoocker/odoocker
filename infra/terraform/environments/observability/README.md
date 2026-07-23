# Grove Observability env (obs droplet)

Provisions the **separate observability plane** from the design spec (§4–6): a DO
droplet running **OpenObserve + Keep**, isolated from the app plane so monitoring
outlives an app outage. OpenObserve stores Parquet in **DO Spaces** (there's no
shared MinIO here — that's the app plane).

## ⚠️ Scaffold status

`terraform fmt` + `terraform validate` pass, but this env has **not been applied
yet**. Cloud-init, cross-plane ingest, and Spaces wiring need live iteration (the
`qa` env's PR history shows how much live debugging this class of work takes).
Treat as a reviewed scaffold, not production-ready, until a clean `terraform plan`
+ first apply is recorded.

## What it manages
1. DO SSH key (CI, long-lived) + reference to the out-of-band admin key
2. Obs droplet (via the shared `modules/droplet`), no attached volume (Parquet →
   Spaces; Keep SQLite fits local disk)
3. Firewall — SSH + OpenObserve (5080) + Keep (3034), all **admin-only**
4. cloud-init — Docker + the standalone `compose/docker-compose.obs.yml`

## Apply (once validated live)
```bash
cp backend.hcl.example backend.hcl        # git-ignored
cp terraform.tfvars.example terraform.tfvars   # or use op:// injection
terraform init -backend-config=backend.hcl
terraform plan      # review before first apply
terraform apply
```

## Applying monitors/alerts/dashboards + Discord routing
Config-as-code is applied **against this droplet from CI/operator**, not from the
droplet, using `setup-monitoring.py`'s remote-URL support:
```bash
OPENOBSERVE_BASE_URL=http://<obs_ip>:5080 \
KEEP_BASE_URL=http://<obs_ip>:8080 \
OPENOBSERVE_ROOT_EMAIL=... OPENOBSERVE_ROOT_PASSWORD=... \
KEEP_WEBHOOK_TOKEN=... DISCORD_WEBHOOK_WARNING=... DISCORD_WEBHOOK_CRITICAL=... \
./scripts/setup-monitoring.py
```

## Follow-ups (need live iteration / other work)
- **Cross-plane ingest:** the app-plane `synthetic-runner` + `cost-bridge` ship OTLP
  to this droplet's `:5080`. Add the app droplet's IP (or a DO VPC) as an ingest
  firewall source, and point their `OPENOBSERVE_OTLP_METRICS_URL` at `<obs_ip>:5080`.
- **Cloudflare-WAF Bearer ingest endpoint** (spec §1) for the off-droplet GitHub
  Actions Playwright/Hurl crons.
- **`make` targets** (`obs-init/plan/apply/destroy`) + `op run` env-file, matching
  the other envs.
- **Release-manifest wiring** — the manifest (ADR-004) isn't implemented yet; pin
  OpenObserve/Keep tags there once it exists so the obs stack promotes qa→main
  with everything else.
