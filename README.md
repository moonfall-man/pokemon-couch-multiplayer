# Couch multiplayer for gen1recomp

Play Pokémon Red side by side — two to four people, one machine, one screen —
on top of [gen1recomp](https://github.com/bryanthaboi/gen1recomp), the LÖVE2D
reimplementation of Gen 1.

**One mod. Import it, set `PLAYERS`, press Play.**

```
MODS -> Import mod .zip -> COUCH_MULTIPLAYER-0.2.0.zip
MODS -> COUCH MULTIPLAYER -> OPTIONS.. -> PLAYERS: 2
```

Quit, press Play, and the second window starts itself — its own save, its own
controller, its own half of the screen, and you can see each other walking
around. No scripts, no installer, no folders to copy.

**`PLAYERS: 1` is the default and does nothing at all** — no extra window, no
controller filtering, no socket. Installing this and playing alone is
indistinguishable from not having it.

→ **[COUCH_MULTIPLAYER/](COUCH_MULTIPLAYER/)** — the mod, and how it works

---

## What it does

**Split screen, 2–4 players.** Separate saves, parties and progress. Not one
window in quadrants — real independent games side by side, each answering to
exactly one controller.

**You can see each other.** A player on your map appears as a walking figure
with their lead Pokémon hovering behind them. Presence only: you can't talk to,
battle, trade with, block or be blocked by another player.

That ceiling is deliberate. Gen 1's overworld has one script runner, one warp
table, one encounter roll and one save; two players genuinely sharing those is
a redesign of the game, not a mod. Presence is the part that's honestly
additive.

**Pokémon followers for all 151.** Gen 1 has *no walking overworld sprites for
Pokémon* — the ROM has 73 character sheets and, in Yellow only,
`SPRITE_PIKACHU`. So followers **hover** instead of walking, which needs one
16×16 frame and no facings rather than six frames and four directions. That
single change is what makes all 151 possible: the art is generated on first
boot by shrinking the front battle sprites the game already extracted **from
your own cartridge dump**, coloured with the game's own per-species palettes.

**Display hotkeys on the pad.** The engine's digit toggles — and every mod
pipeline that claims one, including the voxel mod's ladders — are keyboard
only, which is useless on a couch. Bound to the buttons the engine leaves
free: both stick clicks, X and Y.

---

## The problem underneath

Launching the game twice doesn't work by itself. SDL hands **every**
controller's events to **every** listening process, and the engine discards the
device —

```lua
-- src/core/Input.lua, upstream
function Input:gamepadpressed(joystick, button)
  local btn = self.padBindings[button]
  if btn then press(self, btn, "pad:" .. button) end   -- `joystick` unused
end
```

— so two pads press two games' buttons at once. The mod adds the missing
filter, on **both** paths the engine uses: the `love.*` callbacks, and
`Input:reconcile`, which polls every joystick directly and bypasses callbacks
entirely.

And it starts the other windows itself, which is possible because the fused
build can find its own executable (`love.filesystem.getSource()`), shell out
with per-child environment (`HostShell.popen`), and let every window tile
*itself* (`love.window.setPosition`). See
[COUCH_MULTIPLAYER/README.md](COUCH_MULTIPLAYER/README.md) for the rules it
follows when doing that.

---

## Two people, two machines

Leave `PLAYERS` at 1 and use the `GHOSTS` row instead — `HOST` on one machine,
`JOIN` plus the host's address on the other. Each person gets a full screen,
and there's nothing to route.

---

## Also here

- **[tools/](tools/)** — packaging: builds the release `.zip` and the
  "Find mods" index feed.

There used to be a `splitscreen/` folder of PowerShell and bash launchers, plus
an installer that copied mod folders between save profiles. The mod does all of
it from inside the game, so they're gone — they're in the history at `af53721`
if anyone ever wants them.

## What is deliberately not here

**No ROM, and nothing derived from one.** No game data, no sprites, no audio.
The mod ships code that *derives* from your own dump at runtime; the dump never
enters this repository. `.gitignore` enforces it.

**No engine build, and no engine patch.** Everything is a mod loaded by the
official release you downloaded yourself.

**No third-party mods or sprite packs.**

## Credits

- [gen1recomp](https://github.com/bryanthaboi/gen1recomp) — the engine this
  extends, and the source of every code excerpt quoted in these docs
- [pret/pokered](https://github.com/pret/pokered) — the disassembly the
  engine's data derives from
- The `passable` follower pattern is the engine's own, from its port of
  Yellow's `pikachu_follow.asm`

Built with [Claude Code](https://claude.com/claude-code).

## Licence

MIT — see [LICENSE](LICENSE). Same as the engine it extends.

This covers the code in this repository only. It grants you nothing regarding
Pokémon, which is Nintendo/Creatures/GAME FREAK's, and is not affiliated with
or endorsed by them.
