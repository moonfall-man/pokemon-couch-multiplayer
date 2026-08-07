-- What I broadcast about myself.
--
-- Only four facts leave this machine: which map I am on, which cell I stand
-- in, which way I face, and my lead Pokemon's species. Not my party, not my
-- badges, not my items, not my save. That is the whole point of ghosts -- the
-- other player is looking at a puppet driven by four numbers, and there is
-- nothing else on the wire for them to see or for a bug to leak.
--
-- Sends are edge-triggered on movement, with a slow keepalive underneath so
-- somebody standing still reading a sign does not age out of the pool.

local V = ...

local Wire = V.require("Wire")

local Presence = {}
Presence.__index = Presence

-- Comfortably inside GhostPool's 30s timeout, and rare enough that four
-- idle players cost nothing.
local KEEPALIVE = 5

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.time()
end

function Presence.new(id, opts)
  return setmetatable({
    id = id,
    name = (opts and opts.name) or nil,
    sprite = (opts and opts.sprite) or nil,
    lastMap = nil, lastX = nil, lastY = nil, lastFacing = nil,
    lastSpecies = nil,
    lastSent = 0,
    helloSent = false,
  }, Presence)
end

-- The engine's own player name, when there is a save to read it from.
local function playerName(game)
  local save = game and game.save
  local name = save and save.playerName
  if type(name) == "string" and #name > 0 then return name end
  return nil
end

-- Lead party member's species key (a string like PIKACHU), or nil for an
-- empty party -- which is the normal state before Oak hands over a starter.
local function leadSpecies(game)
  local save = game and game.save
  local party = save and save.party
  local lead = party and party[1]
  local species = lead and lead.species
  if type(species) == "string" and #species > 0 then return species end
  return nil
end

function Presence:sample(world, game)
  if not world then return nil end
  local ok, cur = pcall(function() return world:current() end)
  if not ok or type(cur) ~= "table" or not cur.mapId then return nil end
  if cur.x == nil or cur.y == nil then return nil end
  return {
    map = cur.mapId,
    x = cur.x,
    y = cur.y,
    f = cur.facing,
    species = leadSpecies(game),
  }
end

-- Announce who I am. Sent on connect and repeated whenever a new peer shows
-- up, since a late joiner missed the first one.
function Presence:sendHello(transport, game)
  self.name = self.name or playerName(game)
  transport:send(Wire.hello(self.id, self.name, self.sprite, leadSpecies(game)))
  self.helloSent = true
end

-- Returns true if anything went out this call.
function Presence:tick(transport, world, game)
  if not transport or transport.closed then return false end

  local state = self:sample(world, game)
  if not state then return false end   -- title screen, menus, no overworld

  if not self.helloSent then self:sendHello(transport, game) end

  local sent = false

  if state.species ~= self.lastSpecies then
    self.lastSpecies = state.species
    transport:send(Wire.party(self.id, state.species))
    sent = true
  end

  local moved = state.map ~= self.lastMap
             or state.x ~= self.lastX
             or state.y ~= self.lastY
             or state.f ~= self.lastFacing

  if moved or (now() - self.lastSent) >= KEEPALIVE then
    transport:send(Wire.pos(self.id, state.map, state.x, state.y, state.f))
    -- Repeated with the keepalive, not just on the edge: a peer who joined
    -- while I was already in a battle never saw the transition.
    transport:send(Wire.state(self.id, self.battling))
    self.lastMap, self.lastX, self.lastY, self.lastFacing =
      state.map, state.x, state.y, state.f
    self.lastSent = now()
    sent = true
  end

  return sent
end

-- Battles are edge-triggered from the engine's own events rather than polled,
-- and re-sent on the keepalive tick below so a peer who connected mid-battle
-- still learns about it.
function Presence:setBattling(transport, battling)
  battling = battling and true or false
  if self.battling == battling then return end
  self.battling = battling
  if transport and not transport.closed then
    transport:send(Wire.state(self.id, battling))
  end
end

-- Answer a peer's sync request: arm the next tick to send unconditionally,
-- rather than sending from here. One code path builds the message, and it is
-- the one that also updates lastMap/lastX/lastY -- sending directly would let
-- those drift out of step with what the peers have actually been told.
--
-- IDENTITY IS PART OF THE RESEND, not a once-per-session event.
--
-- hello carries the body sprite and species, and it used to be gated on a
-- helloSent flag that was set true forever the first time it went out. So a
-- peer that connected late, or whose ghost was torn down and rebuilt from a
-- bare pos, never learned who anybody was: they rendered as a generic
-- fallback body with no follower Pokemon, permanently, with no path back.
-- Clearing lastSpecies re-arms the party message for the same reason.
function Presence:armResend()
  self.lastSent = 0
  self.lastMap = nil
  self.helloSent = false
  self.lastSpecies = nil
end

function Presence:sendBye(transport)
  if transport and not transport.closed then
    transport:send(Wire.bye(self.id))
  end
end

return Presence
