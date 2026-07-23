#!/usr/bin/env bash
# qa-deploys.sh -- Color-coded history of recent QA workflow runs.
#
# Shows recent runs of qa-deploy.yml + qa-teardown.yml + qa-ttl-sweeper.yml
# with status icons (success/failure/cancelled/in-progress), duration, the
# failing step name when applicable, and a clickable URL.
#
# Use this to:
#   - See at a glance whether the last few deploys succeeded
#   - Find a recent failure's run ID for `gh run view <id> --log-failed`
#   - Confirm a redispatch landed (watch mode -- re-renders every 5s)
#
# Usage:
#   bash scripts/qa-deploys.sh                 # COLLAPSED view: latest run per
#                                              #   workflow + any in-progress.
#                                              #   Answers "what's the current
#                                              #   state of QA?" in 3-5 rows.
#   bash scripts/qa-deploys.sh 25              # HISTORY view: last 25 runs of
#                                              #   any kind (for digging through
#                                              #   recent iteration cycles).
#   bash scripts/qa-deploys.sh --watch         # live collapsed view, refresh 5s
#   bash scripts/qa-deploys.sh --watch 5       # live history view, 5 rows, 5s
#   make qa-deploys                            # wraps this (collapsed by default)
#   make qa-deploys n=25                       # history view via make
#
# Requires: gh CLI (with auth), jq.
#
# Exit codes:
#   0  Listed successfully
#   1  gh CLI missing or not authed

set -euo pipefail

WATCH=0
LIMIT=""    # empty = collapsed-view mode (default)
for arg in "$@"; do
  case "$arg" in
    --watch) WATCH=1 ;;
    [0-9]*)  LIMIT="$arg" ;;
    *) echo "Usage: $0 [--watch] [LIMIT]" >&2; exit 1 ;;
  esac
done

# Collapsed view = no positional limit. We still need to fetch SOMETHING from
# gh to filter from -- pick a reasonable upper bound. Larger windows would
# surface a workflow that hasn't run in days; smaller might miss the latest
# of a low-frequency workflow (e.g. ttl-sweeper runs once daily).
COLLAPSED=0
if [ -z "$LIMIT" ]; then
  COLLAPSED=1
  LIMIT=10  # fetch from each workflow; collapse to latest below
fi

if ! command -v gh >/dev/null; then
  echo "ERROR: gh CLI not found. Install: brew install gh" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh not authenticated. Run: gh auth login" >&2
  exit 1
fi

# ANSI colors -- disable if not a terminal
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"
  C_GRAY="\033[2m"; C_BOLD="\033[1m"; NC="\033[0m"
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_GRAY=""; C_BOLD=""; NC=""
fi

