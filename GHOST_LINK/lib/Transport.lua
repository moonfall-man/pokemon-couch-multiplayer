-- Multi-peer transport for ghost presence.
--
-- The engine's own src/link/Net.lua is a link CABLE: exactly two ends, one
-- `self.peer`, and a second connection to a host is disconnected on arrival
-- ("room is taken").  Ghosts want up to four players seeing each other, so
-- this is a sibling of that module rather than a user of it -- same API shape
-- (host/join/send/update/poll/.closed/.error) over an enet host with room for
-- several peers.
--
-- Topology is a star: everyone dials the host, and the host relays each
-- message on to the other clients.  A full mesh would need every player to
-- reach every other player, which is a NAT problem nobody wants on a couch;
-- the relay costs one extra hop on a LAN and is invisible at these message
-- rates (a handful of bytes per footstep).
--
-- Messages are JSON, through the engine's own encoder, on enet's channel 0.

local V = ...

local Json = require("src.link.Json")
local Logger = require("src.core.Logger")

local hasEnet, enet = pcall(require, "enet")
if not hasEnet then enet = nil end

local Transport = {}
Transport.__index = Transport

Transport.DEFAULT_PORT = 7778   -- one above the link cable's 7777
Transport.MAX_PEERS = 8         -- 4 players is the target; headroom is free
Transport.JOIN_TIMEOUT = 10

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.time()
end

function Transport.available()
  return enet ~= nil
end

function Transport.new()
  return setmetatable({
    peers = {},        -- live enet peers (host: clients; client: just the host)
    idsByPeer = {},    -- peer -> { [ghostId] = true }, for peer_lost
    inbox = {},
    outbox = {},       -- queued until the first peer arrives
    mode = nil,        -- "hosting" | "joining"
    closed = false,
    error = nil,
    address = nil,
  }, Transport)
end

-- ---------------------------------------------------------------- lifecycle

function Transport:host(port)
  if not enet then
    self.error = "ghost link needs lua-enet (run the game under LOVE)"
    return false
  end
  port = tonumber(port) or Transport.DEFAULT_PORT
  local ok, h, err = pcall(enet.host_create, ("*:%d"):format(port),
                           Transport.MAX_PEERS, 1)
  if not ok or not h then
    self.error = ("can't open UDP port %d (%s)"):format(port, tostring(ok and err or h))
    return false
  end
  self.enetHost = h
  self.mode = "hosting"
  self.port = port
  self.address = ("%s:%d"):format(self:lanIP() or "127.0.0.1", port)
  Logger.info("ghostlink: hosting on %s", self.address)
  return true
end

function Transport:join(address)
  if not enet then
    self.error = "ghost link needs lua-enet (run the game under LOVE)"
    return false
  end
  local host, port = tostring(address):match("^(.-):(%d+)$")
  host = host or tostring(address)
  port = tonumber(port) or Transport.DEFAULT_PORT
  local target = ("%s:%d"):format(host, port)

  local ok, h = pcall(enet.host_create)  -- client: no bind address
  if not ok or not h then
    self.error = "can't create network socket"
    return false
  end
  local okc, peer = pcall(h.connect, h, target, 1)
  if not okc or not peer then
    pcall(function() h:destroy() end)
    self.error = ("bad address %s"):format(target)
    return false
  end
  self.enetHost = h
  self.mode = "joining"
  self.target = target
  self.joinDeadline = now() + Transport.JOIN_TIMEOUT
  Logger.info("ghostlink: joining %s", target)
  return true
end

-- Best-effort LAN address for the "tell your friend this" string. Reuses the
-- engine's resolver so both features report the same number.
function Transport:lanIP()
  local ok, Net = pcall(require, "src.link.Net")
  if ok and Net and Net.lanIP then
    local okIP, ip = pcall(Net.lanIP)
    if okIP then return ip end
  end
  return nil
end

function Transport:peerCount()
  local n = 0
  for _ in pairs(self.peers) do n = n + 1 end
  return n
end

-- ------------------------------------------------------------------ sending

local function rawSend(peer, encoded)
  pcall(function() peer:send(encoded, 0, "reliable") end)
end

-- Send to everyone. Position updates are frequent and each supersedes the
-- last, so `unreliable` would be defensible -- but a dropped map.entered
-- would strand a ghost on the wrong map until the next footstep, and these
-- messages are tiny. Reliable-ordered keeps the state machine honest.
function Transport:send(msg)
  if self.closed then return false end
  local encoded = Json.encode(msg)
  if not encoded then return false end
  if self:peerCount() == 0 then
    -- nobody yet: hold it so a hello isn't lost in the connect race
    if #self.outbox < 32 then table.insert(self.outbox, msg) end
    return false
  end
  for peer in pairs(self.peers) do rawSend(peer, encoded) end
  return true
end

-- Host only: pass a client's message on to the other clients, so a star
-- topology still gives everyone a full view of everyone.
function Transport:relay(msg, fromPeer)
  local encoded = Json.encode(msg)
  if not encoded then return end
  for peer in pairs(self.peers) do
    if peer ~= fromPeer then rawSend(peer, encoded) end
  end
