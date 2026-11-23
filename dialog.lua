-- 对话面板

local Fonts = require("fonts")
local U = require("util")
local Dialog = { on = false, buf = "", text = "", options = {} }

function Dialog.active() return Dialog.on end

function Dialog.close()
    Dialog.on, Dialog.buf, Dialog.text, Dialog.options = false, "", "", {}
end

function Dialog.openTravel(npc, destinations)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    local lines = {
        npc.name .. "：可送你去驿站或其它地界的第 1 层。",
        "（层数加深需在本层击败领主，经归途前进）",
        "（野外逃离回城需付逃离费，随层数上涨）",
    }
    if #destinations == 0 then
        lines[#lines + 1] = "（暂无其它去处）"
    else
        for i = 1, #destinations do
            local d = destinations[i]
            Dialog.options[i] = d
            lines[#lines + 1] = i .. ". " .. d.title
        end
    end
    lines[#lines + 1] = "输入编号前往，Esc 离开"
    Dialog.text = table.concat(lines, "\n")
end

function Dialog.openChat(npc)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.text = table.concat({
        npc.name .. "：",
        "……",
        "",
        "（对话内容待填写）",
        "Esc 离开",
    }, "\n")
end

function Dialog.openJournal(npc, ash, ether, meta)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.options[1] = { act = "save" }
    meta = meta or {}
    local lines = {
        npc.name .. "：只在此落笔。",
        "火烬：" .. tostring(ash or 0) .. "（战死重罚并摔碎部分伤药/牛肉）",
        "以太：" .. tostring(ether or 0) .. "（Boss 掉落，死亡不丢）",
        "循环：三处装置 → 主座 → 更深（第10层为里程碑）",
        "最深：" .. tostring(meta.maxDepth or 1)
            .. "  击杀：" .. tostring(meta.kills or 0)
            .. "  最佳得分：" .. tostring(meta.bestScore or 0),
        "1. 存档（火烬 / 以太 / 探索层 / 强化 / 背包）",
    }
    local deaths = meta.deaths or {}
    if #deaths > 0 then
        lines[#lines + 1] = "── 近期陨落 ──"
        for i = 1, math.min(3, #deaths) do
            lines[#lines + 1] = deaths[i]
        end
    end
    lines[#lines + 1] = "Esc 离开"
    Dialog.text = table.concat(lines, "\n")
end

function Dialog.openAbyss(npc, depth)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.options[1] = { act = "close" }
    Dialog.text = table.concat({
        npc.name .. "：裂隙已凝滞。",
        "当前第 " .. tostring(depth or 1) .. " 层。深入请击败领主后走归途。",
        "1. 离开",
        "Esc 离开",
    }, "\n")
end

-- 搜索点 / 宝箱 / 机关：同一交互，文案按 role 区分
local SEARCHABLE = {
    search = {
        line1 = "地面有翻动过的痕迹。",
        line2 = "搜索可能发现火烬、伤药、牛肉，偶有钥匙；也可能惊动怪物。",
        verb = "仔细搜索",
    },
    chest = {
        line1 = "锈带微亮，箱盖并未锁死。",
        line2 = "打开多半有物资，偶尔也会惊动埋伏。",
        verb = "打开宝箱",
    },
    mech = {
        line1 = "齿轮与拉杆卡在墙缝里。",
        line2 = "拨动可能吐出零碎，也可能一无所获或惊动怪物。",
        verb = "拨动机关",
    },
}

function Dialog.openSearchable(npc)
    local spec = SEARCHABLE[npc and npc.role] or SEARCHABLE.search
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.options[1] = { act = "search_dig" }
    Dialog.text = table.concat({
        npc.name .. "：" .. spec.line1,
        spec.line2,
        "1. " .. spec.verb,
        "Esc 离开",
    }, "\n")
end

function Dialog.openSearch(npc) return Dialog.openSearchable(npc) end
function Dialog.openChest(npc) return Dialog.openSearchable(npc) end
function Dialog.openMech(npc) return Dialog.openSearchable(npc) end

function Dialog.openDoor(npc, keys)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.options[1] = { act = "boss_enter" }
    Dialog.text = table.concat({
        npc.name .. "：沉重的封印纹路在门扉上游走。",
        "持有钥匙：" .. tostring(keys or 0),
        "1. 使用钥匙开启（进入 Boss 战）",
        "Esc 离开",
    }, "\n")
end

function Dialog.openBossDevice(npc, clears)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.options[1] = { act = "boss_enter" }
    local slot = npc and npc.slot
    local done = type(slot) == "number" and clears and clears[slot]
    local lines
    if npc and npc.role == "boss_main" then
        lines = {
            (npc.name or "主座装置") .. "：深渊的脉搏在此汇聚。",
            "需先平息三处普通领主之地，启封时亦可能沉寂。",
            done and "（已不可再用）" or "1. 尝试启封主座",
            "Esc 离开",
        }
    else
        lines = {
            (npc.name or "Boss装置") .. "：此地镇压着一方领主。",
            done and "此处已平息。" or "1. 激活装置（进入领主战）",
            "Esc 离开",
        }
    end
    if done then Dialog.options = {} end
    Dialog.text = table.concat(lines, "\n")
end

function Dialog.openExit(npc, cleared, isMain)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    Dialog.options[1] = { act = "boss_exit" }
    Dialog.text = table.concat({
        npc.name .. "：归途之门微微颤动。",
        cleared
            and (isMain and "主座已陨落，可前往下一层。" or "领主已陨落，可返回本层。")
            or "尚未击败领主。",
        cleared and (isMain and "1. 前往下一层" or "1. 返回本层") or "1. 离开",
        "Esc 离开",
    }, "\n")
end

function Dialog.openShop(npc, shop)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    shop = shop or {}
    local lines = {
        npc.name .. "：看看有什么用得上的。",
        "火烬：" .. tostring(shop.wallet or 0),
        "背包：" .. (shop.bag or "（空）"),
    }
    local goods = shop.lines or {}
    for i = 1, #goods do
        local g = goods[i]
        Dialog.options[i] = { act = "buy", item = g.key, pay = shop.pay }
        lines[#lines + 1] = string.format(
            "%d. %s  %d火烬（持有%d）", i, g.name, g.price, g.owned or 0
        )
    end
    lines[#lines + 1] = "输入编号购买，Esc 离开"
    Dialog.text = table.concat(lines, "\n")
end

function Dialog.openBoost(npc, info)
    Dialog.on, Dialog.buf, Dialog.options = true, "", {}
    info = info or {}
    Dialog.options[1] = { act = "boost_hp" }
    Dialog.options[2] = { act = "boost_atk" }
    Dialog.options[3] = { act = "boost_spd" }
    Dialog.text = table.concat({
        npc.name .. "：以太铸身，代价倍增。",
        "以太：" .. tostring(info.ether or 0) .. "（击败 Boss 获得）",
        string.format("生命 Lv.%d  上限%d  下次%d以太（+2）", info.hpLv or 0, info.maxHp or 0, info.hpCost or 2),
        string.format("攻击 Lv.%d  当前%.2f  下次%d以太（+0.25）", info.atkLv or 0, info.atk or 1, info.atkCost or 2),
        string.format("速度 Lv.%d  当前%.2f  下次%d以太（+0.08）", info.spdLv or 0, info.moveSpd or 2.5, info.spdCost or 2),
        "1. 强化生命上限",
        "2. 强化攻击",
        "3. 强化速度",
        "Esc 离开",
    }, "\n")
end

function Dialog.keypressed(key)
    if not Dialog.on then return end
    if key == "escape" then Dialog.close(); return "close" end
    if key == "return" or key == "kpenter" then
        local opt = Dialog.options[tonumber(Dialog.buf) or 0]
        Dialog.buf = ""
        if not opt then return true end
        Dialog.close()
        if opt.act == "buy" then return "buy", opt end
        if opt.act then return opt.act end
        if opt.key then return "goto", opt end
        return true
    end
    Dialog.buf = U.edit(Dialog.buf, key)
    return true
end

function Dialog.draw()
    if not Dialog.on then return end
    local W, H = love.graphics.getDimensions()
    local pad = Fonts.px(16)
    local boxH = H * 0.42
    love.graphics.setColor(0, 0, 0, 0.72)
    love.graphics.rectangle("fill", 0, H - boxH, W, boxH)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(Fonts.ui)
    love.graphics.printf(Dialog.text, pad, H - boxH + pad, W - pad * 2, "left")
    if Dialog.buf ~= "" then
        love.graphics.printf("> " .. Dialog.buf, pad, H - pad - Fonts.ui:getHeight(), W - pad * 2, "left")
    end
end

return Dialog
