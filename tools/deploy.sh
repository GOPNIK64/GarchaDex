#!/usr/bin/env bash
# Copy the addons of this repo into the Forever client (macOS).
# The folder name must match the .toc name and "AddOns" is case-sensitive.
# Lua-only edits need /reload in game; a NEW folder or file needs a client restart.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WOW_ROOT="${WOW_ROOT:-/Applications/World of Warcraft}"
FLAVOR="${FLAVOR:-_classic_beta_}"
ADDONS="$WOW_ROOT/$FLAVOR/Interface/AddOns"

if [ ! -d "$WOW_ROOT/$FLAVOR" ]; then
  echo "client flavor not found: $WOW_ROOT/$FLAVOR" >&2
  exit 1
fi
mkdir -p "$ADDONS"

# Never deploy text that would reach an English client in Spanish: the phrase table drifts.
if [ -f "$REPO_DIR/tools/text_audit.py" ]; then
  if ! python3 "$REPO_DIR/tools/text_audit.py" "$REPO_DIR"/GarchaDex/*.lua; then
    echo "refusing to deploy: fix the leaked strings in GarchaDex/Locale.lua first" >&2
    exit 1
  fi
fi

for src in "$REPO_DIR"/*/; do
  name="$(basename "$src")"
  case "$name" in tools|data|docs) continue ;; esac
  if [ ! -f "$src$name.toc" ]; then
    continue
  fi
  rm -rf "$ADDONS/$name"
  cp -R "$src" "$ADDONS/$name"
  echo "deployed $name -> $ADDONS/$name"
done

if pgrep -x "World of Warcraft" >/dev/null 2>&1 || pgrep -f "World of Warcraft.*\.app" >/dev/null 2>&1; then
  echo "NOTE: the client is running — a new addon folder only shows up after a full restart (not /reload)."
fi
