#!/usr/bin/env bash
# Build a split-screen-capable gen1recomp game directory on Linux / Raspberry Pi.
#
# Unpacks the stock game, injects src/core/PadOwner.lua, and guards main.lua's
# joystick callbacks so each running copy answers to exactly one controller.
#
# Output is a DIRECTORY, not a .love. LOVE runs a directory directly
# (`love ./game`), which means no zip tooling is needed and editing the patch
# afterwards is just editing a file.
#
# Usage:
#   ./build.sh                          # finds a .love or .apk next to this script
#   ./build.sh -s gen1recomp.love
#   ./build.sh -s gen1recomp-android.apk -o ./game
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=""
OUT="$HERE/game"

while getopts "s:o:h" opt; do
  case "$opt" in
    s) SRC="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) sed -n '2,14p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need unzip
need awk
need grep

# ------------------------------------------------------------------- source
if [ -z "$SRC" ]; then
  for cand in "$HERE"/*.love "$HERE"/../*.love "$HERE"/../../*.love \
              "$HERE"/*.apk "$HERE"/../*.apk "$HERE"/../../*.apk; do
    [ -f "$cand" ] && { SRC="$cand"; break; }
  done
fi
[ -n "$SRC" ] || { echo "No source found. Pass -s <file.love|file.apk>." >&2; exit 1; }
[ -f "$SRC" ] || { echo "Not found: $SRC" >&2; exit 1; }

PADOWNER="$HERE/../patch/PadOwner.lua"
[ -f "$PADOWNER" ] || { echo "Missing $PADOWNER" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# An APK is a zip holding assets/game.love; a .love is the archive itself.
LOVEFILE="$SRC"
case "${SRC,,}" in
  *.apk)
    echo "source apk : $SRC"
    unzip -o -q "$SRC" assets/game.love -d "$WORK"
    LOVEFILE="$WORK/assets/game.love"
    ;;
  *) echo "source love: $SRC" ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"
unzip -o -q "$LOVEFILE" -d "$OUT"
[ -f "$OUT/main.lua" ] || { echo "main.lua not at the archive root -- is this gen1recomp?" >&2; exit 1; }

cp "$PADOWNER" "$OUT/src/core/PadOwner.lua"
echo "  + src/core/PadOwner.lua"

# -------------------------------------------------------------- patch main
MAIN="$OUT/main.lua"

# Insert INSERT immediately after the single line matching ANCHOR.
# Idempotent, and fails loudly when an anchor does not match exactly once --
# so a future upstream version gives a clear error instead of a broken build.
add_after() {
  local anchor="$1" insert="$2" label="$3"
  if grep -qxF "$insert" "$MAIN"; then
    local before after
    before="$(grep -nxF "$anchor" "$MAIN" | head -1 | cut -d: -f1)"
    after="$(grep -nxF "$insert" "$MAIN" | head -1 | cut -d: -f1)"
    if [ -n "$before" ] && [ "$after" = "$((before + 1))" ]; then
      echo "  = $label (already patched)"
      return 0
    fi
  fi
  local count
  count="$(grep -cxF "$anchor" "$MAIN" || true)"
  if [ "$count" != "1" ]; then
    echo "anchor matched $count times (expected 1): $label" >&2
    echo "  anchor: $anchor" >&2
    exit 1
  fi
  awk -v a="$anchor" -v ins="$insert" '
    { print }
    $0 == a { print ins }
  ' "$MAIN" > "$MAIN.tmp" && mv "$MAIN.tmp" "$MAIN"
  echo "  + $label"
}

add_after 'local NxDisplay = require("src.core.NxDisplay")' \
          'local PadOwner = require("src.core.PadOwner")' \
          'require PadOwner'
add_after 'local PadOwner = require("src.core.PadOwner")' \
          'PadOwner.allowBackgroundEvents()' \
          'enable background pad events'

# Every pad/stick entry point. Guarded HERE rather than inside
# src/core/Input.lua on purpose: Game:gamepadpressed cycles GAME SPEED and
# routes menu input BEFORE delegating to Input, so a filter in Input would
# still let player 2's pad drive player 1's menus.
PAD_GUARD='  if not PadOwner.owns(joystick) then return end'
add_after 'function love.gamepadpressed(joystick, button)'      "$PAD_GUARD" 'love.gamepadpressed'
add_after 'function love.gamepadreleased(joystick, button)'     "$PAD_GUARD" 'love.gamepadreleased'
add_after 'function love.gamepadaxis(joystick, axis, value)'    "$PAD_GUARD" 'love.gamepadaxis'
add_after 'function love.joystickpressed(joystick, button)'     "$PAD_GUARD" 'love.joystickpressed'
add_after 'function love.joystickreleased(joystick, button)'    "$PAD_GUARD" 'love.joystickreleased'
add_after 'function love.joystickaxis(joystick, axis, value)'   "$PAD_GUARD" 'love.joystickaxis'
add_after 'function love.joystickhat(joystick, hat, direction)' "$PAD_GUARD" 'love.joystickhat'

# Hotplug changes SDL's enumeration order, so the binding must be retaken.
add_after 'function love.joystickadded(joystick)'   '  PadOwner.refresh()' 'joystickadded -> refresh'
add_after 'function love.joystickremoved(joystick)' '  PadOwner.refresh()' 'joystickremoved -> refresh'

KB_GUARD='  if not PadOwner.keyboardEnabled then return end'
add_after 'function love.keypressed(key, scancode, isrepeat)' "$KB_GUARD" 'love.keypressed'
add_after 'function love.keyreleased(key)'                    "$KB_GUARD" 'love.keyreleased'

echo ""
echo "Built: $OUT"
echo "Next:  ./play.sh -p 2"
