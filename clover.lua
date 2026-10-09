------------------------------------------------------------
--  CLOVER RETRIBUTION — ULTIMATE HUB (INS UI EDITION)
--  Executor: Matcha Lua
--  UI Library: INS-ui (Insignificant UI)
------------------------------------------------------------

-- Services
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local UserInput     = game:GetService("UserInputService")
local TweenService  = game:GetService("TweenService")
local Workspace     = game:GetService("Workspace")

local LocalPlayer   = Players.LocalPlayer
local Camera        = Workspace.CurrentCamera

------------------------------------------------------------
-- 1. LOAD UI LIBRARY (INS-ui)
------------------------------------------------------------
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/source.lua"))()

------------------------------------------------------------
-- 2. STATE & CONFIGURATION
------------------------------------------------------------
local CONFIG_FILE = "clover_ins_config.json"

local State = {
    -- Auto Farm
    Farm_Enabled   = false,
    Farm_Mobs      = true,
    Farm_Bosses    = false,
    Farm_Range     = 1500,
    Farm_Speed     = 75,

    -- ESP
    ESP_Players    = false,
    ESP_Mobs       = false,
    ESP_Bosses     = false,
    ESP_Drops      = false,
    ESP_Boxes      = true,
    ESP_Tracers    = false,
    ESP_HealthBars = true,
    ESP_Nametags   = true,

    -- Movement
    Fly_Enabled    = false,
    Fly_Speed      = 50,
    Speed_Enabled  = false,
    Speed_Value    = 45,
    Noclip_Enabled = false,

    -- Auto Collect
    Collect_Enabled = false,
    Collect_Range   = 400,
}

local PATHS = {
    MobsFolder    = "Mobs",
    BossesFolder  = "Bosses",
    DropsFolder   = "Drops",
}

local Drawings = {}
local Connections = {}
local flyVelocity = Vector3.zero

------------------------------------------------------------
-- 3. PERSISTENT SAVE/LOAD SYSTEM
------------------------------------------------------------
local function SaveConfig()
    local ok, encoded = pcall(function()
        local str = "{"
        local first = true
        for k, v in pairs(State) do
            if not first then str = str .. "," end
            first = false
            if type(v) == "string" then
                str = str .. '"' .. k .. '":"' .. v .. '"'
            elseif type(v) == "boolean" then
                str = str .. '"' .. k .. '":' .. tostring(v)
            elseif type(v) == "number" then
                str = str .. '"' .. k .. '":' .. tostring(v)
            end
        end
        str = str .. "}"
        return str
    end)
    if ok and encoded then
        pcall(writefile, CONFIG_FILE, encoded)
    end
end

local function LoadConfig()
    if not isfile(CONFIG_FILE) then return end
    local ok, data = pcall(readfile, CONFIG_FILE)
    if not ok or not data then return end

    for key, val in string.gmatch(data, '"(%w+)":([^,}]+)') do
        val = string.gsub(val, '"', '')
        if val == "true" then
            State[key] = true
        elseif val == "false" then
            State[key] = false
        elseif tonumber(val) then
            State[key] = tonumber(val)
        else
            State[key] = val
        end
    end
end

LoadConfig()

------------------------------------------------------------
-- 4. UTILITY FUNCTIONS
------------------------------------------------------------
local function GetCharacter()
    return LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
end

local function GetRoot()
    local char = GetCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function GetHumanoid()
    local char = GetCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function WorldToScreen(pos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

local function GetDistance(pos1, pos2)
    return (pos1 - pos2).Magnitude
end

local function ClearDrawings()
    for _, d in pairs(Drawings) do
        if d and d.Remove then
            pcall(function() d:Remove() end)
        end
    end
    Drawings = {}
end

local function CreateDrawing(type, props)
    local d = Drawing.new(type)
    for k, v in pairs(props) do
        pcall(function() d[k] = v end)
    end
    table.insert(Drawings, d)
    return d
end

------------------------------------------------------------
-- 5. ESP & RENDER ENGINE (Drawing API)
------------------------------------------------------------
local function DrawESP_Box(part, color, thickness)
    if not part or not part.Parent then return end
    local pos, onScreen, depth = WorldToScreen(part.Position)
    if not onScreen or depth < 0 then return end

    local size = part.Size
    local factor = 1 / (depth * math.tan(math.rad(Camera.FieldOfView / 2)) * 2) * 1000
    local w = math.clamp(size.X * factor, 10, 500)
    local h = math.clamp(size.Y * factor, 10, 800)

    CreateDrawing("Square", {
        Size      = Vector2.new(w, h),
        Position  = Vector2.new(pos.X - w / 2, pos.Y - h / 2),
        Color     = color,
        Thickness = thickness or 1,
        Filled    = false,
        Visible   = true,
    })
end

local function DrawESP_Text(part, text, color, offsetY)
    if not part or not part.Parent then return end
    local pos, onScreen, depth = WorldToScreen(part.Position)
    if not onScreen or depth < 0 then return end

    CreateDrawing("Text", {
        Text     = text,
        Position = Vector2.new(pos.X, pos.Y + (offsetY or -35)),
        Color    = color,
        Size     = 13,
        Center   = true,
        Outline  = true,
        Visible  = true,
    })
end

local function DrawESP_Tracer(part, color)
    if not part or not part.Parent then return end
    local pos, onScreen, depth = WorldToScreen(part.Position)
    if not onScreen or depth < 0 then return end

    CreateDrawing("Line", {
        From      = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y),
        To        = pos,
        Color     = color,
        Thickness = 1,
        Visible   = true,
    })
