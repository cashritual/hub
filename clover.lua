------------------------------------------------------------
--  CLOVER RETRIBUTION — ULTIMATE HUB (FIXED UI)
--  Executor: Matcha Lua
------------------------------------------------------------

-- 1. ЗАГРУЗКА БИБЛИОТЕКИ С ПРОВЕРКОЙ (Исправленная ссылка)
local function GetLibrary()
    local success, result = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/INS%20UI.lua"))()
    end)
    if success and result then
        return result
    else
        warn("Failed to load INS-ui! Error: " .. tostring(result))
        -- Резервная загрузка другой версии если автор переименовал файл
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/source.lua"))()
    end
end

local Library = GetLibrary()

-- Если библиотека всё равно не загрузилась, останавливаем скрипт
if not Library then 
    print("CRITICAL ERROR: UI Library not found (404). Check links.")
    return 
end

-- Services
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local UserInput     = game:GetService("UserInputService")
local TweenService  = game:GetService("TweenService")
local Workspace     = game:GetService("Workspace")

local LocalPlayer   = Players.LocalPlayer
local Camera        = Workspace.CurrentCamera

------------------------------------------------------------
-- 2. CONFIG & STATE
------------------------------------------------------------
local CONFIG_FILE = "clover_ins_config.json"
local State = {
    Farm_Enabled   = false,
    Farm_Mobs      = true,
    Farm_Bosses    = false,
    Farm_Range     = 1500,
    Farm_Speed     = 75,
    ESP_Players    = false,
    ESP_Mobs       = false,
    ESP_Bosses     = false,
    ESP_Drops      = false,
    ESP_Boxes      = true,
    ESP_HealthBars = true,
    ESP_Nametags   = true,
    Fly_Enabled    = false,
    Fly_Speed      = 50,
    Speed_Enabled  = false,
    Speed_Value    = 45,
    Collect_Enabled = false,
}

local PATHS = { MobsFolder = "Mobs", BossesFolder = "Bosses", DropsFolder = "Drops" }
local Drawings, Connections = {}, {}
local flyVelocity = Vector3.zero

------------------------------------------------------------
-- 3. UTILITIES
------------------------------------------------------------
local function GetRoot() return LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") end
local function GetHumanoid() return LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") end
local function GetDistance(p1, p2) return (p1 - p2).Magnitude end

local function ClearDrawings()
    for _, d in pairs(Drawings) do pcall(function() d:Remove() end) end
    Drawings = {}
end

local function CreateDrawing(type, props)
    local d = Drawing.new(type)
    for k, v in pairs(props) do d[k] = v end
    table.insert(Drawings, d)
    return d
end

------------------------------------------------------------
-- 4. ESP ENGINE
------------------------------------------------------------
local function ESP_Loop()
    ClearDrawings()
    if not (State.ESP_Players or State.ESP_Mobs or State.ESP_Bosses or State.ESP_Drops) then return end

    local function DrawTag(obj, text, color, offset)
        local pos, onScreen = Camera:WorldToViewportPoint(obj.Position)
        if onScreen then
            CreateDrawing("Text", {
                Text = text, Position = Vector2.new(pos.X, pos.Y + offset),
                Color = color, Size = 13, Center = true, Outline = true, Visible = true
            })
        end
    end

    if State.ESP_Players then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                DrawTag(p.Character.HumanoidRootPart, p.Name, Color3.new(1,1,1), -40)
            end
        end
    end

    if State.ESP_Mobs then
        local folder = Workspace:FindFirstChild(PATHS.MobsFolder)
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                local root = m:FindFirstChild("HumanoidRootPart") or m:FindFirstChildWhichIsA("BasePart")
                if root then DrawTag(root, m.Name, Color3.fromRGB(255, 170, 0), -35) end
            end
        end
    end
end

------------------------------------------------------------
-- 5. MOVEMENT & FARM
------------------------------------------------------------
local function Movement_Loop(dt)
    local root = GetRoot()
    local hum = GetHumanoid()
    if not root or not hum then return end

    if State.Speed_Enabled then hum.WalkSpeed = State.Speed_Value else hum.WalkSpeed = 16 end

    if State.Fly_Enabled then
        local camCF = Camera.CFrame
        local moveDir = Vector3.zero
        if UserInput:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + camCF.LookVector end
        if UserInput:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - camCF.LookVector end
        if UserInput:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - camCF.RightVector end
        if UserInput:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + camCF.RightVector end
        if moveDir.Magnitude > 0 then moveDir = moveDir.Unit end
        
        root.AssemblyLinearVelocity = moveDir * State.Fly_Speed
        root.CFrame = CFrame.new(root.Position, root.Position + camCF.LookVector)
    end
end

------------------------------------------------------------
-- 6. UI INITIALIZATION (INS-ui)
------------------------------------------------------------
local Window = Window or Library:CreateWindow({
    Name = "Clover Hub - Matcha Edition",
    Theme = "Dark"
})

local TabFarm = Window:CreateTab("Combat")
local SecFarm = TabFarm:CreateSection("Auto Farm")

SecFarm:CreateToggle("Enable Farm", State.Farm_Enabled, function(v) State.Farm_Enabled = v end)
SecFarm:CreateSlider("Range", 100, 5000, State.Farm_Range, function(v) State.Farm_Range = v end)

local TabESP = Window:CreateTab("Visuals")
local SecESP = TabESP:CreateSection("ESP")
SecESP:CreateToggle("Player ESP", State.ESP_Players, function(v) State.ESP_Players = v end)
SecESP:CreateToggle("Mob ESP", State.ESP_Mobs, function(v) State.ESP_Mobs = v end)

local TabMove = Window:CreateTab("Movement")
local SecFly = TabMove:CreateSection("Fly")
SecFly:CreateToggle("Enable Fly", State.Fly_Enabled, function(v) State.Fly_Enabled = v end)
SecFly:CreateSlider("Fly Speed", 10, 200, State.Fly_Speed, function(v) State.Fly_Speed = v end)

------------------------------------------------------------
-- 7. RUN ENGINE
------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
    pcall(ESP_Loop)
    pcall(Movement_Loop, dt)
end)

Library:Notify("Success", "Clover Hub Loaded!", 3)
