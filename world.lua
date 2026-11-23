-- 世界会话：场景加载 / 人偶 / 绘制 / 存档；战斗 AI 见 enemies.lua

local Data = require("data")
local Gen = require("genmap")
local Ray = require("raycasting")
local Fonts = require("fonts")
local Assets = require("assets")
local Enemies = require("enemies")
local Cursor = require("cursor")
local Blood = require("blood")

local Scenes, Pcs, Ents = Data.scenes, Data.pcs, Data.entities
local TALK2, ATK_DEFAULT = 1.8 * 1.8, 1.35 -- 默认攻击距离（世界单位）
local ORTHO = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local SAVE_FILE = "embers_save.txt"
local BASE_ATK = 1
local BOOST_HP = 2
local BOOST_ATK = 0.15 -- 铸魂攻略弱，深层压力更大
local BOOST_SPD = 0.07
local WIN_DEPTH = 10   -- 通关里程碑层

local function boostCost(level)
    return 3 * (2 ^ (level or 0)) -- 0→3, 1→6, 2→12…
end

local World = {
    key = "main", scene = nil,
    px = 1.5, py = 1.5, pa = 0,
    npcs = {}, enemies = {}, bullets = {},
    infinite = false,
    hp = 5, maxHp = 5,
    moveSpd = 2.5, atk = 1, atkRange = ATK_DEFAULT, atkDur = 0.14, blockDur = 0.32,
    ash = 0,       -- 火烬（击杀掉落；战死扣罚；进存档）
    ether = 0,     -- 以太（仅 Boss；死亡不掉；铸魂强化）
    boost = { hp = 0, atk = 0, spd = 0 }, -- 铸魂强化等级（花以太）
    inv = {}, -- 背包 key -> 数量
    bossMode = false,
    bossCleared = false,
    bossReturn = nil,
    floorBossClears = { false, false, false },
    mainBossReady = false,
    depth = 0,       -- 当前层（驿站/馆=0；野外从 1 起）
    maxDepth = 0,    -- 历史最深层（未探索为 0）
    explored = {},   -- sceneKey -> 该图到达过的最深层
    kills = 0,
    bestScore = 0,
    actionText = "", actionT = 0,
    blocking = false, atkCd = 0,
    blockStamina = 1.0,
    blockStaminaMax = 1.0,
    blockCd = 0,
    poseAtkT = 0, -- 攻击立绘残留时间
    clearedDepth10 = false, -- 通关里程碑
    puppet = nil,
    overlay = nil,
    fx = { hurt = 0, shake = 0, blur = 0, blood = 0 },
    death = nil, -- 突脸杀演出
    showAim = false, -- 判定区调试（\aim 开关；默认关以省性能）
    _spawned = {},
}

-- 须在 local World 赋值之后定义，否则会误解析成全局 World
local function reach()
    return World.atkRange or ATK_DEFAULT
end

local bbPool, bbView, bbN = {}, {}, 0
local sceneCanvas

local hand = {
    on = false, cfg = nil,
    normal = nil, good = nil, img = nil,
    y = 0, phase = "idle", nextImg = nil, holdT = 0,
    yN = 0, yT = 0,
}

local function flash(t) World.actionText, World.actionT = t, 0.7 end
function World.notify(t) flash(t) end

local function fxPulse(key, t)
    local fx = World.fx
    if (fx[key] or 0) < t then fx[key] = t end
end

local function resetHand()
    hand.y, hand.phase, hand.nextImg, hand.holdT = 0, "idle", nil, 0
    hand.yN, hand.yT = 0, 0
    hand.img = hand.normal
end

local function setupHand(pcKey)
    local cfg = pcKey and Pcs[pcKey] and Pcs[pcKey].hand
    hand.on, hand.cfg = cfg ~= nil, cfg
    if not cfg then return end
    hand.normal = Assets.image(cfg.normal)
    hand.good = Assets.image(cfg.good)
    resetHand()
end

local function bindLook(def, sceneKey)
    return Assets.bindLook(def, sceneKey)
end

local function scanFixed(grid, sceneKey)
    local list = {}
    for r = 1, #grid do
        for c = 1, #grid[1] do
            local def = Ents.byId[grid[r][c]]
            if def and def.role ~= "wall" then
                local img, iw, ih, aspect = bindLook(def, sceneKey)
                local pc = Pcs[def.key]
                list[#list + 1] = {
                    id = def.id, key = def.key, name = def.name, role = def.role,
                    select = pc and pc.select,
                    x = c - 0.5, y = r - 0.5,
                    img = img, iw = iw, ih = ih, aspect = aspect,
                }
            end
        end
    end
    return list
end

local function beside(npcs)
    if #npcs == 0 then return 1.5, 1.5, 0 end
    local n = npcs[1]
    for i = 1, #ORTHO do
        local x, y = n.x + ORTHO[i][1], n.y + ORTHO[i][2]
        if not Ray.isWall(x, y) then
            return x, y, math.atan2(n.y - y, n.x - x)
        end
    end
    -- 正交全墙时螺旋外扩，避免卡进墙里
    for r = 2, 6 do
        for dy = -r, r do
            for dx = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local x, y = n.x + dx, n.y + dy
                    if not Ray.isWall(x, y) then
                        return x, y, math.atan2(n.y - y, n.x - x)
                    end
                end
            end
        end
    end
    return 1.5, 1.5, 0
end

local function bbPush(x, y, label, role, img, iw, ih, aspect, grow, atkFx, hurt, hp, quad, size)
    bbN = bbN + 1
    local e = bbPool[bbN]
    if not e then e = {}; bbPool[bbN] = e end
    e.x, e.y, e.label, e.role = x, y, label, role
    e.img, e.iw, e.ih, e.aspect = img, iw, ih, aspect or 1
    e.grow, e.atkFx, e.hurt, e.hp = grow or 0, atkFx, hurt, hp
    e.quad, e.size = quad, size
    bbView[bbN] = e
end

local function wipeRuntime(opts)
    opts = opts or {}
    if not opts.keepMap then
        Gen.clear()
    end
    World.infinite, World.enemies, World.bullets = false, {}, {}
    World.testMode = false
    World.bossMode, World.bossCleared = false, false
    World.blocking, World.atkCd = false, 0
    World.blockStamina = World.blockStaminaMax or 1.0
    World.blockCd = 0
    World._wantBlock = false
    World.poseAtkT = 0
    World._ctrlHeld = false
    World.fx.hurt, World.fx.shake, World.fx.blur, World.fx.blood = 0, 0, 0, 0
    World._spawned, bbN = {}, 0
    World._syncT = 0
    World._shakeX, World._shakeY = 0, 0
    World._prevCtrl, World._prevSlash = false, false
    World._inputMute = 2
    Blood.clear()
end

local function refreshNpcs()
    local src = Gen.npcList()
    local list = {}
    for i = 1, #src do
        local s = src[i]
        local def = Ents.byId[s.id] or Ents.byId[Ents.INF_NPC_ID]
        local img, iw, ih, aspect = bindLook(def, World.key)
        list[i] = {
            id = def.id, key = def.key,
            name = s.name or def.name,
            role = s.role or def.role,
            slot = s.slot,
            x = s.x, y = s.y,
            img = img, iw = iw, ih = ih, aspect = aspect,
        }
    end
    World.npcs = list
end

function World.applyStats(pcKey, opts)
    opts = opts or {}
    local pc = pcKey and Pcs[pcKey]
    local s = (pc and pc.stats) or Data.PC_DEFAULT
    local b = World.boost or { hp = 0, atk = 0, spd = 0 }
    World.maxHp = s.hp + (b.hp or 0) * BOOST_HP
    World.moveSpd = s.moveSpd + (b.spd or 0) * BOOST_SPD
    World.atk = (s.atk or BASE_ATK) + (b.atk or 0) * BOOST_ATK
    World.atkRange = s.atkRange or ATK_DEFAULT
    World.atkDur = s.atkDur
    World.blockDur = s.blockDur or 0.32
    -- 格挡耐力 ≈ 可连续格挡时长
    World.blockStaminaMax = 0.55 + (World.blockDur or 0.32) * 1.1
    if (World.blockStamina or 0) > World.blockStaminaMax then
        World.blockStamina = World.blockStaminaMax
    end
    if opts.refill ~= false then World.hp = World.maxHp end
    if World.hp > World.maxHp then World.hp = World.maxHp end
