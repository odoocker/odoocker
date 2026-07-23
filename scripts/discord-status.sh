#!/usr/bin/env bash
# Post a status-aware Discord embed for a Grove QA workflow.
#
# Handles four alert classes the workflows used to do inline + inconsistently:
#   - HEARTBEAT          clean run, --heartbeat passed (e.g., sweeper found nothing)
#   - NORMAL_SUCCESS     succeeded, prev also succeeded (or no history)
#   - RECOVERED          succeeded, prev was failure or cancelled
#   - NORMAL_FAILURE     failed, prev was success (or first fail in a streak)
#   - REPEATED_FAILURE   failed, 2 consecutive failures
#   - RECURRING_FAILURE  failed, 3+ consecutive failures → adds @here mention
#
# Why a shared script: prior to this, qa-deploy / qa-teardown / qa-ttl-sweeper
# each duplicated jq + curl + color/icon mapping inline. Colors drifted across
# workflows, recovery detection wasn't anywhere, and the noise/signal tradeoff
# differed per file. Consolidating means: one source of truth for the alert
# protocol, one place to fix bugs (e.g., the empty-webhook footgun audit fix #132).
#
# Usage:
#   scripts/discord-status.sh \
#     --status=success|failure|cancelled \
#     --workflow=qa-deploy.yml \
#     --branch=qa \
#     --run-url="$RUN_URL" \
#     --title="QA Deploy" \
#     [--description="..."] \
#     [--field 'name=value']... \
#     [--username="🧪 Grove QA"] \
#     [--heartbeat]
#
# Env required:
#   GH_TOKEN                   gh CLI auth (workflow needs `actions: read`)
#   GITHUB_REPOSITORY          e.g. Goldberry-Playground/odoocker-goldberrygrove
#   DISCORD_OPS_WEBHOOK_URL    destination (skipped silently if empty — same
#                              defense as audit fix #132)
#
# Exit codes:
#   0    posted successfully OR skipped (empty webhook)
#   1    bad args
#   2    gh CLI failure looking up run history (post still happens, classified as NORMAL)
#   3    Discord POST failed (workflow continues; this is best-effort signal)

set -euo pipefail

# ── Arg parsing ─────────────────────────────────────────────────────────────
STATUS=""
WORKFLOW=""
BRANCH=""
RUN_URL=""
TITLE=""
DESCRIPTION=""
USERNAME="🧪 Grove QA"
HEARTBEAT=0
QUIET_SUCCESS=0
declare -a FIELDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --status=*)      STATUS="${1#*=}" ;;
    --workflow=*)    WORKFLOW="${1#*=}" ;;
    --branch=*)      BRANCH="${1#*=}" ;;
    --run-url=*)     RUN_URL="${1#*=}" ;;
    --title=*)       TITLE="${1#*=}" ;;
    --description=*) DESCRIPTION="${1#*=}" ;;
    --username=*)    USERNAME="${1#*=}" ;;
    --heartbeat)     HEARTBEAT=1 ;;
    --quiet-success) QUIET_SUCCESS=1 ;;
    --field)         shift; FIELDS+=("$1") ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

for required in STATUS WORKFLOW BRANCH RUN_URL TITLE; do
  if [ -z "${!required}" ]; then
    echo "Missing --${required,,}" >&2
    exit 1
  fi
done

# ── Empty webhook → skip silently (same pattern audit fix #132 used) ───────
if [ -z "${DISCORD_OPS_WEBHOOK_URL:-}" ]; then
  echo "::warning::DISCORD_OPS_WEBHOOK_URL is empty — skipping Discord post"
  exit 0
fi

# ── Run-history lookup → determine alert variant ───────────────────────────
# Fetch up to 5 prior runs on the same branch. The current run hasn't recorded
# its conclusion yet (it's in-progress executing this very script), so we count
# from index 0 = most recent COMPLETED run.
#
# `gh run list` is per-branch, per-workflow, per-status. With no --status it
# returns all conclusions including 'cancelled' (which we treat as failure for
# streak purposes — a cancelled run usually means concurrency cancelled the
# previous in-flight deploy, and from an alerting standpoint, "nothing
# succeeded recently" is what matters).
PREV_CONCLUSIONS=""
if ! PREV_CONCLUSIONS=$(gh run list \
    --workflow="$WORKFLOW" \
    --branch="$BRANCH" \
    --limit=5 \
    --json conclusion \
    --jq '.[] | .conclusion // "in_progress"' 2>/dev/null); then
  echo "::warning::gh run list failed — falling back to NORMAL alert variant (no streak/recovery context)"
  PREV_CONCLUSIONS=""
fi

