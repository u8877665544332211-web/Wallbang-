local repo = 'https://raw.githubusercontent.com/mstudio45/LinoriaLib/main/'
local Library = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'Addons/ThemeManager.lua'))()
local SaveManager = loadstring(game:HttpGet(repo .. 'Addons/SaveManager.lua'))()

-- ---- 기존 월뱅 스크립트 로직 ------------------------------------------------
local Players           = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Workspace         = game:GetService('Workspace')
local RunService        = game:GetService('RunService')
local UserInputService  = game:GetService('UserInputService')
local LP                = Players.LocalPlayer

if _G.RIVALS_WALLBANG and _G.RIVALS_WALLBANG.Loaded then
    local connKeys = {
        'HeartbeatConnection', 'InputBeganConnection', 'InputEndedConnection',
        'EnemyAddedConnection', 'EnemyRemovedConnection',
        'FighterAddedConnection', 'FighterRemovedConnection',
    }
    for _, key in ipairs(connKeys) do
        local conn = _G.RIVALS_WALLBANG[key]
        if conn then
            pcall(function() conn:Disconnect() end)
            _G.RIVALS_WALLBANG[key] = nil
        end
    end
end

_G.RIVALS_WALLBANG = {
    Loaded                   = true,
    Enabled                  = false,   -- 기본값은 꺼진 상태로 시작 (UI로 켜기)
    Verbose                  = true,
    RequireMouseHeld         = true,
    AcceptRightMouse         = true,
    ShotInterval             = 0.05,
    SearchRadius             = 9.5,
    AimAtPart                = 'Head',
    MeleeAttackMaxStuds      = 15,
    LastShotAt               = 0,
    PrintEvery               = 60,
    SkipCounter              = {},
    LeftMouseHeld            = false,
    RightMouseHeld           = false,
    TrackedFighters          = {},
    TrackedEnemies           = {},
    EnemyControllerHooked    = false,
    FighterControllerHooked  = false,
}
local STATE = _G.RIVALS_WALLBANG

local function vlog(reason)
    if not STATE.Verbose then return end
    STATE.SkipCounter[reason] = (STATE.SkipCounter[reason] or 0) + 1
    if STATE.SkipCounter[reason] % STATE.PrintEvery == 1 then
        print(string.format('[Wallbang] %s (x%d)', reason, STATE.SkipCounter[reason]))
    end
end

local function vlogFire(msg)
    if STATE.Verbose then print('[Wallbang] ' .. msg) end
end

local cachedEnumLib, cachedFighter, cachedRemote, cachedEnum = nil, nil, nil, nil

local function getEnumLib()
    if cachedEnumLib then return cachedEnumLib end
    local modules = ReplicatedStorage:FindFirstChild('Modules')
    local moduleScript = modules and modules:FindFirstChild('EnumLibrary')
    if not moduleScript then return nil end
    local ok, lib = pcall(require, moduleScript)
    if ok then cachedEnumLib = lib end
    return cachedEnumLib
end

local function getFighterController()
    if cachedFighter then return cachedFighter end
    local ps          = LP:FindFirstChild('PlayerScripts')
    local controllers = ps and ps:FindFirstChild('Controllers')
    local moduleScript = controllers and controllers:FindFirstChild('FighterController')
    if not moduleScript then return nil end
    local ok, fc = pcall(require, moduleScript)
    if ok then cachedFighter = fc end
    return cachedFighter
end

local cachedEnemyController = nil
local function getEnemyController()
    if cachedEnemyController then return cachedEnemyController end
    local ps          = LP:FindFirstChild('PlayerScripts')
    local controllers = ps and ps:FindFirstChild('Controllers')
    local moduleScript = controllers and controllers:FindFirstChild('EnemyController')
    if not moduleScript then return nil end
    local ok, ec = pcall(require, moduleScript)
    if ok then cachedEnemyController = ec end
    return cachedEnemyController
end

local function getUseItemRemote()
    if cachedRemote and cachedRemote.Parent then return cachedRemote end
    local remotes     = ReplicatedStorage:FindFirstChild('Remotes')
    local replication = remotes and remotes:FindFirstChild('Replication')
    local fighter     = replication and replication:FindFirstChild('Fighter')
    local remote      = fighter and fighter:FindFirstChild('UseItem')
    if remote and remote:IsA('RemoteEvent') then
        cachedRemote = remote
    end
    return cachedRemote
end

