local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local function getEnv()
	if typeof(getgenv) == "function" then
		local ok, g = pcall(getgenv)
		if ok and type(g) == "table" then
			return g
		end
	end
	return _G
end

local env = getEnv()

local BAD_BUSINESS_PLACE_IDS = {
	[11379161761] = true,
	[3233893879] = true,
}

local BB_SCRIPT_URL = "https://raw.githubusercontent.com/Jp1234pot/CombatClient/refs/heads/main/src/combat_client_bad_business.lua"

local function isBadBusinessPlace()
	return BAD_BUSINESS_PLACE_IDS[game.PlaceId] == true
end

if isBadBusinessPlace() and not env._CombatClientLoadingBB then
	env._CombatClientLoadingBB = true
	local okFetch, src = pcall(function()
		return game:HttpGet(BB_SCRIPT_URL)
	end)
	if okFetch and typeof(src) == "string" and #src > 0 then
		local okCompile, chunk = pcall(loadstring, src)
		if okCompile and typeof(chunk) == "function" then
			local okRun, res = pcall(chunk)
			env._CombatClientLoadingBB = false
			if okRun then
				return res
			end
			warn("[CombatClient] BB script runtime error:", tostring(res))
		else
			env._CombatClientLoadingBB = false
			warn("[CombatClient] BB script compile error:", tostring(chunk))
		end
	else
		env._CombatClientLoadingBB = false
		warn("[CombatClient] BB script fetch error:", tostring(src))
	end
end

local function getExecutorFn(name)
	local fn = rawget(env, name) or rawget(_G, name)
	if typeof(fn) == "function" then
		return fn
	end
	local ok, gFn = pcall(function()
		return _G[name]
	end)
	return (ok and typeof(gFn) == "function") and gFn or nil
end

local fnNewCClosure = getExecutorFn("newcclosure")
local fnSetFpsCap = getExecutorFn("setfpscap") or getExecutorFn("set_fps_cap")

if env.CombatClient and typeof(env.CombatClient.Destroy) == "function" then
	pcall(function()
		env.CombatClient.Destroy()
	end)
end

local CombatClient = {}

local SESSION_ID = HttpService:GenerateGUID(false)
local SESSION_ATTR = "CombatClientSession"
local ENEMY_HL_NAME = "CombatClientEnemyHL"
local TEAM_HL_NAME = "CombatClientTeamHL"
local RENDER_STEP_NAME = "CombatClient_SmartCameraStep"

local DEFAULTS = {
	Mode = "Camera", -- "SilentAim", "Camera", or "Off"
	PriorityMode = "Smart", -- "Smart", "Nearest", or "Crosshair"

	HighlightEnabled = true,
	TeammateHighlightEnabled = false,
	MaxDistance = 500,
	ThroughWalls = true,
	FillColor = Color3.fromRGB(255, 65, 65),
	OutlineColor = Color3.fromRGB(255, 45, 45),
	TeammateFillColor = Color3.fromRGB(65, 145, 255),
	TeammateOutlineColor = Color3.fromRGB(45, 120, 245),
	FillTransparency = 0.85,
	OutlineTransparency = 0,

	AssistEnabled = true,
	TargetPlayers = true,
	TargetNPCs = false,
	AssistMaxDistance = 300,
	AssistMaxAngleDegrees = 35,
	WallCheck = true,
	IgnoreSameTeam = true,
	PreferHead = true,

	CameraSmoothness = 0.25,
	LockHoldSeconds = 0.15,
	CameraPriorityOffset = 1,

	FPSControlEnabled = false,
	FPSCap = 120,

	DebugLogs = false,
}

local Config = {}
local Connections = {}
local Highlights = {} -- [model] = { Instance = Highlight, Role = "enemy" | "teammate" }
local TraceTimers = {} -- [tag] = lastClock
local Initialized = false
local BoundPriority = nil
local HighlightAccum = 0

local WallRayParams = RaycastParams.new()
WallRayParams.FilterType = Enum.RaycastFilterType.Exclude
WallRayParams.IgnoreWater = true
local WallIgnoreCache = {}
local CachedIgnoreChar = nil
local CachedIgnoreCam = nil

local LockState = {
	Character = nil,
	LastValidAt = 0,
}

