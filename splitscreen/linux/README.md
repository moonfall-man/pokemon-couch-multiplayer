# Split screen on a Raspberry Pi (or any Linux box)

For a projector setup. Two players, two controllers, one screen.

> **Use Raspberry Pi OS 64-bit, not Batocera.** Batocera launches one
> fullscreen emulator at a time — no window manager to tile with, a read-only
> root, and its missing `zenity` blocks the ROM import outright. See
> [../OTHER-PLATFORMS.md](../OTHER-PLATFORMS.md) for the details.

Nothing here builds or patches the game. You run the official Linux release and
drop three mod folders next to your saves.

## 1. Get the game

Download the Linux build from the project's
[releases](https://github.com/bryanthaboi/gen1recomp/releases) — the **arm64**
one on a Pi — and make it executable:

```bash
chmod +x gen1recomp-*.AppImage
```

Put it beside these scripts, or pass `-e <path>` to `play.sh`.

If the AppImage won't run for lack of FUSE, extract it once and point at the
binary inside:

```bash
./gen1recomp-*.AppImage --appimage-extract
./play.sh -p 2 -e ./squashfs-root/AppRun
```

## 2. Window-manager helpers

```bash
sudo apt install wmctrl xdotool
```

`wmctrl` does the tiling, `xdotool` reads the screen size. Both optional —
without them the windows just launch untiled and you drag them once.

## 3. Copy over what you need

From the Windows machine (or a `git clone` of this repo), bring the three mod
folders: `PAD_OWNER/`, `PAD_HOTKEYS/`, `GHOST_LINK/`. `install.sh` expects them
two directories up, which is where they sit in a checkout.

## 4. Install and import

```bash
chmod +x install.sh play.sh
./install.sh -p 1
./play.sh -p 1
```

Import the ROM normally — Pi OS has `zenity`, so the picker works. Then quit
and set up everyone else:

```bash
./install.sh -p 2
```

That copies the mods to each player and seeds player 1's extracted cache to the
rest, so only one person does the import.

To skip the import entirely, copy the already-extracted cache from the Windows
machine into `~/.local/share/gen1recomp-p1/`:

```
red/data/generated/
red/assets/generated/
red/rom-cache.complete
```

## 5. Play

```bash
./play.sh -p 2 -G
```

Plug both controllers in **first**. Player 1 gets the pad SDL enumerates first.

| flag | meaning |
| --- | --- |
| `-p N` | players (1–4) |
| `-g red\|blue\|yellow` | which game |
| `-G` | also ghost-link them |
| `-T` | don't tile |
| `-e PATH` | use a specific game binary / AppImage |

Ctrl-C in the terminal closes every instance.

## Where things live

```
~/.local/share/gen1recomp-p1/          saves, options, mods, ROM cache
~/.local/share/gen1recomp-p1/mods/     drop mod folders here
```

LÖVE drops the `love/` segment for **fused** builds, and the official release is
fused — so it's `~/.local/share/<identity>`, not `~/.local/share/love/<identity>`.
Both scripts prefer whichever already has data in it, so a plain `love .` setup
from an earlier version keeps working.

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

Both scripts pass `bash -n` and their error paths were exercised.

**They have not been run on Linux** — there's no Linux machine here. What they
depend on is verified on Windows against the real engine and is
platform-independent Lua: the `PAD_OWNER` mod loading and wrapping every
joystick callback (28/28 in-game assertions), per-instance `POKEPORT_IDENTITY`,
`POKEPORT_PAD` routing, and the SDL background-events hint.

Two Linux-specific things are best-effort and worth knowing about:

- **Save-directory detection.** The fused-vs-plain rule is LÖVE's own and
  identical on every desktop platform, and the fused path was measured on
  Windows — but `savedir()` still prefers a folder that already exists rather
  than trusting the rule blindly.
- **Tiling an AppImage.** An AppImage is a wrapper, so the process that owns
  the window is a *child* of the pid we launched. `play.sh` walks the process
  tree to find it rather than matching the launched pid alone, which would have
  silently skipped tiling on exactly the launch method recommended above.
