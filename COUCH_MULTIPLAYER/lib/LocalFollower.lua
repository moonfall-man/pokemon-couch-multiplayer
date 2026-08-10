-- Your own lead Pokemon, hovering behind you, on your own screen.
--
-- Nothing to do with networking: this works with GHOSTS switched off
-- entirely. It is the same body and the same drift as a ghost's follower --
-- passable, out of the script machinery, positioned in pixels -- just
-- chasing the local player instead of a remote one.
--
-- Yellow already does this for Pikachu, properly: a real grid-walking
-- follower with happiness, moods and hop commands. This is deliberately NOT
-- that. It never steps, never blocks, never enters a script, and never
-- touches the save -- so it cannot disagree with Yellow's own follower, and
-- on Red or Blue it adds the thing those versions never had without
-- pretending to be part of the game.

local V = ...

local Ghost = V.require("Ghost")

local LocalFollower = {}
LocalFollower.__index = LocalFollower

local HOVER_LIFT = 3
local HOVER_BOB = 1.5
local HOVER_BOB_SPEED = 0.11
local HOVER_EASE = 0.18
local HOVER_SNAP = 64

function LocalFollower.new()
  return setmetatable({
    npc = nil,
    species = nil,
    spriteId = nil,
    mapId = nil,
    px = nil, py = nil,
    prevX = nil, prevY = nil,
    lastX = nil, lastY = nil,
    bobPhase = 0,
  }, LocalFollower)
end

local function overworld(world)
  local ok, ow = pcall(function() return world:overworld() end)
  if ok then return ow end
  return nil
end

local function leadSpecies(game)
  local party = game and game.save and game.save.party
  local lead = party and party[1]
  local species = lead and lead.species
  if type(species) == "string" and #species > 0 then
    -- A fainted lead does not follow you around, same as Yellow's Pikachu.
    if (lead.hp or 1) <= 0 then return nil end
    return species
  end
  return nil
end

function LocalFollower:despawn(world)
  if self.npc then Ghost.despawnNpc(world, self.npc) end
  self.npc = nil
  self.px, self.py = nil, nil
  self.prevX, self.prevY = nil, nil
  self.lastX, self.lastY = nil, nil
end

function LocalFollower:spawn(world, game, spriteId, x, y)
  self:despawn(world)
  local ow = overworld(world)
  if not (ow and ow.map) then return false end
  local npc = Ghost.spawnPassableNpc(world, game, ow.map.id, spriteId, x, y,
                                     "GHOSTLINK_MYMON")
  if not npc then return false end
  self.npc = npc
  self.spriteId = spriteId
  self.mapId = ow.map.id
  -- See Ghost:place -- setMap rebuilds ow.npcs as a NEW table on any reload,
  -- dropping anything not in the map definition. Holding the table lets us
  -- notice and rebuild, rather than keeping a live reference to an NPC the
  -- world has already forgotten.
  self.npcsRef = ow.npcs
  self.px, self.py = x * 16, y * 16
  self.prevX, self.prevY = x, y
  self.lastX, self.lastY = x, y
  return true
end

-- Called every fixed step. `spriteFor(game, species)` is passed in rather
-- than required, so this module knows nothing about where art comes from.
function LocalFollower:update(world, game, spriteFor, enabled)
  if not enabled then
    if self.npc then self:despawn(world) end
    return
  end

  local ow = overworld(world)
  local player = ow and ow.player
  if not (ow and ow.map and player and player.cellX) then
    if self.npc then self:despawn(world) end
    return
  end

  local species = leadSpecies(game)
  local spriteId = species and spriteFor(game, species) or nil

  -- No party yet (before the starter), a fainted lead, or a species with no
  -- art at all: nothing to draw.
  if not spriteId then
    if self.npc then self:despawn(world) end
    self.species = species
    return
  end

  -- Re-place on a map change, a species change, a swapped sprite, or the
  -- engine having rebuilt its npc list under us.
  if not self.npc or self.mapId ~= ow.map.id or self.spriteId ~= spriteId
     or (self.npcsRef and ow.npcs ~= self.npcsRef) then
    self.species = species
    self:spawn(world, game, spriteId, player.cellX, player.cellY)
    if not self.npc then return end
  end

  -- Track the cell the player has just left; that is where the follower goes.
  if player.cellX ~= self.lastX or player.cellY ~= self.lastY then
    self.prevX, self.prevY = self.lastX, self.lastY
    self.lastX, self.lastY = player.cellX, player.cellY
  end

  local targetPx = (self.prevX or player.cellX) * 16
  local targetPy = (self.prevY or player.cellY) * 16

  if math.abs(targetPx - self.px) > HOVER_SNAP
     or math.abs(targetPy - self.py) > HOVER_SNAP then
    self.px, self.py = targetPx, targetPy
  else
    self.px = self.px + (targetPx - self.px) * HOVER_EASE
    self.py = self.py + (targetPy - self.py) * HOVER_EASE
  end

  self.bobPhase = self.bobPhase + HOVER_BOB_SPEED
  if self.bobPhase > math.pi * 2 then self.bobPhase = self.bobPhase - math.pi * 2 end

  local npc = self.npc
  npc.px = self.px
  npc.py = self.py - HOVER_LIFT + math.sin(self.bobPhase) * HOVER_BOB
  npc.cellX, npc.cellY = self.prevX or player.cellX, self.prevY or player.cellY

  local dx, dy = targetPx - npc.px, targetPy - npc.py
  if math.abs(dx) > 1 or math.abs(dy) > 1 then
    if math.abs(dx) > math.abs(dy) then
      npc.facing = dx > 0 and "right" or "left"
    else
      npc.facing = dy > 0 and "down" or "up"
    end
  end
end

return LocalFollower