local function log(...)
	if Config.DebugLogs then
		print("[CombatClient]", ...)
	end
end

local function traceThrottled(tag, interval, ...)
	if not Config.DebugLogs then
		return
	end
	local now = os.clock()
	local prev = TraceTimers[tag] or 0
	if (now - prev) >= (interval or 0.5) then
		TraceTimers[tag] = now
		print(string.format("[CombatClient:%s]", tostring(tag)), ...)
	end
end

local function resetLockState()
	LockState.Character = nil
	LockState.LastValidAt = 0
end

local function applyFpsCap()
	if not fnSetFpsCap then
		return
	end
	local fps = Config.FPSControlEnabled and math.clamp(tonumber(Config.FPSCap) or 120, 15, 360) or 0
	pcall(fnSetFpsCap, fps)
end

local function getLocalCharacter()
	if typeof(CombatClient._AdapterGetLocalCharacter) == "function" then
		local ok, char = pcall(CombatClient._AdapterGetLocalCharacter)
		if ok and char then
			return char
		end
	end
	return LocalPlayer and LocalPlayer.Character or nil
end

local function getCharacterRoot(character)
	if not character then
		return nil
	end
	return character:FindFirstChild("Root")
		or character:FindFirstChild("HumanoidRootPart")
		or character.PrimaryPart
		or character:FindFirstChild("Head")
		or character:FindFirstChildWhichIsA("BasePart", true)
end

local function getAimPart(character)
	if not character then
		return nil
	end
	local body = character:FindFirstChild("Body")
	local bodyHead = body and body:FindFirstChild("Head")
	local bodyChest = body and body:FindFirstChild("Chest")
	if Config.PreferHead then
		return bodyHead
			or character:FindFirstChild("Head")
			or bodyChest
			or getCharacterRoot(character)
	end
	return bodyChest
		or getCharacterRoot(character)
		or bodyHead
		or character:FindFirstChild("Head")
end

local function isAliveCharacter(character)
	if typeof(CombatClient._AdapterIsAlive) == "function" then
		local ok, alive = pcall(CombatClient._AdapterIsAlive, character)
		if ok then
			return alive == true
		end
	end
	if not character or not character:IsA("Model") or character.Parent == nil then
		return false
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false
	end
	local okState, state = pcall(function()
		return hum:GetState()
	end)
	if okState and state == Enum.HumanoidStateType.Dead then
		return false
	end
	return true
end

local function isLocalPlayerAlive()
	if typeof(CombatClient._AdapterIsLocalAlive) == "function" then
		local ok, alive = pcall(CombatClient._AdapterIsLocalAlive)
		if ok then
			return alive == true
		end
	end
	return isAliveCharacter(getLocalCharacter())
end

local function getPlayerFromModel(model)
	if not model then
		return nil
	end
	local plr = Players:GetPlayerFromCharacter(model)
	if plr then
		return plr
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character == model or player.Name == model.Name then
			return player
		end
	end
	return nil
end

local function classifyModelRole(model, player)
	if typeof(CombatClient._AdapterClassifyRole) == "function" then
		local ok, role = pcall(CombatClient._AdapterClassifyRole, model, player)
		if ok and (role == "enemy" or role == "teammate" or role == "none") then
			return role
		end
	end
	local myChar = getLocalCharacter()
	if not model or model == myChar then
		return "none"
	end
	local plr = player or getPlayerFromModel(model)
	if plr == LocalPlayer then
		return "none"
	end
	if Config.IgnoreSameTeam and plr and LocalPlayer and LocalPlayer.Team and plr.Team then
		return (plr.Team == LocalPlayer.Team) and "teammate" or "enemy"
	end
	local attrTeam = model:GetAttribute("Team") or model:GetAttribute("TeamName")
	local myTeam = LocalPlayer and (LocalPlayer.Team or LocalPlayer:GetAttribute("Team") or LocalPlayer:GetAttribute("TeamName"))
	if attrTeam ~= nil and myTeam ~= nil then
		return (tostring(attrTeam) == tostring(myTeam)) and "teammate" or "enemy"
	end
	return "enemy"
end