end

local function DrawESP_HealthBar(humanoid, part, height)
    if not humanoid or not part or not part.Parent then return end
    local pos, onScreen, depth = WorldToScreen(part.Position)
    if not onScreen or depth < 0 then return end

    local factor = 1 / (depth * math.tan(math.rad(Camera.FieldOfView / 2)) * 2) * 1000
    local h = math.clamp((height or 6) * factor, 20, 600)
    local ratio = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)

    CreateDrawing("Square", {
        Size     = Vector2.new(3, h),
        Position = Vector2.new(pos.X - 25, pos.Y - h / 2),
        Color    = Color3.fromRGB(50, 50, 50),
        Filled   = true,
        Visible  = true,
    })

    local hpColor = Color3.fromRGB(math.floor(255 * (1 - ratio)), math.floor(255 * ratio), 0)
    CreateDrawing("Square", {
        Size     = Vector2.new(3, h * ratio),
        Position = Vector2.new(pos.X - 25, pos.Y - h / 2 + h * (1 - ratio)),
        Color    = hpColor,
        Filled   = true,
        Visible  = true,
    })
end

local function ESP_Loop()
    ClearDrawings()

    -- 1. Players
    if State.ESP_Players then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local char = player.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                local hum  = char and char:FindFirstChildOfClass("Humanoid")

                if root and hum and hum.Health > 0 then
                    local color = player.TeamColor and player.TeamColor.Color or Color3.fromRGB(255, 255, 255)
                    if State.ESP_Boxes then DrawESP_Box(root, color, 1.5) end
                    if State.ESP_Nametags then DrawESP_Text(root, player.Name, color, -40) end
                    if State.ESP_Tracers then DrawESP_Tracer(root, color) end
                    if State.ESP_HealthBars then DrawESP_HealthBar(hum, root, 6) end
                end
            end
        end
    end

    -- 2. Mobs
    if State.ESP_Mobs then
        local mobFolder = Workspace:FindFirstChild(PATHS.MobsFolder)
        if mobFolder then
            for _, mob in ipairs(mobFolder:GetChildren()) do
                local root = mob:FindFirstChild("HumanoidRootPart") or mob:FindFirstChildWhichIsA("BasePart")
                local hum  = mob:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    local color = Color3.fromRGB(255, 170, 0)
                    if State.ESP_Boxes then DrawESP_Box(root, color, 1) end
                    if State.ESP_Nametags then DrawESP_Text(root, mob.Name, color, -35) end
                    if State.ESP_HealthBars then DrawESP_HealthBar(hum, root, 5) end
                end
            end
        end
    end

    -- 3. Bosses
    if State.ESP_Bosses then
        local bossFolder = Workspace:FindFirstChild(PATHS.BossesFolder)
        if bossFolder then
            for _, boss in ipairs(bossFolder:GetChildren()) do
                local root = boss:FindFirstChild("HumanoidRootPart") or boss:FindFirstChildWhichIsA("BasePart")
                local hum  = boss:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    local color = Color3.fromRGB(255, 0, 75)
                    if State.ESP_Boxes then DrawESP_Box(root, color, 2) end
                    if State.ESP_Nametags then DrawESP_Text(root, "[BOSS] " .. boss.Name, color, -45) end
                    if State.ESP_Tracers then DrawESP_Tracer(root, color) end
                    if State.ESP_HealthBars then DrawESP_HealthBar(hum, root, 7) end
                end
            end
        end
    end

    -- 4. Drops
    if State.ESP_Drops then
        local dropFolder = Workspace:FindFirstChild(PATHS.DropsFolder)
        if dropFolder then
            for _, drop in ipairs(dropFolder:GetChildren()) do
                local part = drop:IsA("BasePart") and drop or drop:FindFirstChildWhichIsA("BasePart")
                if part then
                    DrawESP_Text(part, drop.Name, Color3.fromRGB(0, 255, 200), -20)
                end
            end
        end
    end
end

