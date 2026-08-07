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

**Ports cleanly — all pure Lua:**
- `GHOST_LINK`, `PAD_HOTKEYS` — copy the folders, done
- ROM-derived follower generation — LÖVE does the image work, no Python, no
  native deps
- The `PadOwner` patch itself

**Does not port — Windows-only:**
- `build.ps1`, `play.ps1`, `setup-love.ps1`, `seed-players.ps1`. They use
  `%APPDATA%` and `user32.dll` for window tiling. The *patch* is portable; the
  automation around it is not.

**Save directory differs**, which every manual step depends on:

| platform | path |
| --- | --- |
| Windows | `%APPDATA%\LOVE\<identity>` |
| macOS | `~/Library/Application Support/LOVE/<identity>` |
| Linux | `~/.local/share/love/<identity>` |
| Batocera | `/userdata/system/.local/share/love/<identity>` |

---

## The better idea: don't split-screen across machines

`GHOST_LINK` already does LAN — that is exactly what the multi-peer transport
was built for. Run one copy per machine and ghost-link them:

- Windows box hosts: `POKEGHOST_HOST=1`
- Mac or Pi joins: `POKEGHOST_JOIN=<windows-lan-ip>:7778`

Each person gets a **full screen** instead of half of one, each machine runs
one game instead of two, and a Pi only has to drive a single instance. Strictly
better than sharing a monitor, and it sidesteps the pad-routing patch entirely
— with one game per machine there is nothing to route.

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

That is exactly what `seed-players.ps1` already does between players on one
machine — same operation, different machine. The game boots straight in with
no picker involved.

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
