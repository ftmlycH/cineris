-- \ 打开指令栏，Enter 执行；完整指令结束后自动关闭

local Fonts = require("fonts")
local U = require("util")

local Cmd = {
    on = false, buf = "", msg = "", await = nil, targets = nil,
    showMap = false, showHelp = false, showChar = false, charLines = nil,
}

local RES = {}
for i, r in ipairs(U.RESOLUTIONS) do RES[tostring(i)] = r end

local HELP_LINES = {
    "指令一览（按 Q 关闭）  支持首字母/缩写",
    "",
    "按backslash键打开指令栏",
    "h  help          打开本说明",
    "s  start         开始游戏",
    "n  new           新游戏（先 start）",
    "co continue      读档（先 start）",
    "r  returnmenu    返回主菜单",
    "q  quit          退出游戏",
    "qc quitcmd       强制关闭指令栏",
    "sw setwindow     设置分辨率",
    "sf setfullwindow 切换全屏 / 窗口",
    "sv setvolume     设置音量",
    "t  talk          与附近NPC对话交互",
    "to touch         触碰人偶",
    "w  wakeup        醒来",
    "m  map           打开小地图",
    "b  bag           查看背包",
    "u  use           使用背包中的消耗品",
    "c  char          角色面板（状态 / 层数 / 得分）",
    "a  aim           开关怪物统一碰撞盒显示",
    "se search        搜索附近的可疑痕迹",
    "ta testarea      进入开发者测试区（全怪 / 无限血）",
    "",
    "操作：WASD 移动 AD/方向键转向  / 攻击  按住Ctrl格挡（有耐力）",
    "目标：三处领主装置 → 主座 → 归途更深",
}

-- 快捷输入：首字母或缩写 → 全名（冲突项用两字母）
local ALIAS = {
    h = "help",
    s = "start",
    n = "new",
    co = "continue",
    cont = "continue",
    r = "returnmenu",
    rm = "returnmenu",
    q = "quit",
    qc = "quitcmd",
    sw = "setwindow",
    sf = "setfullwindow",
    sv = "setvolume",
    t = "talk",
    to = "touch",
    w = "wakeup",
    m = "map",
    b = "bag",
    u = "use",
    c = "char",
    a = "aim",
    se = "search",
    ta = "testarea",
}

local function resolveCmd(raw)
    local cmd = (raw or ""):match("^%s*(%S+)")
    if not cmd then return nil end
    cmd = cmd:lower()
    return ALIAS[cmd] or cmd
end

function Cmd.init()
    love.keyboard.setTextInput(false)
    U.toEnglish()
end

function Cmd.active() return Cmd.on end

function Cmd.close()
    Cmd.on, Cmd.buf, Cmd.msg = false, "", ""
    Cmd.await, Cmd.targets, Cmd.showMap, Cmd.showHelp = nil, nil, false, false
    Cmd.showChar, Cmd.charLines = false, nil
    love.keyboard.setTextInput(false)
    U.toEnglish()
end

