-- Follower art, from two sources, in priority order.
--
-- 1. BYO per-species art in assets/followers/<species>.png, if you supplied
--    any. Accurate, and yours to source.
--
-- 2. The species' PARTY-MENU ICON, which is already in the ROM for all 151.
--    Icons are archetypes rather than portraits -- the whole Bulbasaur line
--    shows the GRASS icon, Gyarados shows SNAKE -- but every species has one,
--    they are already 16px, and they cost nothing to use.
--
-- Source 2 is what makes followers work out of the box. Gen 1 has no WALKING
-- overworld sprites for Pokemon, which is why a marching follower needed
-- imported art; a HOVERING one needs a single 16x16 image and no facings, and
-- the icon table supplies exactly that for every species in the game.
--
-- Registered with frames = 1, walker = false. That is deliberate: for a
-- non-walker the renderer picks the frame from FACING
-- (SpriteRenderer.STAND = { down = 0, up = 1, left = 2, right = 2 }), not
-- from a clock, so a 2-frame icon declared as 2 frames would swap pose when
-- the follower turned rather than animate. One frame, and the hover comes
-- from motion instead -- see Ghost:updateFoot.

local V = ...

local mod = V.mod
local SPECIES = V.data("species")
local ICONS = V.data("follower_icons")
local RomFollowers = V.require("RomFollowers")

local FollowerSprites = {}

local ART_PREFIX = "GHOSTMON_"
local ROM_PREFIX = "GHOSTROM_"
local ICON_PREFIX = "GHOSTICON_"
local DIR = "assets/followers/"

-- SPECIES keys are data.pokemon's keys: uppercase, underscores for the three
-- awkward ones. Filenames follow the battle-art mod's convention.
--   MR_MIME -> mr-mime.png    NIDORAN_F -> nidoran-f.png
function FollowerSprites.filename(species)
  return (tostring(species):lower():gsub("_", "-")) .. ".png"
end

function FollowerSprites.spriteId(species)
  return ART_PREFIX .. tostring(species)
end

local artRegistered = {}    -- species   -> sprite id (your own PNGs)
local romRegistered = {}    -- species   -> sprite id (shrunk from your ROM)
local iconRegistered = {}   -- archetype -> sprite id (party-menu fallback)

local function register(id, image, frames, walker, trueColor)
  local ok = pcall(function()
    mod.content.sprites:register(id, {
      image = image,
      frames = frames,
      walker = walker,
      -- trueColor claims the sprite's cell out of the shade-remap pass, so
      -- art that already carries its own colours is drawn as authored rather
      -- than flattened to the object palette's greys.
      trueColor = trueColor or nil,
    })
  end)
  return ok
end

-- Registered at mod-load time, from static tables rather than from game.data:
-- the entry chunk runs while the Game facade is still being wired, so nothing
-- here may depend on Data already being present.
-- `romMode`:
--   "on"   generate missing frames from the ROM's battle sprites (default)
--   "off"  skip them; species fall through to their party-menu icon
function FollowerSprites.registerAll(romMode)
  local Assets = require("src.render.Assets")
  local art, rom, icons = 0, 0, 0

  -- 1. BYO per-species art. getInfo, not a read: probing 151 files must not
  -- pull 151 PNGs into memory on every boot.
  --
  -- Registered with frames = 1 like everything else here. Followers hover, so
  -- only a standing pose is ever drawn -- and one frame is safe whether the
  -- file is a 16x16 portrait or an old 16x96 walk sheet, where a 6-frame
  -- declaration over a 16x16 file would quad off the bottom of the image.
  for _, species in ipairs(SPECIES) do
    local full = mod.assets:path(DIR .. FollowerSprites.filename(species))
    if Assets.exists(full) then
      local id = FollowerSprites.spriteId(species)
      if register(id, full, 1, false) then
        artRegistered[species] = id
        art = art + 1
      end
    end
  end

  -- 2. Real per-species art shrunk out of this machine's own ROM dump. Built
  -- once and cached in the save directory, so only the first boot pays.
  if romMode ~= "off" then
    RomFollowers.checkCacheVersion()
    for _, species in ipairs(SPECIES) do
      if not artRegistered[species] then
        local path, isColour = RomFollowers.ensure(Assets, species)
        if path then
          local id = ROM_PREFIX .. species
          if register(id, path, 1, false, isColour) then
            romRegistered[species] = id
            rom = rom + 1
          end
        end
      end
    end
  end

  -- 3. Party-menu icons, one sprite per archetype. These paths start with
  -- assets/generated/, so Assets.resolve routes them through the same
  -- per-version cache lookup the engine's own records use -- which is why a
  -- Yellow-only image (pikachu.png) simply does not resolve under Red and is
  -- skipped rather than breaking the boot.
  for archetype, image in pairs(ICONS.image or {}) do
    if Assets.exists(Assets.resolve and Assets.resolve(image) or image) then
      local id = ICON_PREFIX .. archetype
      if register(id, image, 1, false) then
        iconRegistered[archetype] = id
        icons = icons + 1
      end
    end
  end

  FollowerSprites.artCount = art
  FollowerSprites.romCount = rom
  FollowerSprites.iconCount = icons
  return art, rom, icons
end

-- Which icon archetype a species uses.
--
-- Resolved from LIVE game data when it is there, because the mapping is
-- version-specific: under Yellow, Pikachu uses its own icon, while under Red
-- it falls in with FAIRY. The embedded table is a Red-derived fallback for
-- when data is not reachable yet.
local function archetypeFor(game, species)
  local data = game and game.data
  local mon = data and data.pokemon and data.pokemon[species]
  local dex = mon and mon.dex
  local byDex = data and data.icons and data.icons.byDex
  if dex and byDex and byDex[dex] then return byDex[dex] end
  return (ICONS.archetype or {})[species]
end

-- The sprite id to draw for a species, or nil if there is nothing to draw.
-- `game` is used both to resolve the archetype and to confirm the engine
-- really knows the id before it reaches NPC.new, which asserts rather than
-- returning nil.
function FollowerSprites.spriteFor(game, species)
  if species == nil then return nil end
  local sprites = game and game.data and game.data.sprites
  local function usable(id)
    return id and (not sprites or sprites[id]) and id or nil
  end

  -- Your own art, then the real thing shrunk out of your ROM, then the
  -- archetype icon. Each step is more specific than the one after it.
  return usable(artRegistered[species])
      or usable(romRegistered[species])
      or usable(iconRegistered[archetypeFor(game, species)])
      or nil
end

function FollowerSprites.has(species)
  return artRegistered[species] ~= nil
end

return FollowerSprites
