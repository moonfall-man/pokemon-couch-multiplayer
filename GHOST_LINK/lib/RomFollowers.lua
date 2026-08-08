-- Real per-species followers, built from YOUR OWN cartridge data.
--
-- The party-menu icons are archetypes: the whole Bulbasaur line shows one
-- plant. But the game already extracted a front battle sprite for all 151
-- species out of your ROM on first boot --
--
--     assets/generated/battle/front/<name>.png     40x40 .. 56x56
--
-- -- and because a follower HOVERS, it needs exactly one 16x16 frame. No walk
-- cycle, no facings. Shrinking a battle sprite into one readable pose is a
-- far smaller ask than inventing six walking frames for a creature the games
-- never animated walking, which is what made per-species followers look
-- impossible earlier.
--
-- So this reads them, shrinks them, and writes 16x16 PNGs into the save
-- directory, where the sprite registry can point at them like any other file.
-- Nothing is downloaded and nothing is redistributed: the input is the dump
-- already sitting on this machine.
--
-- Done once and cached. A later boot finds the files and only pays for the
-- getInfo checks.

local V = ...

local RomFollowers = {}

local CELL = 16
local SRC_DIR = "assets/generated/battle/front/"
local ROOT_DIR = "ghostlink/followers/"

-- Bumped whenever the generator's output changes, so an old cache is thrown
-- away instead of leaving everyone looking at last version's sprites.
local CACHE_VERSION = "4-alpha-pad"
local STAMP = ROOT_DIR .. ".version"

-- ------------------------------------------------------- where a frame lives
--
-- The path carries BOTH facts the caller would otherwise have to guess:
-- which game the art came from, and whether it is colour or DMG grey.
--
--   ghostlink/followers/red/pikachu.png          colour, trueColor = true
--   ghostlink/followers/red/pikachu.dmg.png      four greys over white
--
-- Both were real bugs, and both were the same bug: a cache that does not
-- record what it is forces whoever reads it to re-derive that from today's
-- state, which is not necessarily the state it was written under.
--
--   * The frames are generated from assets/generated, which is per version --
--     so a cache shared across Red, Blue and Yellow served Red's art to all
--     three.
--   * ensure() asked paletteFor() whether this species has colour and then
--     returned a file that may predate the answer. If the palette table was
--     unreachable on the boot that wrote the file but reachable now, a grey
--     frame on a WHITE background got registered as trueColor -- and a
--     trueColor sprite skips the shade bake, which is the only thing that
--     would have keyed that white away. The result is a solid white 16x16
--     block following you around.
local function versionKey()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if ok and GameVersion and GameVersion.get then
    local okGet, v = pcall(GameVersion.get)
    if okGet and type(v) == "string" and v ~= "" then return v end
  end
  return "red"
end

local function outDir()
  return ROOT_DIR .. versionKey() .. "/"
end

-- The 4 DMG shades. Index 1 is the background: SpriteRenderer keys near-white
-- (red > 0.83) to transparent, so the padding has to end up white rather than
-- alpha-0 or it will not be keyed at all.
local SHADES = {
  { 1.00, 1.00, 1.00 },
  { 0.66, 0.66, 0.66 },
  { 0.35, 0.35, 0.35 },
  { 0.00, 0.00, 0.00 },
}

local BG_LUM = 0.83   -- at or above this is background

local function lum(r, g, b) return 0.299 * r + 0.587 * g + 0.114 * b end

-- Only three of the four shades are used in the output, on purpose.
--
-- Gen 1 shades with DITHER -- checkerboards of two tones, because the Game
-- Boy had four shades and no blending. At this reduction a dither pattern
-- averages to a mid-tone, and spreading those mid-tones back across four
-- levels turns them into speckle: the result reads as noise with a creature
-- somewhere inside it. Collapsing the middle onto ONE flat body tone throws
-- the dither away and keeps what actually carries the shape at 16px -- the
-- solid outline and the silhouette it encloses.

-- ROM-derived filenames are not perfectly regular: MR_MIME lands as
-- "mr.mime.png" while NIDORAN_F lands as "nidoranf.png". Probe rather than
-- assume, and let a miss fall back to the icon.
local function candidates(species)
  local low = species:lower()
  return {
    (low:gsub("_", "")),
    (low:gsub("_", ".")),
    (low:gsub("_", "-")),
    low,
  }