local function getStartShootingEnum()
    if cachedEnum ~= nil then return cachedEnum end
    local enums = getEnumLib()
    if not enums or type(enums.ToEnum) ~= 'function' then return nil end
    local ok, enumValue = pcall(enums.ToEnum, enums, 'StartShooting')
    if ok and enumValue ~= nil then
        cachedEnum = enumValue
    end
    return cachedEnum
end

local function getLocalFighter()
    local fc = getFighterController()
    if not fc then return nil end
    if fc.LocalFighter then return fc.LocalFighter end
    if type(fc.GetFighter) == 'function' then
        local ok, f = pcall(fc.GetFighter, fc, LP)
        if ok and f then return f end
        if LP.Character then
            local ok2, f2 = pcall(fc.GetFighter, fc, LP.Character)
            if ok2 and f2 then return f2 end
        end
    end
    return nil
end

local function readItemValue(item, key)
    if not item then return nil end
    if type(item.Get) == 'function' then
        local ok, v = pcall(item.Get, item, key)
        if ok and v ~= nil then return v end
    end
    if type(item.Data) == 'table' then
        return item.Data[key]
    end
    return nil
end

local function isMeleeItem(item)
    local info = item and item.Info
    if not info then return false end
    return info.Class == 'Melee' or info.Type == 'Melee'
end

local DUMMY_MODEL_NAMES = {
    ['Dummy']     = true,
    ['DPS Dummy'] = true,
    ['Target']    = true,
}

local function resolveDummyAimPart(model)
    local head = model:FindFirstChild('Head')
    if head and head:IsA('BasePart') then return head end
    if model.PrimaryPart then return model.PrimaryPart end
    for _, child in ipairs(model:GetChildren()) do
        if child:IsA('BasePart') then return child end
    end
    return nil
end

local function registerFighter(fighter)
    local player = fighter and fighter.Player
    if not player or player == LP then return end
    STATE.TrackedFighters[player] = fighter
end

local function unregisterFighter(fighter)
    local player = fighter and fighter.Player
    if not player then return end
    if STATE.TrackedFighters[player] == fighter then
        STATE.TrackedFighters[player] = nil
    end
end

local function registerEnemy(enemy)
    local model = enemy and enemy.Model
    if not model or not DUMMY_MODEL_NAMES[model.Name] then return end
    STATE.TrackedEnemies[enemy] = {
        model   = model,
        aimPart = resolveDummyAimPart(model),
    }
end

local function unregisterEnemy(enemy)
    STATE.TrackedEnemies[enemy] = nil
end

local function ensureTargetTracking()
    if not STATE.FighterControllerHooked then
        local fc = getFighterController()
        if fc then
            for _, fighter in ipairs(fc.Objects or {}) do
                registerFighter(fighter)
            end
            if fc.ObjectAdded and type(fc.ObjectAdded.Connect) == 'function' then
                STATE.FighterAddedConnection   = fc.ObjectAdded:Connect(registerFighter)
            end
            if fc.ObjectRemoved and type(fc.ObjectRemoved.Connect) == 'function' then
                STATE.FighterRemovedConnection = fc.ObjectRemoved:Connect(unregisterFighter)
            end
            STATE.FighterControllerHooked = true
        end
    end

    if not STATE.EnemyControllerHooked then
        local ec = getEnemyController()
        if ec then
            for _, enemy in ipairs(ec.Objects or {}) do
                registerEnemy(enemy)
            end
            if ec.ObjectAdded and type(ec.ObjectAdded.Connect) == 'function' then
                STATE.EnemyAddedConnection   = ec.ObjectAdded:Connect(registerEnemy)
            end
            if ec.ObjectRemoved and type(ec.ObjectRemoved.Connect) == 'function' then
                STATE.EnemyRemovedConnection = ec.ObjectRemoved:Connect(unregisterEnemy)
            end
            STATE.EnemyControllerHooked = true
        end
    end
end

local function pickTarget()
    local myChar = LP.Character
    local myRoot = myChar and myChar:FindFirstChild('HumanoidRootPart')
    if not myRoot then return nil, 'no local HumanoidRootPart' end

    local best, bestDist = nil, math.huge

    for player, _ in pairs(STATE.TrackedFighters) do
        local char = player.Character
        local part = char and char:FindFirstChild(STATE.AimAtPart)
        if part then
            local d = (myRoot.Position - part.Position).Magnitude
            if d < bestDist then
                best, bestDist = part, d
            end
        end
    end

    for enemy, tracked in pairs(STATE.TrackedEnemies) do
        local part = tracked.aimPart
        if not part or not part.Parent then
            part = resolveDummyAimPart(tracked.model)
            tracked.aimPart = part
        end
        if part and tracked.model.Parent then
            local d = (myRoot.Position - part.Position).Magnitude
            if d < bestDist then
                best, bestDist = part, d
            end
        end
    end

    if not best then return nil, 'no target' end
    return best, bestDist
