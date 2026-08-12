-- Split screen without a launcher script.
--
-- Set PLAYERS to 2 and load your save: this window becomes player 1, clones
-- its own profile to a derived one per extra player, starts them, and every
-- window puts itself in its own quadrant. Nothing to install, nothing to run,
-- no second copy of the game to configure.
--
-- "Load your save", not "press Play", and that is not a detail -- the engine
-- runs no mod code at all until then. See spawnOthers.
--
-- ------- why this can work at all
--
-- Three engine facts, each checked in the real game rather than assumed:
--
--   love.filesystem.getSource()  is the fused executable's own path, so the
--                                game can start another copy of itself
--   HostShell.popen              shells out, so that copy can be given its own
--                                POKEPORT_IDENTITY and POKEPORT_PAD -- which
--                                have to be ENVIRONMENT variables, because
--                                conf.lua reads them before any mod exists
--   love.window.setPosition      every instance tiles ITSELF from its own
--                                player number, so nobody has to enumerate
--                                anyone else's windows
--
-- That last one is the reason this is small. The launcher script it replaces
-- spent most of its length waiting for windows to appear and retrying
-- MoveWindow against processes that were not pumping messages yet. A process
-- that already knows it is player 3 just puts itself bottom-left.
--
-- ------- the safety rules
--
-- A mod that starts processes deserves suspicion, so the rules are narrow and
-- there are no exceptions:
--
--   * PLAYERS = 1 is the default and spawns NOTHING. Playing alone must be
--     indistinguishable from not having this mod.
--   * A spawned window is told it is a child (POKEPORT_COUCH_PLAYER) and a
--     child never spawns. Without that a fork bomb is one bug away.
--   * Only ever this game's own executable, from getSource(), never a path
--     from a config file or the network.
--   * Once per session. The marker is process-local, so a crash cannot leave
--     something that keeps re-launching.

local V = ...

local Couch = {}

Couch.MAX_PLAYERS = 4

-- Set on a spawned window so it knows not to spawn in turn.
local CHILD_ENV = "POKEPORT_COUCH_PLAYER"

local function isWindows()
  return love and love.system and love.system.getOS() == "Windows"
end

-- ------- who am I

-- 1 for the window a human started, N for one this mod started.
function Couch.playerIndex()
  local n = tonumber(os.getenv(CHILD_ENV) or "")
  if n and n >= 1 and n <= Couch.MAX_PLAYERS then return n end
  return 1
end

function Couch.isChild()
  return (os.getenv(CHILD_ENV) or "") ~= ""
end

-- ------- paths
--
-- love.filesystem is sandboxed to this profile, so anything touching a
-- sibling profile goes through plain io / the shell with absolute paths.

function Couch.saveDir()
  local ok, dir = pcall(love.filesystem.getSaveDirectory)
  if ok and type(dir) == "string" then return dir end
  return nil
end

function Couch.identity()
  local ok, id = pcall(love.filesystem.getIdentity)
  if ok and type(id) == "string" and id ~= "" then return id end
  return "pokemon-love2d"
end

-- Player 1 keeps whatever profile it was started with -- your normal save.
-- The others are derived from it, so a machine that has only ever pressed
-- Play still ends up with sensible names.
function Couch.identityFor(n)
  if n <= 1 then return Couch.identity() end
  return ("%s-p%d"):format(Couch.identity(), n)
end

function Couch.saveDirFor(n)
  local dir = Couch.saveDir()
  if not dir then return nil end
  if n <= 1 then return dir end
  local parent = dir:gsub("[/\\][^/\\]+$", "")
  local sep = dir:find("\\") and "\\" or "/"
  return parent .. sep .. Couch.identityFor(n)
end

-- ------- cloning a profile
--
-- A fresh player profile needs two things before it can boot into the game
-- rather than the ROM importer: the mods (this one included, or the child
-- would not know it is player 3) and the extracted ROM cache.
--
-- Copied with the host's own shell rather than in Lua: it is tens of
-- megabytes of small files, and robocopy / cp do it in a fraction of the time
-- a byte-wise Lua copy would take.

