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

local function getExecutorFn(name)
	local fn = rawget(env, name)
	if typeof(fn) == "function" then
		return fn
	end
	fn = rawget(_G, name)
	if typeof(fn) == "function" then
		return fn
	end
	local ok, gFn = pcall(function()
		return _G[name]
	end)
	if ok and typeof(gFn) == "function" then
		return gFn
	end
	return nil
end

local fnHookMetamethod = getExecutorFn("hookmetamethod")
local fnGetNamecallMethod = getExecutorFn("getnamecallmethod")
local fnNewCClosure = getExecutorFn("newcclosure")
local fnCheckCaller = getExecutorFn("checkcaller")
local fnSetFpsCap = getExecutorFn("setfpscap") or getExecutorFn("set_fps_cap")

local function wrapCClosure(fn)
	if not fnNewCClosure then
		return fn
	end
	local ok, wrapped = pcall(fnNewCClosure, fn)
	return (ok and typeof(wrapped) == "function") and wrapped or fn
end

local function isOwnCaller()
	if not fnCheckCaller then
		return false
	end
	local ok, res = pcall(fnCheckCaller)
	return ok and res == true
end

if env.CombatClient and typeof(env.CombatClient.Destroy) == "function" then
	pcall(function()
		env.CombatClient.Destroy()
	end)
end

local CombatClient = {}

local BAD_BUSINESS_PLACE_IDS = {
	[11379161761] = true,
	[3233893879] = true,
}

local function isBadBusinessPlace()
	return BAD_BUSINESS_PLACE_IDS[game.PlaceId] == true
end

local SESSION_ID = HttpService:GenerateGUID(false)
local SESSION_ATTR = "CombatClientSession"
local HIGHLIGHT_NAME = "CombatClientHighlight"
local BB_HIGHLIGHT_NAME = "BBEnemyHighlight"
local BB_TEAM_HIGHLIGHT_NAME = "BBTeammateHighlight"
local RENDER_STEP_NAME = "CombatClient_SmartCameraStep"

local DEFAULTS = {
	Mode = "SilentAim",
	PriorityMode = "Smart",

	HighlightEnabled = true,
	MaxDistance = 500,
	ThroughWalls = true,
	FillColor = Color3.fromRGB(255, 65, 65),
	OutlineColor = Color3.fromRGB(255, 45, 45),
	FillTransparency = 0.85,
	OutlineTransparency = 0,

	AssistEnabled = true,
	TargetPlayers = true,
	TargetNPCs = true,
	AssistMaxDistance = 400,
	AssistMaxAngleDegrees = 25,
	WallCheck = false,
	IgnoreSameTeam = true,
	PreferHead = true,

	CameraSmoothness = 0.14,
	LockHoldSeconds = 0.12,
	CameraPriorityOffset = 4,

	BBChamsEnabled = true,
	BBTeammateChamsEnabled = true,
	TeammateFillColor = Color3.fromRGB(65, 145, 255),
	TeammateOutlineColor = Color3.fromRGB(45, 120, 245),
	BBMaxDistance = 600,
	BBThroughWalls = true,
	BBSilentAimEnabled = true,

	FPSControlEnabled = false,
	FPSCap = 120,

	DebugLogs = true,
	DebugTrace = true,
}

local Config = {}
local Connections = {}
local Highlights = {}
local BBHighlights = {}
local HookedOriginals = {}
local Initialized = false
local HookBusy = false
local HighlightAccum = 0
local BBAccum = 0
local MarkerCacheExpiry = 0
local LastTraceLogAt = 0
local CachedMarkers = {
	enemySet = {},
	nameGuiSet = {},
	foundAnyEnemyHighlight = false,
}

local WallRayParams = RaycastParams.new()
WallRayParams.FilterType = Enum.RaycastFilterType.Exclude
WallRayParams.IgnoreWater = true

local LockState = {
	Character = nil,
	LastValidAt = 0,
}

local function log(...)
	if Config.DebugLogs then
		print("[CombatClient]", ...)
	end
end

local function trace(tag, ...)
	if Config.DebugLogs and Config.DebugTrace then
		print(string.format("[CombatClient:%s]", tostring(tag)), ...)
	end
end

local function traceThrottled(intervalSec, tag, ...)
	if not (Config.DebugLogs and Config.DebugTrace) then
		return
	end
	local now = os.clock()
	if (now - LastTraceLogAt) >= (intervalSec or 0.5) then
		LastTraceLogAt = now
		print(string.format("[CombatClient:%s]", tostring(tag)), ...)
	end
end

