# Release Guide

This document covers the full release lifecycle for the Grove production stack:
cutting a tag, watching the pipeline, approving the deploy, and rolling back.

---

## Cutting a Release

### Quick path

```bash
# 1. Ensure you are on a clean main branch
git checkout main && git pull

# 2. Create and push the annotated tag
make release-prepare version=v1.2.3
git push origin v1.2.3
```

The `make release-prepare` target validates the version format, checks the tag
does not already exist, and creates a local annotated tag. Nothing is pushed
until you run `git push origin <tag>` — this gives you a final review moment.

### Version format

Tags **must** follow `vMAJOR.MINOR.PATCH` (e.g. `v1.0.0`, `v2.3.14`). The
workflow rejects tags that do not match `v*.*.*`.

---

## What the Pipeline Does

Once the tag is pushed, the `Release — Production Deploy` workflow starts
automatically. Jobs run sequentially:

```
push: v*.*.*
      │
      ▼
┌─────────────────────┐
│  1. verify-image    │  Pull image → Trivy scan (fail on HIGH/CRITICAL)
│     (~5–15 min)     │  → boot container → /web/health check
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  2. sandbox-smoke   │  Hit sandbox URLs → expect 2xx
│     (optional)      │  Skip with: workflow_dispatch → skip_sandbox_smoke=true
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  3. require-        │  ← HUMAN GATE (GitHub Environments)
│     approval        │  A required reviewer must click "Approve" in the
│     (waits ≤ 1h)    │  Actions UI before the pipeline continues.
└──────────┬──────────┘
           │ (approved)
           ▼
┌─────────────────────┐
│  4. deploy-         │  SSH → git checkout <tag>
│     production      │  → docker compose pull
│     (~5–10 min)     │  → docker compose up -d
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  5. post-deploy-    │  Hit all 7 production URLs + Grafana → expect 2xx
│     smoke           │  Fails the run on first non-2xx
└──────────┬──────────┘
           │
           ▼  (always — success or failure)
┌─────────────────────┐
│  6. notify          │  Posts Slack message with status, tag, actor, run URL
└─────────────────────┘
```

---

## The Approval Screen

Job 3 (`require-approval`) is gated by the **`production` GitHub Environment**.

To approve:
1. Open the workflow run in the **Actions** tab.
2. Click the `require-approval` job.
3. You will see a yellow banner: _"This workflow is waiting for a reviewer."_
4. Click **Review pending deployments → Approve and deploy**.

If you need to reject the deploy (e.g. you noticed a problem after the Trivy
scan passed), click **Reject** instead. The `deploy-production` job will be
cancelled and `notify` will post a "rejected" Slack message.

