#!/usr/bin/env bash
# Sync .env with .env.example (single, repo-root .env), safely merging new
# variables without losing values you've already overridden.
#
# Usage:
#   bash scripts/env-sync.sh        # interactive (preview diff + confirm)
#   bash scripts/env-sync.sh -y     # non-interactive (apply without asking)
#   bash scripts/env-sync.sh -h     # help
#
# Behavior:
#   First run (no .env):  copies .env.example -> .env as-is. No confirmation.
#   Subsequent runs:      walks .env.example line-by-line. For each KEY=value:
#                           - if you already have KEY in .env, keep YOUR value
#                           - otherwise copy the line from .env.example
#                         Orphaned keys (in your .env but NOT in .env.example)
#                         are preserved at the bottom under a warning header.
#                         A diff is shown; you must confirm [y/N] before apply.
#
# Backups: .env -> .env.bak.<timestamp> on every apply.
set -uo pipefail

ASSUME_YES=0
usage() { sed -n '2,/^set/p' "$0" | sed 's/^# \?//' | sed '$d'; }

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; echo "Usage: $0 [-y|--yes]" >&2; exit 2 ;;
  esac
done

# Repo root = parent of scripts/. The single .env lives there.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.." || { echo "cannot cd to repo root" >&2; exit 1; }

EXAMPLE=".env.example"
TARGET=".env"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
bad()  { printf "  ${RED}✗${NC} %s\n" "$1" >&2; }
info() { printf "\n${BOLD}%s${NC}\n" "$1"; }

if [ ! -f "$EXAMPLE" ]; then
  bad "$EXAMPLE not found in $(pwd)"
  exit 1
fi

# ── First-time setup ────────────────────────────────────────────────────────
if [ ! -f "$TARGET" ]; then
  cp "$EXAMPLE" "$TARGET"
  info "First-time setup"
  ok "created $TARGET from $EXAMPLE"
  printf "\n  Next: edit ${BOLD}$(pwd)/$TARGET${NC} and set your real values.\n"
  exit 0
fi

info "Syncing $TARGET from $EXAMPLE"

# Collect user's CURRENT uncommented keys and their values.
user_keys=(); user_vals=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    user_keys+=("${BASH_REMATCH[1]}"); user_vals+=("${BASH_REMATCH[2]}")
  fi
done < "$TARGET"

lookup_user_value() {
  local key="$1" i
  for i in "${!user_keys[@]}"; do
    [ "${user_keys[$i]}" = "$key" ] && { echo "${user_vals[$i]}"; return 0; }
  done
  return 1
}

# Declaration regex: matches KEY=value and commented #KEY=value template lines.
DECL_RE='^#? ?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'

template_keys=()
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ $DECL_RE ]] && template_keys+=("${BASH_REMATCH[1]}")
done < "$EXAMPLE"

key_in_template() { local k; for k in "${template_keys[@]}"; do [ "$k" = "$1" ] && return 0; done; return 1; }

# Build the proposed .env walking the template.
tmp=$(mktemp); preserved=0; written_keys=()
key_already_written() { local k; for k in "${written_keys[@]}"; do [ "$k" = "$1" ] && return 0; done; return 1; }

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ $DECL_RE ]]; then
    key="${BASH_REMATCH[1]}"
    key_already_written "$key" && continue
    written_keys+=("$key")
    if user_val=$(lookup_user_value "$key"); then
      echo "${key}=${user_val}" >> "$tmp"; preserved=$((preserved + 1))
    else
      echo "$line" >> "$tmp"
    fi
  else
    echo "$line" >> "$tmp"
  fi
done < "$EXAMPLE"

# Orphaned keys (in .env, not in template) → preserved at the bottom.
orphans=()
for key in "${user_keys[@]}"; do
  key_in_template "$key" || orphans+=("$key")
done
if [ "${#orphans[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# ─────────────────────────────────────────────────────────────────"
    echo "# ORPHANED keys — present in your .env but no longer in .env.example."
    echo "# Likely leftovers from an older version. Review and delete if unused."
    echo "# ─────────────────────────────────────────────────────────────────"
    for key in "${orphans[@]}"; do echo "${key}=$(lookup_user_value "$key")"; done
  } >> "$tmp"
fi

# ── Preview + confirm ─────────────────────────────────────────────────────────
new_keys=0
for k in "${template_keys[@]}"; do lookup_user_value "$k" >/dev/null || new_keys=$((new_keys + 1)); done

info "Proposed changes"
printf "  preserved:  ${BOLD}%d${NC} of your override(s)\n" "$preserved"
printf "  new keys:   ${BOLD}%d${NC} template key(s) added\n" "$new_keys"
if [ "${#orphans[@]}" -gt 0 ]; then
  printf "  orphaned:   ${BOLD}${YELLOW}%d${NC} key(s) moved to the bottom — review\n" "${#orphans[@]}"
  for key in "${orphans[@]}"; do printf "              - %s\n" "$key"; done
fi

if cmp -s "$TARGET" "$tmp"; then
  echo; ok "no changes — .env is already in sync"
  rm -f "$tmp"; exit 0
fi

info "Diff (current .env → proposed .env)"
if [ -t 1 ] && command -v git >/dev/null 2>&1; then
  git --no-pager diff --no-index --color=always "$TARGET" "$tmp" 2>/dev/null | tail -n +5 || true
elif command -v diff >/dev/null 2>&1; then
  diff -u "$TARGET" "$tmp" | sed 's/^/  /' || true
else
  echo "  (no diff tool available — skipping preview)"
fi

if [ "$ASSUME_YES" != "1" ]; then
  echo
  printf "${BOLD}Apply these changes?${NC} [y/N] "
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf "\n${YELLOW}Aborted — .env left untouched.${NC}\n"; rm -f "$tmp"; exit 0 ;;
  esac
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
backup="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$backup"
mv "$tmp" "$TARGET"
info "Applied"
ok "backup saved to $(pwd)/$backup"
printf "\n${GREEN}${BOLD}Sync complete.${NC}\n"
