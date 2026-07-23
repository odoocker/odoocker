#!/usr/bin/env bash
# qa-monitor.sh -- persistent live dashboard for the Grove QA env.
#
# Unlike qa-deploys.sh (workflow status only), this is a per-COMPONENT
# health view: workflow + droplet + each URL + Odoo-specific aliveness
# probing. Refreshes in-place every 15s (no full-screen clear, no flash).
#
# Layout (one screen at any time):
#
#   Grove QA monitor    HH:MM:SS UTC    next tick in Ns
#   ---------------------------------------------------------------
#
#   WORKFLOWS  (latest per workflow + in-progress)
#     <symbol> RUN_ID         WHEN         DURATION   WORKFLOW
#     ...
#
#   DROPLET
#     <ip>   id=NNN   status=active   created=N min ago
#     (or "(none)" if torn down)
#
#   PUBLIC URLS  (HTTP probe + per-URL diagnosis)
#     hub         hub.qa.gathering...             200    132ms  alive
#     goldberry   goldberry.qa.gathering...       200     89ms  alive
#     ...
#     odoo        odoo.qa.gathering...            502     11ms  caddy proxy up, odoo backend down
#
# Usage:
#   bash scripts/qa-monitor.sh                  # default: 15s tick
#   bash scripts/qa-monitor.sh --interval 30    # 30s
#   bash scripts/qa-monitor.sh --once           # snapshot, exit
#   make qa-monitor                             # wraps this
#
# Requires: gh CLI (auth), jq, curl. No SSH dependency by default.
#
# Exit codes:
#   0  Normal exit (Ctrl-C in continuous mode, or successful --once)
#   1  Required tools missing
#   2  gh CLI not authenticated

set -euo pipefail

INTERVAL=15
ONCE=0
for arg in "$@"; do
  case "$arg" in
    --once)          ONCE=1 ;;
    --interval)      shift; INTERVAL="${1:-15}" ;;
    --interval=*)    INTERVAL="${arg#--interval=}" ;;
    [0-9]*)          INTERVAL="$arg" ;;
    *) echo "Usage: $0 [--once] [--interval SECONDS|N]" >&2; exit 1 ;;
  esac
done

# Validate interval as positive integer (defense against arithmetic injection)
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
  echo "ERROR: interval must be a positive integer, got: $INTERVAL" >&2
  exit 1
fi

for tool in gh jq curl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run: gh auth login" >&2; exit 2; }

# Colors (off if not a tty)
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"
  C_GRAY="\033[2m"; C_BOLD="\033[1m"; C_DIM="\033[2m"; NC="\033[0m"
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_GRAY=""; C_BOLD=""; C_DIM=""; NC=""
fi

QA_ZONE="${QA_ZONE:-qa.gatheringatthegrove.com}"
TENANTS=("goldberry" "ggg" "nursery" "odoo")  # plus "hub" at hub.$QA_ZONE (subdomain, not apex -- per ADR-006)
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"

# Fetch DO token (read-scoped is fine for monitoring). Cache for the session.
fetch_do_token() {
  if [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then return; fi
  if command -v op >/dev/null; then
    DIGITALOCEAN_TOKEN=$(op item get "GoldberryGrove Infra" --vault "Goldberry Grove - Admin" \
      --fields label=do_token --reveal 2>/dev/null) || DIGITALOCEAN_TOKEN=""
  fi
  export DIGITALOCEAN_TOKEN
}

# --- Probe one URL: returns "HTTP_CODE|TIME_MS|DIAGNOSIS" via stdout ---
probe_url() {
  local host="$1" tenant="$2"
  local url="https://$host/"
  # -w prints code + time; we parse below.
  local raw
  raw=$(curl -sk -o /dev/null -w '%{http_code} %{time_total}' \
    --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null) || raw="000 0"
  local code time_s time_ms diag
  code=$(echo "$raw" | awk '{print $1}')
  time_s=$(echo "$raw" | awk '{print $2}')
  # Convert seconds (float) to ms (integer) without bc
  time_ms=$(python3 -c "print(int(float('$time_s') * 1000))" 2>/dev/null || echo "?")
  # Diagnose based on (tenant, code) -- odoo gets richer interpretation
  if [ "$tenant" = "odoo" ]; then
    case "$code" in
      # 303 is odoo's normal "redirect to /web/login" when hitting /. Was
      # previously misdiagnosed as "unexpected" because the case was
      # `200|302)` -- odoo doesn't use 302, it uses 303. Treat any 2xx/3xx
      # as alive (consistent with tenant branch below).
      2*|3*)   diag="alive" ;;
      502)     diag="caddy up, odoo backend down" ;;
      503)     diag="odoo starting up" ;;
      500)     diag="odoo internal error" ;;
      000)     diag="connection failed / timeout" ;;
      *)       diag="HTTP $code unexpected" ;;
    esac
  else
    case "$code" in
      2*|3*) diag="alive" ;;
      502)   diag="caddy up, backend down" ;;
      503)   diag="backend starting" ;;
      000)   diag="connection failed / timeout" ;;
      *)     diag="HTTP $code unexpected" ;;
    esac
  fi
  echo "$code|$time_ms|$diag"
}