-- Does this path exist -- FILE OR DIRECTORY.
--
-- The directory half used to probe `path .. "\\."` and that never worked. It
-- returned false for every directory on Windows, silently, and the checks
-- built on it simply did not happen:
--
--   mirrorDir's source guard        -> mods were never mirrored
--   linkOrCopyDir's "already there" -> re-linked and re-copied every launch
--   the ghostlink hand-over         -> never copied, so every new player
--                                      rebuilt all 151 frames after all
--
-- Only the checks against real FILES worked, which is why the rest of this
-- file looked fine: rom-cache.complete and options.lua are files.
--
-- Renaming a path to itself succeeds when it exists and moves nothing --
-- files, directories and junctions alike, verified on all four. It is also
-- portable, where the Windows "\\nul" device trick that would also work is
-- not. The io.open fast path stays because it answers for files without
-- touching the filesystem's rename machinery.
local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return os.rename(path, path) and true or false
end

local function shell(cmd)
  local HostShell = require("src.core.HostShell")
  local p = HostShell.popen(cmd)
  if p then HostShell.pclose(p) end
end

-- Make `to` match `from` exactly, deletions included.
--
-- Only for directories this mod owns the contents of -- see the note at the
-- call site. robocopy /MIR is /E plus /PURGE; rsync --delete is the same
-- bargain. Both will happily empty the destination if the source is missing,
-- so the source is checked first: a mistyped path should do nothing rather
-- than wipe a player's mods.
local function mirrorDir(from, to)
  if not exists(from) then return false end
  if isWindows() then
    shell(('robocopy "%s" "%s" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1')
      :format(from, to))
  else
    shell(('mkdir -p "%s" && rsync -a --delete "%s/" "%s/" 2>/dev/null')
      :format(to, from, to))
  end
  return true
end

local function shellCopyDir(from, to)
  if isWindows() then
    -- /E all subdirs incl. empty, /NFL /NDL /NJH /NJS /NC /NS quiet, /R:1 one
    -- retry. robocopy exits 1 for "copied ok", which is not a shell failure.
    shell(('robocopy "%s" "%s" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1')
      :format(from, to))
  else
    shell(('mkdir -p "%s" && cp -r "%s/." "%s/" 2>/dev/null'):format(to, from, to))
  end
end

-- LINK a read-only derived directory rather than copying it.
--
-- Used for the ROM cache only, and the reason is disk rather than time. The
-- cache is 2.6 MB of the same bytes for every player, extracted once from the
-- one cartridge dump and never written again; a junction is 16 ms against a
-- 361 ms copy, which nobody would notice either way, but four players sharing
-- one copy instead of holding four is worth having for free.
--
-- Not a fix for the wait before the second window -- see spawnOthers. A whole
-- profile clones in 658 ms, measured, and that was never where the time went.
--
-- A junction (Windows, no admin needed) or a symlink (everywhere else).
-- Falls back to a real copy when linking is refused -- some filesystems and
-- some policies say no, and a slow start beats no start.
--
-- ONLY for data nothing writes to. Anything a player's own session modifies
-- is genuinely copied, or one player would be editing another's files.
local function linkOrCopyDir(from, to)
  if exists(to) then return true end
  if isWindows() then
    shell(('mklink /J "%s" "%s" >nul 2>&1'):format(to, from))
  else
    shell(('ln -s "%s" "%s" 2>/dev/null'):format(from, to))
  end
  if exists(to) then return true end
  shellCopyDir(from, to)
  return exists(to)
end