end

local SHELL_DIRECTIONS = {
    Vector3.new( 1, 0, 0), Vector3.new(-1, 0, 0),
    Vector3.new( 0, 1, 0), Vector3.new( 0,-1, 0),
    Vector3.new( 0, 0, 1), Vector3.new( 0, 0,-1),
    Vector3.new( 1, 1, 1).Unit, Vector3.new( 1, 1,-1).Unit,
    Vector3.new( 1,-1, 1).Unit, Vector3.new( 1,-1,-1).Unit,
    Vector3.new(-1, 1, 1).Unit, Vector3.new(-1, 1,-1).Unit,
    Vector3.new(-1,-1, 1).Unit, Vector3.new(-1,-1,-1).Unit,
}

local function buildRaycastParams(targetSubject)
    local rp = RaycastParams.new()
    rp.FilterType  = Enum.RaycastFilterType.Exclude
    rp.IgnoreWater = true
    rp.FilterDescendantsInstances = { LP.Character, targetSubject }
    return rp
end

local function isClearLine(origin, target, rp)
    local dir = target - origin
    if dir.Magnitude <= 0 then return false end
    return Workspace:Raycast(origin, dir, rp) == nil
end

local function resolveShotOrigin(targetPart, targetPos, cameraPos)
    local subject = targetPart:FindFirstAncestorOfClass('Model')
    local rp      = buildRaycastParams(subject)

    if isClearLine(cameraPos, targetPos, rp) then
        return cameraPos
    end
    for _, dir in ipairs(SHELL_DIRECTIONS) do
        local candidate = cameraPos + dir * STATE.SearchRadius
        if isClearLine(candidate, targetPos, rp) then
            return candidate
        end
    end
    return nil
end

local function buildShotData(originPos, targetPart, targetPos)
    local lookCF     = CFrame.lookAt(originPos, targetPos)
    local lX, lY, lZ = lookCF:ToOrientation()

    local originStruct = {
        [utf8.char(0)] = originPos.X, [utf8.char(1)] = originPos.Y, [utf8.char(2)] = originPos.Z,
        [utf8.char(3)] = lX,          [utf8.char(4)] = lY,          [utf8.char(5)] = lZ,
    }

    local relCF      = targetPart.CFrame:ToObjectSpace(CFrame.new(targetPos))
    local rX, rY, rZ = relCF:ToOrientation()

    return {
        [utf8.char(1)] = {
            [utf8.char(0)] = originStruct,
            [utf8.char(1)] = originStruct,
            [utf8.char(2)] = targetPart,
            [utf8.char(3)] = {
                [utf8.char(0)] = relCF.X, [utf8.char(1)] = relCF.Y, [utf8.char(2)] = relCF.Z,
                [utf8.char(3)] = rX,      [utf8.char(4)] = rY,      [utf8.char(5)] = rZ,
            },
        },
    }
end

local function isShootInputHeld()
    if STATE.LeftMouseHeld then return true end
    if STATE.AcceptRightMouse and STATE.RightMouseHeld then return true end
    return false
end

local function tryFireWallbangShot()
    local now = tick()

    if STATE.RequireMouseHeld and not isShootInputHeld() then
        return false
    end

    if (now - STATE.LastShotAt) < STATE.ShotInterval then
        return false
    end

    local fighter = getLocalFighter()
    if not fighter then return false, 'no LocalFighter' end

    local item = fighter.EquippedItem
    if not item then return false, 'no equipped item' end

    local melee = isMeleeItem(item)
    if not melee then
        local ammo = readItemValue(item, 'Ammo')
        if type(ammo) == 'number' and ammo <= 0 then
            return false, 'out of ammo'
        end
    end

    if type(item._shoot_cooldown) == 'number' and now < item._shoot_cooldown then
        return false
    end

    local targetPart, targetErr = pickTarget()
    if not targetPart then return false, targetErr end

    if melee then
        local myChar = LP.Character
        local myHrp  = myChar and myChar:FindFirstChild('HumanoidRootPart')
        if myHrp then
            local dist = (myHrp.Position - targetPart.Position).Magnitude
            if dist > STATE.MeleeAttackMaxStuds then
                return false
            end
        end
    end

    local cam = Workspace.CurrentCamera
    if not cam then return false, 'no camera' end

    local origin = resolveShotOrigin(targetPart, targetPart.Position, cam.CFrame.Position)
    if not origin then return false, 'no clear LoS' end

    local objectId = readItemValue(item, 'ObjectID')
    if not objectId then return false, 'no ObjectID' end

    local startShootingEnum = getStartShootingEnum()
    if startShootingEnum == nil then return false, 'Enum not ready' end

    local remote = getUseItemRemote()
    if not remote then return false, 'Remote not found' end

    local shotData = buildShotData(origin, targetPart, targetPart.Position)
    remote:FireServer(objectId, startShootingEnum, shotData, nil)
    STATE.LastShotAt = now

    local subject = targetPart:FindFirstAncestorOfClass('Model')
    return true, string.format('FIRED -> %s', subject and subject.Name or '?')
