-- 有限层地图：512×512；边长 5~7 分类矩形（怪/NPC/机关/Boss），每房≥2出口

local Data = require("data")

local MAP = 512
local MAP2 = MAP * MAP
local NPC_ID = Data.entities.INF_NPC_ID
local ROOM_MAX = 7          -- 边长 < 8
local ROOM_MIN = 5          -- 边长 > 4 → 5..7 任意组合
local ROOM_GAP = 4          -- 房间之间墙廊宽度
local SPAWN_PAD = 8 * 8     -- 出生点附近不刷怪
local REPLENISH_FRAC = 0.35
local REPLENISH_BATCH = 90
-- 怪物房内部最多刷只数（少于 5）
local MAX_ROOM_MONSTERS = 4
local MON_FILL_STRIDE = 2

local Gen = {
    seed = 0,
    sceneKey = "forest",
    depth = 1,
    size = MAP,
    cells = nil,
    npcs = {},
    monsters = {},
    rooms = {},
    spawnX = 16.5,
    spawnY = 16.5,
    monTarget = 0,
    liveCount = 0,
}

local poolCacheKey, poolCache, poolTotal
local nearMonBuf = {}
local enemyTypesCacheKey, enemyTypesCache

local function idx(x, y)
    return y * MAP + x + 1
end

local function inBounds(x, y)
    return x >= 0 and y >= 0 and x < MAP and y < MAP
end

local function hash(a, b, seed)
    local h = a * 374761393 + b * 668265263 + seed * 1274126177
    h = h % 2147483647
    if h < 0 then h = -h end
    return h
end

