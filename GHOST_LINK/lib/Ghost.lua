-- One remote player, drawn in MY world: a body, a hovering follower, and a
-- spinning ball while they are in a battle.
--
-- Everything here is built and moved the way Yellow's companion Pikachu is
-- (src/world/PikachuFollower.lua), because that is the one thing in this
-- engine that already had to be "visible, animated, and not really there":
--
--   * NPC.new directly, inserted into ow.npcs / ow.entities by hand. NOT
--     through mod.world:spawnNpc -- that appends the object to
--     Game.data.maps[mapId].objects, which is the SHARED MAP DEFINITION.
--     Ghosts would accumulate in the map data forever and come back as real,
--     solid NPCs on the next map load.
--
--   * npc.passable = true. Collision.occupied skips passable entities
--     outright ("Yellow's companion Pikachu: the player walks straight
--     through and it re-trails"), so this is the engine's own answer to
--     "draws but never blocks" rather than something invented here.
--
--   * Positioned in PIXELS every tick. NEVER through ow:scriptMove.
--     scriptMove pushes onto ow.scriptMoves, and the engine reads a non-empty
--     scriptMoves queue as "a cutscene is running":
--
--         local scripted = self.runner:isRunning() or #self.scriptMoves > 0
--
--     which suppresses player input. A ghost stepping in time with a remote
--     player therefore froze the LOCAL player's controls for as long as the
--     other person kept walking. Writing px/py directly is safe because
--     NPC:update returns before touching them for a STAY object that is not
--     moving, so nothing in the engine fights the writes.
--
-- The walk cycle is faked the same way the engine fakes Pikachu's idle: an
-- instance field shadows NPC.walkPhase, so NPC:pose keeps working unchanged.

local V = ...

local Ghost = {}
Ghost.__index = Ghost

-- Body: constant speed, matching the engine's own 16px-per-16-frames walk, so
-- a gliding ghost and a real NPC move at the same rate.
local BODY_SPEED = 1
local BODY_CATCHUP = 3        -- px/step once more than a tile behind
local BODY_SNAP = 80          -- px beyond which we jump (a warp)
local WALK_CYCLE = 8          -- px per walk-frame flip

-- Follower: eased and bobbing rather than stepped. A hovering thing reads
-- correctly from ONE frame of art, which is why all 151 species work with no
-- imported sprites at all.
local HOVER_LIFT = 3
local HOVER_BOB = 1.5
local HOVER_BOB_SPEED = 0.11
local HOVER_EASE = 0.18
local HOVER_SNAP = 64

-- Battle marker: a poke ball orbiting over the head. One frame, no rotation
-- available through the sprite path, so the spin is the orbit.
local BALL_SPRITE = "SPRITE_POKE_BALL"
local BALL_HEIGHT = 14        -- px above the body's cell
local BALL_ORBIT = 3          -- px radius
local BALL_SPIN = 0.22        -- radians per fixed step

function Ghost.new(peerId, slot, info)
  return setmetatable({
    peerId = peerId,
    slot = slot,
    name = info and info.name or "?",
    sprite = info and info.sprite or nil,
    species = info and info.species or nil,
    battling = false,

    mapId = nil,
    x = nil, y = nil,
    prevX = nil, prevY = nil,
    facing = "down",

    targetX = nil, targetY = nil, targetFacing = nil,

    bodyNpc = nil, bodyPx = nil, bodyPy = nil,
    walkTravel = 0, walkFlip = false,

    footNpc = nil, footPx = nil, footPy = nil, bobPhase = 0,
    ballNpc = nil, spinPhase = 0,
  }, Ghost)
end

-- --------------------------------------------------------------- internals

local function overworld(world)
  local ok, ow = pcall(function() return world:overworld() end)
  if ok then return ow end
  return nil
end

local function removeFrom(list, npc)
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == npc then table.remove(list, i) end
  end
end

-- Build an NPC and put it in the world by hand. `sprite` MUST already be a
-- sprite id the engine knows -- NPC.new asserts on an unknown one, which
-- would take the game down rather than drop a ghost.
local function makeNpc(world, game, mapId, sprite, x, y, name)
  local ow = overworld(world)
  if not (ow and ow.map and ow.map.id == mapId and ow.npcs) then return nil end
  local sprites = game and game.data and game.data.sprites
  if not (sprites and sprites[sprite]) then return nil end

  local ok, npc = pcall(function()
    local NPC = require("src.world.NPC")
    return NPC.new(game.data, mapId, {
      index = 0, name = name, sprite = sprite,
      movement = "STAY", range = "NONE", x = x, y = y,
    })
  end)
  if not ok or not npc then return nil end

  npc.ghostLink = true
  npc.passable = true      -- never blocks a step (Collision.occupied)
  npc.frozen = true        -- never wanders, never faces the player on its own

  table.insert(ow.npcs, npc)
  if ow.entities then table.insert(ow.entities, npc) end
  return npc
end

local function dropNpc(world, npc)
  if not npc then return end
  local ow = overworld(world)
  if not ow then return end
  removeFrom(ow.npcs, npc)
  removeFrom(ow.entities, npc)
end

-- Move a pixel coordinate toward a target, one axis at a time so the path is
-- L-shaped like a real grid walk rather than diagonal.
local function stepToward(px, py, tx, ty, speed)
  local dx, dy = tx - px, ty - py
  if dx ~= 0 then
    local move = math.min(math.abs(dx), speed)
    return px + (dx > 0 and move or -move), py, move
  elseif dy ~= 0 then
    local move = math.min(math.abs(dy), speed)
    return px, py + (dy > 0 and move or -move), move
  end
  return px, py, 0
end

-- --------------------------------------------------------------- lifecycle

function Ghost:despawn(world)
  dropNpc(world, self.bodyNpc)
  dropNpc(world, self.footNpc)
  dropNpc(world, self.ballNpc)
  self.bodyNpc, self.footNpc, self.ballNpc = nil, nil, nil
  self.mapId = nil
  self.x, self.y, self.prevX, self.prevY = nil, nil, nil, nil
  self.bodyPx, self.bodyPy = nil, nil
  self.footPx, self.footPy = nil, nil
end

function Ghost:isSpawned()
  return self.bodyNpc ~= nil
end

function Ghost:place(world, game, mapId, x, y, facing, bodySprite, footSprite)
  self:despawn(world)

  self.bodySprite = bodySprite
  self.footSprite = footSprite

  local npc = makeNpc(world, game, mapId, bodySprite, x, y, "GHOST_" .. self.peerId)
  if not npc then return false end
  self.bodyNpc = npc

  -- Remember WHICH list we were added to.
  --
  -- OverworldState:setMap rebuilds `self.npcs = {}` and
  -- `self.entities = { self.player }` from the map definition -- not just on
  -- a warp, but on any reload (door stamping, a seamless neighbour swap).
  -- Our bodies are not in that definition, deliberately, so they go with it
  -- and nothing tells us. Holding the TABLE lets us notice in O(1): a new
  -- table means everything we put in the old one is gone.
  local ow = overworld(world)
  self.npcsRef = ow and ow.npcs or nil

  -- Shadow the class method so a gliding body still animates its walk cycle;
  -- NPC.walkPhase is moving-only and this body is never "moving" (#411 does
  -- the same for Pikachu's idle).
  local ghost = self
  npc.walkPhase = function() return ghost.walkFlip and 1 or 0 end

  self.mapId = mapId
  self.x, self.y = x, y
  self.prevX, self.prevY = x, y
  self.targetX, self.targetY = x, y
  self.facing = facing or "down"
  self.targetFacing = self.facing
  npc.facing = self.facing
  self.bodyPx, self.bodyPy = x * 16, y * 16
  npc.px, npc.py = self.bodyPx, self.bodyPy

  if footSprite then
    self.footNpc = makeNpc(world, game, mapId, footSprite, x, y,
                           "GHOSTMON_" .. self.peerId)
    self.footPx, self.footPy = x * 16, y * 16
  end

  self:syncBall(world, game)
  return true
end

-- ---------------------------------------------------------------- movement

function Ghost:setTarget(mapId, x, y, facing)
  self.targetX, self.targetY = x, y
  self.targetFacing = facing
end

function Ghost:setBattling(world, game, battling)
  if self.battling == battling then return end
  self.battling = battling
  self:syncBall(world, game)
end

function Ghost:update(world, game)
  if not self:isSpawned() then return end
  if not (self.targetX and self.targetY) then return end

  -- Did the engine rebuild its lists under us? If so our bodies were dropped
  -- without being destroyed, so we still hold live references to NPCs that
  -- are no longer in the world -- visible to us, invisible on screen. Put
  -- them back rather than waiting for a position message that may be seconds
  -- away, or may never come if the peer is standing still.
  local ow = overworld(world)
  if ow and ow.npcs and self.npcsRef and ow.npcs ~= self.npcsRef then
    local mapId = ow.map and ow.map.id
    if mapId and mapId == self.mapId then
      self:place(world, game, mapId, self.targetX, self.targetY,
                 self.targetFacing, self.bodySprite, self.footSprite)
      self:syncBall(world, game)
    else
      -- A genuine map change; the pool will despawn and re-place us.
      self:despawn(world)
    end
    return
  end

  self:updateBody(world, game)
  self:updateFoot(world)
  self:updateBall(world)
end

function Ghost:updateBody(world, game)
  local npc = self.bodyNpc
  if not npc then return end

  local targetPx, targetPy = self.targetX * 16, self.targetY * 16

  if math.abs(targetPx - self.bodyPx) > BODY_SNAP
     or math.abs(targetPy - self.bodyPy) > BODY_SNAP then
    -- A warp, or we fell badly behind: appear there rather than walk it.
    self.bodyPx, self.bodyPy = targetPx, targetPy
  else
    local gap = math.abs(targetPx - self.bodyPx) + math.abs(targetPy - self.bodyPy)
    local speed = gap > 16 and BODY_CATCHUP or BODY_SPEED
    local moved
    self.bodyPx, self.bodyPy, moved =
      stepToward(self.bodyPx, self.bodyPy, targetPx, targetPy, speed)

    if moved > 0 then
      -- Face the way we are actually travelling, and run the walk cycle off
      -- distance covered so it stays in step with the motion at any speed.
      local dx, dy = targetPx - self.bodyPx, targetPy - self.bodyPy
      if math.abs(dx) > 0 then
        npc.facing = dx > 0 and "right" or "left"
      elseif math.abs(dy) > 0 then
        npc.facing = dy > 0 and "down" or "up"
      end
      self.walkTravel = self.walkTravel + moved
      if self.walkTravel >= WALK_CYCLE then
        self.walkTravel = self.walkTravel - WALK_CYCLE
        self.walkFlip = not self.walkFlip
        npc.stepFlip = not npc.stepFlip
      end
    else
      -- Arrived: stand, and take the facing the peer actually reported.
      self.walkFlip = false
      if self.targetFacing then npc.facing = self.targetFacing end
    end
  end

  -- The cell the body has left is where the follower is headed.
  local cellX = math.floor(self.bodyPx / 16 + 0.5)
  local cellY = math.floor(self.bodyPy / 16 + 0.5)
  if cellX ~= self.x or cellY ~= self.y then
    self.prevX, self.prevY = self.x, self.y
    self.x, self.y = cellX, cellY
  end

  npc.px, npc.py = self.bodyPx, self.bodyPy
  npc.cellX, npc.cellY = self.x, self.y
end

-- The follower drifts toward the cell the body just left, bobbing. No grid
-- step and no walk cycle: all the life is in the easing and the sine.
function Ghost:updateFoot(world)
  local npc = self.footNpc
  if not npc then return end
  if not (self.footPx and self.prevX) then return end

  local targetPx, targetPy = self.prevX * 16, self.prevY * 16

  if math.abs(targetPx - self.footPx) > HOVER_SNAP
     or math.abs(targetPy - self.footPy) > HOVER_SNAP then
    self.footPx, self.footPy = targetPx, targetPy
  else
    self.footPx = self.footPx + (targetPx - self.footPx) * HOVER_EASE
    self.footPy = self.footPy + (targetPy - self.footPy) * HOVER_EASE
  end

  self.bobPhase = self.bobPhase + HOVER_BOB_SPEED
  if self.bobPhase > math.pi * 2 then self.bobPhase = self.bobPhase - math.pi * 2 end

  npc.px = self.footPx
  npc.py = self.footPy - HOVER_LIFT + math.sin(self.bobPhase) * HOVER_BOB
  npc.cellX, npc.cellY = self.prevX, self.prevY

  -- An icon is one frame and ignores this. Supplied 16x96 art has real
  -- standing poses, so pointing it the way it drifts uses them.
  local dx, dy = targetPx - npc.px, targetPy - npc.py
  if math.abs(dx) > 1 or math.abs(dy) > 1 then
    if math.abs(dx) > math.abs(dy) then
      npc.facing = dx > 0 and "right" or "left"
    else
      npc.facing = dy > 0 and "down" or "up"
    end
  end
end

-- ------------------------------------------------------------ battle marker

function Ghost:syncBall(world, game)
  if self.battling and not self.ballNpc and self:isSpawned() then
    self.ballNpc = makeNpc(world, game, self.mapId, BALL_SPRITE,
                           self.x or 0, self.y or 0, "GHOSTBALL_" .. self.peerId)
  elseif not self.battling and self.ballNpc then
    dropNpc(world, self.ballNpc)
    self.ballNpc = nil
  end
end

-- Orbits over the head. The ball sprite is a single frame and the sprite path
-- has no rotation, so the spin IS the orbit -- a small fast circle reads as a
-- ball spinning in place.
function Ghost:updateBall(world)
  local npc = self.ballNpc
  if not npc or not self.bodyPx then return end

  self.spinPhase = self.spinPhase + BALL_SPIN
  if self.spinPhase > math.pi * 2 then self.spinPhase = self.spinPhase - math.pi * 2 end

  npc.px = self.bodyPx + math.cos(self.spinPhase) * BALL_ORBIT
  npc.py = self.bodyPy - BALL_HEIGHT + math.sin(self.spinPhase) * BALL_ORBIT * 0.4
  npc.cellX, npc.cellY = self.x, self.y
end

-- Shared with LocalFollower, which needs exactly the same "draws but is not
-- really there" body for your own Pokemon. Exposed rather than duplicated so
-- there is one place that knows about passable and the two entity lists.
Ghost.spawnPassableNpc = makeNpc
Ghost.despawnNpc = dropNpc

return Ghost