end

STATE.InputBeganConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        STATE.LeftMouseHeld = true
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        STATE.RightMouseHeld = true
    end
end)

STATE.InputEndedConnection = UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        STATE.LeftMouseHeld = false
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        STATE.RightMouseHeld = false
    end
end)

STATE.HeartbeatConnection = RunService.Heartbeat:Connect(function()
    if not (_G.RIVALS_WALLBANG and _G.RIVALS_WALLBANG.Enabled) then return end

    if not (STATE.EnemyControllerHooked and STATE.FighterControllerHooked) then
        ensureTargetTracking()
    end

    local results = table.pack(pcall(tryFireWallbangShot))
    if not results[1] then return end
    local success, reason = results[2], results[3]
    if success then
        vlogFire(reason or 'FIRED')
    elseif reason then
        vlog(reason)
    end
end)

-- ---- LinoriaLib UI 설정 -----------------------------------------------------

local Window = Library:CreateWindow({
    Title = 'Yumu Enchantment — Wallbang test',
    Center = true,
    AutoShow = true,
    TabPadding = 8,
    MenuBarRang = true
})

local Tabs = {
    Main = Window:AddTab('Main'),
    Settings = Window:AddTab('UI Settings'),
}

local LeftGroupBox = Tabs.Main:AddLeftGroupbox('Wallbang Controls')

LeftGroupBox:AddToggle('WallbangToggle', {
    Text = 'Enable Wallbang',
    Default = false,
    Tooltip = 'Enables or disables wallbang shooting logic',
    Callback = function(Value)
        _G.RIVALS_WALLBANG.Enabled = Value
    end
})

LeftGroupBox:AddToggle('RequireMouseHeldToggle', {
    Text = 'Require Mouse Held',
    Default = true,
    Tooltip = 'Only fires while holding left/right click',
    Callback = function(Value)
        _G.RIVALS_WALLBANG.RequireMouseHeld = Value
    end
})

LeftGroupBox:AddToggle('AcceptRMBToggle', {
    Text = 'Accept Right Mouse',
    Default = true,
    Tooltip = 'Allows shooting when RMB is held too',
    Callback = function(Value)
        _G.RIVALS_WALLBANG.AcceptRightMouse = Value
    end
})

local RightGroupBox = Tabs.Main:AddRightGroupbox('Parameters & Tuning')

RightGroupBox:AddSlider('ShotIntervalSlider', {
    Text = 'Shot Interval',
    Default = 0.05,
    Min = 0.01,
    Max = 0.5,
    Rounding = 2,
    Tooltip = 'Minimum delay between shots (seconds)',
    Callback = function(Value)
        _G.RIVALS_WALLGANG = _G.RIVALS_WALLBANG or {}
        _G.RIVALS_WALLBANG.ShotInterval = Value
    end
})

RightGroupBox:AddSlider('SearchRadiusSlider', {
    Text = 'Search Radius',
    Default = 9.5,
    Min = 1,
    Max = 15,
    Rounding = 1,
    Tooltip = 'Studs to sample around camera for LoS',
    Callback = function(Value)
        _G.RIVALS_WALLBANG.SearchRadius = Value
    end
})

RightGroupBox:AddDropdown('AimPartDropdown', {
    Values = { 'Head', 'HumanoidRootPart' },
    Default = 1,
    Text = 'Target Aim Part',
    Tooltip = 'Which part of the enemy to target',
    Callback = function(Value)
        _G.RIVALS_WALLBANG.AimAtPart = Value
    end
})

-- UI 테마 및 설정 관리자 연동
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({})
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)

Library:Notify('RIVALS Wallbang Loaded successfully!')
print('[Wallbang] LinoriaLib UI Initialized.')
