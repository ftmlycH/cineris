-- 射线：墙体网格步进 + Bresenham 视线（整数格，供 AI/精灵遮挡）

local Assets = require("assets")
local Fonts = require("fonts")

local Ray = {}

local FOV = math.pi / 3
local MAX_DIST = 12
local FOG_START = 2.8   -- 开始变暗的距离
local FOG_END = MAX_DIST -- 最远处近黑

local COL_STEP = 4 -- 墙柱步长；略增以减 draw 次数
local MAX_STEPS = math.floor(MAX_DIST * 3) + 4
local AIM_EXPAND = 1.06
-- 怪物统一碰撞盒（与贴图宽高无关；随距离透视缩放）
local ENEMY_HIT_ASPECT = 0.48
local ENEMY_HIT_SIZE = 0.66

local wallTex, bgTex, strip, texW, texH, bgW, bgH, getCell
local floor, abs, cos, sin, atan2, sqrt = math.floor, math.abs, math.cos, math.sin, math.atan2, math.sqrt
local visBuf, visPool = {}, {}
local frameW, frameH = 0, 0
local aimPad, aimMinW, aimMinH = 3, 18, 26
local boxPool, boxPoolN = {}, 0
local visSort = function(a, b) return a.p.dist > b.p.dist end

-- 距离雾：0 清晰 → 1 沉入阴影（平滑曲线，避免断层）
local function fogAmount(z)
    if z <= FOG_START then return 0 end
    if z >= FOG_END then return 1 end
    local t = (z - FOG_START) / (FOG_END - FOG_START)
    -- 更缓的起势，减少相邻墙柱明暗跳变
    return t * t
end

local function shadeRgb(z, r, g, b)
    local f = fogAmount(z)
    local keep = 1 - f * 0.92
    return r * keep * 0.88, g * keep * 0.86, b * keep * 0.84
end

local function acquireBox()
    boxPoolN = boxPoolN + 1
    local t = boxPool[boxPoolN]
    if not t then
        t = { vis = {} }
        boxPool[boxPoolN] = t
    elseif not t.vis then
        t.vis = {}
    end
    return t
end

-- 每帧绘制/瞄准前调用：缓存分辨率与判定常量，重置盒池
function Ray.beginFrame(W, H)
    frameW, frameH = W, H
    aimPad = Fonts.px(3)
    aimMinW = Fonts.px(18)
    aimMinH = Fonts.px(26)
    boxPoolN = 0
end

-- 相对朝向的列角缓存（随分辨率重建）
local colCos, colSin, colFish, colCacheW

local function rebuildColCache(W)
    if colCacheW == W and colCos then return end
    colCacheW = W
    colCos, colSin, colFish = {}, {}, {}
    local invW, half = 1 / W, FOV * 0.5
    local i = 1
    for col = 0, W - 1, COL_STEP do
        local rel = -half + col * invW * FOV
        colCos[i] = cos(rel)
        colSin[i] = sin(rel)
        colFish[i] = cos(rel) -- 鱼眼校正：z = dist * cos(rel)
        i = i + 1
    end
end

function Ray.setTextures(wallPath, bgPath)
    wallTex = Assets.image(wallPath)
    bgTex = Assets.image(bgPath)
    if not wallTex or not bgTex then return end
    texW, texH = wallTex:getDimensions()
    bgW, bgH = bgTex:getDimensions()
    strip = love.graphics.newQuad(0, 0, 1, texH, texW, texH)
end

function Ray.setCellFn(fn)
    getCell = fn
end

function Ray.setScene(grid, wallPath, bgPath)
    Ray.setTextures(wallPath, bgPath)
    local rows, cols = #grid, #grid[1]
    Ray.setCellFn(function(wx, wy)
        local c, r = wx + 1, wy + 1
        if r < 1 or r > rows or c < 1 or c > cols then return 1 end
        return grid[r][c]
    end)
end

function Ray.isWall(x, y)
    if not getCell then return true end
    return getCell(floor(x), floor(y)) == 1
