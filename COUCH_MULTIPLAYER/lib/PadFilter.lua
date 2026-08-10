-- Make this window answer to exactly one controller.
--
-- SDL delivers every pad's events to every listening process, and the engine's
-- input layer discards which pad an event came from --
--
--   function Input:gamepadpressed(joystick, button)
--     local btn = self.padBindings[button]
--     if btn then press(self, btn, "pad:" .. button) end
--   end
--
-- -- so without this, press A on either controller and every window presses A.
--
-- ------- why the callbacks can be wrapped from a mod at all
--
-- main.lua defines love.gamepadpressed at chunk level and mods load later,
-- from inside love.load, so a mod looks hopelessly too late. It is not: LOVE
-- never captures these functions at boot, love.handlers looks up love.<name>
-- at the moment each event is dispatched. "Too late to define it" and "too
-- late to REPLACE it" are different claims and only the first is true.
--
-- ------- and why callbacks are not enough
--
-- The engine also POLLS. Input:reconcile walks every joystick and presses
-- whatever is physically down, straight into Input rather than through
-- love.gamepadpressed, so no wrapper near the callbacks can see it. It runs
-- on focus gain, on resume, and on a hotplug, and it exists for a good reason
-- -- a release can be swallowed while the OS owns the event stream, so holds
-- are rebuilt from the devices' ground truth.
--
-- The symptom is that clicking a window makes it act on whatever the other
-- player is holding. Rather than reimplement reconcile, narrow what it can
-- SEE: a filtered getJoysticks is swapped in for the duration of the call.

local V = ...

local PadFilter = {}

-- Idempotent by identity, not by a flag. The manager can load a mod again in
-- one process, and a flag set inside this chunk is reset by the very reload it
-- is meant to detect. Recording the wrapper FUNCTIONS asks the question that
-- actually matters: is the callback currently installed already one of mine?
_G.__COUCH_WRAPPERS = _G.__COUCH_WRAPPERS or setmetatable({}, { __mode = "k" })
local wrappers = _G.__COUCH_WRAPPERS

-- Returns a list of what it wrapped.
function PadFilter.install(PadOwner)
  local wrapped, skipped = {}, {}

  local function install(name, make)
    local inner = love[name]
    if type(inner) ~= "function" then return end
    if wrappers[inner] then skipped[#skipped + 1] = name; return end
    local outer = make(inner)
    wrappers[outer] = true
    love[name] = outer
    wrapped[#wrapped + 1] = name
  end

  -- Every pad and stick entry point. All of them take the joystick first.
  for _, name in ipairs({
    "gamepadpressed", "gamepadreleased", "gamepadaxis",
    "joystickpressed", "joystickreleased", "joystickaxis", "joystickhat",
  }) do
    install(name, function(inner)
      return function(joystick, ...)
        if not PadOwner.owns(joystick) then return end
        return inner(joystick, ...)
      end
    end)
  end

  -- Hotplug re-arms the binding then falls through UNFILTERED: "a pad
  -- appeared" is news this process needs even when the pad belongs to someone
  -- else, because it may have shifted SDL's enumeration order and therefore
  -- which device is pad #2.
  for _, name in ipairs({ "joystickadded", "joystickremoved" }) do
    install(name, function(inner)
      return function(joystick, ...)
        PadOwner.refresh()
        return inner(joystick, ...)
      end
    end)
  end

  -- Optional keyboard mute. Usually unnecessary -- the OS only delivers keys
  -- to the focused window -- but it makes a background player provably deaf.
  if not PadOwner.keyboardEnabled then
    for _, name in ipairs({ "keypressed", "keyreleased" }) do
      install(name, function() return function() return end end)
    end
  end

  -- The polling path. See the header.
  local okInput, Input = pcall(require, "src.core.Input")
  if okInput and type(Input) == "table" and type(Input.reconcile) == "function" then
    if not wrappers[Input.reconcile] then
      local inner = Input.reconcile
      local outer = function(selfInput, ...)
        local js = love.joystick
        local real = js and js.getJoysticks
        if not real then return inner(selfInput, ...) end

        -- Resolve the binding through the REAL list first. owns(nil) forces
        -- resolution and returns false, so this cannot bind to the filtered
        -- view it is about to install.
        PadOwner.owns(nil)

        js.getJoysticks = function(...)
          local all = real(...)
          if type(all) ~= "table" then return all end
          local mine = {}
          for _, j in ipairs(all) do
            if PadOwner.owns(j) then mine[#mine + 1] = j end
          end
          return mine
        end

        local ok, err = pcall(inner, selfInput, ...)
        js.getJoysticks = real
        if not ok then error(err, 0) end
      end
      wrappers[outer] = true
      Input.reconcile = outer
      wrapped[#wrapped + 1] = "Input:reconcile"
    else
      skipped[#skipped + 1] = "Input:reconcile"
    end
  end

  return wrapped, skipped
end

return PadFilter
