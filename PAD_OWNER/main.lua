-- PAD OWNER: one controller per window.
--
-- Split screen on this engine is not a rendering problem, it is an INPUT
-- problem.  Run the game twice side by side and you already have two
-- independent worlds on one monitor -- but both windows answer to both pads,
-- because SDL broadcasts every pad's events to every listening process and
-- src/core/Input.lua discards the `joystick` argument entirely.  Press A on
-- either controller and both games press A.
--
-- This mod is the missing filter.  POKEPORT_PAD=2 makes this copy of the game
-- answer to the second controller and ignore the rest.  Nothing else changes:
-- no rendering, no world, no save.  Each player is playing an ordinary,
-- unmodified single-player game that happens to be sharing your desk.
--
-- ------- why this is a mod and not a patch
--
-- It used to be a patch.  main.lua defines love.gamepadpressed and friends at
-- chunk level, there is no hook anywhere near them, and the obvious reading is
-- that a mod is simply too late to the party -- mods load from inside
-- love.load, by which time those callbacks are long since defined.
--
-- That reading is wrong, and the reason is worth writing down.  LÖVE does not
-- capture the callbacks at boot; love.handlers looks up love.<name> at the
-- moment each event is dispatched.  So "too late to define it" and "too late
-- to REPLACE it" are different questions, and only the first one has an
-- awkward answer.  Verified in the real game rather than reasoned about:
-- wrapping love.gamepadpressed from mod-load time and pushing an event
-- through love.handlers reaches the wrapper.
--
-- The whole build step -- unpack the game, splice guards into main.lua,
-- repack, keep the anchors matching upstream forever -- existed to work
-- around a restriction that was not there.  Deleting it means this runs on
-- the official release exactly the way the voxel mod does.
--
-- ------- what gets wrapped
--
-- The pad callbacks in main.lua, not src/core/Input.lua.  Game:gamepadpressed
-- cycles GAME SPEED and routes menu input BEFORE it delegates to Input, so a
-- filter placed inside Input would still let player 2's pad drive player 1's
-- menus.  Guarding the outermost callback is what makes the filter total.

local mod = ...

-- ------- lib loading
--
-- A mod directory is not on package.path and may live inside a mounted
-- archive that plain require cannot open, so the one lib file is read and
-- compiled by hand.  Same shape GHOST_LINK uses.
local PadOwner
do
  local rel = "lib/PadOwner.lua"
  local source = mod:read(rel)
  if not source then
    error(("PAD_OWNER: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("PAD_OWNER: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  PadOwner = chunk()
end

-- ------- exports first
--
-- Published before any of the work below, and unconditionally: PAD_HOTKEYS
-- asks this mod which pad it owns, and it needs an answer whether or not this
-- process is filtering.  In a stock single-player install `owns` says yes to
-- everything, which is exactly right.
mod.exports.version = "0.1.0"
mod.exports.owns = function(joystick) return PadOwner.owns(joystick) end
mod.exports.refresh = PadOwner.refresh
mod.exports.describe = PadOwner.describe
mod.exports.mode = PadOwner.mode
mod.exports.index = PadOwner.index
mod.exports.keyboardEnabled = PadOwner.keyboardEnabled
mod.exports.filtering = PadOwner.filtering

-- ------- the no-op case
--
-- Unset POKEPORT_PAD means "every pad", which is stock behaviour, so there is
-- nothing to filter and no reason to sit in the event path.  The mod stays
-- installed and inert until a launcher sets the variable.  This matters for
-- sharing: nobody has to remember to uninstall it before playing alone.
if not PadOwner.filtering then
  mod.log:info("inactive (POKEPORT_PAD unset -- every pad drives this window)")
  return
end

-- ------- wrapping
--
-- Idempotent by identity, not by a flag.  The manager can load a mod again in
-- one process (a rollback, a re-enable), and a flag set inside this chunk is
-- reset by the very reload it is meant to detect.  Recording the wrapper
-- FUNCTIONS in a process-wide set asks the question that actually matters --
-- "is the callback currently installed already one of mine?" -- and survives
-- the chunk being run from scratch.
_G.__PAD_OWNER_WRAPPERS = _G.__PAD_OWNER_WRAPPERS or setmetatable({}, { __mode = "k" })
local wrappers = _G.__PAD_OWNER_WRAPPERS

local wrapped, skipped = {}, {}

local function install(name, make)
  local inner = love[name]
  if type(inner) ~= "function" then return end
  if wrappers[inner] then
    skipped[#skipped + 1] = name
    return
  end
  local outer = make(inner)
  wrappers[outer] = true
  love[name] = outer
  wrapped[#wrapped + 1] = name
end

-- Every pad and stick entry point.  All of them take the joystick first.
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

-- Hotplug re-arms the binding, then falls through unconditionally.  These are
-- deliberately NOT ownership-filtered: "a pad appeared" is news this process
-- needs even when the pad belongs to someone else, because it may have
-- shifted SDL's enumeration order and therefore which device is pad #2.
for _, name in ipairs({ "joystickadded", "joystickremoved" }) do
  install(name, function(inner)
    return function(joystick, ...)
      PadOwner.refresh()
      return inner(joystick, ...)
    end
  end)
end

-- Optional keyboard mute (POKEPORT_KEYBOARD=0).  Usually unnecessary, since
-- the OS only delivers keys to the focused window -- this is for the case
-- where you want a background player provably deaf to the keyboard.
if not PadOwner.keyboardEnabled then
  for _, name in ipairs({ "keypressed", "keyreleased" }) do
    install(name, function(inner)
      return function() return end
    end)
  end
end

-- ------- background events
--
-- Without this, only the focused window gets pad input, which in split screen
-- means exactly one player can move at a time.
--
-- "env" is the route that actually works and the one the launcher scripts
-- take; "ffi" is the fallback for a hand-started game and is later than SDL
-- would like.  See lib/PadOwner.lua.
local background = PadOwner.allowBackgroundEvents()

local backgroundNote =
  background == "env" and "on (from the environment, before SDL started)"
  or background == "ffi" and "set over the FFI -- LATE; if only the focused "
      .. "window responds, launch via play.ps1 or export "
      .. "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1"
  or "UNAVAILABLE (only the focused window will respond)"

mod.log:info("%s, keyboard %s, background pad events: %s",
  PadOwner.describe(),
  PadOwner.keyboardEnabled and "on" or "muted",
  backgroundNote)
if #wrapped > 0 then
  mod.log:info("wrapped: %s", table.concat(wrapped, ", "))
end
if #skipped > 0 then
  mod.log:info("already wrapped, left alone: %s", table.concat(skipped, ", "))
end

mod.exports.backgroundEvents = background
mod.exports.wrapped = wrapped