end

function World.boostInfo()
    local b = World.boost or { hp = 0, atk = 0, spd = 0 }
    return {
        ether = World.ether or 0,
        hpLv = b.hp or 0,
        atkLv = b.atk or 0,
        spdLv = b.spd or 0,
        hpCost = boostCost(b.hp),
        atkCost = boostCost(b.atk),
        spdCost = boostCost(b.spd),
        maxHp = World.maxHp,
        atk = World.atk or BASE_ATK,
        moveSpd = World.moveSpd or 2.5,
    }
end

-- kind: "hp" | "atk" | "spd"；消耗以太（Boss 掉落，死亡不丢）
function World.tryBoost(kind)
    local b = World.boost
    if not b then
        b = { hp = 0, atk = 0, spd = 0 }
        World.boost = b
    end
    if kind ~= "hp" and kind ~= "atk" and kind ~= "spd" then return false end
    local lv = b[kind] or 0
    local cost = boostCost(lv)
    if (World.ether or 0) < cost then
        flash("以太不足（需" .. cost .. "，击败 Boss 获取）")
        return false
    end
    World.ether = World.ether - cost
    b[kind] = lv + 1
    local oldMax = World.maxHp
    World.applyStats(
        World.puppet and World.puppet.key or "player",
        { refill = false }
    )
    if kind == "hp" then
        World.hp = (World.hp or 0) + (World.maxHp - oldMax)
    end
    World.writeSave({ quiet = true })
    local names = { hp = "生命上限", atk = "攻击", spd = "速度" }
    local delta = kind == "hp" and tostring(BOOST_HP)
        or kind == "atk" and string.format("%.2f", BOOST_ATK)
        or string.format("%.2f", BOOST_SPD)
    flash(names[kind] .. " +" .. delta .. "（花费" .. cost .. "以太）")
    return true
end

function World.clearSession()
    wipeRuntime()
    World.actionText, World.actionT = "", 0
    World.puppet, World.scene, World.overlay = nil, nil, nil
    World.key = nil
    World.death = nil
    World.ash, World.ether = 0, 0
    World.boost = { hp = 0, atk = 0, spd = 0 }
    World.inv = {}
    World.bossMode, World.bossCleared, World.bossReturn = false, false, nil
    World.floorBossClears = { false, false, false }
    World.mainBossReady = false
    World.depth, World.maxDepth = 0, 0
    World.explored, World.kills, World.bestScore = {}, 0, 0
    World.clearedDepth10 = false
    World.atk = BASE_ATK
    hand.on = false
    resetHand()
end

local DEATH_FILE = "embers_deaths.txt"

-- 用于死亡惩罚等：Boss 房取进入前所在层
function World.expeditionDepth()
    local ret = World.bossReturn
    if ret and ret.depth and ret.depth > 0 then return ret.depth end
    local d = World.depth or 0
    if d > 0 then return d end
    return World.maxDepth or 0
end

-- 战死扣火烬更狠；并摔碎部分伤药/牛肉
function World.deathAshPenalty()
    local ash = World.ash or 0
    local depth = World.expeditionDepth()
    if depth < 1 then depth = 1 end
    local pen = 5 + depth * 3 + math.floor(ash * 0.25)
    if pen > ash then pen = ash end
    return pen
end

