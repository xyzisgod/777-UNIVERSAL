-- mstudio45 fork: same API as Linoria, adds touch + mobile support
local repo = 'https://raw.githubusercontent.com/mstudio45/LinoriaLib/main/'

local Library = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

local Players = game:GetService('Players')
local Player = Players.LocalPlayer
local RunService = game:GetService('RunService')
local UserInputService = game:GetService('UserInputService')
local CoreGui = game:GetService('CoreGui')

local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local aimbotlib = loadstring(game:HttpGet('https://raw.githubusercontent.com/Exunys/Aimbot-V3/refs/heads/main/src/Aimbot.lua'))()

-- config --
local kDebug = false
local kEspColor = Color3.fromRGB(255, 255, 255)
local kAutosaveSec = 10
local kFolder = '777'
local kAutoFile = kFolder .. '/settings/autoload.txt'

local hasDrawing = Drawing ~= nil and Drawing.new ~= nil
local lastClick = 0
local lastHit

aimbotlib.Load()

local settings = {
    ['aimbot'] = {
        ['enabled'] = false,
        ['targetpart'] = 'Head',
        ['smooth'] = 0,
        ['wallcheck'] = false,
        ['fov'] = { ['radius'] = 180 }
    },
    ['visuals'] = {
        ['enabled'] = false,
        ['box'] = true,
        ['healthbar'] = false,
        ['name'] = false,
        ['distance'] = false,
        ['tracer'] = false,
        ['wallcheck'] = false
    },
    ['trigger'] = {
        ['enabled'] = false,
        ['delay'] = 0.05,
        ['teamcheck'] = false,
        ['wallcheck'] = true
    },
    ['rage'] = {
        ['fly'] = false,
        ['flyspeed'] = 60,
        ['noclip'] = false,
        ['infjump'] = false,
        ['speed'] = false,
        ['speedvalue'] = 32,
        ['jump'] = false,
        ['jumpvalue'] = 100
    },
}

local connections = {}
local function track(conn) table.insert(connections, conn); return conn end

-- helpers --

local function syncAimbotFlags()
    if not (aimbotlib and aimbotlib.Settings) then return end
    aimbotlib.Settings.Enabled     = settings.aimbot.enabled
    aimbotlib.Settings.LockPart    = settings.aimbot.targetpart
    aimbotlib.Settings.Sensitivity = settings.aimbot.smooth or 0
    aimbotlib.Settings.WallCheck   = settings.aimbot.wallcheck
    aimbotlib.FOVSettings.Radius   = settings.aimbot.fov.radius or 180
end

-- nearest Model at or above inst
local function upModel(inst)
    while inst and not inst:IsA('Model') do inst = inst.Parent end
    return inst
end

local function isMine(inst)
    local char = Player.Character
    if char and inst:IsDescendantOf(char) then return true end
    -- clones / viewmodels named after you
    local m = upModel(inst)
    while m and m ~= workspace do
        if m.Name == Player.Name or m.Name == Player.DisplayName then return true end
        m = upModel(m.Parent)
    end
    return false
end

-- true when nothing solid sits between camera and target
local function isVisible(char)
    local cam = workspace.CurrentCamera
    local part = char:FindFirstChild('Head') or char:FindFirstChild('HumanoidRootPart')
    if not (cam and part) then return false end

    local ignore = { char, cam }
    if Player.Character then table.insert(ignore, Player.Character) end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true

    local origin = cam.CFrame.Position
    local dir = part.Position - origin
    for _ = 1, 5 do
        params.FilterDescendantsInstances = ignore
        local r = workspace:Raycast(origin, dir, params)
        if not r then return true end
        if isMine(r.Instance) then
            table.insert(ignore, r.Instance)
        else
            return false
        end
    end
    return false
end

-- trigger --