local function getCandidateModels(includeTeammates)
	if typeof(CombatClient._AdapterGetCandidates) == "function" then
		local ok, list = pcall(CombatClient._AdapterGetCandidates, includeTeammates)
		if ok and typeof(list) == "table" then
			return list
		end
	end

	local entries = {}
	local seen = {}
	local myChar = getLocalCharacter()

	if Config.TargetPlayers then
		for _, player in ipairs(Players:GetPlayers()) do
			if player == LocalPlayer or player.Parent ~= Players then
				continue
			end
			local char = player.Character
			if not char or char == myChar or seen[char] or not isAliveCharacter(char) then
				continue
			end
			local role = classifyModelRole(char, player)
			if role ~= "enemy" and not (includeTeammates and role == "teammate") then
				continue
			end
			seen[char] = true
			table.insert(entries, {
				Player = player,
				Character = char,
				Name = player.Name,
				IsNPC = false,
				Role = role,
			})
		end
	end

	if Config.TargetNPCs then
		for _, child in ipairs(Workspace:GetChildren()) do
			if child:IsA("Model") and child ~= myChar and not seen[child] then
				if getPlayerFromModel(child) == nil and isAliveCharacter(child) then
					seen[child] = true
					table.insert(entries, {
						Player = nil,
						Character = child,
						Name = child.Name,
						IsNPC = true,
						Role = "enemy",
					})
				end
			end
		end
	end

	return entries
end

local function syncWallIgnoreList()
	local myChar = getLocalCharacter()
	local cam = Workspace.CurrentCamera
	if myChar == CachedIgnoreChar and cam == CachedIgnoreCam then
		return
	end
	CachedIgnoreChar = myChar
	CachedIgnoreCam = cam
	table.clear(WallIgnoreCache)
	if myChar then
		table.insert(WallIgnoreCache, myChar)
	end
	if LocalPlayer and LocalPlayer.Character and LocalPlayer.Character ~= myChar then
		table.insert(WallIgnoreCache, LocalPlayer.Character)
	end
	if cam then
		table.insert(WallIgnoreCache, cam)
	end
	WallRayParams.FilterDescendantsInstances = WallIgnoreCache
end

local function isClearOfWalls(origin, targetPart, targetCharacter)
	if not targetPart or not targetPart.Parent then
		return false
	end
	syncWallIgnoreList()
	local delta = targetPart.Position - origin
	if delta.Magnitude < 0.001 then
		return true
	end
	local result = Workspace:Raycast(origin, delta, WallRayParams)
	if not result then
		return true
	end
	local model = targetCharacter or targetPart:FindFirstAncestorOfClass("Model")
	return model ~= nil and result.Instance:IsDescendantOf(model)
end

local function computePriorityScore(dist, angleDeg, maxDist, maxAngleDeg, isLocked)
	local normDist = math.clamp(dist / math.max(maxDist, 1), 0, 1)
	local normAngle = math.clamp(angleDeg / math.max(maxAngleDeg, 1), 0, 1)
	local stickBonus = isLocked and -0.12 or 0

	if Config.PriorityMode == "Nearest" then
		return normDist + (normAngle * 0.2) + stickBonus
	elseif Config.PriorityMode == "Crosshair" then
		return normAngle + (normDist * 0.2) + stickBonus
	end
	return (normAngle * 0.55) + (normDist * 0.45) + stickBonus
end

local function isOwnHighlight(inst, expectedName)
	return typeof(inst) == "Instance"
		and inst:IsA("Highlight")
		and inst.Name == expectedName
		and inst:GetAttribute(SESSION_ATTR) == SESSION_ID
end

local function clearModelHighlight(model)
	local entry = Highlights[model]
	if entry then
		if entry.Instance and entry.Instance.Parent then
			pcall(function()
				entry.Instance:Destroy()
			end)
		end
		Highlights[model] = nil
	end
	if model and model.Parent then
		for _, child in ipairs(model:GetChildren()) do
			if isOwnHighlight(child, ENEMY_HL_NAME) or isOwnHighlight(child, TEAM_HL_NAME) then
				pcall(function()
					child:Destroy()
				end)
			end
		end
	end
end

local function clearAllHighlights()
	for model in pairs(Highlights) do
		clearModelHighlight(model)
	end
end

local function applyHighlightStyle(hl, role)
	hl.DepthMode = Config.ThroughWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
	hl.FillTransparency = Config.FillTransparency
	hl.OutlineTransparency = Config.OutlineTransparency
	if role == "teammate" then
		hl.FillColor = Config.TeammateFillColor
		hl.OutlineColor = Config.TeammateOutlineColor
	else
		hl.FillColor = Config.FillColor
		hl.OutlineColor = Config.OutlineColor
	end