------------------------------------------------------------
-- 6. GAMEPLAY FEATUES (Farm, Flight, Noclip, Collect)
------------------------------------------------------------
local function FindNearestFarmTarget()
    local myRoot = GetRoot()
    if not myRoot then return nil end

    local bestTarget, bestDist = nil, State.Farm_Range

    if State.Farm_Bosses then
        local bossFolder = Workspace:FindFirstChild(PATHS.BossesFolder)
        if bossFolder then
            for _, boss in ipairs(bossFolder:GetChildren()) do
                local root = boss:FindFirstChild("HumanoidRootPart") or boss:FindFirstChildWhichIsA("BasePart")
                local hum  = boss:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    local d = GetDistance(myRoot.Position, root.Position)
                    if d < bestDist then
                        bestDist = d
                        bestTarget = root
                    end
                end
            end
        end
    end

    if not bestTarget and State.Farm_Mobs then
        local mobFolder = Workspace:FindFirstChild(PATHS.MobsFolder)
        if mobFolder then
            for _, mob in ipairs(mobFolder:GetChildren()) do
                local root = mob:FindFirstChild("HumanoidRootPart") or mob:FindFirstChildWhichIsA("BasePart")
                local hum  = mob:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    local d = GetDistance(myRoot.Position, root.Position)
                    if d < bestDist then
                        bestDist = d
                        bestTarget = root
                    end
                end
            end
        end
    end

    return bestTarget
end

local function AutoFarm_Loop(dt)
    if not State.Farm_Enabled then return end

    local myRoot = GetRoot()
    if not myRoot then return end

    local target = FindNearestFarmTarget()
    if not target then return end

    local dir = (target.Position - myRoot.Position)
    if dir.Magnitude > 4 then
        local speed = State.Farm_Speed * dt
        local step = math.min(speed, dir.Magnitude)
        myRoot.CFrame = myRoot.CFrame + dir.Unit * step
        myRoot.AssemblyLinearVelocity = Vector3.zero
    end
end

local function Movement_Loop(dt)
    local myRoot = GetRoot()
    local hum = GetHumanoid()
    if not myRoot or not hum then return end

    -- Speed Hack
    if State.Speed_Enabled then
        hum.WalkSpeed = State.Speed_Value
    else
        hum.WalkSpeed = 16
    end

    -- Noclip
    if State.Noclip_Enabled or State.Fly_Enabled or State.Farm_Enabled then
        local char = GetCharacter()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = false
                end
            end
        end
    end

    -- Smooth Fly
    if State.Fly_Enabled then
        local camCF = Camera.CFrame
        local moveDir = Vector3.zero

        if UserInput:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + camCF.LookVector end
        if UserInput:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - camCF.LookVector end
        if UserInput:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - camCF.RightVector end
        if UserInput:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + camCF.RightVector end
        if UserInput:IsKeyDown(Enum.KeyCode.Space) then moveDir = moveDir + Vector3.new(0, 1, 0) end
        if UserInput:IsKeyDown(Enum.KeyCode.LeftShift) then moveDir = moveDir - Vector3.new(0, 1, 0) end

        if moveDir.Magnitude > 0 then moveDir = moveDir.Unit end

        local targetVel = moveDir * State.Fly_Speed
        flyVelocity = flyVelocity:Lerp(targetVel, math.clamp(dt * 10, 0, 1))

        myRoot.AssemblyLinearVelocity = flyVelocity
        myRoot.CFrame = CFrame.new(myRoot.Position, myRoot.Position + camCF.LookVector)
    else
        flyVelocity = Vector3.zero
    end
end

local function AutoCollect_Loop(dt)
    if not State.Collect_Enabled then return end

    local myRoot = GetRoot()
    if not myRoot then return end

    local dropFolder = Workspace:FindFirstChild(PATHS.DropsFolder)
    if not dropFolder then return end

    for _, drop in ipairs(dropFolder:GetChildren()) do
        local part = drop:IsA("BasePart") and drop or drop:FindFirstChildWhichIsA("BasePart")
        if part then
            local d = GetDistance(myRoot.Position, part.Position)
            if d < State.Collect_Range then
                -- Fire Interactions
                local prompt = drop:FindFirstChildOfClass("ProximityPrompt")
                if prompt then pcall(fireproximityprompt, prompt) end
                
                pcall(firetouchinterest, myRoot, part, 0)
                pcall(firetouchinterest, myRoot, part, 1)
            end
        end
    end
end

------------------------------------------------------------
-- 7. INITIALIZE INS UI WINDOW & TABS
------------------------------------------------------------
local Window = Library:CreateWindow({
    Name = "Clover Retribution - Ultimate Hub",
    Theme = "Dark"
})

-- TAB 1: Auto Farm
local TabFarm = Window:CreateTab("Auto Farm")
local SecFarm = TabFarm:CreateSection("Farm Controls")

