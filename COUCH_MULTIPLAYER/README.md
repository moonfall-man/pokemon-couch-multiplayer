# COUCH MULTIPLAYER

Play side by side on one PC. **Import the mod, set `PLAYERS` to 2, load your save.**

That's the whole setup. No scripts, no installer, no second copy of the game to
configure, no folders to copy.

```
MODS -> COUCH MULTIPLAYER -> PLAYERS: 2
```

Player 1 is the window you opened. It starts the others, gives each its own
save profile and controller, tiles every window into its own quadrant, and
links them so you can see each other walking around.

**`PLAYERS: 1` is the default and does nothing at all** — no extra window, no
controller filtering, no socket. Installing this and playing alone has to be
indistinguishable from not having it, and it is.

---

## What you get

- **Split screen, 2–4 players.** Separate saves, parties and progress. Not one
  window in quadrants — real independent games side by side.
- **See each other.** A player on your map appears as a walking figure with
  their lead Pokémon hovering behind them. All 151 species, built on first boot
  from the battle sprites this game already extracted from *your* cartridge.
- **Pad hotkeys.** The display toggles on the buttons the engine leaves free
  (both stick clicks, X, Y), so you can reach them from a couch.
- **One soundtrack, private sound effects.** Music ducked to 20% in players
  2–4, effects untouched everywhere. Per-window `MUSIC VOL` and `SFX VOL`
  sliders, and `DUCK EXTRA` to turn the policy off.

Presence only: you cannot talk to, battle, trade with, block or be blocked by
another player. That's a deliberate ceiling — Gen 1's overworld has one script
runner, one warp table, one encounter roll and one save, and two players
genuinely sharing those is a redesign, not a mod.

---

## How it starts the other windows

This is the part worth being explicit about, because a mod that launches
processes deserves scrutiny.

Three engine facts make it possible, each checked in the running game rather
than assumed:

| | |
| --- | --- |
| `love.filesystem.getSource()` | the fused executable's own path — the game can start another copy of itself |
| `HostShell.popen` | shells out, so that copy can be handed its own `POKEPORT_IDENTITY` and `POKEPORT_PAD`, which **must** be environment variables because `conf.lua` reads them before any mod exists |
| `love.window.setPosition` | every window tiles **itself** from its own player number |

That last one is why this is small. The launcher script it replaces spent most
of its length waiting for windows to appear and retrying `MoveWindow` against
processes that weren't pumping messages yet. A process that already knows it's
player 3 just puts itself bottom-left.

### The rules it follows

- **`PLAYERS = 1` spawns nothing.** Ever.
- **Only this game's own executable**, from `getSource()` — never a path from a
  config file or the network.
- **A started window is told it is a child** (`POKEPORT_COUCH_PLAYER`) and a
  child never starts anything. Without that, a fork bomb is one bug away.
- **Once per session**, tracked in-process, so a crash can't leave something
  that keeps re-launching.

Verified from a clean profile with only this mod installed:

```
                 player 1     player 2
index / child    1 / false    2 / true
spawned          1            0          <- children never spawn
pad              pad #1       pad #2
ghost role       host         join
```

---

## Why the controller part is two mechanisms

SDL delivers every pad's events to every listening process, and the engine's
input layer discards which pad an event came from — so without a filter, one
controller drives every window.

Wrapping `love.gamepadpressed` handles the events. It is **not sufficient**,
because the engine also *polls*: `Input:reconcile` walks every joystick and
presses whatever is physically down, straight into `Input`, bypassing the
callbacks entirely. It runs on focus gain, on resume and on hotplug, and it
exists for a good reason — a button release can be swallowed while the OS owns
the event stream, so holds are rebuilt from the devices' ground truth.

The symptom of missing it is that clicking a window makes it act on whatever
the *other* player is holding. Rather than reimplement `reconcile`, the mod
narrows what it can **see**: a filtered `getJoysticks` for the duration of the
call.

Both paths are filtered. Ten callbacks in total.

---

## Two people, two machines

`PLAYERS` is for one PC. Over a LAN, leave it at 1 and use the `GHOSTS` row
instead — `HOST` on one machine, `JOIN` plus the host's address on the other.
Each person gets a full screen, and there's nothing to route.

---

## You supply the ROM

**Nothing here contains game data.** The follower sprites are generated on
first boot from art the game already extracted from your own cartridge dump,
and they live in your save folder. Nothing is downloaded and nothing is
redistributed.

## Replaces

`PAD_OWNER`, `GHOST_LINK` and `PAD_HOTKEYS`, which were three separate mods
doing one job between them. The manifest declares them as conflicts — uninstall
them if you have them.
