# POKEMON FOLLOWERS

Your lead Pokémon hovers behind you in the overworld. **All 151 species**,
built from your own cartridge dump on first boot.

Needs no network, no second window and no second controller. Playing alone is
the normal case.

---

## Why they hover

Gen 1 has **no walking overworld sprites for Pokémon**. The ROM carries 73
character sheets — people, mostly — and, in Yellow only, `SPRITE_PIKACHU`.
Every other species has front and back battle art and nothing else.

Hovering is what makes all 151 possible. A hovering thing needs **one 16×16
frame and no facings**; a walking one needs six frames across four directions.
That single change turns an impossible art problem into a solvable one: shrink
the front battle sprite the game already extracted from your ROM, colour it
with the game's own per-species palette, done.

## It draws but is never there

The engine's own trick, from its port of Yellow's `pikachu_follow.asm`: the
follower goes in `ow.entities` — the list the world **draws**, whose collision
check honours `passable` — and never in `ow.npcs`, which is what answers your
A press, what the trainer-sighting scan walks, and what gets `update` called
every frame.

So it is drawn, and nothing can ever find it. See `lib/PassableNpc.lua`.

## Options

| row | |
|---|---|
| `MY MON` | your lead Pokémon follows you |
| `MON ART` | real per-species art from your ROM, or the shared party-menu icons |

`MON ART` takes effect next launch — registering sprites is a load-time phase.

## For other mods

```lua
local art = mod.find("POKEMON_FOLLOWERS")
if art then
  local spriteId = art.exports.spriteFor(game, "PIKACHU")  -- or nil
end
```

That is how [COUCH_MULTIPLAYER](../COUCH_MULTIPLAYER/) puts a Pokémon behind
*other players* — it asks, and does without if this mod is absent. One
function, deliberately: a narrow export is a narrow promise to keep.

`exports.counts()` returns `{ supplied, rom, icons }` for status displays.

## It used to live somewhere else

This was part of COUCH_MULTIPLAYER. It shouldn't have been — generating 151
sprites from battle art has nothing to do with split screen, and a co-op mod
that also ships an art pipeline is two things wearing one manifest.

They still compose. Install both and every player's Pokémon follows them.

## You supply the ROM

**Nothing here contains game data.** The art derives from your own dump at
runtime and lives in your save folder. Nothing is downloaded and nothing is
redistributed.

First boot builds the frames and takes a moment; later boots reuse the cache.

## Also here

- **[tools/](tools/)** — not shipped in the release zip.

MIT — see [LICENSE](../LICENSE).