# --- Status symbol + color for HTTP code (per-URL row) ---
symbol_for() {
  local code="$1" tenant="$2"
  case "$code" in
    2*|3*) printf "${C_GREEN}✓${NC}" ;;
    502)   printf "${C_RED}✗${NC}" ;;
    503)   printf "${C_YELLOW}●${NC}" ;;
    500)   printf "${C_RED}!${NC}" ;;
    000)   printf "${C_RED}✗${NC}" ;;
    *)     printf "${C_YELLOW}?${NC}" ;;
  esac
}

render() {
  # Move cursor home + erase from cursor to end of screen. The first render
  # writes new content; subsequent renders OVERWRITE the previous frame
  # without a flashy full-screen clear. (Use clear for the FIRST render to
  # start with a clean slate.)
  if [ "${FIRST_RENDER:-1}" = "1" ]; then
    clear
    FIRST_RENDER=0
  else
    printf "\033[H"   # cursor home, no clear
  fi

  local now_utc
  now_utc=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  printf "${C_BOLD}Grove QA monitor${NC}   ${C_DIM}%s   tick every ${INTERVAL}s   Ctrl-C to exit${NC}\033[K\n" "$now_utc"
  printf "${C_GRAY}%s${NC}\033[K\n\n" "------------------------------------------------------------------------"

  # ─── Workflows ──────────────────────────────────────────────────────────
  printf "${C_BOLD}WORKFLOWS${NC}  ${C_DIM}latest per workflow + any in-progress${NC}\033[K\n"
  local json_fields="databaseId,workflowName,status,conclusion,createdAt,updatedAt"
  local r1 r2 r3 wfruns
  r1=$(gh run list --workflow=qa-deploy.yml      --limit 5 --json "$json_fields" 2>/dev/null || echo "[]")
  r2=$(gh run list --workflow=qa-teardown.yml    --limit 5 --json "$json_fields" 2>/dev/null || echo "[]")
  r3=$(gh run list --workflow=qa-ttl-sweeper.yml --limit 5 --json "$json_fields" 2>/dev/null || echo "[]")
  wfruns=$(jq -s '
    add |
    ([.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or .status == "pending")]
     + [group_by(.workflowName)[] | sort_by(.createdAt) | reverse | .[0]])
    | unique_by(.databaseId) | sort_by(.createdAt) | reverse
  ' <(echo "$r1") <(echo "$r2") <(echo "$r3"))

  echo "$wfruns" | jq -r '.[] |
    [.databaseId, (.workflowName | sub("^QA "; "")), .status, (.conclusion // ""), .createdAt, .updatedAt] | join("|")' \
  | while IFS='|' read -r id wf status conclusion created updated; do
    local sym dur end
    case "$status" in
      completed)
        case "$conclusion" in
          success)   sym="${C_GREEN}✓${NC}" ;;
          failure)   sym="${C_RED}✗${NC}" ;;
          cancelled) sym="${C_GRAY}○${NC}" ;;
          *)         sym="${C_YELLOW}?${NC}" ;;
        esac
        end="$updated"
        ;;
      *) sym="${C_YELLOW}●${NC}"; end="" ;;
    esac
    # duration
    if [ -n "$created" ]; then
      dur=$(python3 -c "
from datetime import datetime, timezone
a = datetime.fromisoformat('$created'.replace('Z','+00:00'))
b = datetime.fromisoformat('$end'.replace('Z','+00:00')) if '$end' else datetime.now(timezone.utc)
s = int((b - a).total_seconds())
print(f'{s//60}m{s%60}s' if s >= 60 else f'{s}s')
" 2>/dev/null)
    fi
    local when
    when=$(echo "$created" | sed 's/T/ /; s/:[0-9]*Z$//')
    printf "  %b  ${C_DIM}%-11s${NC}  %-19s  %-9s  %s\033[K\n" "$sym" "$id" "$when" "${dur:--}" "$wf"
  done
  printf "\033[K\n"

  # ─── Droplet ────────────────────────────────────────────────────────────
  printf "${C_BOLD}DROPLET${NC}\033[K\n"
  fetch_do_token
  local droplet ip dropid status created_at age_min
  if [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then
    droplet=$(curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
      "https://api.digitalocean.com/v2/droplets?tag_name=env-qa" 2>/dev/null \
      | jq -r '.droplets[0] // empty')
  fi
  if [ -z "${droplet:-}" ]; then
    # Audit fix SC2059 (2026-06-29): pull color codes into args, keep the
    # format string variable-free. Prevents `%` in any color var from being
    # interpreted as a printf format directive.
    printf "  %s(no env-qa droplet currently provisioned)%s\033[K\n" "$C_GRAY" "$NC"
  else
    ip=$(echo "$droplet" | jq -r '.networks.v4[0].ip_address // "(no ip)"')
    dropid=$(echo "$droplet" | jq -r '.id')
    status=$(echo "$droplet" | jq -r '.status')
    created_at=$(echo "$droplet" | jq -r '.created_at')
    age_min=$(python3 -c "
from datetime import datetime, timezone
a = datetime.fromisoformat('$created_at'.replace('Z','+00:00'))
print(int((datetime.now(timezone.utc) - a).total_seconds() // 60))
" 2>/dev/null || echo "?")
    local stat_col
    # Audit fix SC2015 (2026-06-29): explicit if/else instead of A&&B||C.
    if [ "$status" = "active" ]; then stat_col="$C_GREEN"; else stat_col="$C_YELLOW"; fi
    # Audit fix SC2059: format args are %s placeholders, color codes are args.
    printf "  %s  %sid=%s%s  %s%s%s  %screated %s min ago%s\033[K\n" \
      "$ip" "$C_DIM" "$dropid" "$NC" "$stat_col" "$status" "$NC" "$C_DIM" "$age_min" "$NC"
  fi
  printf "\033[K\n"

  # ─── Public URL probes (parallel) ───────────────────────────────────────
  # Audit fix SC2059: pull color vars into %s args; keep format static.
  printf "%sPUBLIC URLS%s  %sprobed each tick%s\033[K\n" "$C_BOLD" "$NC" "$C_DIM" "$NC"
  printf "  %s%-10s  %-44s  %-5s  %-7s  %s%s\033[K\n" "$C_GRAY" "TENANT" "HOST" "HTTP" "TIME" "DIAGNOSIS" "$NC"

  # Probe all 5 URLs in parallel; collect into a temp file
  local tmp
  tmp=$(mktemp)
  {
    # hub at hub.$QA_ZONE (NOT the apex -- ADR-006: apex isn't covered by
    # the wildcard cert per RFC 6125; hub serves at hub.qa.* using the
    # wildcard cert like the other 4 tenants).
    echo "hub|hub.$QA_ZONE|$(probe_url "hub.$QA_ZONE" "hub")" &
    for t in "${TENANTS[@]}"; do
      echo "$t|$t.$QA_ZONE|$(probe_url "$t.$QA_ZONE" "$t")" &
    done
    wait
  } > "$tmp"

  # Sort to consistent order (hub first, then alphabetical)
  {
    grep '^hub|' "$tmp"
    grep -v '^hub|' "$tmp" | sort
  } | while IFS='|' read -r tenant host code time_ms diag; do
    local sym
    sym=$(symbol_for "$code" "$tenant")
    printf "  %b ${C_DIM}%-9s${NC}  %-44s  %-5s  %-7s  %s\033[K\n" \
      "$sym" "$tenant" "$host" "$code" "${time_ms}ms" "$diag"
  done
  rm -f "$tmp"
  printf "\033[K\n"

  # Erase any leftover lines from a longer previous render
  printf "\033[J"
}

# Single-shot mode
if [ "$ONCE" = "1" ]; then
  render
  exit 0
fi

# Continuous mode
trap 'printf "\n${C_DIM}(qa-monitor exited)${NC}\n"; exit 0' INT TERM
while true; do
  render
  sleep "$INTERVAL"
done
