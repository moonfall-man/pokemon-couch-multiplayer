# Side-by-side multiplayer for gen1recomp

Run up to 4 independent copies of the game at once, tiled on one screen, each
with its own controller and its own saves. Two people, two pads, two windows,
one couch.

This is **not** one window split into quadrants — it's N real game windows
side by side. See [Why not one window](#why-not-one-window) for what that
would take.

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

So both pads press both games' buttons at once. `patch/PadOwner.lua` adds the
missing filter, and `build.ps1` wires it into every joystick callback in
`main.lua`.

The guards go in **`main.lua`**, not `Input.lua`, on purpose:
`Game:gamepadpressed` cycles GAME SPEED and routes menu input *before* it
delegates to `Input`, so a filter inside `Input` would still let player 2's
pad drive player 1's menus.

---

## Setup

### 1. LÖVE — already done

`love\love.exe` is in place (LÖVE 11.5, the version the game targets).

It came from the official `gen1recomp-0.1.75-windows.zip`, which ships a
**fused** executable — `love.exe` with the game archive appended — so it runs
its own embedded copy and ignores a `.love` on the command line.
`setup-love.ps1` split the archive back off, leaving the exact LÖVE binary the
game shipped with rather than whatever love2d.org serves today.

To redo it after a version bump:

```bash
cd splitscreen; .\setup-love.ps1 -Zip <gen1recomp-*-windows.zip>
```

### 2. Build the patched game

```bash
cd splitscreen; .\build.ps1
```

Reads the Android APK in the parent folder, injects the patch, and writes
`gen1recomp-splitscreen.love`. Pass `-Source <file.love>` to build from a
different release instead.

Every edit is anchored and verified — if a future version moves things, the
build fails naming the anchor rather than producing a broken package.

### 3. First run: import your ROM once

```bash
cd splitscreen; .\play.ps1 -Players 1
```

Import your ROM as usual, then quit. Install any mods now too, by dropping
them into `%APPDATA%\LOVE\gen1recomp-p1\mods\` (your voxel mod folder goes
there whole).

### 4. Copy that to the other players

```bash
cd splitscreen; .\seed-players.ps1 -Players 2
```

Copies only ROM-derived cache and mods — never saves or settings — so nobody
inherits anyone else's playthrough.

### 5. Play

```bash
cd splitscreen; .\play.ps1 -Players 2
```

Plug in every controller **before** launching. Pad *N* is the *N*th pad in
SDL's order, normally the order they were connected.

---

## How each player is isolated

| | mechanism |
| --- | --- |
| Saves, settings, mods | `POKEPORT_IDENTITY=gen1recomp-pN` → own folder under `%APPDATA%\LOVE\` |
| Controller | `POKEPORT_PAD=N` → only the *N*th pad |
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
.\play.ps1 -Players 2 -LoveExe "C:\Program Files\LOVE\love.exe"
```

`POKEPORT_PAD` accepts `1`–`8`, `all` (default, stock behaviour), or `none`
(keyboard only). An unparseable value falls back to `all` — a typo shouldn't
leave someone unable to press Start.

---

## Known limits

- **Pad order is by SDL enumeration.** Each process enumerates independently.
  On one machine with a fixed set of pads this is consistent, but if two
  instances ever disagree they could grab the same pad. Binding by "press A
  on your controller" instead would be the robust fix.
- **The link cable still works.** `src/link/` is untouched, so the instances
  can trade and battle each other over the network.
- **Disk cost.** Each identity keeps its own ROM cache.

## What's been verified

Tested on this machine against a real Xbox One controller:

| check | result |
| --- | --- |
| Patch applies | 12/12 anchors matched |
| Archive is loadable | forward-slash entries, `main.lua` at root |
| Patched game boots | no `lua-error.log`, assets loaded |
| Two instances at once | both alive, tiled 2×1 |
| `PadOwner` under LuaJIT | loads, `owns(nil)` safe |
| `POKEPORT_PAD=1` | owns the Xbox pad |
| `POKEPORT_PAD=2` | rejects it (correct — only one pad present) |
| `POKEPORT_PAD=all` / `none` | owns / rejects |
| `POKEPORT_PAD=banana` | falls back to `all` |
| `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS` | reads back as `1` |
| `POKEPORT_IDENTITY` | p1/p2/p3 → three distinct save directories |

The one thing not verified is two people playing at once, which needs a second
physical controller and a ROM. The routing logic underneath it is proven
correct against real hardware.

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
