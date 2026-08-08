#!/usr/bin/env bash
# Install the couch-multiplayer mods into each player's game folder.
#
# Nothing is patched and nothing is built. This copies three mod folders into
# the save directories the official build already reads:
#
#     ~/.local/share/gen1recomp-p1/mods/PAD_OWNER/
#     ~/.local/share/gen1recomp-p1/mods/PAD_HOTKEYS/
#     ~/.local/share/gen1recomp-p1/mods/GHOST_LINK/
#
# It also seeds player 1's ROM cache to the other players, so only one person
# has to do the import -- cache and mods only, never a save file and never
# options.lua, so nobody inherits anyone else's playthrough or settings.
#
# Safe to re-run.
#
# Usage:
#   ./install.sh -p 2
#   ./install.sh -i pokemon-love2d      one ordinary single-player copy
#   ./install.sh -p 2 -f                overwrite an existing ROM cache
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

PLAYERS=2
IDENTITY=""
FORCE=0

while getopts "p:i:fh" opt; do
  case "$opt" in
    p) PLAYERS="$OPTARG" ;;
    i) IDENTITY="$OPTARG" ;;
    f) FORCE=1 ;;
    h) sed -n '2,21p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

MODS=(PAD_OWNER PAD_HOTKEYS GHOST_LINK)
for m in "${MODS[@]}"; do
  [ -d "$REPO/$m" ] || { echo "Missing $REPO/$m -- run this from a full checkout." >&2; exit 1; }
done

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

# The official build is FUSED (the game archive is appended to the binary),
# and LOVE drops the "love/" segment for fused games:
#
#   fused      ~/.local/share/<identity>
#   plain love ~/.local/share/love/<identity>
#
# Which one applies depends on how you launch the game, so rather than guess,
# prefer a location that already has data in it and fall back to the fused
# one. Verified on Windows against the real executable; the rule is the same
# in LOVE's filesystem module on every desktop platform.
savedir() {
  local id="$1"
  if [ -d "$DATA/$id" ]; then echo "$DATA/$id"
  elif [ -d "$DATA/love/$id" ]; then echo "$DATA/love/$id"
  else echo "$DATA/$id"; fi
}

if [ -n "$IDENTITY" ]; then
  IDS=("$IDENTITY")
else
  IDS=()
  for i in $(seq 1 "$PLAYERS"); do IDS+=("gen1recomp-p$i"); done
fi

echo "mods from : $REPO"
echo "installing: ${MODS[*]}"
echo ""

for id in "${IDS[@]}"; do
  dest="$(savedir "$id")"
  mkdir -p "$dest/mods"
  echo "$id -> $dest/mods"
  for m in "${MODS[@]}"; do
    rm -rf "$dest/mods/$m"
    cp -r "$REPO/$m" "$dest/mods/$m"
    echo "    + $m"
  done
done

# ------------------------------------------------------------- ROM cache
if [ -z "$IDENTITY" ] && [ "$PLAYERS" -ge 2 ]; then
  src="$(savedir gen1recomp-p1)"
  any=0
  for v in red blue yellow; do
    [ -f "$src/$v/rom-cache.complete" ] && any=1
  done

  echo ""
  if [ "$any" = "0" ]; then
    echo "No ROM cache in gen1recomp-p1 yet."
    echo "Run  ./play.sh -p 1  , import your ROM, quit, then re-run this."
  else
    echo "Seeding the ROM cache from player 1..."
    for i in $(seq 2 "$PLAYERS"); do
      dest="$(savedir "gen1recomp-p$i")"
      copied=0
      for v in red blue yellow; do
        [ -d "$src/$v" ] || continue
        # An allowlist, not a denylist: anything not named here is simply not
        # copied, so a file this script has never heard of cannot leak one
        # player's save into another's folder.
        for d in data/generated assets/generated; do
          [ -d "$src/$v/$d" ] || continue
          if [ -d "$dest/$v/$d" ] && [ "$FORCE" = "0" ]; then continue; fi
          mkdir -p "$dest/$v/$(dirname "$d")"
          rm -rf "$dest/$v/$d"
          cp -r "$src/$v/$d" "$dest/$v/$d"
          copied=$((copied + 1))
        done
        if [ -f "$src/$v/rom-cache.complete" ] \
           && { [ ! -f "$dest/$v/rom-cache.complete" ] || [ "$FORCE" = "1" ]; }; then
          mkdir -p "$dest/$v"
          cp -f "$src/$v/rom-cache.complete" "$dest/$v/rom-cache.complete"
          copied=$((copied + 1))
        fi
      done
      if [ "$copied" -gt 0 ]; then
        echo "    player $i : $copied item(s) copied"
      else
        echo "    player $i : already has a cache (use -f to replace)"
      fi
    done
  fi
fi

echo ""
echo "Done. Next: ./play.sh -p $PLAYERS"
