# Mac, Linux, Raspberry Pi and Batocera

Upstream already ships builds for all of these:

| platform | asset |
| --- | --- |
| macOS | `gen1recomp-<ver>-macos.zip` |
| Linux x86_64 | `gen1recomp-<ver>-linux.zip` |
| **Linux ARM64 (Pi 4/5)** | `gen1recomp-<ver>-linux-arm64.AppImage` |
| raw | `gen1recomp-<ver>.love` |

The engine treats `OS X` and `Linux` as first-class desktop
(`src/core/Platform.lua`), and `HostShell` even has AppImage-specific handling,
so the AppImage path is one the project already thought about.

## What ports, and what doesn't

**Everything that matters ports cleanly**, because everything that matters is
now an ordinary mod — three folders of pure Lua, copied into `mods/`:

- `PAD_OWNER` — the controller filter
- `GHOST_LINK`, `PAD_HOTKEYS`
- ROM-derived follower generation — LÖVE does the image work, no Python, no
  native deps

There is no build step and no patched executable to port, which used to be the
hard part of this page. You run the platform's official release.

**Does not port — the convenience scripts:**
- `install.ps1` / `play.ps1` use `%APPDATA%` and `user32.dll` for tiling.
  `linux/install.sh` and `linux/play.sh` are the bash equivalents; on macOS,
  copy the folders by hand and export the same variables.

**Save directory differs**, which every manual step depends on. The official
builds are **fused** (the game archive is appended to the executable), and LÖVE
drops the `LOVE/` segment for fused games — so it is *not* the path you may
remember from running `love .` on a source checkout:

| platform | fused (official build) | plain `love .` |
| --- | --- | --- |
| Windows | `%APPDATA%\<identity>` | `%APPDATA%\LOVE\<identity>` |
| macOS | `~/Library/Application Support/<identity>` | `…/LOVE/<identity>` |
| Linux | `~/.local/share/<identity>` | `~/.local/share/love/<identity>` |
| Batocera | `/userdata/system/.local/share/<identity>` | `…/love/<identity>` |

The Windows fused path was measured against the real executable rather than
taken from the docs; the rule is LÖVE's own and the same on every desktop
platform. `<identity>` is `pokemon-love2d` unless `POKEPORT_IDENTITY` overrides
it, which the split-screen launcher does (`gen1recomp-pN`).

## macOS, concretely

```bash
IDENT=~/Library/Application\ Support/pokemon-love2d
mkdir -p "$IDENT/mods"
cp -r PAD_OWNER PAD_HOTKEYS GHOST_LINK "$IDENT/mods/"
```

For two players side by side, run the app twice with per-process environment:

```bash
POKEPORT_IDENTITY=gen1recomp-p1 POKEPORT_PAD=1 POKEPORT_GAME=red \
  /Applications/gen1recomp.app/Contents/MacOS/love &
POKEPORT_IDENTITY=gen1recomp-p2 POKEPORT_PAD=2 POKEPORT_GAME=red \
  /Applications/gen1recomp.app/Contents/MacOS/love &
```

Copy the mods into `gen1recomp-p1` and `gen1recomp-p2` rather than
`pokemon-love2d` in that case. macOS has no `wmctrl`, so drag the windows into
place once — it remembers.

---

## The better idea: don't split-screen across machines

`GHOST_LINK` already does LAN — that is exactly what the multi-peer transport
was built for. Run one copy per machine and ghost-link them:

- Windows box hosts: `POKEGHOST_HOST=1`
- Mac or Pi joins: `POKEGHOST_JOIN=<windows-lan-ip>:7778`

Each person gets a **full screen** instead of half of one, each machine runs
one game instead of two, and a Pi only has to drive a single instance. Strictly
better than sharing a monitor, and it sidesteps pad routing entirely — with one
game per machine there is nothing to route, so you can skip `PAD_OWNER`
altogether (or leave it installed; without `POKEPORT_PAD` it does nothing).

---

## Batocera specifically

Batocera is an immutable EmulationStation distro. Two things matter.

### 1. Launching — use the Ports system

Native (non-emulator) games go in `/userdata/roms/ports/` as a launcher script.

```sh
#!/bin/bash
# /userdata/roms/ports/gen1recomp.sh
export POKEPORT_IDENTITY=gen1recomp-p1
export POKEGHOST_JOIN=192.168.1.20:7778       # the host's LAN address
/userdata/roms/ports/gen1recomp/gen1recomp.AppImage --appimage-extract-and-run --game=red
```

`--appimage-extract-and-run` matters: Batocera's FUSE support is inconsistent,
and without it an AppImage can fail to mount. Extraction is slower to start but
reliable.

### 2. The ROM import is the real blocker

On Linux the importer opens a **zenity or kdialog** file picker
(`RomImporter:choose`). Batocera ships neither, and the root filesystem is
read-only so you cannot install them.

There *is* an `imports/` inbox that scans the save directory for a dropped
ROM — but it is gated behind `self.isNX`, so on Linux it never runs:

```lua
function RomImporter:_romAction(version)
  if self.isNX then
    ...
    else self:rescanAction(version) end     -- the inbox path
  elseif self.ready[version] then self:reimport(version)
  else self:choose(version) end             -- the picker path, on Linux
end
```

**Workaround: import elsewhere, copy the cache.** The extracted cache is just
files. Do the import on Windows or Mac once, then copy to the Pi:

```
<save>/<version>/data/generated/
<save>/<version>/assets/generated/
<save>/<version>/rom-cache.complete
```

That is exactly what `install.ps1` already does between players on one machine
— same operation, different machine. The game boots straight in with no picker
involved.

Copy `mods/` across the same way, and the generated followers in
`ghostlink/followers/` too if you do not want the Pi spending its first boot
regenerating them (it will do it fine, just slower on ARM).

### 3. Performance expectations

The base 2D game is a Game Boy title and will be comfortable on a Pi 4/5.

The **voxel mod will not be**. `WATER: FULL` ray-marches the depth buffer per
water pixel and `AA` renders the whole diorama at 2–4× before folding it back
down — its own README calls AA "the most expensive row in the mod". On a Pi,
start with `VOXEL: OFF` and add rungs only if the frame rate holds.

Running 2 instances on one Pi is plausible; 4 is unlikely, which is another
reason the one-machine-per-player LAN setup above is the better shape.

---

## Not verified

None of this has been run on a Mac, a Pi, or Batocera — there is no such
hardware here. The release assets and the code paths quoted above are real and
were checked; the setup steps are reasoned from them, not tested.