local function getTriggerTarget()
    local cam = workspace.CurrentCamera
    if not cam then return nil end

    -- mobile has no cursor, use screen center as crosshair
    local pos = isMobile and (cam.ViewportSize / 2) or UserInputService:GetMouseLocation()
    local ray = cam:ViewportPointToRay(pos.X, pos.Y)

    local params = RaycastParams.new()
    params.IgnoreWater = true
    local result

    if settings.trigger.wallcheck then
        -- first solid hit wins, walls block
        local ignore = { cam }
        if Player.Character then table.insert(ignore, Player.Character) end
        params.FilterType = Enum.RaycastFilterType.Exclude
        for _ = 1, 5 do
            params.FilterDescendantsInstances = ignore
            result = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
            if not result then return nil end
            if isMine(result.Instance) then
                table.insert(ignore, result.Instance)
            else
                break
            end
        end
        if not result or isMine(result.Instance) then return nil end
    else
        -- walls ignored, only other players' characters can be hit
        local chars = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= Player and p.Character then table.insert(chars, p.Character) end
        end
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = chars
        result = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
        if not result then return nil end
    end

    if kDebug and result.Instance ~= lastHit then
        lastHit = result.Instance
        print('[trigger] hit:', result.Instance:GetFullName())
    end

    local model = upModel(result.Instance)
    while model and model ~= workspace and not model:FindFirstChildOfClass('Humanoid') do
        model = upModel(model.Parent)
    end
    if not model or model == workspace then return nil end

    local target = Players:GetPlayerFromCharacter(model)
    if not target or target == Player then return nil end -- players only

    local hum = model:FindFirstChildOfClass('Humanoid')
    if not hum or hum.Health <= 0 then return nil end

    if settings.trigger.teamcheck and target.Team == Player.Team then return nil end

    return model
end

-- esp (own Drawing renderer, per-player wallcheck) --

local espObjects = {}

local function newDraw(class, props)
    local d = Drawing.new(class)
    for k, v in pairs(props) do d[k] = v end
    return d
end

local function createEsp(player)
    if not hasDrawing or player == Player or espObjects[player] then return end
    espObjects[player] = {
        Box        = newDraw('Square', { Thickness = 1, Filled = false, Color = kEspColor, Visible = false }),
        HealthBack = newDraw('Line',   { Thickness = 3, Color = Color3.new(0, 0, 0), Visible = false }),
        Health     = newDraw('Line',   { Thickness = 1, Color = Color3.new(0, 1, 0), Visible = false }),
        Name       = newDraw('Text',   { Size = 13, Center = true, Outline = true, Color = kEspColor, Visible = false }),
        Dist       = newDraw('Text',   { Size = 13, Center = true, Outline = true, Color = kEspColor, Visible = false }),
        Tracer     = newDraw('Line',   { Thickness = 1, Color = kEspColor, Visible = false }),
    }
end

local function hideEsp(obj)
    for _, d in pairs(obj) do d.Visible = false end
end

local function removeEsp(player)
    local obj = espObjects[player]
    if not obj then return end
    for _, d in pairs(obj) do
        pcall(function() d:Remove() end)
    end
    espObjects[player] = nil
end

local function updateEsp()
    local v = settings.visuals
    local cam = workspace.CurrentCamera
    for player, obj in pairs(espObjects) do
        local char = player.Character
        local hum = char and char:FindFirstChildOfClass('Humanoid')
        local root = char and char:FindFirstChild('HumanoidRootPart')
        local head = char and char:FindFirstChild('Head')

        if not (v.enabled and cam and hum and root and head and hum.Health > 0) then
            hideEsp(obj)
            continue
        end

        if v.wallcheck and not isVisible(char) then
            hideEsp(obj)
            continue
        end

        local top = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 0.7, 0))
        local bot = cam:WorldToViewportPoint(root.Position - Vector3.new(0, 3, 0))
        if top.Z <= 0 or bot.Z <= 0 then
            hideEsp(obj)
            continue
        end

        local height = math.abs(bot.Y - top.Y)
        local width = height * 0.6
        local cx = (top.X + bot.X) / 2
        local x, y = cx - width / 2, top.Y

        obj.Box.Position = Vector2.new(x, y)
        obj.Box.Size = Vector2.new(width, height)
        obj.Box.Visible = v.box

        local ratio = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        obj.HealthBack.From = Vector2.new(x - 5, y + height + 1)
        obj.HealthBack.To = Vector2.new(x - 5, y - 1)
        obj.HealthBack.Visible = v.healthbar
        obj.Health.From = Vector2.new(x - 5, y + height)
        obj.Health.To = Vector2.new(x - 5, y + height - height * ratio)
        obj.Health.Color = Color3.new(1 - ratio, ratio, 0)
        obj.Health.Visible = v.healthbar

        obj.Name.Text = player.Name
        obj.Name.Position = Vector2.new(cx, y - 16)
        obj.Name.Visible = v.name

        obj.Dist.Text = math.floor((cam.CFrame.Position - root.Position).Magnitude) .. 'm'
        obj.Dist.Position = Vector2.new(cx, y + height + 2)
        obj.Dist.Visible = v.distance

        local vs = cam.ViewportSize
        obj.Tracer.From = Vector2.new(vs.X / 2, vs.Y)
        obj.Tracer.To = Vector2.new(cx, y + height)
        obj.Tracer.Visible = v.tracer
    end
