local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer

local DEFAULT_CONFIG = {
    AutoPlant = true, AutoHarvest = true, AutoDrop = true, AutoPnb = true,
    AntiAfk = true, TeleportRange = 200, InteractRange = 12, ActionDelay = 0.25, 
    LoopDelay = 0.35, PnbHoldTime = 0.6, FarmRadius = 150, 
    PlantFilter = "plant,crop,tree,seed,sprout", DropFilter = "drop,loot,pickup,item", 
    PnbFilter = "pnb,punch,break,mine,block", WalkSpeed = 16, JumpPower = 50, 
    SpeedEnabled = false, AutoRespawn = false, Verbose = true
}

local CONFIG_PATH = "growblox_config.json"
local CONFIG = {}
for k, v in pairs(DEFAULT_CONFIG) do CONFIG[k] = v end

local function loadConfig()
    if not (readfile and isfile and isfile(CONFIG_PATH)) then return end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_PATH)) end)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do if CONFIG[k] ~= nil then CONFIG[k] = v end end
    end
end

local function saveConfig()
    if not (writefile and type(CONFIG) == "table") then return end
    pcall(function() writefile(CONFIG_PATH, HttpService:JSONEncode(CONFIG)) end)
end
loadConfig()

local state = { running = false, loopThread = nil, speedThread = nil, afkConn = nil, autoRespawnConn = nil, stats = { cycles = 0, plant = 0, harvest = 0, drop = 0, pnb = 0 }, gui = nil }

local function log(...) if CONFIG.Verbose then print("[menu]", ...) end end
local function getChar() return LP.Character or LP.CharacterAdded:Wait() end
local function getRoot() local c = LP.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum() local c = LP.Character return c and c:FindFirstChildOfClass("Humanoid") end
local function alive() local h = getHum() return h and h.Health > 0 end
local function dist(a, b) if not a or not b then return math.huge end return (a - b).Magnitude end
local function tpTo(pos) local r = getRoot() if r and pos then r.CFrame = CFrame.new(pos) end end
local function parseFilter(str) local out = {} for piece in tostring(str):gmatch("[^,]+") do local p = piece:gsub("^%s+", ""):gsub("%s+$", ""):lower() if #p > 0 then table.insert(out, p) end end return out end
local function matchesAny(name, list) local n = name:lower() for _, p in ipairs(list) do if n:find(p, 1, true) then return true end end return false end

local plantFilters, dropFilters, pnbFilters
local function refreshFilters()
    plantFilters = parseFilter(CONFIG.PlantFilter)
    dropFilters = parseFilter(CONFIG.DropFilter)
    pnbFilters = parseFilter(CONFIG.PnbFilter)
end
refreshFilters()

local function partOf(obj)
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart") end
    return obj:FindFirstChildWhichIsA("BasePart")
end

local function withinFarmRadius(part)
    if CONFIG.FarmRadius <= 0 then return true end
    local r = getRoot() if not r then return false end
    return dist(r.Position, part.Position) <= CONFIG.FarmRadius
end

local Scanner = {}
function Scanner.collect(filters)
    local out = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if (obj:IsA("Model") or obj:IsA("BasePart")) and matchesAny(obj.Name, filters) then
            local part = partOf(obj)
            if part and withinFarmRadius(part) then table.insert(out, { obj = obj, part = part }) end
        end
    end
    return out
end

function Scanner.nearest(list)
    local root = getRoot() if not root then return nil end
    local best, bestD = nil, CONFIG.TeleportRange
    for _, entry in ipairs(list) do
        local d = dist(root.Position, entry.part.Position)
        if d < bestD then best, bestD = entry, d end
    end
    return best
end

local function interact(obj)
    local part = partOf(obj) if not part then return false end
    local hit = false
    for _, pp in ipairs(obj:GetDescendants()) do
        if pp:IsA("ProximityPrompt") then
            pcall(function()
                if fireproximityprompt then fireproximityprompt(pp) else pp:InputHoldBegin() task.wait(pp.HoldDuration > 0 and pp.HoldDuration or 0.1) pp:InputHoldEnd() end
            end)
            hit = true
        end
    end
    for _, cd in ipairs(obj:GetDescendants()) do
        if cd:IsA("ClickDetector") then pcall(function() if fireclickdetector then fireclickdetector(cd) end end) hit = true end
    end
    for _, r in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if r:IsA("RemoteEvent") then
            local rn = r.Name:lower()
            if rn:find("interact") or rn:find("click") or rn:find("collect") or rn:find("plant") or rn:find("harvest") or rn:find("drop") or rn:find("hit") or rn:find("break") then
                pcall(function() r:FireServer(obj) end) hit = true
            end
        end
    end
    return hit
