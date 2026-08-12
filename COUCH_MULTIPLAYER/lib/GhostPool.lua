-- Every remote player, and their lifecycle against MY map.
--
-- The rule that keeps this simple: a ghost exists only while that player is
-- standing on the same map as me. Different map -> despawned entirely, not
-- hidden. So there is no bookkeeping for maps I am not looking at, nothing to
-- reconcile when I warp, and no way for a stale ghost to survive somewhere I
-- cannot see it.
--
-- Nothing here writes to my save, my party, my flags or my scripts. A peer
-- can move a decorative NPC around my screen and that is the entire blast
-- radius, which is what "ghosts, no interactions" should mean at the level of
-- what the code is even able to do.

local V = ...

local Ghost = V.require("Ghost")

local GhostPool = {}
GhostPool.__index = GhostPool

-- A player who has said nothing for this long is treated as gone. Footsteps
-- only arrive when someone moves, so this has to be well clear of "standing
-- still reading a sign"; the keepalive in Presence keeps it honest.
local TIMEOUT = 30

local MAX_SLOTS = 8

function GhostPool.new(opts)
  return setmetatable({
    ghosts = {},          -- peerId -> Ghost
    slots = {},           -- slot number -> peerId
    bodySprite = (opts and opts.bodySprite) or "SPRITE_BLUE",
    followers = (opts and opts.followers) ~= false,
    marker = (opts and opts.marker) ~= false,
    -- INJECTED, and allowed to be nil. The art lives in POKEMON FOLLOWERS
    -- now, which may not be installed; this pool does not know or care where
    -- a sprite id comes from, only that something can answer the question.
    spriteFor = (opts and opts.spriteFor) or nil,
    myMapId = nil,
  }, GhostPool)
end

-- The follower sprite for a peer, or nil when followers are switched off, no
-- art mod is installed, or the species has no art and no icon. Ghost:place
-- takes a nil footSprite happily, so all three end the same way: a player
-- with nothing hovering behind them.
function GhostPool:footSpriteFor(game, species)
  if not self.followers then return nil end
  if not self.spriteFor then return nil end
  return self.spriteFor(game, species)
end

-- The body a peer asked to be drawn as, if this build actually has it.
-- Ghost:place refuses to build an NPC from an unknown sprite id (NPC.new
-- asserts on one), so an unrecognised name has to become a real one here or
-- that player would simply be invisible.
local FALLBACK_BODY = "SPRITE_BLUE"

function GhostPool:bodySpriteFor(game, ghost)
  local sprites = game and game.data and game.data.sprites
  local wanted = ghost and ghost.sprite
  if wanted and (not sprites or sprites[wanted]) then return wanted end
  if not sprites or sprites[FALLBACK_BODY] then return FALLBACK_BODY end
  return self.bodySprite
end

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.time()
end

function GhostPool:claimSlot(peerId)
  for slot, owner in pairs(self.slots) do
    if owner == peerId then return slot end
  end
  for slot = 1, MAX_SLOTS do
    if self.slots[slot] == nil then
      self.slots[slot] = peerId
      return slot
    end
  end
  return nil  -- more players than slots; ignore the newcomer
end

function GhostPool:releaseSlot(peerId)
  for slot, owner in pairs(self.slots) do
    if owner == peerId then self.slots[slot] = nil end
  end
end

function GhostPool:get(peerId, info)
  local g = self.ghosts[peerId]
  if g then
    if info then
      if info.name then g.name = info.name end
      if info.sprite then g.sprite = info.sprite end
      if info.species ~= nil then g.species = info.species end
    end
    g.lastSeen = now()
    return g
  end
  local slot = self:claimSlot(peerId)
  if not slot then return nil end
  g = Ghost.new(peerId, slot, info)
  g.lastSeen = now()
  self.ghosts[peerId] = g
  return g
end

function GhostPool:drop(world, peerId)
  local g = self.ghosts[peerId]
  if not g then return end
  g:despawn(world)
  self.ghosts[peerId] = nil
  self:releaseSlot(peerId)
end

function GhostPool:dropAll(world)
  for peerId in pairs(self.ghosts) do
    local g = self.ghosts[peerId]
    if g then g:despawn(world) end
  end
  self.ghosts = {}
  self.slots = {}
end

-- My own map changed: every ghost's body belongs to the map it was spawned
-- on, so they all go. Whoever is on the new map re-spawns on their next
-- position message, which arrives within a step.
function GhostPool:onMapChanged(world, mapId)
  self.myMapId = mapId
  for _, g in pairs(self.ghosts) do
    g:despawn(world)
  end
