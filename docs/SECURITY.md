# Security Scanning — Operator Guide

This document describes the automated security scan suite, how to triage findings,
how to manage allowlists, and how to run scans locally.

---

## Scan Suite Overview

| Job | Tool | Triggers | Failure Threshold | Findings Surface |
|-----|------|----------|-------------------|-----------------|
| `trivy-fs` | [Trivy](https://github.com/aquasecurity/trivy) filesystem scan | PR, push to `main`, manual | HIGH or CRITICAL CVE | GitHub Security → Code Scanning |
| `trivy-image` (×3) | Trivy image scan (odoo, postgres, pgadmin) | PR, push to `main`, manual | HIGH or CRITICAL CVE | GitHub Security → Code Scanning |
| `gitleaks` | [gitleaks](https://github.com/gitleaks/gitleaks) full-history scan | PR, push to `main`, manual | Any secret match | GitHub Actions check log |
| `zap-baseline` | [OWASP ZAP](https://www.zaproxy.org/) baseline passive scan | After `Sandbox Deploy` succeeds | HIGH ZAP alert | GitHub Issues comment + Slack |

SARIF results from Trivy jobs are uploaded to the
[GitHub Security tab → Code Scanning](../../security/code-scanning) where they
persist across runs and can be triaged/dismissed inline.

---

## Triage Flow

### Trivy CVE Finding

1. Open the [Code Scanning tab](../../security/code-scanning) and filter by `trivy-filesystem` or `trivy-image-<service>`.
2. Identify the vulnerable package and its fixable version.
3. **Base image CVE** — update the `FROM` tag in the relevant Dockerfile
   (e.g., `odoo/Dockerfile`, `postgres/Dockerfile`) and rebuild.
4. **Dependency CVE** (Python `requirements.txt`, OS package) — update the
   pinned version in the relevant requirements file or Dockerfile `apt-get` step.
5. If a CVE is unfixable upstream (no patched version available), add a
   `.trivyignore` entry with the CVE ID and a brief justification comment.
   Re-evaluate every 30 days.
6. Commit the fix, open a PR — the scan will re-run and clear the finding.

### gitleaks Secret Finding

> **Act fast.** Treat any detected secret as compromised, even if the commit is
> old or on a non-deployed branch.

1. **Rotate the credential immediately** — revoke the API key / password /
   token in the relevant service before doing anything else.
2. **Remove from Git history** using [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/):
   ```bash
   bfg --delete-files <filename-containing-secret> --no-blob-protection
   # or to scrub by string value:
   echo 'SECRET_VALUE' > secrets.txt
   bfg --replace-text secrets.txt
   git reflog expire --expire=now --all
   git gc --prune=now --aggressive
   git push --force-with-lease
   ```
3. **Force-push all affected branches** and notify all collaborators to
   re-clone (their local copies still have the secret in `.git/objects`).
4. If the finding is a **known-safe placeholder** (e.g., in `.env.*.example`),
   add it to the `.gitleaks.toml` allowlist — see [Managing Allowlists](#managing-allowlists).

### ZAP HIGH Alert Finding

1. Review the ZAP report artifact attached to the workflow run
   (`zap-baseline-report`).
2. Open a GitHub Issue and label it `security:p1`.
3. Reproduce the finding against the sandbox URL:
   ```bash
   docker run --rm -t owasp/zap2docker-stable zap-baseline.py -t https://<sandbox-url>
   ```
4. Fix the root cause (missing header, injection vector, etc.) in the
   nginx config, Odoo code, or application layer.
5. Re-deploy sandbox and confirm the ZAP re-run no longer flags the alert.
6. If the alert is a **known false positive** for this stack, add a `WARN` or
   `IGNORE` entry to `.zap/baseline.conf` with a comment explaining why.

---

## Managing Allowlists

### Trivy — `.trivyignore`

Add CVE IDs that cannot currently be fixed:

```
# CVE-YYYY-XXXXX — <package> — no fix available upstream as of YYYY-MM-DD
# Re-evaluate: YYYY-MM-DD + 30 days
CVE-YYYY-XXXXX
```

**Rule of thumb:** never add a CVE without a dated re-evaluation reminder.
Include the justification in the commit message, not just the file comment.

### gitleaks — `.gitleaks.toml`

Add path or regex allowlist entries under `[allowlist]`:
- **Prefer path-scoped allowlists** over global regex allowlists.
- **Never add a regex that matches real secret patterns** — match only
  placeholder markers (`CHANGE_ME`, `your-key-here`, etc.).
- State the justification in the commit message: `"Allow .env.example: all
  values are operator-facing placeholders, not real credentials"`.

### ZAP — `.zap/baseline.conf`

Format: `<rule-id>\t<action>  # justification`

Actions: `IGNORE`, `WARN`, `FAIL`.

- Prefer `WARN` over `IGNORE` — warnings are still visible without breaking CI.
- Prefer fixing the root cause over suppressing an alert.
- Never use `IGNORE` on a HIGH-severity rule without a written justification
  in the commit message and a plan to re-evaluate.

---

## Running Scans Locally

### Trivy — filesystem scan
```bash
# Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
trivy fs . --severity HIGH,CRITICAL
```

### Trivy — image scan
```bash
# Build the image first, then scan
docker build -f odoo/Dockerfile -t odoo-local:dev .
trivy image odoo-local:dev --severity HIGH,CRITICAL
```

### gitleaks — secret detection
```bash
# Install: https://github.com/gitleaks/gitleaks#installing
gitleaks detect --source . --config .gitleaks.toml --verbose
```

### OWASP ZAP — baseline scan
```bash
# Requires a running sandbox; replace <url> with the target
docker run --rm -t owasp/zap2docker-stable zap-baseline.py \
  -t https://<sandbox-url> \
  -c .zap/baseline.conf \
  -I
```

The `-I` flag treats WARN-level rules as informational (non-blocking), matching
the CI behaviour. Remove `-I` for a stricter local run.

---

## Required Secrets

| Secret | Used by | Purpose |
|--------|---------|---------|
| `GITHUB_TOKEN` | All workflows | Built-in; no setup needed |
| `SLACK_SECURITY_WEBHOOK_URL` | `zap-baseline.yml` | Post HIGH alert notifications to security Slack channel |

Add secrets in: **Repository Settings → Secrets and variables → Actions**.