end

local function sourcePath(Assets, species)
  for _, name in ipairs(candidates(species)) do
    local path = SRC_DIR .. name .. ".png"
    local resolved = Assets.resolve and Assets.resolve(path) or path
    if Assets.exists(resolved) then return resolved end
  end
  return nil
end

-- isColour picks the suffix, so the file names its own mode.
function RomFollowers.outputPath(species, isColour)
  local base = outDir() .. species:lower():gsub("_", "-")
  return base .. (isColour and ".png" or ".dmg.png")
end

-- ------------------------------------------------------------ real colour
--
-- The battle sprites are four DMG shades; their COLOUR lives in the palette
-- tables the ROM import also extracted:
--
--   palettes.pokemon[SPECIES] -> "GREENMON"
--   palettes.palettes.GREENMON -> four RGB triples, lightest first
--
-- Which is how a follower stops being a grey smudge. At 16px, colour carries
-- more identity than shape does -- a green blob reads as Bulbasaur long before
-- its silhouette does.
--
-- Read from Data directly rather than through `game`, because this runs in the
-- entry chunk while the Game facade is still being wired. Data:load() has
-- already happened by then; mods load after it.
function RomFollowers.paletteFor(species)
  local ok, Data = pcall(require, "src.core.Data")
  if not ok or not Data then return nil end
  local p = Data.palettes
  local name = p and p.pokemon and p.pokemon[species]
  local colours = name and p.palettes and p.palettes[name]
  if type(colours) ~= "table" or #colours < 4 then return nil end
  for i = 1, 4 do
    local c = colours[i]
    if type(c) ~= "table" or #c < 3 then return nil end
  end
  return colours
end

-- ------------------------------------------------------------- the shrink

-- Bounding box of the creature, so the fixed padding Gen 1 sprites carry does
-- not eat the output resolution.
--
-- Keyed on ALPHA alone. Brightness would be wrong: opaque white is a real
-- sprite colour here (highlights, eyes, pale bellies), so a luminance test
-- would crop a white-tipped tail or ear straight off the edge of the box.
local function contentBox(data)
  local w, h = data:getDimensions()
  local left, top, right, bottom = w, h, -1, -1
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local _, _, _, a = data:getPixel(x, y)
      if a > 0 then
        if x < left then left = x end
        if x > right then right = x end
        if y < top then top = y end
        if y > bottom then bottom = y end
      end
    end
  end
  if right < 0 then return nil end
  return left, top, right - left + 1, bottom - top + 1
end

-- Downsample by COVERAGE, not by colour average.
--
-- The extracted sprites are the four DMG shades (0 / 85 / 170 / 255) over
-- REAL ALPHA padding. Averaging colour across that gets two things wrong at
-- once: transparent padding bleeds into the creature as mid-grey, and the
-- sprite's own opaque WHITE -- which Gen 1 uses for highlights, eyes and pale
-- bellies -- averages toward the background and then gets keyed away by the
-- renderer, punching holes in the middle of the mon.
--
-- So each output pixel asks two questions of its source footprint:
--   how much of it is actually the creature (opaque)?      -> silhouette
--   and how dark is the creature part of it?               -> outline vs body
-- Padding never contributes a colour, only an absence.
--
-- Returns two arrays, coverage and luminance, indexed oy * outW + ox.
local function sample(data, bx, by, bw, bh, outW, outH)
  local coverage, luminance = {}, {}
  local sx, sy = bw / outW, bh / outH
  for oy = 0, outH - 1 do
    for ox = 0, outW - 1 do
      local x0 = bx + math.floor(ox * sx)
      local y0 = by + math.floor(oy * sy)
      local x1 = math.max(x0 + 1, bx + math.floor((ox + 1) * sx))
      local y1 = math.max(y0 + 1, by + math.floor((oy + 1) * sy))
      local opaque, total, lumSum = 0, 0, 0
      for y = y0, math.min(y1 - 1, by + bh - 1) do
        for x = x0, math.min(x1 - 1, bx + bw - 1) do
          local r, g, b, a = data:getPixel(x, y)
          total = total + 1
          if a > 0 then
            opaque = opaque + 1
            lumSum = lumSum + lum(r, g, b)
          end
        end
      end
      local i = oy * outW + ox
      coverage[i] = total > 0 and (opaque / total) or 0
      luminance[i] = opaque > 0 and (lumSum / opaque) or 1
    end
  end
  return coverage, luminance