SecFarm:CreateToggle("Enable Auto Farm", State.Farm_Enabled, function(val)
    State.Farm_Enabled = val
    SaveConfig()
end)

SecFarm:CreateToggle("Target Mobs", State.Farm_Mobs, function(val)
    State.Farm_Mobs = val
    SaveConfig()
end)

SecFarm:CreateToggle("Target Bosses", State.Farm_Bosses, function(val)
    State.Farm_Bosses = val
    SaveConfig()
end)

SecFarm:CreateSlider("Farm Range", 100, 5000, State.Farm_Range, function(val)
    State.Farm_Range = val
    SaveConfig()
end)

SecFarm:CreateSlider("Farm Speed", 10, 150, State.Farm_Speed, function(val)
    State.Farm_Speed = val
    SaveConfig()
end)


-- TAB 2: ESP (Visuals)
local TabESP = Window:CreateTab("Visuals (ESP)")
local SecESP = TabESP:CreateSection("ESP Options")

SecESP:CreateToggle("Show Players", State.ESP_Players, function(val)
    State.ESP_Players = val
    SaveConfig()
end)

SecESP:CreateToggle("Show Mobs", State.ESP_Mobs, function(val)
    State.ESP_Mobs = val
    SaveConfig()
end)

SecESP:CreateToggle("Show Bosses", State.ESP_Bosses, function(val)
    State.ESP_Bosses = val
    SaveConfig()
end)

SecESP:CreateToggle("Show Drops", State.ESP_Drops, function(val)
    State.ESP_Drops = val
    SaveConfig()
end)

local SecESP_Visuals = TabESP:CreateSection("Visual Settings")

SecESP_Visuals:CreateToggle("Boxes", State.ESP_Boxes, function(val)
    State.ESP_Boxes = val
    SaveConfig()
end)

SecESP_Visuals:CreateToggle("Health Bars", State.ESP_HealthBars, function(val)
    State.ESP_HealthBars = val
    SaveConfig()
end)

SecESP_Visuals:CreateToggle("Nametags", State.ESP_Nametags, function(val)
    State.ESP_Nametags = val
    SaveConfig()
end)

SecESP_Visuals:CreateToggle("Tracers", State.ESP_Tracers, function(val)
    State.ESP_Tracers = val
    SaveConfig()
end)


-- TAB 3: Movement
local TabMove = Window:CreateTab("Movement")
local SecFly = TabMove:CreateSection("Flight")

SecFly:CreateToggle("Enable Fly", State.Fly_Enabled, function(val)
    State.Fly_Enabled = val
    SaveConfig()
end)

SecFly:CreateSlider("Fly Speed", 10, 200, State.Fly_Speed, function(val)
    State.Fly_Speed = val
    SaveConfig()
end)

local SecSpeed = TabMove:CreateSection("Speed Hack")

SecSpeed:CreateToggle("Enable WalkSpeed Adjust", State.Speed_Enabled, function(val)
    State.Speed_Enabled = val
    SaveConfig()
end)

SecSpeed:CreateSlider("WalkSpeed Value", 16, 250, State.Speed_Value, function(val)
    State.Speed_Value = val
    SaveConfig()
end)

local SecNoclip = TabMove:CreateSection("Noclip")

SecNoclip:CreateToggle("Enable Noclip", State.Noclip_Enabled, function(val)
    State.Noclip_Enabled = val
    SaveConfig()
end)


-- TAB 4: Auto Collect
local TabCollect = Window:CreateTab("Auto Collect")
local SecCollect = TabCollect:CreateSection("Item Collector")

SecCollect:CreateToggle("Enable Auto Collect Drops", State.Collect_Enabled, function(val)
    State.Collect_Enabled = val
    SaveConfig()
end)

SecCollect:CreateSlider("Collection Range", 50, 1500, State.Collect_Range, function(val)
    State.Collect_Range = val
    SaveConfig()
end)


-- TAB 5: Config & Settings
local TabSettings = Window:CreateTab("Settings")
local SecConfig = TabSettings:CreateSection("Config Management")

SecConfig:CreateButton("Force Save Config", function()
    SaveConfig()
    Library:Notify("Success", "Configuration successfully saved to local storage!", 3)
end)

SecConfig:CreateButton("Unload Cheat Hub", function()
    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    ClearDrawings()
    Library:Destroy()
end)

------------------------------------------------------------
-- 8. START ENGINE (RunService)
------------------------------------------------------------
local HeartbeatConn = RunService.Heartbeat:Connect(function(dt)
    pcall(ESP_Loop)
    pcall(AutoFarm_Loop, dt)
    pcall(Movement_Loop, dt)
    pcall(AutoCollect_Loop, dt)
end)
table.insert(Connections, HeartbeatConn)

Library:Notify("Clover Retribution", "Ultimate INS Hub Successfully Loaded!", 4)
