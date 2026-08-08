-- Per-process controller ownership.
--
-- Running several copies of the game side by side (one window per player)
-- only works if each copy answers to exactly one controller.  It does not by
-- default: SDL delivers every pad's events to every process that is
-- listening, and src/core/Input.lua throws the `joystick` argument away --
--
--   function Input:gamepadpressed(joystick, button)
--     local btn = self.padBindings[button]
--     if btn then press(self, btn, "pad:" .. button) end
--   end
--
-- -- so every pad presses every button in every window at once.  This module
-- is the missing filter.  POKEPORT_PAD names the one pad this process
-- answers to:
--
--   unset, "all" or "0"   every pad (stock behaviour, the default)
--   "1".."8"              only the Nth pad in SDL's enumeration order
--   "none"                no pad at all, keyboard only
--
-- POKEPORT_KEYBOARD=0 additionally mutes the keyboard for this process.
-- Usually unnecessary -- the OS only delivers keys to the focused window --
-- but it stops a stray keypress reaching a background player.
--
-- Deliberately fails OPEN: an unparseable POKEPORT_PAD means "all pads"
-- rather than "no pads", because a typo should not leave someone unable to
-- press Start.
--
-- Pure Lua with no engine requires, deliberately: this file was a patch
-- dropped into src/core/ before it was a mod, and keeping it self-contained
-- is what let it become one.

local PadOwner = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local spec = trim((os.getenv("POKEPORT_PAD") or ""):lower())
local wantIndex = tonumber(spec)

local mode
if spec == "" or spec == "all" or wantIndex == 0 then
  mode = "all"
elseif spec == "none" then
  mode = "none"
elseif wantIndex and wantIndex >= 1 and wantIndex == math.floor(wantIndex) then
  mode = "index"
else
  mode = "all"
end

PadOwner.mode = mode
PadOwner.index = (mode == "index") and wantIndex or nil
PadOwner.keyboardEnabled = os.getenv("POKEPORT_KEYBOARD") ~= "0"

-- Is this process actually filtering anything?
--
-- The answer is no for a stock single-player install, and that is the point:
-- the mod can sit permanently in mods/ and wrap nothing at all until someone
-- launches split screen.  An installed mod that does nothing until asked is
-- much easier to reason about than one you have to remember to uninstall.
PadOwner.filtering = (mode ~= "all") or (not PadOwner.keyboardEnabled)

-- Resolved lazily rather than at load: this module is loaded while the mods
-- are loading, and while LÖVE has enumerated pads by then, a hotplug can
-- reorder them at any moment.  refresh() re-arms the lookup.
local ownedJoystick = nil
local ownedID = nil
local resolved = false

local function resolve()
  resolved = true
  ownedJoystick, ownedID = nil, nil
  if mode ~= "index" then return end
  if not (love and love.joystick and love.joystick.getJoysticks) then return end
  local ok, list = pcall(love.joystick.getJoysticks)
  if not ok or type(list) ~= "table" then return end
  local js = list[wantIndex]
  if not js then return end
  ownedJoystick = js
  if js.getID then
    local okID, id = pcall(function() return js:getID() end)
    if okID then ownedID = id end
  end
end

-- Called from love.joystickadded / love.joystickremoved: enumeration order
-- changes under a hotplug, so the binding has to be taken again.
function PadOwner.refresh()
  resolved = false
end

-- True when this process should act on an event from `joystick`.
-- LÖVE hands back the same Joystick object for the same device every time,
-- so the identity compare is the fast path and the ID compare is the belt.
function PadOwner.owns(joystick)
  if mode == "all" then return true end
  if mode == "none" then return false end
  if not resolved then resolve() end
  if joystick == nil then return false end
  if ownedJoystick ~= nil and joystick == ownedJoystick then return true end
  if ownedID == nil or not joystick.getID then return false end
  local ok, id = pcall(function() return joystick:getID() end)
  return ok and id == ownedID
end

-- For a log line / debug overlay.
function PadOwner.describe()
  if mode == "all" then return "all pads" end
  if mode == "none" then return "no pad (keyboard only)" end
  return ("pad #%d"):format(wantIndex)
end

-- SDL drops joystick events for an UNFOCUSED window unless this hint is set,
-- which would leave every player but whoever clicked last unable to move.
-- LÖVE ships SDL2 as a shared library on desktop, so ffi.load can reach
-- SDL_SetHint.
--
-- Setting it this late -- from a mod, long after SDL_Init -- still takes:
-- SDL registers a hint CALLBACK for this name when the joystick subsystem
-- starts, and SDL_SetHint fires that callback, so the flag the event pump
-- reads is updated on the spot rather than sampled once at init.
--
-- Best-effort: some builds already set it, and a static link makes the symbol
-- unreachable from here.  Returns true if the call went through.
function PadOwner.allowBackgroundEvents()
  local ok, ffi = pcall(require, "ffi")
  if not (ok and ffi) then return false end
  pcall(ffi.cdef, [[ int SDL_SetHint(const char *name, const char *value); ]])

  local function try(C)
    if not C then return false end
    local okSet = pcall(function()
      C.SDL_SetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1")
    end)
    return okSet
  end

  -- One name per platform's convention, because ffi.load does no guessing:
  -- Windows ships SDL2.dll, Linux libSDL2-2.0.so.0, macOS either a dylib or
  -- an SDL2.framework inside the .app. The ffi.C fallback below is the one
  -- that usually wins on macOS -- SDL is already loaded into the process, so
  -- the symbol resolves out of the global namespace without naming a file.
  local names = {
    "SDL2", "SDL2.dll",
    "libSDL2-2.0.so.0", "libSDL2.so",
    "libSDL2-2.0.0.dylib", "libSDL2.dylib",
    "SDL2.framework/Versions/A/SDL2",
    "love",
  }
  for _, name in ipairs(names) do
    local okLib, C = pcall(ffi.load, name)
    if okLib and try(C) then return true end
  end
  return try(ffi.C)
end

return PadOwner