end

-- Below this share of opaque source pixels an output pixel is background.
-- Low enough to keep thin tails and ears, high enough that the fringe around
-- a silhouette does not smear outward into a halo.
local COVERAGE = 0.34

-- Interior split between the lit body and its shading.
local SHADING = 0.52

-- Build one 16x16 follower frame, or nil.
--
-- With a `palette` the output is REAL COLOUR with a transparent background,
-- and the caller must register the sprite with trueColor = true -- a
-- trueColor sprite skips the OBP bake, and the bake is where near-white would
-- otherwise have been keyed to alpha. Without one it falls back to the four
-- DMG greys over white, which the bake keys as usual.
function RomFollowers.build(Assets, species, palette)
  local src = sourcePath(Assets, species)
  if not src then return nil end

  local ok, data = pcall(love.image.newImageData, src)
  if not ok or not data then return nil end

  local bx, by, bw, bh = contentBox(data)
  if not bx then return nil end

  -- Fit inside the cell, preserving aspect.
  local scale = math.min(CELL / bw, CELL / bh)
  local outW = math.max(1, math.floor(bw * scale + 0.5))
  local outH = math.max(1, math.floor(bh * scale + 0.5))
  if outW > CELL then outW = CELL end
  if outH > CELL then outH = CELL end

  local coverage, luminance = sample(data, bx, by, bw, bh, outW, outH)

  -- THE BACKGROUND MUST MATCH THE MODE.
  --
  -- Only one of outW/outH can be CELL -- the scale is min(CELL/bw, CELL/bh) --
  -- so unless the creature's bounding box is exactly square, the frame has
  -- padding: a bar across the top for a wide mon (bottom-aligned), bars down
  -- both sides for a tall one.
  --
  -- Filling that padding with opaque white unconditionally was correct for
  -- exactly one of the two output modes. The DMG path is drawn over white and
  -- the renderer's shade bake keys near-white to alpha, so white padding
  -- disappears. The COLOUR path sets trueColor, which claims the sprite out of
  -- that bake -- so nothing ever keyed the white, and it stayed: a solid white
  -- slab wrapped around the mon on every species whose sprite is not square.
  -- That is most of them.
  --
  -- So the fill is the same background the body loop uses below, chosen once
  -- here rather than assumed.
  local function background()
    if palette then return 0, 0, 0, 0 end   -- real transparency
    return 1, 1, 1, 1                       -- white, keyed by the bake
  end

  -- Bottom-aligned and centred: a tall mon should stand on the ground rather
  -- than float with its feet cropped.
  local cell = love.image.newImageData(CELL, CELL)
  do
    local br, bg, bb, ba = background()
    for y = 0, CELL - 1 do
      for x = 0, CELL - 1 do cell:setPixel(x, y, br, bg, bb, ba) end
    end
  end

  -- The OUTLINE is drawn from the silhouette, not from brightness.
  --
  -- Shrinking a Gen 1 sprite loses its drawn outline: a 1px black border
  -- averaged 3.5x down becomes a grey suggestion, and thresholding it back
  -- gives a broken, dotted edge. But we already know the exact silhouette --
  -- it is the coverage map -- so the border can be RE-DRAWN at full strength
  -- instead of recovered. Any covered pixel touching an uncovered one is
  -- outline; everything inside is shaded by its own brightness.
  --
  -- That is what buys back the detail: a crisp black edge carries the shape,
  -- which frees the interior to use two tones for form rather than spending
  -- its contrast redescribing where the creature ends.
  local function covered(x, y)
    if x < 0 or y < 0 or x >= outW or y >= outH then return false end
    return coverage[y * outW + x] >= COVERAGE
  end

  -- Shade 1 of a GBC mon palette is its near-white; the creature itself is
  -- drawn in shades 2..4. So the three tones map straight across, and the
  -- background becomes real transparency rather than a colour at all.
  local function tone(n)
    if not palette then return SHADES[n][1], SHADES[n][2], SHADES[n][3], 1 end
    local c = palette[n]
    return c[1] / 255, c[2] / 255, c[3] / 255, 1
  end

  local offX = math.floor((CELL - outW) / 2)
  local offY = CELL - outH
  for y = 0, outH - 1 do
    for x = 0, outW - 1 do
      local i = y * outW + x
      local r, g, b, a
      if not covered(x, y) then
        r, g, b, a = background()
      elseif not (covered(x - 1, y) and covered(x + 1, y)
                  and covered(x, y - 1) and covered(x, y + 1)) then
        r, g, b, a = tone(4)                            -- re-drawn outline
      elseif luminance[i] < SHADING then
        r, g, b, a = tone(3)                            -- shaded interior
      else
        r, g, b, a = tone(2)                            -- lit interior
      end
      cell:setPixel(offX + x, offY + y, r, g, b, a)
    end
  end
  return cell