render() {
  # gh run list's --workflow flag is singular, not repeatable. Fetch all 3
  # QA workflow lists separately, merge to a single sorted JSON array,
  # truncate to LIMIT.
  local json_fields="databaseId,workflowName,status,conclusion,createdAt,updatedAt,event,displayTitle,url"
  local r1 r2 r3 runs
  r1=$(gh run list --workflow=qa-deploy.yml      --limit "$LIMIT" --json "$json_fields" 2>/dev/null) || r1="[]"
  r2=$(gh run list --workflow=qa-teardown.yml    --limit "$LIMIT" --json "$json_fields" 2>/dev/null) || r2="[]"
  r3=$(gh run list --workflow=qa-ttl-sweeper.yml --limit "$LIMIT" --json "$json_fields" 2>/dev/null) || r3="[]"
  runs=$(jq -s --argjson n "$LIMIT" 'add | sort_by(.createdAt) | reverse | .[:$n]' \
    <(echo "$r1") <(echo "$r2") <(echo "$r3") 2>/dev/null) || {
      echo "ERROR: gh run list failed -- check repo context and network" >&2
      return 1
    }

  # Collapsed view: keep all in-progress/queued runs (current activity matters
  # regardless of age) plus the most-recent ONE per workflow (the latest state
  # of each lifecycle). Dedupe by databaseId so an in-progress run isn't
  # counted twice. Sort newest first.
  if [ "$COLLAPSED" = "1" ]; then
    runs=$(echo "$runs" | jq '
      ([.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or .status == "pending" or .status == "requested")]
       + [group_by(.workflowName)[] | sort_by(.createdAt) | reverse | .[0]])
      | unique_by(.databaseId)
      | sort_by(.createdAt) | reverse
    ')
  fi

  if [ "$COLLAPSED" = "1" ]; then
    printf "\n${C_BOLD}QA pipeline state${NC} ${C_GRAY}(latest run per workflow + all in-progress; pass a number for history view)${NC}\n\n"
  else
    printf "\n${C_BOLD}Recent QA workflow runs${NC} ${C_GRAY}(last $LIMIT across qa-deploy / qa-teardown / qa-ttl-sweeper)${NC}\n\n"
  fi
  printf "  ${C_GRAY}%-3s %-11s %-19s %-10s %-9s %-17s %s${NC}\n" "" "RUN_ID" "WHEN (UTC)" "DURATION" "EVENT" "WORKFLOW" "TITLE"
  printf "  ${C_GRAY}%s${NC}\n" "------------------------------------------------------------------------------------------------------------------------"

  # Use ASCII Unit Separator (0x1F) as field delimiter. Tab would seem natural
  # but bash `read` collapses CONSECUTIVE whitespace IFS characters into one
  # delimiter -- so an empty field (e.g. conclusion="" for in_progress runs)
  # gets swallowed and the following variables shift by one. 0x1F is a
  # non-printable control char that can't appear in workflow titles/URLs/etc,
  # and being non-whitespace it doesn't trigger the collapse behavior.
  echo "$runs" | jq -r '
    .[] |
    [ .databaseId, .workflowName, .status, .conclusion, .event,
      .createdAt, .updatedAt, (.displayTitle // ""), (.url // "") ]
    | join("")' \
  | while IFS=$'\x1f' read -r id wfname status conclusion event created updated title _url; do

    # Pick symbol + color from (status, conclusion)
    case "$status" in
      completed)
        case "$conclusion" in
          success)            sym="✓"; col="$C_GREEN" ;;
          failure)            sym="✗"; col="$C_RED" ;;
          cancelled)          sym="○"; col="$C_GRAY" ;;
          startup_failure|action_required|timed_out) sym="!"; col="$C_RED" ;;
          *)                  sym="?"; col="$C_GRAY" ;;
        esac
        ;;
      in_progress|queued|waiting|pending|requested) sym="●"; col="$C_YELLOW" ;;
      *)                                            sym="?"; col="$C_GRAY" ;;
    esac

    # Duration: for completed runs use updatedAt - createdAt; for in_progress
    # runs use NOW - createdAt so the displayed elapsed is honest (gh's
    # updatedAt only refreshes on step transitions, not during a long-running
    # step like the 20-min grove-ready sentinel poll).
    if [ -n "$created" ]; then
      case "$status" in
        completed) end_ts="$updated" ;;
        *)         end_ts="" ;;  # blank => use NOW in python below
      esac
      duration_sec=$(python3 -c "
from datetime import datetime, timezone
try:
    a = datetime.fromisoformat('$created'.replace('Z','+00:00'))
    b = datetime.fromisoformat('$end_ts'.replace('Z','+00:00')) if '$end_ts' else datetime.now(timezone.utc)
    print(int((b - a).total_seconds()))
except Exception:
    print('')
" 2>/dev/null)
      if [ -n "$duration_sec" ] && [ "$duration_sec" -gt 0 ]; then
        if [ "$duration_sec" -ge 60 ]; then
          dur="$((duration_sec/60))m$((duration_sec%60))s"
        else
          dur="${duration_sec}s"
        fi
      else
        dur="-"
      fi
    else
      dur="-"
    fi

    # Short workflow name (drop the "QA " prefix)
    wfshort="${wfname#QA }"

    # Truncate title to fit
    title_short=$(echo "$title" | cut -c1-50)

    # Render WHEN as YYYY-MM-DD HH:MM (no seconds, no TZ)
    when_short=$(echo "$created" | sed 's/T/ /; s/:[0-9]*Z$//')

    printf "  ${col}%-3s${NC} ${C_GRAY}%-11s${NC} %-19s %-10s %-9s %-17s %s\n" \
      "$sym" "$id" "$when_short" "$dur" "$event" "$wfshort" "$title_short"
  done

  printf "\n"
  printf "  ${C_GRAY}Legend: ${C_GREEN}✓${C_GRAY}=success  ${C_RED}✗${C_GRAY}=failure  ${C_GRAY}○=cancelled  ${C_YELLOW}●${C_GRAY}=in-progress  ${C_RED}!${C_GRAY}=startup_failure/timeout${NC}\n"
  printf "  ${C_GRAY}Inspect a run: gh run view <RUN_ID> --log-failed${NC}\n\n"
}

if [ "$WATCH" = "1" ]; then
  # Live refresh every 5 sec. Ctrl-C to exit.
  while true; do
    clear
    render
    printf "  ${C_GRAY}(watch mode -- refreshes every 5s -- Ctrl-C to exit)${NC}\n"
    sleep 5
  done
else
  render
fi
