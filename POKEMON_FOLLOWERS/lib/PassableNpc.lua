-- A body that draws but is not really there.
--
-- The engine's own trick, from its port of Yellow's pikachu_follow.asm: an
-- NPC-shaped entity in the list the world DRAWS, and never in the list that
-- answers questions about it. That is the whole of what makes a follower
-- free -- no collision, no A-press, no trainer sighting, no per-frame update.
--
-- ------- why this is duplicated
--
-- COUCH MULTIPLAYER has the same forty lines inside its Ghost module, and
-- said so in a comment: "exposed rather than duplicated so there is one place
-- that knows about passable and the two entity lists."
--
-- That was correct while they were one mod. They are two now, each installable
-- without the other, and a shared file cannot span two mod directories. The
-- alternatives are worse: exporting this from here would make co-op depend on
-- an art mod, and exporting it from there would make the art mod depend on
-- co-op. Either way the thing that is optional stops being optional.
--
-- So it is copied, knowingly. If the passable/entity-list contract ever
-- changes upstream, BOTH copies need the change -- this comment is the only
-- thing that will remind anyone.

local V = ...

local PassableNpc = {}

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

function PassableNpc.spawn(world, game, mapId, sprite, x, y, name)
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

  -- ENTITIES ONLY, deliberately not ow.npcs.
  --
  -- entities is the list the world DRAWS (OverworldController's y-sorted draw
  -- loop) and the list Collision.occupied walks -- and occupied honours
  -- `passable`, so we are drawn and never block.
  --
  -- npcs is a different job: it is what npcAtCell searches when you press A,
  -- what pushableAtCell searches for boulders, what the trainer-sighting scan
  -- walks, and what gets npc:update called on it every frame. npcAtCell
  -- ignores `passable` entirely, so a follower in that list would answer your
  -- A press with no script behind it. None of those jobs should ever find a
  -- follower, so a follower is simply not in that list.
  if ow.entities then table.insert(ow.entities, npc) end
  return npc
end

function PassableNpc.despawn(world, npc)
  if not npc then return end
  local ow = overworld(world)
  if not ow then return end
  removeFrom(ow.npcs, npc)
  removeFrom(ow.entities, npc)
end

return PassableNpc
