#!/usr/bin/env bash
#
# Verify the GATH-44 acceptance criterion: killing the local Odoo container
# triggers a Discord critical alert within 2 minutes.
#
# Strategy:
#   1. Confirm the monitoring stack is up (OpenObserve + Keep healthy)
#   2. Confirm Odoo is currently up + healthy
#   3. Send a connectivity-check ping through Keep → Discord (prove wiring
#      works BEFORE we kill anything — saves debugging when the real test
#      fails for an unrelated reason)
#   4. Kill the gatheratthegrove-odoo-1 container
#   5. Poll OpenObserve's /api/{org}/alerts/triggered endpoint for the
#      `odoo-down-critical` alert to fire
#   6. Assert the alert appeared within 2 min
#   7. Restore Odoo, restore state
#
# Run after `make monitoring-up` once the stack is bootstrapped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env.monitoring for ports + tokens
if [ ! -f "$REPO_ROOT/.env.monitoring" ]; then
  echo "ERROR: $REPO_ROOT/.env.monitoring not found. Run 'make monitoring-up' first." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
. "$REPO_ROOT/.env.monitoring"
set +a

OO_PORT="${OPENOBSERVE_PORT:-5080}"
KEEP_BE_PORT="${KEEP_BACKEND_PORT:-8080}"
ODOO_CONTAINER="gatheratthegrove-odoo-1"
ALERT_NAME="odoo-down-critical"
DEADLINE_S=130  # 2 min target + 10s buffer

# ── tiny logger ──────────────────────────────────────────────────────────────
log()  { printf "\033[1;36m[smoke]\033[0m  %s\n" "$*"; }
ok()   { printf "\033[1;32m   ✓\033[0m     %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m   %s\n" "$*" >&2; }
fail() { printf "\033[1;31m[FAIL]\033[0m   %s\n" "$*" >&2; exit 1; }

# ── 1. preflight ─────────────────────────────────────────────────────────────
log "1/7  Preflight checks..."
docker ps --format '{{.Names}}' | grep -q "^$ODOO_CONTAINER$" \
  || fail "$ODOO_CONTAINER not running. Run 'make stack-up' first."
curl -sS -m 5 -o /dev/null "http://localhost:$OO_PORT/healthz" \
  || fail "OpenObserve not responding at :$OO_PORT — run 'make monitoring-up'"
curl -sS -m 5 -o /dev/null "http://localhost:$KEEP_BE_PORT/healthcheck" \
  || fail "Keep backend not responding at :$KEEP_BE_PORT — run 'make monitoring-up'"
ok "OpenObserve healthy, Keep healthy, Odoo running"

# ── 2. connectivity-check alert through the full pipeline ───────────────────
log "2/7  Sending connectivity-check alert (Keep → Discord)..."
test_payload=$(cat <<EOF
{
  "name": "smoke-test-connectivity",
  "severity": "warning",
  "message": "GATH-44 smoke-test connectivity probe at $(date -u +%FT%TZ)",
  "tags": {"tenant": "shared", "test": "true"},
  "runbook_key": "smoke-test-no-action-needed",
  "started_at": "$(date -u +%FT%TZ)"
}
EOF
)
code=$(curl -sS -o /tmp/keep-test-resp.json -w '%{http_code}' \
  -X POST "http://localhost:$KEEP_BE_PORT/alerts/event/$KEEP_WEBHOOK_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$test_payload")
if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "202" ]; then
  ok "Keep accepted the test alert (HTTP $code). Check your Discord warning channel — should appear within 5s."
else
  warn "Keep returned HTTP $code. Discord may not be wired correctly — continuing anyway."
  cat /tmp/keep-test-resp.json | head -3
fi
sleep 3

# ── 3. snapshot pre-state ───────────────────────────────────────────────────
log "3/7  Recording pre-kill state..."
T_KILL=$(date +%s)
ok "Kill timestamp: T+0 = $T_KILL"

# ── 4. kill Odoo ────────────────────────────────────────────────────────────
log "4/7  Killing $ODOO_CONTAINER..."
docker kill "$ODOO_CONTAINER" >/dev/null
ok "Container killed"

# ── 5. poll for alert ───────────────────────────────────────────────────────
log "5/7  Polling OpenObserve for '$ALERT_NAME' to fire (deadline: ${DEADLINE_S}s)..."
deadline=$((T_KILL + DEADLINE_S))
alert_fired=false
elapsed=0
while [ "$(date +%s)" -lt $deadline ]; do
  elapsed=$(($(date +%s) - T_KILL))
  resp=$(curl -sS -u "$OPENOBSERVE_ROOT_EMAIL:$OPENOBSERVE_ROOT_PASSWORD" \
    "http://localhost:$OO_PORT/api/default/alerts/triggered" 2>/dev/null || echo '[]')
  if echo "$resp" | grep -q "\"$ALERT_NAME\""; then
    alert_fired=true
    break
  fi
  if [ $((elapsed % 10)) -eq 0 ]; then
    log "  T+${elapsed}s — still polling..."
  fi
  sleep 2
done

# ── 6. restore Odoo regardless of pass/fail ─────────────────────────────────
log "6/7  Restoring Odoo..."
docker start "$ODOO_CONTAINER" >/dev/null
ok "Container restarted (cold boot will take ~30s)"

# ── 7. report ───────────────────────────────────────────────────────────────
log "7/7  Result"
echo "================================================================"
if [ "$alert_fired" = true ]; then
  ok "PASS — '$ALERT_NAME' fired in ${elapsed}s (target: <120s)"
  echo
  echo "GATH-44 acceptance criterion verified:"
  echo "  Killing Odoo locally triggered a critical alert in ${elapsed} seconds."
  echo "  (Discord delivery happens via Keep — confirm visually in your"
  echo "  #grove-alerts-critical channel that the @here ping arrived.)"
  exit 0
else
  fail "TIMEOUT — '$ALERT_NAME' did NOT fire within ${DEADLINE_S}s."
fi
