-- Split screen without a launcher script.
--
-- Set PLAYERS to 2 and press Play: this window becomes player 1, clones its
-- own profile to a derived one per extra player, starts them, and every
-- window puts itself in its own quadrant. Nothing to install, nothing to run,
-- no second copy of the game to configure.
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

local function shellCopyDir(from, to)
  local HostShell = require("src.core.HostShell")
  local cmd
  if isWindows() then
    -- /E all subdirs incl. empty, /NFL /NDL /NJH /NJS /NC /NS quiet, /R:1 one
    -- retry. robocopy exits 1 for "copied ok", which is not a shell failure.
    cmd = ('robocopy "%s" "%s" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1')
      :format(from, to)
  else
    cmd = ('mkdir -p "%s" && cp -r "%s/." "%s/" 2>/dev/null'):format(to, from, to)
  end
  local p = HostShell.popen(cmd)
  if p then HostShell.pclose(p) end
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  -- directories do not open as files on every platform; probe a known child
  local probe = io.open(path .. (isWindows() and "\\." or "/."), "rb")
  if probe then probe:close(); return true end
  return false
end

-- Returns true when the destination looks ready to boot into a game.
function Couch.cloneProfile(n)
  local from = Couch.saveDir()
  local to = Couch.saveDirFor(n)
  if not (from and to) or from == to then return false end
  local sep = isWindows() and "\\" or "/"

  -- Mods every time: this is how an updated mod reaches the other players,
  -- and it is small.
  shellCopyDir(from .. sep .. "mods", to .. sep .. "mods")

  -- ROM cache only when missing. It is the big one, and it never changes for
  -- a given cartridge.
  local GameVersion = require("src.core.GameVersion")
  local version = (GameVersion.get and GameVersion.get()) or "red"
  local marker = to .. sep .. version .. sep .. "rom-cache.complete"
  if not exists(marker) then
    shellCopyDir(from .. sep .. version, to .. sep .. version)
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

  return exists(marker)
end

-- ------- starting the others

local spawned = false

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
    if opts.game then vars[#vars + 1] = { "POKEPORT_GAME", opts.game } end
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

-- ------- putting this window in its place
--
-- Each instance tiles ITSELF from its own player number: 1x2 for two players,
-- 2x2 for three or four. No window enumeration, no waiting for someone else's
-- window to exist, and it works the same on every platform.
function Couch.tileSelf(index, total)
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

  pcall(love.window.setMode, w, h, { resizable = true, borderless = false })
  pcall(love.window.setPosition, col * w, row * h)
  return true
end

return Couch