local function deathItemLoss()
    local lost = {}
    for _, key in ipairs({ "potion", "potion_mid", "potion_high", "beef" }) do
        local n = World.invCount(key)
        if n > 0 then
            local drop = math.max(1, math.floor(n * 0.5 + 0.5))
            World.takeItem(key, drop)
            lost[#lost + 1] = key
        end
    end
    return lost
end

function World.level()
    local md = World.maxDepth or 0
    return 1
        + math.floor((World.kills or 0) / 12)
        + math.floor(math.max(0, md) / 2)
end

function World.calcScore()
    return (World.kills or 0) * 10
        + (World.maxDepth or 0) * 50
        + (World.ether or 0) * 25
        + (World.ash or 0) * 2
end

function World.markExplored(sceneKey, depth)
    if not sceneKey or not depth or depth < 1 then return end
    local prev = World.explored[sceneKey] or 0
    if depth > prev then World.explored[sceneKey] = depth end
    if depth > (World.maxDepth or 0) then World.maxDepth = depth end
end

-- 车资：驿站基础价；野外逃离按当前层收费
function World.travelFare(depth)
    depth = math.max(1, depth or 1)
    if depth <= 1 then return 0 end
    return (depth - 1) * 3
end

function World.fleeFare()
    local d = World.depth or 0
    if d < 1 then return 5 end
    return 5 + d * 2
end

function World.estimateFare(dest)
    if type(dest) == "string" then dest = { key = dest } end
    if not dest or not dest.key then return 0 end
    if dest.fare ~= nil then return dest.fare end
    local s = Scenes[dest.key]
    if not s or s.fixed or s.test or s.boss then return World.fleeFare() end
    return World.travelFare(dest.depth or 1)
end

function World.canPayAsh(n)
    n = math.max(0, math.floor(n or 0))
    return (World.ash or 0) >= n
end

local function payAsh(n)
    n = math.max(0, math.floor(n or 0))
    if n <= 0 then return true end
    local ash = World.ash or 0
    if ash < n then return false end
    World.ash = ash - n
    return true
end

local function encodeExplored()
    local parts = {}
    for scene, d in pairs(World.explored or {}) do
        if type(d) == "number" and d > 0 then
            parts[#parts + 1] = scene .. ":" .. tostring(d)
        elseif type(d) == "table" then
            -- 旧存档：{ [depth]=true } → 取最大层
            local maxd = 0
            for depth, ok in pairs(d) do
                if ok and depth > maxd then maxd = depth end
            end
            if maxd > 0 then parts[#parts + 1] = scene .. ":" .. tostring(maxd) end
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function decodeExplored(raw)
    World.explored = {}
    if not raw or raw == "" then return end
    for token in raw:gmatch("[^,]+") do
        local scene, d = token:match("^([%w_]+):(%d+)$")
        d = tonumber(d)
        if scene and d then World.markExplored(scene, d) end
    end
end

function World.charSheetLines()
    local s = World.scene
    local place = s and s.title or (World.key or "?")
    local depth = World.depth or 0
    local depthText = depth > 0 and (place .. " 第" .. depth .. "层") or place
    local score = World.calcScore()
    if score > (World.bestScore or 0) then World.bestScore = score end
    return {
        "── 角色面板 ──",
        "人偶：" .. (World.puppet and World.puppet.name or "（未附身）"),
        "位置：" .. depthText,
        "阅历：" .. tostring(World.level())
            .. "  （击杀" .. tostring(World.kills or 0)
            .. " / 最深" .. tostring(World.maxDepth or 0) .. "）",
        "HP ：" .. tostring(World.hp or 0) .. "/" .. tostring(World.maxHp or 0),
        "攻击：" .. string.format("%.2f", World.atk or BASE_ATK)
            .. "  距离：" .. string.format("%.2f", World.atkRange or ATK_DEFAULT)
            .. "  速度：" .. string.format("%.2f", World.moveSpd or 2.5),
        "火烬：" .. tostring(World.ash or 0)
            .. "  （战死约扣" .. tostring(World.deathAshPenalty()) .. "）",
        "以太：" .. tostring(World.ether or 0),
        "目标：" .. (World.goalHint() or "—"),
        "得分：" .. tostring(score) .. "  最佳：" .. tostring(World.bestScore or 0),
        "背包：" .. World.invText(),
        "",
        "按 Q 关闭",
    }
end

function World.appendDeathRecord(killer)
    local score = World._deathScore or World.calcScore()
    if score > (World.bestScore or 0) then World.bestScore = score end
    local line = string.format(
        "得分%d | 最深%d | 击杀%d | 扣火烬%d | 余%d | 于%s第%d层 | 凶手:%s",
        score,
        World.maxDepth or 0,
        World.kills or 0,
        World._deathAshLost or 0,
        World.ash or 0,
        (World.scene and World.scene.title) or (World.key or "?"),
        World._deathDepth or World.expeditionDepth(),
        (killer and killer.name) or "不明"
    )
    local prev = love.filesystem.read(DEATH_FILE) or ""
    local rows = {}
    for row in prev:gmatch("[^\r\n]+") do
        rows[#rows + 1] = row
    end
    table.insert(rows, 1, line)
    while #rows > 8 do rows[#rows] = nil end
    love.filesystem.write(DEATH_FILE, table.concat(rows, "\n") .. "\n")
    World._lastDeathLine = line
    World.writeSave({ quiet = true })
    return line
end

function World.recentDeaths()
    local raw = love.filesystem.read(DEATH_FILE)
    if not raw then return {} end
    local t = {}
    for row in raw:gmatch("[^\r\n]+") do
        t[#t + 1] = row
    end
    return t
end

------------------------------------------------------------
-- 背包（纯文本：伤药[3] 牛肉[8]）
------------------------------------------------------------
function World.invCount(key)
    return (World.inv and World.inv[key]) or 0
end

function World.invText()
    local parts = {}
    local items = Data.items or {}
    for i = 1, #items do
        local it = items[i]
        local n = World.invCount(it.key)
        if n > 0 then parts[#parts + 1] = it.name .. "[" .. n .. "]" end
    end
    if #parts == 0 then return "（空）" end
    return table.concat(parts, " ")
end

function World.addItem(key, n)
    n = n or 1
    if n <= 0 or not Data.itemsByKey[key] then return false end
    World.inv = World.inv or {}
    World.inv[key] = (World.inv[key] or 0) + n
    return true
end

function World.takeItem(key, n)
    n = n or 1
    local have = World.invCount(key)
    if have < n then return false end
    World.inv[key] = have - n
    if World.inv[key] <= 0 then World.inv[key] = nil end
    return true
end

function World.shopPayload(npc)
    local def = Ents.byId[npc.id] or Ents.byKey[npc.key]
    local shop = def and def.shop or {
        pay = "ash", goods = { "potion", "potion_mid", "potion_high", "beef", "key" },
    }
    local lines = {}
    local goods = shop.goods or {}
    for i = 1, #goods do
        local it = Data.itemsByKey[goods[i]]
        if it then
            lines[#lines + 1] = {
                key = it.key, name = it.name, price = it.price,
                owned = World.invCount(it.key),
            }
        end
    end
    return {
        pay = "ash",
        wallet = World.ash or 0,
        bag = World.invText(),
        lines = lines,
    }
end

function World.buyItem(key)
    local it = Data.itemsByKey[key]
    if not it then
        flash("未知商品")
        return false
    end
    local price = it.price or 0
    if (World.ash or 0) < price then
        flash("火烬不足（需" .. price .. "）")
        return false
    end
    World.ash = World.ash - price
    World.addItem(key, 1)
    World.writeSave({ quiet = true })
    flash("购得" .. it.name)
    return true
end

function World.useItem(key)
    local it = Data.itemsByKey[key]
    if not it then
        flash("没有这种物品")
        return false
    end
    if World.invCount(key) <= 0 then
        flash(it.name .. "不足")
        return false
    end
    if it.heal and it.heal > 0 then
        if (World.hp or 0) >= (World.maxHp or 0) then
            flash("生命已满")
            return false
        end
        World.takeItem(key, 1)
        local before = World.hp
        World.hp = math.min(World.maxHp, World.hp + it.heal)
        flash(it.name .. " +" .. (World.hp - before) .. "HP")
        return true
    end
    flash(it.name .. "暂时无法使用")
    return false
end

function World.usableItems()
    local list = {}
    local items = Data.items or {}
    for i = 1, #items do
        local it = items[i]
        local n = World.invCount(it.key)
        if n > 0 and it.heal then
            list[#list + 1] = it
        end
    end
    return list
end

function World.load(key, opts)
    local s = Scenes[key]
    if not s then
        flash("未知地点")
        return
    end
    opts = opts or {}
    if key == World.key and World.scene and not opts.force then
        return
    end
    local keep = opts.keepPuppet and World.puppet or nil
    local refill = opts.refill
    if refill == nil then refill = true end
    local keepReturn = World.bossReturn
    local keepClears = World.floorBossClears
    local keepMainReady = World.mainBossReady
    local keepMap = opts.keepMap == true and Gen.cells ~= nil

    wipeRuntime({ keepMap = keepMap })
    World.bossReturn = keepReturn
    if keepMap then
        World.floorBossClears = keepClears or { false, false, false }
        World.mainBossReady = keepMainReady
    end
    World.key, World.scene = key, s
    World.testMode = s.test == true
    World.puppet = opts.puppet or keep
    World.overlay = s.overlay and Assets.image(s.overlay) or nil
    setupHand(s.hub and (s.pc or "player") or nil)
    World.applyStats(
        World.puppet and World.puppet.key or (s.hub and (s.pc or "player") or "player"),
        { refill = refill }
    )

    if s.test and s.map then
        Ray.setScene(s.map, s.wall, s.bg)
        World.infinite = true
        World.depth = 0
        World.npcs = {}
        World.px, World.py, World.pa = s.spawn[1], s.spawn[2], s.spawn[3] or 0
        World.enemies = Enemies.spawnTestRoster()
        World.bullets = {}
    elseif s.boss and s.map then
        Ray.setScene(s.map, s.wall, s.bg)
        World.infinite = true
        World.bossMode = true
        World.bossCleared = false
        local floorDepth = (World.bossReturn and World.bossReturn.depth) or 1
        World.depth = floorDepth
        World.npcs = scanFixed(s.map, key)
        World.px, World.py, World.pa = s.spawn[1], s.spawn[2], s.spawn[3] or 0
        local slot = World.bossReturn and World.bossReturn.slot
        local bossKey = (slot == "main") and "boss_main" or "boss_1"
        local bossDef = Ents.byKey[bossKey] or Ents.byKey.boss_1
        local bossName = (World.bossReturn and World.bossReturn.siteName) or (bossDef and bossDef.name)
        World.enemies = {
            Enemies.spawn({
                x = 5.5, y = 5.5, sx = 5.5, sy = 5.5,
                id = bossDef and bossDef.id or 90,
            }, key, floorDepth + ((slot == "main") and 2 or 0)),
        }
        if World.enemies[1] and bossName then
            World.enemies[1].name = bossName
        end
        World.bullets = {}
        World._spawned = {}
    elseif s.fixed and s.map then
        Ray.setScene(s.map, s.wall, s.bg)
        World.depth = 0
        World.npcs = scanFixed(s.map, key)
        if s.spawn then
            World.px, World.py, World.pa = s.spawn[1], s.spawn[2], s.spawn[3] or 0
        else
            World.px, World.py, World.pa = beside(World.npcs)
        end
    else
        local depth = opts.depth or 1
        if depth < 1 then depth = 1 end
        World.infinite = true
        World.bossMode, World.bossCleared = false, false
        World.depth = depth
        World.markExplored(key, depth)
        Ray.setTextures(s.wall, s.bg)
        Ray.setCellFn(Gen.getCellXY)
        if keepMap then
            refreshNpcs()
            World._spawned = {}
            World.enemies = {}
            World.bullets = {}
            Enemies.sync(World, World._spawned)
            local ret = World.bossReturn
            if ret and ret.px then
                World.px, World.py, World.pa = ret.px, ret.py, ret.pa or 0
            else
                World.px, World.py = Gen.spawnX, Gen.spawnY
                World.pa = 0
            end
        else
            World.floorBossClears = { false, false, false }
            World.mainBossReady = false
            World.px, World.py, World.pa = Gen.begin(key, depth)
            refreshNpcs()
            World._spawned = {}
            World.enemies = {}
            World.bullets = {}
            Enemies.sync(World, World._spawned)
        end
    end
end

-- 马车：驿站车资 2；野外总是进入第 1 层（新随机图）
function World.tryTravel(dest)
    if type(dest) == "string" then
        dest = { key = dest }
    end
    if not dest or not dest.key then return false end
    local s = Scenes[dest.key]
    if not s then
        flash("未知地点")
        return false
    end
    local depth = dest.depth
    if not s.fixed and not s.test and not s.boss then
        depth = depth or 1
        if depth < 1 then depth = 1 end
    else
        depth = 0
    end
    local fare = dest.fare
    if fare == nil then
        fare = depth > 0 and World.travelFare(depth) or 2
    end
    if fare > 0 and not payAsh(fare) then
        flash("火烬不足（车资" .. fare .. "）")
        return false
    end
    World.load(dest.key, {
        keepPuppet = true, refill = false, force = true, depth = depth > 0 and depth or nil,
    })
    if fare > 0 then
        flash("车资 " .. fare .. " 火烬")
    elseif depth > 0 then
        flash("抵达第 " .. depth .. " 层")
    end
    return true
end

-- 兼容旧对话；层数改由 Boss → 归途推进
function World.descendAbyss()
    flash("裂隙已封闭。击败领主后经归途前往下一层。")
    return false
end

-- 击败主座后：进入同图更深一层
function World.advanceFloor()
    local key = World.key
    local ret = World.bossReturn
    if ret and ret.key then key = ret.key end
    local cleared = ret and ret.depth or World.depth or 1
    local nextDepth = cleared + 1
    World.bossReturn, World.bossMode, World.bossCleared = nil, false, false
    World.floorBossClears = { false, false, false }
    World.mainBossReady = false
    World.load(key, {
        keepPuppet = true, refill = false, force = true, depth = nextDepth,
    })
    local heal = math.max(1, math.ceil((World.maxHp or 5) * 0.2))
    World.hp = math.min(World.maxHp or heal, (World.hp or 0) + heal)
    if cleared >= WIN_DEPTH and not World.clearedDepth10 then
        World.clearedDepth10 = true
        flash("第" .. WIN_DEPTH .. "层已征服 · 可继续深入（恢复" .. heal .. "）")
    else
        flash("第 " .. nextDepth .. " 层 · 恢复" .. heal)
    end
    return true
end

local function spawnSearchMobs()
    local n = love.math.random(1, 1 + math.min(2, math.floor((World.depth or 1) / 4)))
    local spawned = 0
    for _ = 1, n do
        local ang = love.math.random() * math.pi * 2
        local dist = 1.6 + love.math.random() * 1.2
        local x = World.px + math.cos(ang) * dist
        local y = World.py + math.sin(ang) * dist
        if not Ray.isWall(x, y) then
            local pick = love.math.random()
            local id = 50
            if pick < 0.45 then id = 50
            elseif pick < 0.75 then id = 53
            elseif pick < 0.90 then id = 51
            elseif pick < 0.97 then id = 52
            else id = 54 end
            World.enemies[#World.enemies + 1] = Enemies.spawn(
                { id = id, x = x, y = y, sx = x, sy = y },
                World.key,
                World.depth or 1
            )
            spawned = spawned + 1
        end
    end
    return spawned
end

local function giveSearchLoot(kind)
    local depthBonus = math.max(0, (World.depth or 1) - 1)
    -- { ashChance, ashLo, ashHiExtra, potion, beef, key, ashPrefix }
    local tables = {
        chest = { 0.38, 2, 4, 0.62, 0.78, 0.90, 0.96, 0.99, "箱中" },
        mech  = { 0.55, 1, 2, 0.72, 0.88, 0.96, 1.00, 1.00, "机关" },
        search = { 0.48, 1, 3, 0.68, 0.82, 0.92, 0.97, 0.99, "搜得" },
    }
    local t = tables[kind] or tables.search
    local roll = love.math.random()
    local prefix = t[9]
    if roll < t[1] then
        local hi = t[3] + (kind == "mech" and math.min(2, depthBonus) or depthBonus)
        local n = love.math.random(t[2], hi)
        World.ash = (World.ash or 0) + n
        if kind == "mech" then flash("机关吐出火烬 " .. n)
        elseif kind == "chest" then flash("箱中火烬 " .. n)
        else flash("搜得火烬 " .. n) end
    elseif roll < t[4] then
        World.addItem("potion", 1)
        flash(kind == "mech" and "机关夹缝里掉出伤药" or (prefix .. "伤药"))
    elseif roll < t[5] then
        World.addItem("potion_mid", 1)
        flash(prefix .. "中级伤药")
    elseif roll < t[6] then
        World.addItem("beef", 1)
        flash(kind == "mech" and "机关里卡着一块牛肉" or (prefix .. "牛肉"))
    elseif roll < t[7] then
        World.addItem("potion_high", 1)
        flash(prefix .. "高级伤药")
    elseif t[8] and roll < t[8] and kind ~= "mech" then
        World.addItem("key", 1)
        flash(prefix .. "钥匙！")
    else
        World.addItem("beef", 1)
        flash(kind == "mech" and "机关里卡着一块牛肉" or (prefix .. "牛肉"))
    end
end

function World.trySearch(npc)
    local role = npc and npc.role
    if role ~= "search" and role ~= "chest" and role ~= "mech" then
        flash("附近没有可搜索之处")
        return false
    end
    if World.infinite and not World.bossMode and not World.testMode then
        Gen.setCell(npc.x, npc.y, 0)
        refreshNpcs()
    end
    local rewardChance = 0.5
    if role == "chest" then rewardChance = 0.72
    elseif role == "mech" then rewardChance = 0.45 end
    if love.math.random() < rewardChance then
        giveSearchLoot(role)
    elseif role == "mech" and love.math.random() < 0.35 then
        flash("机关空转一声，什么也没有……")
    else
        local spawned = spawnSearchMobs()
        flash(spawned > 0 and ("惊动了 " .. spawned .. " 只怪物！") or "空无一物……")
    end
    return true
end

function World.allFloorBossesCleared()
    local c = World.floorBossClears or {}
    return c[1] and c[2] and c[3]
end

function World.markFloorBossCleared(slot)
    if type(slot) ~= "number" or slot < 1 or slot > 3 then return end
    World.floorBossClears = World.floorBossClears or { false, false, false }
    World.floorBossClears[slot] = true
    local list = Gen.npcs or {}
    for i = 1, #list do
        local n = list[i]
        if n and n.slot == slot then
            Gen.setCell(n.x, n.y, 0)
            break
        end
    end
end

-- 普通 / 主座装置：进入对应 Boss 战（保留本层地图）
function World.tryOpenBossDevice(npc)
    if not npc then return false end
    local role = npc.role
    if role ~= "boss_device" and role ~= "boss_main" and role ~= "door" then
        return false
    end
    local slot = npc.slot or (role == "boss_main" and "main") or 1
    if slot ~= "main" and World.floorBossClears and World.floorBossClears[slot] then
        flash("此处已平息")
        return false
    end
    if slot == "main" then
        if not World.allFloorBossesCleared() then
            flash("需先平息三处普通领主之地")
            return false
        end
        -- 完 3 个后才有机会真正开启
        if love.math.random() >= 0.62 then
            flash("主座沉寂……稍后再试")
            return false
        end
    end
    local floorDepth = World.depth or 1
    World.bossReturn = {
        key = World.key,
        depth = floorDepth,
        px = World.px, py = World.py, pa = World.pa,
        slot = slot,
        siteName = npc.name,
    }
    World.load("boss", { keepPuppet = true, refill = false, force = true, keepMap = true })
    local label = npc.name or "领主之地"
    flash("踏入 · " .. label)
    return true
end

-- 兼容旧封印门（钥匙）
function World.tryOpenBossDoor(npc)
    if npc and (npc.role == "boss_device" or npc.role == "boss_main") then
        return World.tryOpenBossDevice(npc)
    end
    if not npc or npc.role ~= "door" then return false end
    if World.invCount("key") <= 0 then
        flash("需要钥匙才能开启")
        return false
    end
    World.takeItem("key", 1)
    Gen.setCell(npc.x, npc.y, 0)
    npc.slot = "main"
    npc.name = npc.name or "封印之门"
    return World.tryOpenBossDevice(npc)
end

function World.tryExitBoss()
    if not World.bossMode then return false end
    if not World.bossCleared then
        flash("击败领主后方可离开")
        return false
    end
    local ret = World.bossReturn
    local slot = ret and ret.slot
    if slot == "main" then
        return World.advanceFloor()
    end
    -- 普通 Boss：回本层，标记，有概率刷主座
    if type(slot) == "number" then
        World.markFloorBossCleared(slot)
    end
    local site = ret and ret.siteName or "领主之地"
    World.bossMode, World.bossCleared = false, false
    local backKey = ret and ret.key or World.key
    local backDepth = ret and ret.depth or World.depth or 1
    World.load(backKey, {
        keepPuppet = true, refill = false, force = true,
        depth = backDepth, keepMap = true,
    })
    World.bossReturn = nil
    local msg = site .. " 已平息"
    if World.allFloorBossesCleared() then
        World.mainBossReady = true
        if not Gen.mainBossPlaced and love.math.random() < 0.7 then
            if Gen.tryPlaceMainBossDevice() then
                refreshNpcs()
                msg = msg .. " · 主座装置显形"
            else
                msg = msg .. " · 主座尚未显形"
            end
        elseif Gen.mainBossPlaced then
            msg = msg .. " · 可挑战主座"
        else
            msg = msg .. " · 主座暂未显形（再寻）"
            -- 允许之后再试刷新
            if love.math.random() < 0.35 then
                if Gen.tryPlaceMainBossDevice() then
                    refreshNpcs()
                    msg = "主座装置终于显形"
                end
            end
        end
    else
        local left = 0
        local c = World.floorBossClears or {}
        for i = 1, 3 do if not c[i] then left = left + 1 end end
        msg = msg .. " · 尚余" .. left .. "处"
    end
    flash(msg)
    return true
end

function World.enterTestArea()
    World.load("testarea", { force = true })
    local doll = Ents.byKey.amoris
    if doll then World.beginPuppet(doll) end
    World.hp = World.maxHp
    flash("测试区 · 无限血")
end

function World.isPuppet() return World.puppet ~= nil end

function World.beginPuppet(npc)
    local pc = Pcs[npc.key] or {}
    local idle = Assets.image(pc.select or npc.select)
    if not idle then return end
    local attack = Assets.image(pc.attack) or idle
    local parry = Assets.image(pc.parry) or idle
    World.puppet = {
        key = npc.key, name = npc.name,
        idle = idle, attack = attack, parry = parry,
        img = idle,
        scale = pc.scale or 1, x = pc.x,
    }
    World.poseAtkT = 0
    World.applyStats(npc.key)
end

function World.endPuppet()
    World.puppet = nil
    World.poseAtkT = 0
    World.applyStats("player")
end

function World.tapY()
    if not hand.on or World.puppet or hand.phase ~= "idle" then return end
    if hand.yT <= 0 then hand.yN = 0 end
    hand.yN = hand.yN + 1
    hand.yT = hand.cfg.yyyGap
    if hand.yN >= hand.cfg.yyyNeed then
        hand.yN, hand.nextImg, hand.phase = 0, hand.good, "down"
    end
end

local function tickHand(dt)
    if not hand.on or hand.phase == "idle" then
        if hand.on and hand.yT > 0 then
            hand.yT = hand.yT - dt
            if hand.yT <= 0 then hand.yN = 0 end
        end
        return
    end
    if hand.yT > 0 then
        hand.yT = hand.yT - dt
        if hand.yT <= 0 then hand.yN = 0 end
    end
    local cfg = hand.cfg
    if hand.phase == "down" then
        hand.y = hand.y + dt / cfg.slide
        if hand.y >= 1 then
            hand.y, hand.img, hand.nextImg, hand.phase = 1, hand.nextImg, nil, "up"
        end
    elseif hand.phase == "up" then
        hand.y = hand.y - dt / cfg.slide
        if hand.y <= 0 then
            hand.y = 0
            if hand.img == hand.good then
                hand.phase, hand.holdT = "hold", cfg.hold
            else
                hand.phase = "idle"
            end
        end
    elseif hand.phase == "hold" then
        hand.holdT = hand.holdT - dt
        if hand.holdT <= 0 then
            hand.nextImg, hand.phase = hand.normal, "down"
        end
    end
end

local function drawPuppet(img, scaleMul, xRatio, pose)
    if not img then return end
    pose = pose or {}
    local W, H = love.graphics.getDimensions()
    local scale = (H / img:getHeight()) * (scaleMul or 1)
    local iw, ih = img:getWidth(), img:getHeight()
    local dw, dh = iw * scale, ih * scale
    local x = xRatio == nil and (W - dw) * 0.5 or W * xRatio
    local oy = pose.oy or 0
    local rot = pose.rot or 0
    love.graphics.setColor(1, 1, 1, 1)
    -- 统一以立绘底边中点为轴，待机/攻击/格挡位置一致
    local pivotX = x + dw * 0.5
    local pivotY = dh
    love.graphics.push()
    love.graphics.translate(pivotX, pivotY + oy)
    love.graphics.rotate(rot)
    love.graphics.draw(img, -dw * 0.5, -dh, 0, scale, scale)
    love.graphics.pop()
end

local function drawHand(img, scaleMul, slide)
    if not img then return end
    local W, H = love.graphics.getDimensions()
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = (H / ih) * (scaleMul or 1)
    local dw, dh = iw * scale, ih * scale
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, (W - dw) * 0.5, (H - dh) + H * (slide or 0), 0, scale, scale)
end

local poseScratch = { oy = 0, rot = 0 }
local aimOpts = { maxDist = 0 }

local function puppetDrawState()
    local p = World.puppet
    if not p then return nil, nil end
    local img = p.idle or p.img
    poseScratch.oy, poseScratch.rot = 0, 0
    if World.blocking then
        img = p.parry or p.idle or img
    elseif (World.poseAtkT or 0) > 0 then
        img = p.attack or img
    end
    return img, poseScratch
end

function World.drawCrosshair()
    if not World.canFight() or not Cursor.inCombat() then return end
    aimOpts.maxDist = reach()
    local locked = World.cursorEnemy(aimOpts) ~= nil
    Cursor.drawCrosshair(locked)
end

function World.drawOverlay()
    local p = World.puppet
    if p and (p.idle or p.img) then
        local img, pose = puppetDrawState()
        drawPuppet(img, p.scale, p.x, pose)
    elseif hand.on and hand.img then
        drawHand(hand.img, hand.cfg.scale, hand.y)
    end
end

local function drawHudIcon(img, text, x, y, iconSize)
    local gap = Fonts.px(4)
    if img then
        local iw, ih = img:getWidth(), img:getHeight()
        local s = iconSize / math.max(iw, ih)
        love.graphics.setBlendMode("add")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(img, x, y, 0, s, s)
        love.graphics.setBlendMode("alpha")
        x = x + iconSize + gap
    end
    love.graphics.setColor(0.95, 0.92, 0.88, 1)
    love.graphics.print(text, x, y + (iconSize - Fonts.ui:getHeight()) * 0.5)
    return x + Fonts.ui:getWidth(text)
end

function World.drawHud()
    local W, H = love.graphics.getDimensions()
    love.graphics.setFont(Fonts.ui)
    local pad = Fonts.px(8)
    local iconSize = Fonts.px(22)
    local rowGap = Fonts.px(6)
    local x0, y = pad, pad

    local hpImg = Assets.image("resources/hp.png")
    local ashImg = Assets.image("resources/ash.png")
    local etherImg = Assets.image("resources/ether.png")

    local hpText = World.testMode and "∞" or (tostring(World.hp or 0) .. "/" .. tostring(World.maxHp or 0))
    drawHudIcon(hpImg, hpText, x0, y, iconSize)
    y = y + iconSize + rowGap
    drawHudIcon(ashImg, tostring(World.ash or 0), x0, y, iconSize)
    y = y + iconSize + rowGap
    drawHudIcon(etherImg, tostring(World.ether or 0), x0, y, iconSize)
    y = y + iconSize + rowGap

    if World.infinite and not World.testMode and (World.depth or 0) > 0 then
        love.graphics.setColor(0.75, 0.7, 0.85, 0.9)
        local depthLabel = "第" .. tostring(World.depth) .. "层"
        if World.bossMode then depthLabel = World.bossCleared and "归途" or "领主" end
        love.graphics.print(depthLabel, x0, y)
    end

    if World.actionText ~= "" and World.actionT > 0 then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(World.actionText, 0, H * 0.18, W, "center")
    end
end

function World.goalHint()
    if World.testMode then return nil end
    if World.bossMode then
        local slot = World.bossReturn and World.bossReturn.slot
        if slot == "main" then
            return World.bossCleared and "目标：经归途进入更深一层" or "目标：击败主座"
        end
        return World.bossCleared and "目标：经归途返回本层" or "目标：击败此地领主"
    end
    if World.infinite and (World.depth or 0) > 0 then
        if World.allFloorBossesCleared() then
            return Gen.mainBossPlaced and "目标：挑战主座装置" or "目标：寻觅主座显形"
        end
        local c = World.floorBossClears or {}
        local n = (c[1] and 1 or 0) + (c[2] and 1 or 0) + (c[3] and 1 or 0)
        return "目标：启三处领主装置（" .. n .. "/3）"
    end
    if World.puppet then
        return "目标：乘马车前往野外探索"
    end
    return "目标：触碰人偶附身，再出发"
end

function World.drawSceneOverlay()
    local img = World.overlay
    if not img then return end
    local W, H = love.graphics.getDimensions()
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, 0, 0, 0, W / img:getWidth(), H / img:getHeight())
end

local function ensureCanvas(W, H)
    if sceneCanvas and sceneCanvas:getWidth() == W and sceneCanvas:getHeight() == H then
        return sceneCanvas
    end
    if sceneCanvas then sceneCanvas:release() end
    sceneCanvas = love.graphics.newCanvas(W, H)
    sceneCanvas:setFilter("nearest", "nearest")
    return sceneCanvas
end

local blurOffs = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }

local function drawSceneWorld()
    Ray.draw(World.px, World.py, World.pa, World.billboards())
    if World.showAim then World.drawAimHelpers() end
    World.drawSceneOverlay()
end

function World.draw()
    local W, H = love.graphics.getDimensions()
    Ray.beginFrame(W, H)
    local fx = World.fx
    local needCanvas = (fx.shake or 0) > 0 or (fx.blur or 0) > 0

    if needCanvas then
        local canvas = ensureCanvas(W, H)
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 1)
        drawSceneWorld()
        love.graphics.setCanvas()

        local ox, oy = 0, 0
        if fx.shake > 0 then
            local amp = Fonts.px(14) * math.min(1.25, fx.shake / 0.22)
            ox = (love.math.random() * 2 - 1) * amp
            oy = (love.math.random() * 2 - 1) * amp
        end
        World._shakeX, World._shakeY = ox, oy

        love.graphics.setColor(1, 1, 1, 1)
        if fx.blur > 0 then
            local s = Fonts.px(5) * math.min(1, fx.blur / 0.35)
            blurOffs[1][1], blurOffs[1][2] = s, 0
            blurOffs[2][1], blurOffs[2][2] = -s, 0
            blurOffs[3][1], blurOffs[3][2] = 0, s
            blurOffs[4][1], blurOffs[4][2] = 0, -s
            love.graphics.setColor(1, 1, 1, 0.28)
            for i = 1, 4 do
                love.graphics.draw(canvas, ox + blurOffs[i][1], oy + blurOffs[i][2])
            end
            love.graphics.setColor(1, 1, 1, 0.55)
        end
        love.graphics.draw(canvas, ox, oy)
    else
        World._shakeX, World._shakeY = 0, 0
        drawSceneWorld()
    end

    if (fx.hurt or 0) > 0 then
        love.graphics.setColor(0.75, 0.05, 0.05, 0.55 * math.min(1, fx.hurt / 0.35))
        love.graphics.rectangle("fill", 0, 0, W, H)
    end
    -- 击中怪物时短暂血雾罩
    if (fx.blood or 0) > 0 then
        love.graphics.setColor(0.55, 0.02, 0.04, 0.35 * math.min(1, fx.blood / 0.2))
        love.graphics.rectangle("fill", 0, 0, W, H)
    end

    World.drawOverlay()
    World.drawHud()
    Blood.draw()
    love.graphics.setColor(1, 1, 1, 1)
end

local function tickTimers(dt)
    if World.actionT > 0 then
        World.actionT = World.actionT - dt
        if World.actionT <= 0 then World.actionText = "" end
    end
    if World.atkCd > 0 then World.atkCd = World.atkCd - dt end
    if World.poseAtkT and World.poseAtkT > 0 then
        World.poseAtkT = World.poseAtkT - dt
        if World.poseAtkT < 0 then World.poseAtkT = 0 end
    end
    World.tickBlockStamina(dt)
    local fx = World.fx
    if fx.hurt > 0 then fx.hurt = fx.hurt - dt end
    if fx.shake > 0 then fx.shake = fx.shake - dt end
    if fx.blur > 0 then fx.blur = fx.blur - dt end
    if fx.blood > 0 then fx.blood = fx.blood - dt end
    tickHand(dt)
    Blood.update(dt)
end

-- canPose：附身或战斗图可播立绘；canFight：可造成伤害 / 刷怪 AI
function World.canPose()
    return World.infinite or World.puppet ~= nil
end

function World.canFight()
    return World.infinite == true
end

function World.sceneKind()
    local s = World.scene
    if not s then return "none" end
    return s.kind or (s.test and "test") or (s.boss and "boss")
        or (s.hub and "hub") or (s.fixed and "station") or "wild"
end

function World.setBlocking(on)
    World.blocking = on and true or false
end

-- scancode 探测（pcall：部分 Love 版本别名无效）
local function scanDown(code)
    local ok, down = pcall(love.keyboard.isScancodeDown, code)
    return ok and down == true
end

local function anyScan(codes)
    for i = 1, #codes do
        if scanDown(codes[i]) then return true end
    end
    return false
end

local CTRL_SC = { "lctrl", "rctrl" }
local SLASH_SC = { "/", "slash", "kp/", "kpdivide" }

local function ctrlDown()
    return anyScan(CTRL_SC)
end

local function slashDown()
    if anyScan(SLASH_SC) then return true end
    local ok, down = pcall(love.keyboard.isDown, "/", "slash", "kp/")
    return ok and down == true
end

-- 只记录意图；实际格挡由 tickBlockStamina 结算（耐力 / 冷却）
local function applyBlock(on)
    World._wantBlock = on and true or false
    if not on then
        World.blocking = false
    end
end

-- 格挡耐力：按住消耗，松手回复；耗尽进入冷却
function World.tickBlockStamina(dt)
    local want = World._wantBlock and World.canPose()
    if (World.blockCd or 0) > 0 then
        World.blockCd = World.blockCd - dt
        World.blocking = false
        if World.blockCd <= 0 then
            World.blockCd = 0
            if not want then
                World.blockStamina = World.blockStaminaMax or 1
            end
        end
        return
    end
    if want then
        if (World.blockStamina or 0) > 0 then
            World.blocking = true
            World.poseAtkT = 0
            World.blockStamina = World.blockStamina - dt
            if World.blockStamina <= 0 then
                World.blockStamina = 0
                World.blocking = false
                World.blockCd = 1.15
                flash("格挡力竭")
            end
        else
            World.blocking = false
        end
    else
        World.blocking = false
        local max = World.blockStaminaMax or 1
        World.blockStamina = math.min(max, (World.blockStamina or 0) + dt * 0.65)
    end
end

function World.muteCombatInput()
    World._inputMute = 2
    World._prevCtrl = ctrlDown()
    World._prevSlash = slashDown()
    World._ctrlHeld = World._prevCtrl
    applyBlock(false)
end

-- 事件通道：Ctrl 格挡，/ 攻击
function World.combatKey(scancode, down)
    if not scancode then return end
    if scancode == "lctrl" or scancode == "rctrl" then
        World._ctrlHeld = down and true or ctrlDown()
        applyBlock(World._ctrlHeld)
        World._prevCtrl = World._ctrlHeld
    elseif down and (scancode == "/" or scancode == "slash" or scancode == "kp/" or scancode == "kpdivide") then
        World.attack()
        World._prevSlash = true
    elseif scancode == "/" or scancode == "slash" or scancode == "kp/" or scancode == "kpdivide" then
        World._prevSlash = slashDown()
    end
end

-- 每帧纠偏：Ctrl 按住格挡；/ 边沿攻击
function World.tickCombatKeys()
    if (World._inputMute or 0) > 0 then
        World._inputMute = World._inputMute - 1
        World._prevCtrl = ctrlDown()
        World._prevSlash = slashDown()
        World._ctrlHeld = World._prevCtrl
        applyBlock(false)
        return
    end
    local ctrl = ctrlDown()
    local slash = slashDown()
    applyBlock(ctrl)
    World._ctrlHeld = ctrl
    if slash and not World._prevSlash then
        World.attack()
    end
    World._prevCtrl = ctrl
    World._prevSlash = slash
end

-- 准星屏幕坐标（固定中心；抵消画布抖动后与场景盒对齐）
function World.aimPos()
    local W, H = love.graphics.getDimensions()
    return W * 0.5 - (World._shakeX or 0), H * 0.5 - (World._shakeY or 0)
end

local function enemyAimScale(e)
    if e.atkFx and e.atkFx > 0 then return Enemies.ATK_SCALE or 1.1 end
    return 1
end

-- 朝向射线命中的敌人（格子判定）。opts: maxDist
function World.cursorEnemy(opts)
    opts = opts or aimOpts
    if not World.canFight() then return nil end
    local maxDist = opts.maxDist or reach()
    local i = Ray.aimRayEnemy(World.px, World.py, World.pa, World.enemies, maxDist)
    return i and World.enemies[i] or nil
end

-- 指定敌人是否在朝向射线上（近战格挡瞄准）
function World.cursorOnEnemy(e, opts)
    if not e or (e.hp or 0) <= 0 then return false end
    opts = opts or {}
    local maxDist = opts.maxDist or (reach() + 0.2)
    return Ray.enemyOnAimRay(World.px, World.py, World.pa, e, maxDist)
end

function World.cursorBullet(opts)
    opts = opts or {}
    local list = World.bullets
    if not list or #list == 0 then return nil end
    local mx, my = World.aimPos()
    local i = Ray.aim(World.px, World.py, World.pa, list, mx, my, {
        role = "bullet",
        expand = false,
        pad = 0,
    })
    return i and list[i] or nil
end

function World.cursorOnBullet(b, opts)
    if not b then return false end
    opts = opts or {}
    local mx, my = World.aimPos()
    return Ray.hitsOne(World.px, World.py, World.pa, b, mx, my, {
        expand = false,
        pad = 0,
    })
end

-- 绘制射线可打中的敌人（需 World.showAim）
function World.drawAimHelpers()
    if not World.canFight() or not World.showAim then return end
    aimOpts.maxDist = reach()
    local px, py, pa = World.px, World.py, World.pa
    local list = World.enemies
    local target = World.cursorEnemy(aimOpts)
    for i = 1, #list do
        local e = list[i]
        if (e.hp or 0) > 0 then
            local box = Ray.enemyHitBox(px, py, pa, e.x, e.y, enemyAimScale(e))
            if box then
                local hot = e == target
                if hot then
                    love.graphics.setColor(0.35, 1, 0.45, 0.22)
                    love.graphics.rectangle("fill", box.left, box.top, box.bw, box.bh)
                    love.graphics.setColor(0.4, 1, 0.5, 0.9)
                else
                    love.graphics.setColor(1, 0.85, 0.2, 0.1)
                    love.graphics.rectangle("fill", box.left, box.top, box.bw, box.bh)
                    love.graphics.setColor(1, 0.8, 0.15, 0.55)
                end
                love.graphics.setLineWidth(2)
                love.graphics.rectangle("line", box.left, box.top, box.bw, box.bh)
            end
        end
    end
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

function World.updateEnemies(dt)
    tickTimers(dt)
    if not World.canFight() then return false end
    if World.testMode then
        World.hp = World.maxHp
        return Enemies.update(World, dt, fxPulse)
    end
    -- 定时把附近怪物拉入列表；数量过低则远处补刷
    World._syncT = (World._syncT or 0) - dt
    if World._syncT <= 0 then
        World._syncT = 0.85
        if not World.bossMode then
            Gen.maybeReplenish(World.px, World.py)
            Enemies.sync(World, World._spawned)
        end
    end
    return Enemies.update(World, dt, fxPulse)
end

local function rollLoot(e)
    local lo = e.lootMin
    if lo == nil then lo = 1 end
    local hi = e.lootMax
    if hi == nil then hi = lo end
    if hi < lo then hi = lo end
    if hi <= 0 then return 0 end
    if lo < 0 then lo = 0 end
    return love.math.random(lo, hi)
end

function World.grantKillLoot(e)
    if not e or e._looted then return end
    e._looted = true
    World.kills = (World.kills or 0) + 1
    if not e.boss and not World.bossMode and not World.testMode then
        Gen.onMonsterKilled()
    end
    local n = rollLoot(e)
    if e.boss then
        World.ether = (World.ether or 0) + n
        World.bossCleared = true
        local heal = math.max(2, math.ceil((World.maxHp or 5) * 0.35))
        World.hp = math.min(World.maxHp or heal, (World.hp or 0) + heal)
        World.writeSave({ quiet = true })
        local slot = World.bossReturn and World.bossReturn.slot
        local tag = (slot == "main") and "主座" or "领主"
        flash(tag .. "陨落 · 以太+" .. n .. " · 恢复" .. heal)
    else
        World.ash = (World.ash or 0) + n
    end
end

function World.separateFromEnemies()
    if not World.canFight() then return end
    local list = World.enemies
    if not list then return end
    local px, py = World.px, World.py
    local minSep = Enemies.MIN_SEP or 0.95
    local min2 = minSep * minSep
    for i = 1, #list do
        local e = list[i]
        if e and (e.hp or 0) > 0 then
            local dx, dy = e.x - px, e.y - py
            local d2 = dx * dx + dy * dy
            if d2 < min2 or (math.floor(e.x) == math.floor(px) and math.floor(e.y) == math.floor(py)) then
                local d = math.sqrt(math.max(d2, 1e-8))
                if d2 < 1e-8 then
                    local ang = World.pa + math.pi
                    e.x = px + math.cos(ang) * minSep
                    e.y = py + math.sin(ang) * minSep
                else
                    e.x = px + dx / d * minSep
                    e.y = py + dy / d * minSep
                end
            end
        end
    end
end

function World.flashAttackPose()
    World.poseAtkT = math.max(0.22, World.atkDur or 0.14)
end

function World.attack()
    if not World.canPose() then return end
    if not World.canFight() then
        World.flashAttackPose()
        return
    end
    if (World.atkCd or 0) > 0 then return end
    World.flashAttackPose()
    aimOpts.maxDist = reach()
    local e = World.cursorEnemy(aimOpts)
    local cd = World.atkDur or 0.14
    if cd < 0.10 then cd = 0.10 end
    World.atkCd = cd
    if not e then return end
    e.hurt, e.hurtT = true, e.hurtFlash or 0.35
    if World.testMode or e.immortal then
        Blood.burstFromEnemy(World, e, { kill = false })
        fxPulse("shake", 0.16)
        fxPulse("blood", 0.16)
        return
    end
    local wasAlive = e.hp > 0
    local dmg = math.floor(((World.atk or BASE_ATK) + 1e-6) * 10 + 0.5) / 10
    e.hp = e.hp - dmg
    -- 余量过小直接击杀，避免 0.85 攻打 1HP 需两刀
    if e.hp < 0.15 then e.hp = 0 end
    local killed = wasAlive and e.hp <= 0
    Blood.burstFromEnemy(World, e, { kill = killed })
    fxPulse("shake", killed and 0.32 or 0.18)
    fxPulse("blood", killed and 0.28 or 0.16)
    if killed then
        World.grantKillLoot(e)
    end
end

function World.inDeath()
    return World.death ~= nil
end

-- 战斗死亡：记分（扣罚前）→ 扣火烬 → 突脸杀 → 黑屏 → 人偶馆醒来
function World.beginDeath(killer)
    if World.testMode then
        World.hp = World.maxHp
        return
    end
    World._deathDepth = World.expeditionDepth()
    World._deathScore = World.calcScore()
    local pen = World.deathAshPenalty()
    World.ash = (World.ash or 0) - pen
    World._deathAshLost = pen
    deathItemLoss()
    World.appendDeathRecord(killer)
    World.bossReturn, World.bossMode, World.bossCleared = nil, false, false
    World.depth = 0
    World.blocking = false
    World._wantBlock = false
    World.blockCd = 0
    World.blockStamina = World.blockStaminaMax or 1
    World.death = {
        phase = "face", t = 0,
        img = killer and killer.img,
        iw = killer and killer.iw or 1,
        ih = killer and killer.ih or 1,
    }
end

function World.updateDeath(dt)
    local d = World.death
    if not d then return end
    d.t = d.t + dt
    if d.phase == "face" and d.t >= 0.55 then
        d.phase, d.t = "black", 0
    elseif d.phase == "black" and d.t >= 0.75 then
        World.finishDeath()
    end
end

function World.finishDeath()
    World.death = nil
    World.endPuppet()
    World.load("main")
    local score = World._deathScore or 0
    local best = World.bestScore or 0
    flash(string.format("陨落 · 得分%d（最佳%d）", score, best))
end

function World.drawDeath()
    local d = World.death
    if not d then return end
    local W, H = love.graphics.getDimensions()
    if d.phase == "face" and d.img then
        local p = math.min(1, d.t / 0.55)
        local ease = p * p
        local scale = (H / d.ih) * (0.4 + ease * 5.2)
        local dw, dh = d.iw * scale, d.ih * scale
        love.graphics.setColor(0.05, 0.02, 0.02)
        love.graphics.rectangle("fill", 0, 0, W, H)
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(d.img, (W - dw) * 0.5, (H - dh) * 0.45, 0, scale, scale)
        love.graphics.setColor(0, 0, 0, ease * 0.65)
        love.graphics.rectangle("fill", 0, 0, W, H)
    else
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function World.billboards()
    bbN = 0
    for i = 1, #World.npcs do
        local n = World.npcs[i]
        bbPush(n.x, n.y, nil, n.role, n.img, n.iw, n.ih, n.aspect, 0, 0, false, nil)
    end
    for i = 1, #World.enemies do
        local e = World.enemies[i]
        local scale = (e.atkFx and e.atkFx > 0) and Enemies.ATK_SCALE or 0
        bbPush(e.x, e.y, nil, "enemy", e.img, e.iw, e.ih, e.aspect, scale, e.atkFx, e.hurt, e.hp)
    end
    local bullets = World.bullets
    if bullets then
        for i = 1, #bullets do
            local b = bullets[i]
            bbPush(b.x, b.y, nil, "bullet", b.img, b.iw, b.ih, b.aspect, 0, 0, false, 1, b.quad, b.size)
        end
    end
    for i = bbN + 1, #bbView do bbView[i] = nil end
    return bbView
end

function World.nearby(role)
    local t = {}
    for i = 1, #World.npcs do
        local n = World.npcs[i]
        if not role or n.role == role then
            local dx, dy = n.x - World.px, n.y - World.py
            if dx * dx + dy * dy <= TALK2 then t[#t + 1] = n end
        end
    end
    return t
end

function World.findNpc(role)
    for i = 1, #World.npcs do
        if World.npcs[i].role == role then return World.npcs[i] end
    end
end

function World.hasSave()
    return love.filesystem.getInfo(SAVE_FILE) ~= nil
end

function World.clearSave()
    if love.filesystem.getInfo(SAVE_FILE) then love.filesystem.remove(SAVE_FILE) end
    World.ash, World.ether = 0, 0
    World.boost = { hp = 0, atk = 0, spd = 0 }
    World.inv = {}
    World.depth, World.maxDepth = 0, 0
    World.explored, World.kills, World.bestScore = {}, 0, 0
    World.atk = BASE_ATK
end

-- 写入火烬、以太、铸魂、探索层与背包
function World.writeSave(opts)
    opts = opts or {}
    local b = World.boost or { hp = 0, atk = 0, spd = 0 }
    local score = World.calcScore()
    if score > (World.bestScore or 0) then World.bestScore = score end
    local lines = {
        "ash=" .. tostring(World.ash or 0),
        "ether=" .. tostring(World.ether or 0),
        "boost_hp=" .. tostring(b.hp or 0),
        "boost_atk=" .. tostring(b.atk or 0),
        "boost_spd=" .. tostring(b.spd or 0),
        "maxDepth=" .. tostring(World.maxDepth or 0),
        "kills=" .. tostring(World.kills or 0),
        "bestScore=" .. tostring(World.bestScore or 0),
        "explored=" .. encodeExplored(),
    }
    local items = Data.items or {}
    for i = 1, #items do
        local key = items[i].key
        local n = World.invCount(key)
        if n > 0 then lines[#lines + 1] = "inv_" .. key .. "=" .. n end
    end
    love.filesystem.write(SAVE_FILE, table.concat(lines, "\n") .. "\n")
    if not opts.quiet then flash("已存档") end
    return true
end

function World.applySave()
    local raw = love.filesystem.read(SAVE_FILE)
    if not raw then return false end
    World.endPuppet()
    local ash = tonumber(raw:match("ash=(%-?%d+)"))
    local ashBank = tonumber(raw:match("ashBank=(%-?%d+)"))
    local etherLine = tonumber(raw:match("ether=(%-?%d+)"))
    local money = tonumber(raw:match("money=(%-?%d+)"))
    if ash ~= nil then
        World.ash = ash
        World.ether = etherLine or 0
    elseif ashBank ~= nil then
        -- 旧档：池中火烬并入火烬
        World.ash = ashBank
        World.ether = etherLine or 0
    else
        -- 更旧：ether=/money= 曾是货币
        World.ash = etherLine or money or 0
        World.ether = 0
    end
    World.boost = {
        hp = tonumber(raw:match("boost_hp=(%-?%d+)")) or 0,
        atk = tonumber(raw:match("boost_atk=(%-?%d+)")) or 0,
        spd = tonumber(raw:match("boost_spd=(%-?%d+)")) or 0,
    }
    World.kills = tonumber(raw:match("kills=(%-?%d+)")) or 0
    World.maxDepth = tonumber(raw:match("maxDepth=(%-?%d+)")) or 0
    World.bestScore = tonumber(raw:match("bestScore=(%-?%d+)")) or 0
    decodeExplored(raw:match("explored=([^\r\n]*)"))
    World.inv = {}
    local items = Data.items or {}
    for i = 1, #items do
        local key = items[i].key
        local n = tonumber(raw:match("inv_" .. key .. "=(%-?%d+)"))
        if n and n > 0 then World.inv[key] = n end
    end
    World.load("main")
    local j = World.findNpc("save")
    if j then World.px, World.py, World.pa = beside({ j }) end
    flash("已读档")
    return true
end

-- 马车：驿站/其它生物群系第 1 层；层内深入靠击败 Boss
-- 野外逃离（depth>0）收逃离费，避免无代价回城
function World.destinations()
    local curKey, curDepth = World.key, World.depth or 0
    local fleeing = curDepth > 0
    local flee = World.fleeFare()
    local t = {}
    for k, s in pairs(Scenes) do
        if k == "main" or s.test or s.boss then
            -- skip
        elseif s.fixed then
            if not (k == curKey and curDepth == 0) then
                local fare = fleeing and flee or 2
                t[#t + 1] = {
                    key = k, depth = 0, fare = fare,
                    title = s.title .. (fleeing and ("（逃离" .. fare .. "）") or ("（车资" .. fare .. "）")),
                }
            end
        else
            -- 野外：总是进入该图第 1 层（新随机层）
            if not (k == curKey and curDepth == 1) then
                local fare = fleeing and flee or 0
                local tag = fare > 0 and ("（逃离" .. fare .. "→第1层）") or "（第1层）"
                t[#t + 1] = {
                    key = k, depth = 1, fare = fare,
                    title = s.title .. tag,
                }
            end
        end
    end
    table.sort(t, function(a, b) return a.key < b.key end)
    return t
end

return World
