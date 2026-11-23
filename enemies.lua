-- 敌人：生成 / 待机 / AI / 子弹 / 受击结算

local Data = require("data")
local Gen = require("genmap")
local Ray = require("raycasting")
local Assets = require("assets")

local Ents = Data.entities
local MELEE_1 = Ents.byKey.melee_1

local VIEW = 8
local KEEP = VIEW + 8          -- 超出则从列表剔除，回到视野可再 sync
local ATK_FX = 1.0 -- 攻击放大持续一秒
-- 与玩家最小间距：贴身但仍能看见精灵
local MIN_SEP = 0.95
local MIN_SEP2 = MIN_SEP * MIN_SEP
local IDLE_WAIT_LO, IDLE_WAIT_HI = 1.1, 2.6
local IDLE_DIRS = {
    { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}
local idleOrder = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
local LOS_CACHE = 0.14 -- 视线结果短缓存，减 Bresenham

-- 刷怪占用键（支持负坐标，避免字符串拼接）
local function spawnKey(sx, sy)
    return math.floor(sx) * 131071 + math.floor(sy)
end

local function refreshLos(e, px, py, vision, dt)
    local ecx, ecy = math.floor(e.x), math.floor(e.y)
    local pcx, pcy = math.floor(px), math.floor(py)
    e._losT = (e._losT or 0) - dt
    if e._losT > 0 and e._losEcx == ecx and e._losEcy == ecy
        and e._losPcx == pcx and e._losPcy == pcy then
        return e._canSee
    end
    e._losT = LOS_CACHE
    e._losEcx, e._losEcy, e._losPcx, e._losPcy = ecx, ecy, pcx, pcy
    e._canSee = Ray.canSee(e.x, e.y, px, py, vision)
    return e._canSee
end

local BULLET_PATH = "resources/bullet5.png"
local BULLET_COLS, BULLET_ROWS = 4, 4
local BULLET_COLORS = 8          -- 前两行共 8 色
local BULLET_DEFAULT = 1         -- 默认第一种（红）
local BULLET_SPEED = 4.4
local BULLET_HIT = 0.26
local BULLET_HIT2 = BULLET_HIT * BULLET_HIT
local BULLET_SIZE = 0.32
local BULLET_LIFE = 1.55 -- 约 6~7 格射程，贴合远程交战距

local Enemies = { ATK_SCALE = 1.1, BULLET_DEFAULT = BULLET_DEFAULT, MIN_SEP = MIN_SEP }

local bulletSheet, bulletQuads, bulletCW, bulletCH

local function ensureBulletSheet()
    if bulletQuads then return bulletSheet ~= nil end
    bulletSheet = Assets.image(BULLET_PATH)
    bulletQuads = {}
    if not bulletSheet then return false end
    local tw, th = bulletSheet:getDimensions()
    bulletCW = math.floor(tw / BULLET_COLS)
    bulletCH = math.floor(th / BULLET_ROWS)
    for i = 1, BULLET_COLORS do
        local idx = i - 1
        local col, row = idx % BULLET_COLS, math.floor(idx / BULLET_COLS)
        bulletQuads[i] = love.graphics.newQuad(
            col * bulletCW, row * bulletCH, bulletCW, bulletCH, tw, th
        )
    end
    return true
end

function Enemies.bulletQuad(index)
    if not ensureBulletSheet() then return nil, nil, 1, 1 end
    local i = index or BULLET_DEFAULT
    if i < 1 or i > BULLET_COLORS then i = BULLET_DEFAULT end
    return bulletSheet, bulletQuads[i], bulletCW, bulletCH
end

local function bindLook(def, sceneKey)
    return Assets.bindLook(def, sceneKey)
end

local function tryStep(e, nx, ny, px, py)
    nx, ny = Ray.slide(e.x, e.y, nx, ny)
    if px and py then
        local dx, dy = nx - px, ny - py
        local d2 = dx * dx + dy * dy
        if d2 < MIN_SEP2 then
            local odx, ody = e.x - px, e.y - py
            local o2 = odx * odx + ody * ody
            -- 禁止再靠近玩家；可侧向滑动时保留不更近的落点
            if d2 <= o2 + 1e-8 then
                return false
            end
        end
        -- 禁止进入玩家所在地图格
        if math.floor(nx) == math.floor(px) and math.floor(ny) == math.floor(py) then
            return false
        end
    end
    local moved = (nx - e.x) * (nx - e.x) + (ny - e.y) * (ny - e.y) > 1e-8
    e.x, e.y = nx, ny
    return moved
end

-- 把过近的敌人推开，保证可见距离与不同格
local function enforceSep(e, px, py)
    local dx, dy = e.x - px, e.y - py
    local d2 = dx * dx + dy * dy
    if d2 < MIN_SEP2 then
        local d = math.sqrt(d2)
        local nx, ny
        if d < 1e-4 then
            nx, ny = px + MIN_SEP, py
        else
            local s = MIN_SEP / d
            nx, ny = px + dx * s, py + dy * s
        end
        e.x, e.y = Ray.slide(e.x, e.y, nx, ny)
        dx, dy = e.x - px, e.y - py
        d2 = dx * dx + dy * dy
        if d2 < MIN_SEP2 then
            d = math.sqrt(math.max(d2, 1e-8))
            e.x = px + dx / d * MIN_SEP
            e.y = py + dy / d * MIN_SEP
        end
    end
    if math.floor(e.x) == math.floor(px) and math.floor(e.y) == math.floor(py) then
        dx, dy = e.x - px, e.y - py
        local ang = math.atan2(dy, dx)
        if dx * dx + dy * dy < 1e-8 then ang = love.math.random() * math.pi * 2 end
        e.x = px + math.cos(ang) * MIN_SEP
        e.y = py + math.sin(ang) * MIN_SEP
    end
end

local function pickIdleCell(e)
    for i = #idleOrder, 2, -1 do
        local j = love.math.random(i)
        idleOrder[i], idleOrder[j] = idleOrder[j], idleOrder[i]
    end
    for i = 1, #idleOrder do
        local d = IDLE_DIRS[idleOrder[i]]
        local tx, ty = e.hx + d[1], e.hy + d[2]
        if not Ray.isWall(tx, ty) then
            e.idleTx, e.idleTy = tx, ty
            return
        end
    end
    e.idleTx, e.idleTy = e.hx, e.hy
end

local function tickIdle(e, dt, px, py)
    if e.move == false then return false end
    e.idleWait = (e.idleWait or 0) - dt
    if e.idleWait <= 0 then
        pickIdleCell(e)
        e.idleWait = love.math.random() * (IDLE_WAIT_HI - IDLE_WAIT_LO) + IDLE_WAIT_LO
    end
    local dx, dy = e.idleTx - e.x, e.idleTy - e.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist > 0.05 then
        return tryStep(e, e.x + dx * (e.moveSpd * 0.4 * dt / dist), e.y + dy * (e.moveSpd * 0.4 * dt / dist), px, py)
    end
    return false
end

function Enemies.spawn(m, sceneKey, depth)
    local def = Ents.byId[m.id] or MELEE_1
    local c = def.combat or MELEE_1.combat
    local img, iw, ih, aspect = bindLook(def, sceneKey)
    local hx = math.floor(m.x) + 0.5
    local hy = math.floor(m.y) + 0.5
    local hp, atk = c.hp, c.atk
    local lootMin, lootMax = c.lootMin or 0, c.lootMax or 0
    -- 第 1 层=基础强度；更深时 HP 涨得比 ATK 快；Boss 同步随层加强
    depth = depth or 1
    if depth > 1 then
        local n = depth - 1
        local hpMul, atkMul, lootMul
        if def.boss then
            hpMul = 1 + n * 0.45
            atkMul = 1 + n * 0.20
            lootMul = 1 + n * 0.25
        else
            hpMul = 1 + n * 0.40
            atkMul = 1 + n * 0.18
            lootMul = 1 + n * 0.22
        end
        hp = math.max(1, math.floor(hp * hpMul + 0.5))
        atk = math.max(1, math.floor(atk * atkMul + 0.5))
        lootMin = math.max(0, math.floor(lootMin * lootMul + 0.5))
        lootMax = math.max(lootMin, math.floor(lootMax * lootMul + 0.5))
    end
    return {
        id = def.id, key = def.key, name = def.name, role = "enemy",
        x = m.x, y = m.y, sx = m.sx, sy = m.sy,
        hx = hx, hy = hy,
        hp = hp, atk = atk,
        style = c.style or "melee",
        move = c.move, blockable = c.blockable ~= false,
        neutral = def.neutral, flee = def.flee,
        atkCd = c.atkCd, moveSpd = c.moveSpd, vision = c.vision,
        atkRange = c.atkRange, hurtFlash = c.hurtFlash,
        lootMin = lootMin, lootMax = lootMax,
        boss = def.boss == true,
        bullet = c.bullet or BULLET_DEFAULT,
        fuseMax = c.fuse,
        fuse = nil,
        hurt = false, hurtT = 0, atkFx = 0,
        idleWait = love.math.random() * (IDLE_WAIT_HI - IDLE_WAIT_LO) + IDLE_WAIT_LO,
        idleTx = hx, idleTy = hy,
        cd = c.spawnCd,
        img = img, iw = iw, ih = ih, aspect = aspect,
    }
end

function Enemies.sync(world, spawned)
    if not world.infinite or world.testMode or world.bossMode then return end
    local found = Gen.monstersNear(world.px, world.py, VIEW + 6)
    local list = world.enemies
    local depth = world.depth or 1
    local key = world.key
    for i = 1, #found do
        local m = found[i]
        local k = spawnKey(m.sx, m.sy)
        if not spawned[k] then
            spawned[k] = true
            list[#list + 1] = Enemies.spawn(m, key, depth)
        end
    end
end

-- 测试区：每种敌人各一只，按 id 排成网格
function Enemies.spawnTestRoster()
    local defs = {}
    for _, def in pairs(Ents.byId) do
        if def.role == "enemy" then defs[#defs + 1] = def end
    end
    table.sort(defs, function(a, b) return a.id < b.id end)
    local list = {}
    local cols = 7
    local x0, y0, gap = 3.5, 3.5, 2.2
    for i = 1, #defs do
        local def = defs[i]
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local x = x0 + col * gap
        local y = y0 + row * gap
        local lookKey = def.specialty or "forest"
        local e = Enemies.spawn({ id = def.id, x = x, y = y, sx = x, sy = y }, lookKey)
        e.immortal = true
        list[#list + 1] = e
    end
    return list
end

local function fireBullet(world, e, px, py)
    local sheet, quad, cw, ch = Enemies.bulletQuad(e.bullet)
    if not sheet or not quad then return end
    -- 发射瞬间锁定方向，之后绝不朝玩家转向
    local dx, dy = px - e.x, py - e.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.05 then return end
    local dirX, dirY = dx / len, dy / len
    local bullets = world.bullets
    if not bullets then
        bullets = {}
        world.bullets = bullets
    end
    local ox, oy = e.x, e.y
    bullets[#bullets + 1] = {
        role = "bullet", label = "",
        ox = ox, oy = oy,           -- 起点（固定）
        dirX = dirX, dirY = dirY,   -- 方向（固定）
        traveled = 0,               -- 已飞行距离
        x = ox, y = oy,             -- 当前点（仅由 traveled 推导）
        atk = e.atk or 1,
        blockable = e.blockable ~= false,
        owner = e,
        img = sheet, quad = quad,
        iw = cw, ih = ch, aspect = 1,
        size = BULLET_SIZE,
        hp = 1, life = BULLET_LIFE,
    }
    e.atkFx = ATK_FX
end

local function resolveMeleeHit(world, e, fxPulse)
    if world.hp <= 0 then return false, nil end
    e.atkFx = ATK_FX
    local aimed = world.cursorOnEnemy and world.cursorOnEnemy(e)
    if aimed and world.blocking and e.blockable then
        fxPulse("shake", 0.55)
        return false, nil
    end
    if world.testMode then
        fxPulse("hurt", 0.45)
        return false, nil
    end
    world.hp = world.hp - (e.atk or 1)
    fxPulse("hurt", 0.45)
    if world.hp <= 0 then
        world.hp = 0
        return true, e
    end
    return false, nil
end

-- 子弹命中：按住格挡即可挡下（远程进攻可格挡）
local function resolveBulletHit(world, b, fxPulse)
    if world.hp <= 0 then return false, nil end
    if world.blocking and b.blockable ~= false then
        fxPulse("shake", 0.55)
        return false, nil
    end
    if world.testMode then
        fxPulse("hurt", 0.45)
        return false, nil
    end
    world.hp = world.hp - (b.atk or 1)
    fxPulse("hurt", 0.45)
    if world.hp <= 0 then
        world.hp = 0
        return true, b.owner or b
    end
    return false, nil
end

-- 点到线段最短距离²（本帧弹道路段 vs 玩家）
local function dist2PointSeg(px, py, x0, y0, x1, y1)
    local ax, ay = x1 - x0, y1 - y0
    local bx, by = px - x0, py - y0
    local ab = ax * ax + ay * ay
    local t = 0
    if ab > 1e-12 then
        t = (bx * ax + by * ay) / ab
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local qx, qy = x0 + ax * t - px, y0 + ay * t - py
    return qx * qx + qy * qy
end

local function tickBullets(world, dt, fxPulse)
    local list = world.bullets
    if not list or #list == 0 then return false, nil end
    local px, py = world.px, world.py
    local dead, killer, w = false, nil, 0
    for i = 1, #list do
        local b = list[i]
        local keep = true
        b.life = (b.life or 0) - dt
        if b.life <= 0 then
            keep = false
        else
            local x0, y0 = b.x, b.y
            b.traveled = (b.traveled or 0) + BULLET_SPEED * dt
            local x1 = b.ox + b.dirX * b.traveled
            local y1 = b.oy + b.dirY * b.traveled
            if Ray.isWall(x1, y1) then
                keep = false
            else
                b.x, b.y = x1, y1
                -- 只检测直线弹道是否擦过玩家，不朝玩家拐弯
                if dist2PointSeg(px, py, x0, y0, x1, y1) <= BULLET_HIT2 then
                    if not dead then
                        local d, k = resolveBulletHit(world, b, fxPulse)
                        if d then dead, killer = true, k end
                    end
                    keep = false
                end
            end
        end
        if keep then
            w = w + 1
            list[w] = b
        end
    end
    for i = w + 1, #list do list[i] = nil end
    return dead, killer
end

-- 自爆：爆炸瞬间结算，自身消失（测试区仅重置引信）
local function resolveSuicide(world, e, fxPulse, dist)
    e.atkFx = ATK_FX
    e.hurt, e.hurtT = true, e.hurtFlash or 0.4
    e.fuse = nil
    local blast = (e.atkRange or 0.75) + 0.25
    local dead, killer = false, nil
    if dist <= blast then
        local aimed = world.cursorOnEnemy and world.cursorOnEnemy(e)
        if aimed and world.blocking and e.blockable then
            fxPulse("shake", 0.6)
        elseif world.testMode then
            fxPulse("hurt", 0.5)
        else
            world.hp = world.hp - (e.atk or 1)
            fxPulse("hurt", 0.5)
            if world.hp <= 0 then
                world.hp = 0
                dead, killer = true, e
            end
        end
    end
    if world.testMode or e.immortal then
        e.cd = math.max(e.atkCd or 1.2, 1.0)
    else
        e.hp = 0
        if world.grantKillLoot then world.grantKillLoot(e) end
    end
    return dead, killer
end

local function tickSuicide(e, dt, px, py, world, fxPulse)
    local dx, dy = px - e.x, py - e.y
    local dist2 = dx * dx + dy * dy
    local vision = e.vision or 0
    local dist = math.sqrt(dist2)

    if e.fuse and e.fuse > 0 then
        -- 引信中站定，不移动
        e.fuse = e.fuse - dt
        e.atkFx = math.max(e.atkFx or 0, 0.35)
        enforceSep(e, px, py)
        if e.fuse <= 0 then
            return resolveSuicide(world, e, fxPulse, dist)
        end
        return false, nil
    end

    if dist2 > (vision + 0.75) * (vision + 0.75) then
        tickIdle(e, dt, px, py)
        enforceSep(e, px, py)
        return false, nil
    end
    if not refreshLos(e, px, py, vision, dt) then
        tickIdle(e, dt, px, py)
        enforceSep(e, px, py)
        return false, nil
    end

    local range = math.max(e.atkRange or MIN_SEP, MIN_SEP)
    if dist <= range then
        -- 已停步：冷却结束后才点引信（移动中不攻击）
        if (e.cd or 0) > 0 then
            e.cd = e.cd - dt
            enforceSep(e, px, py)
            return false, nil
        end
        e.fuse = e.fuseMax or 0.55
        e.atkFx = ATK_FX
        enforceSep(e, px, py)
        return false, nil
    end

    -- 接近中：只移动，不攻击
    if e.move ~= false and dist > 0.05 then
        local step = e.moveSpd * dt / dist
        tryStep(e, e.x + dx * step, e.y + dy * step, px, py)
    end
    enforceSep(e, px, py)
    return false, nil
end

local function tickAi(e, dt, px, py, world, fxPulse)
    if e.style == "suicide" then
        return tickSuicide(e, dt, px, py, world, fxPulse)
    end
    if e.atkFx and e.atkFx > 0 then
        enforceSep(e, px, py)
        return false, nil
    end
    local dx, dy = px - e.x, py - e.y
    local dist2 = dx * dx + dy * dy
    local vision = e.vision or 0
    if dist2 > (vision + 0.75) * (vision + 0.75) then
        tickIdle(e, dt, px, py)
        enforceSep(e, px, py)
        return false, nil
    end
    local dist = math.sqrt(dist2)
    if not refreshLos(e, px, py, vision, dt) then
        e.cd = 0.35
        tickIdle(e, dt, px, py)
        enforceSep(e, px, py)
        return false, nil
    end
    if e.flee then
        if e.move ~= false and dist > 0.15 then
            local step = e.moveSpd * dt / dist
            tryStep(e, e.x - dx * step, e.y - dy * step, px, py)
        end
        enforceSep(e, px, py)
        return false, nil
    end
    if e.neutral then
        tickIdle(e, dt, px, py)
        enforceSep(e, px, py)
        return false, nil
    end

    local ranged = e.style == "ranged"
    local engage = e.atkRange or MIN_SEP
    if not ranged then
        engage = math.max(engage, MIN_SEP)
    end

    if dist > engage then
        -- 移动接近：途中绝不攻击
        e.cd = math.min(e.cd or 0, 0.25)
        if e.move ~= false then
            local step = e.moveSpd * dt / dist
            tryStep(e, e.x + dx * step, e.y + dy * step, px, py)
        end
        enforceSep(e, px, py)
        return false, nil
    end

    -- 停步交战
    enforceSep(e, px, py)
    e.cd = (e.cd or 0) - dt
    if e.cd <= 0 then
        e.cd = e.atkCd
        if ranged then
            fireBullet(world, e, px, py)
            return false, nil
        end
        return resolveMeleeHit(world, e, fxPulse)
    end
    return false, nil
end

-- 返回 dead, killer
function Enemies.update(world, dt, fxPulse)
    local dead, killer = tickBullets(world, dt, fxPulse)
    local px, py = world.px, world.py
    local list, spawned, w = world.enemies, world._spawned, 0
    local keep2 = KEEP * KEEP
    for i = 1, #list do
        local e = list[i]
        local keep = false
        if e.atkFx and e.atkFx > 0 then e.atkFx = e.atkFx - dt end

        local edx, edy = e.x - px, e.y - py
        local far = edx * edx + edy * edy > keep2
-- 过远且非战斗特效中：剔除并允许再刷（测试区不剔除）
        if far and not world.testMode and e.hp > 0 and not (e.atkFx and e.atkFx > 0) and not (e.hurtT and e.hurtT > 0) then
            if e.sx and e.sy and spawned then
                spawned[spawnKey(e.sx, e.sy)] = nil
            end
        elseif e.hp <= 0 then
            if e.hurtT and e.hurtT > 0 then
                e.hurtT = e.hurtT - dt
                e.hurt = e.hurtT > 0
                keep = e.hurt
            end
        else
            keep = true
            if e.hurtT and e.hurtT > 0 then
                e.hurtT = e.hurtT - dt
                e.hurt = e.hurtT > 0
            else
                e.hurt = false
            end
            if not dead then
                local d, k = tickAi(e, dt, px, py, world, fxPulse)
                if d then dead, killer = true, k end
            end
        end
        if keep then
            w = w + 1
            list[w] = e
        end
    end
    for i = w + 1, #list do list[i] = nil end
    return dead, killer
end

return Enemies
