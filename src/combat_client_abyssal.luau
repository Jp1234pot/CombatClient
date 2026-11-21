--// Initialization

local LoadStart = tick()

-- Prevent duplicate executions
if shared.Hastelepasta then
	return
end

-- Initialize the global Abysall environment
getgenv().Abysall = {
	Legit = true
}

-- Main repository URL
local BaseUrl = "https://raw.githubusercontent.com/coolcookiebusiness/AbysallHubContinued/main/"

-- Load status and compatibility checks
loadstring(game:HttpGet(BaseUrl .. "Components/Status.luau"))(BaseUrl)

if shared.Runningnofine then
	return
end

--// Main Components

getgenv().Abysall = {
	-- executor test
	Environment = loadstring(game:HttpGet(BaseUrl .. "Components/Environment.luau"))(),
	-- esp library
	ESPLibrary = loadstring(game:HttpGet(BaseUrl .. "Components/ESP.luau"))(),
	-- required by law
	["16Notice"] = loadstring(game:HttpGet(BaseUrl .. "Components/16Notice.luau"))(),
	-- settings and info
	Interface = loadstring(game:HttpGet(BaseUrl .. "Components/Interface.luau"))(),
	-- so we can see how many people use the scripts
	Analytics = loadstring(game:HttpGet(BaseUrl .. "Components/Analytics.luau"))(),
	-- legit trust
	Legit = true
}

shared.Hastelepasta = true

local Abysall = getgenv().Abysall

--// Service Management

-- cloneref helps avoid certain executor detection and reference issues.
local function CloneReference(Object)
	if Abysall and Abysall.Environment.cloneref then
		return Abysall.Environment.cloneref(Object)
	end

	return Object
end

-- Services are retrieved automatically when accessed.
-- Example: Services.Players or Services.Lighting
local Services = setmetatable({}, {
	__index = function(Self, Name)
		return CloneReference(game:GetService(Name))
	end
})

local LocalPlayer = Services.Players.LocalPlayer

--// Cleanup Management

-- Every connection created by this script should be stored here.
-- They will automatically be disconnected when the hub unloads.
local Connections = {}

-- Every instance created by this script should be stored here.
-- They will automatically be destroyed when the hub unloads.
local Objects = {}

local function TrackConnection(Connection)
	table.insert(Connections, Connection)
	return Connection
end

local function TrackObject(Object)
	table.insert(Objects, Object)
	return Object
end

--// Interface References

local Library = Abysall.Interface.Library
local SaveManager = Abysall.Interface.SaveManager
local ThemeManager = Abysall.Interface.ThemeManager

local Toggles = Library.Toggles
local Options = Library.Options

--// Notification System

local function GetHiddenContainer()
	if Abysall.Environment.gethui then
		return Abysall.Environment.gethui()
	end

	return Services.CoreGui
end

local NotificationLibrary = {
	LiveNotifications = 0,
	Notifications = 0
}

-- Main notification container.
local Container = Instance.new("ScreenGui")
Container.Name = Abysall.ESPLibrary:GenerateRandomString()
Container.Parent = GetHiddenContainer()
Container.DisplayOrder = 32767
Container.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

TrackObject(Container)

function NotificationLibrary:Notify(TitleText, Desc, Delay)
	task.spawn(function()
		local Notification = Instance.new("Frame")
		local Line = Instance.new("Frame")
		local Title = Instance.new("TextLabel")
		local Description = Instance.new("TextLabel")

		local NotificationDuration = math.max(Delay or 5, 0.5)

		Notification.Name = "Notification"
		Notification.Parent = Container
		Notification.BackgroundColor3 = Library.Scheme and Library.Scheme.BackgroundColor or Color3.fromRGB(30, 30, 30)
		Notification.BackgroundTransparency = 0.4
		Notification.BorderSizePixel = 0
		Notification.Position = UDim2.new(1, 5, 0, 60 + (60 * NotificationLibrary.LiveNotifications))
		Notification.Size = UDim2.new(0, 420, 0, 50)

		Line.Name = "Line"
		Line.Parent = Notification
		Line.BackgroundColor3 = Library.Scheme and Library.Scheme.AccentColor or Color3.fromRGB(0, 170, 255)
		Line.BorderSizePixel = 0
		Line.Position = UDim2.new(0, 0, 1, -3)
		Line.Size = UDim2.new(0, 0, 0, 3)

		Title.Name = "Title"
		Title.Parent = Notification
		Title.BackgroundTransparency = 1
		Title.Position = UDim2.new(0, 15, 0.15, 0)
		Title.Size = UDim2.new(0, 390, 0, 15)
		Title.Text = TitleText or "..."
		Title.TextColor3 = Color3.fromRGB(255, 255, 255)
		Title.TextSize = 14
		Title.TextXAlignment = Enum.TextXAlignment.Left
		Title.Font = Enum.Font.GothamBold

		Description.Name = "Description"
		Description.Parent = Notification
		Description.BackgroundTransparency = 1
		Description.Position = UDim2.new(0, 15, 0.48, 0)
		Description.Size = UDim2.new(0, 390, 0, 18)
		Description.Text = Desc or "..."
		Description.TextColor3 = Color3.fromRGB(200, 200, 200)
		Description.TextSize = 12
		Description.TextXAlignment = Enum.TextXAlignment.Left
		Description.Font = Enum.Font.Gotham

		NotificationLibrary.LiveNotifications += 1
		NotificationLibrary.Notifications += 1

		-- Slide the notification onto the screen.
		Services.TweenService:Create(
			Notification,
			TweenInfo.new(0.6, Enum.EasingStyle.Exponential),
			{
				Position = UDim2.new(1, -430, 0, Notification.Position.Y.Offset)
			}
		):Play()

		task.wait(0.25)

		-- Animate the progress bar.
		Services.TweenService:Create(
			Line,
			TweenInfo.new(NotificationDuration, Enum.EasingStyle.Linear),
			{
				Size = UDim2.new(0, 420, 0, 3)
			}
		):Play()

		task.wait(NotificationDuration)

		-- Slide the notification off the screen.
		Services.TweenService:Create(
			Notification,
			TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
			{
				Position = UDim2.new(1, 5, 0, Notification.Position.Y.Offset)
			}
		):Play()

		NotificationLibrary.LiveNotifications -= 1

		task.wait(0.6)

		Notification:Destroy()
	end)
