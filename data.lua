-- 游戏数据：pcs / entities / scenes
-- entities：墙 / NPC / 人偶 / 怪物 / 机关 — 同一套显示字段（look）

local Data = {}

local FALLBACK = "resources/cannibal.png"
local MAP_KEYS = { "main", "main2", "forest", "moon", "ice", "lake", "rock" }

-- look(spec)：string 全图共用；table 按场景填，缺省用 _default 或 cannibal
local function Look(spec)
    local out, default = {}, FALLBACK
    if type(spec) == "string" then
        default = spec
    elseif type(spec) == "table" then
        default = spec._default or FALLBACK
        for k, v in pairs(spec) do
            if k ~= "_default" then out[k] = v end
        end
    end
    for i = 1, #MAP_KEYS do
        local k = MAP_KEYS[i]
        if not out[k] then out[k] = default end
    end
    return out
end

------------------------------------------------------------
-- PC：人偶馆的手、操控各人偶时的立绘 / 战斗属性
------------------------------------------------------------
local function PcStats(over)
    local s = {
        hp = 5,
        atk = 1,
        moveSpd = 2.5,
        atkRange = 1.35, -- 默认近战约一格半
        atkDur = 0.16,   -- 攻击间隔
        blockDur = 0.32,
    }
    if over then for k, v in pairs(over) do s[k] = v end end
    return s
end

Data.PC_DEFAULT = PcStats()

-- 物品：背包纯文本 名称[数量]；price 为火烬价
Data.items = {
    { key = "potion",      name = "伤药",     price = 8,  heal = 3 },
    { key = "potion_mid",  name = "中级伤药", price = 16, heal = 6 },
    { key = "potion_high", name = "高级伤药", price = 28, heal = 10 },
    { key = "key",         name = "钥匙",     price = 22 },
}
Data.itemsByKey = {}
for i = 1, #Data.items do
    Data.itemsByKey[Data.items[i].key] = Data.items[i]
end

-- 各地图普通 Boss 装置名（每图各 1，共 3）；其余场景用「场景名+bossN」
Data.bossSites = {
    forest = { "残破的白桦林", "狼穴", "森林墓地" },
    moon   = { "月面场景boss1", "月面场景boss2", "月面场景boss3" },
    ice    = { "冰原场景boss1", "冰原场景boss2", "冰原场景boss3" },
    lake   = { "湖畔场景boss1", "湖畔场景boss2", "湖畔场景boss3" },
    rock   = { "岩地场景boss1", "岩地场景boss2", "岩地场景boss3" },
}

function Data.bossSiteNames(sceneKey)
    local t = Data.bossSites[sceneKey]
    if t then return t end
    local s = Data.scenes and Data.scenes[sceneKey]
    local title = (s and s.title) or tostring(sceneKey or "未知")
    return { title .. "场景boss1", title .. "场景boss2", title .. "场景boss3" }
end

-- 人偶 PC：统一立绘路径约定 resources/<key>.png / _attack / _parry
local function DollPc(key, statsOver, paths)
    paths = paths or {}
    local base = "resources/" .. key
    return {
        select = paths.select or (base .. ".png"),
        attack = paths.attack or (base .. "_attack.png"),
        parry = paths.parry or (base .. "_parry.png"),
        scale = paths.scale or 1,
        -- 立绘靠左，避免挡住中心准星
        x = paths.x or 0,
        stats = PcStats(statsOver),
    }
end