end

-- --------------------------------------------------------------- messages

function GhostPool:handle(world, game, msg)
  local t = msg.t

  if t == "peer_lost" then
    -- A socket died. The transport names the ids whose messages were arriving
    -- on it, so this can be a real drop rather than the nudge-to-recheck it
    -- used to be.
    --
    -- This is the path for a CRASH or a pulled cable, where no bye is
    -- possible. A clean quit sends one and is handled above; both exist
    -- because either alone leaves a case where somebody stands frozen in
    -- another player's world.
    for _, id in ipairs(msg.ids or {}) do
      self:drop(world, id)
    end
    return
  end

  if t == "bye" then
    self:drop(world, msg.id)
    return
  end

  if t == "hello" then
    self:get(msg.id, { name = msg.name, sprite = msg.sprite, species = msg.species })
    return
  end

  if t == "party" then
    local g = self.ghosts[msg.id]
    if g then
      g.species = msg.species
      -- Re-place so the follower picks up the new sprite, but only if the
      -- ghost is actually on screen right now.
      if g:isSpawned() then
        g:place(world, game, g.mapId, g.x, g.y, g.facing,
                self:bodySpriteFor(game, g),
                self:footSpriteFor(game, g.species))
      end
    end
    return
  end

  if t == "state" then
    -- Recorded even for a peer with no body yet: they may be on another map,
    -- and the marker has to be right the moment they walk back onto mine.
    local g = self:get(msg.id)
    if g and self.marker then g:setBattling(world, game, msg.battling) end
    return
  end

  if t ~= "pos" then return end

  local g = self:get(msg.id)
  if not g then return end

  -- Not on my map: nothing to draw.
  if msg.map ~= self.myMapId then
    if g:isSpawned() then g:despawn(world) end
    return
  end

  if not g:isSpawned() then
    g:place(world, game, msg.map, msg.x, msg.y, msg.f,
            self:bodySpriteFor(game, g), self:footSpriteFor(game, g.species))
  else
    g:setTarget(msg.map, msg.x, msg.y, msg.f)
  end
end

-- ----------------------------------------------------------------- ticking

-- Make a spawned ghost's art match what we now know about that player.
--
-- Species arrives in `hello` and `party`, but a ghost is BUILT on `pos` --
-- and those race. If pos wins, the body is built with species = nil and
-- therefore no follower, and the later hello updates the field without
-- rebuilding anything, so that player's Pokemon never appears. Which side
-- loses the race is pure timing, which is why it showed up on one screen and
-- not the other.
--
-- Reconciling here fixes every ordering rather than the one that was
-- reported: whatever we know now is what gets drawn. It settles immediately,
-- because after a re-place the sprites match and the comparison stops firing.
function GhostPool:reconcile(world, game, g)
  if not g:isSpawned() then return end
  local wantBody = self:bodySpriteFor(game, g)
  local wantFoot = self:footSpriteFor(game, g.species)
  if wantBody == g.bodySprite and wantFoot == g.footSprite then return end
  g:place(world, game, g.mapId, g.x, g.y, g.facing, wantBody, wantFoot)
end

function GhostPool:update(world, game)
  local cutoff = now() - TIMEOUT
  local stale = nil
  for peerId, g in pairs(self.ghosts) do
    if (g.lastSeen or 0) < cutoff then
      stale = stale or {}
      stale[#stale + 1] = peerId
    else
      self:reconcile(world, game, g)
      g:update(world, game)
    end
  end
  if stale then
    for _, peerId in ipairs(stale) do self:drop(world, peerId) end
  end
end

function GhostPool:count()
  local n = 0
  for _ in pairs(self.ghosts) do n = n + 1 end
  return n
end

-- How many are actually standing in the world right now, and a short
-- description of each. Known peers minus spawned bodies is the interesting
-- number when someone reports not seeing anybody.
function GhostPool:describe()
  local total, spawned, parts = 0, 0, {}
  for id, g in pairs(self.ghosts) do
    total = total + 1
    if g:isSpawned() then spawned = spawned + 1 end
    local px = g.bodyNpc and g.bodyNpc.px
    local py = g.bodyNpc and g.bodyNpc.py
    parts[#parts + 1] = ("%s@%s cell(%s,%s) px(%s,%s)%s"):format(
      id, tostring(g.mapId or "-"), tostring(g.x or "-"), tostring(g.y or "-"),
      px and math.floor(px) or "-", py and math.floor(py) or "-",
      g:isSpawned() and "" or " NOT-SPAWNED")
  end
  return total, spawned, table.concat(parts, " ")
end

return GhostPool