end

local function updateHighlights()
	local showEnemy = Initialized and Config.HighlightEnabled == true
	local showTeam = Initialized and Config.TeammateHighlightEnabled == true
	if not showEnemy and not showTeam then
		clearAllHighlights()
		return
	end

	local cam = Workspace.CurrentCamera
	local myRoot = getCharacterRoot(getLocalCharacter())
	local originPos = myRoot and myRoot.Position or (cam and cam.CFrame.Position)
	if not originPos then
		return
	end

	local candidates = getCandidateModels(showTeam)
	local validSet = {}

	for _, entry in ipairs(candidates) do
		local model = entry.Character
		local role = entry.Role or classifyModelRole(model, entry.Player)
		if role == "enemy" and not showEnemy then
			continue
		elseif role == "teammate" and not showTeam then
			continue
		elseif role ~= "enemy" and role ~= "teammate" then
			continue
		end

		local root = getCharacterRoot(model)
		if not root or (root.Position - originPos).Magnitude > Config.MaxDistance then
			continue
		end

		validSet[model] = true
		local desiredName = (role == "teammate") and TEAM_HL_NAME or ENEMY_HL_NAME
		local entryHL = Highlights[model]
		local hl = entryHL and entryHL.Instance

		if not hl or not hl.Parent or not isOwnHighlight(hl, desiredName) then
			clearModelHighlight(model)
			hl = Instance.new("Highlight")
			hl.Name = desiredName
			hl:SetAttribute(SESSION_ATTR, SESSION_ID)
			hl.Adornee = model
			hl.Parent = model
			Highlights[model] = {
				Instance = hl,
				Role = role,
			}
		end

		applyHighlightStyle(hl, role)
	end

	for model in pairs(Highlights) do
		if not validSet[model] then
			clearModelHighlight(model)
		end
	end
end

function CombatClient.GetAssistTarget(origin, direction)
	if not Initialized or not Config.AssistEnabled or Config.Mode == "Off" or not isLocalPlayerAlive() then
		resetLockState()
		return nil
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		return nil
	end

	local unitDir = direction.Unit
	local maxAngleRad = math.rad(Config.AssistMaxAngleDegrees)
	local maxDist = Config.AssistMaxDistance
	local maxDistSq = maxDist * maxDist
	local candidates = getCandidateModels(false)
	local checkWalls = Config.WallCheck == true
	local now = os.clock()

	local bestTarget = nil
	local bestScore = math.huge
	local lockedTarget = nil

	for _, entry in ipairs(candidates) do
		local character = entry.Character
		if entry.Role and entry.Role ~= "enemy" then
			continue
		end
		if not isAliveCharacter(character) then
			continue
		end
		local aimPart = getAimPart(character)
		if not aimPart then
			continue
		end

		local offset = aimPart.Position - origin
		local distSq = offset:Dot(offset)
		if distSq < 0.000001 or distSq > maxDistSq then
			continue
		end

		local dist = math.sqrt(distSq)
		local angle = math.acos(math.clamp(unitDir:Dot(offset / dist), -1, 1))
		if angle > maxAngleRad then
			continue
		end

		if checkWalls and not isClearOfWalls(origin, aimPart, character) then
			continue
		end

		local angleDeg = math.deg(angle)
		local isLocked = (LockState.Character == character)
		local score = computePriorityScore(dist, angleDeg, maxDist, Config.AssistMaxAngleDegrees, isLocked)

		local built = {
			Player = entry.Player,
			Character = character,
			Name = entry.Name,
			IsNPC = entry.IsNPC,
			Part = aimPart,
			Position = aimPart.Position,
			Distance = dist,
			AngleDegrees = angleDeg,
			Score = score,
		}

		if isLocked then
			lockedTarget = built
		end
		if score < bestScore then
			bestScore = score
			bestTarget = built
		end
	end

	if bestTarget then
		LockState.Character = bestTarget.Character
		LockState.LastValidAt = now
		traceThrottled("Target", 0.5, "Selected:", bestTarget.Name, string.format("%.1f studs", bestTarget.Distance))
		return bestTarget
	end

	if lockedTarget then
		LockState.LastValidAt = now
		return lockedTarget
	end

	if LockState.Character and isAliveCharacter(LockState.Character) and (now - LockState.LastValidAt) <= Config.LockHoldSeconds then
		local aimPart = getAimPart(LockState.Character)
		if aimPart and (not checkWalls or isClearOfWalls(origin, aimPart, LockState.Character)) then
			local offset = aimPart.Position - origin
			local dist = offset.Magnitude
			if dist >= 0.001 and dist <= maxDist then
				local plr = getPlayerFromModel(LockState.Character)
				return {
					Player = plr,
					Character = LockState.Character,
					Name = plr and plr.Name or LockState.Character.Name,
					IsNPC = plr == nil,
					Part = aimPart,
					Position = aimPart.Position,
					Distance = dist,
					AngleDegrees = math.deg(math.acos(math.clamp(unitDir:Dot(offset / dist), -1, 1))),
					Score = 0,
				}
			end
		end
	end

	resetLockState()
	return nil