end

local function flushOutbox(self)
  local queued = self.outbox
  self.outbox = {}
  for _, msg in ipairs(queued) do self:send(msg) end
end

-- ------------------------------------------------------------------ pumping

function Transport:update()
  if not self.enetHost or self.closed then return end
  while true do
    local ok, event = pcall(self.enetHost.service, self.enetHost, 0)
    if not ok then
      -- an unreachable join target surfaces here as a service error
      if self.mode == "joining" and self:peerCount() == 0 then
        self.error = ("no answer from %s"):format(self.target or "the host")
      else
        self.error = tostring(event)
      end
      self.closed = true
      return
    end
    if not event then break end

    if event.type == "connect" then
      self.peers[event.peer] = true
      Logger.info("ghostlink: peer connected (%d total)", self:peerCount())
      flushOutbox(self)

    elseif event.type == "receive" then
      local msg = Json.decode(event.data)
      if msg then
        -- Remember WHICH SOCKET this player's messages arrive on, so that a
        -- peer dropping can name the ghosts it took with it. Without this a
        -- disconnect knows only that "a socket went away" -- which is not
        -- something the pool can act on, and is why peer_lost used to be a
        -- no-op that left a statue standing until the stale timeout.
        --
        -- On the HOST each client is its own peer, so the mapping is exact.
        -- On a CLIENT everything arrives relayed down the single host peer,
        -- so every id maps to it -- which is also correct: if that peer dies
        -- the client's whole session is over anyway.
        if type(msg.id) == "string" then
          local ids = self.idsByPeer[event.peer]
          if not ids then ids = {}; self.idsByPeer[event.peer] = ids end
          ids[msg.id] = true
        end
        table.insert(self.inbox, msg)
        if self.mode == "hosting" then self:relay(msg, event.peer) end
      else
        Logger.warn("ghostlink: bad message %q", tostring(event.data):sub(1, 60))
      end

    elseif event.type == "disconnect" then
      if self.peers[event.peer] then
        self.peers[event.peer] = nil
        Logger.info("ghostlink: peer left (%d remain)", self:peerCount())
        -- Surface it as a synthetic message so the pool can drop that
        -- player's ghosts without waiting for a timeout. `ids` is the whole
        -- point: a crash or a pulled cable sends no bye, so this is the only
        -- notice anyone gets.
        local ids = {}
        for id in pairs(self.idsByPeer[event.peer] or {}) do
          ids[#ids + 1] = id
        end
        self.idsByPeer[event.peer] = nil
        table.insert(self.inbox,
          { t = "peer_lost", peer = tostring(event.peer), ids = ids })
      end
      -- A client losing its only peer means the session is over. A host
      -- losing one just means one player quit.
      if self.mode == "joining" and self:peerCount() == 0 then
        self.closed = true
      end
    end
  end

  if self.mode == "joining" and self:peerCount() == 0
     and self.joinDeadline and now() > self.joinDeadline then
    self.error = ("no answer from %s"):format(self.target or "the host")
    self.closed = true
  end
end

function Transport:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

-- FLUSH, THEN LEAVE WITHOUT SAYING GOODBYE. Both halves are deliberate, and
-- the second one is the opposite of what it should be.
--
-- peer:send() only QUEUES a packet; nothing reaches the wire until the host is
-- serviced or flushed. This used to call disconnect_now() first, which tears
-- the connection down and -- by design -- throws that queue away. So the bye
-- Presence had just queued died one line before the flush that would have
-- sent it, and the other player was left looking at a statue until the
-- 30-second stale sweep collected it.
--
-- Flushing first is necessary but NOT sufficient, which is the part worth
-- writing down. Measured against real lua-enet, two ends on localhost:
--
--   teardown                              peer received the payload
--   ------------------------------------  -------------------------
--   flush then disconnect_now             only if it serviced in between
--   graceful disconnect() + service       never
--   flush then destroy, no disconnect     always
--
-- ENet's enet_protocol_handle_disconnect resets the peer's queues, and that
-- includes packets that have ALREADY ARRIVED but not yet been dispatched. On
-- loopback the bye and the disconnect land microseconds apart while the peer
-- services at 60Hz, so they are usually read in the same batch -- and the
-- disconnect throws away the bye sitting next to it. Whether the message
-- survives comes down to how the other process happened to be scheduled.
--
-- Sending no disconnect at all removes the race rather than narrowing it. The
-- peer reads the bye like any other message and drops the ghost immediately;
-- it notices the dead socket later, on ENet's own timeout, which is exactly
-- when peer_lost is supposed to fire. Nothing is waiting on that: the bye has
-- already done the work, and peer_lost exists for the crash that could not
-- send one.
function Transport:close()
  if self.closed and not self.enetHost then return end
  if self.enetHost then
    pcall(function() self.enetHost:flush() end)
    pcall(function() self.enetHost:destroy() end)
    self.enetHost = nil
  end
  self.peers = {}
  self.idsByPeer = {}
  self.closed = true
end

return Transport
