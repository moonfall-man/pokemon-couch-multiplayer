local OUT = os.getenv("PADTEST_OUT")
local lines = {}
local function say(s) lines[#lines+1] = s; print(s) end

-- Fake joysticks that answer the same questions a real one does.
local function pad(name, guid, vid, pid)
  return {
    getName = function(self) return name end,
    getGUID = function(self) return guid end,
    getDeviceInfo = function(self) return vid, pid, 1 end,
    getID = function(self) return 0 end,
  }
end

local A = pad("(8BitDo Ultimate 2C Wired Controller)", "03000000c82d00000631000014010000", 0xc82d, 0x0631)
local B = pad("Controller (Xbox One For Windows)",     "030000005e040000e002000003090000", 0x045e, 0x02e0)
local C = pad("Controller (Xbox One For Windows)",     "030000005e040000e002000003090000", 0x045e, 0x02e0)

local order   -- what "SDL enumerated" for the current fake process
love.joystick = { getJoysticks = function() return order end }

package.path = os.getenv("MOD_DIR") .. "/?.lua;" .. package.path

local function namesFor(padSpec, enumeration)
  -- Reload the module so it re-reads POKEPORT_PAD, like a fresh process.
  package.loaded["lib.PadOwner"] = nil
  local prev = os.getenv
  os.getenv = function(k)
    if k == "POKEPORT_PAD" then return padSpec end
    return prev(k)
  end
  order = enumeration
  local PadOwner = require("lib.PadOwner")
  os.getenv = prev
  local out = {}
  for i, js in ipairs(PadOwner.ordered()) do out[i] = js:getName() end
  return out, PadOwner
end

-- ---- two DIFFERENT controllers, enumerated in opposite orders
local o1 = namesFor("1", { A, B })
local o2 = namesFor("2", { B, A })
say("proc 1 saw [8BitDo, Xbox] -> ordered: " .. table.concat(o1, " | "))
say("proc 2 saw [Xbox, 8BitDo] -> ordered: " .. table.concat(o2, " | "))
local agree = (o1[1] == o2[1]) and (o1[2] == o2[2])
say("orders agree: " .. tostring(agree))

-- ---- and therefore the two players take DIFFERENT devices
local _, P1 = namesFor("1", { A, B })
local _, P2 = namesFor("2", { B, A })
local d1 = select(1, P1.status())
local d2 = select(1, P2.status())
say("player 1: " .. d1)
say("player 2: " .. d2)
say("distinct devices: " .. tostring(d1 ~= d2))

-- ---- old behaviour, for contrast: raw enumeration position
local raw1 = ({ A, B })[1]:getName()
local raw2 = ({ B, A })[2]:getName()
say("by raw position -> p1: " .. raw1)
say("by raw position -> p2: " .. raw2)
say("raw position collides: " .. tostring(raw1 == raw2))

-- ---- two IDENTICAL controllers: nothing distinguishes them, must still
-- ---- hand out two different objects rather than the same one twice
local _, Q1 = namesFor("1", { B, C })
local _, Q2 = namesFor("2", { B, C })
local q1 = Q1.ordered()[1]
local q2 = Q2.ordered()[2]
say("identical pair -> p1 and p2 take different objects: " .. tostring(q1 ~= q2))

local f = io.open(OUT, "w"); f:write(table.concat(lines, "\n")); f:close()
os.exit(0)
