# PAD HOTKEYS

Reach the display hotkeys from a controller.

The engine's digit toggles — and every mod pipeline that claims one, including
the voxel mod's **VOXEL / V-GRID / T-SHIFT / V-CURVE / 3D-BTL / WATER** ladders
— are keyboard digits. On a couch with two pads and nobody near the keyboard,
the one thing you actually want to fiddle with mid-game is the one thing you
can't reach.

## Defaults

| button | fires |
| --- | --- |
| **L3** (click left stick) | `3` — VOXEL ladder (OFF → 15 → 35 → 50 → 75 → 1ST) |
| **R3** (click right stick) | `9` — WATER (FULL / SKY / OFF) |
| **X** | off |
| **Y** | off |

Every one is an options row, so each player picks their own targets, and the
choice persists per player.

## Which buttons, and why those

`GamepadMap.DEFAULT_GAMEPAD_BINDINGS` claims only the d-pad, A, B, START and
SELECT. `Game:gamepadpressed` additionally takes the shoulders and triggers for
GAME SPEED, and SELECT+face for the engine's display chords.

That leaves the two **stick clicks** and the **X/Y** face buttons genuinely
unbound — nothing is stolen from the game to make this work.

## Targets

`1`–`5` are the engine's own. A mod render pipeline claims its digit *last*, so
with the voxel mod installed `3` and `5` are its VOXEL and V-GRID rather than
the engine's TILT and GBC FX. The row labels assume that mod is present.

## Split screen

Polls the pad rather than intercepting its events, and asks
[`PAD_OWNER`](../PAD_OWNER) the same question the event path asks — so player
2's stick click only changes player 2's screen. Without that mod installed,
every pad counts, which is stock single-player behaviour and the right
default: a missing filter must never mean a dead button.

The lookup is retried until it lands rather than done once at load. The
manifest's `optional_dependencies` already orders `PAD_OWNER` first, but a
lookup that quietly degrades to "every pad" on a load-order accident is
exactly the kind of bug that only appears on someone else's machine.

Rising edge only: these are cycles, so holding a stick click doesn't run the
ladder round and round.

## Install

Drop the folder in alongside your other mods:

```
%APPDATA%\pokemon-love2d\mods\PAD_HOTKEYS\
```

`pokemon-love2d` is the save folder the official build uses by default; the
split-screen launcher gives each player their own (`gen1recomp-p1`, `-p2`, …).