local function run(line, ctx)
    local cmd = resolveCmd(line)
    if not cmd then return end

    if Cmd.await == "window" then
        local r = RES[cmd]
        if r then U.applyResolution(r); Cmd.await = nil; Cmd.msg = "window " .. r[3]
        else Cmd.msg = "请输入 1 / 2 / 3" end
        return
    elseif Cmd.await == "volume" then
        local n = tonumber(cmd)
        if n and n >= 0 and n <= 100 then
            love.audio.setVolume(n / 100); Cmd.await = nil; Cmd.msg = "音量 " .. n .. "%"
        else Cmd.msg = "当前音量 " .. U.vol() .. "%，输入 0-100" end
        return
    elseif Cmd.await == "talk" then
        local t = Cmd.targets and Cmd.targets[tonumber(cmd) or 0]
        if t then return "dialog", t end
        Cmd.msg = "无效编号"
        return
    elseif Cmd.await == "touch" then
        local t = Cmd.targets and Cmd.targets[tonumber(cmd) or 0]
        if t then return "touch", t end
        Cmd.msg = "无效编号"
        return
    elseif Cmd.await == "use" then
        local t = Cmd.targets and Cmd.targets[tonumber(cmd) or 0]
        if t then return "use", t.key end
        Cmd.msg = "无效编号"
        return
    end

    if cmd == "quitcmd" then return "quitcmd"
    elseif cmd == "help" then
        Cmd.showHelp = true
        Cmd.msg = "按 Q 关闭说明"
    elseif cmd == "start" then Cmd.await, Cmd.msg = "start", "new/n 或 continue/co？"
    elseif cmd == "new" then
        if Cmd.await ~= "start" then Cmd.msg = "先输入 start/s"; return end
        Cmd.await = nil; return "new"
    elseif cmd == "continue" then
        if Cmd.await ~= "start" then Cmd.msg = "先输入 start/s"; return end
        if not (ctx.hasSave and ctx.hasSave()) then Cmd.msg = "no save found"; return end
        Cmd.await = nil; return "continue"
    elseif cmd == "returnmenu" then
        if ctx.scene ~= "game" then Cmd.msg = "already on menu"; return end
        if Cmd.await == "returnmenu" then Cmd.await = nil; return "returnmenu" end
        Cmd.await, Cmd.msg = "returnmenu", "未保存会丢失，再输入 returnmenu/r 确认回菜单"
    elseif cmd == "quit" then
        if Cmd.await == "quit" then Cmd.await = nil; return "exit" end
        Cmd.await, Cmd.msg = "quit", "未保存会丢失，再输入 quit/q 确认退出"
    elseif cmd == "setwindow" then
        Cmd.await, Cmd.msg = "window", "分辨率 1:1920x1080  2:1280x720  3:640x360"
    elseif cmd == "setfullwindow" then
        local on = U.setFullscreen()
        Cmd.msg = on and "全屏" or "窗口模式"
    elseif cmd == "setvolume" then
        Cmd.await, Cmd.msg = "volume", "当前音量 " .. U.vol() .. "%，输入 0-100"
    elseif cmd == "talk" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中对话"; return end
        local near = ctx.nearby()
        if #near == 0 then Cmd.msg = "附近没有可对话的人"; return end
        Cmd.targets, Cmd.await = near, "talk"
        local p = {}
        for i = 1, #near do p[i] = i .. ":" .. near[i].name .. "(" .. near[i].id .. ")" end
        Cmd.msg = "可对话对象 " .. table.concat(p, "  ")
    elseif cmd == "touch" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中触碰"; return end
        if ctx.isPuppet and ctx.isPuppet() then Cmd.msg = "已在人偶视角中"; return end
        local near = ctx.nearby("doll")
        if #near == 0 then Cmd.msg = "附近没有可触碰的人偶"; return end
        Cmd.targets, Cmd.await = near, "touch"
        local p = {}
        for i = 1, #near do p[i] = i .. ":" .. near[i].name end
        Cmd.msg = "触碰对象 " .. table.concat(p, "  ")
    elseif cmd == "wakeup" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中使用"; return end
        if not (ctx.isPuppet and ctx.isPuppet()) then
            Cmd.msg = "只能在人偶视角下使用 wakeup/w"
            return
        end
        return "wakeup"
    elseif cmd == "map" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中查看地图"; return end
        local x, y, name = ctx.pos()
        Cmd.showMap = true
        Cmd.msg = string.format("位置 %.1f, %.1f  [%s]", x, y, name)
    elseif cmd == "bag" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中查看背包"; return end
        return "bag"
    elseif cmd == "char" or cmd == "status" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中查看"; return end
        return "char"
    elseif cmd == "aim" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中使用"; return end
        return "aim"
    elseif cmd == "search" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中搜索"; return end
        return "search"
    elseif cmd == "use" then
        if ctx.scene ~= "game" then Cmd.msg = "只能在游戏中使用物品"; return end
        local list = ctx.usable and ctx.usable() or {}
        if #list == 0 then Cmd.msg = "没有可使用的物品"; return end
        Cmd.targets, Cmd.await = list, "use"
        local p = {}
        for i = 1, #list do
            local n = ctx.invCount and ctx.invCount(list[i].key) or 0
            p[i] = i .. ":" .. list[i].name .. "[" .. n .. "]"
        end
        Cmd.msg = "使用 " .. table.concat(p, "  ")
    elseif cmd == "testarea" then
        return "testarea"
    else
        Cmd.msg = "未知指令。输入 h 查看帮助"
    end
end

function Cmd.keypressed(key, ctx)
    if not Cmd.on then
        if key == "\\" or key == "backslash" then
            Cmd.on, Cmd.buf, Cmd.msg = true, "", ""
            love.keyboard.setTextInput(false)
            U.toEnglish()
            return true
        end
        return
    end

    if Cmd.showHelp or Cmd.showChar then
        if key == "q" then Cmd.close() end
        return true
    end

    if Cmd.showMap then
        Cmd.close()
        return true
    end

    if key == "return" or key == "kpenter" then
        local r, a = run(Cmd.buf, ctx)
        Cmd.buf = ""
        if not r and (Cmd.await or Cmd.showMap or Cmd.showHelp or Cmd.showChar) then return true end
        Cmd.close()
        return r or true, a
    end

    Cmd.buf = U.edit(Cmd.buf, key)
    return true
end

function Cmd.draw()
    if not Cmd.on then return end
    love.graphics.setFont(Fonts.ui)
    local W, H = love.graphics.getDimensions()
    local lh = Fonts.ui:getHeight()

    if Cmd.showHelp or Cmd.showChar then
        local pad = Fonts.px(24)
        local lines = Cmd.showChar and (Cmd.charLines or {}) or HELP_LINES
        local boxH = (#lines + 1) * lh + pad * 2
        local boxW = math.min(W * 0.78, Fonts.px(620))
        local bx, by = (W - boxW) * 0.5, math.max(Fonts.px(16), (H - boxH) * 0.28)
        love.graphics.setColor(0, 0, 0, 0.78)
        love.graphics.rectangle("fill", bx, by, boxW, boxH)
        love.graphics.setColor(1, 1, 1)
        for i = 1, #lines do
            love.graphics.print(lines[i], bx + pad, by + pad + (i - 1) * lh)
        end
    end

    if Cmd.msg ~= "" then
        love.graphics.setColor(0, 0, 0, 0.65)
        love.graphics.rectangle("fill", 0, H - lh * 2, W, lh)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(Cmd.msg, Fonts.px(2), H - lh * 2)
    end
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 0, H - lh, W, lh)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("\\" .. Cmd.buf, Fonts.px(2), H - lh)
end

function Cmd.openChar(lines)
    Cmd.on, Cmd.buf, Cmd.msg = true, "", "按 Q 关闭"
    Cmd.showChar, Cmd.charLines = true, lines or {}
    love.keyboard.setTextInput(false)
    U.toEnglish()
end

return Cmd