end

function Ray.slide(x, y, nx, ny)
    if not Ray.isWall(nx, y) then x = nx end
    if not Ray.isWall(x, ny) then y = ny end
    return x, y
end

-- 朝向射线打中的格子：DDA 收集 maxDist 内非墙格，再匹配敌人所在格
-- 返回 enemies 下标与距离（沿射线），取最近者
function Ray.aimRayEnemy(px, py, pa, enemies, maxDist)
    if not getCell or not enemies or #enemies == 0 then return nil end
    maxDist = maxDist or 3
    if maxDist < 0.4 then maxDist = 0.4 end
    local dx, dy = cos(pa), sin(pa)
    if abs(dx) < 1e-8 and abs(dy) < 1e-8 then return nil end

    -- cellKey -> true
    local hitCells = {}
    local mapX, mapY = floor(px), floor(py)
    hitCells[mapX * 131071 + mapY] = true

    local deltaX = dx == 0 and 1e30 or abs(1 / dx)
    local deltaY = dy == 0 and 1e30 or abs(1 / dy)
    local stepX, sideX, stepY, sideY
    if dx < 0 then
        stepX, sideX = -1, (px - mapX) * deltaX
    else
        stepX, sideX = 1, (mapX + 1 - px) * deltaX
    end
    if dy < 0 then
        stepY, sideY = -1, (py - mapY) * deltaY
    else
        stepY, sideY = 1, (mapY + 1 - py) * deltaY
    end

    local maxSteps = math.floor(maxDist * 4) + 4
    for _ = 1, maxSteps do
        local dist
        if sideX < sideY then
            dist = sideX
            sideX = sideX + deltaX
            mapX = mapX + stepX
        else
            dist = sideY
            sideY = sideY + deltaY
            mapY = mapY + stepY
        end
        if dist > maxDist then break end
        if getCell(mapX, mapY) == 1 then break end
        hitCells[mapX * 131071 + mapY] = true
    end

    local bestI, bestDist
    for i = 1, #enemies do
        local e = enemies[i]
        if e and (not e.hp or e.hp > 0) and e.role == "enemy" then
            local ecx, ecy = floor(e.x), floor(e.y)
            if hitCells[ecx * 131071 + ecy] then
                local ex, ey = e.x - px, e.y - py
                local along = ex * dx + ey * dy
                if along > 0.12 and along <= maxDist + 0.35 then
                    if not bestDist or along < bestDist then
                        bestDist, bestI = along, i
                    end
                end
            end
        end
    end
    return bestI, bestDist
end

-- 指定敌人是否在朝向射线格子上（格挡瞄准；无临时表分配）
function Ray.enemyOnAimRay(px, py, pa, e, maxDist)
    if not e or not getCell then return false end
    maxDist = maxDist or 3
    local dx, dy = cos(pa), sin(pa)
    if abs(dx) < 1e-8 and abs(dy) < 1e-8 then return false end
    local ecx, ecy = floor(e.x), floor(e.y)
    local ex, ey = e.x - px, e.y - py
    local along = ex * dx + ey * dy
    if along <= 0.12 or along > maxDist + 0.35 then return false end

    local mapX, mapY = floor(px), floor(py)
    if mapX == ecx and mapY == ecy then return true end

    local deltaX = dx == 0 and 1e30 or abs(1 / dx)
    local deltaY = dy == 0 and 1e30 or abs(1 / dy)
    local stepX, sideX, stepY, sideY
    if dx < 0 then
        stepX, sideX = -1, (px - mapX) * deltaX
    else
        stepX, sideX = 1, (mapX + 1 - px) * deltaX
    end
    if dy < 0 then
        stepY, sideY = -1, (py - mapY) * deltaY
    else
        stepY, sideY = 1, (mapY + 1 - py) * deltaY
    end

    local maxSteps = math.floor(maxDist * 4) + 4
    for _ = 1, maxSteps do
        local dist
        if sideX < sideY then
            dist = sideX
            sideX = sideX + deltaX
            mapX = mapX + stepX
        else
            dist = sideY
            sideY = sideY + deltaY
            mapY = mapY + stepY
        end
        if dist > maxDist then return false end
        if getCell(mapX, mapY) == 1 then return false end
        if mapX == ecx and mapY == ecy then return true end
    end
    return false