local function describeValue(v, depth)
	depth = depth or 0
	local t = typeof(v)
	if t == "Vector3" then
		return string.format("Vector3(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
	elseif t == "CFrame" then
		local p = v.Position
		return string.format("CFrame(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
	elseif t == "Instance" then
		return string.format("%s(%s)", v.ClassName, v:GetFullName())
	elseif t == "table" then
		if depth >= 2 then
			return "{...}"
		end
		local parts = {}
		local count = 0
		for k, val in pairs(v) do
			count += 1
			if count > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, string.format("[%s]=%s", tostring(k), describeValue(val, depth + 1)))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	else
		return string.format("%s(%s)", t, tostring(v))
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
	local targetFps = Config.FPSControlEnabled and math.clamp(tonumber(Config.FPSCap) or 120, 15, 360) or 0
	pcall(fnSetFpsCap, targetFps)
end

local function isIgnoredBBModelName(name)
	if typeof(name) ~= "string" then
		return true
	end
	if name == "Proxy" or name == "Arms" or name == "DisplayCharacter" or name == "Body" or name == "ClasBaseWeapon" then
		return true
	end
	if string.sub(name, 1, 14) == "DroppedWeapon_" then
		return true
	end
	return false
end

local function resolveBBCharacterModel(inst, charsFolder)
	if not inst or not charsFolder then
		return nil
	end
	local ok, current = pcall(function()
		return inst:IsA("Model") and inst or inst:FindFirstAncestorOfClass("Model")
	end)
	if not ok then
		return nil
	end
	while current and current.Parent do
		if current.Parent == charsFolder and current:IsA("Model") then
			return isIgnoredBBModelName(current.Name) and nil or current
		end
		current = current.Parent
	end
	return nil
end

local function scanPlayerGuiMarkers(forceRefresh)
	local now = os.clock()
	if not forceRefresh and now < MarkerCacheExpiry then
		return CachedMarkers
	end

	local enemySet = {}
	local nameGuiSet = {}
	local foundAnyEnemyHighlight = false

	pcall(function()
		local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		local charsFolder = Workspace:FindFirstChild("Characters")
		if pg and charsFolder then
			for _, desc in ipairs(pg:GetDescendants()) do
				if desc:IsA("Highlight") and desc.Enabled then
					local model = resolveBBCharacterModel(desc.Adornee, charsFolder)
					if model then
						local fc = desc.FillColor
						if fc.R >= 0.65 and fc.G <= 0.35 and fc.B <= 0.35 then
							enemySet[model] = true
							foundAnyEnemyHighlight = true
						end
					end
				elseif desc.Name == "NameGui" and desc:IsA("BillboardGui") and desc.Enabled then
					local model = resolveBBCharacterModel(desc.Adornee, charsFolder)
					if model then
						nameGuiSet[model] = true
					end
				end
			end
		end
	end)

	CachedMarkers.enemySet = enemySet
	CachedMarkers.nameGuiSet = nameGuiSet
	CachedMarkers.foundAnyEnemyHighlight = foundAnyEnemyHighlight
	MarkerCacheExpiry = now + 0.2
	return CachedMarkers
end

local function getBBLocalCharacter()
	local charsFolder = Workspace:FindFirstChild("Characters")
	if charsFolder and LocalPlayer then
		local direct = charsFolder:FindFirstChild(LocalPlayer.Name)
		if direct and direct:IsA("Model") and not isIgnoredBBModelName(direct.Name) then
			return direct
		end
		for _, child in ipairs(charsFolder:GetChildren()) do
			if child:IsA("Model") and not isIgnoredBBModelName(child.Name) then
				local plrAttr = child:GetAttribute("Player") or child:GetAttribute("UserId")
				if plrAttr == LocalPlayer or plrAttr == LocalPlayer.UserId then
					return child
				end
			end
		end
	end
	if LocalPlayer and LocalPlayer.Character and not isIgnoredBBModelName(LocalPlayer.Character.Name) then
		return LocalPlayer.Character
	end
	return nil
end

local function getPlayerFromCharacter(model)
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

local function getCharacterRoot(character)
	if not character then
		return nil
	end
	local ok, part = pcall(function()
		return character:FindFirstChild("Root")
			or character:FindFirstChild("HumanoidRootPart")
			or character.PrimaryPart
			or character:FindFirstChild("Head")
			or character:FindFirstChildWhichIsA("BasePart", true)
	end)
	return ok and part or nil
end

local function getAimPart(character)
	if not character then
		return nil
	end
	local ok, part = pcall(function()
		local body = character:FindFirstChild("Body")
		local bodyHead = body and body:FindFirstChild("Head")
		local bodyChest = body and body:FindFirstChild("Chest")
		if Config.PreferHead then
			return bodyHead
				or character:FindFirstChild("Head")
				or bodyChest
				or character:FindFirstChild("Root")
				or character:FindFirstChild("HumanoidRootPart")
				or getCharacterRoot(character)
		end
		return bodyChest
			or character:FindFirstChild("Root")
			or character:FindFirstChild("HumanoidRootPart")
			or bodyHead
			or character:FindFirstChild("Head")
			or getCharacterRoot(character)
	end)
	return ok and part or nil
end

local function isAliveCharacter(character)
	if not character or not character:IsA("Model") or character.Parent == nil then
		return false
	end
	if isBadBusinessPlace() and isIgnoredBBModelName(character.Name) then
		return false
	end

	local ok, alive = pcall(function()
		local healthVal = character:FindFirstChild("Health")
		if healthVal and healthVal:IsA("ValueBase") and tonumber(healthVal.Value) and tonumber(healthVal.Value) <= 0 then
			return false
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			if humanoid.Health <= 0 then
				return false
			end
			if humanoid:GetState() == Enum.HumanoidStateType.Dead then
				return false
			end
		end

		local healthAttr = character:GetAttribute("Health")
		if typeof(healthAttr) == "number" and healthAttr <= 0 then
			return false
		end

		if not humanoid and not healthVal and typeof(healthAttr) ~= "number" then
			local root = character:FindFirstChild("Root") or character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Body")
			if not root then
				return false
			end
		end

		return true
	end)
	return ok and alive == true
end

local function isLocalPlayerAlive()
	if isBadBusinessPlace() then
		return Workspace.CurrentCamera ~= nil
	end
	local char = LocalPlayer and LocalPlayer.Character
	return isAliveCharacter(char)
end

local function getLocalTeamValue()
	if LocalPlayer and LocalPlayer.Team then
		return LocalPlayer.Team
	end
	local attrTeam = LocalPlayer and (LocalPlayer:GetAttribute("Team") or LocalPlayer:GetAttribute("TeamName"))
	if attrTeam ~= nil then
		return attrTeam
	end
	local myChar = isBadBusinessPlace() and getBBLocalCharacter() or (LocalPlayer and LocalPlayer.Character)
	if myChar then
		return myChar:GetAttribute("Team") or myChar:GetAttribute("TeamName")
	end
	return nil
end

local function classifyBBModel(model, player, markerCache)
	if not model or not model:IsA("Model") or isIgnoredBBModelName(model.Name) then
		return "none"
	end
	local myChar = getBBLocalCharacter()
	if model == myChar then
		return "none"
	end
	local plr = player or getPlayerFromCharacter(model)
	if plr == LocalPlayer then
		return "none"
	end

	if markerCache.nameGuiSet[model] then
		return "teammate"
	end
	if markerCache.foundAnyEnemyHighlight then
		return markerCache.enemySet[model] and "enemy" or "teammate"
	end
	return "enemy"
end

local function isEnemyModel(model, player, markerCache)
	if not model or not model:IsA("Model") or isIgnoredBBModelName(model.Name) then
		return false
	end

	local myChar = isBadBusinessPlace() and getBBLocalCharacter() or (LocalPlayer and LocalPlayer.Character)
	if model == myChar then
		return false
	end

	local plr = player or getPlayerFromCharacter(model)
	if plr == LocalPlayer then
		return false
	end

	if isBadBusinessPlace() then
		return classifyBBModel(model, plr, markerCache) == "enemy"
	end

	local modelTeam = model:GetAttribute("Team") or model:GetAttribute("TeamName")
	local myTeam = getLocalTeamValue()
	if modelTeam ~= nil and myTeam ~= nil then
		return tostring(modelTeam) ~= tostring(myTeam)
	end

	if Config.IgnoreSameTeam and plr and LocalPlayer and LocalPlayer.Team and plr.Team then
		return plr.Team ~= LocalPlayer.Team
	end

	return true
end

local function isModelAllowedByFilters(model)
	local myChar = isBadBusinessPlace() and getBBLocalCharacter() or (LocalPlayer and LocalPlayer.Character)
	if not model or model == myChar or not isAliveCharacter(model) then
		return false
	end
	local markerCache = isBadBusinessPlace() and scanPlayerGuiMarkers(false) or CachedMarkers
	local plr = getPlayerFromCharacter(model)
	if plr then
		return Config.TargetPlayers == true and isEnemyModel(model, plr, markerCache)
	end
	if isBadBusinessPlace() then
		return isEnemyModel(model, nil, markerCache)
	end
	return Config.TargetNPCs == true
end

local function collectBBCharacterModels()
	local models = {}
	local charsFolder = Workspace:FindFirstChild("Characters")
	if not charsFolder then
		return models
	end

	for _, child in ipairs(charsFolder:GetChildren()) do
		if child:IsA("Model") and not isIgnoredBBModelName(child.Name) then
			if child:FindFirstChild("Root") or child:FindFirstChild("Body") or child:FindFirstChild("Hitbox") then
				table.insert(models, child)
			end
		end
	end

	return models
end

local function getCandidateModels()
	local entries = {}
	local seenModels = {}
	local myChar = isBadBusinessPlace() and getBBLocalCharacter() or (LocalPlayer and LocalPlayer.Character)

	if isBadBusinessPlace() then
		local markerCache = scanPlayerGuiMarkers(false)
		for _, model in ipairs(collectBBCharacterModels()) do
			if model ~= myChar and not seenModels[model] and isAliveCharacter(model) and isEnemyModel(model, nil, markerCache) then
				seenModels[model] = true
				local plr = getPlayerFromCharacter(model)
				table.insert(entries, {
					Player = plr,
					Character = model,
					Name = plr and plr.Name or model.Name,
					IsNPC = plr == nil,
				})
			end
		end
		return entries
	end

	if Config.TargetPlayers then
		for _, player in ipairs(Players:GetPlayers()) do
			if player == LocalPlayer or player.Parent ~= Players then
				continue
			end
			local char = player.Character
			if not char or char == myChar or seenModels[char] or not isAliveCharacter(char) then
				continue
			end
			if not isEnemyModel(char, player, CachedMarkers) then
				continue
			end
			seenModels[char] = true
			table.insert(entries, {
				Player = player,
				Character = char,
				Name = player.Name,
				IsNPC = false,
			})
		end
	end

	if Config.TargetNPCs then
		for _, child in ipairs(Workspace:GetChildren()) do
			if child:IsA("Model") and child ~= myChar and not seenModels[child] then
				if getPlayerFromCharacter(child) == nil and isAliveCharacter(child) then
					seenModels[child] = true
					table.insert(entries, {
						Player = nil,
						Character = child,
						Name = child.Name,
						IsNPC = true,
					})
				end
			end
		end
	end

	return entries
end

local function isClearOfWalls(origin, targetPart)
	if not targetPart or not targetPart.Parent then
		return false
	end

	local ignoreList = {}
	local myChar = isBadBusinessPlace() and getBBLocalCharacter() or (LocalPlayer and LocalPlayer.Character)
	if myChar then
		table.insert(ignoreList, myChar)
	end
	if LocalPlayer and LocalPlayer.Character and LocalPlayer.Character ~= myChar then
		table.insert(ignoreList, LocalPlayer.Character)
	end
	if Workspace.CurrentCamera then
		table.insert(ignoreList, Workspace.CurrentCamera)
	end
	local charsFolder = Workspace:FindFirstChild("Characters")
	if charsFolder then
		table.insert(ignoreList, charsFolder)
	end
	WallRayParams.FilterDescendantsInstances = ignoreList

	local offset = targetPart.Position - origin
	if offset.Magnitude < 0.001 then
		return true
	end

	local ok, result = pcall(function()
		return Workspace:Raycast(origin, offset, WallRayParams)
	end)
	return ok and result == nil
end

local function computePriorityScore(dist, angleDeg, maxDist, maxAngleDeg, isCurrentLock)
	local normDist = math.clamp(dist / math.max(maxDist, 1), 0, 1)
	local normAngle = math.clamp(angleDeg / math.max(maxAngleDeg, 1), 0, 1)
	local stickBonus = isCurrentLock and -0.12 or 0

	if Config.PriorityMode == "Nearest" then
		return normDist + (normAngle * 0.2) + stickBonus
	elseif Config.PriorityMode == "Crosshair" then
		return normAngle + (normDist * 0.2) + stickBonus
	else
		return (normAngle * 0.55) + (normDist * 0.45) + stickBonus
	end
end

local function isOwnHighlight(inst, expectedName)
	local nameToMatch = expectedName or HIGHLIGHT_NAME
	return typeof(inst) == "Instance"
		and inst:IsA("Highlight")
		and inst.Name == nameToMatch
		and inst:GetAttribute(SESSION_ATTR) == SESSION_ID
end

local function clearCharacterHighlight(character)
	local entry = Highlights[character]
	if entry then
		if entry.Instance and entry.Instance.Parent and isOwnHighlight(entry.Instance, HIGHLIGHT_NAME) then
			pcall(function()
				entry.Instance:Destroy()
			end)
		end
		Highlights[character] = nil
	end

	if character and character.Parent then
		for _, child in ipairs(character:GetChildren()) do
			if isOwnHighlight(child, HIGHLIGHT_NAME) then
				pcall(function()
					child:Destroy()
				end)
			end
		end
	end
end

local function clearAllHighlights()
	for char in pairs(Highlights) do
		clearCharacterHighlight(char)
	end
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if isOwnHighlight(obj, HIGHLIGHT_NAME) then
			pcall(function()
				obj:Destroy()
			end)
		end
	end
end

local function updateHighlights()
	if isBadBusinessPlace() then
		clearAllHighlights()
		return
	end

	if not Initialized or not Config.HighlightEnabled or not isLocalPlayerAlive() then
		clearAllHighlights()
		return
	end

	local myRoot = getCharacterRoot(LocalPlayer and LocalPlayer.Character)
	if not myRoot then
		clearAllHighlights()
		return
	end

	local myPos = myRoot.Position
	local validSet = {}
	local candidates = getCandidateModels()

	for _, entry in ipairs(candidates) do
		local character = entry.Character
		local root = getCharacterRoot(character)
		if not character or not root then
			continue
		end

		if (root.Position - myPos).Magnitude > Config.MaxDistance then
			continue
		end

		validSet[character] = true

		local existing = Highlights[character]
		if existing and not isOwnHighlight(existing.Instance, HIGHLIGHT_NAME) then
			clearCharacterHighlight(character)
			existing = nil
		end

		if not existing then
			local hl = Instance.new("Highlight")
			hl.Name = HIGHLIGHT_NAME
			hl:SetAttribute(SESSION_ATTR, SESSION_ID)
			hl.Adornee = character
			hl.DepthMode = Config.ThroughWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
			hl.FillColor = Config.FillColor
			hl.OutlineColor = Config.OutlineColor
			hl.FillTransparency = Config.FillTransparency
			hl.OutlineTransparency = Config.OutlineTransparency
			hl.Parent = character

			Highlights[character] = {
				Instance = hl,
				Character = character,
			}
		end
	end

	for char in pairs(Highlights) do
		if not validSet[char] then
			clearCharacterHighlight(char)
		end
	end
end

local function clearBBModelHighlight(model)
	local entry = BBHighlights[model]
	if entry then
		if entry.Instance and entry.Instance.Parent and (isOwnHighlight(entry.Instance, BB_HIGHLIGHT_NAME) or isOwnHighlight(entry.Instance, BB_TEAM_HIGHLIGHT_NAME)) then
			pcall(function()
				entry.Instance:Destroy()
			end)
		end
		BBHighlights[model] = nil
	end
	if model and model.Parent then
		for _, child in ipairs(model:GetChildren()) do
			if isOwnHighlight(child, BB_HIGHLIGHT_NAME) or isOwnHighlight(child, BB_TEAM_HIGHLIGHT_NAME) then
				pcall(function()
					child:Destroy()
				end)
			end
		end
	end
end

local function clearAllBBHighlights()
	for model in pairs(BBHighlights) do
		clearBBModelHighlight(model)
	end
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if isOwnHighlight(obj, BB_HIGHLIGHT_NAME) or isOwnHighlight(obj, BB_TEAM_HIGHLIGHT_NAME) then
			pcall(function()
				obj:Destroy()
			end)
		end
	end
end

local function applyBBHighlightStyle(hl, role)
	hl.DepthMode = Config.BBThroughWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
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

local function updateBadBusinessChams()
	if not Initialized or not isBadBusinessPlace() or (not Config.BBChamsEnabled and not Config.BBTeammateChamsEnabled) then
		clearAllBBHighlights()
		return
	end

	local cam = Workspace.CurrentCamera
	local myChar = getBBLocalCharacter()
	local myAnchor = getCharacterRoot(myChar)
	local myPos = myAnchor and myAnchor.Position or (cam and cam.CFrame.Position)
	if not myPos then
		return
	end

	local markerCache = scanPlayerGuiMarkers(true)
	local validSet = {}

	for _, model in ipairs(collectBBCharacterModels()) do
		if model == myChar or not isAliveCharacter(model) then
			continue
		end
		local anchor = getCharacterRoot(model)
		if not anchor then
			continue
		end
		if (anchor.Position - myPos).Magnitude > Config.BBMaxDistance then
			continue
		end

		local role = classifyBBModel(model, nil, markerCache)
		if role == "enemy" and not Config.BBChamsEnabled then
			continue
		elseif role == "teammate" and not Config.BBTeammateChamsEnabled then
			continue
		elseif role ~= "enemy" and role ~= "teammate" then
			continue
		end

		validSet[model] = true
		local desiredName = role == "teammate" and BB_TEAM_HIGHLIGHT_NAME or BB_HIGHLIGHT_NAME
		local entry = BBHighlights[model]
		local hl = entry and entry.Instance

		if not hl or not hl.Parent or not isOwnHighlight(hl, desiredName) then
			clearBBModelHighlight(model)
			hl = Instance.new("Highlight")
			hl.Name = desiredName
			hl:SetAttribute(SESSION_ATTR, SESSION_ID)
			hl.Adornee = model
			hl.Parent = model
			BBHighlights[model] = {
				Instance = hl,
				Role = role,
			}
		end

		applyBBHighlightStyle(hl, role)
	end

	for model in pairs(BBHighlights) do
		if not validSet[model] then
			clearBBModelHighlight(model)
		end
	end
end

function CombatClient.GetAssistTarget(origin, direction)
	if not Initialized or not Config.AssistEnabled or not isLocalPlayerAlive() then
		resetLockState()
		traceThrottled(1.0, "Target", "nil | Initialized=", Initialized, "AssistEnabled=", Config.AssistEnabled, "Alive=", isLocalPlayerAlive())
		return nil
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		traceThrottled(1.0, "Target", "nil | bad origin/dir:", describeValue(origin), describeValue(direction))
		return nil
	end

	local okSearch, result = pcall(function()
		local unitDir = direction.Unit
		local maxAngleRad = math.rad(Config.AssistMaxAngleDegrees)
		local maxDist = Config.AssistMaxDistance
		local maxDistSq = maxDist * maxDist
		local candidates = getCandidateModels()
		local checkWalls = Config.WallCheck == true
		local now = os.clock()

		local bestTarget = nil
		local bestScore = math.huge
		local lockedEntryTarget = nil
		local rejectionSummary = {}

		for _, entry in ipairs(candidates) do
			local character = entry.Character
			if not isAliveCharacter(character) then
				table.insert(rejectionSummary, entry.Name .. ":dead")
				continue
			end

			local aimPart = getAimPart(character)
			if not aimPart then
				table.insert(rejectionSummary, entry.Name .. ":noPart")
				continue
			end

			local offset = aimPart.Position - origin
			local distSq = offset:Dot(offset)
			if distSq < 0.000001 or distSq > maxDistSq then
				table.insert(rejectionSummary, string.format("%s:dist(%.1f>%.1f)", entry.Name, math.sqrt(distSq), maxDist))
				continue
			end

			local dist = math.sqrt(distSq)
			local angle = math.acos(math.clamp(unitDir:Dot(offset / dist), -1, 1))
			if angle > maxAngleRad then
				table.insert(rejectionSummary, string.format("%s:ang(%.1f>%.1f)", entry.Name, math.deg(angle), Config.AssistMaxAngleDegrees))
				continue
			end

			if checkWalls and not isClearOfWalls(origin, aimPart) then
				table.insert(rejectionSummary, entry.Name .. ":wall")
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
				lockedEntryTarget = built
			end

			if score < bestScore then
				bestScore = score
				bestTarget = built
			end
		end

		if bestTarget then
			LockState.Character = bestTarget.Character
			LockState.LastValidAt = now
			traceThrottled(0.4, "Target", "SELECTED:", bestTarget.Name, "Part:", bestTarget.Part.Name, "Dist:", string.format("%.1f", bestTarget.Distance), "Ang:", string.format("%.1f", bestTarget.AngleDegrees), "Score:", string.format("%.3f", bestTarget.Score))
			return bestTarget
		end

		if lockedEntryTarget then
			LockState.LastValidAt = now
			traceThrottled(0.4, "Target", "LOCKED:", lockedEntryTarget.Name, "Part:", lockedEntryTarget.Part.Name)
			return lockedEntryTarget
		end

		if LockState.Character
			and isModelAllowedByFilters(LockState.Character)
			and (now - LockState.LastValidAt) <= Config.LockHoldSeconds
		then
			local aimPart = getAimPart(LockState.Character)
			if aimPart and (not checkWalls or isClearOfWalls(origin, aimPart)) then
				local offset = aimPart.Position - origin
				local dist = offset.Magnitude
				if dist >= 0.001 and dist <= maxDist then
					local plr = getPlayerFromCharacter(LockState.Character)
					traceThrottled(0.4, "Target", "HOLD:", LockState.Character.Name, "Part:", aimPart.Name)
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

		traceThrottled(0.8, "Target", "nil | candidates:", #candidates, "rejections:", #rejectionSummary > 0 and table.concat(rejectionSummary, ", ") or "none")
		resetLockState()
		return nil
	end)

	if not okSearch then
		trace("TargetError", tostring(result))
	end
	return okSearch and result or nil
end

local function isBBSilentAimActive()
	local active = Initialized
		and isBadBusinessPlace()
		and Config.BBSilentAimEnabled == true
		and Config.AssistEnabled == true
		and Config.Mode == "SilentAim"
		and isLocalPlayerAlive()
	return active
end

local function stepSmartCamera(dt)
	if not Initialized or not Config.AssistEnabled or Config.Mode ~= "Camera" then
		resetLockState()
		return
	end

	if not isLocalPlayerAlive() then
		resetLockState()
		return
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	local origin = cam.CFrame.Position
	local look = cam.CFrame.LookVector
	local candidate = CombatClient.GetAssistTarget(origin, look)
	if not candidate or not candidate.Position then
		return
	end

	local maxSmooth = isBadBusinessPlace() and 0.14 or 0.45
	local effectiveSmooth = math.min(Config.CameraSmoothness, maxSmooth)
	local alpha = math.clamp(1 - ((1 - effectiveSmooth) ^ (dt * 60)), 0, maxSmooth)

	local currentCf = cam.CFrame
	local targetCf = CFrame.lookAt(currentCf.Position, candidate.Position)
	local deltaCf = currentCf:ToObjectSpace(targetCf)
	local rx, ry, rz = deltaCf:ToEulerAnglesYXZ()
	local nextCf = currentCf * CFrame.fromEulerAnglesYXZ(rx * alpha, ry * alpha, rz * alpha)
	cam.CFrame = nextCf

	traceThrottled(0.5, "CameraStep", "Target:", candidate.Name, "alpha:", string.format("%.3f", alpha), "CamPos:", describeValue(nextCf.Position), "CamLook:", describeValue(nextCf.LookVector))
end

local function isValidUnitVector3(v)
	if typeof(v) ~= "Vector3" then
		return false
	end
	local mag = v.Magnitude
	return mag > 0.0001 and mag == mag and math.abs(mag) < math.huge
end

local function transformBBShotPayload(shotTable, origin, targetPos)
	if typeof(shotTable) ~= "table" or typeof(targetPos) ~= "Vector3" or typeof(origin) ~= "Vector3" then
		trace("Payload", "skip | invalid types:", typeof(shotTable), typeof(origin), typeof(targetPos))
		return nil
	end
	local delta = targetPos - origin
	if delta.Magnitude < 0.05 then
		trace("Payload", "skip | delta too small:", delta.Magnitude)
		return nil
	end
	local aimDir = delta.Unit
	if not isValidUnitVector3(aimDir) then
		trace("Payload", "skip | invalid aimDir:", describeValue(aimDir))
		return nil
	end

	local cloned = table.clone(shotTable)
	local modifiedCount = 0
	for idx, entry in pairs(cloned) do
		if typeof(entry) == "table" and typeof(entry[1]) == "Vector3" then
			local newEntry = table.clone(entry)
			trace("Payload", "entry[" .. tostring(idx) .. "] oldDir:", describeValue(entry[1]), "-> newDir:", describeValue(aimDir), "sub:", describeValue(entry[2]))
			newEntry[1] = aimDir
			cloned[idx] = newEntry
			modifiedCount += 1
		else
			trace("Payload", "entry[" .. tostring(idx) .. "] untouched:", describeValue(entry))
		end
	end
	trace("Payload", "modified entries:", modifiedCount)
	return modifiedCount > 0 and cloned or nil
end

local function installHooksOnce()
	if next(HookedOriginals) ~= nil then
		trace("Hook", "already installed")
		return
	end
	if not fnHookMetamethod or not fnGetNamecallMethod then
		log("hookmetamethod/getnamecallmethod not available. hookmetamethod:", typeof(fnHookMetamethod), "getnamecallmethod:", typeof(fnGetNamecallMethod))
		return
	end

	local oldNamecall
	local ok = pcall(function()
		oldNamecall = fnHookMetamethod(game, "__namecall", wrapCClosure(function(self, ...)
			local okMethod, method = pcall(fnGetNamecallMethod)
			if not okMethod or method ~= "FireServer" then
				return oldNamecall(self, ...)
			end

			local instName = typeof(self) == "Instance" and self.Name or tostring(self)
			local instClass = typeof(self) == "Instance" and self.ClassName or typeof(self)

			if HookBusy or isOwnCaller() then
				trace("FireServer", instClass .. ":" .. instName, "| bypassed (HookBusy=", HookBusy, "ownCaller=", isOwnCaller(), ")")
				return oldNamecall(self, ...)
			end

			local args = { ... }
			local bbActive = isBBSilentAimActive()
			if not bbActive then
				if instName == "Item_Paintball" or instName == "Projectiles" then
					traceThrottled(0.5, "FireServer", instClass .. ":" .. instName, "action=", tostring(args[1]), "| bbActive=false (Init=", Initialized, "BB=", isBadBusinessPlace(), "BBSilent=", Config.BBSilentAimEnabled, "Assist=", Config.AssistEnabled, "Mode=", Config.Mode, ")")
				end
				return oldNamecall(self, ...)
			end

			if typeof(self) ~= "Instance" or not self:IsA("RemoteEvent") or self.Name ~= "Item_Paintball" then
				if instName == "Projectiles" or string.find(string.lower(instName), "shoot", 1, true) or string.find(string.lower(instName), "ball", 1, true) then
					trace("FireServer", "other remote:", instClass .. ":" .. instName, "args:", describeValue(args))
				end
				return oldNamecall(self, ...)
			end

			trace("FireServer", "Item_Paintball | args[1]=" .. tostring(args[1]), "args[2]=" .. describeValue(args[2]), "args[3]=" .. describeValue(args[3]), "args[4]=" .. describeValue(args[4]))

			if args[1] ~= "Shoot" or typeof(args[4]) ~= "table" then
				trace("FireServer", "Item_Paintball skipped | action=" .. tostring(args[1]), "args[4] type=" .. typeof(args[4]))
				return oldNamecall(self, ...)
			end

			local cam = Workspace.CurrentCamera
			if not cam then
				trace("FireServer", "Item_Paintball skipped | CurrentCamera nil")
				return oldNamecall(self, ...)
			end

			local shotOrigin = typeof(args[3]) == "Vector3" and args[3] or cam.CFrame.Position
			local lookDir = cam.CFrame.LookVector
			trace("FireServer", "shotOrigin=", describeValue(shotOrigin), "camPos=", describeValue(cam.CFrame.Position), "lookDir=", describeValue(lookDir))

			HookBusy = true
			local okCand, cand = pcall(CombatClient.GetAssistTarget, shotOrigin, lookDir)
			local newPayload = nil
			if okCand and cand and typeof(cand.Position) == "Vector3" then
				newPayload = transformBBShotPayload(args[4], shotOrigin, cand.Position)
			else
				trace("FireServer", "no valid target | okCand=", okCand, "cand=", cand and cand.Name or "nil", "pos=", cand and describeValue(cand.Position) or "nil")
			end
			HookBusy = false

			if newPayload then
				args[4] = newPayload
				trace("FireServer", "REDIRECTED Item_Paintball:Shoot -> target:", cand.Name, "pos:", describeValue(cand.Position))
				return oldNamecall(self, table.unpack(args))
			end

			trace("FireServer", "PASSED THROUGH original Item_Paintball:Shoot (newPayload nil)")
			return oldNamecall(self, ...)
		end))
	end)

	if ok and typeof(oldNamecall) == "function" then
		HookedOriginals.Namecall = oldNamecall
		log("Hooks ready: __namecall (Item_Paintball.Shoot safe redirect + trace)")
	else
		log("Failed to install __namecall hook:", tostring(oldNamecall))
	end
end

function CombatClient.SetConfig(partial)
	if typeof(partial) ~= "table" then
		return
	end
	local fpsChanged = false
	for key, val in pairs(partial) do
		if Config[key] ~= nil then
			Config[key] = val
			if key == "FPSControlEnabled" or key == "FPSCap" then
				fpsChanged = true
			end
		end
	end
	if fpsChanged then
		applyFpsCap()
	end
	if Initialized then
		updateHighlights()
		updateBadBusinessChams()
	end
end

function CombatClient.GetConfig()
	return table.clone(Config)
end

function CombatClient.Destroy()
	Initialized = false
	resetLockState()
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
	clearAllBBHighlights()
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
		for key, val in pairs(userConfig) do
			if Config[key] ~= nil then
				Config[key] = val
			end
		end
	end

	Initialized = true
	applyFpsCap()
	installHooksOnce()

	if LocalPlayer then
		table.insert(Connections, LocalPlayer.CharacterAdded:Connect(function()
			resetLockState()
			if Initialized then
				task.defer(function()
					updateHighlights()
					updateBadBusinessChams()
				end)
			end
		end))
	end

	table.insert(Connections, Players.PlayerRemoving:Connect(function(player)
		if LockState.Character == player.Character then
			resetLockState()
		end
		if player.Character then
			clearCharacterHighlight(player.Character)
			clearBBModelHighlight(player.Character)
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

		if isBadBusinessPlace() then
			BBAccum += dt
			if BBAccum >= 0.25 then
				BBAccum = 0
				updateBadBusinessChams()
			end
		end
	end))

	pcall(function()
		RunService:BindToRenderStep(
			RENDER_STEP_NAME,
			Enum.RenderPriority.Camera.Value + Config.CameraPriorityOffset,
			stepSmartCamera
		)
	end)

	updateHighlights()
	updateBadBusinessChams()
	log("Initialized | PlaceId:", game.PlaceId, "| BadBusiness:", isBadBusinessPlace(), "| Mode:", Config.Mode, "| Priority:", Config.PriorityMode, "| Trace:", Config.DebugTrace)
	return CombatClient
end

CombatClient.Init()

env.CombatClient = CombatClient
env.PremiumCombat = CombatClient
_G.CombatClient = CombatClient
_G.PremiumCombat = CombatClient

-- ===================== OBSIDIAN UI =====================
task.spawn(function()
	local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
	local okFetch, rawSrc = pcall(function()
		return game:HttpGet(repo .. "Library.lua")
	end)
	if not okFetch or typeof(rawSrc) ~= "string" or #rawSrc == 0 then
		warn("[CombatClient] Failed to fetch Obsidian Library:", tostring(rawSrc))
		return
	end

	local okChunk, chunk = pcall(loadstring, rawSrc)
	if not okChunk or typeof(chunk) ~= "function" then
		warn("[CombatClient] Failed to compile Obsidian Library:", tostring(chunk))
		return
	end

	local okLib, Library = pcall(chunk)
	if not okLib or not Library then
		warn("[CombatClient] Failed to execute Obsidian Library:", tostring(Library))
		return
	end

	local function pushNotification(title, description, duration)
		if typeof(Library.Notify) == "function" then
			local ok = pcall(function()
				Library:Notify({
					Title = title,
					Description = description,
					Time = duration or 5,
				})
			end)
			if not ok then
				pcall(function()
					Library:Notify(title, description, duration or 5)
				end)
			end
		end
	end

	local okUI, uiErr = pcall(function()
		local Window = Library:CreateWindow({
			Title = "CombatClient",
			Footer = isBadBusinessPlace() and "Featured: Bad Business | Obsidian UI" or "Smart Camera | Obsidian UI",
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
			Description = "Highlights & Cleanup",
			Icon = "eye",
		})

		local AssistBox = CombatTab:AddLeftGroupbox("Aim & Silent Aim", "target")
		local FilterBox = CombatTab:AddRightGroupbox("Target Filters", "sliders")
		local EspBox = VisualsTab:AddLeftGroupbox("ESP Highlights", "scan-eye")
		local SystemBox = VisualsTab:AddRightGroupbox("Session & FPS", "wrench")

		AssistBox:AddToggle("AssistEnabled", {
			Text = "Enable Targeting",
			Default = Config.AssistEnabled,
			Callback = function(val)
				CombatClient.SetConfig({ AssistEnabled = val })
				if not val then
					resetLockState()
				end
			end,
		})

		AssistBox:AddDropdown("AssistMode", {
			Text = "Aim Mode",
			Values = { "SilentAim", "Camera", "Off" },
			Default = Config.Mode,
			Multi = false,
			Callback = function(val)
				CombatClient.SetConfig({ Mode = val })
			end,
		})

		AssistBox:AddDropdown("PriorityMode", {
			Text = "Target Priority",
			Values = { "Smart", "Nearest", "Crosshair" },
			Default = Config.PriorityMode,
			Multi = false,
			Callback = function(val)
				CombatClient.SetConfig({ PriorityMode = val })
			end,
		})

		AssistBox:AddSlider("CameraSmoothness", {
			Text = "Camera Smoothness",
			Default = Config.CameraSmoothness,
			Min = 0.02,
			Max = 1,
			Rounding = 2,
			Callback = function(val)
				CombatClient.SetConfig({ CameraSmoothness = val })
			end,
		})

		AssistBox:AddSlider("LockHoldSeconds", {
			Text = "Lock Hold (sec)",
			Default = Config.LockHoldSeconds,
			Min = 0,
			Max = 1,
			Rounding = 2,
			Callback = function(val)
				CombatClient.SetConfig({ LockHoldSeconds = val })
			end,
		})

		FilterBox:AddToggle("TargetPlayers", {
			Text = "Target Players",
			Default = Config.TargetPlayers,
			Callback = function(val)
				CombatClient.SetConfig({ TargetPlayers = val })
			end,
		})

		FilterBox:AddToggle("TargetNPCs", {
			Text = "Target NPCs",
			Default = Config.TargetNPCs,
			Callback = function(val)
				CombatClient.SetConfig({ TargetNPCs = val })
			end,
		})

		FilterBox:AddToggle("PreferHead", {
			Text = "Prefer Head",
			Default = Config.PreferHead,
			Callback = function(val)
				CombatClient.SetConfig({ PreferHead = val })
			end,
		})

		FilterBox:AddToggle("WallCheck", {
			Text = "Wall Check",
			Default = Config.WallCheck,
			Callback = function(val)
				CombatClient.SetConfig({ WallCheck = val })
			end,
		})

		FilterBox:AddToggle("IgnoreTeam", {
			Text = "Ignore Same Team",
			Default = Config.IgnoreSameTeam,
			Callback = function(val)
				CombatClient.SetConfig({ IgnoreSameTeam = val })
			end,
		})

		FilterBox:AddSlider("MaxAngle", {
			Text = "Max Angle / FOV (Deg)",
			Default = Config.AssistMaxAngleDegrees,
			Min = 1,
			Max = 90,
			Rounding = 0,
			Callback = function(val)
				CombatClient.SetConfig({ AssistMaxAngleDegrees = val })
			end,
		})

		FilterBox:AddSlider("MaxAssistDist", {
			Text = "Max Assist Distance",
			Default = Config.AssistMaxDistance,
			Min = 25,
			Max = 1000,
			Rounding = 0,
			Callback = function(val)
				CombatClient.SetConfig({ AssistMaxDistance = val })
			end,
		})

		EspBox:AddToggle("HighlightEnabled", {
			Text = "Enemy Highlights",
			Default = Config.HighlightEnabled,
			Callback = function(val)
				CombatClient.SetConfig({ HighlightEnabled = val })
			end,
		})

		EspBox:AddToggle("ThroughWalls", {
			Text = "Always On Top",
			Default = Config.ThroughWalls,
			Callback = function(val)
				CombatClient.SetConfig({ ThroughWalls = val })
				clearAllHighlights()
				updateHighlights()
			end,
		})

		EspBox:AddSlider("EspMaxDist", {
			Text = "ESP Max Distance",
			Default = Config.MaxDistance,
			Min = 50,
			Max = 1500,
			Rounding = 0,
			Callback = function(val)
				CombatClient.SetConfig({ MaxDistance = val })
			end,
		})

		if isBadBusinessPlace() then
			local FeaturedTab = Window:AddTab({
				Name = "Featured",
				Description = "Bad Business Game Features",
				Icon = "flame",
			})

			local BBBox = FeaturedTab:AddLeftGroupbox("Bad Business", "shield-alert")

			BBBox:AddLabel("Featured Game Detected: Bad Business", true)

			BBBox:AddToggle("BBSilentAimEnabled", {
				Text = "Silent Aim (BB)",
				Default = Config.BBSilentAimEnabled,
				Callback = function(val)
					CombatClient.SetConfig({ BBSilentAimEnabled = val })
				end,
			})

			BBBox:AddToggle("BBChamsEnabled", {
				Text = "Enemy Chams (Red)",
				Default = Config.BBChamsEnabled,
				Callback = function(val)
					CombatClient.SetConfig({ BBChamsEnabled = val })
				end,
			})

			BBBox:AddToggle("BBTeammateChamsEnabled", {
				Text = "Teammate Chams (Blue)",
				Default = Config.BBTeammateChamsEnabled,
				Callback = function(val)
					CombatClient.SetConfig({ BBTeammateChamsEnabled = val })
				end,
			})

			BBBox:AddToggle("BBThroughWalls", {
				Text = "Chams Through Walls",
				Default = Config.BBThroughWalls,
				Callback = function(val)
					CombatClient.SetConfig({ BBThroughWalls = val })
					clearAllBBHighlights()
					updateBadBusinessChams()
				end,
			})

			BBBox:AddSlider("BBMaxDist", {
				Text = "Chams Max Distance",
				Default = Config.BBMaxDistance,
				Min = 50,
				Max = 1500,
				Rounding = 0,
				Callback = function(val)
					CombatClient.SetConfig({ BBMaxDistance = val })
				end,
			})
		end

		SystemBox:AddToggle("DebugTrace", {
			Text = "Verbose Trace Logs",
			Default = Config.DebugTrace,
			Callback = function(val)
				CombatClient.SetConfig({ DebugTrace = val })
			end,
		})

		SystemBox:AddToggle("FPSControlEnabled", {
			Text = "Enable Custom FPS Cap",
			Default = Config.FPSControlEnabled,
			Callback = function(val)
				CombatClient.SetConfig({ FPSControlEnabled = val })
			end,
		})

		SystemBox:AddSlider("FPSCapSlider", {
			Text = "Target FPS Cap",
			Default = Config.FPSCap,
			Min = 30,
			Max = 240,
			Rounding = 0,
			Callback = function(val)
				CombatClient.SetConfig({ FPSCap = val })
			end,
		})

		SystemBox:AddButton({
			Text = "Unlock FPS (Default)",
			Func = function()
				CombatClient.SetConfig({ FPSControlEnabled = false })
				if fnSetFpsCap then
					pcall(fnSetFpsCap, 0)
				end
			end,
		})

		SystemBox:AddButton({
			Text = "Unload & Cleanup",
			Func = function()
				CombatClient.Destroy()
				pcall(function()
					Library:Unload()
				end)
			end,
		})

		if isBadBusinessPlace() then
			pushNotification("CombatClient", "BB Detected", 4)
			task.delay(0.35, function()
				pushNotification("Warning", "Script is still in development, use at your own risk!", 6)
			end)
		end

		env.ObsidianLibrary = Library
		env.CombatToggles = Library.Toggles
		env.CombatOptions = Library.Options
	end)

	if not okUI then
		warn("[CombatClient] Obsidian UI error:", tostring(uiErr))
	end
end)

return CombatClient
