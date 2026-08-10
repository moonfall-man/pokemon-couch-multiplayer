# padorder — does every window agree which pad is #1?

```bash
MOD_DIR=/path/to/COUCH_MULTIPLAYER PADTEST_OUT=/tmp/out.txt love COUCH_MULTIPLAYER/tools/padorder
```

Not shipped in the release zip — `tools/` is skipped by `package.ps1`.

## What it is for

The bug it exists to prevent is quiet: **both windows answer to the same
controller and the other one does nothing.** Nothing in a single window's
state looks wrong when that happens. Each one is confident it owns "pad #1",
or "pad #2", and each is right about the list it can see.

The cause is that the two windows are separate processes. Their
`love.joystick.getJoysticks()` lists are in SDL enumeration order, which is
set by the order devices are discovered while each process starts, and there
is nothing to make two processes discover them in the same order. Being a
race, it works most of the time.

## What it checks

The fake pads are the two real controllers this was found on — an 8BitDo and
an Xbox pad — handed to the module in **opposite** orders, the way two racing
processes would see them.

| | |
|---|---|
| orders agree | both processes sort to the same sequence |
| distinct devices | player 1 and player 2 take different controllers |
| raw position collides | **the old behaviour still fails**, so this test can fail |
| identical pair | two of the same controller still yield two objects |

That third row is the one that matters. A test that passes for both the old
and new code proves nothing, so it asserts the enumeration-position approach
still puts both players on the same pad.
