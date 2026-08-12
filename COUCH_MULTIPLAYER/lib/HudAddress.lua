-- Show the address, on screen, while nobody is connected.
--
-- The host has always known its own address -- ghostlink-status.txt has said
-- `hosting 192.168.50.162:7778` since the first version -- but a file in the
-- save directory is no use to the person holding the other controller. They
-- need it on the television.
--
-- Only while there is nobody to talk to. Once a peer arrives this is clutter
-- over the game, so it goes. That also makes it a connection indicator by
-- accident: text on screen means nobody is there yet, and it vanishing is the
-- confirmation that someone arrived.
--
-- Drawn in screen space over the finished frame, which is what render.hud is
-- for -- the engine calls it after the render pipelines have composed, with a
-- viewport carrying the playfield's real position and size:
--
--   { width, height, gameX, gameY, gameWidth, gameHeight, scale, dpiX, dpiY }
--
-- so this sits over the game rather than guessing where the game is on a
-- window that might be tiled to half a super-ultrawide.

local V = ...

local HudAddress = {}

-- Fonts are expensive to build and cheap to keep. One per pixel size, made
-- once -- a new font every frame would cost more than everything else this
-- mod draws put together.
local fontCache = {}
local function fontFor(px)
  px = math.max(8, math.floor(px))
  if not fontCache[px] then
    local ok, f = pcall(love.graphics.newFont, px)
    fontCache[px] = ok and f or false
  end
  return fontCache[px] or nil
end

-- What to say, or nil for "say nothing".
--
-- Deliberately silent once connected, and deliberately silent when ghosts are
-- off entirely: a single player who never enabled any of this should never
-- see a line of network chatter over their game.
function HudAddress.text(info)
  if not info then return nil end
  if info.mode == "off" then return nil end
  if (info.peers or 0) > 0 then return nil end

  if info.role == "host" then
    local addr = info.address
    if not addr or addr == "" then return "STARTING SESSION..." end
    return "OTHERS JOIN: " .. tostring(addr)
  elseif info.role == "join" then
    return "LOOKING FOR " .. tostring(info.join or "?")
  end
  return nil
end

function HudAddress.draw(viewport, info)
  local text = HudAddress.text(info)
  if not text then return end
  if not (love and love.graphics and viewport) then return end

  local gx = viewport.gameX or 0
  local gy = viewport.gameY or 0
  local gw = viewport.gameWidth or viewport.width or 0
  local gh = viewport.gameHeight or viewport.height or 0
  if gw <= 0 or gh <= 0 then return end

  -- Sized from the PLAYFIELD, not the window: on a split screen the window is
  -- half as wide but the game inside it is the same 160x144, so scaling to
  -- the window would make this twice the size it should be for player 1 and
  -- wrong again for player 3.
  local font = fontFor(gh / 16)
  if not font then return end

  local pad = math.max(2, math.floor(gh / 72))
  local tw = font:getWidth(text)
  local th = font:getHeight()
  local bw = tw + pad * 4
  local bh = th + pad * 2
  -- Bottom of the playfield: the top carries the textbox in a lot of scenes,
  -- and the bottom is empty far more often.
  local bx = gx + math.floor((gw - bw) / 2)
  local by = gy + gh - bh - pad * 2

  local r, g, b, a = love.graphics.getColor()
  local prevFont = love.graphics.getFont()

  love.graphics.setColor(0, 0, 0, 0.72)
  love.graphics.rectangle("fill", bx, by, bw, bh, pad, pad)
  love.graphics.setColor(1, 1, 1, 0.95)
  love.graphics.setFont(font)
  love.graphics.print(text, bx + pad * 2, by + pad)

  love.graphics.setColor(r, g, b, a)
  if prevFont then love.graphics.setFont(prevFont) end
end

return HudAddress