end

local function equipToolByKeyword(keyword)
    local char, hum, bp = getChar(), getHum(), LP:FindFirstChildOfClass("Backpack")
    if not char or not hum or not bp then return nil end
    for _, t in ipairs(char:GetChildren()) do if t:IsA("Tool") and t.Name:lower():find(keyword, 1, true) then return t end end
    for _, t in ipairs(bp:GetChildren()) do if t:IsA("Tool") and t.Name:lower():find(keyword, 1, true) then pcall(function() hum:EquipTool(t) end) return t end end
    return nil
end

local TaskPlant = { name = "plant", canRun = function() return alive() and CONFIG.AutoPlant and #Scanner.collect(plantFilters) > 0 end, run = function() local target = Scanner.nearest(Scanner.collect(plantFilters)) if not target then return false end if dist(getRoot().Position, target.part.Position) > CONFIG.InteractRange then tpTo(target.part.Position + Vector3.new(0, 3, 0)) task.wait(CONFIG.ActionDelay) end equipToolByKeyword("seed") interact(target.obj) state.stats.plant = state.stats.plant + 1 return true end }
local TaskHarvest = { name = "harvest", canRun = function() return alive() and CONFIG.AutoHarvest and #Scanner.collect(plantFilters) > 0 end, run = function() local target = Scanner.nearest(Scanner.collect(plantFilters)) if not target then return false end if dist(getRoot().Position, target.part.Position) > CONFIG.InteractRange then tpTo(target.part.Position + Vector3.new(0, 3, 0)) task.wait(CONFIG.ActionDelay) end equipToolByKeyword("harvest") interact(target.obj) state.stats.harvest = state.stats.harvest + 1 return true end }
local TaskDrop = { name = "drop", canRun = function() return alive() and CONFIG.AutoDrop and #Scanner.collect(dropFilters) > 0 end, run = function() local target = Scanner.nearest(Scanner.collect(dropFilters)) if not target then return false end if dist(getRoot().Position, target.part.Position) > CONFIG.InteractRange then tpTo(target.part.Position + Vector3.new(0, 3, 0)) task.wait(CONFIG.ActionDelay) end interact(target.obj) state.stats.drop = state.stats.drop + 1 return true end }
local TaskPnb = { name = "pnb", canRun = function() return alive() and CONFIG.AutoPnb and #Scanner.collect(pnbFilters) > 0 end, run = function() local target = Scanner.nearest(Scanner.collect(pnbFilters)) if not target then return false end if dist(getRoot().Position, target.part.Position) > CONFIG.InteractRange then tpTo(target.part.Position + Vector3.new(0, 3, 0)) task.wait(CONFIG.ActionDelay) end local hum, bp = getHum(), LP:FindFirstChildOfClass("Backpack") if hum and bp then for _, t in ipairs(bp:GetChildren()) do if t:IsA("Tool") then pcall(function() hum:EquipTool(t) end) break end end end interact(target.obj) task.wait(CONFIG.PnbHoldTime) state.stats.pnb = state.stats.pnb + 1 return true end }

local QUEUE = { TaskPlant, TaskHarvest, TaskDrop, TaskPnb }

local function mainLoop()
    while state.running do
        if not alive() then task.wait(1) else
            local acted = false
            for _, t in ipairs(QUEUE) do
                if not state.running then break end
                local ok, canRun = pcall(t.canRun)
                if ok and canRun then
                    local ran = false
                    pcall(function() ran = t.run() end)
                    if ran then state.stats.cycles = state.stats.cycles + 1 acted = true task.wait(CONFIG.ActionDelay) break end
                end
            end
            task.wait(acted and 0.1 or CONFIG.LoopDelay)
        end
    end
end

local function speedLoop()
    while state.speedThread do
        if CONFIG.SpeedEnabled and alive() then
            local hum = getHum()
            if hum then
                if math.abs(hum.WalkSpeed - CONFIG.WalkSpeed) > 1 then hum.WalkSpeed = CONFIG.WalkSpeed end
                pcall(function() hum.JumpPower = CONFIG.JumpPower hum.UseJumpPower = true end)
            end
        end
        task.wait(0.5)
    end
end

local function applyAntiAfk()
    if state.afkConn then pcall(function() state.afkConn:Disconnect() end) state.afkConn = nil end
    if CONFIG.AntiAfk then state.afkConn = LP.Idled:Connect(function() pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end) end
end

local function toggleAutoRespawn()
    if state.autoRespawnConn then pcall(function() state.autoRespawnConn:Disconnect() end) state.autoRespawnConn = nil end
    if CONFIG.AutoRespawn then state.autoRespawnConn = LP.CharacterAdded:Connect(function(char) task.wait(2) local hum = char:FindFirstChildOfClass("Humanoid") if hum and hum.Health <= 0 then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Dead) end) end end) end
end

local startBtnRef = nil
local function start() if state.running then return end state.running = true state.loopThread = task.spawn(mainLoop) if not state.speedThread then state.speedThread = task.spawn(speedLoop) end if startBtnRef then startBtnRef.Text = "STOP" startBtnRef.BackgroundColor3 = Color3.fromRGB(140, 50, 50) end end
local function stop() state.running = false state.loopThread = nil if startBtnRef then startBtnRef.Text = "START" startBtnRef.BackgroundColor3 = Color3.fromRGB(55, 135, 90) end end

local function round(parent, radius) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, radius or 8) c.Parent = parent end

local function makeButton(parent, text, color, callback, height) 
    local btn = Instance.new("TextButton") 
    btn.Size = UDim2.new(1, -8, 0, height or 34) 
    btn.BackgroundColor3 = color or Color3.fromRGB(50, 50, 65) 
    btn.BorderSizePixel = 0 
    btn.Text = text 
    btn.TextColor3 = Color3.fromRGB(235, 235, 245) 
    btn.Font = Enum.Font.GothamMedium 
    btn.TextSize = 13 
    btn.AutoButtonColor = true 
    btn.Parent = parent 
    round(btn, 6) 
    btn.MouseButton1Click:Connect(function() pcall(callback) end) 
    return btn 
end

local function makeToggle(parent, label, initial, callback) 
    local btn = Instance.new("TextButton") 
    btn.Size = UDim2.new(1, -8, 0, 34) 
    btn.BackgroundColor3 = initial and Color3.fromRGB(55, 135, 90) or Color3.fromRGB(45, 45, 60) 
    btn.BorderSizePixel = 0 
    btn.TextColor3 = Color3.fromRGB(240, 240, 250) 
    btn.Font = Enum.Font.GothamMedium 
    btn.TextSize = 13 
    btn.Text = string.format("%s  ·  %s", label, initial and "ON" or "OFF") 
    btn.Parent = parent 
    round(btn, 6) 
    local on = initial 
    btn.MouseButton1Click:Connect(function() 
        on = not on 
        btn.BackgroundColor3 = on and Color3.fromRGB(55, 135, 90) or Color3.fromRGB(45, 45, 60) 
        btn.Text = string.format("%s  ·  %s", label, on and "ON" or "OFF") 
        pcall(function() callback(on) end) 
        saveConfig() 
    end) 
    return btn 
end

-- FIX SLIDER UNTUK TOUCH HP
local function makeSlider(parent, label, min, max, initial, fmt, callback)
    local holder = Instance.new("Frame") 
    holder.Size = UDim2.new(1, -8, 0, 50) 
    holder.BackgroundColor3 = Color3.fromRGB(35, 35, 45) 
    holder.BorderSizePixel = 0 
    holder.Parent = parent 
    round(holder, 6)
    
    local lbl = Instance.new("TextLabel") 
    lbl.Size = UDim2.new(1, -12, 0, 22) 
    lbl.Position = UDim2.new(0, 6, 0, 2) 
    lbl.BackgroundTransparency = 1 
    lbl.Text = string.format("%s: %s", label, fmt(initial)) 
    lbl.TextColor3 = Color3.fromRGB(235, 235, 245) 
    lbl.Font = Enum.Font.GothamMedium 
    lbl.TextSize = 12 
    lbl.TextXAlignment = Enum.TextXAlignment.Left 
    lbl.Parent = holder
    
    local track = Instance.new("Frame") 
    track.Size = UDim2.new(1, -16, 0, 12) 
    track.Position = UDim2.new(0, 8, 0, 28) 
    track.BackgroundColor3 = Color3.fromRGB(55, 55, 70) 
    track.BorderSizePixel = 0 
    track.Parent = holder 
    round(track, 6)
    
    local fill = Instance.new("Frame") 
    fill.Size = UDim2.new((initial - min) / (max - min), 0, 1, 0) 
    fill.BackgroundColor3 = Color3.fromRGB(90, 180, 130) 
    fill.BorderSizePixel = 0 
    fill.Parent = track 
    round(fill, 6)
    
    local knob = Instance.new("Frame") 
    knob.Size = UDim2.new(0, 18, 0, 18) 
    knob.Position = UDim2.new((initial - min) / (max - min), -9, 0.5, -9) 
    knob.BackgroundColor3 = Color3.fromRGB(220, 220, 240) 
    knob.BorderSizePixel = 0 
    knob.Parent = track 
    round(knob, 9)
    
    local dragging = false
    
    local function updateFromX(px) 
        local rel = math.clamp((px - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1) 
        local val = min + rel * (max - min) 
        if max - min >= 10 then val = math.floor(val + 0.5) end 
        fill.Size = UDim2.new(rel, 0, 1, 0) 
        knob.Position = UDim2.new(rel, -9, 0.5, -9) 
        lbl.Text = string.format("%s: %s", label, fmt(val)) 
        pcall(function() callback(val) end) 
    end

    -- Deteksi sentuhan (Touch) dan Mouse
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromX(input.Position.X)
        end
    end)
    
    track.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            saveConfig()
        end
    end)
    
    UserInputService.InputChanged:Connect(function(input) 
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then 
            updateFromX(input.Position.X) 
        end 
    end)
    
    return holder
