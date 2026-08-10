# rejoin — does a joined window come back when the host's socket dies?

```bash
MOD_DIR=/path/to/COUCH_MULTIPLAYER ENGINE_DIR=/path/to/engine \
  REJOIN_OUT=/tmp/out.txt love COUCH_MULTIPLAYER/tools/rejoin
```

Needs `ENGINE_DIR` — `Transport` requires the engine's `src.link.Json`. Not
shipped in the release zip; `tools/` is skipped by `package.ps1`.

Uses a fake `love.timer.getTime` so the silence timeout elapses instantly
instead of costing twelve seconds of wall clock.

## The thing it caught

The retry was first written as "redial when `peerCount() == 0`". This test
says why that never fires:

```
B. host destroyed  join still reports peers=1
```

`Transport:close()` destroys the host without disconnecting — deliberately,
so a parting `bye` is not thrown away along with the connection. The other
end is never told anything. It keeps reporting a live peer until ENet's own
timeout gives up, about half a minute later.

So the trigger is **silence**, not peer count. A peer in the world transmits
at least every `KEEPALIVE` (5s), so twelve seconds of nothing means gone.

It also caught `lastRx = 0` as a sentinel for "nothing has arrived yet": zero
is a real reading from `love.timer.getTime()` early in a boot, so the
sentinel sat inside the value's own range and silence was never detected.
It is `nil` now.

| | |
|---|---|
| A | host and joiner connected |
| B | **host destroyed, joiner still reports peers=1** |
| C | silence detected after the timeout |
| D | joiner reconnects once the host is back |

## What changed after this test passed

Passing here was not enough. In the real game the reconnect then thrashed —
`peer_lost=3` on the host — because **silence is not evidence of death**.
Every other message is about being in the overworld, so two windows sitting
at a menu or on the title screen transmit nothing and look exactly like a
dead host.

Hence `Wire.ping`: a heartbeat both roles send every 4s whatever they are
doing. Only then does going quiet mean something. Measured after the change,
idle at a menu for 25s: `ping` climbing on both sides, no `peer_lost`,
status steady.

The lesson this test could not teach on its own is that a passing harness
proves the mechanism, not the behaviour. Both were needed.
