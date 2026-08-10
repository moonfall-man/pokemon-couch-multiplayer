-- Per-window volume, so four copies of the game are not four copies of the
-- soundtrack.
--
-- ------- the actual problem
--
-- It is not loudness. It is PHASING. Two windows playing the Route 1 theme a
-- few milliseconds apart is a flanged mess in a way that either one alone is
-- not, and it gets worse with every extra player because they never start
-- together -- window 2 is a second behind window 1 by construction.
--
-- Sound effects do not do that. They are short, they are sparse, and they are
-- information: your cry, your menu blip, your battle sting. Each player wants
-- their own on their own screen.
--
-- So the default is one soundtrack for the room and private effects per
-- player: music ducked hard on players 2+, effects untouched everywhere.
-- Both are sliders, because that default is a guess about a living room and
-- the people in it are better placed to judge than this comment is.
--
-- ------- what is deliberately NOT here
--
-- Ducking whoever is not focused. It is the obvious implementation and it is
-- wrong for this format for exactly the reason the pad code needs
-- SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS: on a couch the unfocused window is
-- not idle, it is the other player. Focus-based ducking would silence
-- whoever did not click last, which is worse than the noise it fixes.
--
-- ------- the two seams
--
--   music   the engine's own `music.volume` hook, which is consulted every
--           time a song's volume is computed and multiplies cleanly.
--   sfx     no such hook exists, so Sound.applyOptions is wrapped. That is
--           the right seam rather than Sound.setVolumeLevel: applyOptions
--           receives the player's own engine-level sfxVol in `opts`, so the
--           scale composes with their setting instead of clobbering it.
--
-- Game:applyOptions calls both on boot and after loading a save, so `opts` is
-- captured there and replayed by refresh() when a slider moves.

local V = ...

local Audio = {}

-- How quiet the extra windows' music gets when DUCK is on. Low enough that
-- the phasing stops reading as phasing, not so low that a player misses their
-- own battle theme starting.
local DUCK_TO = 0.2

-- Wrapped by identity rather than a flag, for the reason PadFilter documents:
-- the manager can load a mod again inside one process, and a flag set in this
-- chunk is reset by the very reload it is meant to notice.
_G.__COUCH_AUDIO_WRAPPED = _G.__COUCH_AUDIO_WRAPPED
  or setmetatable({}, { __mode = "k" })
local wrapped = _G.__COUCH_AUDIO_WRAPPED

local state = {
  installed = false,
  index = 1,
  music = 1,      -- 0..1, from the slider
  sfx = 1,        -- 0..1, from the slider
  duck = true,
  lastOpts = nil, -- the engine's own audio settings, for replay
  -- What the music hook last turned an incoming volume INTO. Registering a
  -- hook and having it take effect are different claims, and a factor
  -- printed from this module's own state is evidence of neither -- it is
  -- just the slider read back. This is the number the engine applied.
  lastIn = nil,
  lastOut = nil,
  hookCalls = 0,
}

local function pct(v, fallback)
  local n = tonumber(v)
  if not n then return fallback end
  if n < 0 then n = 0 elseif n > 100 then n = 100 end
  return n / 100
end

-- The multiplier this window applies to music. Player 1 is never ducked --
-- it is the window that already existed, and on most sofas the one nearest
-- the television.
function Audio.musicFactor()
  local f = state.music
  if state.duck and state.index > 1 then f = f * DUCK_TO end
  return f
end

function Audio.sfxFactor()
  return state.sfx
end

-- Read the sliders. Returns true when this window would actually change
-- something, which is what decides whether anything gets wrapped at all.
function Audio.read(opt, index)
  state.index = tonumber(index) or 1
  state.music = pct(opt("musicvol"), 1)
  state.sfx = pct(opt("sfxvol"), 1)
  state.duck = opt("duckextra") ~= false
  return Audio.musicFactor() ~= 1 or Audio.sfxFactor() ~= 1
end

