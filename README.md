# Couch multiplayer for gen1recomp

Play Pokémon Red side by side — two to four people, one machine, one screen —
on top of [gen1recomp](https://github.com/bryanthaboi/gen1recomp), the LÖVE2D
reimplementation of Gen 1.

Three separate pieces, usable independently:

| | what it is |
| --- | --- |
| **[splitscreen/](splitscreen/)** | Runs 2–4 copies side by side, each with its own controller, saves and tiled window |
| **[GHOST_LINK/](GHOST_LINK/)** | A mod: see the other players walking around *your* world, with their Pokémon hovering behind them |
| **[PAD_HOTKEYS/](PAD_HOTKEYS/)** | A mod: reach the display hotkeys from a controller instead of the keyboard |

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

— so two pads press two games' buttons at once. `splitscreen/` adds the
missing filter and gives each copy its own save identity.

That gets you two independent games. **GHOST_LINK** then makes them aware of
each other, without sharing anything that could break either save.

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

Everything needs a legally-dumped ROM, which you supply — see each folder's
README:

- **[splitscreen/README.md](splitscreen/README.md)** — Windows setup
- **[splitscreen/linux/README.md](splitscreen/linux/README.md)** — Raspberry Pi / Linux
- **[splitscreen/OTHER-PLATFORMS.md](splitscreen/OTHER-PLATFORMS.md)** — macOS, Batocera, and playing across machines over LAN
- **[GHOST_LINK/README.md](GHOST_LINK/README.md)** — the presence mod
- **[PAD_HOTKEYS/README.md](PAD_HOTKEYS/README.md)** — controller hotkeys

Short version, on Windows:

```bash
cd splitscreen; .\build.ps1
```

```bash
.\play.ps1 -Players 2 -Ghosts
```

---

## What is deliberately not here

**No ROM, and nothing derived from one.** No game data, no sprites, no audio.
The mods ship code that *derives* from your own dump at runtime; the dump never
enters this repository. `.gitignore` enforces it.

**No engine build.** `splitscreen/build.ps1` patches the official release you
downloaded yourself.

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
