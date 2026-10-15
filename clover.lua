------------------------------------------------------------
-- Clover Retribution Hub v4 (Matcha Edition)
-- Custom INS-style UI drawn with the Matcha Drawing API.
-- No UI.AddTab: the menu is fully standalone (press P).
--
-- IMPORTANT: this file is pure ASCII on purpose - the Matcha
-- parser chokes on non-ASCII characters in source text.
--
-- Matcha quirks handled:
--   * task.defer/task.delay are no-ops -> task.spawn + wait
--   * error() only prints -> assert for real errors
--   * RunService.Stepped passes only deltaTime
--   * no Instance.new -> everything is Drawing.new
--   * property writes wrapped in pcall
------------------------------------------------------------

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

------------------------------------------------------------
-- UTILS
------------------------------------------------------------
-- shared game state (populated below, referenced by HUD earlier)
local st

-- UI table is declared here so input polling can see it
local UI

local function Now() return tick() * 1000 end

local function clampNum(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function lerp(a, b, t) return a + (b - a) * t end

local function splitCsv(s)
    local out = {}
    if not s or s == "" then return out end
    for w in string.gmatch(s, "[^,]+") do
        w = string.match(w, "^%s*(.-)%s*$")
        if w ~= "" then out[#out + 1] = w end
    end
    return out
end

local function fmtTime(ms)
    local s = math.floor(ms / 1000)
    return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

local function strFind(hay, needle)
    if needle == "" then return true end
    return string.find(string.lower(hay), string.lower(needle), 1, true) ~= nil
end

-- Color3 channel readback. Matcha only documents Color3.fromRGB, so we
-- probe available read methods once and cache the working one.
local RGB_MODE = nil

local function hsvToRgb01(h, s, v)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    local r, g, b
    if i == 0 then r, g, b = v, t, p
    elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t
    elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t, p, v
    else r, g, b = v, p, q end
    return r * 255, g * 255, b * 255
end

local function colToRgb(c)
    if c == nil then return 255, 255, 255 end
    if RGB_MODE == nil then
        local ok = pcall(function() local _ = c.R end)
        if ok then
            RGB_MODE = "fields"
        else
            local ok2 = pcall(function() local _ = c:ToHSV() end)
            RGB_MODE = ok2 and "tohsv" or "tostring"
        end
    end
    if RGB_MODE == "fields" then
        local ok, r, g, b = pcall(function() return c.R, c.G, c.B end)
        if ok and type(r) == "number" then
            if r <= 1.001 and g <= 1.001 and b <= 1.001 then
                return r * 255, g * 255, b * 255
            end
            return r, g, b
        end
    elseif RGB_MODE == "tohsv" then
        local ok, h, s, v = pcall(function() return c:ToHSV() end)
        if ok and type(h) == "number" then
            return hsvToRgb01(h, s, v)
        end
    end
    -- last resort: parse numbers out of the string form
    local str = tostring(c)
    local nums = {}
    for num in string.gmatch(str, "%-?%d+%.?%d*") do
        nums[#nums + 1] = tonumber(num)
        if #nums == 3 then break end
    end
    if #nums == 3 then
        local r, g, b = nums[1], nums[2], nums[3]
        if r <= 1.001 and g <= 1.001 and b <= 1.001 then
            return r * 255, g * 255, b * 255
        end
        return r, g, b
    end
    return 255, 255, 255
end

------------------------------------------------------------
-- INPUT POLLING (one pass per frame)
------------------------------------------------------------
local VK = {
    LMB = 0x01, RMB = 0x02, MMB = 0x04,
    Space = 0x20, Enter = 0x0D, Back = 0x08, Esc = 0x1B, Tab = 0x09,
    Shift = 0x10, Ctrl = 0x11, Alt = 0x12,
    LShift = 0xA0, RShift = 0xA1, LCtrl = 0xA2, RCtrl = 0xA3, LAlt = 0xA4, RAlt = 0xA5,
    P = 0x50,
}

local IN = {
    mx = 0, my = 0,
    md = false, mdc = false, mu = false,
    rd = false, rdc = false,
    keys = {}, pressed = {}, down = {},
}

local function vkName(vk)
    if vk == nil or vk == 0 then return "none" end
    if vk == VK.LMB then return "m1" end
    if vk == VK.RMB then return "m2" end
    if vk == VK.MMB then return "m3" end
    if vk == VK.Space then return "space" end
    if vk == VK.Enter then return "enter" end
    if vk == VK.Back then return "back" end
    if vk == VK.Shift then return "shift" end
    if vk == VK.Ctrl then return "ctrl" end
    if vk == VK.Alt then return "alt" end
    if vk == VK.RShift then return "rshift" end
    if vk == VK.RCtrl then return "rctrl" end
    if vk == VK.RAlt then return "ralt" end
    if vk >= 0x41 and vk <= 0x5A then return string.lower(string.char(vk)) end
    if vk >= 0x30 and vk <= 0x39 then return string.char(vk) end
    if vk >= 0x70 and vk <= 0x7B then return "f" .. tostring(vk - 0x6F) end
    return "vk" .. tostring(vk)
end

-- scan list used when capturing a keybind
local CAPTURE_VKS = {}
do
    for k, v in pairs(VK) do CAPTURE_VKS[#CAPTURE_VKS + 1] = v end
    for vk = 0x41, 0x5A do CAPTURE_VKS[#CAPTURE_VKS + 1] = vk end
    for vk = 0x30, 0x39 do CAPTURE_VKS[#CAPTURE_VKS + 1] = vk end
    for vk = 0x70, 0x7B do CAPTURE_VKS[#CAPTURE_VKS + 1] = vk end
end

-- typing table for textboxes (lower, upper)
local TYPE_MAP = {
    [0x20] = { " ", " " }, [0xBA] = { ";", ":" }, [0xBB] = { "=", "+" },
    [0xBC] = { ",", "<" }, [0xBD] = { "-", "_" }, [0xBE] = { ".", ">" },
    [0xBF] = { "/", "?" }, [0xC0] = { "`", "~" }, [0xDB] = { "[", "{" },
    [0xDC] = { "\\", "|" }, [0xDD] = { "]", "}" }, [0xDE] = { "'", "\"" },
}
for vk = 0x30, 0x39 do
    local up = ")!@#$%^&*("
    TYPE_MAP[vk] = { string.char(vk), string.sub(up, vk - 0x30 + 1, vk - 0x30 + 1) }
end

-- input probing: call iskeypressed directly once it is confirmed to exist
local HAS_KEYPRESS = pcall(function() return iskeypressed(0x10) end)
local HAS_M1 = pcall(function() return ismouse1pressed() end)
local HAS_M2 = pcall(function() return ismouse2pressed() end)
local cachedMouse = nil
local mouseInit = false

-- steady-state we only poll keys that are actually bound; the full scan
-- runs only while capturing a keybind or typing into a textbox/search
local pollNormal = {}
local pollNormalDirty = true
local pollLastBuild = 0

local function rebuildPollNormal()
    pollNormalDirty = false
    pollLastBuild = Now()
    local list, seen = {}, {}
    local function add(vk)
        if type(vk) == "number" and vk ~= 0 and not seen[vk] then
            seen[vk] = true
            list[#list + 1] = vk
        end
    end
    add(VK.P); add(VK.Esc); add(VK.Back); add(VK.Enter)
    add(VK.LShift); add(VK.RShift); add(VK.Shift)
    add(VK.LCtrl); add(VK.RCtrl); add(VK.LAlt); add(VK.RAlt)
    add(VK.Home); add(VK.End); add(VK.Insert); add(VK.Delete)
    for _, w in pairs(UI.byId) do
        if w.kb then add(w.kb.key) end
    end
    pollNormal = list
end

local function pollInput()
    if not mouseInit then
        mouseInit = true
        pcall(function() cachedMouse = Players.LocalPlayer:GetMouse() end)
    end
    if cachedMouse then
        local ok, x, y = pcall(function() return cachedMouse.X, cachedMouse.Y end)
        if ok and x then
            IN.mx = x
            IN.my = y
        end
    end
    for k in pairs(IN.pressed) do IN.pressed[k] = nil end
    if HAS_KEYPRESS then
        if pollNormalDirty or (Now() - pollLastBuild > 5000) then
            rebuildPollNormal()
        end
        local typing = (UI.capture ~= nil) or UI.searchFocus or (UI.focusedBox ~= nil)
        local list = typing and CAPTURE_VKS or pollNormal
        for _, vk in ipairs(list) do
            local d = iskeypressed(vk)
            if d and not IN.keys[vk] then IN.pressed[vk] = true end
            IN.keys[vk] = d
        end
    end
    local md = HAS_M1 and ismouse1pressed() or false
    local rd = HAS_M2 and ismouse2pressed() or false
    IN.mdc = md and not IN.md
    IN.mu = (not md) and IN.md
    IN.rdc = rd and not IN.rd
    IN.md = md
    IN.rd = rd
end

local function inBox(x, y, w, h)
    return IN.mx >= x and IN.mx <= x + w and IN.my >= y and IN.my <= y + h
end

------------------------------------------------------------
-- DRAWING POOL (objects are reused every frame, not re-created)
------------------------------------------------------------
local pool = { Square = {}, Text = {}, Line = {}, Circle = {}, Triangle = {} }
local poolCur = { Square = 0, Text = 0, Line = 0, Circle = 0, Triangle = 0 }
local POOL_CLASSES = { "Square", "Text", "Line", "Circle", "Triangle" }

local function take(cls)
    local c = poolCur[cls] + 1
    poolCur[cls] = c
    local list = pool[cls]
    local d = list[c]
    if not d then
        d = Drawing.new(cls)
        list[c] = d
        d.Visible = true
    else
        d.Visible = true
    end
    return d
end

local function poolEndFrame()
    for ci = 1, #POOL_CLASSES do
        local cls = POOL_CLASSES[ci]
        local list = pool[cls]
        for i = poolCur[cls] + 1, #list do
            list[i].Visible = false
        end
        poolCur[cls] = 0
    end
end

-- Optional Drawing properties are probed ONCE at boot; afterwards all
-- property writes are direct (no pcall, no closures) - this is the main
-- performance lever of the whole UI.
local TRI_OK = pcall(function()
    local d = Drawing.new("Triangle")
    d.Visible = false
end)

local OPT = {}
do
    local function build(cls, props)
        local t = {}
        for _, p in ipairs(props) do
            t[p] = pcall(function()
                local d = Drawing.new(cls)
                local v = d[p]  -- read first: fails if property missing
                d[p] = v
                d.Visible = false
            end)
        end
        return t
    end
    OPT.Square = build("Square", { "Corner", "ZIndex" })
    OPT.Text = build("Text", { "ZIndex" })
    OPT.Line = build("Line", { "ZIndex" })
    OPT.Circle = build("Circle", { "NumSides", "ZIndex" })
    OPT.Triangle = TRI_OK and build("Triangle", { "ZIndex" }) or {}
end
local SQ_OPT, TX_OPT, LN_OPT, CI_OPT, TR_OPT =
    OPT.Square, OPT.Text, OPT.Line, OPT.Circle, OPT.Triangle

local function newSq(x, y, w, h, col, filled, corner, z)
    local d = take("Square")
    d.Position = Vector2.new(x, y)
    d.Size = Vector2.new(w, h)
    d.Color = col
    d.Filled = filled and true or false
    if SQ_OPT.Corner then d.Corner = corner or 0 end
    if SQ_OPT.ZIndex then d.ZIndex = z or 1 end
    return d
end

local function newTx(x, y, col, size, text, center, font, z)
    local d = take("Text")
    d.Position = Vector2.new(x, y)
    d.Color = col
    d.Text = text or ""
    d.Center = center and true or false
    d.Outline = true
    d.FontSize = size or 13
    if font then d.Font = font end
    if TX_OPT.ZIndex then d.ZIndex = z or 2 end
    return d
end

local function newLn(x1, y1, x2, y2, col, thick, z)
    local d = take("Line")
    d.From = Vector2.new(x1, y1)
    d.To = Vector2.new(x2, y2)
    d.Color = col
    d.Thickness = thick or 1
    if LN_OPT.ZIndex then d.ZIndex = z or 2 end
    return d
end

local function newCi(x, y, r, col, filled, thick, z)
    local d = take("Circle")
    d.Position = Vector2.new(x, y)
    d.Radius = r
    d.Color = col
    d.Filled = filled and true or false
    d.Thickness = thick or 1
    if CI_OPT.NumSides then d.NumSides = 24 end
    if CI_OPT.ZIndex then d.ZIndex = z or 2 end
    return d
end

local function newTr(x1, y1, x2, y2, x3, y3, col, z)
    if not TRI_OK then return nil end
    local d = take("Triangle")
    d.PointA = Vector2.new(x1, y1)
    d.PointB = Vector2.new(x2, y2)
    d.PointC = Vector2.new(x3, y3)
    d.Color = col
    d.Filled = true
    if TR_OPT.ZIndex then d.ZIndex = z or 2 end
    return d
end

------------------------------------------------------------
-- THEME (INS-style palette)
------------------------------------------------------------
local T = {
    bg      = Color3.fromRGB(23, 23, 28),
    sidebar = Color3.fromRGB(16, 16, 20),
    card    = Color3.fromRGB(33, 33, 40),
    cardHov = Color3.fromRGB(40, 40, 48),
    field   = Color3.fromRGB(43, 43, 52),
    field2  = Color3.fromRGB(50, 50, 60),
    stroke  = Color3.fromRGB(58, 58, 70),
    text    = Color3.fromRGB(232, 232, 238),
    dim     = Color3.fromRGB(150, 150, 162),
    faint   = Color3.fromRGB(100, 100, 112),
    accent  = Color3.fromRGB(122, 134, 255),
    accent2 = Color3.fromRGB(189, 130, 255),
    good    = Color3.fromRGB(95, 210, 135),
    warn    = Color3.fromRGB(255, 190, 70),
    bad     = Color3.fromRGB(255, 90, 120),
    knob    = Color3.fromRGB(245, 245, 250),
}

local FONT_TITLE = Drawing.Fonts.ProximaSoftBold or Drawing.Fonts.SystemBold
local FONT_BODY  = Drawing.Fonts.System or Drawing.Fonts.UI
local FONT_NUM   = Drawing.Fonts.Monospace or Drawing.Fonts.UI

------------------------------------------------------------
-- UI LIBRARY
------------------------------------------------------------
UI = {}
UI.byId = {}
UI.tabs = {}
UI.categories = {}
UI.activeTab = 1
UI.activeSub = 1
UI.visible = true
UI.minimized = false
UI.search = ""
UI.searchFocus = false
UI.capture = nil          -- keybind widget currently capturing
UI.openDropdown = nil
UI.openColor = nil
UI.focusedBox = nil
UI.drag = nil             -- { kind = "window"|"slider", ... }
UI.layoutDirty = true

UI.x, UI.y, UI.w, UI.h = 0, 0, 780, 620
local SIDE_W, TOP_H, PAD, COL_GAP = 180, 56, 18, 14

local function colX1() return UI.x + SIDE_W + PAD end
local function colX2() return UI.x + SIDE_W + PAD + ((UI.w - SIDE_W - PAD * 2 - COL_GAP) / 2) + COL_GAP end
local function colW() return (UI.w - SIDE_W - PAD * 2 - COL_GAP) / 2 end
local function contentY() return UI.y + TOP_H + PAD + 30 end -- +30 for sub-tab row space

-- widget height per kind
local H = {
    toggle = 30, slider = 42, mini = 40, dropdown = 46, color = 32,
    button = 30, textbox = 46, divider = 26, label = 20, info = 22,
}

local function cat(name)
    UI.categories[#UI.categories + 1] = { name = name, tabs = {} }
end

function UI:Tab(name, icon)
    local t = {
        name = name, icon = icon or string.sub(name, 1, 1),
        sections = {}, subs = { { name = nil, sections = {} } }, subName = nil,
    }
    t.secList = t.subs[1].sections
    self.tabs[#self.tabs + 1] = t
    local c = UI.categories[#UI.categories]
    if c then c.tabs[#c.tabs + 1] = #self.tabs end
    return t
end

function UI:Sub(name)
    local t = self.tabs[#self.tabs]
    -- reuse the default (first, unnamed) sub if it is still empty
    if #t.subs == 1 and t.subs[1].name == nil and #t.subs[1].sections == 0 then
        t.subs[1].name = name
        t.secList = t.subs[1].sections
        return t
    end
    local s = { name = name, sections = {} }
    t.subs[#t.subs + 1] = s
    t.secList = s.sections
    return t
end

local function mkWidget(sec, kind, label, extra)
    local w = {
        kind = kind, label = label, sec = sec, value = nil,
        visible = true, id = extra and extra.id or nil,
        kb = extra and extra.kb or nil,
        x = 0, y = 0, w = 0, h = H[kind] or 30,
    }
    sec.widgets[#sec.widgets + 1] = w
    if w.id then UI.byId[w.id] = w end
    return w
end

-- widget adders live on the Section metatable
local SectionMT = {}
SectionMT.__index = {}

function SectionMT.__index:Toggle(label, def, cb, id)
    local w = mkWidget(self, "toggle", label, { id = id })
    w.value = def and true or false
    w.cb = cb
    return w
end

function SectionMT.__index:Slider(label, def, min, max, step, unit, cb, id, mini)
    local w = mkWidget(self, mini and "mini" or "slider", label, { id = id })
    w.value, w.min, w.max, w.step = def or min, min, max, step or 1
    w.unit = unit or ""
    w.cb = cb
    return w
end

function SectionMT.__index:Dropdown(label, items, defIdx, cb, id)
    local w = mkWidget(self, "dropdown", label, { id = id })
    w.items = items or {}
    w.value = defIdx or 1
    w.cb = cb
    return w
end

function SectionMT.__index:Colorpicker(label, def, cb, id)
    local w = mkWidget(self, "color", label, { id = id })
    w.value = def or T.accent
    w.cb = cb
    return w
end

function SectionMT.__index:Textbox(label, def, cb, id)
    local w = mkWidget(self, "textbox", label, { id = id })
    w.value = def or ""
    w.cb = cb
    return w
end

function SectionMT.__index:Button(label, cb, id)
    local w = mkWidget(self, "button", label, { id = id })
    w.cb = cb
    return w
end

function SectionMT.__index:Label(text)
    local w = mkWidget(self, "label", text)
    w.value = text
    return w
end

function SectionMT.__index:Info(text)
    local w = mkWidget(self, "info", text)
    w.value = text
    return w
end

function SectionMT.__index:Divider(text)
    local w = mkWidget(self, "divider", text or "")
    return w
end

local function mkSection(tab, title, side, subtitle)
    local sec = { title = title, side = side or "Left", subtitle = subtitle, widgets = {}, h = 0 }
    setmetatable(sec, SectionMT)
    tab.secList[#tab.secList + 1] = sec
    return sec
end

-- patch UI:Tab / UI:Sub to return objects with :Section
local realTab, realSub = UI.Tab, UI.Sub
function UI:Tab(name, icon)
    local t = realTab(self, name, icon)
    local mt = {
        __index = {
            Section = function(tab, title, side, subtitle)
                return mkSection(tab, title, side, subtitle)
            end,
            Sub = function(tab, name2)
                return realSub(UI, name2) and tab
            end,
        },
    }
    setmetatable(t, mt)
    return t
end

------------------------------------------------------------
-- KEYBIND MODEL
--  modes: "Always" | "Hold" | "Toggle"
--  attached to a toggle as t.kb = { key = vk, mode = "...", gate = true }
------------------------------------------------------------
local function kbAttach(toggle, key, mode)
    toggle.kb = { key = key or 0, mode = mode or "Always", gate = true }
    pollNormalDirty = true
    return toggle
end

local function kbActive(w)
    if not w or not w.value then return false end
    local kb = w.kb
    if not kb or kb.key == 0 or kb.mode == "Always" then return true end
    if kb.mode == "Hold" then
        return IN.keys[kb.key] == true
    end
    return kb.gate
end

local function kbTick()
    -- update Toggle-mode gates on key edges
    for _, w in pairs(UI.byId) do
        if w.kb and w.kb.mode == "Toggle" and w.kb.key ~= 0 and IN.pressed[w.kb.key] then
            w.kb.gate = not w.kb.gate
        end
    end
end

------------------------------------------------------------
-- UI LAYOUT + RENDER
------------------------------------------------------------
local function layout()
    local cw = colW()
    local search = UI.search
    for ti = 1, #UI.tabs do
        local tab = UI.tabs[ti]
        for si = 1, #tab.subs do
            local sub = tab.subs[si]
            for sideName, cx in pairs({ Left = colX1(), Right = colX2() }) do
                local cy = contentY()
                for _, sec in ipairs(sub.sections) do
                    if sec.side == sideName then
                        local y = cy + 42 + (sec.subtitle and 14 or 0)
                        local any = false
                        for _, w in ipairs(sec.widgets) do
                            w.visible = (search == "") or strFind(w.label or "", search) or (w.kind == "divider")
                            if w.visible then
                                local cols = w.groupCols or 1
                                if cols > 1 then
                                    local gw = (cw - 24 - (cols - 1) * 8) / cols
                                    w.w = gw
                                    w.x = cx + 12 + (w.groupIdx - 1) * (gw + 8)
                                    w.y = y
                                    if w.groupIdx >= cols then y = y + w.h + 2 end
                                else
                                    w.x, w.y, w.w = cx + 12, y, cw - 24
                                    y = y + w.h + 2
                                end
                                any = true
                            end
                        end
                        sec.h = (y - cy) + 10
                        sec.x, sec.y, sec.w = cx, cy, cw
                        sec.anyVisible = any
                        if any then cy = cy + sec.h + 14 end
                    end
                end
            end
        end
    end
end

local function drawChip(x, y, text, col, bgCol)
    local w = math.max(28, 10 + #text * 7)
    local s = newSq(x, y, w, 18, bgCol or T.field, true, 6, 3)
    local t = newTx(x + w / 2, y + 2, col or T.dim, 11, text, true, FONT_NUM, 4)
    return w, s, t
end

local function drawCheck(x, y, on)
    local box = newSq(x, y, 18, 18, on and T.accent or T.field, true, 6, 3)
    if not on then box.Thickness = 1 end
    if on then
        newLn(x + 4, y + 9, x + 8, y + 13, T.knob, 2, 4)
        newLn(x + 8, y + 13, x + 14, y + 5, T.knob, 2, 4)
    end
    return box
end

local function widgetUnder(mx, my)
    local tab = UI.tabs[UI.activeTab]
    if not tab then return nil end
    local sub = tab.subs[UI.activeSub] or tab.subs[1]
    for i = #sub.sections, 1, -1 do
        local sec = sub.sections[i]
        if sec.anyVisible then
            for j = #sec.widgets, 1, -1 do
                local w = sec.widgets[j]
                if w.visible and my >= w.y - 2 and my <= w.y + w.h and mx >= w.x and mx <= w.x + w.w then
                    return w
                end
            end
        end
    end
    return nil
end

local function renderWidget(w, hov)
    local x, y, ww = w.x, w.y, w.w
    if w.kind == "toggle" then
        newTx(x, y + 7, hov and T.text or T.dim, 13, w.label, false, FONT_BODY, 3)
        local cx = x + ww - 18
        if w.kb and w.kb.key and w.kb.key ~= 0 then
            local kw = math.max(26, 12 + #vkName(w.kb.key) * 7)
            cx = cx - kw - 6
            local capt = (UI.capture == w)
            local chip = newSq(cx, y + 6, kw, 18, capt and T.accent or T.field, true, 6, 3)
            newTx(cx + kw / 2, y + 8, capt and T.knob or T.dim, 11,
                capt and "..." or vkName(w.kb.key), true, FONT_NUM, 4)
            w._chipBox = { x = cx, y = y + 6, w = kw, h = 18 }
        else
            w._chipBox = nil
        end
        drawCheck(x + ww - 18, y + 6, w.value)
    elseif w.kind == "slider" then
        newTx(x, y + 2, hov and T.text or T.dim, 12, w.label, false, FONT_BODY, 3)
        local vtxt = (w.step and w.step >= 1) and tostring(math.floor(w.value + 0.5))
            or string.format("%.2f", w.value)
        if w.unit ~= "" then vtxt = vtxt .. " " .. w.unit end
        drawChip(x + ww - 46, y - 2, vtxt, T.text, T.field)
        local ty = y + 26
        newSq(x, ty, ww, 6, T.field, true, 3, 3)
        local frac = (w.value - w.min) / math.max(1e-6, (w.max - w.min))
        newSq(x, ty, math.max(6, ww * frac), 6, T.accent, true, 3, 3)
        newCi(x + ww * frac, ty + 3, 7, T.knob, true, 1, 4)
    elseif w.kind == "mini" then
        local txt = (w.step and w.step >= 1) and tostring(math.floor(w.value + 0.5))
            or string.format("%.2f", w.value)
        newTx(x, y + 2, T.faint, 10, w.label, false, FONT_BODY, 3)
        local twd = #txt * 6 + 4
        newTx(x + ww - twd / 2, y + 2, T.dim, 10, txt, true, FONT_NUM, 3)
        local ty = y + 22
        newSq(x, ty, ww, 5, T.field, true, 3, 3)
        local frac = (w.value - w.min) / math.max(1e-6, (w.max - w.min))
        newSq(x, ty, math.max(5, ww * frac), 5, T.accent, true, 3, 3)
        newCi(x + ww * frac, ty + 2.5, 5, T.knob, true, 1, 4)
    elseif w.kind == "dropdown" then
        newTx(x, y + 2, hov and T.text or T.dim, 12, w.label, false, FONT_BODY, 3)
        local fy = y + 18
        local open = (UI.openDropdown == w)
        local f = newSq(x, fy, ww, 26, open and T.field2 or T.field, true, 7, 3)
        local item = w.items[w.value] or "?"
        newTx(x + 10, fy + 5, T.text, 12, item, false, FONT_BODY, 4)
        -- chevron
        local cxx, cyy = x + ww - 16, fy + 11
        if open then
            newTr(cxx - 4, cyy + 3, cxx + 4, cyy + 3, cxx, cyy - 3, T.dim, 4)
        else
            newTr(cxx - 4, cyy - 3, cxx + 4, cyy - 3, cxx, cyy + 3, T.dim, 4)
        end
    elseif w.kind == "color" then
        newTx(x, y + 8, hov and T.text or T.dim, 12, w.label, false, FONT_BODY, 3)
        local sw = newSq(x + ww - 26, y + 3, 22, 22, w.value, true, 7, 3)
        sw.Thickness = 1
        local open = (UI.openColor == w)
        if open then
            sw.Color = T.accent
        end
    elseif w.kind == "button" then
        local hovL = hov
        local b = newSq(x, y, ww, w.h - 2, hovL and T.field2 or T.field, true, 8, 3)
        b.Thickness = 1
        newTx(x + ww / 2, y + (w.h - 2) / 2 - 8, hovL and T.text or T.dim, 12, w.label, true, FONT_BODY, 4)
    elseif w.kind == "textbox" then
        newTx(x, y + 2, hov and T.text or T.dim, 12, w.label, false, FONT_BODY, 3)
        local fy = y + 18
        local foc = (UI.focusedBox == w)
        local f = newSq(x, fy, ww, 26, foc and T.field2 or T.field, true, 7, 3)
        if foc then f.Thickness = 1 end
        local shown = w.value
        if #shown > 28 then shown = "..." .. string.sub(shown, #shown - 24) end
        newTx(x + 10, fy + 5, T.text, 12, shown, false, FONT_BODY, 4)
        if foc and (math.floor(Now() / 500) % 2 == 0) then
            newTx(x + 12 + #shown * 7, fy + 5, T.accent, 12, "|", false, FONT_BODY, 4)
        end
    elseif w.kind == "divider" then
        local my2 = y + w.h / 2
        newLn(x, my2, x + ww, my2, T.stroke, 1, 3)
        if w.label and w.label ~= "" then
            local tw = #w.label * 6 + 16
            newSq(x + ww / 2 - tw / 2, my2 - 8, tw, 16, T.card, true, 4, 3)
            newTx(x + ww / 2, my2 - 7, T.faint, 10, string.upper(w.label), true, FONT_BODY, 4)
        end
    elseif w.kind == "label" then
        newTx(x, y + 4, T.dim, 12, w.value, false, FONT_BODY, 3)
    elseif w.kind == "info" then
        newTx(x, y + 4, T.faint, 11, w.value, false, FONT_BODY, 3)
    end
end

local function renderDropdownPopup(w)
    local x, y = w.x, w.y + 18 + 28
    local ww = w.w
    local n = #w.items
    local h = n * 26 + 8
    newSq(x, y, ww, h, T.field2, true, 8, 20)
    newSq(x, y, ww, h, T.stroke, false, 8, 20).Thickness = 1
    for i = 1, n do
        local iy = y + 4 + (i - 1) * 26
        local hov = inBox(x, iy, ww, 26)
        local sel = (i == w.value)
        if hov or sel then
            newSq(x + 4, iy, ww - 8, 24, sel and T.accent or T.field, true, 6, 21)
        end
        newTx(x + 12, iy + 5, sel and T.knob or (hov and T.text or T.dim), 12, w.items[i], false, FONT_BODY, 22)
    end
end

local function renderColorPopup(w)
    local x, y = w.x - 150, w.y + 26
    if y > UI.y + UI.h - 150 then y = UI.y + UI.h - 150 end
    local pw, ph = 200, 132
    newSq(x, y, pw, ph, T.field2, true, 10, 20)
    newSq(x, y, pw, ph, T.stroke, false, 10, 20).Thickness = 1
    newTx(x + 12, y + 8, T.text, 12, "Color", false, FONT_TITLE, 21)
    newSq(x + pw - 36, y + 8, 24, 24, w.value, true, 7, 21)
    local rr, gg, bb = colToRgb(w.value)
    local chans = { { "R", rr / 255 }, { "G", gg / 255 }, { "B", bb / 255 } }
    for i = 1, 3 do
        local cy = y + 40 + (i - 1) * 28
        newTx(x + 12, cy + 2, T.dim, 11, chans[i][1], false, FONT_NUM, 21)
        local tx, tw = x + 32, pw - 80
        newSq(tx, cy + 6, tw, 5, T.field, true, 3, 21)
        newSq(tx, cy + 6, tw * chans[i][2], 5, T.accent, true, 3, 21)
        newCi(tx + tw * chans[i][2], cy + 8.5, 5, T.knob, true, 1, 22)
        w["_c" .. i] = { x = tx, y = cy, w = tw, h = 18 }
    end
    w._cbox = { x = x, y = y, w = pw, h = ph }
end

local function renderSidebar()
    newSq(UI.x, UI.y, SIDE_W, UI.h, T.sidebar, true, 12, 1)
    -- logo block
    newSq(UI.x + 18, UI.y + 18, 40, 40, T.accent, true, 10, 2)
    newTx(UI.x + 38, UI.y + 27, T.knob, 18, "C", true, FONT_TITLE, 3)
    newTx(UI.x + 68, UI.y + 22, T.text, 16, "CLOVER", false, FONT_TITLE, 3)
    newTx(UI.x + 68, UI.y + 42, T.faint, 10, "retribution hub", false, FONT_BODY, 3)

    local y = UI.y + 84
    for _, c in ipairs(UI.categories) do
        newTx(UI.x + 22, y, T.faint, 10, string.upper(c.name), false, FONT_BODY, 3)
        y = y + 18
        for _, tabIdx in ipairs(c.tabs) do
            local tab = UI.tabs[tabIdx]
            local active = (tabIdx == UI.activeTab)
            if active then
                newSq(UI.x + 12, y, SIDE_W - 24, 34, T.field, true, 9, 2)
            end
            newSq(UI.x + 22, y + 7, 20, 20, active and T.accent or T.field2, true, 6, 3)
            newTx(UI.x + 32, y + 11, active and T.knob or T.dim, 11, tab.icon, true, FONT_TITLE, 4)
            newTx(UI.x + 52, y + 9, active and T.text or T.dim, 13, tab.name, false, FONT_BODY, 3)
            tab._rect = { x = UI.x + 12, y = y, w = SIDE_W - 24, h = 34 }
            y = y + 38
        end
        y = y + 6
    end

    -- footer: executor + ping
    newSq(UI.x + 12, UI.y + UI.h - 54, SIDE_W - 24, 42, T.field, true, 9, 2)
    local host = "Matcha"
    pcall(function()
        local ok, nm = pcall(function() return select(1, identifyexecutor()) end)
        if ok and type(nm) == "string" then host = nm end
    end)
    newTx(UI.x + 24, UI.y + UI.h - 46, T.text, 12, host, false, FONT_BODY, 3)
    local ping = "?"
    pcall(function() ping = tostring(math.floor(GetPingValue())) .. " ms" end)
    newTx(UI.x + 24, UI.y + UI.h - 30, T.faint, 10, "ping " .. ping, false, FONT_NUM, 3)
end

local function renderTopbar()
    local tab = UI.tabs[UI.activeTab]
    newSq(UI.x + SIDE_W, UI.y, UI.w - SIDE_W, TOP_H, T.bg, true, 0, 1)
    newTx(UI.x + SIDE_W + PAD, UI.y + 16, T.text, 20, tab and tab.name or "", false, FONT_TITLE, 3)

    -- search box
    local sw = 170
    local sx = UI.x + UI.w - sw - 92
    local s = newSq(sx, UI.y + 12, sw, 30, UI.searchFocus and T.field2 or T.field, true, 8, 3)
    if UI.searchFocus then s.Thickness = 1 end
    newCi(sx + 18, UI.y + 27, 6, T.faint, false, 2, 4)
    newLn(sx + 22, UI.y + 31, sx + 27, UI.y + 36, T.faint, 2, 4)
    if UI.search ~= "" then
        newTx(sx + 36, UI.y + 18, T.text, 12, UI.search, false, FONT_BODY, 4)
    else
        newTx(sx + 36, UI.y + 18, T.faint, 12, "search", false, FONT_BODY, 4)
    end
    UI._searchBox = { x = sx, y = UI.y + 12, w = sw, h = 30 }

    -- min / close
    local bx = UI.x + UI.w - 74
    newTx(bx + 12, UI.y + 14, T.dim, 16, "-", true, FONT_BODY, 4)
    UI._minBox = { x = bx, y = UI.y + 8, w = 30, h = 30 }
    newTx(bx + 48, UI.y + 14, T.dim, 16, "x", true, FONT_BODY, 4)
    UI._closeBox = { x = bx + 32, y = UI.y + 8, w = 30, h = 30 }
end

local function renderSubTabs()
    local tab = UI.tabs[UI.activeTab]
    if not tab or #tab.subs < 2 then return end
    local x = colX1()
    local y = UI.y + TOP_H + 6
    for i = 1, #tab.subs do
        local name = tab.subs[i].name
        if name then
            local w = 16 + #name * 7
            local active = (UI.activeSub == i)
            newSq(x, y, w, 24, active and T.accent or T.field, true, 7, 3)
            newTx(x + w / 2, y + 5, active and T.knob or T.dim, 11, name, true, FONT_BODY, 4)
            tab.subs[i]._rect = { x = x, y = y, w = w, h = 24 }
            x = x + w + 8
        end
    end
end

local function renderSections()
    local tab = UI.tabs[UI.activeTab]
    if not tab then return end
    local sub = tab.subs[UI.activeSub] or tab.subs[1]
    local bottom = contentY() + contentH() - 2
    for _, sec in ipairs(sub.sections) do
        if sec.anyVisible and sec.y < bottom then
            newSq(sec.x, sec.y, sec.w, math.min(sec.h, bottom - sec.y), T.card, true, 10, 2)
            newTx(sec.x + 14, sec.y + 12, T.accent, 12, string.upper(sec.title), false, FONT_TITLE, 3)
            local tw = #sec.title * 8 + 30
            newLn(sec.x + 14 + tw, sec.y + 18, sec.x + sec.w - 14, sec.y + 18, T.stroke, 1, 3)
            if sec.subtitle then
                newTx(sec.x + 14, sec.y + 28, T.faint, 10, sec.subtitle, false, FONT_BODY, 3)
            end
            for _, w in ipairs(sec.widgets) do
                if w.visible and w.y < bottom then
                    local hov = (UI.drag == nil) and (UI.openDropdown == nil) and (UI.openColor == nil)
                        and inBox(w.x, w.y - 2, w.w, w.h)
                    renderWidget(w, hov)
                end
            end
        end
    end
end

local function renderWindow()
    if not UI.visible then return end
    if UI.minimized then
        newSq(UI.x, UI.y, UI.w, TOP_H, T.bg, true, 12, 1)
        renderTopbar()
        return
    end
    newSq(UI.x, UI.y, UI.w, UI.h, T.bg, true, 12, 1)
    renderSidebar()
    renderTopbar()
    renderSubTabs()
    renderSections()
    if UI.openDropdown then renderDropdownPopup(UI.openDropdown) end
    if UI.openColor then renderColorPopup(UI.openColor) end
end

------------------------------------------------------------
-- UI INPUT
------------------------------------------------------------
local function sliderSetFromMouse(w, mx)
    local frac = clampNum((mx - w.x) / math.max(1, w.w), 0, 1)
    local v = w.min + (w.max - w.min) * frac
    v = math.floor(v / w.step + 0.5) * w.step
    v = clampNum(v, w.min, w.max)
    if v ~= w.value then
        w.value = v
        if w.cb then pcall(w.cb, v) end
    end
end

local function handleTextboxTyping()
    local w = UI.focusedBox
    if not w then return end
    if IN.pressed[VK.Back] then
        w.value = string.sub(w.value, 1, -2)
        if w.cb then pcall(w.cb, w.value) end
        return
    end
    if IN.pressed[VK.Enter] or IN.pressed[VK.Esc] then
        UI.focusedBox = nil
        if w.cb then pcall(w.cb, w.value) end
        return
    end
    if IN.pressed[VK.LShift] or IN.pressed[VK.RShift] or IN.keys[VK.Shift] then end
    local shifted = IN.keys[VK.LShift] or IN.keys[VK.RShift] or IN.keys[VK.Shift]
    for vk = 0x30, 0x5A do
        if IN.pressed[vk] then
            local ch
            if TYPE_MAP[vk] then
                ch = shifted and TYPE_MAP[vk][2] or TYPE_MAP[vk][1]
            elseif vk >= 0x41 and vk <= 0x5A then
                ch = shifted and string.char(vk) or string.lower(string.char(vk))
            end
            if ch and #w.value < 120 then
                w.value = w.value .. ch
                if w.cb then pcall(w.cb, w.value) end
            end
        end
    end
    for vk = 0xBA, 0xE2 do
        if IN.pressed[vk] and TYPE_MAP[vk] then
            local ch = shifted and TYPE_MAP[vk][2] or TYPE_MAP[vk][1]
            if ch and #w.value < 120 then
                w.value = w.value .. ch
                if w.cb then pcall(w.cb, w.value) end
            end
        end
    end
end

local function handleUIInput()
    -- menu toggle
    if IN.pressed[VK.P] and not UI.focusedBox and not UI.searchFocus then
        UI.visible = not UI.visible
    end

    -- keybind capture takes priority
    if UI.capture then
        if IN.pressed[VK.Esc] then
            UI.capture = nil
            return
        end
        for _, vk in ipairs(CAPTURE_VKS) do
            if IN.pressed[vk] and vk ~= VK.P then
                UI.capture.kb.key = vk
                UI.capture = nil
                pollNormalDirty = true
                return
            end
        end
        -- clicking chip again cancels
        if IN.mdc and UI.capture._chipBox and inBox(UI.capture._chipBox.x, UI.capture._chipBox.y, UI.capture._chipBox.w, UI.capture._chipBox.h) then
            UI.capture = nil
        end
        return
    end

    handleTextboxTyping()

    if not UI.visible or UI.minimized then return end

    -- popups first (click inside / outside)
    if UI.openDropdown then
        local w = UI.openDropdown
        local x, y = w.x, w.y + 18 + 28
        local n = #w.items
        local h = n * 26 + 8
        if IN.mdc then
            if inBox(x, y, w.w, h) then
                local idx = math.floor((IN.my - y - 4) / 26) + 1
                if idx >= 1 and idx <= n then
                    w.value = idx
                    if w.cb then pcall(w.cb, idx, w.items[idx]) end
                end
                UI.openDropdown = nil
            elseif not inBox(w.x, w.y, w.w, w.h + 20) then
                UI.openDropdown = nil
            end
        end
        return
    end

    if UI.openColor then
        local w = UI.openColor
        local box = w._cbox
        if IN.mdc then
            local inP = box and inBox(box.x, box.y, box.w, box.h)
            local onSw = inBox(w.x + w.w - 26, w.y + 3, 22, 22)
            if not inP and not onSw then
                UI.openColor = nil
                return
            end
        end
        if IN.md and box then
            for i = 1, 3 do
                local sl = w["_c" .. i]
                if sl and inBox(sl.x, sl.y - 6, sl.w, 18) then
                    local frac = clampNum((IN.mx - sl.x) / sl.w, 0, 1)
                    local rr, gg, bb = colToRgb(w.value)
                    if i == 1 then rr = frac * 255 elseif i == 2 then gg = frac * 255 else bb = frac * 255 end
                    w.value = Color3.fromRGB(
                        clampNum(math.floor(rr + 0.5), 0, 255),
                        clampNum(math.floor(gg + 0.5), 0, 255),
                        clampNum(math.floor(bb + 0.5), 0, 255))
                    if w.cb then pcall(w.cb, w.value, 1) end
                end
            end
        end
        return
    end

    -- slider drag continuation
    if UI.drag and UI.drag.kind == "slider" then
        if IN.md then
            sliderSetFromMouse(UI.drag.w, IN.mx)
            return
        else
            UI.drag = nil
        end
    end

    -- window drag
    if UI.drag and UI.drag.kind == "window" then
        if IN.md then
            UI.x = clampNum(IN.mx - UI.drag.dx, -UI.w + 120, 4000)
            UI.y = clampNum(IN.my - UI.drag.dy, 0, 4000)
            return
        else
            UI.drag = nil
        end
    end

    if IN.mdc then
        -- chrome
        if UI._closeBox and inBox(UI._closeBox.x, UI._closeBox.y, UI._closeBox.w, UI._closeBox.h) then
            UI.visible = false
            return
        end
        if UI._minBox and inBox(UI._minBox.x, UI._minBox.y, UI._minBox.w, UI._minBox.h) then
            UI.minimized = not UI.minimized
            UI.layoutDirty = true
            return
        end
        if UI._searchBox and inBox(UI._searchBox.x, UI._searchBox.y, UI._searchBox.w, UI._searchBox.h) then
            UI.searchFocus = true
            UI.focusedBox = nil
            return
        else
            UI.searchFocus = false
        end
        -- drag window by topbar
        if inBox(UI.x + SIDE_W, UI.y, UI.w - SIDE_W - 90, TOP_H - 10) then
            UI.drag = { kind = "window", dx = IN.mx - UI.x, dy = IN.my - UI.y }
            return
        end
        -- sidebar tabs
        for ti = 1, #UI.tabs do
            local r = UI.tabs[ti]._rect
            if r and inBox(r.x, r.y, r.w, r.h) then
                UI.activeTab = ti
                UI.activeSub = 1
                UI.openDropdown = nil
                UI.openColor = nil
                UI.layoutDirty = true
                return
            end
        end
        -- sub tabs
        local tab = UI.tabs[UI.activeTab]
        if tab then
            for si = 1, #tab.subs do
                local r = tab.subs[si]._rect
                if r and inBox(r.x, r.y, r.w, r.h) then
                    UI.activeSub = si
                    UI.layoutDirty = true
                    return
                end
            end
        end
        -- widgets
        local w = widgetUnder(IN.mx, IN.my)
        if w then
            if w.kind == "toggle" then
                if w._chipBox and inBox(w._chipBox.x, w._chipBox.y, w._chipBox.w, w._chipBox.h) then
                    UI.capture = w
                else
                    w.value = not w.value
                    if w.kb and w.kb.mode == "Toggle" then w.kb.gate = w.value end
                    if w.cb then pcall(w.cb, w.value) end
                end
                return
            elseif w.kind == "slider" or w.kind == "mini" then
                UI.drag = { kind = "slider", w = w }
                sliderSetFromMouse(w, IN.mx)
                return
            elseif w.kind == "dropdown" then
                UI.openDropdown = w
                return
            elseif w.kind == "color" then
                UI.openColor = (UI.openColor == w) and nil or w
                return
            elseif w.kind == "textbox" then
                UI.focusedBox = w
                UI.searchFocus = false
                return
            elseif w.kind == "button" then
                if w.cb then pcall(w.cb) end
                return
            end
        else
            UI.focusedBox = nil
        end
    end

    -- right click on keybind chip cycles mode
    if IN.rdc then
        local w = widgetUnder(IN.mx, IN.my)
        if w and w.kind == "toggle" and w.kb and w._chipBox
            and inBox(w._chipBox.x, w._chipBox.y, w._chipBox.w, w._chipBox.h) then
            local order = { "Always", "Hold", "Toggle" }
            local i = 1
            for k = 1, 3 do if order[k] == w.kb.mode then i = k end end
            w.kb.mode = order[(i % 3) + 1]
            w.kb.gate = true
        end
    end
end

-- typing for search box
local function handleSearchTyping()
    if not UI.searchFocus then return end
    if IN.pressed[VK.Back] then
        UI.search = string.sub(UI.search, 1, -2)
        layout()
        return
    end
    if IN.pressed[VK.Esc] or IN.pressed[VK.Enter] then
        UI.searchFocus = false
        return
    end
    local shifted = IN.keys[VK.LShift] or IN.keys[VK.RShift] or IN.keys[VK.Shift]
    for vk = 0x30, 0x5A do
        if IN.pressed[vk] and #UI.search < 24 then
            local ch
            if TYPE_MAP[vk] then
                ch = shifted and TYPE_MAP[vk][2] or TYPE_MAP[vk][1]
            elseif vk >= 0x41 and vk <= 0x5A then
                ch = shifted and string.char(vk) or string.lower(string.char(vk))
            end
            if ch then
                UI.search = UI.search .. ch
                layout()
            end
        end
    end
end

------------------------------------------------------------
-- GAME DATA
------------------------------------------------------------
local CHEST_MAP = {
    ["Terra"]                   = { folder = "Bandit Leader",      path = {"Chest", "Chest"} },
    ["Aetherstone Golem"]       = { folder = "Aetherstone Golem",  path = {"Chests", "Chest"} },
    ["Grasslands Warlord"]      = { folder = "Grasslands Warlord", path = {"Chests", "Chest"} },
    ["Khamsin"]                 = { folder = "Khamsin's Legend",   path = {"Chests", "Chest"} },
    ["Ice Golem"]               = { folder = "Ice Golem",          path = {"Chests", "Chest"} },
    ["Vampire Elite"]           = { folder = "Vampire Elites",     path = {"Chest"} },
    ["Primal Werewolf"]         = { folder = "Primal Werewolves",  path = {"Chest"} },
    ["Elder Vampire"]           = { folder = "Vampire Lord",       path = {"Chest"} },
    ["Corrupted Elder Vampire"] = { folder = "Vampire Lord",       path = {"Chest"} },
}

local BOSS_NAMES = {
    ["Ice Golem"] = true, ["Aetherstone Golem"] = true, ["Desert Kraken"] = true,
    ["Grasslands Warlord"] = true, ["Khamsin"] = true, ["Medusa"] = true,
    ["Primal Werewolf"] = true, ["Terra"] = true, ["Elder Vampire"] = true,
    ["Vampire Elite"] = true, ["Corrupted Elder Vampire"] = true,
}

local ORE_KINDS = {
    { id = "oreStone",     label = "Stone",      names = { "StoneL", "StoneS", "StoneM" },
      paths = { "GrasslandsOreCorrect", "Collectibles.Desert", "TundraOre" } },
    { id = "oreMana",      label = "Mana Stone", names = { "ManaStoneS", "ManaStoneM", "ManaStoneL" },
      paths = { "TundraOre" } },
    { id = "oreIron",      label = "Iron",       names = { "IronS", "IronM", "IronL" },
      paths = { "GrasslandsOreCorrect", "TundraOre" } },
    { id = "oreDragonite", label = "Dragonite",  names = { "DragoniteS", "DragoniteM", "DragoniteL" },
      paths = { "TundraOre" } },
}

local SPAWN_CAMP_MOBS = { ["Wolf"] = true, ["Vampire Soldier"] = true, ["Shadow Hand Goon"] = true }

local COLOR_MOB    = Color3.fromRGB(77, 163, 255)
local COLOR_BOSS   = Color3.fromRGB(255, 60, 60)
local COLOR_TARGET = Color3.fromRGB(255, 255, 0)
local COLOR_CHEST  = Color3.fromRGB(255, 215, 0)
local COLOR_RIFT   = Color3.fromRGB(200, 60, 255)
local COLOR_SPIRIT = Color3.fromRGB(0, 200, 255)
local COLOR_WISP   = Color3.fromRGB(0, 255, 180)
local COLOR_ORE    = Color3.fromRGB(255, 170, 60)

------------------------------------------------------------
-- VALUE ACCESS
------------------------------------------------------------
local function vb(id, def)
    local w = UI.byId[id]
    if w and type(w.value) == "boolean" then return w.value end
    return def
end

local function vn(id, def)
    local w = UI.byId[id]
    if w and type(w.value) == "number" then return w.value end
    return def
end

local function vs(id, def)
    local w = UI.byId[id]
    if w and type(w.value) == "string" then return w.value end
    return def
end

local function vc(id, def)
    local w = UI.byId[id]
    if w and typeof(w.value) == "Color3" then return w.value end
    return def
end

local function vactive(id)
    local w = UI.byId[id]
    if w then return kbActive(w) end
    return false
end

------------------------------------------------------------
-- GAME HELPERS
------------------------------------------------------------
local function nameMatches(instName, wantedList)
    for i = 1, #wantedList do
        local w = wantedList[i]
        if instName == w or string.find(instName, w, 1, true) then return true end
    end
    return false
end

local function isAlive(model)
    if not model or not model.Parent then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return false end
    return true
end

local function anchorOf(model)
    return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
end

local function firstPartOf(root)
    if not root then return nil end
    if root:IsA("BasePart") then return root end
    local direct = root:FindFirstChildWhichIsA("BasePart")
    if direct then return direct end
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

local function countAliveByName(ef, name)
    if not ef then return 0 end
    local c = 0
    for _, e in ipairs(ef:GetChildren()) do
        if e.Name == name and isAlive(e) then c = c + 1 end
    end
    return c
end

local function dist3(a, b) return (a - b).Magnitude end

local function getEnemiesFolder()
    local ent = game.Workspace:FindFirstChild("Entities")
    return ent and ent:FindFirstChild("Enemies")
end

local function setRoot(root, x, y, z)
    local ok = pcall(function() root.CFrame = CFrame.new(x, y, z) end)
    if not ok then
        pcall(function() root.Position = Vector3.new(x, y, z) end)
    end
end

local function setRootVel(root)
    local ok = pcall(function() root.AssemblyLinearVelocity = Vector3.zero end)
    if not ok then pcall(function() root.Velocity = Vector3.zero end) end
end

local function tpTo(root, x, y, z)
    setRoot(root, x, y, z)
    setRootVel(root)
end

local function lookCF(from, to)
    local okC, cf = pcall(function()
        if CFrame.lookAt then return CFrame.lookAt(from, to) end
        return nil
    end)
    if okC and cf then return cf end
    local okK, cf2 = pcall(function()
        local camClass = rawget(_G, "Camera")
        if camClass and camClass.lookAt then return camClass.lookAt(from, to) end
        return nil
    end)
    if okK and cf2 then return cf2 end
    local d = to - from
    local yaw = math.atan2(-d.X, -d.Z)
    local pitch = math.atan2(d.Y, math.sqrt(d.X * d.X + d.Z * d.Z))
    return CFrame.new(from.X, from.Y, from.Z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-pitch, 0, 0)
end

local function partVelocity(part)
    local ok, v = pcall(function() return part.AssemblyLinearVelocity end)
    if ok and v then return v end
    local ok2, v2 = pcall(function() return part.Velocity end)
    if ok2 and v2 then return v2 end
    return nil
end

local function findChestPart(mobName)
    local info = CHEST_MAP[mobName]
    if not info then return nil end
    local ent = game.Workspace:FindFirstChild("Entities")
    local events = ent and ent:FindFirstChild("Events")
    if not events then return nil end
    local folder = events:FindFirstChild(info.folder)
    if not folder then return nil end
    local current = folder
    for _, step in ipairs(info.path) do
        current = current:FindFirstChild(step)
        if not current then return nil end
    end
    if current:IsA("BasePart") then return current end
    return firstPartOf(current)
end

local wispScanCache = { list = {}, at = 0 }
local function getAllWispParts()
    if Now() - wispScanCache.at < 500 then return wispScanCache.list end
    wispScanCache.at = Now()
    local result = {}
    local ws = game.Workspace
    for _, wn in ipairs({ "WindWisp", "ManaWisp", "LightWisp", "BloodWisp" }) do
        local w = ws:FindFirstChild(wn)
        if w then
            local part = firstPartOf(w)
            if part then result[#result + 1] = { part = part, name = wn } end
        end
    end
    wispScanCache.list = result
    return result
end

local riftScanCache = { demon = nil, spirit = nil, at = 0 }
local function getRiftParts()
    if Now() - riftScanCache.at < 500 then
        return riftScanCache.demon, riftScanCache.spirit
    end
    riftScanCache.at = Now()
    local ignore = game.Workspace:FindFirstChild("Ignore")
    riftScanCache.demon = firstPartOf(ignore and ignore:FindFirstChild("DemonRift"))
    riftScanCache.spirit = firstPartOf(ignore and ignore:FindFirstChild("SpiritPortal"))
    return riftScanCache.demon, riftScanCache.spirit
end

local function getDemonRiftPart()
    local d = getRiftParts()
    return d
end

local function getSpiritPortalPart()
    local _, s = getRiftParts()
    return s
end

local ORE_FOLDER_NAMES = { ["GrasslandsOreCorrect"] = true, ["Collectibles.Desert"] = true, ["TundraOre"] = true }

local function discoverOreFolders()
    local found = {}
    local stack = { { game.Workspace, 0 } }
    local budget = 6000
    while #stack > 0 and budget > 0 do
        local item = table.remove(stack)
        local node, depth = item[1], item[2]
        budget = budget - 1
        local okC, kids = pcall(function() return node:GetChildren() end)
        if okC and type(kids) == "table" then
            for _, k in ipairs(kids) do
                if ORE_FOLDER_NAMES[k.Name] then
                    local okP, fp = pcall(function() return k:GetFullName() end)
                    if okP and type(fp) == "string" and string.find(fp, "Orespawn", 1, true) then
                        found[#found + 1] = { folder = k, path = fp }
                    end
                end
                if depth < 12 and not k:IsA("BasePart") then
                    stack[#stack + 1] = { k, depth + 1 }
                end
            end
        end
    end
    return found
end

local function collectOreIn(node, kindOK, result, depth)
    if depth > 4 then return end
    local okC, kids = pcall(function() return node:GetChildren() end)
    if not okC or type(kids) ~= "table" then return end
    for _, k in ipairs(kids) do
        local n = k.Name
        local matched = nil
        for kind, _ in pairs(kindOK) do
            for _, wn in ipairs(kind.names) do
                if n == wn then matched = kind; break end
            end
            if matched then break end
        end
        if matched then
            local p = firstPartOf(k)
            if p then result[#result + 1] = { part = p, id = n, kind = matched.label } end
        elseif not k:IsA("BasePart") then
            collectOreIn(k, kindOK, result, depth + 1)
        end
    end
end

local function scanOres()
    local want = {}
    for _, kind in ipairs(ORE_KINDS) do
        if vb(kind.id, true) then want[#want + 1] = kind end
    end
    local result = {}
    if #want == 0 then return result end

    -- revalidate folder cache; full rediscovery at most every 30s
    local cache = st.oreFolders
    local alive = #cache > 0
    if alive then
        for _, e in ipairs(cache) do
            if not e.folder or not e.folder.Parent then alive = false; break end
        end
    end
    if not alive or (Now() - st.oreFolderAt > 30000) then
        cache = discoverOreFolders()
        st.oreFolders = cache
        st.oreFolderAt = Now()
    end

    for _, entry in ipairs(cache) do
        local kindOK = {}
        for _, kind in ipairs(want) do
            for _, frag in ipairs(kind.paths) do
                if string.find(entry.path, frag, 1, true) then kindOK[kind] = true; break end
            end
        end
        if next(kindOK) then
            collectOreIn(entry.folder, kindOK, result, 0)
        end
    end

    -- safety net: if folder discovery found nothing, fall back to one
    -- full scan (still rate-limited by the caller cache)
    if #cache == 0 then
        for _, desc in ipairs(game.Workspace:GetDescendants()) do
            local n = desc.Name
            for _, kind in ipairs(want) do
                local isName = false
                for _, wn in ipairs(kind.names) do
                    if n == wn then isName = true; break end
                end
                if isName then
                    local okP, fn = pcall(function() return desc:GetFullName() end)
                    if okP and fn and string.find(fn, "Orespawn", 1, true) then
                        local okF = false
                        for _, frag in ipairs(kind.paths) do
                            if string.find(fn, frag, 1, true) then okF = true; break end
                        end
                        if okF then
                            local p = firstPartOf(desc)
                            if p then result[#result + 1] = { part = p, id = fn, kind = kind.label } end
                        end
                    end
                    break
                end
            end
        end
    end
    return result
end

local function isVisible(fromPos, part, model)
    if not vb("aimVisCheck", false) then return true end
    local ok, res = pcall(function()
        return game.Workspace:Raycast(fromPos, part.Position - fromPos)
    end)
    if not ok or not res then return true end
    local inst = res.Instance
    if not inst then return true end
    if inst == part then return true end
    local m = inst.Parent
    while m and m ~= game.Workspace do
        if m == model then return true end
        m = m.Parent
    end
    return false
end

local function aimFovOk(aimPos, camera)
    if not vb("aimFovCheck", false) then return true end
    local sp, on = WorldToScreen(aimPos)
    if not on then return false end
    local vs = camera and camera.ViewportSize or Vector2.new(1920, 1080)
    local dx = sp.X - vs.X / 2
    local dy = sp.Y - vs.Y / 2
    local r = vn("aimFov", 300)
    return (dx * dx + dy * dy) <= r * r
end

local lastClickAt = 0
local function autoClick(intervalMs, now)
    if now - lastClickAt >= intervalMs then
        lastClickAt = now
        mouse1click()
    end
end

local attackHeld = false
local function setAttackHold(state)
    if state and not attackHeld then
        attackHeld = true
        mouse1press()
    elseif not state and attackHeld then
        attackHeld = false
        mouse1release()
    end
end

local function applyAim(aimPart, camera)
    local smooth = clampNum(vn("aimSmooth", 0.2), 0.01, 1.0)
    local alpha = clampNum(1 - smooth, 0.01, 1)
    local aimPos = aimPart.Position
    if vb("aimPredict", false) then
        local v = partVelocity(aimPart)
        if v then
            local pxz = vn("aimPredXZ", 1.0)
            local py = vn("aimPredY", 1.0)
            aimPos = aimPos + Vector3.new(v.X * pxz, v.Y * py, v.Z * pxz) * 0.15
        end
    end
    if vn("aimMethod", 1) == 1 then
        if camera then
            local from = camera.CFrame.Position
            local goal = lookCF(from, aimPos)
            pcall(function() camera.CFrame = camera.CFrame:Lerp(goal, alpha) end)
        end
    else
        local sp, on = WorldToScreen(aimPos)
        if on then
            local mx, my = sp.X, sp.Y
            if cachedMouse then
                local okxy, mx0, my0 = pcall(function() return cachedMouse.X, cachedMouse.Y end)
                if okxy and mx0 then
                    mx = mx0 + (sp.X - mx0) * alpha
                    my = my0 + (sp.Y - my0) * alpha
                end
            end
            mousemoveabs(math.floor(mx + 0.5), math.floor(my + 0.5))
        end
    end
end

------------------------------------------------------------
-- GAME HUD (watermark, status, radar, notifications)
------------------------------------------------------------
local notifs = {}

local function hudNotify(title, msg, col, dur)
    notifs[#notifs + 1] = {
        title = title, msg = msg or "", col = col or T.accent,
        born = Now(), dur = (dur or 4) * 1000,
    }
    if #notifs > 6 then table.remove(notifs, 1) end
end

local function gameHud()
    local camera = game.Workspace.CurrentCamera
    local vs = camera and camera.ViewportSize or Vector2.new(1920, 1080)

    -- watermark
    if vb("hudWatermark", true) then
        local ping = "?"
        pcall(function() ping = tostring(math.floor(GetPingValue())) end)
        local txt = "CLOVER HUB  v4  |  " .. ping .. "ms"
        local w = 32 + #txt * 8
        newSq(16, 16, w, 30, T.bg, true, 8, 5)
        newSq(16, 19, 3, 24, T.accent, true, 2, 6)
        newTx(30, 22, T.text, 13, txt, false, FONT_NUM, 6)
    end

    -- status panel
    if vb("hudStatus", true) then
        local x, y, w, h = 16, 54, 250, 118
        newSq(x, y, w, h, T.bg, true, 8, 5)
        newSq(x, y + 2, 3, h - 4, T.accent, true, 2, 6)
        newTx(x + 14, y + 10, T.accent, 11, "STATUS", false, FONT_TITLE, 6)
        newTx(x + 14, y + 28, T.text, 14, _G.__cloverStatus or "IDLE", false, FONT_BODY, 6)
        newTx(x + 14, y + 48, T.dim, 11, _G.__cloverStatusSub or "", false, FONT_BODY, 6)
        local stats = string.format("kills %d   chests %d   wisps %d   ores %d",
            _G.__cloverKills or 0, _G.__cloverChests or 0, _G.__cloverWisps or 0, _G.__cloverOres or 0)
        newTx(x + 14, y + h - 22, T.faint, 10, stats, false, FONT_NUM, 6)
    end

    -- radar
    if vb("hudRadar", true) then
        local size = 190
        local x, y = vs.X - size - 16, vs.Y - size - 16
        newSq(x, y, size, size, T.bg, true, 10, 5)
        newSq(x, y + 2, 3, size - 4, T.accent, true, 2, 6)
        newTx(x + 12, y + 8, T.accent, 10, "RADAR", false, FONT_TITLE, 6)
        local cx, cy = x + size / 2, y + size / 2 + 6
        local r = size / 2 - 16
        newCi(cx, cy, r, T.stroke, false, 1, 6)
        newLn(cx - r, cy, cx + r, cy, T.stroke, 1, 6)
        newLn(cx, cy - r, cx, cy + r, T.stroke, 1, 6)

        local myPos = nil
        pcall(function()
            local ch = Players.LocalPlayer.Character
            local root = ch and ch:FindFirstChild("HumanoidRootPart")
            if root then myPos = root.Position end
        end)
        if myPos then
            local look = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)
            local fX, fZ = look.X, look.Z
            local fl = math.sqrt(fX * fX + fZ * fZ)
            if fl < 0.01 then fX, fZ, fl = 0, -1, 1 end
            fX, fZ = fX / fl, fZ / fl
            local rX, rZ = fZ, -fX
            local scale = r / vn("hudRadarRange", 500)
            local function dot(pos, col, sz)
                local dx = pos.X - myPos.X
                local dz = pos.Z - myPos.Z
                local px = cx + (dx * rX + dz * rZ) * scale
                local py = cy - (dx * fX + dz * fZ) * scale
                local ddx, ddy = px - cx, py - cy
                local dd2 = ddx * ddx + ddy * ddy
                if dd2 > r * r then
                    local dd = math.sqrt(dd2)
                    px = cx + ddx / dd * r
                    py = cy + ddy / dd * r
                end
                newSq(px - sz / 2, py - sz / 2, sz, sz, col, true, 2, 7)
            end
            local en = getEnemiesFolder()
            local want = _G.__cloverWant or {}
            if en and #want > 0 then
                -- rescan the enemy list at 6Hz; positions are read live below
                if Now() - st.radarScanAt > 150 then
                    st.radarScanAt = Now()
                    local list = {}
                    for _, e in ipairs(en:GetChildren()) do
                        if nameMatches(e.Name, want) and isAlive(e) then
                            local a = anchorOf(e)
                            if a then list[#list + 1] = { e = e, part = a, boss = BOSS_NAMES[e.Name] and true or false } end
                        end
                    end
                    st.radarCache = list
                end
                local tgt = _G.__cloverTarget
                for _, m in ipairs(st.radarCache) do
                    if m.part and m.part.Parent then
                        if m.e == tgt then
                            dot(m.part.Position, COLOR_TARGET, 6)
                        elseif m.boss then
                            dot(m.part.Position, COLOR_BOSS, 7)
                        else
                            dot(m.part.Position, COLOR_MOB, 5)
                        end
                    end
                end
            end
            for _, w in ipairs(getAllWispParts()) do
                if w.part and w.part.Parent then dot(w.part.Position, COLOR_WISP, 4) end
            end
            local rd, rp = getRiftParts()
            if rd and rd.Parent then dot(rd.Position, COLOR_RIFT, 8) end
            if rp and rp.Parent then dot(rp.Position, COLOR_SPIRIT, 8) end
            newTr(cx, cy - 7, cx - 5, cy + 5, cx + 5, cy + 5, T.accent, 7)
        end
    end

    -- notifications
    if vb("hudNotifs", true) then
        local now = Now()
        local alive = {}
        for _, n in ipairs(notifs) do
            if now - n.born < n.dur then alive[#alive + 1] = n end
        end
        notifs = alive
        local w, h = 300, 52
        local y = vs.Y - 16 - h
        for i = #alive, 1, -1 do
            local n = alive[i]
            local age = now - n.born
            local slide = clampNum(age / 250, 0, 1)
            local x = vs.X - 16 - w + (1 - slide) * 60
            newSq(x, y, w, h, T.bg, true, 8, 30)
            newSq(x, y + 2, 3, h - 4, n.col, true, 2, 31)
            newTx(x + 14, y + 8, n.col, 12, n.title, false, FONT_TITLE, 31)
            if n.msg ~= "" then
                newTx(x + 14, y + 26, T.dim, 11, n.msg, false, FONT_BODY, 31)
            end
            newSq(x + 14, y + h - 8, w - 28, 3, T.field, true, 2, 31)
            newSq(x + 14, y + h - 8, (w - 28) * (1 - age / n.dur), 3, n.col, true, 2, 31)
            y = y - h - 8
        end
    end
end

------------------------------------------------------------
-- WEBHOOK
------------------------------------------------------------
local whQueue = {}
local whLastSend = 0

local function whPush(title, desc, col)
    if not vb("whOn", false) then return end
    local url = vs("whUrl", "")
    if url == "" then return end
    local colInt = 5793266
    if col then
        local r, g, b = colToRgb(col)
        colInt = math.floor(r) * 65536 + math.floor(g) * 256 + math.floor(b)
    end
    whQueue[#whQueue + 1] = {
        url = url, title = title, desc = desc, col = colInt,
    }
end

local function whWorker()
    while true do
        if #whQueue > 0 and Now() - whLastSend > 2200 then
            local item = table.remove(whQueue, 1)
            whLastSend = Now()
            pcall(function()
                local payload = HttpService:JSONEncode({
                    username = "Clover Hub",
                    embeds = { {
                        title = item.title,
                        description = item.desc,
                        color = item.col,
                        footer = { text = "Clover Retribution Hub v4 - Matcha" },
                    } },
                })
                httppost(item.url, payload, "application/json")
            end)
        end
        wait(0.5)
    end
end

------------------------------------------------------------
-- CONFIG / PROFILES / SAVED LOCATIONS
------------------------------------------------------------
local CFG_FILE = "clover_hub_cfg.json"
local LOC_FILE = "clover_saved_locs.json"
local savedLocs = {}
local locsDirty = true

local function dumpConfig()
    local data = {}
    for id, w in pairs(UI.byId) do
        if w.kind == "toggle" then
            data[id] = { t = "b", v = w.value and 1 or 0 }
            if w.kb then data[id .. "#kb"] = { t = "k", v = w.kb.key, m = w.kb.mode } end
        elseif w.kind == "slider" or w.kind == "mini" or w.kind == "dropdown" then
            data[id] = { t = "n", v = w.value }
        elseif w.kind == "textbox" then
            data[id] = { t = "s", v = w.value }
        elseif w.kind == "color" then
            local r, g, b = colToRgb(w.value)
            data[id] = { t = "c", v = { r, g, b } }
        end
    end
    return data
end

local function applyConfig(data)
    if type(data) ~= "table" then return false end
    for id, w in pairs(UI.byId) do
        local d = data[id]
        if d then
            if d.t == "b" then
                w.value = (d.v == 1)
            elseif d.t == "n" then
                w.value = tonumber(d.v) or w.value
            elseif d.t == "s" then
                w.value = tostring(d.v)
            elseif d.t == "c" and type(d.v) == "table" then
                w.value = Color3.fromRGB(
                    clampNum(tonumber(d.v[1]) or 255, 0, 255),
                    clampNum(tonumber(d.v[2]) or 255, 0, 255),
                    clampNum(tonumber(d.v[3]) or 255, 0, 255))
            end
        end
        local kd = data[id .. "#kb"]
        if kd and w.kb then
            w.kb.key = tonumber(kd.v) or w.kb.key
            w.kb.mode = tostring(kd.m or w.kb.mode)
            w.kb.gate = true
            pollNormalDirty = true
        end
    end
    return true
end

local function saveConfigFile(path)
    local ok = pcall(function()
        writefile(path, HttpService:JSONEncode(dumpConfig()))
    end)
    hudNotify(ok and "Config saved" or "Save failed", path, ok and T.good or T.bad)
end

local function loadConfigFile(path)
    local ok, data = pcall(function()
        if not isfile(path) then return nil end
        return HttpService:JSONDecode(readfile(path))
    end)
    if ok and applyConfig(data) then
        hudNotify("Config loaded", path, T.good)
    else
        hudNotify("Load failed", path, T.bad)
    end
end

local function refreshList(combo, pattern, prefix)
    if not combo then return end
    local items = {}
    pcall(function()
        for _, f in ipairs(listfiles("") or {}) do
            if string.find(f, pattern, 1, true) then
                local nm = string.match(f, prefix .. "(.+)%.json")
                if nm then items[#items + 1] = nm end
            end
        end
    end)
    if #items == 0 then items = { "<empty>" } end
    combo.items = items
    combo.value = 1
end

local function loadSavedLocs()
    local ok, data = pcall(function()
        if not isfile(LOC_FILE) then return nil end
        return HttpService:JSONDecode(readfile(LOC_FILE))
    end)
    if ok and type(data) == "table" then savedLocs = data end
end

local function persistLocs()
    pcall(function() writefile(LOC_FILE, HttpService:JSONEncode(savedLocs)) end)
end

------------------------------------------------------------
-- PRESETS
------------------------------------------------------------
local PRESETS = {
    ["Grasslands Farm"] = {
        autotp = 1, autoattack = 1, autoChest = 1, spawnCamp = 1,
        mWolf = 1, mBandit = 1, mBanditArcher = 1, mBanditBrute = 1,
    },
    ["Boss Rush"] = {
        autotp = 1, autoattack = 1, autoChest = 1, bossKillPause = 7,
        bTerra = 1, bWarlord = 1, bAetherGolem = 1, bKhamsin = 1,
        bKraken = 1, bMedusa = 1, bIceGolem = 1, bVampElite = 1,
        bElderVamp = 1, bCorruptedElder = 1, bWerewolf = 1,
    },
    ["Wisp Run"] = {
        autowisp = 1, wispEsp = 1, wispWind = 1, wispMana = 1,
        wispLight = 1, wispBlood = 1,
    },
    ["Rift Run"] = { autorift = 1, riftDemon = 1, riftSpirit = 1, riftEsp = 1 },
    ["Ore Run"] = { autoore = 1, oreStone = 1, oreMana = 1, oreIron = 1, oreDragonite = 1, oreEsp = 1 },
    ["Reset All"] = {
        autotp = 0, autoattack = 0, autoaim = 0, autowisp = 0, autoore = 0,
        autorift = 0, autospeed = 0, autonoclip = 0, spectate = 0,
        mWolf = 0, mBandit = 0, mBanditArcher = 0, mBanditBrute = 0,
        mDesertBandit = 0, mAlphaDesertClaw = 0, mStoneGuardian = 0, mDesertClaw = 0,
        mVamp = 0, mVampElite = 0, mShadowGoon = 0, mDevil = 0,
        bTerra = 0, bWarlord = 0, bAetherGolem = 0, bKhamsin = 0, bKraken = 0,
        bMedusa = 0, bIceGolem = 0, bVampElite = 0, bElderVamp = 0,
        bCorruptedElder = 0, bWerewolf = 0,
    },
}

local function applyPreset(name)
    local p = PRESETS[name]
    if not p then return end
    for id, v in pairs(p) do
        local w = UI.byId[id]
        if w then
            if w.kind == "toggle" then
                w.value = (v == 1)
                if w.kb then w.kb.gate = true end
            else
                w.value = v
            end
        end
    end
    hudNotify("Preset", name, T.accent)
end

------------------------------------------------------------
-- BUILD THE UI
------------------------------------------------------------
local function mobBlock(sec, label, idp, defP, defH, defO)
    sec:Toggle(label, false, nil, idp)
    local a = sec:Slider("Priority", defP or 5, 1, 10, 1, "", nil, idp .. "_p", true)
    local b = sec:Slider("Height", defH or 5, -20, 100, 1, "", nil, idp .. "_h", true)
    local c = sec:Slider("Offset", defO or 0, 0, 50, 1, "", nil, idp .. "_o", true)
    a.groupCols, a.groupIdx = 3, 1
    b.groupCols, b.groupIdx = 3, 2
    c.groupCols, c.groupIdx = 3, 3
end

do
    -- center window
    local cam = game.Workspace.CurrentCamera
    local vs = (cam and cam.ViewportSize) or Vector2.new(1600, 900)
    UI.x = math.floor((vs.X - UI.w) / 2)
    UI.y = math.floor((vs.Y - UI.h) / 2)

    cat("COMBAT")
    local combat = UI:Tab("Combat", "C")

    local core = combat:Section("Core", "Left", "teleport to targets")
    local tTP = core:Toggle("Auto Teleport", false, nil, "autotp")
    kbAttach(tTP, VK.P == 0 and 0 or 0x46, "Toggle") -- F
    core:Slider("TP height", 5, -20, 100, 1, "", nil, "tpHeight")
    core:Slider("TP offset", 0, 0, 50, 1, "", nil, "tpOffset")
    core:Slider("Max range", 500, 50, 10000, 50, "m", nil, "maxDist")

    local atk = combat:Section("Auto Attack", "Right", "hit the current target")
    local tAtk = atk:Toggle("Auto Attack", false, nil, "autoattack")
    kbAttach(tAtk, 0x5A, "Toggle") -- Z
    atk:Dropdown("Attack mode", { "Click", "Hold M1" }, 1, nil, "attackMode")
    atk:Slider("Attack range", 30, 5, 100, 1, "m", nil, "attackRange")
    atk:Slider("Click interval", 100, 50, 1000, 10, "ms", nil, "attackInterval")

    local tgt = combat:Section("Targeting", "Left")
    tgt:Dropdown("Target selection", { "Priority + distance", "Closest", "Lowest HP", "Highest HP" }, 1, nil, "targetMode")
    tgt:Toggle("Re-target if too far", true, nil, "smartRetarget")
    tgt:Slider("Re-target multiplier", 3, 1, 10, 1, "x", nil, "retargetMult")
    tgt:Toggle("Anti-stuck", true, nil, "antiStuck")
    tgt:Slider("Stuck timeout", 10, 3, 30, 1, "s", nil, "stuckTime")

    local farm = combat:Section("Farming", "Right")
    farm:Toggle("Camp spawn points", true, nil, "spawnCamp")
    farm:Slider("Camp time", 5, 2, 20, 1, "s", nil, "spawnCampTime")
    farm:Toggle("Auto loot chests", true, nil, "autoChest")
    farm:Slider("Loot time", 7, 2, 20, 1, "s", nil, "chestLootTime")
    farm:Slider("Chest search time", 5, 1, 15, 1, "s", nil, "chestSearchTime")
    farm:Slider("Boss kill pause", 7, 0, 30, 1, "s", nil, "bossKillPause")

    local aim = UI:Tab("Aimbot", "A")
    local am = aim:Section("Aimbot", "Left", "camera or mouse assist")
    local tAim = am:Toggle("Enable Aimbot", false, nil, "autoaim")
    kbAttach(tAim, 0x51, "Hold") -- Q
    am:Dropdown("Aim at", { "Head", "HumanoidRootPart", "Torso" }, 1, nil, "aimPart")
    am:Slider("Smoothness", 0.2, 0.01, 1, 0.01, "", nil, "aimSmooth")
    am:Dropdown("Aim method", { "Mouse", "Camera" }, 2, nil, "aimMethod")
    am:Toggle("Predict movement", false, nil, "aimPredict")
    am:Slider("Predict XZ", 1, 0.1, 5, 0.1, "x", nil, "aimPredXZ")
    am:Slider("Predict Y", 1, 0.1, 5, 0.1, "x", nil, "aimPredY")

    local chk = aim:Section("Checks", "Right")
    chk:Toggle("FOV check", false, nil, "aimFovCheck")
    chk:Slider("FOV radius", 300, 50, 800, 10, "px", nil, "aimFov")
    chk:Toggle("Visible check", false, nil, "aimVisCheck")
    local tSpec = chk:Toggle("Spectate target", false, nil, "spectate")
    kbAttach(tSpec, 0, "Always")
    chk:Info("spectate locks the camera on the target")

    cat("FARMING")
    local wisps = UI:Tab("Wisps", "W")
    local wc = wisps:Section("Collector", "Left")
    local tWisp = wc:Toggle("Auto Collect Wisps", false, nil, "autowisp")
    kbAttach(tWisp, 0x4A, "Toggle") -- J
    wc:Slider("Time per wisp", 3, 1, 15, 1, "s", nil, "wispWaitTime")
    wc:Slider("TP height offset", 3, 0, 10, 1, "", nil, "wispHeight")
    local wf = wisps:Section("Filter", "Right")
    wf:Toggle("Wind Wisp", true, nil, "wispWind")
    wf:Toggle("Mana Wisp", true, nil, "wispMana")
    wf:Toggle("Light Wisp", true, nil, "wispLight")
    wf:Toggle("Blood Wisp", true, nil, "wispBlood")
    local wv = wisps:Section("Visuals", "Right")
    wv:Toggle("Wisp ESP", true, nil, "wispEsp")
    wv:Colorpicker("ESP color", Color3.fromRGB(0, 255, 180), nil, "wispColor")

    local ores = UI:Tab("Ores", "O")
    local oc = ores:Section("Mining", "Left")
    local tOre = oc:Toggle("Auto Mine Ores", false, nil, "autoore")
    kbAttach(tOre, 0x4B, "Toggle") -- K
    oc:Slider("Time per ore", 4, 1, 20, 1, "s", nil, "oreWaitTime")
    oc:Slider("TP height offset", 3, 0, 15, 1, "", nil, "oreHeight")
    local of = ores:Section("Filter", "Right")
    of:Toggle("Stone", true, nil, "oreStone")
    of:Toggle("Mana Stone", true, nil, "oreMana")
    of:Toggle("Iron", true, nil, "oreIron")
    of:Toggle("Dragonite", true, nil, "oreDragonite")
    local ov = ores:Section("Visuals", "Right")
    ov:Toggle("Ore ESP", true, nil, "oreEsp")
    ov:Colorpicker("ESP color", Color3.fromRGB(255, 170, 60), nil, "oreColor")

    local rifts = UI:Tab("Rifts", "R")
    local rc = rifts:Section("Auto Teleport", "Left")
    local tRift = rc:Toggle("Auto TP Rifts", false, nil, "autorift")
    kbAttach(tRift, 0x43, "Toggle") -- C
    rc:Slider("TP height offset", 3, 0, 15, 1, "", nil, "riftHeight")
    rc:Slider("Cycle wait time", 5, 1, 30, 1, "s", nil, "riftWaitTime")
    local rt = rifts:Section("Targets", "Right")
    rt:Toggle("Demon Rift", true, nil, "riftDemon")
    rt:Colorpicker("Demon color", Color3.fromRGB(200, 60, 255), nil, "riftColor")
    rt:Toggle("Spirit Portal", true, nil, "riftSpirit")
    rt:Colorpicker("Spirit color", Color3.fromRGB(0, 200, 255), nil, "spiritColor")
    local rv = rifts:Section("Visuals", "Right")
    rv:Toggle("Rift ESP", true, nil, "riftEsp")

    cat("VISUALS")
    local esp = UI:Tab("ESP & HUD", "E")
    local el = esp:Section("Elements", "Left")
    el:Toggle("Box", true, nil, "espBox")
    el:Toggle("Name", true, nil, "espName")
    el:Toggle("Distance", true, nil, "espDist")
    el:Toggle("Health Bar", true, nil, "espHealth")
    el:Toggle("Snapline", false, nil, "espSnap")
    el:Toggle("FOV Circle", false, nil, "espFov")
    el:Dropdown("Box style", { "Corners", "Full outline", "3D" }, 1, nil, "espBoxStyle")
    el:Slider("Max ESP distance", 1000, 100, 5000, 100, "m", nil, "espMaxDist")

    local cl = esp:Section("Colors", "Left")
    cl:Toggle("Custom mob color", true, nil, "espColMob")
    cl:Colorpicker("Mob color", COLOR_MOB, nil, "espMobCol")
    cl:Toggle("Custom boss color", true, nil, "espColBoss")
    cl:Colorpicker("Boss color", COLOR_BOSS, nil, "espBossCol")
    cl:Toggle("Custom target color", true, nil, "espColTgt")
    cl:Colorpicker("Target color", COLOR_TARGET, nil, "espTgtCol")

    local hd = esp:Section("HUD", "Right", "overlay stays when menu is closed")
    hd:Toggle("Watermark", true, nil, "hudWatermark")
    hd:Toggle("Status panel", true, nil, "hudStatus")
    hd:Toggle("Radar", true, nil, "hudRadar")
    hd:Slider("Radar range", 500, 100, 5000, 100, "m", nil, "hudRadarRange")
    hd:Toggle("Notifications", true, nil, "hudNotifs")

    cat("ZONES")
    local zones = UI:Tab("Zones", "Z")
    UI:Sub("Grasslands")
    local gm = zones:Section("Mobs", "Left")
    mobBlock(gm, "Wolf", "mWolf", 9, 5, 0)
    mobBlock(gm, "Bandit", "mBandit", 8, 5, 0)
    mobBlock(gm, "Bandit Archer", "mBanditArcher", 8, 5, 0)
    mobBlock(gm, "Bandit Brute", "mBanditBrute", 7, 5, 0)
    local gb = zones:Section("Bosses", "Right")
    mobBlock(gb, "Terra", "bTerra", 1, 5, 0)
    mobBlock(gb, "Grasslands Warlord", "bWarlord", 1, 5, 0)
    mobBlock(gb, "Aetherstone Golem", "bAetherGolem", 1, 5, 0)

    UI:Sub("Desert")
    local dm = zones:Section("Mobs", "Left")
    mobBlock(dm, "Desert Bandit", "mDesertBandit", 8, 5, 0)
    mobBlock(dm, "Alpha Desert Claw", "mAlphaDesertClaw", 6, 5, 0)
    mobBlock(dm, "Stone Guardian", "mStoneGuardian", 7, 5, 0)
    mobBlock(dm, "Desert Claw", "mDesertClaw", 7, 5, 0)
    local db = zones:Section("Bosses", "Right")
    mobBlock(db, "Khamsin", "bKhamsin", 1, 5, 0)
    mobBlock(db, "Desert Kraken", "bKraken", 1, 5, 0)
    mobBlock(db, "Medusa", "bMedusa", 1, 5, 0)

    UI:Sub("Other")
    local om = zones:Section("Mobs", "Left")
    mobBlock(om, "Vampire Soldier", "mVamp", 5, 5, 0)
    mobBlock(om, "Vampire Elite", "mVampElite", 5, 5, 0)
    mobBlock(om, "Lesser Devil Juggernaut", "mDevil", 5, 5, 0)
    mobBlock(om, "Shadow Hand Goon", "mShadowGoon", 5, 5, 0)
    local ob = zones:Section("Bosses", "Right")
    mobBlock(ob, "Ice Golem", "bIceGolem", 1, 5, 0)
    mobBlock(ob, "Vampire Elite", "bVampElite", 1, 5, 0)
    mobBlock(ob, "Elder Vampire", "bElderVamp", 1, 5, 0)
    mobBlock(ob, "Corrupted Elder", "bCorruptedElder", 1, 5, 0)
    mobBlock(ob, "Primal Werewolf", "bWerewolf", 1, 5, 0)
    local cu = zones:Section("Custom", "Right")
    cu:Textbox("Extra mob names (csv)", "", nil, "mCustom")

    cat("SYSTEM")
    local wh = UI:Tab("Webhook", "D")
    local wd = wh:Section("Discord", "Left", "event notifications")
    wd:Toggle("Enable Webhook", false, nil, "whOn")
    wd:Textbox("Webhook URL", "", nil, "whUrl")
    wd:Button("Send test", function()
        whPush("Test", "Webhook is working", T.good)
        hudNotify("Webhook test", "queued", T.good)
    end)
    wd:Toggle("Boss spawned", true, nil, "whBossSpawn")
    wd:Toggle("Boss killed", true, nil, "whBossKill")
    wd:Toggle("Chest looted", true, nil, "whChest")
    wd:Toggle("Wisp collected", false, nil, "whWisp")

    local ws = wh:Section("Session", "Right")
    ws:Toggle("Session summary", true, nil, "whSummary")
    ws:Slider("Summary interval", 30, 5, 240, 5, "min", nil, "whSummaryMin")
    ws:Divider("Popups")
    ws:Toggle("Boss spawn/kill", true, nil, "notifyBoss")
    ws:Toggle("Chest looted", true, nil, "notifyChest")
    ws:Toggle("Wisp collected", true, nil, "notifyWisp")
    ws:Toggle("Ore mined", false, nil, "notifyOre")

    local misc = UI:Tab("Misc", "M")
    local mv = misc:Section("Movement", "Left")
    local tSpd = mv:Toggle("Speed Hack", false, nil, "autospeed")
    kbAttach(tSpd, 0, "Always")
    mv:Slider("Walk Speed", 50, 16, 200, 1, "", nil, "walkSpeed")
    local tNc = mv:Toggle("NoClip", false, nil, "autonoclip")
    kbAttach(tNc, 0, "Always")

    local safe = misc:Section("Safety", "Right")
    safe:Toggle("Anti-AFK", true, nil, "antiAfk")
    safe:Slider("Anti-AFK interval", 300, 30, 1800, 30, "s", nil, "afkTime")
    safe:Toggle("Only when game focused", true, nil, "focusOnly")
    local tPanic = safe:Toggle("Panic (hold)", false, nil, "panic")
    kbAttach(tPanic, VK.RAlt, "Hold")
    safe:Button("Disable all features", function()
        applyPreset("Reset All")
        hudNotify("Panic", "all features disabled", T.warn)
    end)

    local pr = misc:Section("Presets", "Left")
    pr:Button("Grasslands Farm", function() applyPreset("Grasslands Farm") end)
    pr:Button("Boss Rush", function() applyPreset("Boss Rush") end)
    pr:Button("Wisp Run", function() applyPreset("Wisp Run") end)
    pr:Button("Rift Run", function() applyPreset("Rift Run") end)
    pr:Button("Ore Run", function() applyPreset("Ore Run") end)
    pr:Button("Reset All", function() applyPreset("Reset All") end)

    local loc = misc:Section("Saved Locations", "Left")
    loc:Textbox("Location name", "", nil, "locName")
    local locCombo
    loc:Button("Save current position", function()
        local ch = Players.LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local name = vs("locName", "")
        if name == "" then name = "loc " .. tostring(#savedLocs + 1) end
        local p = root.Position
        savedLocs[#savedLocs + 1] = { name = name, x = p.X, y = p.Y, z = p.Z }
        persistLocs()
        refreshList(locCombo, "clover_saved_locs", "clover_saved_locs")
        -- rebuild items from savedLocs instead
        local items = {}
        for _, L in ipairs(savedLocs) do items[#items + 1] = L.name end
        if #items == 0 then items = { "<empty>" } end
        locCombo.items = items
        locCombo.value = 1
        hudNotify("Location saved", name, T.good)
    end)
    locCombo = loc:Dropdown("Saved", { "<empty>" }, 1, nil, "locList")
    loc:Button("Teleport to selected", function()
        local L = savedLocs[locCombo.value]
        if not L then return end
        local ch = Players.LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if not root then return end
        tpTo(root, L.x, L.y, L.z)
        hudNotify("Teleport", L.name, T.accent)
    end)
    loc:Button("Delete selected", function()
        if savedLocs[locCombo.value] then
            local nm = savedLocs[locCombo.value].name
            table.remove(savedLocs, locCombo.value)
            persistLocs()
            local items = {}
            for _, L in ipairs(savedLocs) do items[#items + 1] = L.name end
            if #items == 0 then items = { "<empty>" } end
            locCombo.items = items
            locCombo.value = 1
            hudNotify("Deleted", nm or "?", T.warn)
        end
    end)

    local cfg = misc:Section("Config", "Right")
    cfg:Textbox("Profile name", "default", nil, "cfgName")
    local profCombo
    cfg:Button("Save profile", function()
        local nm = vs("cfgName", "default")
        if nm == "" then nm = "default" end
        saveConfigFile("clover_profile_" .. nm .. ".json")
        refreshList(profCombo, "clover_profile_", "clover_profile_")
    end)
    profCombo = cfg:Dropdown("Profiles", { "<empty>" }, 1, nil, "profList")
    cfg:Button("Load profile", function()
        local nm = profCombo.items[profCombo.value]
        if nm and nm ~= "<empty>" then
            loadConfigFile("clover_profile_" .. nm .. ".json")
        end
    end)
    cfg:Button("Delete profile", function()
        local nm = profCombo.items[profCombo.value]
        if nm and nm ~= "<empty>" then
            pcall(function() delfile("clover_profile_" .. nm .. ".json") end)
            refreshList(profCombo, "clover_profile_", "clover_profile_")
            hudNotify("Profile deleted", nm, T.warn)
        end
    end)
    cfg:Divider("Global")
    cfg:Button("Save config", function() saveConfigFile(CFG_FILE) end)
    cfg:Button("Load config", function() loadConfigFile(CFG_FILE) end)

    refreshList(profCombo, "clover_profile_", "clover_profile_")
    do
        local items = {}
        for _, L in ipairs(savedLocs) do items[#items + 1] = L.name end
        if #items == 0 then items = { "<empty>" } end
        locCombo.items = items
    end
end

------------------------------------------------------------
-- GAME STATE
------------------------------------------------------------
st = {
    currentTarget = nil, currentTargetName = nil,
    targetLockedAt = 0, lastTargetPos = nil, stuckCheckAt = 0,
    chestStage = "none", chestTarget = nil, chestStartAt = 0,
    chestDeadName = nil, chestSearchUntil = 0, bossKillPauseUntil = 0,
    wispIndex = 0, wispWaitUntil = 0,
    portalIndex = 0, portalWaitUntil = 0,
    oreIndex = 0, oreWaitUntil = 0, oreCache = {}, oreScanAt = 0,
    oreFolders = {}, oreFolderAt = 0,
    radarCache = {}, radarScanAt = 0,
    kills = 0, chests = 0, wisps = 0, ores = 0,
    sessionStart = 0, lastAfkAt = 0, whLastSummary = 0,
    seenBoss = {}, spawnPositions = {},
    spawnCampIndex = 0, spawnCampWaitUntil = 0,
    speedBackup = nil, ncTouched = {}, ncParts = {}, ncScanAt = 0, lastChar = nil,
    fpsFrames = 0, fpsAt = 0,
}

local function setStatus(a, b)
    _G.__cloverStatus = a
    _G.__cloverStatusSub = b or ""
end

local function recordSpawnPos(name, pos)
    if not SPAWN_CAMP_MOBS[name] then return end
    if not st.spawnPositions[name] then st.spawnPositions[name] = {} end
    local list = st.spawnPositions[name]
    for _, sp in ipairs(list) do
        local dx = sp.X - pos.X
        local dz = sp.Z - pos.Z
        if dx * dx + dz * dz < 100 then return end
    end
    list[#list + 1] = Vector3.new(pos.X, pos.Y, pos.Z)
end

local function pickTarget(en, want, priMap, maxD, myPos)
    local best, bestScore = nil, math.huge
    if not en or #want == 0 then return nil end
    local mode = vn("targetMode", 1)
    for _, e in ipairs(en:GetChildren()) do
        if nameMatches(e.Name, want) and isAlive(e) then
            local a = anchorOf(e)
            local p = a and a.Position
            if p then
                local d = dist3(p, myPos)
                if d <= maxD then
                    local sc
                    if mode == 2 then
                        sc = d
                    elseif mode == 3 then
                        local h = e:FindFirstChildOfClass("Humanoid")
                        sc = (h and h.Health or 1e9) * 1e6 + d
                    elseif mode == 4 then
                        local h = e:FindFirstChildOfClass("Humanoid")
                        sc = -(h and h.Health or 0) * 1e6 + d
                    else
                        sc = (priMap[e.Name] or 5) * 10000 + d
                    end
                    if sc < bestScore then
                        best, bestScore = e, sc
                    end
                end
            end
        end
    end
    return best
end

local function resetChest()
    st.chestStage = "none"
    st.chestTarget = nil
    st.chestDeadName = nil
    st.chestSearchUntil = 0
    st.chestStartAt = 0
end

------------------------------------------------------------
-- MAIN TICK
------------------------------------------------------------
local lastTickErr = 0

local function doTick()
    local now = Now()
    if st.sessionStart == 0 then
        st.sessionStart = now
        st.lastAfkAt = now
    end
    setStatus("IDLE", "")

    -- respawn detect
    local myChar = Players.LocalPlayer.Character
    if myChar ~= st.lastChar then
        if st.lastChar ~= nil then
            st.ncTouched = {}
            st.speedBackup = nil
            setAttackHold(false)
            st.currentTarget = nil
            st.currentTargetName = nil
            resetChest()
            hudNotify("Respawned", "state reset", T.warn)
        end
        st.lastChar = myChar
    end

    -- panic / focus
    local panicOn = vactive("panic")
    if vb("focusOnly", true) then
        local okf, focused = pcall(isrbxactive)
        if okf and focused == false and not panicOn then
            setStatus("PAUSED", "game is not focused")
            return
        end
    end

    local tpOn     = vactive("autotp")
    local attackOn = vactive("autoattack")
    local aimOn    = vactive("autoaim")
    local riftOn   = vactive("autorift")
    local wispOn   = vactive("autowisp")
    local oreOn    = vactive("autoore")
    local speedOn  = vactive("autospeed")
    local noclipOn = vactive("autonoclip")
    local spectateOn = vactive("spectate")

    if panicOn then
        setAttackHold(false)
        setStatus("PANIC", "all features paused")
        return
    end

    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then
        setStatus("LOADING", "waiting for character")
        return
    end
    local myPos = myRoot.Position

    if vb("antiAfk", true) and now - st.lastAfkAt > vn("afkTime", 300) * 1000 then
        st.lastAfkAt = now
        task.spawn(function()
            keypress(0x20)
            wait(0.05)
            keyrelease(0x20)
        end)
    end

    local camera = game.Workspace.CurrentCamera
    local en = getEnemiesFolder()

    -- speed / noclip
    if speedOn then
        local hum = myChar:FindFirstChildOfClass("Humanoid")
        if hum then
            if not st.speedBackup or st.speedBackup.hum ~= hum then
                local orig = 16
                pcall(function() orig = hum.WalkSpeed end)
                st.speedBackup = { hum = hum, orig = orig }
            end
            pcall(function() hum.WalkSpeed = vn("walkSpeed", 50) end)
        end
    elseif st.speedBackup then
        pcall(function() st.speedBackup.hum.WalkSpeed = st.speedBackup.orig end)
        st.speedBackup = nil
    end

    if noclipOn then
        -- rescan character parts at most every 400ms, not every tick
        if now - st.ncScanAt > 400 then
            st.ncScanAt = now
            local parts = {}
            for _, p in ipairs(myChar:GetDescendants()) do
                if p:IsA("BasePart") then parts[#parts + 1] = p end
            end
            st.ncParts = parts
        end
        for _, p in ipairs(st.ncParts) do
            if st.ncTouched[p] == nil then
                local orig = true
                pcall(function() orig = p.CanCollide end)
                st.ncTouched[p] = orig
                pcall(function() p.CanCollide = false end)
            end
        end
    elseif next(st.ncTouched) then
        for p, orig in pairs(st.ncTouched) do
            pcall(function() p.CanCollide = orig end)
        end
        st.ncTouched = {}
    end

    -- chest looting
    if st.chestStage == "looting" then
        setStatus("LOOTING", st.chestDeadName and ("chest: " .. st.chestDeadName) or "")
        if st.chestTarget and st.chestTarget.Parent then
            local pos = st.chestTarget.Position
            tpTo(myRoot, pos.X, pos.Y + 3, pos.Z)
            applyAim(st.chestTarget, camera)
            autoClick(80, now)
            local elapsed = now - st.chestStartAt
            local lootTime = vn("chestLootTime", 7) * 1000
            if elapsed >= lootTime then
                st.chests = st.chests + 1
                _G.__cloverChests = st.chests
                if BOSS_NAMES[st.chestDeadName] then
                    st.bossKillPauseUntil = now + vn("bossKillPause", 7) * 1000
                end
                if vb("notifyChest", true) then
                    hudNotify("Chest looted", st.chestDeadName or "?", COLOR_CHEST)
                end
                if vb("whChest", true) then
                    whPush("Chest looted", "Chest from: **" .. tostring(st.chestDeadName) .. "**", COLOR_CHEST)
                end
                resetChest()
                st.currentTarget = nil
                st.currentTargetName = nil
            end
        else
            if BOSS_NAMES[st.chestDeadName] then
                st.bossKillPauseUntil = now + vn("bossKillPause", 7) * 1000
            end
            resetChest()
            st.currentTarget = nil
            st.currentTargetName = nil
        end
        return
    end

    if st.chestStage == "searching" then
        setStatus("SEARCHING", "chest: " .. tostring(st.chestDeadName))
        if now > st.chestSearchUntil then
            if BOSS_NAMES[st.chestDeadName] then
                st.bossKillPauseUntil = now + vn("bossKillPause", 7) * 1000
            end
            resetChest()
            st.currentTarget = nil
            st.currentTargetName = nil
            return
        end
        local cp = findChestPart(st.chestDeadName)
        if cp and cp.Parent then
            st.chestTarget = cp
            st.chestStage = "looting"
            st.chestStartAt = now
        end
        return
    end

    if now < st.bossKillPauseUntil then
        setStatus("BOSS PAUSE", string.format("%.1fs", (st.bossKillPauseUntil - now) / 1000))
        setAttackHold(false)
        return
    end

    -- wisps
    local rawW = getAllWispParts()
    if vb("wispEsp", true) then
        local wCol = vc("wispColor", COLOR_WISP)
        for _, w in ipairs(rawW) do
            if w.part and w.part.Parent then
                local sp, on = WorldToScreen(w.part.Position)
                if on then
                    local dist = math.floor(dist3(w.part.Position, myPos))
                    local gsz = clampNum(1200 / math.max(1, dist), 8, 120)
                    newSq(sp.X - gsz / 2, sp.Y - gsz / 2, gsz, gsz, wCol, false, 0, 8)
                    newTx(sp.X, sp.Y - gsz / 2 - 16, wCol, 12, w.name, true, FONT_BODY, 8)
                    newTx(sp.X, sp.Y + gsz / 2 + 2, wCol, 11, tostring(dist) .. "m", true, FONT_NUM, 8)
                end
            end
        end
    end

    local activeWisp = nil
    if wispOn then
        local wf = {
            WindWisp = vb("wispWind", true), ManaWisp = vb("wispMana", true),
            LightWisp = vb("wispLight", true), BloodWisp = vb("wispBlood", true),
        }
        local allW = {}
        for _, w in ipairs(rawW) do
            if wf[w.name] then allW[#allW + 1] = w end
        end
        if #allW > 0 then
            if now >= st.wispWaitUntil then
                if st.wispIndex > 0 then
                    st.wisps = st.wisps + 1
                    _G.__cloverWisps = st.wisps
                    local wName = allW[math.max(1, ((st.wispIndex - 1) % #allW) + 1)]
                    if vb("notifyWisp", true) then
                        hudNotify("Wisp collected", wName and wName.name or "?", COLOR_WISP)
                    end
                    if vb("whWisp", false) then
                        whPush("Wisp collected", "Wisp: **" .. tostring(wName and wName.name or "?") .. "**", COLOR_WISP)
                    end
                end
                st.wispIndex = st.wispIndex % #allW + 1
                st.wispWaitUntil = now + vn("wispWaitTime", 3) * 1000
            end
            local idx = math.max(1, ((st.wispIndex - 1) % #allW) + 1)
            local w = allW[idx]
            if w and w.part and w.part.Parent then activeWisp = w end
        else
            st.wispIndex = 0
            st.wispWaitUntil = 0
        end
    else
        st.wispIndex = 0
        st.wispWaitUntil = 0
    end

    if activeWisp then
        local wPos = activeWisp.part.Position
        tpTo(myRoot, wPos.X, wPos.Y + vn("wispHeight", 3), wPos.Z)
        applyAim(activeWisp.part, camera)
        autoClick(100, now)
        setStatus("COLLECTING", activeWisp.name)
        return
    end

    -- ores
    if oreOn or vb("oreEsp", true) then
        if now - st.oreScanAt > 5000 then
            st.oreScanAt = now
            st.oreCache = scanOres()
        end
    end
    if vb("oreEsp", true) then
        local oCol = vc("oreColor", COLOR_ORE)
        for _, o in ipairs(st.oreCache) do
            if o.part and o.part.Parent then
                local sp, on = WorldToScreen(o.part.Position)
                if on then
                    local dist = math.floor(dist3(o.part.Position, myPos))
                    local gsz = clampNum(1000 / math.max(1, dist), 6, 90)
                    newSq(sp.X - gsz / 2, sp.Y - gsz / 2, gsz, gsz, oCol, false, 0, 8)
                    newTx(sp.X, sp.Y - gsz / 2 - 14, oCol, 11, o.kind, true, FONT_BODY, 8)
                end
            end
        end
    end

    if oreOn then
        local ores = {}
        for _, o in ipairs(st.oreCache) do
            if o.part and o.part.Parent then ores[#ores + 1] = o end
        end
        local activeOre = nil
        if #ores > 0 then
            if now >= st.oreWaitUntil then
                if st.oreIndex > 0 then
                    st.ores = st.ores + 1
                    _G.__cloverOres = st.ores
                    if vb("notifyOre", false) then
                        hudNotify("Ore mined", "", COLOR_ORE)
                    end
                end
                st.oreIndex = st.oreIndex % #ores + 1
                st.oreWaitUntil = now + vn("oreWaitTime", 4) * 1000
            end
            local idx = math.max(1, ((st.oreIndex - 1) % #ores) + 1)
            activeOre = ores[idx]
        else
            st.oreIndex = 0
            st.oreWaitUntil = 0
        end
        if activeOre then
            local oPos = activeOre.part.Position
            tpTo(myRoot, oPos.X, oPos.Y + vn("oreHeight", 3), oPos.Z)
            applyAim(activeOre.part, camera)
            autoClick(150, now)
            setStatus("MINING", activeOre.kind)
            return
        end
    end

    -- rifts
    local demonRiftPart = getDemonRiftPart()
    local spiritPortalPart = getSpiritPortalPart()
    local riftCol = vc("riftColor", COLOR_RIFT)
    local spiritCol = vc("spiritColor", COLOR_SPIRIT)

    if vb("riftEsp", true) then
        for _, info in ipairs({
            { part = demonRiftPart, name = "Demon Rift", col = riftCol, on = vb("riftDemon", true) },
            { part = spiritPortalPart, name = "Spirit Portal", col = spiritCol, on = vb("riftSpirit", true) },
        }) do
            if info.on and info.part and info.part.Parent then
                local sp, on = WorldToScreen(info.part.Position)
                    if on then
                        local dist = math.floor(dist3(info.part.Position, myPos))
                        local gsz = clampNum(1600 / math.max(1, dist), 10, 160)
                        newSq(sp.X - gsz / 2, sp.Y - gsz / 2, gsz, gsz, info.col, false, 0, 8)
                        newTx(sp.X, sp.Y - gsz / 2 - 16, info.col, 12, info.name, true, FONT_BODY, 8)
                        newTx(sp.X, sp.Y + gsz / 2 + 2, info.col, 11, tostring(dist) .. "m", true, FONT_NUM, 8)
                        local vsc = camera and camera.ViewportSize or Vector2.new(1920, 1080)
                        newLn(vsc.X / 2, vsc.Y / 2, sp.X, sp.Y, info.col, 1, 8)
                    end
            end
        end
    end

    if riftOn then
        local validPortals = {}
        if vb("riftDemon", true) and demonRiftPart and demonRiftPart.Parent then
            validPortals[#validPortals + 1] = { part = demonRiftPart, name = "DEMON RIFT", color = riftCol }
        end
        if vb("riftSpirit", true) and spiritPortalPart and spiritPortalPart.Parent then
            validPortals[#validPortals + 1] = { part = spiritPortalPart, name = "SPIRIT PORTAL", color = spiritCol }
        end
        if #validPortals > 0 then
            if now >= st.portalWaitUntil then
                st.portalIndex = (st.portalIndex % #validPortals) + 1
                st.portalWaitUntil = now + vn("riftWaitTime", 5) * 1000
            end
            local idx = math.max(1, ((st.portalIndex - 1) % #validPortals) + 1)
            local tp = validPortals[idx]
            if tp and tp.part and tp.part.Parent then
                local rPos = tp.part.Position
                if rPos then
                    tpTo(myRoot, rPos.X, rPos.Y + vn("riftHeight", 3), rPos.Z)
                    setStatus("RIFT TP", tp.name)
                end
            end
            return
        end
    else
        st.portalIndex = 0
        st.portalWaitUntil = 0
    end

    -- combat defs
    local mobDefs = {
        { "Wolf", vb("mWolf"), vn("mWolf_p", 9), vn("mWolf_h", 5), vn("mWolf_o", 0) },
        { "Bandit", vb("mBandit"), vn("mBandit_p", 8), vn("mBandit_h", 5), vn("mBandit_o", 0) },
        { "Bandit Archer", vb("mBanditArcher"), vn("mBanditArcher_p", 8), vn("mBanditArcher_h", 5), vn("mBanditArcher_o", 0) },
        { "Bandit Brute", vb("mBanditBrute"), vn("mBanditBrute_p", 7), vn("mBanditBrute_h", 5), vn("mBanditBrute_o", 0) },
        { "Desert Bandit", vb("mDesertBandit"), vn("mDesertBandit_p", 8), vn("mDesertBandit_h", 5), vn("mDesertBandit_o", 0) },
        { "Alpha Desert Claw", vb("mAlphaDesertClaw"), vn("mAlphaDesertClaw_p", 6), vn("mAlphaDesertClaw_h", 5), vn("mAlphaDesertClaw_o", 0) },
        { "Stone Guardian", vb("mStoneGuardian"), vn("mStoneGuardian_p", 7), vn("mStoneGuardian_h", 5), vn("mStoneGuardian_o", 0) },
        { "Desert Claw", vb("mDesertClaw"), vn("mDesertClaw_p", 7), vn("mDesertClaw_h", 5), vn("mDesertClaw_o", 0) },
        { "Vampire Soldier", vb("mVamp"), vn("mVamp_p", 5), vn("mVamp_h", 5), vn("mVamp_o", 0) },
        { "Vampire Elite", vb("mVampElite"), vn("mVampElite_p", 5), vn("mVampElite_h", 5), vn("mVampElite_o", 0) },
        { "Shadow Hand Goon", vb("mShadowGoon"), vn("mShadowGoon_p", 5), vn("mShadowGoon_h", 5), vn("mShadowGoon_o", 0) },
        { "Lesser Devil Juggernaut", vb("mDevil"), vn("mDevil_p", 5), vn("mDevil_h", 5), vn("mDevil_o", 0) },
    }
    local bossDefs = {
        { "Terra", vb("bTerra"), vn("bTerra_p", 1), vn("bTerra_h", 5), vn("bTerra_o", 0) },
        { "Grasslands Warlord", vb("bWarlord"), vn("bWarlord_p", 1), vn("bWarlord_h", 5), vn("bWarlord_o", 0) },
        { "Aetherstone Golem", vb("bAetherGolem"), vn("bAetherGolem_p", 1), vn("bAetherGolem_h", 5), vn("bAetherGolem_o", 0) },
        { "Khamsin", vb("bKhamsin"), vn("bKhamsin_p", 1), vn("bKhamsin_h", 5), vn("bKhamsin_o", 0) },
        { "Desert Kraken", vb("bKraken"), vn("bKraken_p", 1), vn("bKraken_h", 5), vn("bKraken_o", 0) },
        { "Medusa", vb("bMedusa"), vn("bMedusa_p", 1), vn("bMedusa_h", 5), vn("bMedusa_o", 0) },
        { "Ice Golem", vb("bIceGolem"), vn("bIceGolem_p", 1), vn("bIceGolem_h", 5), vn("bIceGolem_o", 0) },
        { "Vampire Elite", vb("bVampElite"), vn("bVampElite_p", 1), vn("bVampElite_h", 5), vn("bVampElite_o", 0) },
        { "Elder Vampire", vb("bElderVamp"), vn("bElderVamp_p", 1), vn("bElderVamp_h", 5), vn("bElderVamp_o", 0) },
        { "Corrupted Elder Vampire", vb("bCorruptedElder"), vn("bCorruptedElder_p", 1), vn("bCorruptedElder_h", 5), vn("bCorruptedElder_o", 0) },
        { "Primal Werewolf", vb("bWerewolf"), vn("bWerewolf_p", 1), vn("bWerewolf_h", 5), vn("bWerewolf_o", 0) },
    }

    local want, priMap, isBossMap, heightMap, offsetMap = {}, {}, {}, {}, {}
    for _, d in ipairs(mobDefs) do
        if d[2] then
            want[#want + 1] = d[1]
            priMap[d[1]] = d[3]
            heightMap[d[1]] = d[4]
            offsetMap[d[1]] = d[5]
        end
    end
    for _, d in ipairs(bossDefs) do
        if d[2] then
            want[#want + 1] = d[1]
            isBossMap[d[1]] = true
            local ex = priMap[d[1]]
            if not ex or d[3] < ex then
                priMap[d[1]] = d[3]
                heightMap[d[1]] = d[4]
                offsetMap[d[1]] = d[5]
            end
        end
    end
    for _, n in ipairs(splitCsv(vs("mCustom", ""))) do
        want[#want + 1] = n
        priMap[n] = 5
    end

    _G.__cloverWant = want
    local maxD = vn("maxDist", 500)
    local espMaxD = vn("espMaxDist", 1000)
    local espMobCol = vb("espColMob", true) and vc("espMobCol", COLOR_MOB) or COLOR_MOB
    local espBossCol = vb("espColBoss", true) and vc("espBossCol", COLOR_BOSS) or COLOR_BOSS
    local espTgtCol = vb("espColTgt", true) and vc("espTgtCol", COLOR_TARGET) or COLOR_TARGET

    if vb("espFov", false) then
        local vsc = camera and camera.ViewportSize or Vector2.new(1920, 1080)
        newCi(vsc.X / 2, vsc.Y / 2, maxD * 0.3, espMobCol, false, 1, 8)
    end

    for name, _ in pairs(st.spawnPositions) do
        local isActive = false
        for _, w in ipairs(want) do
            if w == name then isActive = true; break end
        end
        if not isActive then st.spawnPositions[name] = nil end
    end

    if en and #want > 0 then
        for _, e in ipairs(en:GetChildren()) do
            if nameMatches(e.Name, want) and isAlive(e) then
                local a = anchorOf(e)
                local p = a and a.Position
                if p then
                    recordSpawnPos(e.Name, p)
                    local d = dist3(p, myPos)

                    if isBossMap[e.Name] and not st.seenBoss[e.Name] then
                        st.seenBoss[e.Name] = true
                        if vb("notifyBoss", true) then
                            hudNotify("Boss spawned", e.Name, COLOR_BOSS)
                        end
                        if vb("whBossSpawn", true) then
                            whPush("Boss spawned", "Boss appeared: **" .. e.Name .. "**", COLOR_BOSS)
                        end
                    end

                    if d <= espMaxD then
                        local isCur = (e == st.currentTarget)
                        local col = isCur and espTgtCol or (isBossMap[e.Name] and espBossCol or espMobCol)
                        local sp, on = WorldToScreen(p)
                        if on then
                            local style = vn("espBoxStyle", 1)
                            local hh = clampNum(3200 / math.max(1, d), 10, 420)
                            local ww = hh * 0.62
                            if vb("espBox", true) then
                                if style == 3 then
                                    local off = math.max(2, ww * 0.18)
                                    newSq(sp.X - ww / 2, sp.Y - hh / 2, ww, hh, col, false, 0, 8)
                                    newSq(sp.X - ww / 2 + off, sp.Y - hh / 2 - off, ww, hh, col, false, 0, 8)
                                else
                                    newSq(sp.X - ww / 2, sp.Y - hh / 2, ww, hh, col, false, 0, 8)
                                end
                            end
                            if vb("espName", true) then
                                newTx(sp.X, sp.Y - hh / 2 - 16, col, 12, isCur and ("> " .. e.Name) or e.Name, true, FONT_BODY, 8)
                            end
                            if vb("espDist", true) then
                                newTx(sp.X, sp.Y + hh / 2 + 2, col, 11, tostring(math.floor(d)) .. "m", true, FONT_NUM, 8)
                            end
                            if vb("espHealth", true) then
                                local h = e:FindFirstChildOfClass("Humanoid")
                                if h then
                                    local ratio = clampNum(h.Health / math.max(1, h.MaxHealth), 0, 1)
                                    local bx = sp.X - ww / 2 - 8
                                    newSq(bx, sp.Y - hh / 2, 4, hh, T.field, true, 2, 8)
                                    newSq(bx, sp.Y - hh / 2 + hh * (1 - ratio), 4, hh * ratio, T.good, true, 2, 8)
                                end
                            end
                            if vb("espSnap", false) and isCur and camera then
                                local vsc = camera.ViewportSize
                                newLn(vsc.X / 2, vsc.Y, sp.X, sp.Y, col, 1, 8)
                            end
                        end
                    end
                end
            end
        end
        for name, _ in pairs(st.seenBoss) do
            local still = false
            for _, e in ipairs(en:GetChildren()) do
                if e.Name == name and isAlive(e) then still = true; break end
            end
            if not still then st.seenBoss[name] = nil end
        end
    end

    -- target logic
    if st.currentTarget then
        if not nameMatches(st.currentTargetName, want) then
            st.currentTarget = nil
            st.currentTargetName = nil
        elseif not isAlive(st.currentTarget) then
            local dn = st.currentTargetName
            st.currentTarget = nil
            st.currentTargetName = nil
            st.kills = st.kills + 1
            _G.__cloverKills = st.kills
            if BOSS_NAMES[dn] then
                if vb("notifyBoss", true) then
                    hudNotify("Boss killed", dn or "?", T.good)
                end
                if vb("whBossKill", true) then
                    whPush("Boss killed", "Boss defeated: **" .. tostring(dn) .. "**", T.good)
                end
            end
            if vb("autoChest", true) and dn and CHEST_MAP[dn] then
                if countAliveByName(en, dn) == 0 then
                    local cp = findChestPart(dn)
                    if cp and cp.Parent then
                        st.chestTarget = cp
                        st.chestStage = "looting"
                        st.chestStartAt = now
                        st.chestDeadName = dn
                    else
                        st.chestStage = "searching"
                        st.chestDeadName = dn
                        st.chestSearchUntil = now + vn("chestSearchTime", 5) * 1000
                    end
                    return
                end
            elseif dn and BOSS_NAMES[dn] then
                st.bossKillPauseUntil = now + vn("bossKillPause", 7) * 1000
            end
        else
            if vb("smartRetarget", true) then
                local a = anchorOf(st.currentTarget)
                local p = a and a.Position
                if p and dist3(p, myPos) > maxD * vn("retargetMult", 3) then
                    st.currentTarget = nil
                    st.currentTargetName = nil
                end
            end
            if vb("antiStuck", true) and st.currentTarget then
                if now - st.stuckCheckAt > 2000 then
                    st.stuckCheckAt = now
                    if st.lastTargetPos then
                        if dist3(myPos, st.lastTargetPos) < 2 then
                            if now - st.targetLockedAt > vn("stuckTime", 10) * 1000 then
                                st.currentTarget = nil
                                st.currentTargetName = nil
                            end
                        else
                            st.targetLockedAt = now
                        end
                    end
                    st.lastTargetPos = myPos
                end
            end
        end
    end

    if not st.currentTarget then
        local best = pickTarget(en, want, priMap, maxD, myPos)
        if best then
            st.currentTarget = best
            st.currentTargetName = best.Name
            st.targetLockedAt = now
            st.lastTargetPos = myPos
            st.stuckCheckAt = now
            st.spawnCampIndex = 0
            st.spawnCampWaitUntil = 0
        end
    end
    _G.__cloverTarget = st.currentTarget

    -- tp to target
    if st.currentTarget and isAlive(st.currentTarget) then
        local a = anchorOf(st.currentTarget)
        if a then
            local p = a.Position
            if p and tpOn then
                local tpH = heightMap[st.currentTargetName] or vn("tpHeight", 5)
                local tpOff = offsetMap[st.currentTargetName] or vn("tpOffset", 0)
                if tpOff > 0 then
                    local dirX = myPos.X - p.X
                    local dirZ = myPos.Z - p.Z
                    local dirLen = math.sqrt(dirX * dirX + dirZ * dirZ)
                    if dirLen < 0.1 then
                        dirX = 1; dirZ = 0; dirLen = 1
                    end
                    dirX = (dirX / dirLen) * tpOff
                    dirZ = (dirZ / dirLen) * tpOff
                    tpTo(myRoot, p.X + dirX, p.Y + tpH, p.Z + dirZ)
                else
                    tpTo(myRoot, p.X, p.Y + tpH, p.Z)
                end
                setStatus("TP", (st.currentTargetName or "?") .. " -> combat")
            end
        end
    end

    -- auto attack
    if attackOn and st.currentTarget and isAlive(st.currentTarget) then
        local a = anchorOf(st.currentTarget)
        local p = a and a.Position
        if p and dist3(p, myPos) <= vn("attackRange", 30) then
            if vn("attackMode", 1) == 1 then
                setAttackHold(false)
                autoClick(vn("attackInterval", 100), now)
            else
                setAttackHold(true)
            end
            setStatus("ATTACKING", st.currentTargetName or "?")
        else
            setAttackHold(false)
        end
    else
        setAttackHold(false)
    end

    -- aimbot
    if aimOn then
        local aimTarget = st.currentTarget
        if not aimTarget or not isAlive(aimTarget) then
            if en then
                local bestAim, bestAimD = nil, math.huge
                for _, e in ipairs(en:GetChildren()) do
                    if nameMatches(e.Name, want) and isAlive(e) then
                        local a = anchorOf(e)
                        local p = a and a.Position
                        if p then
                            local d = dist3(p, myPos)
                            if d <= maxD and d < bestAimD then
                                bestAim, bestAimD = e, d
                            end
                        end
                    end
                end
                aimTarget = bestAim
            end
        end
        if aimTarget and isAlive(aimTarget) then
            local partNames = { "Head", "HumanoidRootPart", "Torso" }
            local partName = partNames[vn("aimPart", 1)] or "Head"
            local aimPart = aimTarget:FindFirstChild(partName)
                or aimTarget:FindFirstChild("Head")
                or aimTarget:FindFirstChild("HumanoidRootPart")
                or anchorOf(aimTarget)
            if aimPart and aimPart.Parent and camera then
                if isVisible(camera.CFrame.Position, aimPart, aimTarget) and aimFovOk(aimPart.Position, camera) then
                    applyAim(aimPart, camera)
                end
            end
        end
    end

    -- spectate
    if spectateOn and st.currentTarget and isAlive(st.currentTarget) and camera then
        local a = anchorOf(st.currentTarget)
        local p = a and a.Position
        if p then
            local back = camera.CFrame.LookVector * -12
            local camPos = p + Vector3.new(back.X, 6, back.Z)
            pcall(function() camera.CFrame = lookCF(camPos, p) end)
            setStatus("SPECTATE", st.currentTargetName or "?")
        end
    end

    -- spawn camping
    if not st.currentTarget and tpOn and vb("spawnCamp", true) then
        local spots = {}
        for name, list in pairs(st.spawnPositions) do
            local isActive = false
            for _, w in ipairs(want) do
                if w == name then isActive = true; break end
            end
            if isActive then
                for _, pos in ipairs(list) do
                    spots[#spots + 1] = { name = name, pos = pos }
                end
            end
        end
        if #spots > 0 then
            if now >= st.spawnCampWaitUntil then
                st.spawnCampIndex = st.spawnCampIndex % #spots + 1
                st.spawnCampWaitUntil = now + vn("spawnCampTime", 5) * 1000
            end
            local idx = math.max(1, ((st.spawnCampIndex - 1) % #spots) + 1)
            local spot = spots[idx]
            if spot then
                tpTo(myRoot, spot.pos.X, spot.pos.Y + vn("tpHeight", 5), spot.pos.Z)
                setStatus("CAMPING", spot.name)
            end
        end
    end

    -- webhook summary
    if vb("whSummary", false) and vs("whUrl", "") ~= "" then
        if now - st.whLastSummary > vn("whSummaryMin", 30) * 60000 then
            st.whLastSummary = now
            local sess = "0m"
            if st.sessionStart > 0 then sess = fmtTime(now - st.sessionStart) end
            whPush("Session summary", string.format(
                "Time: %s\nKills: %d\nChests: %d\nWisps: %d\nOres: %d",
                sess, st.kills, st.chests, st.wisps, st.ores), T.accent)
        end
    end
end

------------------------------------------------------------
-- FRAME LOOP
------------------------------------------------------------
local lastLayoutAt = 0
local lastLogicAt = 0

local function frame()
    local now = Now()

    pollInput()
    handleSearchTyping()
    handleUIInput()
    kbTick() -- every frame so keybind taps are never missed

    -- layout only when something actually moved/changed
    local draggingWindow = (UI.drag and UI.drag.kind == "window")
    if draggingWindow or UI.layoutDirty or (now - lastLayoutAt > 250) then
        UI.layoutDirty = false
        lastLayoutAt = now
        layout()
    end

    -- game logic at ~30Hz; UI + HUD still render at full frame rate
    if now - lastLogicAt >= 33 then
        lastLogicAt = now
        local okG, errG = pcall(doTick)
        if not okG then
            if now - lastTickErr > 5000 then
                lastTickErr = now
                warn("[Clover] tick error: " .. tostring(errG))
            end
        end
    end

    pcall(renderWindow)
    pcall(gameHud)

    poolEndFrame()
end

-- initial boot
layout()

loadSavedLocs()

RunService.RenderStepped:Connect(function()
    local ok, err = pcall(frame)
    if not ok then
        local now = Now()
        if now - lastTickErr > 5000 then
            lastTickErr = now
            warn("[Clover] frame error: " .. tostring(err))
        end
    end
end)

task.spawn(whWorker)

task.spawn(function()
    wait(1)
    hudNotify("Clover Hub v4", "press P to toggle the menu", T.accent, 5)
end)
notify("Clover Retribution Hub v4", "Menu: P key | custom INS-style UI", 5)
print("[Clover Hub] v4 loaded - custom UI, press P")