end

-- Public notification helper.
-- All features should use this instead of creating their own notifications.
local Functions = {}

Functions.Notify = function(Settings)
	NotificationLibrary:Notify(
		Settings.Title or "Notification",
		Settings.Body or "...",
		Settings.Time or 5
	)
end

--// Main Window

local Window = Library:CreateWindow({
	Title = "Abysall Hub Continued",
	Footer = "dsc.gg/abysallhubcontinued",
	NotifySide = "Right",
	ShowCustomCursor = false,
	AutoShow = true,
	Center = true,
	TabPadding = 3,
	MenuFadeTime = 0,
	CornerRadius = 6
})

--// Tabs
Abysall.Interface.ApplyInfoTab(Window)
local Tabs = {
	General = Window:AddTab("General", "house"),
	Combat = Window:AddTab("Combat", "crosshair"),
	Visuals = Window:AddTab("Visuals", "eye"),
	Settings = Window:AddTab("Settings", "gear")
}

--// Groupboxes

local Groupboxes = {}

Groupboxes.Character = Tabs.General:AddLeftGroupbox("Character")
Groupboxes.Self = Tabs.General:AddRightGroupbox("Self")

Groupboxes.SmartCamera = Tabs.Combat:AddLeftGroupbox("Smart Camera")
Groupboxes.TargetFilters = Tabs.Combat:AddRightGroupbox("Target Filters")

Groupboxes.Visuals = Tabs.Visuals:AddLeftGroupbox("Visuals")
Groupboxes.Performance = Tabs.Visuals:AddRightGroupbox("Performance")

Groupboxes.Config = Tabs.Settings:AddLeftGroupbox("Configuration")
Groupboxes.Information = Tabs.Settings:AddRightGroupbox("Information")

--// Character

-- Stores the current character and humanoid.
local CharacterHumanoid = nil
local CharacterModel = nil

-- Stores the original properties of the current character.
local OriginalCharacterSettings = {
	WalkSpeed = 16,
	JumpPower = 50,
	UseJumpPower = true
}

-- Retrieves the player's current character.
local function UpdateCharacterHumanoid()
	CharacterModel = LocalPlayer.Character

	CharacterHumanoid = CharacterModel and CharacterModel:FindFirstChildOfClass("Humanoid")

	if CharacterHumanoid then
		OriginalCharacterSettings.WalkSpeed = CharacterHumanoid.WalkSpeed
		OriginalCharacterSettings.JumpPower = CharacterHumanoid.JumpPower
		OriginalCharacterSettings.UseJumpPower = CharacterHumanoid.UseJumpPower
	end
end

-- Applies the selected movement settings.
local function ApplyCharacterSettings()
	if not CharacterHumanoid then
		return
	end

	CharacterHumanoid.WalkSpeed = Options.WalkSpeedSlider.Value

	CharacterHumanoid.UseJumpPower = true
	CharacterHumanoid.JumpPower = Options.JumpPowerSlider.Value
end

-- WalkSpeed slider.
-- WalkSpeed controls how quickly the character moves.
Groupboxes.Character:AddSlider("WalkSpeedSlider", {
	Text = "WalkSpeed",
	Min = 16,
	Max = 100,
	Default = 16,
	Rounding = 0,
	Compact = true
})

-- JumpPower slider.
-- JumpPower controls the upward force applied when jumping.
Groupboxes.Character:AddSlider("JumpPowerSlider", {
	Text = "JumpPower",
	Min = 50,
	Max = 150,
	Default = 50,
	Rounding = 0,
	Compact = true
})

-- Sliders use Options rather than Toggles.
Options.WalkSpeedSlider:OnChanged(function(Value)
	if CharacterHumanoid then
		CharacterHumanoid.WalkSpeed = Value
	end
end)

Options.JumpPowerSlider:OnChanged(function(Value)
	if CharacterHumanoid then
		CharacterHumanoid.UseJumpPower = true
		CharacterHumanoid.JumpPower = Value
	end
end)

