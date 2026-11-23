local U = {}
local EXTRA = { space = " ", minus = "-", period = "." }
local imeReady = false

U.RESOLUTIONS = {
    {1920, 1080, "1920x1080"},
    {1280, 720, "1280x720"},
    {640, 360, "640x360"},
}

function U.pickResolution()
    local dw, dh = love.window.getDesktopDimensions()
    local maxW, maxH = dw - 32, dh - 96
    for i = 1, #U.RESOLUTIONS do
        local r = U.RESOLUTIONS[i]
        if r[1] <= maxW and r[2] <= maxH then return r end
    end
    return U.RESOLUTIONS[#U.RESOLUTIONS]
end

function U.applyResolution(r)
    r = r or U.pickResolution()
    love.window.setMode(r[1], r[2], { fullscreen = false, resizable = false })
    require("fonts").reload()
    return r
end

function U.setFullscreen(on)
    if on == nil then on = not love.window.getFullscreen() end
    if on then
        love.window.setFullscreen(true, "desktop")
    else
        U.applyResolution()
        return on
    end
    require("fonts").reload()
    return on
end

function U.edit(buf, key)
    if key == "backspace" then return buf:sub(1, -2) end
    local ch = (#key == 1 and key) or EXTRA[key]
    return ch and (buf .. ch) or buf
end

function U.vol()
    return math.floor(love.audio.getVolume() * 100 + 0.5)
end

-- Windows：切美式英语并关闭中文 IME
function U.toEnglish()
    if love.system.getOS() ~= "Windows" then return end
    pcall(function()
        local ffi = require("ffi")
        if not imeReady then
            ffi.cdef[[
                typedef void* HWND; typedef void* HKL; typedef void* HIMC;
                HWND GetForegroundWindow();
                HKL  LoadKeyboardLayoutA(const char*, unsigned int);
                HKL  ActivateKeyboardLayout(HKL, unsigned int);
                HIMC ImmGetContext(HWND);
                int  ImmSetOpenStatus(HIMC, int);
                int  ImmReleaseContext(HWND, HIMC);
            ]]
            imeReady = true
        end
        local u, i = ffi.load("user32"), ffi.load("imm32")
        local hwnd = u.GetForegroundWindow()
        u.ActivateKeyboardLayout(u.LoadKeyboardLayoutA("00000409", 1), 0)
        local himc = i.ImmGetContext(hwnd)
        if himc ~= nil then
            i.ImmSetOpenStatus(himc, 0)
            i.ImmReleaseContext(hwnd, himc)
        end
    end)
end

return U
