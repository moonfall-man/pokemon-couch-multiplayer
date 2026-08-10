-- Ghost link wire protocol.
--
-- Deliberately tiny: a footstep is sent on every step, so the message is
-- short keys and no nesting. Everything is presentational -- nothing here
-- can change another player's game, because nothing here is ever applied to
-- anything but a decorative NPC.
--
--   hello  { t="hello", v, id, name, sprite, species }   on connect / on demand
--   pos    { t="pos",   id, map, x, y, f }               on every step + warp
--   party  { t="party", id, species }                    lead Pokemon changed
--   state  { t="state", id, battling }                   entered/left a battle
--   bye    { t="bye",   id }                             clean exit
--
-- `state` is its own message rather than a field on `pos` because a player
-- who starts a battle stops moving: piggybacking it on movement would mean
-- the marker never appeared until they walked again, which is precisely when
-- it is no longer true.
--
-- `id` is a per-session random string rather than anything derived from the
-- save: two players who started from the same seeded save must not collide,
-- and nothing about a player's file should go on the wire.

local V = ...

local Wire = {}

Wire.VERSION = 1

-- A session id that MUST differ between two copies running side by side.
--
-- This was randomness alone, and it collided: LOVE seeds love.math from the
-- clock, so two instances launched in the same second produce the identical
-- sequence and therefore the identical id. Every message from the peer then
-- matched my own id, got discarded as an echo by the guard in main.lua, and
-- neither player ever saw anybody. It "worked" only when the two launches
-- happened to straddle a second boundary, which is exactly the kind of bug
-- that looks intermittent and unrelated to the code you just changed.
--
-- So uniqueness now comes from things that CANNOT be equal across two
-- processes, with randomness only as a garnish:
--
--   POKEPORT_IDENTITY  the launcher gives every player its own save identity
--   tostring({})       a fresh table's address, unique within a process image
--
-- `extra` exists so tests can vary the identity without touching the
-- environment.
function Wire.newId(extra)
  local rand = (love and love.math and love.math.random) or math.random
  local parts = {
    tostring(extra or os.getenv("POKEPORT_IDENTITY") or "?"),
    tostring({}),
    tostring(os.time()),
    tostring(os.clock()),
    tostring(rand(0, 0xFFFFFF)),
  }
  local s = table.concat(parts, "|")
  -- djb2. Plain arithmetic on purpose: LuaJIT has no `~` operator, and this
  -- only has to spread a handful of inputs across 32 bits.
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return ("%08x"):format(h)
end

function Wire.hello(id, name, sprite, species)
  return { t = "hello", v = Wire.VERSION, id = id, name = name,
           sprite = sprite, species = species }
end

function Wire.pos(id, mapId, x, y, facing)
  return { t = "pos", id = id, map = mapId, x = x, y = y, f = facing }
end

function Wire.party(id, species)
  return { t = "party", id = id, species = species }
end

function Wire.state(id, battling)
  return { t = "state", id = id, battling = battling and true or false }
end

-- "Tell me where you are, now."
--
-- Sent when I walk onto a new map. Every ghost is despawned on a map change,
-- and a peer who is standing still would otherwise not say anything until the
-- keepalive came round -- so someone waiting in the next town took seconds to
-- appear. This turns that into one round trip.
function Wire.sync(id)
  return { t = "sync", id = id }
end

function Wire.bye(id)
  return { t = "bye", id = id }
end

-- Anything off the wire is untrusted: a malformed or hostile message must
-- not reach spawnNpc with a nil sprite (NPC.new asserts on an unknown sprite
-- id and would take the whole game down). Every field is checked here so the
-- rest of the mod can assume well-formed input.
local function isFiniteNumber(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local FACINGS = { up = true, down = true, left = true, right = true }

-- A species is the engine's own key into data.pokemon -- an uppercase name
-- like PIKACHU or MR_MIME, not a dex number. Constrained here so a wire
-- value can only ever be used to build a filename or index a table.
local function isSpecies(v)
  return type(v) == "string" and #v > 0 and #v <= 24 and v:match("^[A-Z0-9_]+$") ~= nil
end

function Wire.validate(msg)
  if type(msg) ~= "table" then return nil, "not a table" end
  local t = msg.t
  if type(t) ~= "string" then return nil, "no type" end

  if t == "peer_lost" then return msg end  -- synthetic, from the transport

  if type(msg.id) ~= "string" or #msg.id == 0 or #msg.id > 32 then
    return nil, "bad id"
  end

  if t == "hello" then
    if msg.v ~= Wire.VERSION then return nil, "version mismatch" end
    if msg.name ~= nil and type(msg.name) ~= "string" then return nil, "bad name" end
    if msg.sprite ~= nil and type(msg.sprite) ~= "string" then return nil, "bad sprite" end
    if msg.species ~= nil and not isSpecies(msg.species) then return nil, "bad species" end
    return msg

  elseif t == "pos" then
    if type(msg.map) ~= "string" and not isFiniteNumber(msg.map) then
      return nil, "bad map"
    end
    if not (isFiniteNumber(msg.x) and isFiniteNumber(msg.y)) then return nil, "bad cell" end
    if msg.f ~= nil and not FACINGS[msg.f] then return nil, "bad facing" end
    return msg

  elseif t == "party" then
    if msg.species ~= nil and not isSpecies(msg.species) then return nil, "bad species" end
    return msg

  elseif t == "state" then
    if type(msg.battling) ~= "boolean" then return nil, "bad battling flag" end
    return msg

  elseif t == "sync" or t == "bye" then
    return msg
  end

  return nil, "unknown type " .. tostring(t)
end

return Wire
