#!/usr/bin/env bash
# Launch N copies side by side on Linux / Raspberry Pi, one controller each.
#
# Runs the OFFICIAL build. Nothing is patched, unpacked or rebuilt -- the
# split-screen behaviour comes from the PAD_OWNER mod, which ./install.sh
# drops into each player's mods folder.
#
# Each player gets:
#   * their own save directory   POKEPORT_IDENTITY=gen1recomp-pN
#   * exactly one controller     POKEPORT_PAD=N  (the Nth pad in SDL order)
#   * their own tiled window
#
# Plug every controller in BEFORE running this.
#
# Usage:
#   ./play.sh -p 2                 two players, Red
#   ./play.sh -p 2 -g yellow
#   ./play.sh -p 2 -G              also ghost-link them
#   ./play.sh -p 2 -T              don't tile the windows
#   ./play.sh -e ./gen1recomp.AppImage   point at the game explicitly
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYERS=2
GAME="red"
GAMEEXE="${GEN1RECOMP:-}"
TILE=1
GHOSTS=0
GHOST_PORT=7778

while getopts "p:g:e:TGh" opt; do
  case "$opt" in
    p) PLAYERS="$OPTARG" ;;
    g) GAME="$OPTARG" ;;
    e) GAMEEXE="$OPTARG" ;;
    T) TILE=0 ;;
    G) GHOSTS=1 ;;
    h) sed -n '2,21p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

# ------------------------------------------------------------------ the game
if [ -z "$GAMEEXE" ]; then
  for c in \
    "$HERE"/gen1recomp*.AppImage \
    "$HERE"/../gen1recomp*.AppImage \
    "$HERE"/gen1recomp/gen1recomp \
    "$HERE"/../gen1recomp/gen1recomp \
    "$HOME"/Applications/gen1recomp*.AppImage \
    "$(command -v gen1recomp 2>/dev/null || true)"
  do
    if [ -n "${c:-}" ] && [ -x "$c" ]; then GAMEEXE="$c"; break; fi
  done
fi

if [ -z "$GAMEEXE" ] || [ ! -x "$GAMEEXE" ]; then
  cat >&2 <<EOF
Could not find the game.

Download the Linux build from the project's releases, make it executable, and
either put it beside this script or point at it:

  chmod +x gen1recomp-*.AppImage
  ./play.sh -p $PLAYERS -e ./gen1recomp-*.AppImage

On a Raspberry Pi take the arm64 build. If the AppImage will not run (no FUSE),
extract it once and use the binary inside:

  ./gen1recomp-*.AppImage --appimage-extract
  ./play.sh -p $PLAYERS -e ./squashfs-root/AppRun
EOF
  exit 1
fi

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
savedir() {
  local id="$1"
  if [ -d "$DATA/$id" ]; then echo "$DATA/$id"
  elif [ -d "$DATA/love/$id" ]; then echo "$DATA/love/$id"
  else echo "$DATA/$id"; fi
}

echo "game    : $GAMEEXE"
echo "players : $PLAYERS ($GAME)"

# ------------------------------------------------------------------- checks
#
# Warnings, not errors: the game still runs, it just will not do what you
# asked. Saying so up front beats debugging a pad that drives both windows.
missing_mods=""
missing_cache=""
for i in $(seq 1 "$PLAYERS"); do
  d="$(savedir "gen1recomp-p$i")"
  [ -d "$d/mods/PAD_OWNER" ] || missing_mods="$missing_mods $i"
  [ -f "$d/$GAME/rom-cache.complete" ] || missing_cache="$missing_cache $i"
done
if [ -n "$missing_mods" ]; then
  echo "WARNING: PAD_OWNER is not installed for player(s)$missing_mods --" >&2
  echo "         every pad will drive every window. Run ./install.sh -p $PLAYERS" >&2
fi
if [ -n "$missing_cache" ]; then
  echo "WARNING: no $GAME ROM cache for player(s)$missing_cache -- they will open" >&2
  echo "         the launcher and ask for a ROM instead of booting straight in." >&2
fi
echo ""

# SDL drops joystick events for an UNFOCUSED window unless this is set, which
# in split screen means only whoever clicked last can move.
#
# Set in the ENVIRONMENT rather than from the mod. SDL reads its hints from the
# environment during SDL_Init, so this is in force before the joystick
# subsystem exists. No Lua can get close to that: by the time main.lua's own
# chunk runs -- which is where this used to live -- the joystick module is
# loaded, the pads are enumerated and the window is already open.
export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1

# Ghost bodies, so players can tell each other apart on screen.
SPRITES=(SPRITE_RED SPRITE_BLUE SPRITE_COOLTRAINER_M SPRITE_COOLTRAINER_F)

PIDS=()
for i in $(seq 1 "$PLAYERS"); do
  export POKEPORT_IDENTITY="gen1recomp-p$i"
  export POKEPORT_PAD="$i"
  export POKEPORT_KEYBOARD=1
  # Boot straight into the game rather than the launcher. Not just
  # convenience: mods do not load until a game boots, so the launcher is the
  # one screen PAD_OWNER cannot filter.
  export POKEPORT_GAME="$GAME"

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

  "$GAMEEXE" &
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

# An AppImage is a WRAPPER: the pid we launched is the runtime, and the
# process that actually owns the window is a child of it. Matching wmctrl's
# pid column against only the launched pid would therefore find nothing and
# silently skip tiling on exactly the launch method the docs recommend. Walk
# the descendants too.
pid_tree() {
  local pid="$1"
  echo "$pid"
  local kid
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do
    pid_tree "$kid"
  done
}

window_for() {
  local pid p
  for p in $(pid_tree "$1"); do
    local w
    w="$(wmctrl -lp | awk -v q="$p" '$3 == q { print $1; exit }')"
    if [ -n "$w" ]; then echo "$w"; return; fi
  done
}

idx=0
for pid in "${PIDS[@]}"; do
  win="$(window_for "$pid")"
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
