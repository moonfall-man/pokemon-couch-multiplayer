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

-- Claim a pad from code rather than from the environment.
--
-- POKEPORT_PAD is how a SPAWNED window is told which controller is its own,
-- because conf.lua reads the environment before any mod exists. Player 1 has
-- no such luxury: nobody set a variable for the window a human opened, and it
-- cannot set one for itself after the fact. So when PLAYERS says this is a
-- multiplayer session, the mod binds player 1 to pad #1 here.
--
-- Declared below the env parsing on purpose: an explicit POKEPORT_PAD still
-- wins, because a launcher that went to the trouble of naming a pad means it.
function PadOwner.bind(index)
  if PadOwner.mode == "index" then return false end   -- env already decided
  index = tonumber(index)
  if not (index and index >= 1 and index == math.floor(index)) then return false end
  mode = "index"
  wantIndex = index
  PadOwner.mode = mode
  PadOwner.index = index
  PadOwner.filtering = true
  PadOwner.refresh()
  return true
end

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

-- ------- agreeing on which pad is "#1" ACROSS PROCESSES
--
-- This is the whole difficulty, and getting it wrong is subtle rather than
-- loud: both windows answer to the same controller and the other one does
-- nothing.
--
-- "Pad #2" cannot mean "second in love.joystick.getJoysticks()". That list is
-- in SDL's enumeration order, which is per-process and set by the order
-- devices are discovered while THAT process starts. The windows here are
-- separate processes starting about a second apart, and nothing synchronises
-- their discovery. When their orders disagree, pads[1] over here and pads[2]
-- over there are the same physical device. It is a race, so it works most of
-- the time, which is worse than never working.
--
-- So order by something every process computes the same: the device's own
-- identity. GUID first (SDL's per-model id -- stable, and different for two
-- different controllers), then vendor/product, then name. Enumeration
-- position is the last resort and only breaks ties between devices that are
-- identical by every one of those, i.e. two of the same controller -- where
-- there is nothing left to tell them apart and it is no worse than before.
local function sortKey(js, fallbackIndex)
  local parts = {}

  local function add(fn)
    local ok, v = pcall(fn)
    parts[#parts + 1] = (ok and v ~= nil) and tostring(v) or ""
  end

  if js.getGUID then add(function() return js:getGUID() end) end
  if js.getDeviceInfo then
    -- 11.3+: vendorID, productID, productVersion. Separates two models that
    -- somehow share a GUID.
    add(function()
      local v, p, r = js:getDeviceInfo()
      return ("%s:%s:%s"):format(tostring(v), tostring(p), tostring(r))
    end)
  end
  if js.getName then add(function() return js:getName() end) end

  -- Fixed width so the tie-break sorts numerically rather than "10" < "2".
  parts[#parts + 1] = ("%04d"):format(fallbackIndex)
  return table.concat(parts, "\0")
end

-- The joystick list in an order every process agrees on.
function PadOwner.ordered()
  if not (love and love.joystick and love.joystick.getJoysticks) then return {} end
  local ok, list = pcall(love.joystick.getJoysticks)
  if not ok or type(list) ~= "table" then return {} end

  local keyed = {}
  for i, js in ipairs(list) do
    keyed[#keyed + 1] = { js = js, key = sortKey(js, i) }
  end
  table.sort(keyed, function(a, b) return a.key < b.key end)

  local out = {}
  for i, e in ipairs(keyed) do out[i] = e.js end
  return out
end

local function resolve()
  resolved = true
  ownedJoystick, ownedID = nil, nil
  if mode ~= "index" then return end
  local list = PadOwner.ordered()
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

-- describe() says which pad this window WANTS. This says whether it got one.
--
-- Those are not the same, and the difference is the single most confusing
-- failure here: "pad #2" reads like success right up until you notice SDL
-- only enumerated one device, at which point the window is bound to nothing
-- and the player cannot move. A pad that is unplugged, asleep, paired but
-- not connected, or plugged in after launch all land here.
--
-- Returns: text, ok
function PadOwner.status()
  local n = #PadOwner.ordered()

  if mode == "all" then return ("all pads, %d seen"):format(n), n > 0 end
  if mode == "none" then return "no pad (keyboard only)", true end

  if not resolved then resolve() end
  local name = "?"
  if ownedJoystick and ownedJoystick.getName then
    local okN, got = pcall(function() return ownedJoystick:getName() end)
    if okN and got then name = got end
  end
  if not ownedJoystick then
    return ("pad #%d of %d seen -- NOT CONNECTED"):format(wantIndex, n), false
  end
  return ("pad #%d of %d seen, %s"):format(wantIndex, n, name), true
end

-- Every pad in the agreed order, marked with the one this window took.
--
-- Worth dumping in full rather than just the winner: the failure this is here
-- to catch is TWO WINDOWS AGREEING, and you cannot see that in one window's
-- status line. Put the two files side by side and the lists either match or
-- they do not.
function PadOwner.roster()
  local lines = {}
  for i, js in ipairs(PadOwner.ordered()) do
    local nm, guid = "?", "?"
    if js.getName then
      local ok, v = pcall(function() return js:getName() end)
      if ok and v then nm = v end
    end
    if js.getGUID then
      local ok, v = pcall(function() return js:getGUID() end)
      if ok and v then guid = tostring(v) end
    end
    lines[#lines + 1] = ("%s#%d %s [%s]")
      :format(js == ownedJoystick and "*" or " ", i, nm, guid)
  end
  if #lines == 0 then return "(none)" end
  return table.concat(lines, "  ")
end

-- SDL drops joystick events for an UNFOCUSED window unless this hint is set,
-- which leaves every player but whoever clicked last unable to move.
--
-- Two routes, and BOTH work.
--
--   "env"  SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1 in the environment before
--          SDL_Init.  This is what a spawned window gets, because whoever
--          spawned it could set it; conf.lua and SDL both read the
--          environment long before a mod exists.
--   "ffi"  SDL_SetHint at runtime.  This is what player 1 needs -- a human
--          double-clicked the game and set nothing.
--
-- The ffi route being live is the whole reason player 1 can work at all, so
-- it is worth saying why it is not too late.  SDL_JoystickInit registers a
-- callback on this hint and caches the result in a flag; the per-event check
-- reads that flag, and SDL_SetHint fires the callback again whenever it is
-- called.  So a hint set after SDL_Init, after the window, after pads are
-- enumerated, still governs the NEXT event.  Nothing here has to happen
-- early -- it has to happen before somebody presses a button.
--
-- This file used to claim the opposite -- "THE ENVIRONMENT IS THE RELIABLE
-- ROUTE, and no Lua can match it" -- on the strength of a boot probe that
-- reported `hint : (unset)`.  That probe read the value BEFORE anything set
-- it, so all it established was that the environment route had not been
-- taken.  It said nothing about whether SDL_SetHint works, which is what the
-- conclusion was about.  Believing it is why nothing called this function.
--
-- Reports which route was taken rather than just "true", because "the call
-- did not throw" is not the same claim as "background pads work" --
-- confusing those two is what let this sit broken once already.  The ffi
-- route reads the hint back out of SDL rather than trusting the set.
--
-- Returns: "env" | "ffi" | false
function PadOwner.allowBackgroundEvents()
  if (os.getenv("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS") or "") ~= "" then
    return "env"
  end

  local ok, ffi = pcall(require, "ffi")
  if not (ok and ffi) then return false end
  pcall(ffi.cdef, [[
    int SDL_SetHint(const char *name, const char *value);
    const char *SDL_GetHint(const char *name);
  ]])

  -- Set it, then ask SDL what it holds. A pcall that did not throw only says
  -- the symbol resolved; the readback says the hint is actually in there.
  local function try(C)
    if not C then return false end
    local okSet = pcall(function()
      C.SDL_SetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1")
    end)
    if not okSet then return false end
    local okGet, got = pcall(function()
      local p = C.SDL_GetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS")
      return p ~= nil and ffi.string(p) or nil
    end)
    return okGet and got == "1"
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
    if okLib and try(C) then return "ffi" end
  end
  return try(ffi.C) and "ffi" or false
end

return PadOwner