end

-- ------------------------------------------------------------- generation

-- A cached frame for `species`, or nil. Returns path, isColour.
--
-- The mode comes from WHICH FILE EXISTS, never from asking paletteFor() again:
-- the file on disk was written under whatever was true at the time, and the
-- only honest way to describe it is to read its name.
function RomFollowers.cached(species)
  for _, isColour in ipairs({ true, false }) do
    local path = RomFollowers.outputPath(species, isColour)
    if love.filesystem.getInfo(path) then return path, isColour end
  end
  return nil
end

-- Ensure a follower PNG exists for `species`.
-- Returns path, isColour -- or nil. Cached on disk, so this is one or two
-- getInfo calls on every boot after the first.
function RomFollowers.ensure(Assets, species)
  local hit, hitColour = RomFollowers.cached(species)
  if hit then return hit, hitColour end

  local palette = RomFollowers.paletteFor(species)
  local out = RomFollowers.outputPath(species, palette ~= nil)

  local cell = RomFollowers.build(Assets, species, palette)
  if not cell then return nil end

  love.filesystem.createDirectory(outDir())
  local okEnc = pcall(function() cell:encode("png", out) end)
  if not okEnc then return nil end
  if not love.filesystem.getInfo(out) then return nil end
  return out, palette ~= nil
end

-- Throw the whole cache away when the generator's output has changed shape,
-- so a version bump does not leave everyone staring at last version's art.
--
-- The stamp is at the root and the frames are per game version, deliberately:
-- a generator change invalidates Red, Blue and Yellow alike, and clearing all
-- three is what stops a Blue playthrough from quietly keeping frames this
-- version of the code would no longer produce.
function RomFollowers.checkCacheVersion()
  local stamp = love.filesystem.read(STAMP)
  if stamp == CACHE_VERSION then return false end
  RomFollowers.clear()
  love.filesystem.createDirectory(ROOT_DIR)
  love.filesystem.createDirectory(outDir())
  love.filesystem.write(STAMP, CACHE_VERSION)
  return true
end

-- Build every species that does not already have a cached frame.
-- Returns written, reused, missing.
function RomFollowers.generateAll(Assets, speciesList)
  local written, reused, missing = 0, 0, 0
  for _, species in ipairs(speciesList) do
    if RomFollowers.cached(species) then
      reused = reused + 1
    else
      local made = RomFollowers.ensure(Assets, species)
      if made then written = written + 1 else missing = missing + 1 end
    end
  end
  return written, reused, missing
end

-- Throw the cache away, so a version switch or a changed ROM regenerates.
-- Walks every version's folder, not just the current one.
function RomFollowers.clear()
  local function purge(dir)
    for _, name in ipairs(love.filesystem.getDirectoryItems(dir) or {}) do
      local path = dir .. name
      local info = love.filesystem.getInfo(path)
      if info and info.type == "directory" then
        purge(path .. "/")
        love.filesystem.remove(path)
      else
        love.filesystem.remove(path)
      end
    end
  end
  purge(ROOT_DIR)
  love.filesystem.remove(STAMP)
end

return RomFollowers