end

------------------------------------------------------------
-- 墙体：Amanatides–Woo 网格步进（连续距离 + 贴图 u；墙柱必需）
------------------------------------------------------------
local function castWall(px, py, dx, dy)
    local mapX, mapY = floor(px), floor(py)
    local deltaX = dx == 0 and 1e30 or abs(1 / dx)
    local deltaY = dy == 0 and 1e30 or abs(1 / dy)

    local stepX, sideX, stepY, sideY
    if dx < 0 then
        stepX, sideX = -1, (px - mapX) * deltaX
    else
        stepX, sideX = 1, (mapX + 1 - px) * deltaX
    end
    if dy < 0 then
        stepY, sideY = -1, (py - mapY) * deltaY
    else
        stepY, sideY = 1, (mapY + 1 - py) * deltaY
    end

    local side = 0
    for _ = 1, MAX_STEPS do
        if sideX < sideY then
            sideX = sideX + deltaX
            mapX = mapX + stepX
            side = 0
        else
            sideY = sideY + deltaY
            mapY = mapY + stepY
            side = 1
        end

        if getCell(mapX, mapY) == 1 then
            local dist = side == 0
                and (mapX - px + (1 - stepX) * 0.5) / dx
                or (mapY - py + (1 - stepY) * 0.5) / dy
            if dist < 0.01 then dist = 0.01 end
            if dist > MAX_DIST then return end

            local u = side == 0 and (py + dist * dy) or (px + dist * dx)
            u = u - floor(u)
            if (side == 0 and dx > 0) or (side == 1 and dy < 0) then u = 1 - u end
            return dist, u, side
        end
    end
end

------------------------------------------------------------
-- 视线：超覆盖 Bresenham（整数格，对角穿墙也挡）
------------------------------------------------------------
local function losBlocked(x0, y0, x1, y1)
    local gx0, gy0 = floor(x0), floor(y0)
    local gx1, gy1 = floor(x1), floor(y1)
    local dx, dy = abs(gx1 - gx0), abs(gy1 - gy0)
    local sx = gx0 < gx1 and 1 or -1
    local sy = gy0 < gy1 and 1 or -1
    local err = dx - dy
    local x, y = gx0, gy0

    while not (x == gx1 and y == gy1) do
        local e2 = err + err
        local movedX, movedY = false, false
        if e2 > -dy then
            err = err - dy
            x = x + sx
            movedX = true
        end
        if e2 < dx then
            err = err + dx
            y = y + sy
            movedY = true
        end
        -- 对角步进时，若两侧正交格都是墙则视为挡住（防穿角）
        if movedX and movedY then
            if getCell(x - sx, y) == 1 and getCell(x, y - sy) == 1 then
                return true
            end
        end
        if x == gx1 and y == gy1 then break end
        if getCell(x, y) == 1 then return true end
    end
    return false
end

function Ray.canSee(ex, ey, px, py, maxDist)
    if not getCell then return false, maxDist end
    local dx, dy = px - ex, py - ey
    local dist2 = dx * dx + dy * dy
    local max2 = maxDist * maxDist
    if dist2 > max2 then return false, sqrt(dist2) end
    local dist = sqrt(dist2)
    if dist < 0.15 then return true, dist end
    if losBlocked(ex, ey, px, py) then return false, dist end
    return true, dist
end

