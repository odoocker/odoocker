#!/usr/bin/env bash
# Synthetic health sweep for the Level 3 QA environment. The successor to
# the monolith's deploy-pipeline alerting: instead of watching pipeline
# runs, watch REALITY -- the 7 public hostnames plus the App Platform
# deployment phases.
#
# Exit 0 = everything healthy; exit 1 = one or more checks degraded (the
# calling workflow's conclusion then feeds discord-status.sh's streak /
# recovery logic).
#
# Env:
#   DIGITALOCEAN_TOKEN   optional -- enables the App Platform phase checks.
#                        Without it, only the HTTP sweep runs.
#   QA_ZONE              default qa.gatheringatthegrove.com
set -uo pipefail

QA_ZONE="${QA_ZONE:-qa.gatheringatthegrove.com}"
fail=0

echo "== HTTP sweep =="
# odoo returns 303 (redirect to /odoo login), oo/keep 30x to their UIs;
# any 2xx/3xx counts as serving. 000/5xx = degraded. 4xx is deliberate:
# a 403/404 at the APEX of these services would be a routing regression.
for host in hub goldberry ggg nursery odoo oo keep; do
  code=$(curl -sk -o /dev/null -w "%{http_code}" "https://${host}.${QA_ZONE}/" --connect-timeout 5 --max-time 12 2>/dev/null)
  case "$code" in
    2*|3*) echo "  ok   ${host}.${QA_ZONE} (${code})" ;;
    *)     echo "  FAIL ${host}.${QA_ZONE} (${code})"; fail=1 ;;
  esac
done

if [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "== App Platform deployment phases =="
  resp=$(curl -s --max-time 20 -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/apps?per_page=50" || true)
  if [ -z "$resp" ]; then
    echo "  FAIL could not list apps (API unreachable)"; fail=1
  else
    # Evaluate every grove-*-qa app: ACTIVE is healthy; a stuck/errored
    # deployment is degraded even if yesterday's deployment still serves
    # (that's exactly the state that silently rots).
    out=$(printf '%s' "$resp" | python3 -c '
import sys, json
d = json.load(sys.stdin)
bad = 0
seen = 0
for app in d.get("apps", []):
    name = app["spec"]["name"]
    if not (name.startswith("grove-") and name.endswith("-qa")):
        continue
    seen += 1
    dep = app.get("in_progress_deployment") or app.get("active_deployment") or {}
    phase = dep.get("phase", "UNKNOWN")
    status = "ok  " if phase in ("ACTIVE", "DEPLOYING", "BUILDING", "PENDING_DEPLOY") else "FAIL"
    if status == "FAIL":
        bad = 1
    print(f"  {status} {name}: {phase}")
if seen < 4:
    print(f"  FAIL expected 4 grove-*-qa apps, found {seen}")
    bad = 1
sys.exit(bad)')
    rc=$?
    echo "$out"
    [ "$rc" != "0" ] && fail=1
  fi
else
  echo "== App Platform checks skipped (no DIGITALOCEAN_TOKEN) =="
fi

if [ "$fail" = "0" ]; then
  echo "RESULT: healthy"
else
  echo "RESULT: DEGRADED"
fi
exit $fail
