-- Reach the display hotkeys from a controller.
--
-- The engine's display toggles -- and every mod pipeline that claims a digit,
-- including the voxel mod's VOXEL / V-GRID / T-SHIFT / V-CURVE / 3D-BTL /
-- WATER ladders -- are keyboard digits. On a couch with two pads and nobody
-- near the keyboard, the one thing you actually want to fiddle with while
-- playing is the one thing you cannot reach.
--
-- So: bind them to pad buttons the engine leaves free.
-- GamepadMap.DEFAULT_GAMEPAD_BINDINGS claims only dpad, a, b, start and back;
-- Game:gamepadpressed additionally takes the shoulders and triggers for GAME
-- SPEED, and Select+face for the display chords. That leaves the two STICK
-- CLICKS (L3/R3) and the X/Y face buttons genuinely unbound.
--
-- POLLS rather than intercepting gamepadpressed: the engine's pad path is a
-- chain of special cases a wrapper would have to replicate, whereas
-- isGamepadDown asks the question directly and cannot swallow an event the
-- game needed.

local V = ...

local Hotkeys = {}

-- Buttons the engine does not already use for something.
Hotkeys.BUTTONS = {
  { key = "leftstick",  label = "L-STICK",  default = "3" },
  { key = "rightstick", label = "R-STICK",  default = "9" },
  { key = "x",          label = "PAD X",    default = "off" },
  { key = "y",          label = "PAD Y",    default = "off" },
}

-- What each digit reaches. 1-5 are the engine's own; a mod render pipeline
-- claims its digit last, so with the voxel mod installed 3 and 5 are its
-- VOXEL and V-GRID rather than TILT and GBC FX.
Hotkeys.CHOICES = {
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

function Hotkeys.schema()
  local rows = {}
  for i, b in ipairs(Hotkeys.BUTTONS) do
    rows[i] = {
      key = "hk_" .. b.key, type = "choice", label = b.label, default = b.default,
      choices = Hotkeys.CHOICES,
      description = "Which display hotkey this button fires. The labels assume "
        .. "the voxel mod is installed; without it, 3 is TILT and 5 is GBC FX.",
    }
  end
  return rows
end

local held = {}   -- button -> was down last step

local function joysticks()
  if not (love and love.joystick and love.joystick.getJoysticks) then return {} end
  local ok, list = pcall(love.joystick.getJoysticks)
  if ok and type(list) == "table" then return list end
  return {}
end

-- `owns` decides whether a pad belongs to this window, so in split screen
-- player 2's stick click only changes player 2's screen.
local function isDown(button, owns)
  for _, js in ipairs(joysticks()) do
    local mine = true
    if owns then
      local ok, yes = pcall(owns, js)
      mine = ok and yes
    end
    if mine and js.isGamepadDown then
      local ok, down = pcall(function() return js:isGamepadDown(button) end)
      if ok and down then return true end
    end
  end
  return false
end

-- Call once per logic step. `get(key)` reads an options row.
function Hotkeys.step(game, get, owns)
  if not game or not game.keypressed then return end
  for _, b in ipairs(Hotkeys.BUTTONS) do
    local digit = get("hk_" .. b.key)
    local down = (digit and digit ~= "off") and isDown(b.key, owns) or false
    -- Rising edge only: these are cycles, and a held stick click must not run
    -- the ladder round and round.
    if down and not held[b.key] then
      pcall(function() game:keypressed(digit) end)
    end
    held[b.key] = down
  end
end

return Hotkeys