end

local function makeInput(parent, label, initial, callback, placeholder)
    local holder = Instance.new("Frame") 
    holder.Size = UDim2.new(1, -8, 0, 56) 
    holder.BackgroundColor3 = Color3.fromRGB(35, 35, 45) 
    holder.BorderSizePixel = 0 
    holder.Parent = parent 
    round(holder, 6)
    
    local lbl = Instance.new("TextLabel") 
    lbl.Size = UDim2.new(1, -12, 0, 20) 
    lbl.Position = UDim2.new(0, 6, 0, 2) 
    lbl.BackgroundTransparency = 1 
    lbl.Text = label 
    lbl.TextColor3 = Color3.fromRGB(235, 235, 245) 
    lbl.Font = Enum.Font.GothamMedium 
    lbl.TextSize = 12 
    lbl.TextXAlignment = Enum.TextXAlignment.Left 
    lbl.Parent = holder
    
    local box = Instance.new("TextBox") 
    box.Size = UDim2.new(1, -12, 0, 28) 
    box.Position = UDim2.new(0, 6, 0, 22) 
    box.BackgroundColor3 = Color3.fromRGB(25, 25, 35) 
    box.BorderSizePixel = 0 
    box.Text = initial or "" 
    box.PlaceholderText = placeholder or "" 
    box.TextColor3 = Color3.fromRGB(235, 235, 245) 
    box.Font = Enum.Font.Gotham 
    box.TextSize = 12 
    box.ClearTextOnFocus = false 
    box.Parent = holder 
    round(box, 4)
    
    box.FocusLost:Connect(function() 
        pcall(function() callback(box.Text) end) 
        saveConfig() 
    end) 
    return holder