-- Returns true when the destination looks ready to boot into a game.
function Couch.cloneProfile(n)
  local from = Couch.saveDir()
  local to = Couch.saveDirFor(n)
  if not (from and to) or from == to then return false end
  local sep = isWindows() and "\\" or "/"

  -- Mods every time: this is how an updated mod reaches the other players.
  --
  -- MIRRORED, not merely copied, and that distinction is a bug fix. A plain
  -- copy adds and overwrites but never removes, so a mod uninstalled on
  -- player 1 stayed installed on players 2-4 forever -- they drifted apart
  -- silently, one launch at a time, and the only symptom was the other
  -- windows behaving like a setup nobody remembered choosing.
  --
  -- Caught by moving POKEMON_FOLLOWERS out of player 1's mods folder: player
  -- 1 correctly reported it missing while player 2 was still happily loading
  -- its stale copy.
  --
  -- This DELETES from the child's mods folder. That is the intent -- these
  -- profiles are derived from player 1 and exist to match it -- but it does
  -- mean a mod installed only in a child window will not survive the next
  -- launch. Install it for player 1 and let it propagate.
  mirrorDir(from .. sep .. "mods", to .. sep .. "mods")

  -- The ROM cache, linked rather than copied -- see linkOrCopyDir.
  local GameVersion = require("src.core.GameVersion")
  local version = (GameVersion.get and GameVersion.get()) or "red"
  linkOrCopyDir(from .. sep .. version, to .. sep .. version)

  -- The generated follower frames -- COPIED, not linked, deliberately.
  --
  -- Without them a new player rebuilds all 151 by shrinking battle sprites on
  -- its first boot into the world, and pays for it while its own screen waits.
  -- Handing over a finished cache costs nothing: the whole set is 26 KB.
  --
  -- Linking it would be wrong even though the bytes are identical. This mod
  -- WRITES here -- RomFollowers.checkCacheVersion calls clear() on a version
  -- bump -- and through a junction that is one player deleting another's
  -- cache, with both then regenerating into the same files at once.
  if exists(from .. sep .. "ghostlink") then
    shellCopyDir(from .. sep .. "ghostlink", to .. sep .. "ghostlink")
  end

  -- options.lua carries the display settings -- notably which render
  -- pipelines are on -- so a new player looks like the one who started it.
  -- saveSlots is deliberately NOT copied: that is the host's own save
  -- registry, and a new profile has no saves to register anyway.
  local optTo = to .. sep .. "options.lua"
  if not exists(optTo) then
    local src = io.open(from .. sep .. "options.lua", "rb")
    if src then
      local text = src:read("*a")
      src:close()
      text = text:gsub("\n%s*saveSlots = %b{},?\r?\n", "\n")
      text = text:gsub("\n%s*lastVersion = [^\n]*\r?\n", "\n")
      local dst = io.open(optTo, "wb")
      if dst then dst:write(text); dst:close() end
    end
  end

  return exists(to .. sep .. version .. sep .. "rom-cache.complete")
end

-- ------- starting the others
--
-- WHEN this can happen is not our choice. The engine loads a mod's entry
-- chunk in Game:load -- after a save is picked -- and says so itself:
--
--   -- Launcher-side mod surface: the mods panel runs BEFORE Game:load, so
--   -- this NEVER loads a mod entry chunk -- it scans manifests only.
--   src/mods/LauncherMods.lua
--
-- So no mod code of any kind runs while the launcher is on screen, and the
-- earliest a second window can start is the moment player 1 enters the world.
-- Nothing here can beat that; what it CAN do is make the gap the only gap,
-- which is what POKEPORT_GAME below is for.

local spawned = false

-- The version this session is playing, for POKEPORT_GAME.
local function currentVersion()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if ok and GameVersion and GameVersion.get then
    local v = GameVersion.get()
    if type(v) == "string" and v ~= "" then return v end
  end
  return nil
end