end

function CombatClient.GetAdjustedDirection(origin, direction)
	if not Initialized or not Config.AssistEnabled or Config.Mode == "Off" or not isLocalPlayerAlive() then
		return direction
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		return direction
	end
	local cand = CombatClient.GetAssistTarget(origin, direction)
	if not cand or not cand.Position then
		return direction
	end
	local delta = cand.Position - origin
	if delta.Magnitude < 0.001 then
		return direction
	end
	return delta.Unit * direction.Magnitude
end

function CombatClient.IsSilentAimActive()
	return Initialized
		and Config.AssistEnabled == true
		and Config.Mode == "SilentAim"
		and isLocalPlayerAlive()
end

local function stepSmartCamera(dt)
	if not Initialized or not Config.AssistEnabled or Config.Mode ~= "Camera" or not isLocalPlayerAlive() then
		resetLockState()
		return
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	local origin = cam.CFrame.Position
	local cand = CombatClient.GetAssistTarget(origin, cam.CFrame.LookVector)
	if not cand or not cand.Position then
		return
	end

	local maxSmooth = isBadBusinessPlace() and 0.14 or 0.45
	local smooth = math.min(Config.CameraSmoothness, maxSmooth)
	local alpha = math.clamp(1 - ((1 - smooth) ^ (dt * 60)), 0, maxSmooth)

	local currentCf = cam.CFrame
	local targetCf = CFrame.lookAt(currentCf.Position, cand.Position)
	local rx, ry, rz = currentCf:ToObjectSpace(targetCf):ToEulerAnglesYXZ()
	cam.CFrame = currentCf * CFrame.fromEulerAnglesYXZ(rx * alpha, ry * alpha, rz * alpha)
end

local function bindCameraStep()
	local targetPriority = Enum.RenderPriority.Camera.Value + (tonumber(Config.CameraPriorityOffset) or 1)
	if BoundPriority == targetPriority then
		return
	end
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	RunService:BindToRenderStep(RENDER_STEP_NAME, targetPriority, stepSmartCamera)
	BoundPriority = targetPriority
end

function CombatClient.SetConfig(partial)
	if typeof(partial) ~= "table" then
		return
	end
	local fpsDirty = false
	local priorityDirty = false
	for k, v in pairs(partial) do
		if Config[k] ~= nil then
			Config[k] = v
			if k == "FPSControlEnabled" or k == "FPSCap" then
				fpsDirty = true
			elseif k == "CameraPriorityOffset" then
				priorityDirty = true
			end
		end
	end
	if fpsDirty then
		applyFpsCap()
	end
	if Initialized then
		if priorityDirty then
			bindCameraStep()
		end
		updateHighlights()
	end
end

function CombatClient.GetConfig()
	return table.clone(Config)
end

