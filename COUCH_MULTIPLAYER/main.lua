-- GHOST LINK: see the other players walking around your own world.
--
-- Everyone runs their own complete, independent game -- own save, own party,
-- own progress. The only thing crossing the wire is where each player is
-- standing. On your screen, a player who happens to be on your map appears as
-- a walking figure with their lead Pokemon trailing behind. You cannot talk to
-- them, battle them, block them or be blocked by them. You walk straight
-- through each other.
--
-- That is a deliberate ceiling, not a first version. Gen 1's overworld has one
-- script runner, one warp table, one encounter roll and one save; two players
-- genuinely sharing those is a redesign of the game, not a mod. Presence is
-- the part that is honestly additive, so presence is all this does.
--
-- The trick that makes ghosts free is the engine's own: Yellow's Pikachu is
-- "an NPC-shaped entity that lives in ow.npcs ... but never in ow.entities",
-- so it draws and animates but does not block the player. npcs is the draw
-- list, entities is the collision list, and a body in the first but not the
-- second is exactly a ghost. See lib/Ghost.lua.

local mod = ...

-- ------- the mod namespace
--
-- Same shape as the battle-art/voxel mod: lib modules are loaded through V
-- rather than package.path, because a mod directory is not on it and may live
-- inside a mounted archive that plain require cannot open.

