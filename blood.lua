-- 像素血花：命中怪物时喷溅的红色方块粒子（屏幕空间）

local Ray = require("raycasting")

local Blood = {}

local pool, active = {}, {}
local MAX = 420
local projScratch = {}

local function acquire()
    local p = pool[#pool]
    if p then
        pool[#pool] = nil
        return p
    end
    return {}
end

local function release(p)
    pool[#pool + 1] = p
end

local function push(x, y, vx, vy, life, size, r, g, b, a)
    if #active >= MAX then return end
    local p = acquire()
    p.x, p.y = x, y
    p.vx, p.vy = vx, vy
    p.life, p.max = life, life
    p.size = size
    p.r, p.g, p.b, p.a = r, g, b, a
    active[#active + 1] = p
end

function Blood.clear()
    for i = 1, #active do
        release(active[i])
        active[i] = nil
    end
end

-- cx,cy 喷溅中心；count 粒子数；power 力度
function Blood.burstAt(cx, cy, count, power)
    if not cx or not cy then return end
    count = count or 28
    power = power or 1
    local rnd = love.math.random
    for _ = 1, count do
        local ang = rnd() * math.pi * 2
        local spd = (55 + rnd() * 200) * power
        local life = 0.22 + rnd() * 0.45
        local size = math.max(2, math.floor(3 + rnd() * 6 * power + 0.5))
        local shade = rnd()
        local r, g, b
        if shade < 0.3 then
            r, g, b = 0.35 + rnd() * 0.15, 0.01, 0.02
        elseif shade < 0.65 then
            r, g, b = 0.7 + rnd() * 0.2, 0.03 + rnd() * 0.06, 0.04
        else
            r, g, b = 0.98, 0.08 + rnd() * 0.12, 0.08
        end
        push(
            cx + (rnd() - 0.5) * 14,
            cy + (rnd() - 0.5) * 16,
            math.cos(ang) * spd,
            math.sin(ang) * spd - 50 * power,
            life, size, r, g, b, 0.9 + rnd() * 0.1
        )
    end
end

-- 从敌人世界坐标投影到屏幕后喷溅；kill 时更猛
function Blood.burstFromEnemy(world, e, opts)
    if not world or not e then return end
    opts = opts or {}
    Ray.beginFrame(love.graphics.getDimensions())
    local box = Ray.project(
        world.px, world.py, world.pa,
        e.x, e.y, e.aspect or 0.5, 1, projScratch
    )
    if not box then
        local W, H = love.graphics.getDimensions()
        Blood.burstAt(W * 0.5, H * 0.45, opts.kill and 48 or 22, opts.kill and 1.7 or 1.15)
        return
    end
    local cx = box.sx
    local cy = box.top + box.bh * 0.38
    local n = opts.kill and (55 + love.math.random(20)) or (28 + love.math.random(16))
    local pow = opts.kill and 1.85 or 1.25
    Blood.burstAt(cx, cy, n, pow)
    -- 向下淌血 + 横向甩溅
    local drip = opts.kill and 22 or 12
    for _ = 1, drip do
        local life = 0.4 + love.math.random() * 0.55
        push(
            cx + (love.math.random() - 0.5) * box.bw * 0.5,
            cy + box.bh * 0.1,
            (love.math.random() - 0.5) * 50,
            80 + love.math.random() * 140,
            life,
            math.max(2, math.floor(3 + love.math.random() * 5)),
            0.5 + love.math.random() * 0.3, 0.02, 0.04,
            0.95
        )
    end
    for _ = 1, opts.kill and 14 or 8 do
        local side = love.math.random() < 0.5 and -1 or 1
        push(
            cx, cy,
            side * (90 + love.math.random() * 160),
            -40 + love.math.random() * 80,
            0.25 + love.math.random() * 0.3,
            math.max(2, math.floor(2 + love.math.random() * 4)),
            0.85, 0.05, 0.06, 0.9
        )
    end
end

function Blood.update(dt)
    local w = 0
    local grav = 520
    for i = 1, #active do
        local p = active[i]
        p.life = p.life - dt
        if p.life > 0 then
            p.vy = p.vy + grav * dt
            p.vx = p.vx * (1 - 1.8 * dt)
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            w = w + 1
            active[w] = p
        else
            release(p)
        end
    end
    for i = w + 1, #active do active[i] = nil end
end

function Blood.draw()
    if #active == 0 then return end
    love.graphics.setBlendMode("alpha")
    for i = 1, #active do
        local p = active[i]
        local t = p.life / p.max
        local a = p.a * math.min(1, t * 1.8)
        love.graphics.setColor(p.r, p.g, p.b, a)
        local s = p.size
        love.graphics.rectangle("fill", math.floor(p.x), math.floor(p.y), s, s)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

return Blood