Data.pcs = {
    player = {
        hand = {
            normal = "resources/hand_normal.png",
            good = "resources/hand_good.png",
            scale = 1.55,
            hold = 3,
            slide = 0.28,
            yyyGap = 0.4,
            yyyNeed = 3,
        },
        stats = PcStats(),
    },
    amoris = DollPc("amoris", {
        -- 轻快短刃：最短距、最快攻；1.0 可一刀收 1HP 杂兵
        atk = 1.0, moveSpd = 3.05, atkRange = 1.20,
        atkDur = 0.12, blockDur = 0.28,
    }),
    doloris = DollPc("doloris", {
        atk = 1.05, moveSpd = 2.70, atkRange = 1.35,
        atkDur = 0.14, blockDur = 0.32,
    }),
    oblivionis = DollPc("oblivionis", {
        atk = 1.15, moveSpd = 2.50, atkRange = 1.50,
        atkDur = 0.15, blockDur = 0.34,
    }),
    motis = DollPc("motis", {
        -- 重击：稍长距、慢攻高伤
        atk = 1.45, moveSpd = 2.15, atkRange = 1.65,
        atkDur = 0.20, blockDur = 0.36,
    }),
    timoris = DollPc("timoris", {
        -- 长刃：人偶中最远，仍控制在两格内
        atk = 1.35, moveSpd = 2.25, atkRange = 1.80,
        atkDur = 0.17, blockDur = 0.35,
    }, {
        select = "resources/timoris_saber.png",
        attack = "resources/timoris_attack.png",
        parry = "resources/timoris_parry.png",
    }),
}

------------------------------------------------------------
-- Entities：统一表（墙 / NPC / 人偶 / 怪物 / 机关）
-- 字段：id key name role look
-- 敌人另有 combat：hp atk style(melee|ranged) move blockable
--          + 共用节奏 atkCd moveSpd vision atkRange hurtFlash spawnCd
------------------------------------------------------------
local COMBAT_BASE = {
    atkCd = 1.15, moveSpd = 1.20, vision = 4.5,
    -- 近战贴身交战（略小于玩家最短距，需贴近）
    atkRange = 1.05, rangedRange = 3.8, hurtFlash = 0.35, spawnCd = 0.4,
    rangedAtkCd = 2.4,
    suicideFuse = 0.50,
    suicideRange = 0.95,
}

local function lootRange(hp, atk)
    local t = (hp or 1) * (atk or 1)
    if t <= 1 then return 1, 3
    elseif t <= 2 then return 2, 5
    elseif t <= 4 then return 4, 9
    elseif t <= 6 then return 6, 14
    elseif t <= 10 then return 10, 20
    else return 14, 30 end
end

local function Combat(hp, atk, style, opts)
    opts = opts or {}
    local lo, hi = lootRange(hp, atk)
    local ranged = style == "ranged"
    local suicide = style == "suicide"
    local c = {
        hp = hp, atk = atk, style = style,
        move = opts.move ~= false,
        blockable = opts.blockable ~= false, -- 默认可格挡；显式 false 关闭
        atkCd = opts.atkCd or (ranged and COMBAT_BASE.rangedAtkCd or COMBAT_BASE.atkCd),
        moveSpd = opts.moveSpd or COMBAT_BASE.moveSpd,
        vision = opts.vision or COMBAT_BASE.vision,
        atkRange = opts.atkRange
            or (ranged and COMBAT_BASE.rangedRange)
            or (suicide and COMBAT_BASE.suicideRange)
            or COMBAT_BASE.atkRange,
        hurtFlash = opts.hurtFlash or COMBAT_BASE.hurtFlash,
        spawnCd = opts.spawnCd or COMBAT_BASE.spawnCd,
        lootMin = opts.lootMin or lo,
        lootMax = opts.lootMax or hi,
        bullet = opts.bullet or 1, -- bullet5 四×四裁切，默认第 1 色
        fuse = opts.fuse or (suicide and COMBAT_BASE.suicideFuse or nil),
    }
    return c
end

-- 刷新：weight 越大越常见；pack={min,max} 成群
-- 强弱大致按威胁（血×攻，群按只数）压权重
local function Spawn(weight, opts)
    opts = opts or {}
    return { weight = weight, pack = opts.pack }
end

-- 通用怪：各野外层都会刷，look 按地图分（暂无 cannibal）
local GENERIC_LOOK = Look(FALLBACK)

