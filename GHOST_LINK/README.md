# GHOST LINK

See the other players walking around your own world.

Everyone runs a **complete, independent game** — own save, own party, own
progress. The only thing crossing the wire is where each player is standing.
A player who happens to be on your map appears as a walking figure with their
lead Pokémon trailing behind. You walk straight through each other.

No talking, no battling, no trading, no collision. Ghosts.

---

## Why it's only presence

Gen 1's overworld has one script runner, one warp table, one encounter roll
and one save. Two players genuinely sharing those is a redesign of the game,
not a mod — who triggers Oak's intro, what happens when one of you warps and
the other doesn't, which of you the wild Pidgey attacks.

Presence is the part that's honestly additive, so presence is all this does.
Nothing here writes to your save, party, flags or scripts. A peer can move a
decorative NPC around your screen and that is the entire blast radius.

## How the ghosts work

Everything follows Yellow's companion Pikachu, which is the one thing in this
engine that already had to be *visible, animated, and not really there*.

**They never block.** `npc.passable = true`. `Collision.occupied` skips
passable entities outright — its own comment says "Yellow's companion Pikachu:
the player walks straight through and it re-trails". That's the engine's
answer to "draws but doesn't block", not something invented here.

**They're built by hand, not registered.** `NPC.new` directly into `ow.npcs` /
`ow.entities` — deliberately *not* `mod.world:spawnNpc`, which appends the
object to `Game.data.maps[mapId].objects`, the **shared map definition**.
Ghosts would pile up in the map data forever and come back as real, solid NPCs
on the next map load.

**They never touch the script machinery.** Positioned in pixels every tick,
never through `ow:scriptMove`. This one caused a real softlock:

```lua
local scripted = self.runner:isRunning() or #self.scriptMoves > 0
```

The engine reads a non-empty `scriptMoves` queue as *"a cutscene is running"*
and suppresses player input. A ghost stepping in time with a remote player
therefore froze the **local** player's controls for as long as the other
person kept walking. Writing `px`/`py` directly is safe because `NPC:update`
returns before touching them for a `STAY` object that isn't moving.

The walk cycle is faked the way the engine fakes Pikachu's idle — an instance
field shadows `NPC.walkPhase`, so `NPC:pose` keeps working unchanged.

## The battle marker

When a player is in a battle, a **Poké Ball spins over their ghost's head**.

The overworld state stays on the stack underneath a battle, so `world:current()`
keeps reporting where they're standing — their ghost simply stops moving and
grows a marker rather than vanishing.

It's a separate wire message rather than a field on the position update,
because a player who starts a battle stops moving: piggybacking it on movement
would mean the marker never appeared until they walked again, which is exactly
when it's no longer true. It's also re-sent on the keepalive, so joining
mid-battle still shows it.

`SPRITE_POKE_BALL` is one frame and the sprite path has no rotation, so the
spin is a tight fast orbit rather than a real rotation.

## Setup

Install into each player's mods folder:

```
%APPDATA%\LOVE\<identity>\mods\GHOST_LINK\
```

It stays **off** unless told otherwise — installing it never opens a socket
on its own.

### Settings are already per player

Options live in `save.options.modOptions`, which is stored in `options.lua` —
and `options.lua` is per LÖVE **identity**. The split-screen launcher already
gives every player their own identity (`POKEPORT_IDENTITY=gen1recomp-pN`), so
each player's rows are genuinely their own with nothing extra to configure.

| row | what it does |
| --- | --- |
| `GHOSTS` | OFF / HOST / JOIN |
| `GHOST ADDR` | who to dial when joining (`127.0.0.1` for same-PC) |
| `GHOST BODY` | how **others** see you — give each player a different one |
| `GHOST MON` | show hovering followers |
| `BTL MARKER` | spin a Poké Ball over a ghost who's in a battle |

Changing a row tears the session down and rebuilds it on the next tick, so
switching HOST/JOIN or a body sprite takes effect without a restart.

**Environment overrides the saved rows**, deliberately: the launcher decides
who hosts, and that must not be overridden by whatever the menu was left on.

### Environment (what the launcher uses)

