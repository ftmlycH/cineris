-- 贴图缓存（最近邻）

local Assets = {}
local cache = {}

function Assets.image(path)
    if not path then return end
    local img = cache[path]
    if img ~= nil then return img ~= false and img or nil end
    local ok, loaded = pcall(love.graphics.newImage, path)
    if not ok or not loaded then
        cache[path] = false
        return nil
    end
    loaded:setFilter("nearest", "nearest")
    cache[path] = loaded
    return loaded
end

-- bindLook(path) 或 bindLook(ent, sceneKey) → img, iw, ih, aspect
function Assets.bindLook(a, b)
    local path = a
    if type(a) == "table" then
        path = require("data").look(a, b)
    end
    local img = Assets.image(path)
    if not img then return nil, 1, 1, 1 end
    local iw, ih = img:getWidth(), img:getHeight()
    return img, iw, ih, iw / ih
end

function Assets.clear()
    cache = {}
end

return Assets