-- 墙：射线贴图按场景
local WALL_LOOK = Look({
    main   = "resources/castle_wall.jpg",
    main2  = "resources/tree.png",
    forest = "resources/tree.png",
    moon   = "resources/MOON_M.png",
    ice    = "resources/ICE_M.png",
    lake   = "resources/lake.png",
    rock   = "resources/ROCKM.png",
})

local list = {
    ------------------------------------------------------------
    -- 墙 / NPC / 人偶 / 机关
    ------------------------------------------------------------
    {
        id = 1, key = "wall", name = "墙", role = "wall",
        look = WALL_LOOK,
    },
    {
        id = 2, key = "carter", name = "马车夫", role = "travel",
        spawn = Spawn(36),
        look = Look(FALLBACK),
    },
    {
        id = 3, key = "journal", name = "手记", role = "save",
        look = Look(FALLBACK),
    },
    {
        id = 5, key = "smith", name = "铸魂师", role = "boost",
        look = Look(FALLBACK),
    },
    {
        id = 6, key = "shop", name = "杂货商", role = "shop",
        look = Look(FALLBACK),
        shop = { pay = "ash", goods = { "potion", "potion_mid", "potion_high", "beef", "key" } },
    },
    {
        id = 7, key = "peddler", name = "行商人", role = "shop",
        spawn = Spawn(40),
        look = Look(FALLBACK),
        shop = { pay = "ash", goods = { "potion", "potion_mid", "beef", "key" } },
    },
    {
        id = 8, key = "boss_door", name = "封印之门", role = "door",
        spawn = Spawn(0),
        look = Look(FALLBACK),
    },
    {
        -- 普通 Boss 激活装置（名由生成时写入）
        id = 19, key = "boss_device", name = "Boss装置", role = "boss_device",
        spawn = Spawn(0),
        look = Look(FALLBACK),
    },
    {
        -- 主 Boss 装置：清完 3 个普通后才有机会出现
        id = 20, key = "boss_main_device", name = "主座装置", role = "boss_main",
        spawn = Spawn(0),
        look = Look(FALLBACK),
    },
    {
        id = 9, key = "boss_exit", name = "归途", role = "exit",
        look = Look(FALLBACK),
    },
    {
        -- 裂隙保留实体定义（兼容对话），不再随机刷出
        id = 15, key = "abyss", name = "深渊裂隙", role = "abyss",
        spawn = Spawn(0),
        look = Look(FALLBACK),
    },
    {
        -- 可疑痕迹：搜索得点/物资，也可能刷怪
        id = 16, key = "search", name = "可疑痕迹", role = "search",
        spawn = Spawn(70),
        look = Look(FALLBACK),
    },
    {
        -- 宝箱：与搜索同类交互，奖励略偏物资
        id = 17, key = "chest", name = "宝箱", role = "chest",
        spawn = Spawn(65),
        look = Look(FALLBACK),
    },
    {
        -- 简易机关：触发后随机小奖励或惊吓
        id = 18, key = "mechanism", name = "锈蚀机关", role = "mech",
        spawn = Spawn(55),
        look = Look(FALLBACK),
    },
    {
        id = 10, key = "amoris", name = "Amoris", role = "doll",
        look = Look({ main = "resources/amoris_scene.png", _default = "resources/amoris_scene.png" }),
    },
    {
        id = 11, key = "doloris", name = "Doloris", role = "doll",
        look = Look({ main = "resources/doloris_scene.png", _default = "resources/doloris_scene.png" }),
    },
    {
        id = 12, key = "motis", name = "Motis", role = "doll",
        look = Look({ main = "resources/motis_scene.png", _default = "resources/motis_scene.png" }),
    },
    {
        id = 13, key = "oblivionis", name = "Oblivionis", role = "doll",
        look = Look({ main = "resources/oblivionis_scene.png", _default = "resources/oblivionis_scene.png" }),
    },
    {
        id = 14, key = "timoris", name = "Timoris", role = "doll",
        look = Look({ main = "resources/timoris_scene.png", _default = "resources/timoris_scene.png" }),
    },
    ------------------------------------------------------------
    -- 通用怪物（按机制；每图外貌不同）
    ------------------------------------------------------------
    {
        id = 50, key = "melee_1", name = "近战怪", role = "enemy",
        archetype = true, spawn = Spawn(110, { pack = { 1, 2 } }),
        combat = Combat(2, 1, "melee"),
        look = GENERIC_LOOK,
    },
    {
        id = 51, key = "melee_3", name = "壮近战怪", role = "enemy",
        archetype = true, spawn = Spawn(40),
        combat = Combat(4, 2, "melee"),
        look = GENERIC_LOOK,
    },
    {
        id = 52, key = "melee_5", name = "重近战怪", role = "enemy",
        archetype = true, spawn = Spawn(20),
        combat = Combat(7, 3, "melee"),
        look = GENERIC_LOOK,
    },
    {
        id = 53, key = "ranged_1", name = "远程怪", role = "enemy",
        archetype = true, spawn = Spawn(85, { pack = { 1, 2 } }),
        combat = Combat(2, 1, "ranged", { blockable = true }),
        look = GENERIC_LOOK,
    },
    {
        id = 54, key = "suicide_1", name = "自爆怪", role = "enemy",
        archetype = true, spawn = Spawn(32),
        -- 脆皮、高伤、略快；贴脸引信后爆炸（可格挡）
        combat = Combat(2, 3, "suicide", { moveSpd = 1.50, vision = 4.8 }),
        look = GENERIC_LOOK,
    },
    {
        -- 普通领主（装置 1~3）
        id = 90, key = "boss_1", name = "巡境领主", role = "enemy",
        boss = true,
        combat = Combat(20, 3, "melee", {
            moveSpd = 1.05, vision = 5.5, atkRange = 1.15, atkCd = 1.15,
            lootMin = 8, lootMax = 14,
        }),
        look = GENERIC_LOOK,
    },
    {
        id = 91, key = "boss_main", name = "深渊主座", role = "enemy",
        boss = true,
        combat = Combat(32, 5, "melee", {
            moveSpd = 1.08, vision = 6.0, atkRange = 1.20, atkCd = 1.05,
            lootMin = 16, lootMax = 26,
        }),
        look = GENERIC_LOOK,
    },

    ------------------------------------------------------------
    -- 地图特色怪
    ------------------------------------------------------------
    -- 森林（中立狐权重压低，避免刷表被占满）
    {
        id = 60, key = "wolf", name = "狼", role = "enemy",
        specialty = "forest", spawn = Spawn(90, { pack = { 2, 3 } }),
        combat = Combat(2, 1, "melee"),
        look = Look({ forest = "resources/wolf.png" }),
    },
    {
        id = 61, key = "bear", name = "熊", role = "enemy",
        specialty = "forest", spawn = Spawn(40),
        combat = Combat(5, 2, "melee"),
        look = Look({ forest = "resources/bear.png" }),
    },
    {
        id = 62, key = "fox", name = "狐狸", role = "enemy",
        specialty = "forest", neutral = true, flee = true,
        spawn = Spawn(70),
        combat = Combat(2, 1, "melee", { moveSpd = 1.45, lootMin = 0, lootMax = 1 }),
        look = Look({ forest = "resources/fox.png" }),
    },
    {
        id = 63, key = "pig", name = "野猪", role = "enemy",
        specialty = "forest", spawn = Spawn(100),
        combat = Combat(4, 2, "melee"),
        look = Look({ forest = "resources/pig.png" }),
    },
    -- 月面 / 冰原 / 湖畔 / 岩地：特色槽位（机制后定；权重与森林总特色接近）
    {
        id = 70, key = "moon_a", name = "月面怪甲", role = "enemy",
        specialty = "moon", spawn = Spawn(100),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 71, key = "moon_b", name = "月面怪乙", role = "enemy",
        specialty = "moon", spawn = Spawn(75),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 72, key = "moon_c", name = "月面怪丙", role = "enemy",
        specialty = "moon", spawn = Spawn(50),
        combat = Combat(3, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 73, key = "moon_d", name = "月面怪丁", role = "enemy",
        specialty = "moon", spawn = Spawn(30),
        combat = Combat(4, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 74, key = "ice_a", name = "冰原怪甲", role = "enemy",
        specialty = "ice", spawn = Spawn(100),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 75, key = "ice_b", name = "冰原怪乙", role = "enemy",
        specialty = "ice", spawn = Spawn(75),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 76, key = "ice_c", name = "冰原怪丙", role = "enemy",
        specialty = "ice", spawn = Spawn(50),
        combat = Combat(3, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 77, key = "ice_d", name = "冰原怪丁", role = "enemy",
        specialty = "ice", spawn = Spawn(30),
        combat = Combat(4, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 78, key = "lake_a", name = "湖畔怪甲", role = "enemy",
        specialty = "lake", spawn = Spawn(100),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 79, key = "lake_b", name = "湖畔怪乙", role = "enemy",
        specialty = "lake", spawn = Spawn(75),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 80, key = "lake_c", name = "湖畔怪丙", role = "enemy",
        specialty = "lake", spawn = Spawn(50),
        combat = Combat(3, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 81, key = "lake_d", name = "湖畔怪丁", role = "enemy",
        specialty = "lake", spawn = Spawn(30),
        combat = Combat(4, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 82, key = "rock_a", name = "岩地怪甲", role = "enemy",
        specialty = "rock", spawn = Spawn(100),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 83, key = "rock_b", name = "岩地怪乙", role = "enemy",
        specialty = "rock", spawn = Spawn(75),
        combat = Combat(2, 1, "melee"), look = Look(FALLBACK),
    },
    {
        id = 84, key = "rock_c", name = "岩地怪丙", role = "enemy",
        specialty = "rock", spawn = Spawn(50),
        combat = Combat(3, 2, "melee"), look = Look(FALLBACK),
    },
    {
        id = 85, key = "rock_d", name = "岩地怪丁", role = "enemy",
        specialty = "rock", spawn = Spawn(30),
        combat = Combat(4, 2, "melee"), look = Look(FALLBACK),
    },
}

Data.entities = {
    FALLBACK = FALLBACK,
    INF_NPC_ID = 2,
    WALL_ID = 1,
    byId = {},
    byKey = {},
    archetypes = {},   -- 通用怪 id 列表（刷怪池）
    specialty = {},    -- sceneKey -> { def, ... }
}

for i = 1, #list do
    local e = list[i]
    Data.entities.byId[e.id] = e
    Data.entities.byKey[e.key] = e
    if e.archetype then
        Data.entities.archetypes[#Data.entities.archetypes + 1] = e
    end
    if e.specialty then
        local bag = Data.entities.specialty[e.specialty]
        if not bag then
            bag = {}
            Data.entities.specialty[e.specialty] = bag
        end
        bag[#bag + 1] = e
    end
end

-- 取某实体在场景下的显示图
function Data.look(ent, sceneKey)
    if not ent then return FALLBACK end
    local look = ent.look
    if type(look) == "string" then return look end
    if type(look) == "table" then
        return look[sceneKey] or look._default or FALLBACK
    end
    return FALLBACK
end

------------------------------------------------------------
-- Scenes：地图 / 背景 / 出生（墙贴图来自 entities.wall.look）
------------------------------------------------------------
-- 人偶馆：1墙 0空；a/d/m/o/t=人偶，w=手记，n=出生（空地）
local function hubMap()
    return {
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 13, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 }, -- m Motis / o Oblivionis
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 }, -- t Timoris / a Amoris
        { 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 0, 11, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, -- w 手记 / d Doloris
        { 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, -- n 出生
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    }
end

local function stationMap()
    return {
        {1,1,1,1,1,1,1,1},
        {1,0,0,0,0,6,0,1}, -- 杂货商
        {1,0,1,0,1,1,0,1},
        {1,0,1,0,5,0,0,1}, -- 铸魂师（强化）
        {1,0,0,0,1,0,1,1},
        {1,0,1,0,0,0,0,1},
        {1,0,0,2,0,1,0,1}, -- 马车夫
        {1,1,1,1,1,1,1,1},
    }
end

local function testArenaMap()
    -- 开发者试玩场：大空地，怪物由 World 另行生成
    local w, h = 22, 16
    local map = {}
    for r = 1, h do
        local row = {}
        for c = 1, w do
            row[c] = (r == 1 or r == h or c == 1 or c == w) and 1 or 0
        end
        map[r] = row
    end
    return map
end

-- Boss 独立房间：中央 Boss，南侧归途
local function bossRoomMap()
    return {
        {1,1,1,1,1,1,1,1,1,1,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,0,0,0,0,9,0,0,0,0,1}, -- 归途
        {1,0,0,0,0,0,0,0,0,0,1},
        {1,1,1,1,1,1,1,1,1,1,1},
    }
end

local function wallOf(sceneKey)
    return Data.look(Data.entities.byKey.wall, sceneKey)
end

-- 统一场景构造：kind = hub | station | wild | boss | test
-- map 有值 → 固定图；无 map → 512×512 随机层（打 Boss 后加深）
local function Scene(key, title, bg, opts)
    opts = opts or {}
    local kind = opts.kind
    if not kind then
        if opts.test then kind = "test"
        elseif opts.boss then kind = "boss"
        elseif opts.hub then kind = "hub"
        elseif opts.map then kind = "station"
        else kind = "wild" end
    end
    local wallKey = opts.wallKey or key
    local s = {
        key = key,
        title = title,
        wall = wallOf(wallKey),
        bg = bg,
        map = opts.map,
        fixed = opts.map ~= nil,
        kind = kind,
        hub = kind == "hub" or opts.hub or false,
        test = kind == "test" or opts.test or false,
        boss = kind == "boss" or opts.boss or false,
        pc = opts.pc,
        spawn = opts.spawn,
        overlay = opts.overlay,
    }
    return s
end

Data.scenes = {
    main = Scene("main", "人偶馆", "resources/castle_background.jpg", {
        kind = "hub", map = hubMap(), pc = "player", spawn = { 3.5, 27.5, 0 },
    }),
    main2 = Scene("main2", "驿站", "resources/background_yoru.png", {
        kind = "station", map = stationMap(),
    }),
    forest = Scene("forest", "森林", "resources/background_yoru.png", { kind = "wild" }),
    moon   = Scene("moon",   "月面", "resources/background_moon.png", { kind = "wild" }),
    ice    = Scene("ice",    "冰原", "resources/background_ice.png",  { kind = "wild" }),
    lake   = Scene("lake",   "湖畔", "resources/background_lake.png", {
        kind = "wild", overlay = "resources/boat.png",
    }),
    rock   = Scene("rock",   "岩地", "resources/background_rock.png", { kind = "wild" }),
    testarea = Scene("forest", "测试区", "resources/background_yoru.png", {
        kind = "test", map = testArenaMap(), wallKey = "forest",
        spawn = { 11.5, 8.5, -math.pi * 0.5 },
    }),
    boss = Scene("forest", "深渊之间", "resources/background_yoru.png", {
        kind = "boss", map = bossRoomMap(), wallKey = "forest",
        spawn = { 5.5, 9.5, -math.pi * 0.5 },
    }),
}

return Data