-- opts: { players, game, ghostPort, ghosts }
function Couch.spawnOthers(opts)
  if spawned then return 0, "already started" end
  if Couch.isChild() then return 0, "a spawned window never spawns" end
  local players = math.min(tonumber(opts.players) or 1, Couch.MAX_PLAYERS)
  if players < 2 then return 0, "single player" end

  local exe = love.filesystem.getSource()
  if type(exe) ~= "string" or exe == "" then
    return 0, "cannot find this game's executable"
  end
  -- Running from a source folder rather than a built game: there is no
  -- executable to start a second copy of.
  if not love.filesystem.isFused() then
    return 0, "only a packaged build can start extra players"
  end

  local HostShell = require("src.core.HostShell")
  spawned = true
  local started = 0

  for n = 2, players do
    Couch.cloneProfile(n)

    local vars = {
      { "POKEPORT_IDENTITY", Couch.identityFor(n) },
      { "POKEPORT_PAD", tostring(n) },
      { CHILD_ENV, tostring(n) },
      { "POKEPORT_COUCH_TOTAL", tostring(players) },
      -- background pad events must be in the environment before SDL_Init,
      -- which is the whole reason the launcher script set it there too
      { "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1" },
    }
    -- Straight into the game, past the launcher.
    --
    -- Without this the second window opens on the title screen and sits
    -- there until somebody walks over and clicks Play -- which reads as the
    -- window being late rather than being ready, because player 1 is already
    -- walking around by then. POKEPORT_GAME is the engine's own
    -- desktop-shortcut path (LaunchOptions.resolve): it boots the version
    -- directly, on that profile's own previous save slot, and falls back to
    -- the launcher by itself if that version is not imported here yet.
    --
    -- Which version comes from THIS session, so player 2 lands in the same
    -- game player 1 just opened rather than whatever they last played.
    local game = opts.game or currentVersion()
    if game then vars[#vars + 1] = { "POKEPORT_GAME", game } end
    if opts.ghosts then
      vars[#vars + 1] = { "POKEGHOST_JOIN", "127.0.0.1:" .. tostring(opts.ghostPort or 7778) }
    end

    local cmd
    if isWindows() then
      local sets = {}
      for _, kv in ipairs(vars) do
        sets[#sets + 1] = ("set %s=%s"):format(kv[1], kv[2])
      end
      cmd = ('start "" /b cmd /c "%s&& \"%s\""')
        :format(table.concat(sets, "&& "), exe)
    else
      local sets = {}
      for _, kv in ipairs(vars) do
        sets[#sets + 1] = ("%s=%s"):format(kv[1], kv[2])
      end
      cmd = ('%s "%s" >/dev/null 2>&1 &'):format(table.concat(sets, " "), exe)
    end

    local p = HostShell.popen(cmd)
    if p then HostShell.pclose(p); started = started + 1 end
  end

  return started
end

-- ------- how is this window actually doing

function Couch.describeMode()
  local fps = (love.timer and love.timer.getFPS and love.timer.getFPS()) or 0
  local w, h, flags = 0, 0, {}
  if love.window and love.window.getMode then
    local ok, a, b, c = pcall(love.window.getMode)
    if ok then w, h, flags = a or 0, b or 0, c or {} end
  end
  local cap = "?"
  local okF, FrameCap = pcall(require, "src.core.FrameCap")
  if okF and FrameCap and FrameCap.current then cap = tostring(FrameCap.current) end
  return ("%dfps cap=%s %dx%d vsync=%s msaa=%s")
    :format(fps, cap, w, h, tostring(flags.vsync), tostring(flags.msaa))
end

-- ------- putting this window in its place
--
-- Each instance tiles ITSELF from its own player number: 1x2 for two players,
-- 2x2 for three or four. No window enumeration, no waiting for someone else's
-- window to exist, and it works the same on every platform.
-- vsync: "auto" | "on" | "off". auto means OFF for a split screen.
--
-- Two windows both waiting on the same display's vblank do not share it
-- gracefully -- the compositor serves the foreground one and the other waits,
-- which is why "great for player 1, not so much for player 2" is the usual
-- report rather than "both a bit slower". With vsync off, love.run paces from
-- the engine's own FrameCap instead and the windows stop queueing behind each
-- other.
--
-- Single player is left exactly as the engine shipped it. Whatever this
-- costs or buys, someone playing alone did not sign up for it.
function Couch.tileSelf(index, total, vsyncMode)
  if not (love.window and love.window.getDesktopDimensions) then return false end
  total = math.max(1, math.min(total or 1, Couch.MAX_PLAYERS))
  if total < 2 then return false end
  index = math.max(1, math.min(index or 1, total))

  local okD, dw, dh = pcall(love.window.getDesktopDimensions)
  if not okD or not dw then return false end

  local cols = 2
  local rows = (total <= 2) and 1 or 2
  local w = math.floor(dw / cols)
  local h = math.floor(dh / rows)
  local col = (index - 1) % cols
  local row = math.floor((index - 1) / cols)

  -- START FROM THE CURRENT FLAGS. setMode does not merge -- every flag left
  -- out reverts to a library default, which is not obvious and is not what
  -- anyone means by "resize the window". Measured in LOVE 11.5: a window at
  -- vsync=0 msaa=4 minwidth=480, given setMode(w, h, {resizable = true}),
  -- comes back vsync=1 msaa=0 minwidth=1. This used to pass exactly that,
  -- so tiling quietly reset three settings it had no business touching.
  local flags = {}
  if love.window.getMode then
    local okM, _, _, cur = pcall(love.window.getMode)
    if okM and type(cur) == "table" then
      for k, v in pairs(cur) do flags[k] = v end
    end
  end
  flags.resizable = true
  flags.borderless = false
  flags.fullscreen = false
  -- x/y come from setPosition below; leaving them in confuses the placement.
  flags.x, flags.y = nil, nil

  if vsyncMode == "on" then flags.vsync = 1
  elseif vsyncMode == "off" then flags.vsync = 0
  elseif vsyncMode ~= "keep" then flags.vsync = 0 end   -- "auto"

  pcall(love.window.setMode, w, h, flags)
  pcall(love.window.setPosition, col * w, row * h)
  return true
end

return Couch