See the [GitHub Environments documentation](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#required-reviewers)
for how to configure required reviewers on the `production` environment.

---

## Monitoring the Deploy

### Actions tab

Open `https://github.com/Goldberry-Playground/odoocker-goldberrygrove/actions`
and filter by the `Release — Production Deploy` workflow. Each step streams
live logs.

### Slack

The `notify` job posts to the `#deployments` channel (or whichever channel your
`SLACK_WEBHOOK_URL` secret points to). The message includes:
- Status (success / failure / rejected)
- Tag deployed
- Actor who triggered the run
- Direct link to the Actions run

### Grafana

If the `GRAFANA_URL` secret is set on the `production` environment, the
`post-deploy-smoke` job hits it after checking the 7 public hostnames. Log in
to Grafana directly to see container metrics post-deploy.

---

## Rollback

### Fast-path: re-tag the previous good SHA

```bash
# Find the previous good commit
git log --oneline v1.2.2..v1.2.3   # inspect what changed
git log --oneline -5                # or just look at recent history

# Tag the previous release commit as the new "current"
git tag -a v1.2.3-redeploy <previous-good-sha> -m "Redeploy v1.2.2 as v1.2.3-redeploy"
git push origin v1.2.3-redeploy
```

This triggers the full pipeline again (Trivy scan, approval, deploy) with the
previous image. Using a new tag means the audit trail is preserved — you can see
exactly when the rollback happened and who approved it.

### Manual rollback (emergency, skipping the pipeline)

```bash
ssh root@<PROD_HOST>
cd /opt/grove
git fetch --tags
git checkout v1.2.2   # previous known-good tag
docker compose \
  -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  pull
docker compose \
  -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  up -d
```

Then run `scripts/smoke-test-public.sh` from the server or locally to verify.

---

## Failure Modes and Recovery

### Trivy scan fails (HIGH/CRITICAL CVE)

**What happens:** Job 1 fails. No deploy proceeds.

**Recovery:** Identify the CVE, update the base image or affected package, push
a new tag. If the CVE is a false-positive or accepted risk, open a discussion
before overriding.

### Health check fails after image pull

**What happens:** Job 1 emits a warning (non-fatal) — the check is advisory
because Odoo requires a running PostgreSQL to fully start. The Trivy scan is
the hard gate. The pipeline continues.

**Recovery:** If you see the health check warning, manually verify the Odoo
container boots on the Droplet after the deploy.

### Sandbox smoke fails

**What happens:** Job 2 fails. The pipeline stops before the approval gate.

**Recovery:** Debug the sandbox, fix the issue, push a new tag. Or, for a
time-sensitive production fix, dispatch the workflow manually with
`skip_sandbox_smoke=true`.

### Approval times out (1 hour)

**What happens:** Job 3 is cancelled. The downstream deploy jobs are skipped.
The `notify` job fires and posts a "rejected" Slack message.

**Recovery:** Push the same tag again or use `workflow_dispatch` with the tag
input to re-trigger the pipeline.

### `docker compose pull` succeeds but `docker compose up -d` fails

**What happens:** Job 4 (`deploy-production`) fails after images have already
been pulled to the Droplet. The running containers are **not** replaced —
`up -d` is a no-op on containers that are already running unless their image
digest changed. If `up -d` fails before all services are restarted, the Droplet
may have a mix of old and new containers.

**Recovery:**
1. SSH into the Droplet.
2. Run `docker compose ps` to identify which containers are on the new vs. old
   image.
3. Restart individual services: `docker compose up -d --no-deps <service>`.
4. Or roll back by checking out the previous tag and running `up -d` again.

> **Key behaviour to understand:** `docker compose pull` only downloads image
> layers; it does not restart containers. Containers are only replaced when
> `up -d` runs and detects that the image digest has changed. If `up -d` is
> interrupted mid-way, you must complete or roll back manually.

### Post-deploy smoke fails

**What happens:** Job 5 fails. The `notify` job fires with "failure" status.
The deploy already happened — containers are running the new image.

**Recovery:**
1. Check the failing URL in the Actions logs.
2. SSH to the Droplet and inspect logs: `docker compose logs <service> --tail 50`.
3. If the new image is broken, rollback immediately using the manual procedure
   above.

---

## Required GitHub Environment Secrets

Configure these on the **`production` GitHub Environment**
(`Settings → Environments → production → Environment secrets`):

| Secret | Description |
|--------|-------------|
| `PROD_SSH_PRIVATE_KEY` | Private key whose public half is in the Droplet's `~/.ssh/authorized_keys` |
| `PROD_HOST` | IP address or hostname of the app Droplet |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL for deploy notifications |
| `GRAFANA_URL` | (Optional) Full URL to Grafana dashboard for post-deploy health check |

Additional secret (non-environment, available to all jobs):

| Secret | Description |
|--------|-------------|
| `SANDBOX_HOST` | (Optional) Hostname/IP of the sandbox Droplet for pre-release smoke test |

---

## Manual Workflow Dispatch

You can trigger a release without pushing a new tag:

1. Go to **Actions → Release — Production Deploy → Run workflow**.
2. Fill in:
   - **tag**: the existing tag to deploy (e.g. `v1.2.3`)
   - **skip_sandbox_smoke**: `true` to skip the sandbox pre-check
3. Click **Run workflow**.

This is useful for re-deploying an existing tag (e.g. after a Droplet rebuild)
without creating a new tag.
