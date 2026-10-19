-- record_gilded_skies.lua
-- Recorder for Dungeon Quest "Gilded Skies" runs.
-- Usage:
-- 1) In-game run: loadstring(game:HttpGet("https://raw.githubusercontent.com/DeltaDevOS/Isnwowoanso9191/gilded-skies-recorder/record_gilded_skies.lua"))()
-- 2) Toggle the on-screen "Start Record" button before entering the dungeon. Toggle again to stop and save the JSON.
--
-- The script samples:
--  - player position
--  - nearby models with Humanoids (name, position, health)
--  - BaseParts whose name contains common telegraph/aoe hints ("aoe", "tele", "circle", "hit")
-- It attempts multiple save methods (writefile variants, setclipboard, print) and notifies you of where the data landed.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- CONFIG
local SAMPLE_INTERVAL = 0.2 -- seconds between samples (0.1-0.3 recommended)
local MAX_SAMPLES = 25000 -- safety cap to avoid runaway files
local FILENAME = "gilded_skies_run_" .. os.date("%Y%m%d_%H%M%S") .. ".json"

-- STORAGE
local recording = false
local samples = {}
local meta = {
    mapName = nil, -- optional: fill in if known at runtime
    startedAt = nil,
    stoppedAt = nil,
    executor = "unknown"
}

-- executor detection (try common globals/objects)
local function detectExecutor()
    local exec = "unknown"
    local ok, _ = pcall(function()
        if type(writefile) == "function" then exec = exec .. " writefile" end
        if type(setclipboard) == "function" then exec = exec .. " setclipboard" end
        if syn and type(syn.write_file) == "function" then exec = exec .. " syn.write_file" end
        if syn and type(syn.set_clipboard) == "function" then exec = exec .. " syn.set_clipboard" end
        -- delta executor heuristics
        if type(delta) == "table" or type(Delta) == "table" or type(_G.DELTA) ~= "nil" then
            exec = exec .. " delta"
        end
    end)
    exec = exec:gsub("^ ", "")
    if exec == "" then exec = "unknown" end
    return exec
end

meta.executor = detectExecutor()

-- utilities: safe write/copy
local function try_writefile(name, content)
    local ok, err
    if type(writefile) == "function" then
        ok, err = pcall(function() writefile(name, content) end)
        if ok then return true, "writefile" end
    end
    if syn and type(syn.write_file) == "function" then
        ok, err = pcall(function() syn.write_file(name, content) end)
        if ok then return true, "syn.write_file" end
    end
    -- delta-specific: try common lowercase/uppercase variants
    if type(delta) == "table" and type(delta.writefile) == "function" then
        ok, err = pcall(function() delta.writefile(name, content) end)
        if ok then return true, "delta.writefile" end
    end
    if type(Delta) == "table" and type(Delta.writefile) == "function" then
        ok, err = pcall(function() Delta.writefile(name, content) end)
        if ok then return true, "Delta.writefile" end
    end
    return false, nil
end

local function try_setclipboard(text)
    if type(setclipboard) == "function" then
        local ok = pcall(function() setclipboard(text) end)
        if ok then return true, "setclipboard" end
    end
    if syn and type(syn.set_clipboard) == "function" then
        local ok = pcall(function() syn.set_clipboard(text) end)
        if ok then return true, "syn.set_clipboard" end
    end
    if type(delta) == "table" and type(delta.setclipboard) == "function" then
        local ok = pcall(function() delta.setclipboard(text) end)
        if ok then return true, "delta.setclipboard" end
    end
    if type(Delta) == "table" and type(Delta.setclipboard) == "function" then
        local ok = pcall(function() Delta.setclipboard(text) end)
        if ok then return true, "Delta.setclipboard" end
    end
    return false, nil
end

-- detection helpers
local function getPlayerPos()
    if LocalPlayer and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        local p = LocalPlayer.Character.HumanoidRootPart.Position
        return {x = p.X, y = p.Y, z = p.Z}
    end
    return nil
end

local function getNearbyBosses(radius)
    local res = {}
    radius = radius or 200
    local rootPos = nil
    if LocalPlayer and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        rootPos = LocalPlayer.Character.HumanoidRootPart.Position
    else
        rootPos = Vector3.new(0,0,0)
    end
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") and obj.PrimaryPart then
            local ok, dist = pcall(function()
                return (obj.PrimaryPart.Position - rootPos).Magnitude
            end)
            if ok and dist and dist <= radius then
                local humanoid = obj:FindFirstChildOfClass("Humanoid")
                table.insert(res, {
                    name = obj.Name,
                    pos = {x = obj.PrimaryPart.Position.X, y = obj.PrimaryPart.Position.Y, z = obj.PrimaryPart.Position.Z},
                    health = (humanoid and humanoid.Health) or nil
                })
            end
        end
    end
    return res