function CombatClient.Destroy()
	Initialized = false
	BoundPriority = nil
	CachedIgnoreChar = nil
	CachedIgnoreCam = nil
	resetLockState()
	if typeof(CombatClient._AdapterDestroy) == "function" then
		pcall(CombatClient._AdapterDestroy)
	end
	if fnSetFpsCap then
		pcall(fnSetFpsCap, 0)
	end
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	for _, conn in ipairs(Connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(Connections)
	clearAllHighlights()
	log("Destroyed.")
end

function CombatClient.Init(userConfig)
	if not RunService:IsClient() then
		warn("[CombatClient] Client only.")
		return
	end
	CombatClient.Destroy()

	Config = table.clone(DEFAULTS)
	if typeof(userConfig) == "table" then
		for k, v in pairs(userConfig) do
			if Config[k] ~= nil then
				Config[k] = v
			end
		end
	end

	Initialized = true
	applyFpsCap()
	bindCameraStep()

	if LocalPlayer then
		table.insert(Connections, LocalPlayer.CharacterAdded:Connect(function()
			resetLockState()
			if Initialized then
				task.defer(updateHighlights)
			end
		end))
	end

	table.insert(Connections, Players.PlayerRemoving:Connect(function(player)
		if LockState.Character == player.Character then
			resetLockState()
		end
		if player.Character then
			clearModelHighlight(player.Character)
		end
	end))

	table.insert(Connections, RunService.Heartbeat:Connect(function(dt)
		if not Initialized then
			return
		end
		HighlightAccum += dt
		if HighlightAccum >= 0.2 then
			HighlightAccum = 0
			updateHighlights()
		end
	end))

	if typeof(CombatClient._AdapterInit) == "function" then
		pcall(CombatClient._AdapterInit, CombatClient)
	end

	updateHighlights()
	log("Initialized | PlaceId:", game.PlaceId)
	return CombatClient
end

CombatClient.Init()

env.CombatClient = CombatClient
env.PremiumCombat = CombatClient
_G.CombatClient = CombatClient
_G.PremiumCombat = CombatClient

-- ===================== OBSIDIAN UI (UNIFIED) =====================
task.spawn(function()
	local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
	local okFetch, rawSrc = pcall(function()
		return game:HttpGet(repo .. "Library.lua")
	end)
	if not okFetch or typeof(rawSrc) ~= "string" or #rawSrc == 0 then
		return
	end
	local okChunk, chunk = pcall(loadstring, rawSrc)
	if not okChunk or typeof(chunk) ~= "function" then
		return
	end
	local okLib, Library = pcall(chunk)
	if not okLib or not Library then
		return
	end

	local Window = Library:CreateWindow({
		Title = "CombatClient",
		Footer = isBadBusinessPlace() and "Bad Business | Obsidian UI" or "Universal | Obsidian UI",
		ToggleKeybind = Enum.KeyCode.RightShift,
		NotifySide = "Right",
		ShowCustomCursor = false,
	})

	local CombatTab = Window:AddTab({
		Name = "Combat",
		Description = "Silent Aim & Camera",
		Icon = "crosshair",
	})
	local VisualsTab = Window:AddTab({
		Name = "Visuals",
		Description = "Highlights & Session",
		Icon = "eye",
	})

	local AimBox = CombatTab:AddLeftGroupbox("Aim & Silent Aim", "target")
	local FilterBox = CombatTab:AddRightGroupbox("Target Filters", "sliders")
	local EspBox = VisualsTab:AddLeftGroupbox("Chams / Highlights", "scan-eye")
	local SysBox = VisualsTab:AddRightGroupbox("Session & FPS", "wrench")

	AimBox:AddToggle("AssistEnabled", {
		Text = "Enable Assist",
		Default = Config.AssistEnabled,
		Callback = function(v)
			CombatClient.SetConfig({ AssistEnabled = v })
			if not v then
				resetLockState()
			end
		end,
	})
	AimBox:AddDropdown("AssistMode", {
		Text = "Aim Mode",
		Values = { "SilentAim", "Camera", "Off" },
		Default = Config.Mode,
		Multi = false,
		Callback = function(v)
			CombatClient.SetConfig({ Mode = v })
		end,
	})
	AimBox:AddDropdown("PriorityMode", {
		Text = "Target Priority",
		Values = { "Smart", "Nearest", "Crosshair" },
		Default = Config.PriorityMode,
		Multi = false,
		Callback = function(v)
			CombatClient.SetConfig({ PriorityMode = v })
		end,
	})
	AimBox:AddSlider("CameraSmoothness", {
		Text = "Camera Smoothness",
		Default = Config.CameraSmoothness,
		Min = 0.02,
		Max = 1,
		Rounding = 2,
		Callback = function(v)
			CombatClient.SetConfig({ CameraSmoothness = v })
		end,
	})
	AimBox:AddSlider("LockHoldSeconds", {
		Text = "Lock Hold (sec)",
		Default = Config.LockHoldSeconds,
		Min = 0,
		Max = 1,
		Rounding = 2,
		Callback = function(v)
			CombatClient.SetConfig({ LockHoldSeconds = v })
		end,
	})

	FilterBox:AddToggle("TargetPlayers", {
		Text = "Target Players",
		Default = Config.TargetPlayers,
		Callback = function(v)
			CombatClient.SetConfig({ TargetPlayers = v })
		end,
	})
	FilterBox:AddToggle("TargetNPCs", {
		Text = "Target NPCs",
		Default = Config.TargetNPCs,
		Callback = function(v)
			CombatClient.SetConfig({ TargetNPCs = v })
		end,
	})
	FilterBox:AddToggle("PreferHead", {
		Text = "Prefer Head",
		Default = Config.PreferHead,
		Callback = function(v)
			CombatClient.SetConfig({ PreferHead = v })
		end,
	})
	FilterBox:AddToggle("WallCheck", {
		Text = "Wall Check",
		Default = Config.WallCheck,
		Callback = function(v)
			CombatClient.SetConfig({ WallCheck = v })
		end,
	})
	FilterBox:AddToggle("IgnoreTeam", {
		Text = "Ignore Same Team",
		Default = Config.IgnoreSameTeam,
		Callback = function(v)
			CombatClient.SetConfig({ IgnoreSameTeam = v })
		end,
	})
	FilterBox:AddSlider("MaxAngle", {
		Text = "Max Angle / FOV (Deg)",
		Default = Config.AssistMaxAngleDegrees,
		Min = 1,
		Max = 90,
		Rounding = 0,
		Callback = function(v)
			CombatClient.SetConfig({ AssistMaxAngleDegrees = v })
		end,
	})
	FilterBox:AddSlider("MaxAssistDist", {
		Text = "Max Assist Distance",
		Default = Config.AssistMaxDistance,
		Min = 25,
		Max = 1000,
		Rounding = 0,
		Callback = function(v)
			CombatClient.SetConfig({ AssistMaxDistance = v })
		end,
	})

	-- Unified Chams / Highlights (works for both general & Bad Business roles)
	EspBox:AddToggle("HighlightEnabled", {
		Text = "Enemy Chams",
		Default = Config.HighlightEnabled,
		Callback = function(v)
			CombatClient.SetConfig({ HighlightEnabled = v })
		end,
	})
	EspBox:AddToggle("TeammateHighlightEnabled", {
		Text = "Teammate Chams",
		Default = Config.TeammateHighlightEnabled,
		Callback = function(v)
			CombatClient.SetConfig({ TeammateHighlightEnabled = v })
		end,
	})
	EspBox:AddToggle("ThroughWalls", {
		Text = "Always On Top",
		Default = Config.ThroughWalls,
		Callback = function(v)
			CombatClient.SetConfig({ ThroughWalls = v })
		end,
	})
	EspBox:AddSlider("EspMaxDist", {
		Text = "Chams Max Distance",
		Default = Config.MaxDistance,
		Min = 50,
		Max = 1500,
		Rounding = 0,
		Callback = function(v)
			CombatClient.SetConfig({ MaxDistance = v })
		end,
	})

	SysBox:AddToggle("FPSControlEnabled", {
		Text = "Custom FPS Cap",
		Default = Config.FPSControlEnabled,
		Callback = function(v)
			CombatClient.SetConfig({ FPSControlEnabled = v })
		end,
	})
	SysBox:AddSlider("FPSCapSlider", {
		Text = "Target FPS",
		Default = Config.FPSCap,
		Min = 30,
		Max = 240,
		Rounding = 0,
		Callback = function(v)
			CombatClient.SetConfig({ FPSCap = v })
		end,
	})
	SysBox:AddButton({
		Text = "Unload & Cleanup",
		Func = function()
			CombatClient.Destroy()
			pcall(function()
				Library:Unload()
			end)
		end,
	})

	env.ObsidianLibrary = Library
	env.CombatToggles = Library.Toggles
	env.CombatOptions = Library.Options
end)

return CombatClient
