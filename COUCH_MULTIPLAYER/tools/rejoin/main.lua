-- Does silence detection actually spot a destroyed host, and does the
-- joiner come back? Uses a fake clock so 12s of silence costs no wall time.
local OUT = os.getenv("REJOIN_OUT")
local lines = {}
local function say(s) lines[#lines+1] = s; print(s) end
package.path = os.getenv("MOD_DIR") .. "/?.lua;" .. os.getenv("ENGINE_DIR") .. "/?.lua;" .. package.path

local Transport = require("lib.Transport")
if not Transport.available() then say("no enet"); os.exit(1) end

-- Fake clock, so SILENCE can elapse instantly.
local fake = 0
local realGetTime = love.timer.getTime
love.timer.getTime = function() return fake end

local PORT, ADDR = 7912, "127.0.0.1:7912"
local function pump(list, secs)
  local t0 = realGetTime()
  while realGetTime() - t0 < secs do
    for _, tr in ipairs(list) do if tr and not tr.closed then tr:update() end end
  end
end

local host = Transport.new(); host:host(PORT)
local join = Transport.new(); join:join(ADDR)
pump({host, join}, 1.5)
say(("A. connected      host=%d join=%d  join.lastRx=%s")
    :format(host:peerCount(), join:peerCount(), tostring(join.lastRx)))

-- ---- the exact retryJoin logic, lifted
local RETRY_EVERY, SILENCE = 3, 12
local nextRetry = 0
local function retryJoin()
  local t = join
  if not t or t.closed then return end
  local now = love.timer.getTime()
  local silent = t.lastRx ~= nil and (now - t.lastRx) > SILENCE
  if t:peerCount() > 0 and not silent then nextRetry = 0; return end
  if nextRetry == 0 then nextRetry = now + RETRY_EVERY; return end
  if now < nextRetry then return end
  nextRetry = now + RETRY_EVERY
  pcall(function() t:close() end)
  local fresh = Transport.new()
  fresh:join(ADDR)
  join = fresh
  return true
end

-- host dies the way close() does it: destroy, no disconnect
host:close()
pump({join}, 0.6)
say(("B. host destroyed  join still reports peers=%d  <- why peerCount alone fails")
    :format(join:peerCount()))

fake = fake + SILENCE + 1
say(("C. after %ds of silence -> silent=%s")
    :format(SILENCE + 1, tostring(join.lastRx ~= nil and (fake - join.lastRx) > SILENCE)))

local host2 = Transport.new(); host2:host(PORT)
local back = false
for i = 1, 8 do
  fake = fake + RETRY_EVERY + 1
  retryJoin()
  pump({host2, join}, 0.8)
  if join:peerCount() > 0 and host2:peerCount() > 0 then
    say(("D. retry %d reconnected  host=%d join=%d"):format(i, host2:peerCount(), join:peerCount()))
    back = true; break
  end
end
if not back then say("D. never reconnected") end
say("RESULT: " .. (back and "joiner recovers from a destroyed host" or "STILL DARK"))

local f = io.open(OUT,"w"); f:write(table.concat(lines,"\n")); f:close()
os.exit(back and 0 or 1)