-- When the player respawns, retrieve the new Humanoid.
-- Reapply the selected movement settings after the character loads.
TrackConnection(LocalPlayer.CharacterAdded:Connect(function(NewCharacter)
	CharacterModel = NewCharacter
	CharacterHumanoid = NewCharacter:WaitForChild("Humanoid", 10)

	if CharacterHumanoid then
		OriginalCharacterSettings.WalkSpeed = CharacterHumanoid.WalkSpeed
		OriginalCharacterSettings.JumpPower = CharacterHumanoid.JumpPower
		OriginalCharacterSettings.UseJumpPower = CharacterHumanoid.UseJumpPower

		ApplyCharacterSettings()
	end
end))

UpdateCharacterHumanoid()

-- Reset Character button.
-- Uses the character's Humanoid to kill the current character.
Groupboxes.Character:AddButton({
	Text = "Reset Character",
	Func = function()
		if CharacterHumanoid then
			CharacterHumanoid.Health = 0

			Functions.Notify({
				Title = "Character",
				Body = "Resetting character...",
				Time = 3
			})
		end
	end
})

--// Self

-- Anti-AFK prevents the standard idle timeout from disconnecting the player.
-- The connection is only active while the toggle is enabled.
Groupboxes.Self:AddToggle("AntiAFK", {
	Text = "Anti-AFK",
	Default = false,
	Tooltip = "Attempts to prevent automatic idle disconnection."
})

local AntiAFKConnection

Toggles.AntiAFK:OnChanged(function(Value)
	if Value then
		if AntiAFKConnection then
			AntiAFKConnection:Disconnect()
			AntiAFKConnection = nil
		end

		local VirtualUser = Services.VirtualUser

		AntiAFKConnection = TrackConnection(LocalPlayer.Idled:Connect(function()
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new())
			end)
		end))

		Functions.Notify({
			Title = "Anti-AFK",
			Body = "Anti-AFK enabled.",
			Time = 3
		})
	else
		if AntiAFKConnection then
			AntiAFKConnection:Disconnect()
			AntiAFKConnection = nil
		end

		Functions.Notify({
			Title = "Anti-AFK",
			Body = "Anti-AFK disabled.",
			Time = 3
		})
	end
end)

-- Rejoin button.
-- Teleports the player back into the current experience.
Groupboxes.Self:AddButton({
	Text = "Rejoin Server",
	Func = function()
		Functions.Notify({
			Title = "Rejoining",
			Body = "Attempting to reconnect to the server...",
			Time = 4
		})

		task.spawn(function()
			local Success, ErrorMessage = pcall(function()
				Services.TeleportService:Teleport(game.PlaceId, LocalPlayer)
			end)

			if not Success then
				Functions.Notify({
					Title = "Rejoin Failed",
					Body = tostring(ErrorMessage),
					Time = 5
				})
			end
		end)
	end
})

--// Smart Camera & Combat Logic

local CombatConfig = {
	Mode = "Camera", -- "Camera", "Raycast", or "Remote"
	PriorityMode = "Smart", -- "Smart", "Nearest", or "Crosshair"

	AssistEnabled = false,
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

	HighlightPlayers = false,
	HighlightNPCs = false,
	MaxDistance = 500,
	ThroughWalls = true,
	FillTransparency = 0.85,
	OutlineTransparency = 0,
	HighlightColors = {
		NPC = Color3.fromRGB(255, 140, 0),
		Enemy = Color3.fromRGB(255, 65, 65),
		Teammate = Color3.fromRGB(65, 145, 255),
		Unregistered = Color3.fromRGB(245, 245, 245),
	},
}

local CombatSessionId = Services.HttpService:GenerateGUID(false)
local CombatSessionAttr = "AbysallCombatSession"
local CombatHighlightName = "AbysallCombatHighlight"
local CombatRenderStepName = "Abysall_SmartCameraStep"

local CombatHighlights = {}
local CombatHookedOriginals = {}
local CombatHookBusy = false
local CombatHighlightAccum = 0
local CombatActive = true

local CombatLockState = {
	Character = nil,
	LastValidAt = 0,
}

local function getCombatEnv()
	return (typeof(getgenv) == "function" and getgenv()) or _G
end

local function getCombatExecutorFn(name)
	local env = getCombatEnv()
	local fn = rawget(env, name) or rawget(_G, name) or _G[name]
	return typeof(fn) == "function" and fn or nil
end

local fnHookFunction = getCombatExecutorFn("hookfunction")
local fnNewCClosure = getCombatExecutorFn("newcclosure")
local fnCheckCaller = getCombatExecutorFn("checkcaller")

local function wrapCombatCClosure(fn)
	if not fnNewCClosure then
		return fn
	end
	local ok, wrapped = pcall(fnNewCClosure, fn)
	return (ok and typeof(wrapped) == "function") and wrapped or fn
end

local function isOwnCombatCaller()
	if not fnCheckCaller then
		return false
	end
	local ok, res = pcall(fnCheckCaller)
	return ok and res == true
end

local function resetCombatLockState()
	CombatLockState.Character = nil
	CombatLockState.LastValidAt = 0
end

local function getCombatCharacterRoot(character)
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
		or character.PrimaryPart
		or character:FindFirstChild("Head")
		or character:FindFirstChildWhichIsA("BasePart", true)
end

