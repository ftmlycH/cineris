local Cmd = require("cmd")
local Dialog = require("dialog")
local Fonts = require("fonts")
local World = require("world")
local Ray = require("raycasting")
local U = require("util")
local Cursor = require("cursor")
local Assets = require("assets")

local mode = "menu"
local menuBg
local fade = { on = false, phase = "out", t = 0, dur = 0.45, after = nil }

local INTRO = {
    "得到Ave Mujica乐队的海外限量版演出的票时，我无疑是兴奋的。",
    "可前行的飞机却发生了空难，我失去了记忆。",
    "再次醒来时，我已身处这座古堡之中，",
    "此时，眼前的却是那似曾相识的...人偶?",
    "",
    "按任意键继续",
}

local function resetUi()
    Cmd.close(); Dialog.close(); U.toEnglish()
    love.keyboard.setTextInput(false)
    World.muteCombatInput()
end

local function go(to)
    mode, fade.on = to, false
    if to == "game" then
        World.clearSave()
        World.clearSession()
        World.load("main")
        Cursor.useSword()
    else
        World.clearSession()
        Cursor.useDefault()
    end
    resetUi()
end

local function startIntro()
    World.clearSave()
    World.clearSession()
    World.load("main")
    mode, fade.on = "intro", false
    Cursor.useDefault()
    resetUi()
end

local function finishIntro()
    mode = "game"
    Cursor.useSword()
end

local function continueGame()
    if not World.applySave() then return false end
    mode, fade.on = "game", false
    Cursor.useSword()
    resetUi()
    return true
end

local function playing()
    return mode == "game" and not Cmd.active() and not Dialog.active()
        and not fade.on and not World.inDeath()
end

local function startFade(afterFn)
    fade.on, fade.phase, fade.t, fade.after = true, "out", 0, afterFn
    resetUi()
end

function love.load()
    U.setFullscreen(true)
    love.graphics.setLineStyle("rough")
    love.keyboard.setTextInput(false)
    Fonts.load()
    Cmd.init()
    Cursor.load()
    Cursor.useDefault()
    menuBg = Assets.image("resources/menu_background.png")
end

function love.focus(ok)
    if ok then
        U.toEnglish()
        love.keyboard.setTextInput(false)
        World.muteCombatInput()
    else
        World.muteCombatInput()
    end
end

function love.update(dt)
    if fade.on then
        fade.t = fade.t + dt
        if fade.phase == "out" and fade.t >= fade.dur then
            fade.phase, fade.t = "hold", 0
            if fade.after then fade.after(); fade.after = nil end
        elseif fade.phase == "hold" and fade.t >= 0.12 then
            fade.phase, fade.t = "in", 0
        elseif fade.phase == "in" and fade.t >= fade.dur then
            fade.on = false
            World.muteCombatInput()
        end
        return
    end

    if mode == "game" and World.inDeath() then
        World.updateDeath(dt)
        return
    end

    if not playing() then
        World.muteCombatInput()
        -- Cmd / 对话打开时完全暂停战斗（含敌人 AI）
        return
    end

    if not Cursor.inCombat() then
        Cursor.useSword()
    end

    local px, py, pa = World.px, World.py, World.pa
    if love.keyboard.isDown("a") or love.keyboard.isDown("left") then pa = pa - 2 * dt end
    if love.keyboard.isDown("d") or love.keyboard.isDown("right") then pa = pa + 2 * dt end
    local spd = World.moveSpd or 2.5
    local step = (love.keyboard.isDown("w") and spd or love.keyboard.isDown("s") and -spd or 0) * dt
    local nx, ny = px + math.cos(pa) * step, py + math.sin(pa) * step
    World.px, World.py = Ray.slide(px, py, nx, ny)
    World.pa = pa
    World.separateFromEnemies()
    World.tickCombatKeys()
    local dead, killer = World.updateEnemies(dt)
    if dead then World.beginDeath(killer) end
end