| variable | meaning |
| --- | --- |
| `POKEGHOST_HOST=1` | host a session |
| `POKEGHOST_JOIN=addr[:port]` | join one (`127.0.0.1` for same-PC play) |
| `POKEGHOST_PORT=7778` | port (default 7778, one above the link cable's 7777) |
| `POKEGHOST_SPRITE=SPRITE_RED` | how **others** see you |
| `POKEGHOST_NAME=Cory` | overrides the save's player name |

With the split-screen launcher this is one flag — player 1 hosts, the rest
join, and each gets a different body sprite automatically:

```bash
.\play.ps1 -Players 2 -Ghosts
```

## Your own Pokémon follows you

`MY MON` puts your lead Pokémon behind **you**, on your own screen. It needs no
network at all — it works with `GHOSTS: OFF`, so the mod is useful solo.

Same body as a ghost's follower: passable, out of the script machinery,
positioned in pixels. Yellow already does this properly for Pikachu, with
happiness and moods and hop commands; this is deliberately *not* that. It
never steps, never blocks, never enters a script and never touches the save,
so it can't disagree with Yellow's own follower, and on Red or Blue it adds
the thing those versions never had without pretending to be part of the game.

A fainted lead doesn't follow you, same as Pikachu.

## Follower Pokémon

**Works out of the box for all 151 species. No art needed.**

Followers don't walk — they **hover**, drifting toward the cell their trainer
just left with a slow bob. That's not a shortcut, it's what makes the feature
possible: Gen 1 has no walking overworld sprites for Pokémon, so a *marching*
follower needs six frames and four facings for every species. A *hovering* one
needs **one 16×16 image and no facings at all**.

Which means the art can come from a place that already exists.

### Real per-species art, from your own cartridge

`MON ART: ON` shrinks the **front battle sprites this game already extracted
from your ROM** into 16×16 followers — all 151, generated on first boot and
cached in the save directory. Nothing is downloaded and nothing is
redistributed: the input is the dump already on your machine.

Four things make it read at that size, and all four were wrong in the first
pass:

**Colour, from the game's own palettes.** This mattered more than everything
else combined. The battle sprites are four DMG shades; their colour lives in
`palettes.pokemon[SPECIES] -> "GREENMON"` and `palettes.palettes.GREENMON ->`
four RGB triples, both extracted from your ROM alongside the art. Baking those
in and registering the sprite with `trueColor = true` — which claims its cell
out of the shade-remap pass — turns a grey smudge into a green one that
everybody recognises. At 16px, colour carries more identity than shape does.

One catch worth knowing: a `trueColor` sprite skips the OBP bake, and the bake
is where near-white would have been keyed to alpha. So the colour output needs
**real transparency** for its background, not white.

**Re-draw the outline; don't recover it.** A 1px black border averaged 3.5×
down becomes a grey suggestion, and thresholding it back gives a broken,
dotted edge. But the exact silhouette is already known — it *is* the coverage
map — so the border is re-drawn at full strength: any covered pixel touching
an uncovered one is outline. A crisp edge carries the shape, which frees the
interior to spend its two tones on form instead of on redescribing where the
creature ends.

**Downsample by coverage, not colour.** The sprites are the four DMG shades
over *real alpha* padding, and opaque white is a genuine sprite colour —
highlights, eyes, pale bellies. Averaging colour bled the transparent padding
into the creature as grey and turned interior white into holes the renderer
keys away. Each output pixel now asks how much of its source footprint is
opaque (the silhouette) and how dark that part is (outline vs body).

**Three shades, not four.** Gen 1 shades with dither — checkerboards, not
greys. Downsampled, a dither averages to a mid-tone, and spreading those back
across four levels turns them into speckle. Collapsing the middle onto one
flat body tone throws the dither away and keeps the outline and silhouette,
which is all that survives at 16px anyway.

Turn it `OFF` to fall back to the icons below.

### Fallback: party-menu icons

Every species also has a **party-menu icon** in the ROM. Icons are archetypes
rather than portraits (the whole Bulbasaur line shows the GRASS icon,
Gyarados shows SNAKE), but every species has one and they cost nothing.

The mapping is resolved from live game data, so it's version-correct: under
Yellow, Pikachu uses its own icon; under Red it falls in with FAIRY. An
archetype whose image isn't in your version is skipped rather than breaking
the boot — under Red that's `PIKACHU`, leaving 10 of 11.

### Optional: per-species art

If archetypes aren't enough, drop 16×96 PNGs into `assets/followers/` named
for the species (`pikachu.png`, `mr-mime.png`) and they take priority. See
[assets/followers/README.md](assets/followers/README.md) for the frame layout
and `tools/import_follower_sprites.py` to convert what you have. Since
followers hover, only the standing frames are shown — pointed the way the
follower is drifting.

### How the hover works

The follower is positioned in **pixels**, not stepped in cells: `px`/`py` are
written directly each tick and eased toward the target, with a sine bob on
`py`. That's safe because `NPC:update` returns before touching `px`/`py` for a
`STAY` object that isn't moving, so nothing in the engine fights the writes.

Registered with `frames = 1, walker = false` deliberately. For a non-walker
the renderer picks the frame from *facing*
(`STAND = { down = 0, up = 1, left = 2, right = 2 }`), not from a clock — so a
two-frame icon declared as two frames would swap pose when the follower
turned, rather than animate. One frame, and all the life comes from motion.

## Design notes

**Star topology.** The engine's own `src/link/Net.lua` is a link *cable* —
exactly two ends, and a second connection to a host is disconnected on
arrival. Ghosts want up to four players, so `lib/Transport.lua` is a sibling
of that module rather than a user of it: one enet host with room for several
peers, and the host relays each message to the others. The link cable itself
is untouched, so trades and link battles still work.

**Target-chasing, not a step queue.** Position updates bunch and drop. Each
ghost holds a target cell and steps toward it whenever idle, so packet loss
degrades to "slightly behind" instead of desyncing, and a big jump (a warp) is
taken as a teleport rather than a long walk through walls.

**Map-scoped lifetime, with an explicit resync.** A ghost exists only while
that player is on your map. Different map means despawned, not hidden — so
there's no bookkeeping for maps you can't see and no way for a stale ghost to
survive somewhere invisible.

The cost of that is a `sync` message. Walking onto a new map despawns
everyone, and a peer who is standing still wouldn't say anything until their
5-second keepalive — so arriving in a town where someone was already waiting
left them invisible for several seconds. Changing map now broadcasts "tell me
where you are", which turns that into one round trip.

**Everything off the wire is untrusted.** `lib/Wire.lua` validates every
field before it reaches the world. That's not paranoia about your spouse:
`NPC.new` *asserts* on an unknown sprite id, so one malformed message would
take the whole game down rather than drop a ghost.

## Verified

Tested against the real engine on Windows, LÖVE 11.5:

| check | result |
| --- | --- |
**88/88** on the harness, plus real-game checks:

| check | result |
| --- | --- |
| Module load, all 6 libs | pass |
| `Wire.validate` — good messages | accepted |
| `Wire.validate` — NaN, bad facing, missing id, wrong version, path-ish species | rejected |
| Species filename mapping incl. `MR_MIME`, `NIDORAN_F` | pass |
| 151-species list matches ROM data | pass |
| Every species has an icon archetype | 151/151 |
| Icon fallback: `BULBASAUR` → `GHOSTICON_GRASS` | pass |
| Version-specific: Yellow `PIKACHU` → own icon, Red → FAIRY | pass |
| Sprite id the engine doesn't know | returns nil, never reaches `NPC.new` |
| Ghost pool slot allocation | pass |
| Real enet session, both ends, localhost | paired, payload intact both ways |
| Loads in the real game | `state=loaded`, alongside the voxel mod |
| Icon registration against Red's real cache | **10 archetypes**, Yellow-only one skipped |
| Two real game processes | both `PAIRED` |
| Same, through `play.ps1 -Ghosts` | both `PAIRED` |
| `main.lua` compiles **and runs** against a stub mod API | pass |
| Option rows valid per `ManagerState`'s contract | 5/5 |
| `battle.started` / `battle.ended` / `mod.options_changed` subscribed | pass |
| `state` message: booleans only | non-boolean rejected |
| Unknown peer body sprite | falls back, never invisible, never reaches `NPC.new` |
| Tick with no world and no session | survives |

That `main.lua` row exists because a syntax error in it once shipped — a `...`
inside a nested closure. The harness only loaded `lib/`, so the entry point was
never compiled until the real game refused it. It's covered now.

Not yet verified: two players actually seeing each other on screen, which
needs both games past the intro on the same map. The networking, spawn,
sprite-resolution and validation paths underneath it are tested; the rendering
is the untested inch.

## Limits

- Ghosts trail your peer by network latency plus up to one grid step. On a LAN
  that isn't visible.
- Needs lua-enet, which LÖVE bundles. A build without it logs and stays off.
- Internet play would need port forwarding. The engine's relay (with its
  6-character room codes) is two-party only, so it can't carry four ghosts —
  wiring it up as a two-player fallback is the obvious next step.
- Up to 8 ghost slots exist; 4 players is what it's designed around.