local function getCombatAimPart(character)
	if not character then
		return nil
	end
	if CombatConfig.PreferHead then
		return character:FindFirstChild("Head")
			or character:FindFirstChild("HumanoidRootPart")
			or getCombatCharacterRoot(character)
	end
	return character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("Head")
		or getCombatCharacterRoot(character)
end

local function isAliveCombatCharacter(character)
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

local function isLocalCombatPlayerAlive()
	local char = LocalPlayer and LocalPlayer.Character
	return isAliveCombatCharacter(char)
end

local function getPlayerFromCombatCharacter(model)
	if not model then
		return nil
	end
	local plr = Services.Players:GetPlayerFromCharacter(model)
	if plr then
		return plr
	end
	for _, player in ipairs(Services.Players:GetPlayers()) do
		if player.Character == model then
			return player
		end
	end
	return nil
end

local function isEnemyCombatPlayer(player)
	if not player or player == LocalPlayer or player.Parent ~= Services.Players then
		return false
	end
	if CombatConfig.IgnoreSameTeam and LocalPlayer and LocalPlayer.Team and player.Team == LocalPlayer.Team then
		return false
	end
	return true
end

local function getCombatCandidateModels()
	local entries = {}
	local seenModels = {}

	if CombatConfig.TargetPlayers then
		for _, player in ipairs(Services.Players:GetPlayers()) do
			if not isEnemyCombatPlayer(player) then
				continue
			end
			local char = player.Character
			if not char or seenModels[char] or not isAliveCombatCharacter(char) then
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

	if CombatConfig.TargetNPCs then
		local localChar = LocalPlayer and LocalPlayer.Character
		for _, child in ipairs(Services.Workspace:GetChildren()) do
			if child:IsA("Model") and child ~= localChar and not seenModels[child] then
				if getPlayerFromCombatCharacter(child) == nil and isAliveCombatCharacter(child) then
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

local function isClearOfWallsCombat(origin, targetPart, targetCharacter)
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
	if Services.Workspace.CurrentCamera then
		table.insert(ignoreList, Services.Workspace.CurrentCamera)
	end
	params.FilterDescendantsInstances = ignoreList
	params.IgnoreWater = true

	local offset = targetPart.Position - origin
	if offset.Magnitude < 0.001 then
		return true
	end

	local result = Services.Workspace:Raycast(origin, offset, params)
	if not result then
		return true
	end

	return result.Instance:IsDescendantOf(characterModel)
end

local function computeCombatPriorityScore(dist, angleDeg, maxDist, maxAngleDeg, isCurrentLock)
	local normDist = math.clamp(dist / math.max(maxDist, 1), 0, 1)
	local normAngle = math.clamp(angleDeg / math.max(maxAngleDeg, 1), 0, 1)
	local stickBonus = isCurrentLock and -0.12 or 0

	if CombatConfig.PriorityMode == "Nearest" then
		return normDist + (normAngle * 0.2) + stickBonus
	elseif CombatConfig.PriorityMode == "Crosshair" then
		return normAngle + (normDist * 0.2) + stickBonus
	else
		return (normAngle * 0.55) + (normDist * 0.45) + stickBonus
	end
end

local function isOwnCombatHighlight(inst)
	return typeof(inst) == "Instance"
		and inst:IsA("Highlight")
		and inst.Name == CombatHighlightName
		and inst:GetAttribute(CombatSessionAttr) == CombatSessionId
end

local function clearCombatCharacterHighlight(character)
	local entry = CombatHighlights[character]
	if entry then
		if entry.Instance and entry.Instance.Parent and isOwnCombatHighlight(entry.Instance) then
			entry.Instance:Destroy()
		end
		CombatHighlights[character] = nil
	end

	if character and character.Parent then
		for _, child in ipairs(character:GetChildren()) do
			if isOwnCombatHighlight(child) then
				child:Destroy()
			end
		end
	end
end

local function clearAllCombatHighlights()
	for char in pairs(CombatHighlights) do
		clearCombatCharacterHighlight(char)
	end
	for _, obj in ipairs(Services.Workspace:GetDescendants()) do
		if isOwnCombatHighlight(obj) then
			obj:Destroy()
		end
	end
end

local function getPlayerHighlightCategory(player)
	if not player then
		return "Unregistered"
	end

	local localTeam = LocalPlayer and LocalPlayer.Team
	local playerTeam = player.Team

	if localTeam == nil or playerTeam == nil then
		return "Unregistered"
	end

	if playerTeam == localTeam then
		return "Teammate"
	end

	return "Enemy"
end

local function getHighlightCandidates(maxDist, myPos)
	local candidates = {}
	local seenModels = {}
	local localChar = LocalPlayer and LocalPlayer.Character

	if CombatConfig.HighlightPlayers then
		for _, player in ipairs(Services.Players:GetPlayers()) do
			if player == LocalPlayer then
				continue
			end

			local char = player.Character
			local root = getCombatCharacterRoot(char)
			if char and root and not seenModels[char] and isAliveCombatCharacter(char) then
				if (root.Position - myPos).Magnitude <= maxDist then
					seenModels[char] = true
					table.insert(candidates, {
						Character = char,
						Color = CombatConfig.HighlightColors[getPlayerHighlightCategory(player)],
					})
				end
			end
		end
	end

	if CombatConfig.HighlightNPCs then
		for _, child in ipairs(Services.Workspace:GetChildren()) do
			if child:IsA("Model") and child ~= localChar and not seenModels[child] then
				if getPlayerFromCombatCharacter(child) == nil and isAliveCombatCharacter(child) then
					local root = getCombatCharacterRoot(child)
					if root and (root.Position - myPos).Magnitude <= maxDist then
						seenModels[child] = true
						table.insert(candidates, {
							Character = child,
							Color = CombatConfig.HighlightColors.NPC,
						})
					end
				end
			end
		end
	end

	return candidates
