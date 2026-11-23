local Fonts = {}
local EN = "Alice-In-Wonderland/AliceInWonderland-1GzL0-2.ttf"
local ZH = "HanYiXiangSu-11px-U/HYPixel11pxU-2.ttf"
local BASE_H = 1080

Fonts.scale = 1

local function make(n)
    local f = love.graphics.newFont(EN, n)
    f:setFallbacks(love.graphics.newFont(ZH, n))
    return f
end

function Fonts.reload()
    local H = love.graphics.getHeight()
    if H < 1 then H = BASE_H end
    local s = H / BASE_H
    Fonts.scale = s
    local ui = math.max(12, math.floor(22 * s + 0.5))
    local title = math.max(28, math.floor(72 * s + 0.5))
    Fonts.ui, Fonts.title = make(ui), make(title)
    love.graphics.setFont(Fonts.ui)
end

Fonts.load = Fonts.reload

-- 设计稿像素 → 当前分辨率
function Fonts.px(n)
    return n * Fonts.scale
end

return Fonts
