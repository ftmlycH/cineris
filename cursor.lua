-- 战斗准星：屏幕中心西北向剑；可击中时变红。无鼠标操作。

local Cursor = {}

local combat = false

function Cursor.load()
    love.mouse.setVisible(false)
    love.mouse.setRelativeMode(false)
end

function Cursor.useSword()
    combat = true
    love.mouse.setVisible(false)
    love.mouse.setRelativeMode(false)
end

function Cursor.useDefault()
    combat = false
    love.mouse.setVisible(false)
    love.mouse.setRelativeMode(false)
end

function Cursor.inCombat()
    return combat
end

local function putPoly(pts, r, g, b, a)
    love.graphics.setColor(r, g, b, a)
    love.graphics.polygon("fill", pts)
end

-- 剑尖在中心（瞄准点），刃身朝东南 → 整体指向左上；刃身加长
function Cursor.drawCrosshair(onTarget)
    local W, H = love.graphics.getDimensions()
    local cx, cy = W * 0.5, H * 0.5
    local s = math.max(28, math.floor(H * 0.055 + 0.5))

    local ux, uy = -0.7071, -0.7071 -- 尖朝西北
    local vx, vy = -uy, ux           -- 刃侧向

    local tipX, tipY = cx, cy
    local guardT = 0.70
    local pomT = 0.92 -- 短柄
    local gx = cx - ux * s * guardT
    local gy = cy - uy * s * guardT
    local hx = cx - ux * s * pomT
    local hy = cy - uy * s * pomT
    local midX = cx - ux * s * 0.30
    local midY = cy - uy * s * 0.30

    local bladeW = s * 0.10
    local tipW = s * 0.02
    local guardW = s * 0.26
    local gripW = s * 0.06

    local sr, sg, sb = 0.86, 0.88, 0.94
    local hr, hg, hb = 0.55, 0.38, 0.22
    local gr, gg, gb = 0.72, 0.62, 0.35
    if onTarget then
        sr, sg, sb = 0.95, 0.18, 0.16
        hr, hg, hb = 0.55, 0.12, 0.1
        gr, gg, gb = 0.85, 0.25, 0.18
    end

    -- 阴影
    local ox, oy = 1.4, 1.4
    putPoly({
        tipX + ox, tipY + oy,
        midX + vx * tipW + ox, midY + vy * tipW + oy,
        gx + vx * bladeW + ox, gy + vy * bladeW + oy,
        gx - vx * bladeW + ox, gy - vy * bladeW + oy,
        midX - vx * tipW + ox, midY - vy * tipW + oy,
    }, 0, 0, 0, 0.35)

    -- 刃身（菱形锥，加长）
    putPoly({
        tipX, tipY,
        midX + vx * tipW, midY + vy * tipW,
        gx + vx * bladeW, gy + vy * bladeW,
        gx - vx * bladeW, gy - vy * bladeW,
        midX - vx * tipW, midY - vy * tipW,
    }, sr, sg, sb, 0.98)

    -- 刃脊高光
    love.graphics.setLineWidth(math.max(1, s * 0.035))
    love.graphics.setColor(1, 1, 1, onTarget and 0.35 or 0.55)
    love.graphics.line(tipX, tipY, gx, gy)

    -- 护手
    putPoly({
        gx + vx * guardW, gy + vy * guardW,
        gx + vx * guardW * 0.2 - ux * s * 0.06, gy + vy * guardW * 0.2 - uy * s * 0.06,
        gx - vx * guardW * 0.2 - ux * s * 0.06, gy - vy * guardW * 0.2 - uy * s * 0.06,
        gx - vx * guardW, gy - vy * guardW,
        gx - ux * s * 0.04, gy - uy * s * 0.04,
    }, gr, gg, gb, 1)

    -- 柄
    putPoly({
        gx + vx * gripW - ux * s * 0.02, gy + vy * gripW - uy * s * 0.02,
        hx + vx * gripW * 0.85, hy + vy * gripW * 0.85,
        hx - vx * gripW * 0.85, hy - vy * gripW * 0.85,
        gx - vx * gripW - ux * s * 0.02, gy - vy * gripW - uy * s * 0.02,
    }, hr, hg, hb, 1)

    -- 柄头
    love.graphics.setColor(gr, gg, gb, 1)
    love.graphics.circle("fill", hx - ux * s * 0.02, hy - uy * s * 0.02, math.max(2, s * 0.065))

    -- 瞄准核（剑尖）
    love.graphics.setColor(sr, sg, sb, 1)
    love.graphics.circle("fill", tipX, tipY, math.max(1.5, s * 0.04))

    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

return Cursor
