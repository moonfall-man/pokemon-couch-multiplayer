# Split screen on a Raspberry Pi (or any Linux box)

For a projector setup. Two players, two controllers, one screen.

> **Use Raspberry Pi OS 64-bit, not Batocera.** Batocera launches one
> fullscreen emulator at a time — no window manager to tile with, a read-only
> root, and its missing `zenity` blocks the ROM import outright. See
> [../OTHER-PLATFORMS.md](../OTHER-PLATFORMS.md) for the details.

## 1. Get LÖVE

```bash
sudo apt install love wmctrl xdotool unzip
```

`wmctrl` does the tiling, `xdotool` reads the screen size. Both optional —
without them the windows just launch untiled.

The game targets **LÖVE 11.5**. If `apt` gives you an older 11.x and something
misbehaves, use the exact bundled one instead:

```bash
./gen1recomp-0.1.75-linux-arm64.AppImage --appimage-extract
```

then pass `-l ./squashfs-root/bin/love` to `play.sh`.

## 2. Copy over what you need

From the Windows machine, bring:

- `gen1recomp-0.1.75-android.apk` (or the `.love`) — the game to patch
- `splitscreen/patch/PadOwner.lua` — must sit at `../patch/PadOwner.lua`
  relative to these scripts
- optionally `GHOST_LINK/` and `PAD_HOTKEYS/`

## 3. Build

```bash
chmod +x build.sh play.sh
./build.sh
```

Unpacks the game into `./game/` and applies the controller-routing patch —
12 anchored edits, each verified. The output is a **directory**, not a `.love`:
LÖVE runs a directory directly, so no zip tooling is needed and you can edit
the patched files in place.

## 4. The ROM

Run once and import it normally — Pi OS has `zenity`, so the picker works:

```bash
./play.sh -p 1
```

Or skip the import entirely by copying the already-extracted cache from the
Windows machine into `~/.local/share/love/gen1recomp-p1/`:

```
red/data/generated/
red/assets/generated/
red/rom-cache.complete
```

Then seed the other players by copying those same three into
`gen1recomp-p2/`, and drop any mods into `gen1recomp-pN/mods/`.

## 5. Play

```bash
./play.sh -p 2
```

Plug both controllers in **first**. Player 1 gets the pad SDL enumerates first.

| flag | meaning |
| --- | --- |
| `-p N` | players (1–4) |
| `-g red\|blue\|yellow` | which game |
| `-G` | also ghost-link them (needs `GHOST_LINK`) |
| `-T` | don't tile |
| `-l PATH` | use a specific `love` binary |

Ctrl-C in the terminal closes every instance.

## Performance

The base 2D game is a Game Boy title and will be fine on a Pi 4/5.

The **voxel mod will not be**. `WATER: FULL` ray-marches the depth buffer per
water pixel, and `AA` renders the diorama at 2–4× before folding it back down —
its own README calls AA "the most expensive row in the mod". Start with
`VOXEL: OFF` and add rungs only while the frame rate holds. With `PAD_HOTKEYS`
installed that's a click of the left stick.

Two instances on one Pi is plausible. Four is optimistic — if you want four
players, one machine each with `-G` ghost-linking is the better shape.

## What's tested

`build.sh` was run on the real APK here and produces a `main.lua`
**byte-identical** to the Windows build that is verified working in-game, and
rebuilding is deterministic. Both scripts pass `bash -n` and their error paths
were exercised.

`play.sh`'s launching and tiling have **not** been run — there's no Linux
machine here. The parts it depends on (per-instance `POKEPORT_IDENTITY`,
`POKEPORT_PAD` routing, the SDL background-events hint) are all verified on
Windows and are platform-independent Lua.
