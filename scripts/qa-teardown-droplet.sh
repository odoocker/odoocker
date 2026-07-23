#!/usr/bin/env bash
# qa-teardown-droplet.sh -- Destroy ALL droplets tagged env-qa via DO API.
#
# Side-steps TF entirely (the DO provider's hardcoded 1m destroy poll has bit
# us multiple times). Direct API DELETE + generous poll budget per droplet.
#
# Idempotent: if no env-qa droplets exist, exits 0 silently.
#
# Usage:
#   bash scripts/qa-teardown-droplet.sh
#   bash scripts/qa-teardown-droplet.sh --dry-run     # list, don't destroy
#
# Required env:
#   DIGITALOCEAN_TOKEN  Must have `droplet:delete` scope. The do_token_teardown
#                       PAT from 1P 'GoldberryGrove Infra' is the right token.
#
# Optional env:
#   POLL_MAX_SECONDS   Poll budget per droplet (default: 300)
#   POLL_INTERVAL      Seconds between polls (default: 5)
#
# Exit codes:
#   0  All env-qa droplets destroyed (or none existed)
#   1  Required env missing
#   2  At least one DELETE failed (likely scope issue -- check token)
#   3  At least one poll timed out (DO API genuinely slow)

set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "ERROR: DIGITALOCEAN_TOKEN not set." >&2
  echo "  export DIGITALOCEAN_TOKEN=\$(op item get \"GoldberryGrove Infra\" --vault \"Goldberry Grove - Admin\" --fields label=do_token_teardown --reveal)" >&2
  exit 1
fi

POLL_MAX_SECONDS="${POLL_MAX_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

echo "-- QA droplet teardown --"
list_json=$(curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" "https://api.digitalocean.com/v2/droplets?tag_name=env-qa")
ids=$(echo "$list_json" | jq -r '.droplets[].id // empty')

if [ -z "$ids" ]; then
  echo "  (no env-qa droplets found -- nothing to destroy)"
  exit 0
fi

count=$(echo "$ids" | wc -l | tr -d ' ')
echo "  found $count droplet(s) to destroy"

if [ "$DRY_RUN" = "1" ]; then
  echo "$list_json" | jq -r '.droplets[] | "  DRY-RUN would destroy: \(.name) id=\(.id) ip=\(.networks.v4[0].ip_address // "(no ip)") created=\(.created_at)"'
  exit 0
fi

# Pre-detach any attached volumes BEFORE issuing droplet DELETE. Without this,
# the volume_attachment in TF state still references the dead droplet on next
# apply -- and the new attachment can collide with the DO-side stale "attached
# to droplet <gone-id>" record, causing the qa-deploy to fail with a
# confusing "volume already attached" error. Detaching here makes the
# next apply's reattach clean.
#
# Idempotent: if a droplet has no volumes, the detach loop is a no-op.
# Token scope: needs volume:write. The teardown PAT now has block_storage
# scope (added 2026-06-27 alongside this script change); if not, the detach
# is silently 403'd and the script continues (droplet still gets destroyed,
# next apply just has the same race window as before -- not worse than baseline).
# Pre-detach pattern: POST detach action returns 201/202 (action queued, NOT
# completed). Then poll the action endpoint until status="completed" before
# proceeding to droplet DELETE -- otherwise DO can refuse the delete because
# a volume action is still in flight, or auto-detach during droplet destroy
# leaves the volume in `detaching` state when the next TF apply tries to
# reattach. Audit finding 2026-06-27 #2.
for id in $ids; do
  vol_ids=$(echo "$list_json" | jq -r --arg id "$id" 'select(. != null) | .droplets[] | select((.id|tostring) == $id) | .volume_ids[]?')
  for vol_id in $vol_ids; do
    echo "  -> pre-detaching volume $vol_id from droplet $id"
    detach_body=$(mktemp)
    detach_resp=$(curl -s -o "$detach_body" -w '%{http_code}' \
      -X POST -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"detach\",\"droplet_id\":${id}}" \
      "https://api.digitalocean.com/v2/volumes/${vol_id}/actions")
    case "$detach_resp" in
      201|202)
        action_id=$(jq -r '.action.id' < "$detach_body" 2>/dev/null || echo "")
        if [ -z "$action_id" ] || [ "$action_id" = "null" ]; then
          echo "     WARN: detach accepted (HTTP $detach_resp) but action.id missing in body -- continuing without polling" >&2
        else
          echo "     detach action $action_id queued; polling until completed (up to 60s)..."
          waited=0
          while [ "$waited" -lt 60 ]; do
            status=$(curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
              "https://api.digitalocean.com/v2/volumes/${vol_id}/actions/${action_id}" \
              2>/dev/null | jq -r '.action.status' 2>/dev/null || echo "?")
            case "$status" in
              completed) echo "     detach completed (waited ${waited}s)"; break ;;
              errored)   echo "     WARN: detach action errored after ${waited}s -- continuing (droplet destroy will retry)" >&2; break ;;
              in-progress|"") sleep 3; waited=$((waited + 3)) ;;
              *)         echo "     WARN: unexpected detach status '$status' -- continuing" >&2; break ;;
            esac
          done
          if [ "$waited" -ge 60 ]; then
            echo "     WARN: detach action timed out at 60s -- droplet DELETE will attempt auto-detach" >&2
          fi
        fi
        ;;
      403)     echo "     WARN: HTTP 403 -- token lacks block_storage:write, skipping (droplet destroy will auto-detach but may race next apply)" >&2 ;;
      *)       echo "     WARN: HTTP $detach_resp -- continuing anyway" >&2 ;;
    esac
    rm -f "$detach_body"
  done
done

fail_destroy=0
fail_poll=0
for id in $ids; do
  echo "  -> droplet $id: issuing DELETE"
  http_code=$(curl -s -o /tmp/td.$$ -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/droplets/${id}")
  case "$http_code" in
    204|404)
      echo "     DELETE accepted (HTTP $http_code) -- polling"
      ;;
    403)
      echo "     FAIL: HTTP 403 (token lacks droplet:delete scope)" >&2
      fail_destroy=1
      continue
      ;;
    *)
      echo "     FAIL: HTTP $http_code -- response: $(cat /tmp/td.$$ 2>/dev/null)" >&2
      fail_destroy=1
      continue
      ;;
  esac
  rm -f /tmp/td.$$

  # Poll until 404 or budget exhausted
  start=$(date +%s)
  deadline=$((start + POLL_MAX_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
      "https://api.digitalocean.com/v2/droplets/${id}")
    if [ "$code" = "404" ]; then
      echo "     droplet $id confirmed destroyed (HTTP 404)"
      break
    fi
    sleep "$POLL_INTERVAL"
  done
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "     POLL TIMEOUT after ${POLL_MAX_SECONDS}s -- DO API may be slow; verify manually" >&2
    fail_poll=1
  fi
done

if [ "$fail_destroy" = "1" ]; then exit 2; fi
if [ "$fail_poll" = "1" ]; then exit 3; fi
echo "  done -- $count droplet(s) destroyed"
