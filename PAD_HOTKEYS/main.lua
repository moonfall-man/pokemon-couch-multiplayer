-- PAD HOTKEYS: reach the display hotkeys from a controller.
--
-- The engine's display toggles -- and every mod pipeline that claims a digit,
-- including the voxel mod's VOXEL / V-GRID / T-SHIFT / V-CURVE / 3D-BTL /
-- WATER ladders -- are keyboard digits. On a couch with two pads and nobody
-- near the keyboard, that means the one thing you actually want to fiddle
-- with while playing is the one thing you cannot reach.
--
-- So: bind them to pad buttons the engine leaves free.
-- GamepadMap.DEFAULT_GAMEPAD_BINDINGS claims only dpad, a, b, start and back;
-- Game:gamepadpressed additionally takes the shoulders and triggers for GAME
-- SPEED, and Select+face for the display chords. That leaves the two STICK
-- CLICKS (L3/R3) and the X/Y face buttons genuinely unbound, which is what
-- these rows offer.
--
-- Implemented by POLLING rather than by intercepting gamepadpressed: the
-- engine's pad path is a chain of special cases that a mod wrapping it would
-- have to replicate, whereas isGamepadDown asks the question directly and
-- cannot swallow an event the game needed.

local mod = ...

-- Buttons the engine does not already use for something.
local BUTTONS = {
  { key = "leftstick",  label = "L-STICK",  default = "3" },
  { key = "rightstick", label = "R-STICK",  default = "9" },
  { key = "x",          label = "PAD X",    default = "off" },
  { key = "y",          label = "PAD Y",    default = "off" },
}

-- What each digit reaches. 1-5 are the engine's own; a mod render pipeline
-- claims its digit last, so with the voxel mod installed 3 and 5 are its
-- VOXEL and V-GRID rather than TILT and GBC FX.
local CHOICES = {
  { "OFF", "off" },
  { "1 SPEED", "1" },
  { "2 COLORS", "2" },
  { "3 VOXEL", "3" },
  { "4 ZOOM", "4" },
  { "5 V-GRID", "5" },
  { "6 T-SHIFT", "6" },
  { "7 V-CURVE", "7" },
  { "8 3D-BTL", "8" },
  { "9 WATER", "9" },
}

local schema = {}
for i, b in ipairs(BUTTONS) do
  schema[i] = {
    key = b.key, type = "choice", label = b.label, default = b.default,
    choices = CHOICES,
    description = "Which display hotkey this button fires. The labels assume "
      .. "the voxel mod is installed; without it, 3 is TILT and 5 is GBC FX.",
  }
end
mod.options:define(schema)

-- ------- pad ownership
--
-- In split screen every process sees every pad, so a poll has to ask the same
-- question the event path asks: is this the pad THIS window owns?  Absent (no
-- PAD_OWNER installed), every pad counts, which is stock single-player
-- behaviour and the right default -- a missing filter must never mean a dead
-- button.
--
-- Resolved LAZILY and re-tried until it lands, rather than looked up once at
-- load.  mod.find returns nil for a mod that has not run yet, and while the
-- optional_dependency in the manifest orders PAD_OWNER ahead of this one, a
-- lookup that silently degrades to "every pad" on a load-order accident is
-- exactly the kind of bug that only shows up on someone else's machine.  Ask
-- again next frame instead of remembering a nil.
local PadOwner

local function resolveOwner()
  if PadOwner then return PadOwner end

  -- the mod, which is where it lives now
  local ok, handle = pcall(mod.find, mod, "PAD_OWNER")
  if ok and handle and handle.exports and handle.exports.owns then
    PadOwner = handle.exports
    return PadOwner
  end

  -- a legacy engine-patched build, where it was spliced into src/core/
  local okReq, m = pcall(require, "src.core.PadOwner")
  if okReq and type(m) == "table" and m.owns then
    PadOwner = m
    return PadOwner
  end

  return nil
end

local function owned(js)
  local owner = resolveOwner()
  if not owner then return true end
  local ok, yes = pcall(owner.owns, js)
  return ok and yes
end

-- ------- polling

local held = {}   -- button -> was down last step

local function joysticks()
  if not (love and love.joystick and love.joystick.getJoysticks) then return {} end
  local ok, list = pcall(love.joystick.getJoysticks)
  if ok and type(list) == "table" then return list end
  return {}
end

local function isDown(button)
  for _, js in ipairs(joysticks()) do
    if owned(js) and js.isGamepadDown then
      local ok, down = pcall(function() return js:isGamepadDown(button) end)
      if ok and down then return true end
    end
  end
  return false
end

mod.hooks:wrap("input.step", function(next, game, dt)
  next(game, dt)
  if not game or not game.keypressed then return end

  for _, b in ipairs(BUTTONS) do
    local digit = mod.options:get(b.key)
    local down = (digit and digit ~= "off") and isDown(b.key) or false

    -- Rising edge only: these are cycles, and a held stick click must not
    -- run the ladder round and round.
    if down and not held[b.key] then
      pcall(function() game:keypressed(digit) end)
    end
    held[b.key] = down
  end
end)

mod.exports.version = "0.1.0"
mod.exports.buttons = BUTTONS
-- Whoever is currently answering the ownership question, or nil for "nobody,
-- so every pad counts". Exported so the split-screen setup can be verified
-- from outside rather than inferred from a button that did not do anything.
mod.exports.padOwner = resolveOwner