end

local function syncCharacterHighlight(character, color)
	local existing = CombatHighlights[character]
	if existing and not isOwnCombatHighlight(existing.Instance) then
		clearCombatCharacterHighlight(character)
		existing = nil
	end

	local hl = existing and existing.Instance
	if not hl then
		hl = Instance.new("Highlight")
		hl.Name = CombatHighlightName
		hl:SetAttribute(CombatSessionAttr, CombatSessionId)
		hl.Adornee = character
		hl.Parent = character
		TrackObject(hl)

		CombatHighlights[character] = {
			Instance = hl,
			Character = character,
		}
	end

	hl.DepthMode = CombatConfig.ThroughWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
	hl.FillColor = color
	hl.OutlineColor = color
	hl.FillTransparency = CombatConfig.FillTransparency
	hl.OutlineTransparency = CombatConfig.OutlineTransparency
end

local function updateCombatHighlights()
	if not CombatActive or not isLocalCombatPlayerAlive() then
		clearAllCombatHighlights()
		return
	end

	if not (CombatConfig.HighlightPlayers or CombatConfig.HighlightNPCs) then
		clearAllCombatHighlights()
		return
	end

	local myRoot = getCombatCharacterRoot(LocalPlayer and LocalPlayer.Character)
	if not myRoot then
		clearAllCombatHighlights()
		return
	end

	local myPos = myRoot.Position
	local maxDist = CombatConfig.MaxDistance
	local validSet = {}

	for _, item in ipairs(getHighlightCandidates(maxDist, myPos)) do
		validSet[item.Character] = true
		syncCharacterHighlight(item.Character, item.Color)
	end

	for char in pairs(CombatHighlights) do
		if not validSet[char] then
			clearCombatCharacterHighlight(char)
		end
	end
end

