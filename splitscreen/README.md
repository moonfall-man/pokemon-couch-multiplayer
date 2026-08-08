# Side-by-side multiplayer for gen1recomp

Run up to 4 independent copies of the game at once, tiled on one screen, each
with its own controller and its own saves. Two people, two pads, two windows,
one couch.

This is **not** one window split into quadrants — it's N real game windows side
by side. See [Why not one window](#why-not-one-window) for what that would take.

Nothing here patches or rebuilds the game. These are launcher scripts around
the official release, plus three ordinary mods.

---

## The problem this solves

Launching the game twice doesn't work. SDL delivers every controller's events
to every listening process, and the engine throws the device away:

```lua
-- src/core/Input.lua, stock
function Input:gamepadpressed(joystick, button)
  local btn = self.padBindings[button]
  if btn then press(self, btn, "pad:" .. button) end   -- `joystick` unused
end
```

So both pads press both games' buttons at once. The
[**PAD_OWNER**](../PAD_OWNER) mod adds the missing filter — it wraps every
joystick callback and drops events from pads this window doesn't own.

It wraps the callbacks in **`main.lua`**, not `Input.lua`, on purpose:
`Game:gamepadpressed` cycles GAME SPEED and routes menu input *before* it
delegates to `Input`, so a filter inside `Input` would still let player 2's pad
drive player 1's menus.

---

## Setup

### 1. Get the official build

Download `gen1recomp-<version>-windows.zip` from the project's
[releases](https://github.com/bryanthaboi/gen1recomp/releases) and unzip it to:

```
<this repo>\gen1recomp\
```

That's where `play.ps1` looks first. Anywhere else works too — pass
`-GameExe <path to gen1recomp.exe>`.

### 2. First run: import your ROM once

```bash
cd splitscreen; .\install.ps1 -Players 1
```

```bash
.\play.ps1 -Players 1
```

Import your ROM as usual, then quit. Install any other mods now too, by
dropping them into `%APPDATA%\gen1recomp-p1\mods\` (your voxel mod folder goes
there whole).

### 3. Set up the other players

```bash
.\install.ps1 -Players 2
```

Copies the three mods to every player, then copies player 1's ROM-derived cache
to the rest — cache and mods only, never a save file and never `options.lua`,
so nobody inherits anyone else's playthrough or settings.

Safe to re-run any time you pull an update to these mods.

### 4. Play

```bash
.\play.ps1 -Players 2 -Ghosts
```

Plug in every controller **before** launching. Pad *N* is the *N*th pad in
SDL's order, normally the order they were connected.

---

## Where things live

The official build is **fused** — the game archive is appended to the
executable — and LÖVE drops the `LOVE\` segment from the save path for fused
games. So:

```
%APPDATA%\gen1recomp-p1\           <- saves, options, mods, ROM cache
%APPDATA%\gen1recomp-p1\mods\      <- drop mod folders here
```

If you used an earlier version of this project, your data is at
`%APPDATA%\LOVE\gen1recomp-p1\` instead — that setup ran the game through a
standalone `love.exe`, which is not fused. `install.ps1` copies it across on
first run and **leaves the original in place**, so nothing is at risk if that
guess is wrong for your setup.

## How each player is isolated

| | mechanism |
| --- | --- |
| Saves, settings, mods | `POKEPORT_IDENTITY=gen1recomp-pN` → own folder under `%APPDATA%\` |
| Controller | `POKEPORT_PAD=N` → PAD_OWNER drops every other pad's events |
| Keyboard | focused window only; `-KeyboardPlayerOne` makes P2+ pad-only |
| Window | tiled 1×2 for two players, 2×2 for three or four |

Separate identities rather than shared-identity save slots is deliberate:
`SaveData.setActiveSlot` rewrites the **shared `options.lua`**, so four
instances on one identity would race over settings and the slot registry.

---

## Options

```powershell
.\play.ps1 -Players 4 -Game yellow      # red | blue | yellow
.\play.ps1 -Players 2 -NoTile           # don't move windows
.\play.ps1 -Players 2 -KeyboardPlayerOne
.\play.ps1 -Players 2 -GameExe "D:\games\gen1recomp\gen1recomp.exe"
.\install.ps1 -Identity pokemon-love2d  # install into a normal single-player copy
```

`POKEPORT_PAD` accepts `1`–`8`, `all` (default, stock behaviour), or `none`
(keyboard only). An unparseable value falls back to `all` — a typo shouldn't
leave someone unable to press Start.

---

## Known limits

- **The launcher screen isn't filtered.** Mods don't load until a game boots,
  so the version-select screen and the ROM importer see every pad. `play.ps1`
  sets `POKEPORT_GAME` so each window boots straight past both; the one time
  this bites is the very first run, before a ROM has been imported.
- **Two engine paths, not one.** Controller input reaches the game through
  `love`'s callbacks *and* through `Input:reconcile`, which polls every device
  directly on focus gain. Both are filtered; if a future engine version adds a
  third, the symptom to watch for is "clicking a window acts on the other
  player's held buttons."
- **Pad order is by SDL enumeration.** Each process enumerates independently.
  On one machine with a fixed set of pads this is consistent, but if two
  instances ever disagree they could grab the same pad. Binding by "press A on
  your controller" instead would be the robust fix.
- **The link cable still works.** `src/link/` is untouched, so the instances
  can trade and battle each other over the network.
- **Disk cost.** Each identity keeps its own ROM cache.

## What's been verified

Against the **official unmodified `gen1recomp.exe` v0.1.75**, with the voxel
mod installed alongside:

| check | result |
| --- | --- |
| Wrapping a `love.*` callback from a mod reaches real dispatch | `handlers dispatch reached wrapper: true` |
| Fused save directory | `%APPDATA%\<identity>`, measured not assumed |
| `PAD_OWNER` unit suite (modes, ownership, hotplug, wrapping, reconcile) | 81/81 |
| In-game suite (load order, exports, live callbacks, dispatch) | 28/28 |
| Inert with `POKEPORT_PAD` unset | 10/10 — registry never even created |
| Both players boot with the voxel mod present | 0 loader errors, 9/9 callbacks wrapped |
| Engine's own `Input:reconcile` polling | owned pad 10×, foreign pad **0×** |
| `PAD_HOTKEYS` finds `PAD_OWNER` | resolved, not the legacy `src.core` path |
| Two instances launched and tiled by `play.ps1` | 2×1, both booted straight into Red |
| `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS` | enabled in both processes |

The one thing not verified here is two people playing at once, which needs a
second physical controller. The routing underneath it is proven against real
hardware and the filter is proven in the real engine.

---

## Why not one window

True in-window split screen means N independent game states in one process.
The blocker is that the state is a process-wide singleton web: `OverworldState`
is a plain module table rather than a class, and `Input`, `Renderer`, `Data`
and `TouchControls` are module singletons hung off `Game`. There is no
`Game.new()`.

The tractable route is *not* refactoring 189 files. It's loading the whole
`src/` tree N times into N isolated module registries — a custom `require`
with its own `package.loaded` per instance — so each gets private singletons.
Rendering is the easy half: the game already draws into an offscreen 160×144
canvas, so you'd blit N of them into quadrants.

Real work remains around audio (four Pokémon Center themes at once), per-
instance save separation, and the cost of running the voxel mod four times.
Estimate: a weekend for solid 2-player. Everything in this folder is a
prerequisite for it, so none of it is wasted.