-- out 可选：写入复用表，避免每精灵分配
function Ray.project(px, py, pa, ex, ey, aspect, sizeMul, out)
    if not getCell then return end
    aspect = aspect or 1
    sizeMul = sizeMul or 1
    local W, H = frameW, frameH
    if W <= 0 or H <= 0 then
        W, H = love.graphics.getDimensions()
        frameW, frameH = W, H
    end
    local dx, dy = ex - px, ey - py
    local dist2 = dx * dx + dy * dy
    if dist2 >= MAX_DIST * MAX_DIST or dist2 < 1e-8 then return end

    local dist = sqrt(dist2)
    local ang = (atan2(dy, dx) - pa + math.pi) % (math.pi * 2) - math.pi
    if abs(ang) >= FOV * 0.5 then return end
    if losBlocked(px, py, ex, ey) then return end

    local z = dist * cos(ang)
    if z < 0.2 then z = 0.2 end
    local wallH = H / z
    local bh = wallH * 0.65 * sizeMul
    if bh > wallH then bh = wallH end
    local bw = bh * aspect
    local bottom = H * 0.5 + wallH * 0.5
    local sx = (0.5 + ang / FOV) * W
    out = out or acquireBox()
    out.sx, out.bottom, out.bw, out.bh, out.dist = sx, bottom, bw, bh, z
    out.top = bottom - bh
    out.left = sx - bw * 0.5
    out.right = sx + bw * 0.5
    return out
end

-- 与绘制一致的精灵屏幕盒（scale>1 相对放大；scale 为像素增量时兼容旧语义）
function Ray.spriteBox(px, py, pa, ex, ey, aspect, scale, sizeMul, out)
    local p = Ray.project(px, py, pa, ex, ey, aspect, sizeMul, out)
    if not p then return end
    scale = scale or 1
    local bw, bh
    if scale > 1 then
        bw, bh = p.bw * scale, p.bh * scale
    elseif scale > 0 and scale ~= 1 then
        bw, bh = p.bw + scale, p.bh + scale
    else
        bw, bh = p.bw, p.bh
    end
    p.bw, p.bh = bw, bh
    p.left = p.sx - bw * 0.5
    p.right = p.sx + bw * 0.5
    p.top = p.bottom - bh
    return p
end

-- 瞄准用判定盒：略大于贴图 + 很小最小尺寸（子弹等仍可用）
function Ray.aimHitBox(px, py, pa, ex, ey, aspect, scale, sizeMul, opts)
    opts = opts or {}
    local hit = acquireBox()
    local vis = hit.vis
    local box = Ray.spriteBox(px, py, pa, ex, ey, aspect, scale, sizeMul, vis)
    if not box then return end
    local expand = opts.expand or AIM_EXPAND
    local minW = opts.minW or aimMinW
    local minH = opts.minH or aimMinH
    local cx = (box.left + box.right) * 0.5
    local cy = (box.top + box.bottom) * 0.5
    local hw = math.max((box.right - box.left) * 0.5 * expand, minW * 0.5)
    local hh = math.max((box.bottom - box.top) * 0.5 * expand, minH * 0.5)
    hit.left, hit.right = cx - hw, cx + hw
    hit.top, hit.bottom = cy - hh, cy + hh
    hit.dist, hit.sx = box.dist, cx
    hit.bw, hit.bh = hw * 2, hh * 2
    return hit
end

-- 怪物统一碰撞盒：固定宽高比与体型，不跟贴图走
function Ray.enemyHitBox(px, py, pa, ex, ey, scale, out)
    local hit = out or acquireBox()
    local box = Ray.project(px, py, pa, ex, ey, ENEMY_HIT_ASPECT, ENEMY_HIT_SIZE, hit)
    if not box then return end
    scale = scale or 1
    if scale ~= 1 and scale > 0 then
        local cx = (box.left + box.right) * 0.5
        local cy = (box.top + box.bottom) * 0.5
        local hw, hh
        if scale > 1 then
            hw, hh = box.bw * 0.5 * scale, box.bh * 0.5 * scale
        else
            hw, hh = box.bw * 0.5 + scale * 0.5, box.bh * 0.5 + scale * 0.5
        end
        box.left, box.right = cx - hw, cx + hw
        box.top, box.bottom = cy - hh, cy + hh
        box.bw, box.bh = hw * 2, hh * 2
        box.sx = cx
    end
    return box