end

local function setupPlayer(player)
    createEsp(player)
end

-- rage --
-- fly/speed/jump get flagged by server-side checks, expect kicks on guarded games

local rageOrig = {}
local flyOn = false

local function getChar()
    local char = Player.Character
    local hum = char and char:FindFirstChildOfClass('Humanoid')
    local root = char and char:FindFirstChild('HumanoidRootPart')
    return char, hum, root
end

local function restoreRage()
    local _, hum = getChar()
    if hum then
        hum.PlatformStand = false
        if rageOrig.speed then hum.WalkSpeed = rageOrig.speed end
        if rageOrig.jump then hum.JumpPower = rageOrig.jump end
    end
    rageOrig = {}
    flyOn = false
end

track(Player.CharacterAdded:Connect(function()
    rageOrig = {}
    flyOn = false
end))

track(RunService.Heartbeat:Connect(function()
    local r = settings.rage
    local _, hum, root = getChar()
    if not (hum and root) then return end

    -- fly: camera-relative, space up, left ctrl down
    if r.fly then
        local cam = workspace.CurrentCamera
        local dir = Vector3.zero
        if cam and isMobile then
            -- thumbstick moves relative to camera, jump button goes up
            local cf = cam.CFrame
            local md = hum.MoveDirection
            if md.Magnitude > 0 then
                local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
                local fwd = flatLook.Magnitude > 0 and flatLook.Unit:Dot(md) or 0
                local rgt = cf.RightVector:Dot(md)
                dir += cf.LookVector * fwd + cf.RightVector * rgt
            end
            if hum.Jump then dir += Vector3.yAxis end
        elseif cam and not UserInputService:GetFocusedTextBox() then
            local cf = cam.CFrame
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cf.LookVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cf.LookVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cf.RightVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cf.RightVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
        end
        hum.PlatformStand = true
        root.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * r.flyspeed or Vector3.zero
        flyOn = true
    elseif flyOn then
        flyOn = false
        hum.PlatformStand = false
    end

    -- walkspeed
    if r.speed then
        rageOrig.speed = rageOrig.speed or hum.WalkSpeed
        hum.WalkSpeed = r.speedvalue
    elseif rageOrig.speed then
        hum.WalkSpeed = rageOrig.speed
        rageOrig.speed = nil
    end

    -- jump power
    if r.jump then
        rageOrig.jump = rageOrig.jump or hum.JumpPower
        hum.UseJumpPower = true
        hum.JumpPower = r.jumpvalue
    elseif rageOrig.jump then
        hum.JumpPower = rageOrig.jump
        rageOrig.jump = nil
    end
end))