-- Push the current factors at the engine.
--
-- The music hook is consulted when a song's volume is computed, which is not
-- every frame -- so moving a slider mid-route would otherwise not be heard
-- until the next song change. Replaying the captured opts re-applies both.
function Audio.refresh()
  local opts = state.lastOpts
  local okM, Music = pcall(require, "src.core.Music")
  if okM and Music and Music.applyOptions and opts then pcall(Music.applyOptions, opts) end
  local okS, Sound = pcall(require, "src.core.Sound")
  if okS and Sound and Sound.applyOptions and opts then pcall(Sound.applyOptions, opts) end
end

-- Returns a list of what it wrapped, for the status dump.
function Audio.install(mod)
  local done = {}
  if state.installed then return done end
  state.installed = true

  -- music: the engine's own hook, so nothing is patched.
  local okHook = pcall(function()
    mod.hooks:wrap("music.volume", function(next, vol, ctx)
      local base = tonumber(next(vol, ctx)) or 0
      local out = base * Audio.musicFactor()
      state.lastIn, state.lastOut = base, out
      state.hookCalls = state.hookCalls + 1
      return out
    end)
  end)
  if okHook then done[#done + 1] = "music.volume" end

  -- sfx: no hook, so wrap the one function that is handed the player's own
  -- setting. Capturing opts here is also what lets refresh() replay it.
  local okS, Sound = pcall(require, "src.core.Sound")
  if okS and type(Sound) == "table" and type(Sound.applyOptions) == "function"
     and not wrapped[Sound.applyOptions] then
    local inner = Sound.applyOptions
    local outer = function(opts)
      state.lastOpts = opts or state.lastOpts
      inner(opts)
      -- After, not instead: the engine has just set the player's own level
      -- and this scales that rather than replacing it.
      local level = (opts and opts.sfxVol) or 7
      pcall(Sound.setVolumeLevel, level * Audio.sfxFactor())
    end
    wrapped[outer] = true
    Sound.applyOptions = outer
    done[#done + 1] = "Sound.applyOptions"
  end

  -- Music.applyOptions is wrapped only to capture opts -- the volume itself
  -- is the hook's job.
  local okM, Music = pcall(require, "src.core.Music")
  if okM and type(Music) == "table" and type(Music.applyOptions) == "function"
     and not wrapped[Music.applyOptions] then
    local inner = Music.applyOptions
    local outer = function(opts)
      state.lastOpts = opts or state.lastOpts
      return inner(opts)
    end
    wrapped[outer] = true
    Music.applyOptions = outer
    done[#done + 1] = "Music.applyOptions"
  end

  return done
end

function Audio.describe()
  -- Two halves on purpose: what this window INTENDS, then what the engine
  -- was actually handed. If the second says "hook not called yet" while the
  -- first says 20%, nothing is being ducked no matter how right the first
  -- half looks.
  local applied = "hook not called yet"
  if state.lastOut then
    applied = ("last %0.3f -> %0.3f, %d call(s)")
      :format(state.lastIn or 0, state.lastOut, state.hookCalls)
  end
  return ("music=%d%% sfx=%d%%%s [%s]"):format(
    math.floor(Audio.musicFactor() * 100 + 0.5),
    math.floor(Audio.sfxFactor() * 100 + 0.5),
    (state.duck and state.index > 1) and " ducked" or "",
    applied)
end

-- The rows, kept beside the code that reads them.
function Audio.schema()
  return {
    { key = "musicvol", type = "number", label = "MUSIC VOL", default = 100,
      min = 0, max = 100, step = 5,
      description = "This window's music, as a percentage of your normal "
        .. "music setting. Each player's window has its own." },
    { key = "sfxvol", type = "number", label = "SFX VOL", default = 100,
      min = 0, max = 100, step = 5,
      description = "This window's sound effects. Left alone on purpose by "
        .. "DUCK EXTRA -- cries and menu beeps are how you know what your "
        .. "own game is doing." },
    { key = "duckextra", type = "toggle", label = "DUCK EXTRA", default = true,
      description = "Play the music quietly in players 2, 3 and 4 so the "
        .. "same track is not going twice slightly out of step, which is the "
        .. "part that actually grates. Player 1 and all sound effects are "
        .. "untouched. Off means every window plays its own music in full." },
  }
end

return Audio