end

-- try to detect visible telegraphs/AoE parts by naming pattern
local function scanAoEParts()
    local parts = {}
    for _, p in ipairs(workspace:GetDescendants()) do
        if p:IsA("BasePart") then
            local success, n = pcall(function() return p.Name:lower() end)
            if success and n then
                if n:find("aoe") or n:find("tele") or n:find("circle") or n:find("hit") or n:find("telegraph") then
                    table.insert(parts, {
                        name = p.Name,
                        pos = {x = p.Position.X, y = p.Position.Y, z = p.Position.Z},
                        size = {x = p.Size.X, y = p.Size.Y, z = p.Size.Z},
                        parent = p.Parent and p.Parent.Name or nil
                    })
                end
            end
        end
    end
    return parts
end

-- main sampler
local sampler = nil
local function startRecording()
    if recording then return end
    recording = true
    meta.startedAt = os.time()
    samples = {}
    local accum = 0
    sampler = RunService.Heartbeat:Connect(function(dt)
        accum = accum + dt
        if accum < SAMPLE_INTERVAL then return end
        accum = 0
        if #samples >= MAX_SAMPLES then
            warn("Recorder reached max samples, stopping to avoid huge file.")
            recording = false
            if sampler then sampler:Disconnect() sampler = nil end
            meta.stoppedAt = os.time()
            return
        end
        local entry = {
            t = tick(),
            player = getPlayerPos(),
            bosses = getNearbyBosses(300),
            aoeParts = scanAoEParts()
        }
        table.insert(samples, entry)
    end)
    warn("Recording started.")
end

local function stopAndSave()
    if not recording then return end
    recording = false
    if sampler then sampler:Disconnect(); sampler = nil end
    meta.stoppedAt = os.time()
    local payload = {
        meta = meta,
        samples = samples
    }
    local ok, json = pcall(function() return HttpService:JSONEncode(payload) end)
    if not ok then
        json = "{}"
    end
    -- try writefile
    local wrote, mode = try_writefile(FILENAME, json)
    if wrote then
        warn("Saved recording to file: " .. FILENAME .. " via " .. tostring(mode))
        return true, "file", FILENAME
    end
    -- fallback setclipboard
    local clipped, cbmode = try_setclipboard(json)
    if clipped then
        warn("Saved recording to clipboard via: " .. tostring(cbmode))
        return true, "clipboard", nil
    end
    -- final fallback: print (may be huge)
    print(json)
    warn("No writefile/clipboard available — JSON printed to console (may be truncated).")
    return true, "printed", nil
end

-- Simple UI toggle
local StarterGui = game:GetService("StarterGui")
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local existing = PlayerGui:FindFirstChild("GildedRecorderUI")
if existing then existing:Destroy() end
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "GildedRecorderUI"
ScreenGui.ResetOnSpawn = false

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 200, 0, 48)
Frame.Position = UDim2.new(0.02, 0, 0.02, 0)
Frame.BackgroundTransparency = 0.35
Frame.BackgroundColor3 = Color3.fromRGB(20,20,20)
Frame.Parent = ScreenGui

local Button = Instance.new("TextButton")
Button.Size = UDim2.new(1, -10, 1, -10)
Button.Position = UDim2.new(0, 5, 0, 5)
Button.TextScaled = true
Button.Text = "Start Record"
Button.BackgroundColor3 = Color3.fromRGB(60,60,60)
Button.TextColor3 = Color3.new(1,1,1)
Button.Parent = Frame

Button.MouseButton1Click:Connect(function()
    if not recording then
        startRecording()
        Button.Text = "Stop & Save"
        Button.BackgroundColor3 = Color3.fromRGB(180,60,60)
    else
        local ok, mode, name = stopAndSave()
        Button.Text = "Start Record"
        Button.BackgroundColor3 = Color3.fromRGB(60,60,60)
        if ok and mode == "file" then
            pcall(function()
                StarterGui:SetCore("SendNotification", {Title="Recorder", Text="Saved: "..tostring(name), Duration=5})
            end)
        elseif ok and mode == "clipboard" then
            pcall(function()
                StarterGui:SetCore("SendNotification", {Title="Recorder", Text="Saved to clipboard", Duration=5})
            end)
        else
            pcall(function()
                StarterGui:SetCore("SendNotification", {Title="Recorder", Text="Saved to console", Duration=5})
            end)
        end
    end
end)

ScreenGui.Parent = PlayerGui

print("Gilded Skies recorder loaded. Use the on-screen button to start/stop recording.")