-- noclip: humanoid re-enables collisions on its own after disable
track(RunService.Stepped:Connect(function()
    if not settings.rage.noclip then return end
    local char = Player.Character
    if not char then return end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA('BasePart') and p.CanCollide then p.CanCollide = false end
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if not settings.rage.infjump then return end
    local _, hum = getChar()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

-- unload --

local function unload()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}

    for player in pairs(espObjects) do removeEsp(player) end
    restoreRage()

    pcall(function() aimbotlib:Exit() end)
    pcall(function() Library:Unload() end)

    getgenv().settings777 = nil
end

-- ui --

local Window = Library:CreateWindow({
    Title = '777',
    Center = true,
    AutoShow = true,
    Size = isMobile and UDim2.fromOffset(460, 290) or UDim2.fromOffset(550, 600),
    TabPadding = 8,
    MenuFadeTime = 0.2
})

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()

local Tabs = {
    Aiming = Window:AddTab('Aiming'),
    Visuals = Window:AddTab('Visuals'),
    Misc = Window:AddTab('Misc'),
    Rage = Window:AddTab('Rage'),
}

SaveManager:SetFolder(kFolder)
SaveManager:BuildConfigSection(Tabs.Misc)

local GroupBoxes = {
    Aiming1 = Tabs.Aiming:AddLeftGroupbox('Aimbot'),
    Trigger1 = Tabs.Aiming:AddRightGroupbox('Triggerbot'),
    Visuals1 = Tabs.Visuals:AddLeftGroupbox('ESP'),
    Misc1 = Tabs.Misc:AddLeftGroupbox('Misc'),
    Rage1 = Tabs.Rage:AddLeftGroupbox('Movement'),
    Rage2 = Tabs.Rage:AddRightGroupbox('Character'),
}

local Toggles = {
    Aiming1 = GroupBoxes.Aiming1:AddToggle('AimbotEnabled', {
        Text = 'Enabled',
        Default = settings.aimbot.enabled,
        Tooltip = 'Enables/disables aimbot.',
        Callback = function(value)
            settings.aimbot.enabled = value
            syncAimbotFlags()
        end
    }),
    Visuals1 = GroupBoxes.Visuals1:AddToggle('Enabled', {
        Text = 'Enabled',
        Default = settings.visuals.enabled,
        Tooltip = 'Enables/disables ESP.',
        Callback = function(value) settings.visuals.enabled = value end
    })
}

local WallToggles = {
    Aim = GroupBoxes.Aiming1:AddToggle('AimbotWallcheck', {
        Text = 'Wallcheck',
        Default = settings.aimbot.wallcheck,
        Tooltip = 'Ignore targets behind walls.',
        Callback = function(v) settings.aimbot.wallcheck = v; syncAimbotFlags() end
    }),
    Trigger = GroupBoxes.Trigger1:AddToggle('TriggerWallcheck', {
        Text = 'Wallcheck',
        Default = settings.trigger.wallcheck,
        Tooltip = 'Off = fires through walls.',
        Callback = function(v) settings.trigger.wallcheck = v end
    }),
    Esp = GroupBoxes.Visuals1:AddToggle('EspWallcheck', {
        Text = 'Wallcheck',
        Default = settings.visuals.wallcheck,
        Tooltip = 'Hide players behind walls.',
        Callback = function(v) settings.visuals.wallcheck = v end
    })
}

local VisualToggles = {
    Box = GroupBoxes.Visuals1:AddToggle('Box', {
        Text = 'Box',
        Default = settings.visuals.box,
        Callback = function(v) settings.visuals.box = v end
    }),
    Healthbar = GroupBoxes.Visuals1:AddToggle('Healthbar', {
        Text = 'Health Bar',
        Default = settings.visuals.healthbar,
        Callback = function(v) settings.visuals.healthbar = v end
    }),
    Name = GroupBoxes.Visuals1:AddToggle('Name', {
        Text = 'Name',
        Default = settings.visuals.name,
        Callback = function(v) settings.visuals.name = v end
    }),
    Distance = GroupBoxes.Visuals1:AddToggle('Distance', {
        Text = 'Distance',
        Default = settings.visuals.distance,
        Callback = function(v) settings.visuals.distance = v end
    }),
    Tracer = GroupBoxes.Visuals1:AddToggle('Tracer', {
        Text = 'Tracer',
        Default = settings.visuals.tracer,
        Callback = function(v) settings.visuals.tracer = v end
    })
}

local Sliders = {
    Aiming1 = GroupBoxes.Aiming1:AddSlider('smoothaimbot', {
        Text = 'Aim smoothing',
        Default = settings.aimbot.smooth,
        Min = 0,
        Max = 1,
        Rounding = 1,
        Compact = false,
        Callback = function(v) settings.aimbot.smooth = v; syncAimbotFlags() end
    }),
    Aiming2 = GroupBoxes.Aiming1:AddSlider('fovaimbot', {
        Text = 'Aim fov radius',
        Default = settings.aimbot.fov.radius,
        Min = 0,
        Max = 500,
        Rounding = 1,
        Compact = false,
        Callback = function(v) settings.aimbot.fov.radius = v; syncAimbotFlags() end
    })
}

local Dropdowns = {
    Aiming1 = GroupBoxes.Aiming1:AddDropdown('TargetPart', {
        Values = { 'Head', 'HumanoidRootPart' },
        Default = 1,
        Multi = false,
        Text = 'Target Part',
        Tooltip = 'Select part to target when aiming.',
        Callback = function(value)
            settings.aimbot.targetpart = value
            if aimbotlib and aimbotlib.Settings then
                aimbotlib.Settings.LockPart = value
                aimbotlib.Restart()
            end
        end
    })
}

local TriggerToggles = {
    Enabled = GroupBoxes.Trigger1:AddToggle('TriggerEnabled', {
        Text = 'Triggerbot',
        Default = settings.trigger.enabled,
        Callback = function(v) settings.trigger.enabled = v end
    }),
    Team = GroupBoxes.Trigger1:AddToggle('TriggerTeam', {
        Text = 'Team check',
        Default = settings.trigger.teamcheck,
        Callback = function(v) settings.trigger.teamcheck = v end
    })
}

local TriggerDelay = GroupBoxes.Trigger1:AddSlider('TriggerDelay', {
    Text = 'Trigger delay',
    Default = settings.trigger.delay,
    Min = 0,
    Max = 0.5,
    Rounding = 2,
    Callback = function(v) settings.trigger.delay = v end
})

local RageUI = {}

RageUI.Fly = GroupBoxes.Rage1:AddToggle('RageFly', {
    Text = 'Fly',
    Default = settings.rage.fly,
    Tooltip = 'WASD + camera, Space up, Left Ctrl down.',
    Callback = function(v) settings.rage.fly = v end
})
RageUI.Fly:AddKeyPicker('RageFlyKey', {
    Default = 'F',
    SyncToggleState = true,
    Mode = 'Toggle',
    Text = 'Fly',
    NoUI = false
})

RageUI.FlySpeed = GroupBoxes.Rage1:AddSlider('RageFlySpeed', {
    Text = 'Fly speed',
    Default = settings.rage.flyspeed,
    Min = 10,
    Max = 300,
    Rounding = 0,
    Callback = function(v) settings.rage.flyspeed = v end
})

RageUI.Noclip = GroupBoxes.Rage1:AddToggle('RageNoclip', {
    Text = 'Noclip',
    Default = settings.rage.noclip,
    Tooltip = 'Walk through walls.',
    Callback = function(v) settings.rage.noclip = v end
})
RageUI.Noclip:AddKeyPicker('RageNoclipKey', {
    Default = 'N',
    SyncToggleState = true,
    Mode = 'Toggle',
    Text = 'Noclip',
    NoUI = false
})

RageUI.InfJump = GroupBoxes.Rage1:AddToggle('RageInfJump', {
    Text = 'Infinite jump',
    Default = settings.rage.infjump,
    Callback = function(v) settings.rage.infjump = v end
})

RageUI.Speed = GroupBoxes.Rage2:AddToggle('RageSpeed', {
    Text = 'Walk speed',
    Default = settings.rage.speed,
    Callback = function(v) settings.rage.speed = v end
})
RageUI.SpeedValue = GroupBoxes.Rage2:AddSlider('RageSpeedValue', {
    Text = 'Speed',
    Default = settings.rage.speedvalue,
    Min = 16,
    Max = 200,
    Rounding = 0,
    Callback = function(v) settings.rage.speedvalue = v end
})

RageUI.Jump = GroupBoxes.Rage2:AddToggle('RageJump', {
    Text = 'Jump power',
    Default = settings.rage.jump,
    Callback = function(v) settings.rage.jump = v end
})
RageUI.JumpValue = GroupBoxes.Rage2:AddSlider('RageJumpValue', {
    Text = 'Power',
    Default = settings.rage.jumpvalue,
    Min = 50,
    Max = 300,
    Rounding = 0,
    Callback = function(v) settings.rage.jumpvalue = v end
})

local Buttons = {
    Misc1 = GroupBoxes.Misc1:AddButton({
        Text = 'Unload 777',
        Func = function() unload() end,
        DoubleClick = true,
        Tooltip = 'WARNING: This unloads the entire UI, ESP and Aimbot'
    })
}

local KeyPickers = {
    Misc1 = GroupBoxes.Misc1:AddLabel('Menu keybind'):AddKeyPicker('MenuKeybind', {
        Default = 'Insert',
        NoUI = true,
        Text = 'Menu keybind'
    })
}

local Opts = Library.Options or getgenv().Options
if Opts and Opts.MenuKeybind then
    Library.ToggleKeybind = Opts.MenuKeybind
end

-- mobile: floating button to open/close the menu (no Insert key on touch)
if isMobile then
    local btnGui = Instance.new('ScreenGui')
    btnGui.Name = 'MenuToggle777'
    btnGui.ResetOnSpawn = false
    btnGui.DisplayOrder = 999
    btnGui.Parent = (gethui and gethui()) or CoreGui

    local btn = Instance.new('TextButton')
    btn.Size = UDim2.fromOffset(44, 44)
    btn.Position = UDim2.new(0, 10, 0.5, -22)
    btn.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    btn.BackgroundTransparency = 0.2
    btn.Text = '777'
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.Code
    btn.TextSize = 14
    btn.Parent = btnGui
    Instance.new('UICorner', btn).CornerRadius = UDim.new(0, 8)

    btn.Activated:Connect(function()
        if Library.Toggle then Library:Toggle() end
    end)

    track({ Disconnect = function() btnGui:Destroy() end })
end

-- main --


for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end
track(Players.PlayerAdded:Connect(setupPlayer))
track(Players.PlayerRemoving:Connect(removeEsp))

track(RunService.RenderStepped:Connect(function()
    local ok, err = pcall(updateEsp)
    if not ok and kDebug then warn('[esp]', err) end
end))

track(RunService.RenderStepped:Connect(function()
    if not settings.trigger.enabled then return end
    if Library.Toggled then return end -- menu open, click would hit UI
    if tick() - lastClick < settings.trigger.delay then return end
    if getTriggerTarget() then
        lastClick = tick()
        if kDebug then print('[trigger] fire') end
        mouse1click()
    end
end))

aimbotlib.Restart()

-- saving: first run creates 'default' and marks it autoload
local okLoad, errLoad = pcall(function()
    if not isfile(kAutoFile) then
        SaveManager:Save('default')
        writefile(kAutoFile, 'default')
    end
    SaveManager:LoadAutoloadConfig()
end)
if not okLoad and kDebug then warn('[save]', errLoad) end

-- sync everything from UI after load, callbacks may not fire
local function syncFromUI()
    settings.aimbot.enabled    = Toggles.Aiming1.Value
    settings.aimbot.smooth     = Sliders.Aiming1.Value
    settings.aimbot.fov.radius = Sliders.Aiming2.Value
    settings.aimbot.targetpart = Dropdowns.Aiming1.Value
    settings.aimbot.wallcheck  = WallToggles.Aim.Value

    settings.visuals.enabled    = Toggles.Visuals1.Value
    settings.visuals.box        = VisualToggles.Box.Value
    settings.visuals.healthbar  = VisualToggles.Healthbar.Value
    settings.visuals.name       = VisualToggles.Name.Value
    settings.visuals.distance   = VisualToggles.Distance.Value
    settings.visuals.tracer     = VisualToggles.Tracer.Value
    settings.visuals.wallcheck  = WallToggles.Esp.Value

    settings.trigger.enabled    = TriggerToggles.Enabled.Value
    settings.trigger.teamcheck  = TriggerToggles.Team.Value
    settings.trigger.delay      = TriggerDelay.Value
    settings.trigger.wallcheck  = WallToggles.Trigger.Value

    settings.rage.fly        = RageUI.Fly.Value
    settings.rage.flyspeed   = RageUI.FlySpeed.Value
    settings.rage.noclip     = RageUI.Noclip.Value
    settings.rage.infjump    = RageUI.InfJump.Value
    settings.rage.speed      = RageUI.Speed.Value
    settings.rage.speedvalue = RageUI.SpeedValue.Value
    settings.rage.jump       = RageUI.Jump.Value
    settings.rage.jumpvalue  = RageUI.JumpValue.Value

    syncAimbotFlags()
end

syncFromUI()

-- autosave to whichever config is set as autoload
task.spawn(function()
    while not Library.Unloaded do
        task.wait(kAutosaveSec)
        if Library.Unloaded then break end
        local ok, name = pcall(readfile, kAutoFile)
        if not ok or name == '' then name = 'default' end
        pcall(function() SaveManager:Save(name) end)
    end
end)