local function getCombatAssistTarget(origin, direction)
	if not CombatActive or not CombatConfig.AssistEnabled or not isLocalCombatPlayerAlive() then
		resetCombatLockState()
		return nil
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		return nil
	end

	local unitDir = direction.Unit
	local maxAngleRad = math.rad(CombatConfig.AssistMaxAngleDegrees)
	local maxDist = CombatConfig.AssistMaxDistance
	local maxDistSq = maxDist * maxDist
	local candidates = getCombatCandidateModels()
	local checkWalls = CombatConfig.WallCheck == true
	local now = os.clock()

	local bestTarget = nil
	local bestScore = math.huge
	local lockedEntryTarget = nil

	for _, entry in ipairs(candidates) do
		local character = entry.Character
		if not isAliveCombatCharacter(character) then
			continue
		end

		local aimPart = getCombatAimPart(character)
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

		if checkWalls and not isClearOfWallsCombat(origin, aimPart, character) then
			continue
		end

		local angleDeg = math.deg(angle)
		local isLocked = (CombatLockState.Character == character)
		local score = computeCombatPriorityScore(dist, angleDeg, maxDist, CombatConfig.AssistMaxAngleDegrees, isLocked)

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
		CombatLockState.Character = bestTarget.Character
		CombatLockState.LastValidAt = now
		return bestTarget
	end

	if lockedEntryTarget then
		CombatLockState.LastValidAt = now
		return lockedEntryTarget
	end

	if CombatLockState.Character and isAliveCombatCharacter(CombatLockState.Character) and (now - CombatLockState.LastValidAt) <= CombatConfig.LockHoldSeconds then
		local aimPart = getCombatAimPart(CombatLockState.Character)
		if aimPart then
			local offset = aimPart.Position - origin
			local dist = offset.Magnitude
			if dist >= 0.001 and dist <= maxDist then
				local plr = getPlayerFromCombatCharacter(CombatLockState.Character)
				return {
					Player = plr,
					Character = CombatLockState.Character,
					Name = plr and plr.Name or CombatLockState.Character.Name,
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

	resetCombatLockState()
	return nil
end

local function getCombatAdjustedDirection(origin, direction)
	if not CombatActive or not CombatConfig.AssistEnabled or not isLocalCombatPlayerAlive() then
		return direction
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 0.001 then
		return direction
	end

	local candidate = getCombatAssistTarget(origin, direction)
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
	if not CombatActive or not CombatConfig.AssistEnabled or CombatConfig.Mode ~= "Camera" then
		resetCombatLockState()
		return
	end

	if not isLocalCombatPlayerAlive() then
		resetCombatLockState()
		return
	end

	local cam = Services.Workspace.CurrentCamera
	if not cam then
		return
	end

	local origin = cam.CFrame.Position
	local look = cam.CFrame.LookVector
	local candidate = getCombatAssistTarget(origin, look)
	if not candidate or not candidate.Position then
		return
	end

	local targetCFrame = CFrame.lookAt(origin, candidate.Position)
	local alpha = math.clamp(1 - ((1 - CombatConfig.CameraSmoothness) ^ (dt * 60)), 0, 1)
	cam.CFrame = cam.CFrame:Lerp(targetCFrame, alpha)
end

local function installCombatHooksOnce()
	if next(CombatHookedOriginals) ~= nil then
		return
	end
	if not fnHookFunction then
		return
	end

	if typeof(Services.Workspace.Raycast) == "function" then
		local oldRaycast
		local ok = pcall(function()
			oldRaycast = fnHookFunction(Services.Workspace.Raycast, wrapCombatCClosure(function(ws, origin, direction, params)
				if CombatHookBusy or isOwnCombatCaller() or not CombatActive or not CombatConfig.AssistEnabled or CombatConfig.Mode ~= "Raycast" or not isLocalCombatPlayerAlive() then
					return oldRaycast(ws, origin, direction, params)
				end
				CombatHookBusy = true
				local okAdj, adj = pcall(getCombatAdjustedDirection, origin, direction)
				CombatHookBusy = false
				local finalDir = (okAdj and typeof(adj) == "Vector3") and adj or direction
				return oldRaycast(ws, origin, finalDir, params)
			end))
		end)
		if ok and typeof(oldRaycast) == "function" then
			CombatHookedOriginals.Raycast = oldRaycast
		end
	end

	local remote = Services.LocalizationService:FindFirstChild("RemoteEvent")
	if remote and remote:IsA("RemoteEvent") and typeof(remote.FireServer) == "function" then
		local oldFire
		local ok = pcall(function()
			oldFire = fnHookFunction(remote.FireServer, wrapCombatCClosure(function(rem, ...)
				if CombatHookBusy or isOwnCombatCaller() or rem ~= remote or not CombatActive or not CombatConfig.AssistEnabled or CombatConfig.Mode ~= "Remote" or not isLocalCombatPlayerAlive() then
					return oldFire(rem, ...)
				end

				local args = { ... }
				local action = args[2]

				if action == "Fire" and typeof(args[5]) == "CFrame" then
					local cf = args[5]
					CombatHookBusy = true
					local okCand, cand = pcall(getCombatAssistTarget, cf.Position, cf.LookVector)
					CombatHookBusy = false

					if okCand and cand and cand.Position and (cand.Position - cf.Position).Magnitude > 0.001 then
						args[5] = CFrame.lookAt(cf.Position, cand.Position)
						return oldFire(rem, table.unpack(args))
					end
				elseif action == "Hitcheck" then
					local cam = Services.Workspace.CurrentCamera
					if cam then
						CombatHookBusy = true
						local okCand, cand = pcall(getCombatAssistTarget, cam.CFrame.Position, cam.CFrame.LookVector)
						CombatHookBusy = false

						if okCand and cand and cand.Character then
							local aimPart = getCombatAimPart(cand.Character)
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
			CombatHookedOriginals.FireServer = oldFire
		end
	end
end

installCombatHooksOnce()

TrackConnection(Services.Players.PlayerRemoving:Connect(function(player)
	if CombatLockState.Character == player.Character then
		resetCombatLockState()
	end
	if player.Character then
		clearCombatCharacterHighlight(player.Character)
	end
end))

TrackConnection(Services.RunService.Heartbeat:Connect(function(dt)
	if not CombatActive then
		return
	end
	CombatHighlightAccum += dt
	if CombatHighlightAccum >= 0.2 then
		CombatHighlightAccum = 0
		updateCombatHighlights()
	end
end))

Services.RunService:BindToRenderStep(
	CombatRenderStepName,
	Enum.RenderPriority.Camera.Value + CombatConfig.CameraPriorityOffset,
	stepSmartCamera
)

--// Combat UI Controls

Groupboxes.SmartCamera:AddToggle("SmartCameraEnabled", {
	Text = "Enable Smart Camera",
	Default = CombatConfig.AssistEnabled,
	Tooltip = "Enables target-assisted aim/camera logic."
})

Toggles.SmartCameraEnabled:OnChanged(function(Value)
	CombatConfig.AssistEnabled = Value
	if not Value then
		resetCombatLockState()
	end
end)

Groupboxes.SmartCamera:AddDropdown("SmartCameraMode", {
	Text = "Assist Mode",
	Values = { "Camera", "Raycast", "Remote" },
	Default = CombatConfig.Mode,
	Multi = false,
	Tooltip = "Selects whether assistance adjusts camera, raycasts, or remote args."
})

Options.SmartCameraMode:OnChanged(function(Value)
	CombatConfig.Mode = Value
end)

Groupboxes.SmartCamera:AddDropdown("SmartCameraPriority", {
	Text = "Target Priority",
	Values = { "Smart", "Nearest", "Crosshair" },
	Default = CombatConfig.PriorityMode,
	Multi = false,
	Tooltip = "Selects target scoring behavior."
})

Options.SmartCameraPriority:OnChanged(function(Value)
	CombatConfig.PriorityMode = Value
end)

Groupboxes.SmartCamera:AddSlider("SmartCameraSmoothness", {
	Text = "Camera Smoothness",
	Min = 0.05,
	Max = 1,
	Default = CombatConfig.CameraSmoothness,
	Rounding = 2,
	Compact = true
})

Options.SmartCameraSmoothness:OnChanged(function(Value)
	CombatConfig.CameraSmoothness = Value
end)

Groupboxes.SmartCamera:AddSlider("SmartCameraLockHold", {
	Text = "Lock Hold (sec)",
	Min = 0,
	Max = 1,
	Default = CombatConfig.LockHoldSeconds,
	Rounding = 2,
	Compact = true
})

Options.SmartCameraLockHold:OnChanged(function(Value)
	CombatConfig.LockHoldSeconds = Value
end)

Groupboxes.TargetFilters:AddToggle("CombatTargetPlayers", {
	Text = "Target Players",
	Default = CombatConfig.TargetPlayers
})

Toggles.CombatTargetPlayers:OnChanged(function(Value)
	CombatConfig.TargetPlayers = Value
end)

Groupboxes.TargetFilters:AddToggle("CombatTargetNPCs", {
	Text = "Target NPCs",
	Default = CombatConfig.TargetNPCs
})

Toggles.CombatTargetNPCs:OnChanged(function(Value)
	CombatConfig.TargetNPCs = Value
end)

Groupboxes.TargetFilters:AddToggle("CombatPreferHead", {
	Text = "Prefer Head",
	Default = CombatConfig.PreferHead
})

Toggles.CombatPreferHead:OnChanged(function(Value)
	CombatConfig.PreferHead = Value
end)

Groupboxes.TargetFilters:AddToggle("CombatWallCheck", {
	Text = "Wall Check",
	Default = CombatConfig.WallCheck
})

Toggles.CombatWallCheck:OnChanged(function(Value)
	CombatConfig.WallCheck = Value
end)

Groupboxes.TargetFilters:AddToggle("CombatIgnoreTeam", {
	Text = "Ignore Same Team",
	Default = CombatConfig.IgnoreSameTeam
})

Toggles.CombatIgnoreTeam:OnChanged(function(Value)
	CombatConfig.IgnoreSameTeam = Value
end)

Groupboxes.TargetFilters:AddSlider("CombatMaxAngle", {
	Text = "Max Angle (Deg)",
	Min = 1,
	Max = 90,
	Default = CombatConfig.AssistMaxAngleDegrees,
	Rounding = 0,
	Compact = true
})

Options.CombatMaxAngle:OnChanged(function(Value)
	CombatConfig.AssistMaxAngleDegrees = Value
end)

Groupboxes.TargetFilters:AddSlider("CombatMaxAssistDist", {
	Text = "Max Assist Distance",
	Min = 25,
	Max = 1000,
	Default = CombatConfig.AssistMaxDistance,
	Rounding = 0,
	Compact = true
})

Options.CombatMaxAssistDist:OnChanged(function(Value)
	CombatConfig.AssistMaxDistance = Value
end)

--// Visuals

-- Store the original Lighting settings so they can be restored.
local OriginalLightingSettings = {
	Brightness = Services.Lighting.Brightness,
	ClockTime = Services.Lighting.ClockTime,
	GlobalShadows = Services.Lighting.GlobalShadows,
	Ambient = Services.Lighting.Ambient,
	OutdoorAmbient = Services.Lighting.OutdoorAmbient
}

-- Fullbright makes the environment brighter.
Groupboxes.Visuals:AddToggle("Fullbright", {
	Text = "Fullbright",
	Default = false,
	Tooltip = "Removes most environmental darkness."
})

Toggles.Fullbright:OnChanged(function(Value)
	if Value then
		Services.Lighting.Brightness = 2
		Services.Lighting.ClockTime = 14
		Services.Lighting.GlobalShadows = false
		Services.Lighting.Ambient = Color3.new(1, 1, 1)
		Services.Lighting.OutdoorAmbient = Color3.new(1, 1, 1)

		Functions.Notify({
			Title = "Fullbright",
			Body = "Fullbright enabled.",
			Time = 3
		})
	else
		-- Restore every property to its original value.
		for Property, OriginalValue in pairs(OriginalLightingSettings) do
			Services.Lighting[Property] = OriginalValue
		end

		Functions.Notify({
			Title = "Fullbright",
			Body = "Original lighting restored.",
			Time = 3
		})
	end
end)

--// Combat Highlights (Visuals)

Groupboxes.Visuals:AddToggle("HighlightPlayersToggle", {
	Text = "Highlight Players",
	Default = CombatConfig.HighlightPlayers,
	Tooltip = "ESP/Chams players (Red = enemy, Blue = team, White = no team)."
})

Toggles.HighlightPlayersToggle:OnChanged(function(Value)
	CombatConfig.HighlightPlayers = Value
	updateCombatHighlights()
end)

Groupboxes.Visuals:AddToggle("HighlightNPCsToggle", {
	Text = "Highlight NPCs",
	Default = CombatConfig.HighlightNPCs,
	Tooltip = "ESP/Chams NPCs in orange."
})

Toggles.HighlightNPCsToggle:OnChanged(function(Value)
	CombatConfig.HighlightNPCs = Value
	updateCombatHighlights()
end)

Groupboxes.Visuals:AddToggle("CombatThroughWalls", {
	Text = "Highlights Always On Top",
	Default = CombatConfig.ThroughWalls
})

Toggles.CombatThroughWalls:OnChanged(function(Value)
	CombatConfig.ThroughWalls = Value
	clearAllCombatHighlights()
	updateCombatHighlights()
end)

Groupboxes.Visuals:AddSlider("CombatHighlightMaxDist", {
	Text = "Highlight Max Distance",
	Min = 50,
	Max = 1500,
	Default = CombatConfig.MaxDistance,
	Rounding = 0,
	Compact = true
})

Options.CombatHighlightMaxDist:OnChanged(function(Value)
	CombatConfig.MaxDistance = Value
	updateCombatHighlights()
end)

--// Field Of View

-- Save the original camera FOV.
local OriginalFieldOfView = workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView or 70

-- FOV controls how much of the environment is visible on screen.
Groupboxes.Visuals:AddSlider("FOVSlider", {
	Text = "Field Of View",
	Min = 50,
	Max = 120,
	Default = 70,
	Rounding = 0,
	Compact = true
})

Options.FOVSlider:OnChanged(function(Value)
	local Camera = workspace.CurrentCamera

	if Camera then
		Camera.FieldOfView = Value
	end
end)

--// FPS Counter

-- This creates a small FPS display rather than repeatedly
-- sending notifications.
local FPSCounterGui = Instance.new("TextLabel")

FPSCounterGui.Name = "FPSCounter"
FPSCounterGui.Parent = Container
FPSCounterGui.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
FPSCounterGui.BackgroundTransparency = 0.25
FPSCounterGui.BorderSizePixel = 0
FPSCounterGui.Position = UDim2.new(0, 15, 0, 15)
FPSCounterGui.Size = UDim2.new(0, 150, 0, 30)
FPSCounterGui.Font = Enum.Font.GothamBold
FPSCounterGui.TextColor3 = Color3.fromRGB(255, 255, 255)
FPSCounterGui.TextSize = 14
FPSCounterGui.Text = "FPS: --"
FPSCounterGui.Visible = false

TrackObject(FPSCounterGui)

Groupboxes.Performance:AddToggle("FPSCounter", {
	Text = "FPS Counter",
	Default = false,
	Tooltip = "Displays your current frames per second."
})

local FPSCounterConnection
local FPSFrameCount = 0
local FPSLastUpdate = tick()

Toggles.FPSCounter:OnChanged(function(Value)
	FPSCounterGui.Visible = Value

	if Value then
		FPSFrameCount = 0
		FPSLastUpdate = tick()

		if FPSCounterConnection then
			FPSCounterConnection:Disconnect()
			FPSCounterConnection = nil
		end

		FPSCounterConnection = TrackConnection(Services.RunService.RenderStepped:Connect(function()
			FPSFrameCount += 1

			local CurrentTime = tick()
			local ElapsedTime = CurrentTime - FPSLastUpdate

			if ElapsedTime >= 1 then
				local CurrentFPS = math.floor(FPSFrameCount / ElapsedTime)

				FPSCounterGui.Text = "FPS: " .. CurrentFPS

				FPSFrameCount = 0
				FPSLastUpdate = CurrentTime
			end
		end))
	else
		if FPSCounterConnection then
			FPSCounterConnection:Disconnect()
			FPSCounterConnection = nil
		end

		FPSCounterGui.Text = "FPS: --"
	end
end)

--// Configuration

Library:OnUnload(function()
	CombatActive = false
	CombatConfig.AssistEnabled = false
	CombatConfig.HighlightPlayers = false
	CombatConfig.HighlightNPCs = false
	resetCombatLockState()

	pcall(function()
		Services.RunService:UnbindFromRenderStep(CombatRenderStepName)
	end)

	clearAllCombatHighlights()

	-- Disconnect every connection.
	for _, Connection in pairs(Connections) do
		pcall(function()
			Connection:Disconnect()
		end)
	end

	-- Clear connection references.
	table.clear(Connections)

	-- Restore original character settings.
	if CharacterHumanoid and CharacterHumanoid.Parent then
		pcall(function()
			CharacterHumanoid.WalkSpeed = OriginalCharacterSettings.WalkSpeed
			CharacterHumanoid.UseJumpPower = OriginalCharacterSettings.UseJumpPower
			CharacterHumanoid.JumpPower = OriginalCharacterSettings.JumpPower
		end)
	end

	-- Restore original Lighting.
	for Property, OriginalValue in pairs(OriginalLightingSettings) do
		pcall(function()
			Services.Lighting[Property] = OriginalValue
		end)
	end

	-- Restore the original FOV.
	pcall(function()
		if workspace.CurrentCamera then
			workspace.CurrentCamera.FieldOfView = OriginalFieldOfView
		end
	end)

	-- Destroy all instances created by this script.
	for _, Object in pairs(Objects) do
		pcall(function()
			Object:Destroy()
		end)
	end

	table.clear(Objects)

	-- Clear global references.
	getgenv().Abysall = nil

	-- Allow the script to execute again.
	shared.Hastelepasta = false

	print("Abysall Hub Continued cleaned up and unloaded.")
end)

Abysall.Interface.ApplySettingsTab(Window)
Functions.Notify({
	Title = "Successfully loaded",
	Body = "UI loaded in " .. math.floor((tick() - LoadStart) * 1000) / 1000 .. " seconds.",
	Time = 5
})
