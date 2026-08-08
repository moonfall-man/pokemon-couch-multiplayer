# Couch multiplayer for gen1recomp

Play Pokémon Red side by side — two to four people, one machine, one screen —
on top of [gen1recomp](https://github.com/bryanthaboi/gen1recomp), the LÖVE2D
reimplementation of Gen 1.

**It's just mods.** Nothing is patched, unpacked or rebuilt — you drop three
folders into `mods/` and run the official release, exactly the way you'd
install the voxel mod.

| mod | what it does |
| --- | --- |
| **[PAD_OWNER/](PAD_OWNER/)** | One controller per window — the piece that makes split screen possible at all |
| **[GHOST_LINK/](GHOST_LINK/)** | See the other players walking around *your* world, with their Pokémon hovering behind them |
| **[PAD_HOTKEYS/](PAD_HOTKEYS/)** | Reach the display hotkeys from a controller instead of the keyboard |

Plus **[splitscreen/](splitscreen/)** — launcher scripts that install the mods
and start 2–4 copies with the right environment, tiled.

---

## The problem, and the shape of the fix

Launching the game twice doesn't work: SDL hands **every** controller's events
to **every** listening process, and the engine discards the device —

```lua
-- src/core/Input.lua, upstream
function Input:gamepadpressed(joystick, button)
  local btn = self.padBindings[button]
  if btn then press(self, btn, "pad:" .. button) end   -- `joystick` unused
end
```

— so two pads press two games' buttons at once. **PAD_OWNER** adds the missing
filter, and the launcher gives each copy its own save identity.

That gets you two independent games. **GHOST_LINK** then makes them aware of
each other, without sharing anything that could break either save.

### This started as a patch, and didn't need to be

`main.lua` defines `love.gamepadpressed` at chunk level; mods load later, from
inside `love.load`. Reading that ordering, a mod looks hopelessly too late —
so the project shipped a build step that spliced guards into `main.lua` and
kept its anchors matching upstream forever.

The flaw is that *"too late to define the callback"* and *"too late to **replace**
it"* are different claims, and only the first is true. LÖVE never captures
these functions at boot; `love.handlers` looks up `love.<name>` at the moment
each event is dispatched. Checked in the real game rather than argued from
source:

```
gamepadpressed defined at driver time: function
handlers dispatch reached wrapper: true
```

The whole build step was working around a restriction that was never there.
It's gone.

## Ghosts, not co-op

Everyone runs a **complete, independent game** — own save, own party, own
progress. The only thing on the wire is where each player is standing. A player
on your map appears as a walking figure; you can't talk to them, battle them,
or block them. You walk straight through each other.

That ceiling is deliberate. Gen 1's overworld has one script runner, one warp
table, one encounter roll and one save; two players genuinely sharing those is
a redesign of the game, not a mod. Presence is the part that's honestly
additive.

The trick is the engine's own: Yellow's companion Pikachu lives in `ow.npcs`
with `passable = true`, so `Collision.occupied` skips it and the player walks
straight through. Ghosts are built the same way.

## Followers work with no art

Gen 1 has **no walking overworld sprites for Pokémon** — the ROM has 73
character sheets and, in Yellow only, `SPRITE_PIKACHU`.

So followers **hover** instead of walking, which needs one 16×16 frame and no
facings rather than six frames and four directions. That single change is what
makes all 151 possible: the art is generated on first boot by shrinking the
front battle sprites the game already extracted **from your own cartridge
dump**, coloured with the game's own per-species palettes.

Nothing is downloaded and nothing is redistributed. The generated frames land
in your save directory, not in this repo.

---

## Getting started

You supply a legally-dumped ROM and the official
[gen1recomp release](https://github.com/bryanthaboi/gen1recomp/releases). Unzip
it into `gen1recomp/` beside this README, then:

```bash
cd splitscreen; .\install.ps1 -Players 2
```

```bash
.\play.ps1 -Players 2 -Ghosts
```

`install.ps1` copies the three mods into each player's folder and seeds
player 1's ROM cache to everyone else. First run only: launch with
`-Players 1`, import your ROM, quit, and re-run `install.ps1`.

Longer versions, per platform:

- **[splitscreen/README.md](splitscreen/README.md)** — Windows setup
- **[splitscreen/linux/README.md](splitscreen/linux/README.md)** — Raspberry Pi / Linux
- **[splitscreen/OTHER-PLATFORMS.md](splitscreen/OTHER-PLATFORMS.md)** — macOS, Batocera, and playing across machines over LAN
- **[PAD_OWNER/README.md](PAD_OWNER/README.md)** — the controller filter
- **[GHOST_LINK/README.md](GHOST_LINK/README.md)** — the presence mod
- **[PAD_HOTKEYS/README.md](PAD_HOTKEYS/README.md)** — controller hotkeys

### Double-click launchers

If you'd rather not type anything, drop these in the repo root. They're
gitignored — one line each, and they only wrap the scripts below:

```bat
@echo off
REM play_2.bat -- two players, split screen, ghosts on
cd /d "%~dp0splitscreen"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\play.ps1" -Players 2 -Ghosts
if errorlevel 1 pause
```

Make one per player count (`play_1.bat` … `play_4.bat`, changing `-Players`),
and an `install.bat` that runs `install.ps1` the same way. Keep the `pause` —
without it a failure closes the window before you can read why.

### Installing from inside the game

The engine has its own mod manager, and it is the least painful route on a
fresh machine — no scripts, no folders, and it updates itself afterwards.

**MODS → Find mods → add an index**, and paste:

```
moonfall-man/pokemon-couch-multiplayer
```

All three mods appear; install the ones you want. The game ships with **no**
index sources on purpose — adding one is a deliberate act of trusting whoever
publishes it — so this is a one-time paste rather than something that is just
there.

Prefer not to trust a feed? **MODS → Import mod .zip**, or drag a
[release](https://github.com/moonfall-man/pokemon-couch-multiplayer/releases)
`.zip` onto the window. Same installer either way; a listing buys a mod no
trust it wouldn't otherwise have.

**One catch for split screen:** mods install into *the current save folder*,
and each player has their own. The launcher's Play button uses
`pokemon-love2d`, so a GUI install never reaches the per-player profiles by
itself.

Install whatever you like through the game, then mirror it out:

```bash
cd splitscreen; .\install.ps1 -Players 2 -Mirror
```

That copies every mod from `pokemon-love2d` to each player. It **merges and
never prunes** — a player profile keeps mods the source doesn't have — and a
plain `install.ps1` run tells you when there's something worth mirroring.

Two mods can be individually fine and still refuse to share a game: the
original voxel mod and its battle-art fork both claim the `voxel` render
pipeline, so whichever loads second fails outright. Nothing in a manifest
declares that, so there's an escape hatch:

```bash
.\install.ps1 -Players 2 -Mirror -Except DRAMATIC_SHAPE
```

### Installing by hand

The scripts are convenience, not magic. All they do is copy folders:

```
%APPDATA%\<identity>\mods\PAD_OWNER\
%APPDATA%\<identity>\mods\PAD_HOTKEYS\
%APPDATA%\<identity>\mods\GHOST_LINK\
```

`<identity>` is `pokemon-love2d` for an ordinary install, or `gen1recomp-pN`
per player under the launcher. On Linux and macOS the same folders live under
`~/.local/share/` and `~/Library/Application Support/`.

`PAD_OWNER` is completely inert unless `POKEPORT_PAD` is set, so installing it
on a normal single-player copy changes nothing.

---

## What is deliberately not here

**No ROM, and nothing derived from one.** No game data, no sprites, no audio.
The mods ship code that *derives* from your own dump at runtime; the dump never
enters this repository. `.gitignore` enforces it.

**No engine build, and no engine patch.** Everything here is a mod loaded by
the official release you downloaded yourself. Nothing rewrites the game.

**No third-party mods or sprite packs.**

## Credits

- [gen1recomp](https://github.com/bryanthaboi/gen1recomp) — the engine these
  mods extend, and the source of every code excerpt quoted in these docs
- [pret/pokered](https://github.com/pret/pokered) — the disassembly the engine's
  data derives from
- The `passable` follower pattern is the engine's own, from its port of
  Yellow's `pikachu_follow.asm`

Built with [Claude Code](https://claude.com/claude-code).

## Licence

MIT — see [LICENSE](LICENSE). Same as the engine it extends.

This covers the code in this repository only. It grants you nothing regarding
Pokémon, which is Nintendo/Creatures/GAME FREAK's, and is not affiliated with
or endorsed by them.