end

local function buildGUI()
    if state.gui then state.gui:Destroy() end
    
    local screen = Instance.new("ScreenGui") 
    screen.Name = "GrowBloxMenu" 
    screen.ResetOnSpawn = false 
    screen.IgnoreGuiInset = true 
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling 
    screen.DisplayOrder = 999
    
    -- FIX UTAMA: Paksa masuk ke CoreGui atau PlayerGui dengan benar
    pcall(function() screen.Parent = CoreGui end) 
    if not screen.Parent then screen.Parent = LP:WaitForChild("PlayerGui") end
    
    local main = Instance.new("Frame") 
    main.Name = "Main" 
    main.Size = UDim2.new(0, 300, 0, 440) 
    main.Position = UDim2.new(0, 20, 0, 100) 
    main.BackgroundColor3 = Color3.fromRGB(20, 20, 28) 
    main.BorderSizePixel = 0 
    main.Active = true 
    main.Draggable = true 
    main.Parent = screen 
    round(main, 10)
    
    local stroke = Instance.new("UIStroke") 
    stroke.Color = Color3.fromRGB(90, 180, 130) 
    stroke.Thickness = 1 
    stroke.Transparency = 0.4 
    stroke.Parent = main
    
    local header = Instance.new("Frame") 
    header.Name = "Header" 
    header.Size = UDim2.new(1, 0, 0, 40) 
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 42) 
    header.BorderSizePixel = 0 
    header.Parent = main 
    round(header, 10)
    
    local title = Instance.new("TextLabel") 
    title.Size = UDim2.new(1, -80, 1, 0) 
    title.Position = UDim2.new(0, 12, 0, 0) 
    title.BackgroundTransparency = 1 
    title.Text = "GrowBlox Menu" 
    title.TextColor3 = Color3.fromRGB(235, 235, 245) 
    title.Font = Enum.Font.GothamBold 
    title.TextSize = 14 
    title.TextXAlignment = Enum.TextXAlignment.Left 
    title.Parent = header
    
    local minimizeBtn = Instance.new("TextButton") 
    minimizeBtn.Size = UDim2.new(0, 30, 0, 30) 
    minimizeBtn.Position = UDim2.new(1, -66, 0, 5) 
    minimizeBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80) 
    minimizeBtn.BorderSizePixel = 0 
    minimizeBtn.Text = "—" 
    minimizeBtn.TextColor3 = Color3.fromRGB(230, 230, 240) 
    minimizeBtn.Font = Enum.Font.GothamBold 
    minimizeBtn.TextSize = 14 
    minimizeBtn.Parent = header 
    round(minimizeBtn, 5)
    
    local closeBtn = Instance.new("TextButton") 
    closeBtn.Size = UDim2.new(0, 30, 0, 30) 
    closeBtn.Position = UDim2.new(1, -34, 0, 5) 
    closeBtn.BackgroundColor3 = Color3.fromRGB(140, 50, 50) 
    closeBtn.BorderSizePixel = 0 
    closeBtn.Text = "×" 
    closeBtn.TextColor3 = Color3.fromRGB(240, 240, 250) 
    closeBtn.Font = Enum.Font.GothamBold 
    closeBtn.TextSize = 16 
    closeBtn.Parent = header 
    round(closeBtn, 5)
    
    local body = Instance.new("ScrollingFrame") 
    body.Name = "Body" 
    body.Size = UDim2.new(1, -8, 1, -88) 
    body.Position = UDim2.new(0, 4, 0, 44) 
    body.BackgroundTransparency = 1 
    body.BorderSizePixel = 0 
    body.ScrollBarThickness = 4 
    body.ScrollBarImageColor3 = Color3.fromRGB(90, 180, 130) 
    body.CanvasSize = UDim2.new(0, 0, 0, 0) 
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y 
    body.Parent = main
    
    local layout = Instance.new("UIListLayout") 
    layout.Padding = UDim.new(0, 6) 
    layout.SortOrder = Enum.SortOrder.LayoutOrder 
    layout.Parent = body
    
    local bottomBar = Instance.new("Frame") 
    bottomBar.Size = UDim2.new(1, -8, 0, 40) 
    bottomBar.Position = UDim2.new(0, 4, 1, -42) 
    bottomBar.BackgroundTransparency = 1 
    bottomBar.Parent = main
    
    local startBtn = makeButton(bottomBar, "START", Color3.fromRGB(55, 135, 90), function() if state.running then stop() else start() end, 36) 
    startBtn.Size = UDim2.new(0.5, -4, 1, 0) 
    startBtn.Position = UDim2.new(0, 0, 0, 0) 
    startBtnRef = startBtn
    
    local statsBtn = makeButton(bottomBar, "STATS", Color3.fromRGB(60, 60, 80), function() 
        local s = state.stats 
        print(string.format("cycles=%d plant=%d harvest=%d drop=%d pnb=%d", s.cycles, s.plant, s.harvest, s.drop, s.pnb)) 
        statsBtn.Text = "check log" 
        task.wait(1.5) 
        statsBtn.Text = "STATS" 
    end, 36) 
    statsBtn.Size = UDim2.new(0.5, -4, 1, 0) 
    statsBtn.Position = UDim2.new(0.5, 4, 0, 0)
    
    minimizeBtn.MouseButton1Click:Connect(function() 
        if body.Visible then 
            body.Visible = false 
            main.Size = UDim2.new(0, 300, 0, 44) 
            minimizeBtn.Text = "+" 
        else 
            body.Visible = true 
            main.Size = UDim2.new(0, 300, 0, 440) 
            minimizeBtn.Text = "—" 
        end 
    end)
    
    closeBtn.MouseButton1Click:Connect(function() 
        stop() 
        screen:Destroy() 
        state.gui = nil 
    end)
    
    local function section(text) 
        local f = Instance.new("Frame") 
        f.Size = UDim2.new(1, -8, 0, 24) 
        f.BackgroundTransparency = 1 
        f.Parent = body 
        local l = Instance.new("TextLabel") 
        l.Size = UDim2.new(1, 0, 1, 0) 
        l.BackgroundTransparency = 1 
        l.Text = "  " .. text 
        l.TextColor3 = Color3.fromRGB(120, 200, 150) 
        l.Font = Enum.Font.GothamBold 
        l.TextSize = 11 
        l.TextXAlignment = Enum.TextXAlignment.Left 
        l.Parent = f 
        return f 
    end
    
    section("PRIORITY TASKS")
    makeToggle(body, "Auto Plant", CONFIG.AutoPlant, function(v) CONFIG.AutoPlant = v end)
    makeToggle(body, "Auto Harvest", CONFIG.AutoHarvest, function(v) CONFIG.AutoHarvest = v end)
    makeToggle(body, "Auto Drop", CONFIG.AutoDrop, function(v) CONFIG.AutoDrop = v end)
    makeToggle(body, "Auto PNB", CONFIG.AutoPnb, function(v) CONFIG.AutoPnb = v end)
    
    section("TIMING")
    makeSlider(body, "Teleport Range", 30, 800, CONFIG.TeleportRange, function(v) return tostring(math.floor(v)) .. " studs" end, function(v) CONFIG.TeleportRange = math.floor(v) end)
    makeSlider(body, "Interact Range", 4, 30, CONFIG.InteractRange, function(v) return tostring(math.floor(v)) .. " studs" end, function(v) CONFIG.InteractRange = math.floor(v) end)
    makeSlider(body, "Farm Radius", 0, 500, CONFIG.FarmRadius, function(v) return v <= 0 and "unlimited" or (tostring(math.floor(v)) .. " studs") end, function(v) CONFIG.FarmRadius = math.floor(v) end)
    makeSlider(body, "Action Delay", 0.05, 1.5, CONFIG.ActionDelay, function(v) return string.format("%.2fs", v) end, function(v) CONFIG.ActionDelay = v end)
    makeSlider(body, "Loop Delay", 0.1, 2.0, CONFIG.LoopDelay, function(v) return string.format("%.2fs", v) end, function(v) CONFIG.LoopDelay = v end)
    makeSlider(body, "PNB Hold", 0.1, 3.0, CONFIG.PnbHoldTime, function(v) return string.format("%.2fs", v) end, function(v) CONFIG.PnbHoldTime = v end)
    
    section("PLAYER")
    makeToggle(body, "Speed Hack", CONFIG.SpeedEnabled, function(v) CONFIG.SpeedEnabled = v end)
    makeSlider(body, "WalkSpeed", 16, 200, CONFIG.WalkSpeed, function(v) return tostring(math.floor(v)) end, function(v) CONFIG.WalkSpeed = math.floor(v) end)
    makeSlider(body, "JumpPower", 50, 300, CONFIG.JumpPower, function(v) return tostring(math.floor(v)) end, function(v) CONFIG.JumpPower = math.floor(v) end)
    makeToggle(body, "Anti AFK", CONFIG.AntiAfk, function(v) CONFIG.AntiAfk = v applyAntiAfk() end)
    makeToggle(body, "Auto Respawn", CONFIG.AutoRespawn, function(v) CONFIG.AutoRespawn = v toggleAutoRespawn() end)
    
    section("FILTERS")
    makeInput(body, "Plant Keywords", CONFIG.PlantFilter, function(v) CONFIG.PlantFilter = v refreshFilters() end, "plant,crop,tree,seed")
    makeInput(body, "Drop Keywords", CONFIG.DropFilter, function(v) CONFIG.DropFilter = v refreshFilters() end, "drop,loot,pickup")
    makeInput(body, "PNB Keywords", CONFIG.PnbFilter, function(v) CONFIG.PnbFilter = v refreshFilters() end, "pnb,punch,break,mine")
    
    section("MISC")
    makeToggle(body, "Verbose Log", CONFIG.Verbose, function(v) CONFIG.Verbose = v end)
    makeButton(body, "Reset Config", Color3.fromRGB(90, 60, 60), function() for k, v in pairs(DEFAULT_CONFIG) do CONFIG[k] = v end refreshFilters() saveConfig() buildGUI() end)
    makeButton(body, "Destroy GUI", Color3.fromRGB(120, 50, 50), function() stop() screen:Destroy() state.gui = nil end)
    
    state.gui = screen
    applyAntiAfk()
end

buildGUI()
print("[GrowBlox] Mod Menu Loaded!")