function love.draw()
    if mode == "menu" then
        local W, H = love.graphics.getDimensions()
        love.graphics.setColor(1, 1, 1)
        if menuBg then
            love.graphics.draw(menuBg, 0, 0, 0, W / menuBg:getWidth(), H / menuBg:getHeight())
        else
            love.graphics.setColor(0.22, 0.22, 0.24)
            love.graphics.rectangle("fill", 0, 0, W, H)
        end
        love.graphics.setFont(Fonts.title)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("Cineris", 0, H * 0.3, W * 0.15, "center", 0, 3)
        love.graphics.printf("from bangdream ave mujica", 0, H * 0.5, W * 0.75, "center", 0, 0.8)
        love.graphics.printf("按backslash键打开命令行，输入help获取帮助", 0, H * 0.85, W * 0.85, "center", 0, 0.6)
    elseif mode == "intro" then
        local W, H = love.graphics.getDimensions()
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("fill", 0, 0, W, H)
        love.graphics.setFont(Fonts.ui)
        local lh = Fonts.ui:getHeight() * 1.35
        local total = #INTRO * lh
        local y = (H - total) * 0.42
        local pad = Fonts.px(48)
        for i = 1, #INTRO do
            local line = INTRO[i]
            if line == "按任意键继续" then
                love.graphics.setColor(0.7, 0.7, 0.72)
            else
                love.graphics.setColor(1, 1, 1)
            end
            love.graphics.printf(line, pad, y + (i - 1) * lh, W - pad * 2, "center")
        end
    else
        if World.inDeath() then
            World.drawDeath()
        else
            World.draw()
            if Cmd.showMap then Ray.drawMiniMap(World.px, World.py, World.pa) end
        end
    end
    if mode ~= "intro" and not World.inDeath() then
        Cmd.draw()
        Dialog.draw()
    end
    -- 剑准星始终最上层（对话/命令行打开时不画）
    if mode == "game" and playing() and not World.inDeath() then
        World.drawCrosshair()
    end
    if fade.on then
        local a = fade.phase == "hold" and 1
            or fade.phase == "out" and math.min(1, fade.t / fade.dur)
            or (1 - math.min(1, fade.t / fade.dur))
        local W, H = love.graphics.getDimensions()
        love.graphics.setColor(0, 0, 0, a)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end
end

function love.resize() Fonts.reload() end