# Count CONSECUTIVE failures from most-recent backwards.
# "failure" + "cancelled" + "timed_out" + "startup_failure" all count as
# fail-equivalents; success breaks the streak.
streak=0
prev_was_failure=0
while IFS= read -r c; do
  [ -z "$c" ] && continue
  case "$c" in
    success|"") break ;;
    failure|cancelled|timed_out|startup_failure|action_required)
      streak=$((streak + 1))
      [ "$streak" = "1" ] && prev_was_failure=1
      ;;
    *) break ;;  # in_progress, neutral, skipped → don't count
  esac
done <<< "$PREV_CONCLUSIONS"

# Variant decision matrix
variant=""
if [ "$STATUS" = "success" ]; then
  if [ "$prev_was_failure" = "1" ]; then
    variant="RECOVERED"
  elif [ "$HEARTBEAT" = "1" ]; then
    variant="HEARTBEAT"
  else
    variant="NORMAL_SUCCESS"
  fi
else
  # failure / cancelled / etc. The streak count INCLUDES this run.
  this_streak=$((streak + 1))
  if [ "$this_streak" -ge 3 ]; then
    variant="RECURRING_FAILURE"
  elif [ "$this_streak" = "2" ]; then
    variant="REPEATED_FAILURE"
  else
    variant="NORMAL_FAILURE"
  fi
fi

# --quiet-success: cron health checks run every N minutes; posting every
# plain success is noise. With this flag, NORMAL_SUCCESS exits silently --
# only failures + RECOVERED (streak break) reach Discord.
if [ "$variant" = "NORMAL_SUCCESS" ] && [ "${QUIET_SUCCESS:-0}" = "1" ]; then
  echo "  (quiet-success: healthy + no streak to clear; not posting)"
  exit 0
fi

# ── Variant → display config (icon, color, title prefix, mention) ──────────
# Colors are Discord integer values (decimal). Mapping per ADR-008 design:
#   green = success-class
#   muted-blue = informational (heartbeat)
#   red = first failure / cancellation
#   dark-red = recurring failure
case "$variant" in
  NORMAL_SUCCESS)
    icon="✅"; color=5763719; title_prefix=""; mention=""
    ;;
  HEARTBEAT)
    icon="🟢"; color=3447003; title_prefix="heartbeat: "; mention=""
    ;;
  RECOVERED)
    icon="✅"; color=3066993; title_prefix="RECOVERED: "; mention=""
    ;;
  NORMAL_FAILURE)
    icon="🚨"; color=15158332; title_prefix="FAILED: "; mention=""
    ;;
  REPEATED_FAILURE)
    icon="🚨"; color=15158332; title_prefix="FAILED (2nd in a row): "; mention=""
    ;;
  RECURRING_FAILURE)
    icon="🔥"; color=10038562; title_prefix="RECURRING FAILURE (${this_streak}× in a row): "; mention="@here"
    ;;
esac

# ── Build embed via jq (handles escaping, never echoes secrets) ─────────────
# Convert --field name=value args into JSON [{name, value, inline}, ...]
fields_json="[]"
if [ "${#FIELDS[@]}" -gt 0 ]; then
  fields_json=$(printf '%s\n' "${FIELDS[@]}" | jq -R 'split("=") | {name: .[0], value: (.[1:] | join("=")), inline: false}' | jq -s .)
fi

# Recovery alerts include a "previous run" hint so the operator can compare.
# We don't have the exact prev run URL here (would need another gh call); the
# variant name is enough context. Streak count is shown for failure variants.
footer_text=""
case "$variant" in
  RECOVERED)         footer_text="Previous run was a failure — service is back" ;;
  REPEATED_FAILURE)  footer_text="2 consecutive failures — investigate if it happens again" ;;
  RECURRING_FAILURE) footer_text="${this_streak} consecutive failures — operator attention needed" ;;
  HEARTBEAT)         footer_text="Heartbeat — workflow ran clean, no action needed" ;;
esac

payload=$(jq -n \
  --arg username "$USERNAME" \
  --arg title "${icon} ${title_prefix}${TITLE}" \
  --arg description "$DESCRIPTION" \
  --arg url "$RUN_URL" \
  --argjson color "$color" \
  --argjson fields "$fields_json" \
  --arg footer "$footer_text" \
  --arg mention "$mention" \
  '{
    username: $username,
    content: (if $mention != "" then $mention else null end),
    embeds: [{
      title: $title,
      description: (if $description != "" then $description else null end),
      url: $url,
      color: $color,
      fields: $fields,
      footer: (if $footer != "" then {text: $footer} else null end)
    }]
  } | del(.. | nulls)')

# ── POST (best-effort; failure here doesn't fail the workflow) ─────────────
if ! curl -fsS -X POST -H "Content-Type: application/json" \
    -d "$payload" "$DISCORD_OPS_WEBHOOK_URL" >/dev/null 2>&1; then
  echo "::warning::Discord POST failed (variant=${variant}); workflow continues"
  exit 3
fi

echo "  ✓ Discord posted (variant=${variant})"