local V = { mod = mod, path = mod.path }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("GHOST_LINK: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("GHOST_LINK: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local dataFiles = {}
function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

local Transport = V.require("Transport")
local Wire = V.require("Wire")
local Presence = V.require("Presence")
local GhostPool = V.require("GhostPool")
local FollowerSprites = V.require("FollowerSprites")
local LocalFollower = V.require("LocalFollower")

-- ------- follower art
--
-- Registered during the entry chunk, which is the content-registration phase.
-- Two sources: your own per-species PNGs if you supplied any, and the ROM's
-- party-menu icons, which cover all 151 species out of the box. Zero supplied
-- PNGs is the normal state and is not an error -- the icons carry it.

-- MON ART has to be read here rather than deferred to session start, because
-- sprite registration is a load-time phase and cannot be redone later. The
-- loader folds modOptions in before any entry chunk runs, so the saved value
-- is already there; a failure defaults to on.
local romMode = "on"
do
  local ok, v = pcall(function() return mod.options:get("romart") end)
  if ok and v == false then romMode = "off" end
end

local followerArt, followerRom, followerIcons = FollowerSprites.registerAll(romMode)
local localFollower = LocalFollower.new()

-- ------- configuration
--
-- Environment rather than an options row, because the launcher already passes
-- per-player environment (POKEPORT_PAD, POKEPORT_IDENTITY) and this has to be
-- decided before anyone reaches a menu. Unset means off: installing the mod
-- must not open a socket on its own.
--
--   POKEGHOST_HOST=1            host a session
--   POKEGHOST_JOIN=addr[:port]  join one ("127.0.0.1" for same-PC play)
--   POKEGHOST_PORT=7778         port to host on / default for join
--   POKEGHOST_SPRITE=SPRITE_RED how OTHERS see me
--   POKEGHOST_NAME=Cory         overrides the save's player name

local function env(name)
  local v = os.getenv(name)
  if type(v) ~= "string" then return nil end
  v = v:gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then return nil end
  return v
end

-- ------- options
--
-- These persist in save.options.modOptions, which lives in options.lua --
-- and options.lua is per LOVE identity. The split-screen launcher already
-- gives every player their own identity (POKEPORT_IDENTITY=gen1recomp-pN),
-- so each player's rows are genuinely their own with nothing extra to do.
--
-- Environment wins over the saved row. That ordering is deliberate: the
-- launcher decides who hosts, and it must not be overridden by whatever the
-- OPTIONS menu happened to be left on last session.

local Couch = V.require("Couch")
local PadOwner = V.require("PadOwner")
local PadFilter = V.require("PadFilter")
local Hotkeys = V.require("Hotkeys")

local optionRows = {
  -- FIRST ROW, and the only one most people will ever touch.
  --
  -- 1 is the default and does nothing at all: no window is started, no
  -- controller is filtered, no socket is opened. Playing alone with this mod
  -- installed has to be indistinguishable from not having it.
  { key = "players", type = "choice", label = "PLAYERS", default = "1",
    choices = { { "1", "1" }, { "2", "2" }, { "3", "3" }, { "4", "4" } },
    description = "Split screen. 2 or more starts that many copies of the "
      .. "game side by side, one controller each, and links them so you can "
      .. "see each other. Plug every controller in BEFORE pressing Play. "
      .. "Takes effect next launch." },

  -- For two people on two MACHINES. A couch session on one PC sets this for
  -- itself from PLAYERS, so most people never touch it.
  { key = "role", type = "choice", label = "GHOSTS", default = "off",
    choices = { { "OFF", "off" }, { "HOST", "host" }, { "JOIN", "join" } },
    description = "See other players walking around your world. HOST opens a "
      .. "session; JOIN dials the address below. Off by default, and the "
      .. "launcher's -Ghosts flag overrides this row." },
  { key = "address", type = "text", label = "GHOST ADDR", default = "127.0.0.1",
    description = "Who to dial when GHOSTS is JOIN. 127.0.0.1 is another copy "
      .. "on this same PC; otherwise the host's LAN address." },
  { key = "body", type = "choice", label = "GHOST BODY", default = "SPRITE_RED",
    choices = { { "RED", "SPRITE_RED" }, { "BLUE", "SPRITE_BLUE" },
                { "TRAINER M", "SPRITE_COOLTRAINER_M" },
                { "TRAINER F", "SPRITE_COOLTRAINER_F" } },
    description = "How OTHER players see you. Give each player a different "
      .. "one so you can tell each other apart." },
  { key = "follower", type = "toggle", label = "GHOST MON", default = true,
    description = "Show each ghost's lead Pokemon hovering behind them, using "
      .. "its party-menu icon." },
  { key = "marker", type = "toggle", label = "BTL MARKER", default = true,
    description = "Spin a POKe BALL over a ghost's head while that player is "
      .. "in a battle." },
  { key = "mymon", type = "toggle", label = "MY MON", default = true,
    description = "Your own lead Pokemon hovers behind you, on your own "
      .. "screen. Works with GHOSTS off -- it needs no network at all." },
  { key = "romart", type = "toggle", label = "MON ART", default = true,
    description = "Build real per-species followers by shrinking the battle "
      .. "sprites this game extracted from your own ROM. OFF uses the "
      .. "party-menu icons instead, which are shared archetypes." },
}

for _, row in ipairs(Hotkeys.schema()) do optionRows[#optionRows + 1] = row end
mod.options:define(optionRows)

local function opt(key)
  local ok, v = pcall(function() return mod.options:get(key) end)
  if ok then return v end
  return nil
end

-- Resolved lazily, at session start rather than at load: options.lua is not
-- guaranteed to be folded in while the entry chunk is still running.
-- ------- the couch session
--
-- Everything the launcher scripts used to do, decided here instead: how many
-- windows there are, which controller this one owns, where it sits on the
-- screen, and who hosts the ghost link.
--
-- Runs ONCE, at load. PLAYERS is read straight from the options store rather
-- than through resolveConfig, because that resolves lazily at the first tick
-- and the extra windows have to be on their way before then.

local couch = {
  index = Couch.playerIndex(),
  isChild = Couch.isChild(),
  players = 1,
  started = 0,
  note = nil,
}

do
  -- A child is told the total; player 1 reads the row.
  local total = tonumber(env("POKEPORT_COUCH_TOTAL") or "")
  if not total then total = tonumber(opt("players") or "1") end
  couch.players = math.max(1, math.min(total or 1, Couch.MAX_PLAYERS))

  if couch.players > 1 then
    -- One controller per window. A child was given POKEPORT_PAD by whoever
    -- started it; player 1 has to claim pad #1 for itself, since nobody set a
    -- variable for the window a human opened.
    PadOwner.bind(couch.index)

    -- Put this window in its own quadrant. Every instance does its own, from
    -- its own player number -- no waiting on anyone else's window to exist.
    Couch.tileSelf(couch.index, couch.players)

    -- Start the others. Guarded three ways inside: never from a child, never
    -- below 2 players, never twice.
    if not couch.isChild then
      local started, why = Couch.spawnOthers({
        players = couch.players,
        game = env("POKEPORT_GAME"),
        ghosts = true,
        ghostPort = tonumber(env("POKEGHOST_PORT")) or 7778,
      })
      couch.started = started or 0
      couch.note = why
    end
  end

  -- Filter the pads whenever there is anything to filter. With PLAYERS = 1
  -- and no POKEPORT_PAD this is false and not one callback is touched.
  if PadOwner.filtering then
    local wrapped = PadFilter.install(PadOwner)
    couch.wrapped = wrapped
  end
end

local function resolveConfig()
  -- A couch session links itself. Nobody setting PLAYERS = 2 wants to then
  -- discover a separate GHOSTS row and work out which window should host, so
  -- player 1 hosts and everyone it started joins. The manual row still exists
  -- for the case it was written for: two people on two machines over a LAN.
  local couchRole = nil
  if couch.players > 1 then
    couchRole = couch.isChild and "join" or "host"
  end

  local role = couchRole
            or (env("POKEGHOST_HOST") == "1" and "host")
            or (env("POKEGHOST_JOIN") and "join")
            or opt("role") or "off"

  local cfg = {
    role = role,
    host = role == "host",
    join = env("POKEGHOST_JOIN") or opt("address") or "127.0.0.1",
    port = tonumber(env("POKEGHOST_PORT")),
    sprite = env("POKEGHOST_SPRITE") or opt("body") or "SPRITE_RED",
    name = env("POKEGHOST_NAME"),
    follower = opt("follower") ~= false,
    marker = opt("marker") ~= false,
    myMon = opt("mymon") ~= false,
  }
  cfg.enabled = (role == "host") or (role == "join")
  return cfg
end

local config = { enabled = false, role = "off" }


-- ------- session

local session = {
  transport = nil,
  presence = nil,
  pool = nil,
  attempted = false,
  status = "off",
}

-- Varargs are passed straight through pcall rather than captured in a
-- closure: an inner `function() ... end` is not itself vararg, so `...`
-- inside one is a syntax error.
local function log(fmt, ...)
  pcall(mod.log.info, mod.log, fmt, ...)
end

local function start()
  if session.attempted then return end
  session.attempted = true
  config = resolveConfig()
  if not config.enabled then
    session.status = "off"
    return
  end

  if not Transport.available() then
    session.status = "no enet"
    log("lua-enet unavailable; ghosts disabled")
    return
  end

  local t = Transport.new()
  local ok
  if config.host then
    ok = t:host(config.port)
  else
    ok = t:join(config.join)
  end
  if not ok then
    session.status = "error: " .. tostring(t.error)
    log("%s", session.status)
    return
  end

  session.transport = t
  session.presence = Presence.new(Wire.newId(), { name = config.name, sprite = config.sprite })
  session.pool = GhostPool.new({
    bodySprite = config.sprite,
    followers = config.follower,
    marker = config.marker,
  })
  session.status = config.host and ("hosting " .. tostring(t.address)) or ("joined " .. tostring(config.join))
  log("%s (%d supplied, %d from ROM, %d icon archetypes)",
      session.status, followerArt, followerRom, followerIcons)
end

-- ------- live status dump
--
-- Written to the save directory a couple of times a second so a session can
-- be diagnosed after the fact. "I can't see them" has several very different
-- causes -- no peer, no messages, peer on another map, spawn refused -- and
-- they are indistinguishable from inside the game.
local rx = {}          -- message type -> count received
local lastDump = 0

local function dumpStatus(myMap, cur)
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
  if now - lastDump < 0.5 then return end
  lastDump = now

  local t = session.transport
  local pool = session.pool
  local total, spawned, detail = 0, 0, ""
  if pool then total, spawned, detail = pool:describe() end

  local counts = {}
  for k, v in pairs(rx) do counts[#counts + 1] = ("%s=%d"):format(k, v) end
  table.sort(counts)

  local lines = {
    ("status    : %s"):format(tostring(session.status)),
    ("role      : %s"):format(tostring(config.role)),
    ("peers     : %d"):format(t and t:peerCount() or 0),
    ("my map    : %s"):format(tostring(myMap)),
    -- The GB screen is 160x144, so about 10x9 tiles with the player centred.
    -- A ghost more than ~4 cells away is simply off the edge of the screen,
    -- which looks identical to "not working" from the couch.
    ("me at     : cell(%s,%s)"):format(
      tostring(cur and cur.x), tostring(cur and cur.y)),
    ("pool map  : %s"):format(tostring(pool and pool.myMapId)),
    ("known     : %d peers, %d spawned"):format(total, spawned),
    ("ghosts    : %s"):format(detail ~= "" and detail or "(none)"),
    ("received  : %s"):format(#counts > 0 and table.concat(counts, " ") or "(nothing)"),
    ("my id     : %s"):format(tostring(session.presence and session.presence.id)),
    ("followers : %d supplied, %d rom, %d icons"):format(followerArt, followerRom, followerIcons),
    ("error     : %s"):format(tostring(t and t.error)),
  }
  pcall(function()
    love.filesystem.write("ghostlink-status.txt", table.concat(lines, "\n") .. "\n")
  end)
end

local function stop()
  if session.presence and session.transport then
    session.presence:sendBye(session.transport)
  end
  if session.transport then session.transport:close() end
  -- Take the bodies out of the world before dropping the pool, or the NPCs
  -- stay in ow.npcs with nothing left holding a reference to remove them.
  if session.pool then pcall(function() session.pool:dropAll(mod.world) end) end
  session.transport, session.presence, session.pool = nil, nil, nil
  session.status = "closed"
end

-- ------- the tick
--
-- input.step runs once per fixed step from EVERY state -- overworld, battle,
-- menu, title -- so the socket keeps being pumped while a player is in a
-- battle or staring at a menu, and their ghost keeps standing where they left
-- it rather than freezing the pool for everyone else.

mod.hooks:wrap("input.step", function(next, game, dt)
  next(game, dt)

  -- Display hotkeys on the pad buttons the engine leaves free. Polled here
  -- rather than hooked, and filtered by pad ownership so player 2's stick
  -- click only changes player 2's screen.
  pcall(Hotkeys.step, game, opt, PadOwner.filtering and PadOwner.owns or nil)

  start()   -- resolves config on the first tick; a no-op thereafter

  -- Your own Pokemon follows you whether or not anyone else is connected --
  -- this is the half of the mod that needs no network.
  local world = mod.world
  pcall(function()
    localFollower:update(world, game, FollowerSprites.spriteFor, config.myMon)
  end)

  local t = session.transport
  if not t then return end

  if t.closed then
    if session.status ~= "closed" then
      session.status = "closed: " .. tostring(t.error or "peer left")
      log("%s", session.status)
      if session.pool then session.pool:dropAll(mod.world) end
      session.status = "closed"
    end
    return
  end

  t:update()

  -- Someone new arrived, so re-announce ourselves.
  --
  -- A peer that connects late gets nothing retroactively: Transport only
  -- queues messages while it has NO peers, and that outbox is drained on the
  -- first connection. Without this, the third player -- and anyone whose
  -- session restarted -- would see everyone already in the game as a generic
  -- body with no follower, permanently, because identity is only ever
  -- volunteered and never asked for.
  local peers = t:peerCount()
  if peers > (session.peerCount or 0) and session.presence then
    session.presence:armResend()
  end
  session.peerCount = peers

  local pool = session.pool

  -- My own map, read straight from the world rather than from a map event:
  -- one source of truth, and no assumption about an event payload's shape.
  local okCur, cur = pcall(function() return world:current() end)
  local myMap = (okCur and type(cur) == "table") and cur.mapId or nil
  if pool and myMap ~= pool.myMapId then
    pool:onMapChanged(world, myMap)
    -- Every ghost was just despawned. Ask everyone to say where they are
    -- instead of waiting for whoever is standing still to hit their keepalive
    -- -- otherwise walking into a town where someone is already waiting left
    -- them invisible for several seconds.
    if myMap and session.presence then
      t:send(Wire.sync(session.presence.id))
    end
  end

  for _, raw in ipairs(t:poll()) do
    local msg = Wire.validate(raw)
    rx[msg and msg.t or "REJECTED"] = (rx[msg and msg.t or "REJECTED"] or 0) + 1
    if msg and pool and session.presence and msg.id == session.presence.id
       and msg.t ~= "peer_lost" then
      -- We never receive our OWN messages: a client sends only to the host,
      -- and the host relays to every peer except the sender. So a message
      -- wearing our id is proof that two instances generated the same one --
      -- which used to mean every peer message was discarded as an echo and
      -- nobody ever appeared. Re-roll and re-announce instead of ignoring
      -- that player forever.
      log("id collision with a peer (%s); re-rolling", tostring(msg.id))
      session.presence.id = Wire.newId(tostring(msg.id) .. tostring(t))
      session.presence.helloSent = false
      session.presence:armResend()
    end

    if msg and pool then
      -- Never let a peer's message stand in for my own player.
      if msg.id ~= (session.presence and session.presence.id) then
        if msg.t == "sync" then
          -- Someone changed map and lost sight of everyone. Re-announce.
          if session.presence then session.presence:armResend() end
        else
          pcall(function() pool:handle(world, game, msg) end)
        end
      end
    end
  end

  if myMap and session.presence then
    pcall(function() session.presence:tick(t, world, game) end)
  end

  if pool then pcall(function() pool:update(world, game) end) end

  dumpStatus(myMap, (okCur and type(cur) == "table") and cur or nil)
end)

-- ------- battle marker
--
-- Edge-triggered off the engine's own events. The overworld state stays on
-- the stack underneath a battle, so world:current() keeps reporting where
-- this player is standing -- their ghost simply stops moving and grows a
-- spinning ball rather than vanishing.

mod.events:on("battle.started", function()
  if session.presence then
    session.presence:setBattling(session.transport, true)
  end
end)

mod.events:on("battle.ended", function()
  if session.presence then
    session.presence:setBattling(session.transport, false)
  end
end)

-- ------- live reconfiguration
--
-- Changing a row in the mod manager tears the session down and lets the next
-- tick build it again from the new values, so switching HOST/JOIN or a body
-- sprite takes effect without a restart.
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  stop()
  session.attempted = false
end)

-- Returning to the title tears the world down under any spawned ghost, so
-- drop them rather than leave dangling npc ids behind.
mod.events:on("save.loaded", function()
  if session.pool then session.pool:dropAll(mod.world) end
end)

mod.events:on("world.blacked_out", function()
  if session.pool then session.pool:dropAll(mod.world) end
end)

-- ------- leaving
--
-- Closing the window has to take my ghost out of everyone else's world, and
-- there is no engine event for it: the mod bus emits mods.loaded,
-- mod.options_changed and pokemon.before_give, and nothing at all for quit.
-- Before this, quitting sent no notice whatsoever -- the process simply died,
-- and since ENet is UDP there is no FIN to notice. The other player was left
-- looking at a statue until ENet's own peer timeout expired and then the
-- pool's 30-second stale sweep finally collected it.
--
-- So wrap love.quit. This works for the same reason PAD_OWNER's controller
-- filter does, and it is worth being explicit that it is the same fact rather
-- than a coincidence: LOVE never captures its callbacks at boot, love.handlers
-- resolves love.<name> at the moment each event is dispatched. A function
-- installed from a mod is simply the one that runs.
--
-- Both exits come through here. A plain quit, and -- when the game was not
-- launched with --game/POKEPORT_GAME -- the window close that RESTARTS into
-- the launcher, which would otherwise leave a ghost standing in the other
-- player's world while this process was busy being reborn.
--
-- Delegates unconditionally and never changes the answer: love.quit returning
-- true ABORTS the quit (that is how the restart-to-launcher path works), so
-- swallowing or inventing that return value would hang the window shut.
do
  local inner = love.quit
  love.quit = function(...)
    pcall(stop)
    if type(inner) == "function" then return inner(...) end
  end
end

-- ------- exports (for debugging from another mod or the console)

mod.exports.version = "0.2.0"
mod.exports.players = couch.players
mod.exports.index = couch.index
mod.exports.isChild = couch.isChild
mod.exports.started = couch.started
mod.exports.note = couch.note
mod.exports.wrapped = couch.wrapped
mod.exports.pad = PadOwner.describe and PadOwner.describe() or nil
mod.exports.role = function() return config.role end
mod.exports.status = function() return session.status end
mod.exports.ghosts = function() return session.pool and session.pool:count() or 0 end
mod.exports.peers = function()
  return session.transport and session.transport:peerCount() or 0
end
mod.exports.followers = followerArt
mod.exports.followerRom = followerRom
mod.exports.followerIcons = followerIcons
mod.exports.stop = stop
mod.exports.lib = V