function love.keypressed(key, scancode, isrepeat)
    if fade.on then return end
    if World.inDeath() then return end
    if mode == "intro" then
        if not isrepeat then finishIntro() end
        return
    end

    if Dialog.active() then
        local act, dest = Dialog.keypressed(key)
        if act == "save" then
            World.writeSave()
            resetUi()
        elseif act == "boss_enter" then
            local door = World._doorNpc
            startFade(function()
                if door and (door.role == "boss_device" or door.role == "boss_main") then
                    World.tryOpenBossDevice(door)
                else
                    World.tryOpenBossDoor(door)
                end
                Cursor.useSword()
            end)
            resetUi()
        elseif act == "boss_exit" then
            if not World.bossCleared then
                World.tryExitBoss()
                resetUi()
            else
                startFade(function()
                    World.tryExitBoss()
                    Cursor.useSword()
                end)
                resetUi()
            end

        elseif act == "boost_hp" or act == "boost_atk" or act == "boost_spd" then
            local kind = act:match("^boost_(%w+)$")
            World.tryBoost(kind)
            local npc = World.findNpc("boost")
            if npc then Dialog.openBoost(npc, World.boostInfo())
            else resetUi() end
        elseif act == "buy" then
            -- dest 此处为选项表 { item, pay }
            if dest and dest.item then
                World.buyItem(dest.item, dest.pay)
            end
            local npc = World._shopNpc
            if npc then Dialog.openShop(npc, World.shopPayload(npc))
            else resetUi() end
        elseif act == "goto" then
            -- dest: { key, depth, fare } 或旧式字符串 key
            local target = dest
            if type(dest) == "string" then target = { key = dest } end
            if target and target.key then
                local fare = World.estimateFare(target)
                if fare > 0 and not World.canPayAsh(fare) then
                    World.tryTravel(target) -- 提示火烬不足
                    resetUi()
                else
                    startFade(function()
                        World.tryTravel(target)
                        Cursor.useSword()
                    end)
                    resetUi()
                end
            else
                resetUi()
            end
        elseif act == "abyss_down" then
            World.descendAbyss()
            resetUi()
        elseif act == "search_dig" then
            World.trySearch(World._searchNpc)
            resetUi()
        elseif act == "close" then
            resetUi()
        end
        return
    end

    local r, a = Cmd.keypressed(key, {
        scene = mode,
        nearby = World.nearby,
        pos = function() return World.px, World.py, World.key end,
        isPuppet = World.isPuppet,
        hasSave = World.hasSave,
        bag = World.invText,
        usable = World.usableItems,
        invCount = World.invCount,
    })

    if r == "new" then startIntro()
    elseif r == "continue" then continueGame()
    elseif r == "returnmenu" then go("menu")
    elseif r == "exit" then love.event.quit()
    elseif r == "use" then
        World.useItem(a)
    elseif r == "bag" then
        World.notify("背包：" .. World.invText())
    elseif r == "char" then
        Cmd.openChar(World.charSheetLines())
    elseif r == "aim" then
        World.showAim = not World.showAim
        World.notify(World.showAim and "判定区：开" or "判定区：关")
    elseif r == "search" then
        local near = World.nearby("search")
        if #near == 0 then near = World.nearby("chest") end
        if #near == 0 then near = World.nearby("mech") end
        if #near == 0 then
            World.notify("附近没有可搜索之物")
        else
            World.trySearch(near[1])
        end
    elseif r == "testarea" then
        startFade(function()
            mode = "game"
            World.enterTestArea()
            Cursor.useSword()
        end)
    elseif r == "dialog" then
        Cmd.close()
        if a.role == "travel" then Dialog.openTravel(a, World.destinations())
        elseif a.role == "save" then
            Dialog.openJournal(a, World.ash, World.ether, {
                maxDepth = World.maxDepth,
                kills = World.kills,
                bestScore = math.max(World.bestScore or 0, World.calcScore()),
                deaths = World.recentDeaths(),
            })
        elseif a.role == "boost" then Dialog.openBoost(a, World.boostInfo())
        elseif a.role == "shop" then
            World._shopNpc = a
            Dialog.openShop(a, World.shopPayload(a))
        elseif a.role == "door" then
            World._doorNpc = a
            Dialog.openDoor(a, World.invCount("key"))
        elseif a.role == "boss_device" or a.role == "boss_main" then
            World._doorNpc = a
            Dialog.openBossDevice(a, World.floorBossClears)
        elseif a.role == "exit" then
            local isMain = World.bossReturn and World.bossReturn.slot == "main"
            Dialog.openExit(a, World.bossCleared, isMain)
        elseif a.role == "abyss" then
            World._abyssNpc = a
            Dialog.openAbyss(a, World.depth or 1)
        elseif a.role == "search" or a.role == "chest" or a.role == "mech" then
            World._searchNpc = a
            Dialog.openSearchable(a)
        elseif a.role == "doll" then Dialog.openChat(a) end
        U.toEnglish()
    elseif r == "touch" then
        startFade(function()
            World.beginPuppet(a)
            World.load("main2", { keepPuppet = true })
            Cursor.useSword()
        end)
    elseif r == "wakeup" then
        startFade(function()
            World.endPuppet()
            World.load("main")
            Cursor.useSword()
        end)
    elseif r then return
    elseif mode == "menu" and key == "escape" then love.event.quit()
    elseif playing() and not isrepeat then
        local sc = scancode or key
        if sc == "slash" or sc == "/" or sc == "kp/" or sc == "kpdivide"
            or key == "/" or key == "slash" then
            World.combatKey("/", true)
        elseif sc == "lctrl" or sc == "rctrl" or key == "lctrl" or key == "rctrl" then
            World.combatKey(sc == "rctrl" and "rctrl" or "lctrl", true)
        elseif key == "y" then
            World.tapY()
        end
    end
end

function love.keyreleased(key, scancode)
    if not playing() then return end
    local sc = scancode or key
    if sc == "lctrl" or sc == "rctrl" or key == "lctrl" or key == "rctrl" then
        World.combatKey(sc == "rctrl" and "rctrl" or "lctrl", false)
    elseif sc == "slash" or sc == "/" or sc == "kp/" or sc == "kpdivide"
        or key == "/" or key == "slash" then
        World.combatKey("/", false)
    end
end

function love.quit() World.clearSession() end
