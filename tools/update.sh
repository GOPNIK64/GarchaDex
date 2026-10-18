#!/usr/bin/env bash
# Check the latest GarchaDex release, and optionally install it.
#
# Why a shell script and not something in the addon: the WoW client has no network access and the
# addon sandbox has no file IO, so nothing running inside the game can ask GitHub anything. This is
# the asking half; it leaves the answer in data/gdx_latest.lua, which the addon reads on the next
# /reload to put "a new version is out: x.y.z" in the window footer.
#
#   ./tools/update.sh            check only (prints installed vs latest, writes the stamp)
#   ./tools/update.sh --install  download the release asset and replace the addon folder
#
# Overrides: GDX_ADDONS (AddOns path), GDX_REPO (owner/name).
set -euo pipefail

REPO="${GDX_REPO:-GOPNIK64/GarchaDex}"
ADDONS="${GDX_ADDONS:-/Applications/World of Warcraft/_classic_beta_/Interface/AddOns}"
DIR="$ADDONS/GarchaDex"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

if [ ! -f "$DIR/GarchaDex.toc" ]; then
  echo "no encuentro $DIR/GarchaDex.toc — pasá la ruta con GDX_ADDONS=/ruta/a/Interface/AddOns" >&2
  exit 2
fi

latest=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
current=$(sed -n 's/^## Version: *//p' "$DIR/GarchaDex.toc" | tr -d '\r')

stamp() {
  mkdir -p "$DIR/data"
  printf 'local _, ns = ...\nns.LATEST = "%s"\nns.LATEST_AT = %s\n' "$latest" "$(date +%s)" > "$DIR/data/gdx_latest.lua"
}

echo "instalada: $current   ·   publicada: $latest"

if [ "$latest" = "$current" ]; then
  stamp
  echo "estás al día"
  exit 0
fi

if python3 - "$current" "$latest" <<'PY'
import sys
def n(v):
    p = [int(x) for x in (v.split('.') + ['0', '0'])[:3]]
    return p[0] * 10000 + p[1] * 100 + p[2]
sys.exit(0 if n(sys.argv[2]) > n(sys.argv[1]) else 1)
PY
then
  echo "hay una versión nueva: $latest"
else
  stamp
  echo "la publicada no es más nueva que la tuya (build local)"
  exit 0
fi

if [ "$INSTALL" = "1" ]; then
  tmp=$(mktemp -d)
  url="https://github.com/$REPO/releases/download/v$latest/GarchaDex-$latest.zip"
  echo "bajando $url"
  curl -fsSL "$url" -o "$tmp/gdx.zip"
  rm -rf "$DIR"
  unzip -q "$tmp/gdx.zip" -d "$ADDONS"
  rm -rf "$tmp"
  stamp
  echo "instalada $latest en $ADDONS/GarchaDex"
  echo "cerrá WoW por completo y volvé a entrar (si cambió la lista de archivos, /reload no alcanza)"
else
  stamp
  echo "para instalarla: $0 --install"
  echo "o bajala a mano: https://github.com/$REPO/releases/latest"
fi
