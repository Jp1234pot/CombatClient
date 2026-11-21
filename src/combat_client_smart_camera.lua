local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local LocalizationService = game:GetService("LocalizationService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local function getEnv()
	return (typeof(getgenv) == "function" and getgenv()) or _G
end

local env = getEnv()

local function getExecutorFn(name)
	local fn = rawget(env, name) or rawget(_G, name) or _G[name]
	return typeof(fn) == "function" and fn or nil
end

local fnHookFunction = getExecutorFn("hookfunction")
local fnNewCClosure = getExecutorFn("newcclosure")
local fnCheckCaller = getExecutorFn("checkcaller")

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

local SESSION_ID = HttpService:GenerateGUID(false)
local SESSION_ATTR = "CombatClientSession"
local HIGHLIGHT_NAME = "CombatClientHighlight"
local RENDER_STEP_NAME = "CombatClient_SmartCameraStep"

local DEFAULTS = {
	Mode = "Camera", -- "Camera", "Raycast", or "Remote"
	PriorityMode = "Smart", -- "Smart", "Nearest", or "Crosshair"

	HighlightEnabled = true,
	MaxDistance = 500,
	ThroughWalls = true,
	FillColor = Color3.fromRGB(255, 65, 65),
	OutlineColor = Color3.fromRGB(255, 255, 255),
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

	CameraSmoothness = 0.35,
	LockHoldSeconds = 0.2,
	CameraPriorityOffset = 1,

	DebugLogs = true,
}

local Config = {}
local Connections = {}
local Highlights = {}
local HookedOriginals = {}
local Initialized = false
local HookBusy = false
local HighlightAccum = 0

local LockState = {
	Character = nil,
	LastValidAt = 0,
}

local function log(...)
	if Config.DebugLogs then
		print("[CombatClient]", ...)
	end
end

local function resetLockState()
	LockState.Character = nil
	LockState.LastValidAt = 0
end

local function getCharacterRoot(character)
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
		or character.PrimaryPart
		or character:FindFirstChild("Head")
		or character:FindFirstChildWhichIsA("BasePart", true)
end

local function getAimPart(character)
	if not character then
		return nil
	end
	if Config.PreferHead then
		return character:FindFirstChild("Head")
			or character:FindFirstChild("HumanoidRootPart")
			or getCharacterRoot(character)
	end
	return character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("Head")
		or getCharacterRoot(character)
end

local function isAliveCharacter(character)
	if not character or not character:IsA("Model") or character.Parent == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local okState, state = pcall(function()
		return humanoid:GetState()
	end)
	if okState and state == Enum.HumanoidStateType.Dead then
		return false
	end
	return true
end

local function isLocalPlayerAlive()
	local char = LocalPlayer and LocalPlayer.Character
	return isAliveCharacter(char)
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
		if player.Character == model then
			return player
		end
	end
	return nil
end

local function isEnemyPlayer(player)
	if not player or player == LocalPlayer or player.Parent ~= Players then
		return false
	end
	if Config.IgnoreSameTeam and LocalPlayer and LocalPlayer.Team and player.Team == LocalPlayer.Team then
		return false
	end
	return true
end

local function getCandidateModels()
	local entries = {}
	local seenModels = {}

	if Config.TargetPlayers then
		for _, player in ipairs(Players:GetPlayers()) do
			if not isEnemyPlayer(player) then
				continue
			end
			local char = player.Character
			if not char or seenModels[char] or not isAliveCharacter(char) then
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
		local localChar = LocalPlayer and LocalPlayer.Character
		for _, child in ipairs(Workspace:GetChildren()) do
			if child:IsA("Model") and child ~= localChar and not seenModels[child] then
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

local function isClearOfWalls(origin, targetPart, targetCharacter)
	if not targetPart or not targetPart.Parent then
		return false
	end

	local characterModel = targetCharacter or targetPart:FindFirstAncestorOfClass("Model") or targetPart.Parent
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local ignoreList = {}
	if LocalPlayer and LocalPlayer.Character then
		table.insert(ignoreList, LocalPlayer.Character)
	end
	if Workspace.CurrentCamera then
		table.insert(ignoreList, Workspace.CurrentCamera)
	end
	params.FilterDescendantsInstances = ignoreList
	params.IgnoreWater = true

	local offset = targetPart.Position - origin
	if offset.Magnitude < 0.001 then
		return true
	end

	local result = Workspace:Raycast(origin, offset, params)
	if not result then
		return true
	end

	return result.Instance:IsDescendantOf(characterModel)
end

local function computePriorityScore(dist, angleDeg, maxDist, maxAngleDeg, isCurrentLock)
	local normDist = math.clamp(dist / math.max(maxDist, 1), 0, 1)
	local normAngle = math.clamp(angleDeg / math.max(maxAngleDeg, 1), 0, 1)
	local stickBonus = isCurrentLock and -0.12 or 0

	if Config.PriorityMode == "Nearest" then
		-- Lower score = higher priority
		return normDist + (normAngle * 0.2) + stickBonus
	elseif Config.PriorityMode == "Crosshair" then
		return normAngle + (normDist * 0.2) + stickBonus
	else
		-- "Smart": balances proximity and crosshair alignment
		return (normAngle * 0.55) + (normDist * 0.45) + stickBonus
	end
end

local function isOwnHighlight(inst)
	return typeof(inst) == "Instance"
		and inst:IsA("Highlight")
		and inst.Name == HIGHLIGHT_NAME
		and inst:GetAttribute(SESSION_ATTR) == SESSION_ID
end

local function clearCharacterHighlight(character)
	local entry = Highlights[character]
	if entry then
		if entry.Instance and entry.Instance.Parent and isOwnHighlight(entry.Instance) then
			entry.Instance:Destroy()
		end
		Highlights[character] = nil
	end

	if character and character.Parent then
		for _, child in ipairs(character:GetChildren()) do
			if isOwnHighlight(child) then
				child:Destroy()
			end
		end
	end
end

local function clearAllHighlights()
	for char in pairs(Highlights) do
		clearCharacterHighlight(char)
	end
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if isOwnHighlight(obj) then
			obj:Destroy()
		end
	end
end

local function updateHighlights()
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
		if existing and not isOwnHighlight(existing.Instance) then
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

function CombatClient.GetAssistTarget(origin, direction)
	if not Initialized or not Config.AssistEnabled or not isLocalPlayerAlive() then
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
	local candidates = getCandidateModels()
	local checkWalls = Config.WallCheck == true
	local now = os.clock()

	local bestTarget = nil
	local bestScore = math.huge
	local lockedEntryTarget = nil

	for _, entry in ipairs(candidates) do
		local character = entry.Character
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
		return bestTarget
	end

	if lockedEntryTarget then
		LockState.LastValidAt = now
		return lockedEntryTarget
	end

	-- Grace hold across brief angle/wall flickers while target remains alive & in range
	if LockState.Character and isAliveCharacter(LockState.Character) and (now - LockState.LastValidAt) <= Config.LockHoldSeconds then
		local aimPart = getAimPart(LockState.Character)
		if aimPart then
			local offset = aimPart.Position - origin
			local dist = offset.Magnitude
			if dist >= 0.001 and dist <= maxDist then
				local plr = getPlayerFromCharacter(LockState.Character)
				return {
					Player = plr,
					Character = LockState.Character,
					Name = plr and plr.Name or LockState.Character.Name,
					IsNPC = plr == nil,
					Part = aimPart,
					Position = aimPart.Position,
					Distance = dist,
					AngleDegrees = math.deg(math.acos(math.clamp(unitDir:Dot(offset.Unit), -1, 1))),
					Score = 0,
				}
			end
		end
	end

	resetLockState()
	return nil
end

function CombatClient.GetAdjustedDirection(origin, direction)
	if not Initialized or not Config.AssistEnabled or not isLocalPlayerAlive() then
		return direction
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		return direction
	end

	local candidate = CombatClient.GetAssistTarget(origin, direction)
	if not candidate or not candidate.Position then
		return direction
	end

	local delta = candidate.Position - origin
	if delta.Magnitude < 0.001 then
		return direction
	end

	return delta.Unit * direction.Magnitude
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

	local targetCFrame = CFrame.lookAt(origin, candidate.Position)
	local alpha = math.clamp(1 - ((1 - Config.CameraSmoothness) ^ (dt * 60)), 0, 1)
	cam.CFrame = cam.CFrame:Lerp(targetCFrame, alpha)
end

local function installHooksOnce()
	if next(HookedOriginals) ~= nil then
		return
	end
	if not fnHookFunction then
		log("hookfunction not available; Camera mode still works.")
		return
	end

	local installed = {}

	if typeof(Workspace.Raycast) == "function" then
		local oldRaycast
		local ok = pcall(function()
			oldRaycast = fnHookFunction(Workspace.Raycast, wrapCClosure(function(ws, origin, direction, params)
				if HookBusy or isOwnCaller() or not Initialized or not Config.AssistEnabled or Config.Mode ~= "Raycast" or not isLocalPlayerAlive() then
					return oldRaycast(ws, origin, direction, params)
				end
				HookBusy = true
				local okAdj, adj = pcall(CombatClient.GetAdjustedDirection, origin, direction)
				HookBusy = false
				local finalDir = (okAdj and typeof(adj) == "Vector3") and adj or direction
				return oldRaycast(ws, origin, finalDir, params)
			end))
		end)
		if ok and typeof(oldRaycast) == "function" then
			HookedOriginals.Raycast = oldRaycast
			table.insert(installed, "Workspace.Raycast")
		end
	end

	local remote = LocalizationService:FindFirstChild("RemoteEvent")
	if remote and remote:IsA("RemoteEvent") and typeof(remote.FireServer) == "function" then
		local oldFire
		local ok = pcall(function()
			oldFire = fnHookFunction(remote.FireServer, wrapCClosure(function(rem, ...)
				if HookBusy or isOwnCaller() or rem ~= remote or not Initialized or not Config.AssistEnabled or Config.Mode ~= "Remote" or not isLocalPlayerAlive() then
					return oldFire(rem, ...)
				end

				local args = { ... }
				local action = args[2]

				if action == "Fire" and typeof(args[5]) == "CFrame" then
					local cf = args[5]
					HookBusy = true
					local okCand, cand = pcall(CombatClient.GetAssistTarget, cf.Position, cf.LookVector)
					HookBusy = false

					if okCand and cand and cand.Position and (cand.Position - cf.Position).Magnitude > 0.001 then
						args[5] = CFrame.lookAt(cf.Position, cand.Position)
						return oldFire(rem, table.unpack(args))
					end
				elseif action == "Hitcheck" then
					local cam = Workspace.CurrentCamera
					if cam then
						HookBusy = true
						local okCand, cand = pcall(CombatClient.GetAssistTarget, cam.CFrame.Position, cam.CFrame.LookVector)
						HookBusy = false

						if okCand and cand and cand.Character then
							local aimPart = getAimPart(cand.Character)
							if aimPart then
								args[4] = cand.Player and cand.Player.Name or cand.Character.Name
								args[5] = aimPart.Name
								if typeof(args[6]) == "table" then
									local hitData = table.clone(args[6])
									if typeof(hitData[4]) == "Vector3" then
										hitData[4] = aimPart.Position
									end
									args[6] = hitData
								end
								return oldFire(rem, table.unpack(args))
							end
						end
					end
				end

				return oldFire(rem, ...)
			end))
		end)
		if ok and typeof(oldFire) == "function" then
			HookedOriginals.FireServer = oldFire
			table.insert(installed, "RemoteEvent.FireServer")
		end
	end

	log("Hooks ready:", #installed > 0 and table.concat(installed, ", ") or "none")
end

function CombatClient.SetConfig(partial)
	if typeof(partial) ~= "table" then
		return
	end
	for key, val in pairs(partial) do
		if Config[key] ~= nil then
			Config[key] = val
		end
	end
	if Initialized then
		updateHighlights()
	end
end

function CombatClient.GetConfig()
	return table.clone(Config)
end

function CombatClient.Destroy()
	Initialized = false
	resetLockState()
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	for _, conn in ipairs(Connections) do
		conn:Disconnect()
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
		for key, val in pairs(userConfig) do
			if Config[key] ~= nil then
				Config[key] = val
			end
		end
	end

	Initialized = true
	installHooksOnce()

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
			clearCharacterHighlight(player.Character)
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

	RunService:BindToRenderStep(
		RENDER_STEP_NAME,
		Enum.RenderPriority.Camera.Value + Config.CameraPriorityOffset,
		stepSmartCamera
	)

	updateHighlights()
	log("Initialized | Mode:", Config.Mode, "| Priority:", Config.PriorityMode, "| Session:", SESSION_ID)
	return CombatClient
end

CombatClient.Init()

env.CombatClient = CombatClient
env.PremiumCombat = CombatClient
_G.CombatClient = CombatClient
_G.PremiumCombat = CombatClient

-- ===================== OBSIDIAN UI =====================
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local okLib, Library = pcall(function()
	return loadstring(game:HttpGet(repo .. "Library.lua"))()
end)

if not okLib or not Library then
	warn("[CombatClient] Failed to load Obsidian Library.")
	return CombatClient
end

local Toggles = Library.Toggles
local Options = Library.Options

local Window = Library:CreateWindow({
	Title = "CombatClient",
	Footer = "Smart Camera | Obsidian UI",
	ToggleKeybind = Enum.KeyCode.RightShift,
	NotifySide = "Right",
	ShowCustomCursor = false,
})

local CombatTab = Window:AddTab({
	Name = "Combat",
	Description = "Smart Camera & Aim",
	Icon = "crosshair",
})

local VisualsTab = Window:AddTab({
	Name = "Visuals",
	Description = "Highlights & Cleanup",
	Icon = "eye",
})

local AssistBox = CombatTab:AddLeftGroupbox("Smart Camera", "target")
local FilterBox = CombatTab:AddRightGroupbox("Target Filters", "sliders")
local EspBox = VisualsTab:AddLeftGroupbox("ESP Highlights", "scan-eye")
local SystemBox = VisualsTab:AddRightGroupbox("Session", "wrench")

AssistBox:AddToggle("AssistEnabled", {
	Text = "Enable Smart Camera",
	Default = Config.AssistEnabled,
	Callback = function(val)
		CombatClient.SetConfig({ AssistEnabled = val })
		if not val then
			resetLockState()
		end
	end,
})

AssistBox:AddDropdown("AssistMode", {
	Text = "Assist Mode",
	Values = { "Camera", "Raycast", "Remote" },
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
	Min = 0.05,
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
	Text = "Max Angle (Deg)",
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

SystemBox:AddButton({
	Text = "Unload & Cleanup",
	Func = function()
		CombatClient.Destroy()
		pcall(function()
			Library:Unload()
		end)
	end,
})

env.ObsidianLibrary = Library
env.CombatToggles = Toggles
env.CombatOptions = Options

return CombatClient
