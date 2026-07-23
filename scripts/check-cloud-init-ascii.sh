#!/usr/bin/env bash
# check-cloud-init-ascii.sh -- Verify cloud-init inputs are pure ASCII.
#
# Cloud-init's YAML parser (PyYAML in strict mode) rejects raw high bytes with
# "unacceptable character #x0080: special characters are not allowed". UTF-8
# typographic characters (em-dash, en-dash, smart quotes, box-drawing chars,
# arrows) embed bytes >= 0x80, so any one of them inside a templatefile()'d
# value crashes cloud-init at YAML parse time -- meaning the droplet boots
# but never runs docker compose, never writes the grove-ready sentinel.
#
# This wasted ~30 min on 2026-06-24 when em-dashes (U+2014) in comments
# silently broke the QA droplet. The compose pull succeeded, all images
# were public -- the entire stack just never ran.
#
# Run this as part of qa-preflight to catch the bug at PR time, not after a
# 20-min sentinel-poll timeout.
#
# Usage:
#   bash scripts/check-cloud-init-ascii.sh             # checks default file list
#   FILES="path/to/extra.yml" bash scripts/check-cloud-init-ascii.sh
#
# Exit codes:
#   0  All files are pure ASCII
#   1  At least one file has a non-ASCII byte

set -euo pipefail

DEFAULT_FILES=(
  # (monolith QA entries removed 2026-07-07 -- env deleted at Phase 4+5 cutover)
  # Level 3 (ADR-007) -- added 2026-07-01 after Level 3 first-boot failed
  # exactly this way: em-dashes + arrows + box-drawing in cloud-init.yaml.tpl
  # caused YAML #x0080 parse error at cloud-init time. The droplet booted +
  # ran DO's default base config, but cloud-init SKIPPED the user_data's
  # write_files/runcmd blocks entirely -- no docker, no /etc/grove, no compose.
  # Only diagnosed via SSH after 25+ min of watching URLs return 000.
  "infra/terraform/environments/qa-app-platform/cloud-init.yaml.tpl"
  "infra/terraform/environments/qa-app-platform/cloud-init-obs.yaml.tpl"
  "infra/terraform/environments/qa-app-platform/compose/docker-compose.qa.yml"
  "infra/terraform/environments/qa-app-platform/compose/docker-compose.obs.yml"
  "infra/terraform/environments/qa-app-platform/compose/Caddyfile.tpl"
  "infra/terraform/environments/qa-app-platform/compose/Caddyfile-obs.tpl"
)

if [ -n "${FILES:-}" ]; then
  # shellcheck disable=SC2206
  FILE_LIST=($FILES)
else
  FILE_LIST=("${DEFAULT_FILES[@]}")
fi

fail=0
for f in "${FILE_LIST[@]}"; do
  if [ ! -f "$f" ]; then
    echo "  ? $f  (not found, skipping)"
    continue
  fi
  # Find non-ASCII lines. Uses perl (not grep -nP) because macOS BSD grep
  # doesn't ship Perl-compat regex support: `grep -P` errors out, the prior
  # `2>/dev/null || true` swallowed the error, and the check ALWAYS reported
  # "pure ASCII" on macOS. CI (Linux GNU grep) catches it correctly -- which
  # masked the divergence until a U+2192 right-arrow slipped into PR #82's
  # compose file and broke deploy 28246806115. perl is in macOS base install
  # and on every GH runner.
  match=$(perl -ne 'print "$.: $_" if /[^\x00-\x7f]/' "$f" | head -3)
  if [ -z "$match" ]; then
    echo "  v $f  (pure ASCII)"
  else
    echo "  X $f  (non-ASCII detected):"
    # Audit note SC2001 (2026-06-29): sed is more readable than bash parameter
    # expansion for prefix-indent on a multi-line string. Disable suggestion.
    # shellcheck disable=SC2001
    echo "$match" | sed 's/^/      /'
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

ERROR: Non-ASCII characters found in cloud-init template inputs. Cloud-init's
YAML parser will reject these as #x0080 errors, the droplet will boot but
NEVER run docker compose, and the grove-ready sentinel will never fire.

Common culprits (replace with ASCII equivalents):
  em-dash       U+2014 ->  --
  en-dash       U+2013 ->  -
  smart quotes  U+2018/2019/201C/201D ->  ' "
  box-drawing   U+2500 / U+2502 etc. ->  - |
  arrows        U+2192/2190 ->  -> <-
  ellipsis      U+2026 ->  ...

To bulk-fix in one go:
  python3 - <<'PYEOF'
  import re
  for p in ['infra/terraform/environments/qa-app-platform/cloud-init.yaml.tpl',
            'infra/terraform/environments/qa-app-platform/compose/docker-compose.qa.yml',
            'infra/terraform/environments/qa-app-platform/compose/Caddyfile.tpl']:
      with open(p, 'rb') as f: d = f.read()
      out = bytearray()
      i = 0
      while i < len(d):
          if d[i] < 0x80:
              out.append(d[i]); i += 1
          else:
              n = 2 if d[i] & 0xE0 == 0xC0 else (3 if d[i] & 0xF0 == 0xE0 else 4)
              out.extend(b'-'); i += n
      with open(p, 'wb') as f: f.write(bytes(out))
  PYEOF
EOF
  exit 1
fi

echo "v all ${#FILE_LIST[@]} files are pure ASCII -- cloud-init YAML parse will succeed"