end

local function pointInBox(mx, my, box, pad)
    pad = pad or 0
    return mx + pad >= box.left and mx - pad <= box.right
        and my + pad >= box.top and my - pad <= box.bottom
end

function Ray.pointInBox(mx, my, box, pad)
    return box and pointInBox(mx, my, box, pad)
end

local function resolveBox(px, py, pa, n, scale, opts)
    if opts.unified then
        return Ray.enemyHitBox(px, py, pa, n.x, n.y, scale)
    end
    if opts.expand == false then
        return Ray.spriteBox(px, py, pa, n.x, n.y, n.aspect, scale, n.size)
    end
    local ex = type(opts.expand) == "number" and opts.expand or AIM_EXPAND
    return Ray.aimHitBox(px, py, pa, n.x, n.y, n.aspect, scale, n.size, {
        expand = ex, minW = opts.minW, minH = opts.minH,
    })
end

-- 单目标命中（避免临时 {e} 分配）
function Ray.hitsOne(px, py, pa, n, mx, my, opts)
    if not n or (n.hp and n.hp <= 0) then return false end
    opts = opts or {}
    local pad = opts.pad
    if pad == nil then pad = opts.unified and 0 or aimPad end
    local scale = 1
    if opts.scaleOf then scale = opts.scaleOf(n) or 1
    elseif n.grow and n.grow > 0 then scale = n.grow end
    local box = resolveBox(px, py, pa, n, scale, opts)
    if not box then return false end
    if opts.maxDist and box.dist > opts.maxDist then return false end
    return pointInBox(mx, my, box, pad), box.dist
end

-- 瞄准：准星/指针落在可见目标上；取最近者。
-- opts: role, maxDist, pad, scaleOf, expand, unified, minW, minH
function Ray.aim(px, py, pa, list, mx, my, opts)
    opts = opts or {}
    local role, maxDist = opts.role, opts.maxDist
    local pad = opts.pad
    if pad == nil then pad = opts.unified and 0 or aimPad end
    local scaleOf = opts.scaleOf
    local bestDist, bestI
    for i = 1, #(list or {}) do
        local n = list[i]
        if (not role or n.role == role) and (not n.hp or n.hp > 0) then
            local scale = 1
            if scaleOf then
                scale = scaleOf(n) or 1
            elseif n.grow and n.grow > 0 then
                scale = n.grow
            end
            local box = resolveBox(px, py, pa, n, scale, opts)
            if box and (not maxDist or box.dist <= maxDist)
                and pointInBox(mx, my, box, pad)
                and (not bestDist or box.dist < bestDist) then
                bestDist, bestI = box.dist, i
            end
        end
    end
    return bestI, bestDist
end

-- 兼容旧调用
function Ray.pick(px, py, pa, list, mx, my, role, maxDist)
    return Ray.aim(px, py, pa, list, mx, my, { role = role, maxDist = maxDist })
end

