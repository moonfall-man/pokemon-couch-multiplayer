# PAD OWNER

One controller per window.

Split screen on this engine is not a rendering problem. Run the game twice and
you already have two independent worlds side by side on one monitor — separate
saves, separate parties, separate everything. What you do *not* have is a way
to control them separately, and that is the entire difficulty.

SDL delivers every pad's events to every process that is listening, and the
engine's input layer throws away which pad an event came from:

```lua
function Input:gamepadpressed(joystick, button)
  local btn = self.padBindings[button]
  if btn then press(self, btn, "pad:" .. button) end
end
```

`joystick` goes in and is never looked at again. So press A on either
controller and both games press A. This mod is the missing filter.

## Use

Set `POKEPORT_PAD` per process. The launcher scripts in
[`splitscreen/`](../splitscreen) do it for you; this is what they set:

| Variable | Meaning |
| --- | --- |
| `POKEPORT_PAD` unset / `all` / `0` | every pad — stock behaviour, the default |
| `POKEPORT_PAD=1`…`8` | only the Nth pad in SDL's enumeration order |
| `POKEPORT_PAD=none` | no pad at all, keyboard only |
| `POKEPORT_KEYBOARD=0` | additionally mute the keyboard for this window |

Pad numbering is SDL's enumeration order, which in practice is the order the
controllers were connected — **plug them all in before launching.**

With `POKEPORT_PAD` unset the mod does nothing at all: it does not wrap a
single callback and returns immediately. Leaving it installed while playing
alone costs you nothing, which is deliberate — a mod you have to remember to
uninstall is a mod that will eventually be blamed for something it did not do.

## Why this is a mod and not a patch

It used to be a patch, and the reason it no longer needs to be is worth
recording, because the argument for patching was superficially airtight.

`main.lua` defines `love.gamepadpressed` and its siblings at chunk level. There
is no hook anywhere near them. Mods load from inside `love.load` →
`Game:load` → `mods:load`, which is *after* that chunk has run. Reading that
ordering, a mod looks hopelessly too late, and so the project shipped a build
step: unpack the game, splice guards into `main.lua`, repack, and keep the
anchors matching upstream forever.

The flaw is that "too late to define the callback" and "too late to *replace*
it" are different claims, and only the first one is true. LÖVE never captures
these functions at boot — `love.handlers` looks up `love.<name>` at the moment
each event is dispatched, every time. A function installed a minute after boot
is found just as readily as one installed before it.

That is a claim about someone else's engine, so it was checked in the real
game rather than argued from source:

```
gamepadpressed defined at driver time: function
handlers dispatch reached wrapper: true
```

The wrapper fires. The build step was working around a restriction that was
never there, and deleting it means this runs on the **official release**
exactly the way any other mod does.

## What gets wrapped

The callbacks in `main.lua`, not `src/core/Input.lua`. That is not an
arbitrary choice: `Game:gamepadpressed` cycles game speed and routes menu
input *before* it delegates to `Input`, so a filter placed inside `Input`
would still let player 2's pad drive player 1's menus. Guarding the outermost
callback is what makes the filter total.

- `gamepadpressed`, `gamepadreleased`, `gamepadaxis`
- `joystickpressed`, `joystickreleased`, `joystickaxis`, `joystickhat`
- `joystickadded`, `joystickremoved` — re-arm the binding, then fall through
  **unfiltered**. A pad appearing is news this process needs even when the pad
  belongs to someone else, because it may have shifted SDL's enumeration order
  and therefore which physical device is pad #2.
- `keypressed`, `keyreleased` — only when `POKEPORT_KEYBOARD=0`.

Plus one thing that isn't a callback at all — see below.

## The path that isn't an event

Guarding the callbacks is necessary and **not sufficient**, because the engine
also *polls*:

```lua
-- src/core/Input.lua
function Input:reconcile()
  ...
  local ok, joysticks = pcall(js.getJoysticks)
  for _, j in ipairs(joysticks) do
    for button, btn in pairs(self.padBindings) do
      local ok2, down = pcall(j.isGamepadDown, j, button)
      if ok2 and down then press(self, btn, "pad:" .. button) end
```

Every joystick, no ownership test, pressing straight into `Input` rather than
through `love.gamepadpressed` — so no wrapper anywhere near the callbacks can
see it. It runs from `Game:focus` (on focus **gained**), `Game:onResume`, and
`Game:recoverInput` on a hotplug. The symptom is that clicking a window makes
it act on whatever the *other* player is holding.

It exists for a good reason: a button release can be swallowed while the OS
owns the event stream, so held buttons are rebuilt from the devices' ground
truth rather than guessed.

**This hid behind a second bug for a long time.** While the background-events
hint was being set too late to work, SDL discarded presses for an unfocused
window — and `SDL_PrivateJoystickButton` drops the internal state update along
with the event, so `isGamepadDown` answered "not pressed" for another window's
pad. Polling every device was harmless because the devices lied. Fixing the
hint made them tell the truth, and this surfaced immediately.

Rather than reimplement `reconcile`, the mod narrows what it can **see**: a
filtered `love.joystick.getJoysticks` is swapped in for the duration of the
call and restored afterwards, including if it throws. Whatever it polls — and
whatever a future engine version adds to it — it can only poll pads this
window owns.

Measured in the real game, two pads, by handing the engine stand-in devices
that record being polled:

```
                    with the wrap      without it
pad id=1 (owned)    polled 10x         polled 10x
pad id=2 (foreign)  polled  0x         polled 10x   <- the bug
```

Re-wrapping is prevented by identity rather than by a flag: the wrapper
functions are recorded in a process-wide weak set, so the question asked is
"is the callback currently installed already one of mine?" A boolean set
inside this chunk would be reset by the very reload it exists to detect.

## Background events

SDL drops joystick events for an **unfocused** window unless
`SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS` is set — which leaves exactly one
player able to move at a time, whoever clicked last.

**Set it in the environment.** SDL reads its hints during `SDL_Init`, so
`SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` in the launching process is in force
before the joystick subsystem exists. The launcher scripts do this.

No Lua can match that, and it is later than it looks. This used to be set from
`main.lua`'s chunk on the assumption that early in `main.lua` meant early.
Measured at exactly that point in a real LÖVE 11.5 boot:

```
joystick module loaded : true
joysticks enumerated   : 2
window open            : true
hint                   : (unset)
```

Everything the hint could influence had already happened. `allowBackgroundEvents()`
remains as a fallback for a hand-started game, and returns `"env"` / `"ffi"` /
`false` so the log says which route was taken — *"`SDL_SetHint` did not throw"*
is a different claim from *"background pads work"*, and confusing the two is
what let this sit broken.

## Limits worth knowing

**The launcher is not filtered.** Mods do not exist until a game boots, so the
ROM importer and the version-select screen see every pad. Launch with
`--game=red` (the scripts do) and you skip straight past both. The one time
this bites is the very first run on a fresh install, before the ROM has been
imported.

**Pads are bound by index, not identity.** Unplugging pad #1 mid-session
promotes pad #2 to index 1. `joystickremoved` re-arms the lookup, so the
binding is retaken rather than left dangling, but who owns what may change.

## Talking to it

Other mods can ask which pad this window owns:

```lua
local owner = mod.find("PAD_OWNER")
local mine = not owner or owner.exports.owns(joystick)
```

`nil` means the mod is absent, and treating that as "yes" is the correct
default — that is stock single-player behaviour. [`PAD_HOTKEYS`](../PAD_HOTKEYS)
uses exactly this, so a stick click only changes the screen of the player who
clicked it.