local function addToPool(pool, total, def)
    local sp = def and def.spawn
    local w = sp and sp.weight
    if not w or w <= 0 then return total end
    pool[#pool + 1] = def
    return total + w
end

local function spawnPool()
    if poolCacheKey == Gen.sceneKey and poolCache then
        return poolCache, poolTotal
    end
    local ents = Data.entities
    local pool, total = {}, 0
    local arch = ents.archetypes
    for i = 1, #arch do
        total = addToPool(pool, total, arch[i])
    end
    local spec = ents.specialty[Gen.sceneKey]
    if spec then
        for i = 1, #spec do
            total = addToPool(pool, total, spec[i])
        end
    end
    for _, def in pairs(ents.byId) do
        if not def.archetype and not def.specialty
            and def.key ~= "abyss" and def.key ~= "boss_1" then
            total = addToPool(pool, total, def)
        end
    end
    table.sort(pool, function(a, b) return a.id < b.id end)
    poolCacheKey, poolCache, poolTotal = Gen.sceneKey, pool, total
    return pool, total
end

-- 本图应出现的全部敌人类（通用 + 本场景特色，排除 boss）
local function enemyTypesForScene()
    if enemyTypesCacheKey == Gen.sceneKey and enemyTypesCache then
        return enemyTypesCache
    end
    local ents = Data.entities
    local list = {}
    local arch = ents.archetypes
    for i = 1, #arch do
        local d = arch[i]
        if d.role == "enemy" and not d.boss then list[#list + 1] = d end
    end
    local spec = ents.specialty[Gen.sceneKey]
    if spec then
        for i = 1, #spec do
            local d = spec[i]
            if d.role == "enemy" and not d.boss then list[#list + 1] = d end
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    enemyTypesCacheKey, enemyTypesCache = Gen.sceneKey, list
    return list
end

local function pickFromPool(salt)
    local pool, weightSum = spawnPool()
    if weightSum <= 0 or #pool == 0 then return nil end
    local roll = hash(salt, Gen.seed, Gen.depth) % weightSum
    local acc = 0
    for i = 1, #pool do
        acc = acc + pool[i].spawn.weight
        if roll < acc then return pool[i] end
    end
    return pool[#pool]
end

local function pickEnemy(salt)
    for _ = 1, 12 do
        local def = pickFromPool(salt)
        salt = salt + 31
        if def and def.role == "enemy" then return def end
    end
    local types = enemyTypesForScene()
    if #types > 0 then return types[1 + hash(salt, 5, Gen.seed) % #types] end
end

local function pickPoi(salt)
    for _ = 1, 16 do
        local def = pickFromPool(salt)
        salt = salt + 37
        if def and def.role ~= "enemy" and def.key ~= "boss_door" and def.key ~= "abyss" then
            return def
        end
    end
    -- 兜底：痕迹 / 箱 / 机关
    local keys = { "search", "chest", "mechanism" }
    local k = keys[1 + hash(salt, 8, Gen.seed) % #keys]
    return Data.entities.byKey[k]
end

local function getRaw(x, y)
    if not inBounds(x, y) then return 1 end
    return Gen.cells[idx(x, y)]
end

local function setRaw(x, y, v)
    Gen.cells[idx(x, y)] = v
end

local function carve(x, y)
    if inBounds(x, y) then setRaw(x, y, 0) end
end

local function isOpen(x, y)
    return getRaw(x, y) == 0
end

-- 连续空地过长时补墙（仅用于 ensureConnected 挖出的长廊）
local function breakLongRuns()
    local cells = Gen.cells
    local lim = ROOM_MAX
    for y = 1, MAP - 2 do
        local run = 0
        local row = y * MAP + 1
        for x = 1, MAP - 2 do
            local i = row + x
            if cells[i] == 0 then
                run = run + 1
                if run > lim then
                    cells[i] = 1
                    run = 0
                end
            else
                run = 0
            end
        end
    end
    for x = 1, MAP - 2 do
        local run = 0
        for y = 1, MAP - 2 do
            local i = y * MAP + x + 1
            if cells[i] == 0 then
                run = run + 1
                if run > lim then
                    cells[i] = 1
                    run = 0
                end
            else
                run = 0
            end
        end
    end
end

local function carveRect(x0, y0, x1, y1)
    local cells = Gen.cells
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    if x0 < 1 then x0 = 1 end
    if y0 < 1 then y0 = 1 end
    if x1 > MAP - 2 then x1 = MAP - 2 end
    if y1 > MAP - 2 then y1 = MAP - 2 end
    for y = y0, y1 do
        local row = y * MAP + 1
        for x = x0, x1 do
            cells[row + x] = 0
        end
    end
end

local function carveDoor(x, y)
    local cells = Gen.cells
    if x < 1 or y < 1 or x > MAP - 2 or y > MAP - 2 then return end
    cells[y * MAP + x + 1] = 0
end

local function carveLink(x0, y0, x1, y1)
    local cells = Gen.cells
    local x, y = x0, y0
    while x ~= x1 or y ~= y1 do
        cells[y * MAP + x + 1] = 0
        if x ~= x1 then
            x = x + (x1 > x and 1 or -1)
        else
            y = y + (y1 > y and 1 or -1)
        end
    end
    cells[y1 * MAP + x1 + 1] = 0
end

local function roomContains(r, x, y)
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local function countRoomExits(r)
    local n = 0
    local x0, y0, x1, y1 = r.x, r.y, r.x + r.w - 1, r.y + r.h - 1
    for x = x0, x1 do
        if isOpen(x, y0 - 1) then n = n + 1 end
        if isOpen(x, y1 + 1) then n = n + 1 end
    end
    for y = y0, y1 do
        if isOpen(x0 - 1, y) then n = n + 1 end
        if isOpen(x1 + 1, y) then n = n + 1 end
    end
    return n
end

-- 在房间某侧开一格门并外延 1 格廊
local function punchExit(r, side, salt, seed)
    local x0, y0, x1, y1 = r.x, r.y, r.x + r.w - 1, r.y + r.h - 1
    if side == "n" then
        local x = x0 + hash(salt, 1, seed) % r.w
        carveDoor(x, y0)
        carveDoor(x, y0 - 1)
    elseif side == "s" then
        local x = x0 + hash(salt, 2, seed) % r.w
        carveDoor(x, y1)
        carveDoor(x, y1 + 1)
    elseif side == "w" then
        local y = y0 + hash(salt, 3, seed) % r.h
        carveDoor(x0, y)
        carveDoor(x0 - 1, y)
    else
        local y = y0 + hash(salt, 4, seed) % r.h
        carveDoor(x1, y)
        carveDoor(x1 + 1, y)
    end
end

-- 邻房对接：有水平/垂直重叠走短廊，否则连中心
local function linkRooms(a, b)
    local y0 = math.max(a.y, b.y)
    local y1 = math.min(a.y + a.h - 1, b.y + b.h - 1)
    local x0 = math.max(a.x, b.x)
    local x1 = math.min(a.x + a.w - 1, b.x + b.w - 1)
    if b.cx > a.cx and y1 >= y0 then
        local y = y0 + math.floor((y1 - y0) / 2)
        local xStart = math.min(a.x + a.w - 1, b.x)
        local xEnd = math.max(a.x + a.w - 1, b.x)
        for x = xStart, xEnd do carveDoor(x, y) end
    elseif b.cy > a.cy and x1 >= x0 then
        local x = x0 + math.floor((x1 - x0) / 2)
        local yStart = math.min(a.y + a.h - 1, b.y)
        local yEnd = math.max(a.y + a.h - 1, b.y)
        for y = yStart, yEnd do carveDoor(x, y) end
    else
        carveLink(a.cx, a.cy, b.cx, b.cy)
    end
end

-- 房内散落墙块/短柱（不贴边，避免堵出口）
local function scatterInnerWalls(r, salt, seed)
    if r.w < 4 or r.h < 4 then return end
    local x0, y0 = r.x + 1, r.y + 1
    local x1, y1 = r.x + r.w - 2, r.y + r.h - 2
    if x1 < x0 or y1 < y0 then return end
    local iw, ih = x1 - x0 + 1, y1 - y0 + 1
    local area = iw * ih
    local n = 1 + hash(salt, 2, seed) % math.max(1, math.floor(area / 5))
    if n > 6 then n = 6 end
    for i = 1, n do
        local xx = x0 + hash(salt + i * 3, 4, seed) % iw
        local yy = y0 + hash(salt + i * 5, 6, seed) % ih
        if xx == r.cx and yy == r.cy and hash(salt + i, 9, seed) % 2 == 0 then
            xx = x0 + (xx - x0 + 1) % iw
        end
        setRaw(xx, yy, 1)
        if hash(salt + i, 11, seed) % 3 == 0 then
            local orth = {
                { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
            }
            local d = orth[1 + hash(salt + i, 13, seed) % 4]
            local nx, ny = xx + d[1], yy + d[2]
            if nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1 then
                if not (nx == r.cx and ny == r.cy) then
                    setRaw(nx, ny, 1)
                end
            end
        end
    end
end

local function randRoomSide(salt, seed)
    return ROOM_MIN + hash(salt, 1, seed) % (ROOM_MAX - ROOM_MIN + 1)
end

-- 边长 5~7 独立随机的矩形；邻房连廊，每房 ≥2 出口
local function buildTypedRooms(seed)
    local rooms = {}
    local y, row = 2, 0
    while y + ROOM_MIN < MAP - 2 do
        local x, col = 2, 0
        local rowMaxH = 0
        local rowStart = #rooms + 1
        while x + ROOM_MIN < MAP - 2 do
            local rw = randRoomSide(row * 31 + col * 7, seed)
            local rh = randRoomSide(row * 47 + col * 11 + 3, seed)
            if x + rw >= MAP - 1 then break end
            if y + rh >= MAP - 1 then break end
            carveRect(x, y, x + rw - 1, y + rh - 1)
            local room = {
                x = x, y = y, w = rw, h = rh,
                cx = x + math.floor(rw / 2),
                cy = y + math.floor(rh / 2),
                row = row, col = col,
                kind = "monster",
            }
            scatterInnerWalls(room, row * 97 + col * 13, seed)
            rooms[#rooms + 1] = room
            if rh > rowMaxH then rowMaxH = rh end
            x = x + rw + ROOM_GAP
            col = col + 1
        end
        if rowMaxH <= 0 then break end
        -- 同排右邻
        for i = rowStart, #rooms - 1 do
            linkRooms(rooms[i], rooms[i + 1])
        end
        -- 与上一排按水平重叠连南向
        if row > 0 then
            for i = rowStart, #rooms do
                local a = rooms[i]
                local best, bestOv
                for j = 1, rowStart - 1 do
                    local b = rooms[j]
                    if b.row == row - 1 then
                        local ov0 = math.max(a.x, b.x)
                        local ov1 = math.min(a.x + a.w - 1, b.x + b.w - 1)
                        local ov = ov1 - ov0 + 1
                        if ov > 0 and (not bestOv or ov > bestOv) then
                            best, bestOv = b, ov
                        end
                    end
                end
                if best then linkRooms(best, a) end
            end
        end
        y = y + rowMaxH + ROOM_GAP
        row = row + 1
    end

    local sides = { "n", "e", "s", "w" }
    for i = 1, #rooms do
        local r = rooms[i]
        local guard = 0
        while countRoomExits(r) < 2 and guard < 6 do
            local side = sides[1 + hash(i, guard + 9, seed) % 4]
            punchExit(r, side, i * 17 + guard, seed)
            guard = guard + 1
        end
    end

    return rooms
end

-- 从出生点连通全部空地；未达口袋挖曼哈顿廊再 flood
local function ensureConnected(sx, sy)
    local cells = Gen.cells
    local seen, q = {}, {}
    local qi = 1
    local function push(x, y)
        if x < 1 or y < 1 or x > MAP - 2 or y > MAP - 2 then return end
        local i = y * MAP + x + 1
        if cells[i] ~= 0 or seen[i] then return end
        seen[i] = true
        q[#q + 1] = x
        q[#q + 1] = y
    end
    local function drain()
        while qi <= #q do
            local x, y = q[qi], q[qi + 1]
            qi = qi + 2
            push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1)
        end
    end

    push(sx, sy)
    drain()

    for y = 1, MAP - 2 do
        local row = y * MAP + 1
        for x = 1, MAP - 2 do
            local i = row + x
            if cells[i] == 0 and not seen[i] then
                carveLink(x, y, sx, sy)
                push(x, y)
                drain()
            end
        end
    end
end

local function clearSpawnPad(cx, cy, r)
    for dy = -r, r do
        for dx = -r, r do
            carve(cx + dx, cy + dy)
        end
    end
    for i = 1, ROOM_MAX do
        carve(cx + i, cy)
        carve(cx + i, cy - 1)
        carve(cx + i, cy + 1)
    end
end

local function placeEntityCell(x, y, id)
    if not isOpen(x, y) then return false end
    setRaw(x, y, id)
    return true
end

local function findOpenNear(tx, ty, maxR)
    for r = 0, maxR or 12 do
        for dy = -r, r do
            for dx = -r, r do
                if r == 0 or math.abs(dx) == r or math.abs(dy) == r then
                    local x, y = tx + dx, ty + dy
                    if isOpen(x, y) then return x, y end
                end
            end
        end
    end
end

local function pushNpc(x, y, id)
    if not placeEntityCell(x, y, id) then return false end
    Gen.npcs[#Gen.npcs + 1] = { id = id, x = x + 0.5, y = y + 0.5 }
    return true
end

local function pushMonster(id, x, y)
    Gen.monsters[#Gen.monsters + 1] = { id = id, x = x + 0.5, y = y + 0.5 }
end

local function tryPlaceMonsterAt(id, x, y, spawnX, spawnY)
    if not isOpen(x, y) then return false end
    local dx, dy = x + 0.5 - spawnX, y + 0.5 - spawnY
    if dx * dx + dy * dy < SPAWN_PAD then return false end
    pushMonster(id, x, y)
    return true
end

local function findSpawnCell(salt, spawnX, spawnY, avoidX, avoidY, avoidR2)
    local seed = Gen.seed
    for tries = 1, 40 do
        local x = hash(salt + tries, 3, seed) % (MAP - 4) + 2
        local y = hash(salt + tries, 9, seed + 11) % (MAP - 4) + 2
        if isOpen(x, y) then
            local dx, dy = x + 0.5 - spawnX, y + 0.5 - spawnY
            if dx * dx + dy * dy >= SPAWN_PAD then
                local ok = true
                if avoidX then
                    local ax, ay = x + 0.5 - avoidX, y + 0.5 - avoidY
                    if ax * ax + ay * ay < avoidR2 then ok = false end
                end
                if ok then return x, y end
            end
        end
    end
end

local function nearestRoom(rooms, tx, ty)
    local best, bestD
    for i = 1, #rooms do
        local r = rooms[i]
        local dx, dy = r.cx - tx, r.cy - ty
        local d = dx * dx + dy * dy
        if not bestD or d < bestD then
            best, bestD = r, d
        end
    end
    return best
end

local function farthestRoom(rooms, tx, ty)
    local best, bestD
    for i = 1, #rooms do
        local r = rooms[i]
        local dx, dy = r.cx - tx, r.cy - ty
        local d = dx * dx + dy * dy
        if not bestD or d > bestD then
            best, bestD = r, d
        end
    end
    return best
end

local function assignRoomKinds(rooms, sx, sy, seed)
    local spawnRoom = nearestRoom(rooms, sx, sy)
    if spawnRoom then spawnRoom.kind = "npc" end

    -- 三间尽量分散的普通 Boss 装置房（全图各一种仅一间）
    local picks = {}
    for slot = 1, 3 do
        local best, bestScore
        for i = 1, #rooms do
            local r = rooms[i]
            if r.kind == "monster" and r ~= spawnRoom then
                local dx, dy = r.cx - sx, r.cy - sy
                local score = dx * dx + dy * dy
                for p = 1, #picks do
                    local ox, oy = picks[p].cx - r.cx, picks[p].cy - r.cy
                    local d2 = ox * ox + oy * oy
                    if d2 < score then score = d2 end
                end
                if not bestScore or score > bestScore then
                    best, bestScore = r, score
                end
            end
        end
        if best then
            best.kind = "boss"
            best.bossSlot = slot
            picks[#picks + 1] = best
        end
    end

    for i = 1, #rooms do
        local r = rooms[i]
        if r.kind == "monster" then
            local dx, dy = r.cx - sx, r.cy - sy
            if dx * dx + dy * dy < SPAWN_PAD * 2.5 then
                r.kind = "npc"
            else
                local roll = hash(i, 41, seed) % 100
                -- NPC / 商人房更稀；机关略少；其余怪物房
                if roll < 4 then
                    r.kind = "npc"
                elseif roll < 18 then
                    r.kind = "mech"
                else
                    r.kind = "monster"
                end
            end
        end
    end
end

local MECH_KEYS = { "search", "chest", "mechanism" }

-- 高级怪：高血或高攻，一房只刷这一种
local function isEliteEnemy(def)
    if not def or not def.combat then return false end
    local c = def.combat
    return (c.hp or 1) >= 5 or (c.atk or 1) >= 3
end

-- 每房 1~2 种；抽到高级怪则强制单种类
local function pickRoomEnemySet(salt)
    local types = enemyTypesForScene()
    if #types == 0 then return {} end
    local a = pickEnemy(salt) or types[1 + hash(salt, 1, Gen.seed) % #types]
    if isEliteEnemy(a) then
        return { a }
    end
    local two = hash(salt, 3, Gen.seed) % 100 < 55
    if not two then
        return { a }
    end
    local b
    for g = 0, 10 do
        b = pickEnemy(salt + 19 + g * 7)
        if b and b.id ~= a.id and not isEliteEnemy(b) then
            return { a, b }
        end
    end
    return { a }
end

local function fillMonsterRoom(r, spawnX, spawnY, salt)
    local set = pickRoomEnemySet(salt)
    if #set == 0 then return 0 end
    r.enemyIds = {}
    for i = 1, #set do
        r.enemyIds[i] = set[i].id
    end
    local cand = {}
    local stride = MON_FILL_STRIDE
    for yy = r.y, r.y + r.h - 1 do
        for xx = r.x, r.x + r.w - 1 do
            local edge = xx == r.x or yy == r.y
                or xx == r.x + r.w - 1 or yy == r.y + r.h - 1
            local place = false
            if edge then
                place = ((xx + yy + salt) % 3) == 0
            else
                place = ((xx + yy) % stride) == 0
            end
            if place and isOpen(xx, yy) then
                cand[#cand + 1] = { x = xx, y = yy }
            end
        end
    end
    for i = #cand, 2, -1 do
        local j = 1 + hash(salt, i, Gen.seed) % i
        cand[i], cand[j] = cand[j], cand[i]
    end
    local n = 0
    local lim = math.min(MAX_ROOM_MONSTERS, #cand)
    for i = 1, lim do
        local def = set[1 + ((cand[i].x + cand[i].y + salt) % #set)]
        if tryPlaceMonsterAt(def.id, cand[i].x, cand[i].y, spawnX, spawnY) then
            n = n + 1
        end
    end
    return n
end

local function fillNpcRoom(r, salt, forceCarter)
    local key
    if forceCarter then
        key = "carter"
    else
        -- 多数 NPC 房空置；商人/马车夫极少
        local roll = hash(salt, 7, Gen.seed) % 100
        if roll < 55 then
            return false
        elseif roll < 80 then
            key = "smith"
        elseif roll < 90 then
            key = "shop"
        elseif roll < 96 then
            key = "peddler"
        else
            key = "carter"
        end
    end
    local def = Data.entities.byKey[key] or Data.entities.byKey.carter
    if not def then return false end
    local x = r.cx
    local y = r.cy
    if not isOpen(x, y) then
        x, y = findOpenNear(r.cx, r.cy, 4)
    end
    if x then return pushNpc(x, y, def.id) end
    return false
end

local function fillMechRoom(r, salt)
    local n = 1 + hash(salt, 5, Gen.seed) % 2
    local placed = 0
    for i = 1, n do
        local key = MECH_KEYS[1 + hash(salt + i, 11, Gen.seed) % #MECH_KEYS]
        local def = Data.entities.byKey[key]
        if def then
            local ox = r.x + hash(salt + i, 13, Gen.seed) % r.w
            local oy = r.y + hash(salt + i, 17, Gen.seed) % r.h
            if pushNpc(ox, oy, def.id) then placed = placed + 1 end
        end
    end
    return placed
end

local function fillBossRoom(r, slot, siteName)
    local def = Data.entities.byKey.boss_device
    if not def then return false end
    local x, y = r.cx, r.cy
    if not isOpen(x, y) then
        x, y = findOpenNear(r.cx, r.cy, 4)
    end
    if not x then return false end
    if not placeEntityCell(x, y, def.id) then return false end
    Gen.npcs[#Gen.npcs + 1] = {
        id = def.id, x = x + 0.5, y = y + 0.5,
        name = siteName or def.name,
        slot = slot or 1,
        role = "boss_device",
    }
    return true
end

-- 清完 3 普通 Boss 后：有概率在远处刷主座装置（全图仅一）
function Gen.tryPlaceMainBossDevice()
    if Gen.mainBossPlaced then return false end
    local def = Data.entities.byKey.boss_main_device
    if not def then return false end
    local rooms = Gen.rooms or {}
    local best = farthestRoom(rooms, math.floor(Gen.spawnX), math.floor(Gen.spawnY))
    if not best then return false end
    local x, y = best.cx, best.cy
    if not isOpen(x, y) then
        x, y = findOpenNear(best.cx, best.cy, 6)
    end
    if not x then return false end
    if getRaw(x, y) ~= 0 and getRaw(x, y) ~= 1 then
        -- 已有实体则找空地
        x, y = findOpenNear(best.cx, best.cy, 10)
        if not x then return false end
    end
    if not placeEntityCell(x, y, def.id) then return false end
    Gen.npcs[#Gen.npcs + 1] = {
        id = def.id, x = x + 0.5, y = y + 0.5,
        name = "主座装置",
        slot = "main",
        role = "boss_main",
    }
    Gen.mainBossPlaced = true
    return true
end

-- 按矩形类型固定刷：怪房密布、NPC/机关/Boss 各司其职
local function placeSpawns(depth, rooms)
    Gen.npcs, Gen.monsters = {}, {}
    Gen.mainBossPlaced = false
    local spawnX, spawnY = Gen.spawnX, Gen.spawnY
    local sx, sy = math.floor(spawnX), math.floor(spawnY)
    local seed = Gen.seed
    rooms = rooms or Gen.rooms or {}
    assignRoomKinds(rooms, sx, sy, seed)

    local names = Data.bossSiteNames(Gen.sceneKey)
    local monN = 0
    local spawnRoom = nearestRoom(rooms, sx, sy)
    for i = 1, #rooms do
        local r = rooms[i]
        if r.kind == "monster" then
            monN = monN + fillMonsterRoom(r, spawnX, spawnY, i * 31 + depth)
        elseif r.kind == "npc" then
            fillNpcRoom(r, i * 19, r == spawnRoom)
        elseif r.kind == "mech" then
            fillMechRoom(r, i * 23)
        elseif r.kind == "boss" then
            local slot = r.bossSlot or 1
            fillBossRoom(r, slot, names[slot] or ("boss" .. slot))
        end
    end

    -- 出生点旁保证马车夫（仍仅此一处保底）
    if spawnRoom then
        local hasCarter = false
        for i = 1, #Gen.npcs do
            local n = Gen.npcs[i]
            if roomContains(spawnRoom, math.floor(n.x), math.floor(n.y)) then
                local def = Data.entities.byId[n.id]
                if def and def.key == "carter" then hasCarter = true; break end
            end
        end
        if not hasCarter then
            local cx, cy = findOpenNear(sx + 1, sy, 6)
            if cx then pushNpc(cx, cy, NPC_ID) end
        end
    end

    Gen.monTarget = monN
    Gen.rooms = rooms
end

function Gen.clear()
    Gen.cells, Gen.npcs, Gen.monsters, Gen.rooms = nil, {}, {}, {}
    Gen.seed, Gen.depth = 0, 1
    Gen.monTarget = 0
    Gen.liveCount = 0
    Gen.mainBossPlaced = false
    poolCacheKey, poolCache, poolTotal = nil, nil, nil
    enemyTypesCacheKey, enemyTypesCache = nil, nil
end

function Gen.begin(sceneKey, depth)
    Gen.clear()
    Gen.sceneKey = sceneKey or "forest"
    Gen.depth = math.max(1, depth or 1)
    Gen.seed = love.math.random(1, 2 ^ 30)
    local seed = Gen.seed
    local cells = {}
    for i = 1, MAP2 do cells[i] = 1 end
    Gen.cells = cells

    local sx, sy = 16, 16
    local rooms = buildTypedRooms(seed)
    clearSpawnPad(sx, sy, 3)
    ensureConnected(sx, sy)
    -- 长廊打断后再补出口，避免口袋房
    breakLongRuns()
    ensureConnected(sx, sy)
    for i = 1, #rooms do
        local r = rooms[i]
        local guard = 0
        while countRoomExits(r) < 2 and guard < 6 do
            local sides = { "n", "e", "s", "w" }
            punchExit(r, sides[1 + hash(i, guard + 21, seed) % 4], i * 29 + guard, seed)
            guard = guard + 1
        end
    end
    clearSpawnPad(sx, sy, 3)

    Gen.spawnX, Gen.spawnY = sx + 0.5, sy + 0.5
    Gen.rooms = rooms
    placeSpawns(Gen.depth, rooms)
    Gen.liveCount = #Gen.monsters
    return Gen.spawnX, Gen.spawnY, 0
end

function Gen.getCellXY(x, y)
    if x < 0 or y < 0 or x >= MAP or y >= MAP then return 1 end
    return Gen.cells[y * MAP + x + 1] or 1
end

function Gen.getCell(wx, wy)
    return Gen.getCellXY(math.floor(wx), math.floor(wy))
end

function Gen.setCell(wx, wy, v)
    local x, y = math.floor(wx), math.floor(wy)
    if not inBounds(x, y) then return end
    local old = getRaw(x, y)
    setRaw(x, y, v)
    if old ~= 0 and old ~= 1 then
        local list, w = Gen.npcs, 0
        for i = 1, #list do
            local n = list[i]
            if math.floor(n.x) ~= x or math.floor(n.y) ~= y then
                w = w + 1
                list[w] = n
            end
        end
        for i = w + 1, #list do list[i] = nil end
    end
    if v ~= 0 and v ~= 1 then
        Gen.npcs[#Gen.npcs + 1] = { id = v, x = x + 0.5, y = y + 0.5 }
    end
end

function Gen.npcList()
    return Gen.npcs
end

function Gen.monstersNear(px, py, radius)
    local r2 = radius * radius
    local list, n = nearMonBuf, 0
    local src = Gen.monsters
    for i = 1, #src do
        local m = src[i]
        local dx, dy = m.x - px, m.y - py
        if dx * dx + dy * dy <= r2 then
            n = n + 1
            local slot = list[n]
            if not slot then slot = {}; list[n] = slot end
            slot.x, slot.y, slot.sx, slot.sy, slot.id = m.x, m.y, m.x, m.y, m.id
        end
    end
    for i = n + 1, #list do list[i] = nil end
    return list
end

-- 存活过少时在怪物房内按该房种类补刷
function Gen.replenishMonsters(px, py, need)
    need = math.max(0, math.floor(need or 0))
    if need <= 0 then return 0 end
    local types = enemyTypesForScene()
    if #types == 0 then return 0 end
    local rooms = Gen.rooms or {}
    local spawnX, spawnY = Gen.spawnX, Gen.spawnY
    local avoidR2 = 16 * 16
    local added, salt = 0, (#Gen.monsters + 1) * 13
    local tries = 0
    while added < need and tries < need * 40 do
        tries = tries + 1
        local r = rooms[1 + hash(salt + tries, 3, Gen.seed) % math.max(1, #rooms)]
        if r and r.kind == "monster" then
            local ids = r.enemyIds
            local id
            if ids and #ids > 0 then
                id = ids[1 + hash(salt + tries, 5, Gen.seed) % #ids]
            else
                id = types[1 + hash(salt + tries, 5, Gen.seed) % #types].id
            end
            local xx = r.x + hash(salt + tries, 7, Gen.seed) % r.w
            local yy = r.y + hash(salt + tries, 9, Gen.seed) % r.h
            local ax, ay = xx + 0.5 - px, yy + 0.5 - py
            if ax * ax + ay * ay >= avoidR2 then
                if tryPlaceMonsterAt(id, xx, yy, spawnX, spawnY) then
                    added = added + 1
                end
            end
        elseif #rooms == 0 then
            local x, y = findSpawnCell(salt + tries * 17, spawnX, spawnY, px, py, avoidR2)
            if x then
                local def = types[1 + hash(salt + tries, 11, Gen.seed) % #types]
                if tryPlaceMonsterAt(def.id, x, y, spawnX, spawnY) then
                    added = added + 1
                end
            end
        end
    end
    return added
end

function Gen.replenishThreshold()
    return math.max(120, math.floor((Gen.monTarget or 0) * REPLENISH_FRAC))
end

function Gen.replenishBatch()
    return REPLENISH_BATCH
end

function Gen.onMonsterKilled()
    Gen.liveCount = math.max(0, (Gen.liveCount or 0) - 1)
end

-- 存活过少则补刷；返回新增数量
function Gen.maybeReplenish(px, py)
    local th = Gen.replenishThreshold()
    local live = Gen.liveCount or 0
    if live >= th then return 0 end
    local cap = Gen.monTarget or live
    local need = math.min(REPLENISH_BATCH, math.max(0, cap - live))
    if need <= 0 then need = REPLENISH_BATCH end
    local n = Gen.replenishMonsters(px, py, need)
    Gen.liveCount = live + n
    return n
end

return Gen