function Ray.draw(px, py, pa, sprites)
    if not wallTex or not bgTex or not getCell then return end
    local W, H = frameW, frameH
    if W <= 0 or H <= 0 then
        W, H = love.graphics.getDimensions()
        Ray.beginFrame(W, H)
    end
    rebuildColCache(W)

    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(bgTex, 0, 0, 0, W / bgW, H / bgH)
    -- 环境压暗（整屏均匀）
    love.graphics.setColor(0.01, 0.0, 0.02, 0.38)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- 墙柱：按真实距离雾化明暗（只作用在墙面上，不画横竖雾条）
    local cpa, spa = cos(pa), sin(pa)
    local ci = 1
    for col = 0, W - 1, COL_STEP do
        local rcx, rsx = colCos[ci], colSin[ci]
        local dx = cpa * rcx - spa * rsx
        local dy = spa * rcx + cpa * rsx
        local dist, u = castWall(px, py, dx, dy)
        if dist then
            local z = dist * colFish[ci]
            if z < 0.01 then z = 0.01 end
            local wh = H / z
            local sr, sg, sb = shadeRgb(z, 1, 1, 1)
            love.graphics.setColor(sr, sg, sb)
            strip:setViewport(floor(u * texW) % texW, 0, 1, texH)
            love.graphics.draw(wallTex, strip, col, H * 0.5 - wh * 0.5, 0, COL_STEP, wh / texH)
        end
        ci = ci + 1
    end

    local nVis = 0
    for i = 1, #(sprites or {}) do
        local n = sprites[i]
        nVis = nVis + 1
        local slot = visPool[nVis]
        if not slot then
            slot = { p = {} }
            visPool[nVis] = slot
        elseif not slot.p then
            slot.p = {}
        end
        local p = Ray.project(px, py, pa, n.x, n.y, n.aspect, n.size, slot.p)
        if p then
            slot.n = n
            visBuf[nVis] = slot
        else
            nVis = nVis - 1
        end
    end
    for i = nVis + 1, #visBuf do visBuf[i] = nil end
    if nVis > 1 then table.sort(visBuf, visSort) end

    for i = 1, nVis do
        local n, p = visBuf[i].n, visBuf[i].p
        local grow = n.grow or 0
        local bw, bh
        if grow > 1 then
            bw, bh = p.bw * grow, p.bh * grow
        else
            bw, bh = p.bw + grow, p.bh + grow
        end
        local left = p.sx - bw * 0.5
        local top = p.bottom - bh
        local r, g, b = 1, 1, 1
        if n.hurt then
            r, g, b = 0.72, 0.05, 0.08
        elseif not n.img then
            if n.role == "enemy" then
                r, g, b = 0.45, 0.35, 0.3
            elseif n.role == "save" then
                r, g, b = 0.78, 0.58, 0.32
            else
                r, g, b = 0.25, 0.55, 0.35
            end
        end
        r, g, b = shadeRgb(p.dist or 0, r, g, b)
        love.graphics.setColor(r, g, b)
        local additive = n.role == "bullet"
        if additive then love.graphics.setBlendMode("add") end
        if n.img and n.iw and n.ih and n.iw > 0 and n.ih > 0 then
            if n.quad then
                love.graphics.draw(n.img, n.quad, left, top, 0, bw / n.iw, bh / n.ih)
            else
                love.graphics.draw(n.img, left, top, 0, bw / n.iw, bh / n.ih)
            end
        else
            love.graphics.rectangle("fill", left, top, bw, bh)
        end
        if additive then love.graphics.setBlendMode("alpha") end
    end
end

function Ray.drawMiniMap(px, py, pa)
    if not getCell then return end
    local s = math.max(3, floor(Fonts.px(5) + 0.5))
    local view = 16
    local ox, oy = Fonts.px(8), Fonts.px(8)
    local x0, y0 = floor(px) - view, floor(py) - view
    local x1, y1 = floor(px) + view, floor(py) + view

    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", ox - 2, oy - 2, (x1 - x0 + 1) * s + 4, (y1 - y0 + 1) * s + 4)

    for y = y0, y1 do
        for x = x0, x1 do
            local v = getCell(x, y)
            if v ~= 0 then
                local wall = v == 1
                love.graphics.setColor(wall and 0.5 or 0.2, wall and 0.5 or 0.8, wall and 0.5 or 0.4)
                love.graphics.rectangle("fill", ox + (x - x0) * s, oy + (y - y0) * s, s - 1, s - 1)
            end
        end
    end

    local mx = ox + (px - x0) * s
    local my = oy + (py - y0) * s
    love.graphics.setColor(1, 1, 0)
    love.graphics.circle("fill", mx, my, math.max(2, s * 0.4))
    love.graphics.line(mx, my, mx + cos(pa) * s * 1.2, my + sin(pa) * s * 1.2)
end

return Ray
