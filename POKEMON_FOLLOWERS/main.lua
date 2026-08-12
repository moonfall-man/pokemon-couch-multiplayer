-- POKEMON FOLLOWERS: your lead Pokemon hovers behind you, all 151 species.
--
-- Gen 1 has NO walking overworld sprites for Pokemon. The ROM carries 73
-- character sheets -- people, mostly -- and, in Yellow only, SPRITE_PIKACHU.
-- Every other species has front and back battle art and nothing else.
--
-- So followers HOVER rather than walk. That is not a stylistic choice, it is
-- what makes all 151 possible: a hovering thing needs one 16x16 frame and no
-- facings, where a walking one needs six frames across four directions. The
-- art is generated on first boot by shrinking the front battle sprites the
-- game already extracted from YOUR OWN cartridge dump, coloured with the
-- game's own per-species palettes. Nothing is downloaded and nothing is
-- redistributed.
--
-- The engine's own Pikachu is the pattern being borrowed: an NPC-shaped
-- entity that lives in ow.npcs but never in ow.entities, so it draws and
-- animates without blocking anyone.
--
-- ------- why this is its own mod
--
-- It began inside COUCH MULTIPLAYER, because a ghost of another player wants
-- a Pokemon behind it. But it needs no network, no second window and no
-- second controller -- it is worth having on its own, playing alone -- and a
-- co-op mod that also ships a sprite generator is two things wearing one
-- manifest.
--
-- The two still compose: this publishes spriteFor through mod.exports, and
-- COUCH MULTIPLAYER asks for it by name. Install both and other players'
-- Pokemon follow them too; install either alone and it stands up by itself.

local mod = ...

-- ------- the mod namespace
--
-- lib modules load through V rather than package.path: a mod directory is not
-- on it, and may live inside a mounted archive plain require cannot open.

local V = { mod = mod, path = mod.path }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("POKEMON_FOLLOWERS: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("POKEMON_FOLLOWERS: %s did not compile: %s"):format(rel, tostring(err)), 0)
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

local FollowerSprites = V.require("FollowerSprites")
local LocalFollower = V.require("LocalFollower")

-- ------- options

mod.options:define({
  { key = "mymon", type = "toggle", label = "MY MON", default = true,
    description = "Your own lead Pokemon hovers behind you on your own "
      .. "screen. Needs nothing else -- no network, no second player." },
  { key = "romart", type = "toggle", label = "MON ART", default = true,
    description = "Build real per-species followers by shrinking the battle "
      .. "sprites this game extracted from your own ROM. OFF uses the "
      .. "party-menu icons instead, which are shared archetypes rather than "
      .. "one look per species. Takes effect next launch." },
})

local function opt(key)
  local ok, v = pcall(function() return mod.options:get(key) end)
  if ok then return v end
  return nil
end

-- ------- sprite registration
--
-- MON ART is read HERE and not at session start: registering sprites is a
-- load-time phase and cannot be redone later, so deferring it would mean the
-- setting never took effect until the next launch anyway. The loader folds
-- saved options in before any entry chunk runs, so the stored value is
-- already available; a failure to read it defaults to on.
local romMode = (opt("romart") == false) and "off" or "on"

local supplied, fromRom, icons = FollowerSprites.registerAll(romMode)

local function log(fmt, ...)
  pcall(mod.log.info, mod.log, fmt, ...)
end
log("followers: %d supplied, %d from ROM, %d icon archetypes", supplied, fromRom, icons)

-- ------- what other mods can use
--
-- One function, deliberately. COUCH MULTIPLAYER needs to answer exactly one
-- question -- "what does this species look like as a follower" -- and every
-- other detail here is this mod's business. A narrow export is a narrow
-- promise to keep.
mod.exports.spriteFor = function(game, species)
  return FollowerSprites.spriteFor(game, species)
end

-- Counts, so a co-op session's status dump can report where the art came from
-- without reaching into this mod's internals.
mod.exports.counts = function()
  return { supplied = supplied, rom = fromRom, icons = icons }
end

mod.exports.version = 1

-- ------- your own follower

local localFollower = LocalFollower.new()

-- No teardown handlers for the title screen or a blackout, deliberately.
-- update() already despawns whenever there is no overworld, no map, no
-- player, no party or no art -- and re-places itself when the engine rebuilds
-- ow.npcs underneath it, which is exactly what returning to the title does.
-- Adding save.loaded/world.blacked_out here would be a second mechanism for a
-- job that already has one.
mod.hooks:wrap("input.step", function(next, game, dt)
  next(game, dt)
  local world = mod.world
  pcall(function()
    localFollower:update(world, game, FollowerSprites.spriteFor, opt("mymon") ~= false)
  end)
end)
