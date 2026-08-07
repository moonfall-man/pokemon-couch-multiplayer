#!/usr/bin/env bash
# Launch N copies side by side on Linux / Raspberry Pi, one controller each.
#
# Each player gets:
#   * their own save directory   POKEPORT_IDENTITY=gen1recomp-pN
#                                -> ~/.local/share/love/gen1recomp-pN
#   * exactly one controller     POKEPORT_PAD=N  (the Nth pad in SDL order)
#   * their own tiled window
#
# Plug every controller in BEFORE running this.
#
# Usage:
#   ./play.sh -p 2                 two players, Red
#   ./play.sh -p 2 -g yellow
#   ./play.sh -p 2 -G              also ghost-link them (needs the GHOST_LINK mod)
#   ./play.sh -p 2 -T              don't tile the windows
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYERS=2
GAME="red"
GAMEDIR="$HERE/game"
LOVEBIN="${LOVE:-love}"
TILE=1
GHOSTS=0
GHOST_PORT=7778

while getopts "p:g:d:l:TGh" opt; do
  case "$opt" in
    p) PLAYERS="$OPTARG" ;;
    g) GAME="$OPTARG" ;;
    d) GAMEDIR="$OPTARG" ;;
    l) LOVEBIN="$OPTARG" ;;
    T) TILE=0 ;;
    G) GHOSTS=1 ;;
    h) sed -n '2,17p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

command -v "$LOVEBIN" >/dev/null 2>&1 || cat >&2 <<EOF
Could not find LOVE ('$LOVEBIN').

  sudo apt install love

or extract the official build and point at its binary:
  ./gen1recomp-<ver>-linux-arm64.AppImage --appimage-extract
  ./play.sh -l ./squashfs-root/bin/love

The game targets LOVE 11.5; the bundled one in the official build is exactly
that, whereas apt may give you an older 11.x.
EOF
command -v "$LOVEBIN" >/dev/null 2>&1 || exit 1

[ -d "$GAMEDIR" ] || { echo "No game directory at $GAMEDIR -- run ./build.sh first." >&2; exit 1; }

# Ghost bodies, so players can tell each other apart on screen.
SPRITES=(SPRITE_RED SPRITE_BLUE SPRITE_COOLTRAINER_M SPRITE_COOLTRAINER_F)

echo "love    : $(command -v "$LOVEBIN")"
echo "game    : $GAMEDIR"
echo "players : $PLAYERS ($GAME)"
echo ""

PIDS=()
for i in $(seq 1 "$PLAYERS"); do
  export POKEPORT_IDENTITY="gen1recomp-p$i"
  export POKEPORT_PAD="$i"
  export POKEPORT_KEYBOARD=1

  note=""
  if [ "$GHOSTS" = "1" ]; then
    export POKEGHOST_PORT="$GHOST_PORT"
    export POKEGHOST_SPRITE="${SPRITES[$(( (i - 1) % ${#SPRITES[@]} ))]}"
    if [ "$i" = "1" ]; then
      export POKEGHOST_HOST=1
      unset POKEGHOST_JOIN || true
      note=", hosting ghosts on :$GHOST_PORT"
    else
      unset POKEGHOST_HOST || true
      export POKEGHOST_JOIN="127.0.0.1:$GHOST_PORT"
      note=", ghosts -> 127.0.0.1:$GHOST_PORT"
    fi
    note="$note as $POKEGHOST_SPRITE"
  fi

  "$LOVEBIN" "$GAMEDIR" "--game=$GAME" &
  PIDS+=($!)
  echo "  player $i: pid ${PIDS[-1]}, pad #$i, saves in gen1recomp-p$i$note"
  # The host has to be listening before anyone dials, and SDL needs a moment
  # to enumerate before the next instance asks for pad N.
  sleep 1
done

if [ "$TILE" = "0" ]; then
  echo ""
  echo "Launched (untiled). Ctrl-C here closes them all."
  wait
  exit 0
fi

# ---------------------------------------------------------------------- tile
if ! command -v wmctrl >/dev/null 2>&1; then
  echo ""
  echo "wmctrl not installed, so windows are untiled. Either:"
  echo "  sudo apt install wmctrl"
  echo "or drag them into place once -- most WMs remember the position."
  wait
  exit 0
fi

# Work area, falling back to a sane 1080p projector default.
read -r SW SH < <(xdotool getdisplaygeometry 2>/dev/null || echo "1920 1080")

if   [ "$PLAYERS" -le 1 ]; then COLS=1; ROWS=1
elif [ "$PLAYERS" -eq 2 ]; then COLS=2; ROWS=1
else COLS=2; ROWS=2
fi
W=$(( SW / COLS ))
H=$(( SH / ROWS ))

echo ""
echo "Tiling ${COLS}x${ROWS} at ${W}x${H} on a ${SW}x${SH} display..."

# Windows do not exist the instant the processes do.
sleep 3

idx=0
for pid in "${PIDS[@]}"; do
  win="$(wmctrl -lp | awk -v p="$pid" '$3 == p { print $1; exit }')"
  if [ -z "$win" ]; then
    echo "  player $((idx + 1)) (pid $pid): no window found to tile"
    idx=$((idx + 1))
    continue
  fi
  x=$(( (idx % COLS) * W ))
  y=$(( (idx / COLS) * H ))
  # remove maximised state first, or a move is ignored
  wmctrl -i -r "$win" -b remove,maximized_vert,maximized_horz 2>/dev/null || true
  wmctrl -i -r "$win" -e "0,$x,$y,$W,$H"
  idx=$((idx + 1))
done

echo ""
echo "Ready. Ctrl-C here closes them all."
wait
