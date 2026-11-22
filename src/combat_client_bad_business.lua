local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

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
	local fn = rawget(env, name) or rawget(_G, name)
	if typeof(fn) == "function" then
		return fn
	end
	local ok, gFn = pcall(function()
		return _G[name]
	end)
	return (ok and typeof(gFn) == "function") and gFn or nil
end

local fnHookMetamethod = getExecutorFn("hookmetamethod")
local fnGetNamecallMethod = getExecutorFn("getnamecallmethod")
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

local IGNORED_NAMES = {
	Proxy = true,
	Arms = true,
	DisplayCharacter = true,
	Body = true,
	ClasBaseWeapon = true,
}

local function isIgnoredModelName(name)
	if typeof(name) ~= "string" then
		return true
	end
	if IGNORED_NAMES[name] or string.sub(name, 1, 14) == "DroppedWeapon_" then
		return true
	end
	return false
end

local CachedMarkers = {
	enemySet = {},
	nameGuiSet = {},
	hasEnemyHighlight = false,
	expiresAt = 0,
}

local HookActive = false
local HookBusy = false
local HookInstalled = false

local function resolveBBModelFromInst(inst, charsFolder)
	if not inst or not charsFolder then
		return nil
	end
	local current = inst:IsA("Model") and inst or inst:FindFirstAncestorOfClass("Model")
	while current and current.Parent do
		if current.Parent == charsFolder and current:IsA("Model") then
			return isIgnoredModelName(current.Name) and nil or current
		end
		current = current.Parent
	end
	return nil
end

local function refreshMarkers(force)
	local now = os.clock()
	if not force and now < CachedMarkers.expiresAt then
		return CachedMarkers
	end

	local enemySet = {}
	local nameGuiSet = {}
	local foundEnemy = false

	local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
	local charsFolder = Workspace:FindFirstChild("Characters")
	if pg and charsFolder then
		for _, desc in ipairs(pg:GetDescendants()) do
			if desc:IsA("Highlight") and desc.Enabled then
				local model = resolveBBModelFromInst(desc.Adornee, charsFolder)
				if model then
					local fc = desc.FillColor
					if fc.R >= 0.65 and fc.G <= 0.35 and fc.B <= 0.35 then
						enemySet[model] = true
						foundEnemy = true
					end
				end
			elseif desc.Name == "NameGui" and desc:IsA("BillboardGui") and desc.Enabled then
				local model = resolveBBModelFromInst(desc.Adornee, charsFolder)
				if model then
					nameGuiSet[model] = true
				end
			end
		end
	end

	CachedMarkers.enemySet = enemySet
	CachedMarkers.nameGuiSet = nameGuiSet
	CachedMarkers.hasEnemyHighlight = foundEnemy
	CachedMarkers.expiresAt = now + 0.2
	return CachedMarkers
end

local function getBBLocalCharacter()
	local charsFolder = Workspace:FindFirstChild("Characters")
	if charsFolder and LocalPlayer then
		local direct = charsFolder:FindFirstChild(LocalPlayer.Name)
		if direct and direct:IsA("Model") and not isIgnoredModelName(direct.Name) then
			return direct
		end
		for _, child in ipairs(charsFolder:GetChildren()) do
			if child:IsA("Model") and not isIgnoredModelName(child.Name) then
				local attr = child:GetAttribute("Player") or child:GetAttribute("UserId")
				if attr == LocalPlayer or attr == LocalPlayer.UserId then
					return child
				end
			end
		end
	end
	if LocalPlayer and LocalPlayer.Character and not isIgnoredModelName(LocalPlayer.Character.Name) then
		return LocalPlayer.Character
	end
	return nil
end

local function isBBModelAlive(model)
	if not model or not model:IsA("Model") or model.Parent == nil or isIgnoredModelName(model.Name) then
		return false
	end
	local healthVal = model:FindFirstChild("Health")
	if healthVal and healthVal:IsA("ValueBase") then
		local num = tonumber(healthVal.Value)
		if num and num <= 0 then
			return false
		end
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum and (hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead) then
		return false
	end
	local attrHp = model:GetAttribute("Health")
	if typeof(attrHp) == "number" and attrHp <= 0 then
		return false
	end
	return (model:FindFirstChild("Root") or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Body")) ~= nil
end

local function classifyBBModel(model, player)
	if not model or not model:IsA("Model") or isIgnoredModelName(model.Name) then
		return "none"
	end
	if model == getBBLocalCharacter() or player == LocalPlayer then
		return "none"
	end
	local markers = refreshMarkers(false)
	if markers.nameGuiSet[model] then
		return "teammate"
	end
	if markers.hasEnemyHighlight then
		return markers.enemySet[model] and "enemy" or "none"
	end
	return "enemy"
end

local function getBBCandidates(includeTeammates)
	local results = {}
	local charsFolder = Workspace:FindFirstChild("Characters")
	if not charsFolder then
		return results
	end
	local myChar = getBBLocalCharacter()
	refreshMarkers(false)

	for _, child in ipairs(charsFolder:GetChildren()) do
		if child:IsA("Model") and child ~= myChar and isBBModelAlive(child) then
			local plr = Players:GetPlayerFromCharacter(child) or Players:FindFirstChild(child.Name)
			if plr == LocalPlayer then
				continue
			end
			local role = classifyBBModel(child, plr)
			if role == "enemy" or (includeTeammates and role == "teammate") then
				table.insert(results, {
					Player = plr,
					Character = child,
					Name = plr and plr.Name or child.Name,
					IsNPC = plr == nil,
					Role = role,
				})
			end
		end
	end
	return results
end

local function transformShotPayload(shotTable, origin, targetPos)
	if typeof(shotTable) ~= "table" or typeof(origin) ~= "Vector3" or typeof(targetPos) ~= "Vector3" then
		return nil
	end
	local delta = targetPos - origin
	if delta.Magnitude < 0.05 then
		return nil
	end
	local aimDir = delta.Unit
	local cloned = table.clone(shotTable)
	local changed = 0
	for idx, entry in pairs(cloned) do
		if typeof(entry) == "table" and typeof(entry[1]) == "Vector3" then
			local copyEntry = table.clone(entry)
			copyEntry[1] = aimDir
			cloned[idx] = copyEntry
			changed += 1
		end
	end
	return changed > 0 and cloned or nil
end

local function installBBHookOnce(client)
	if HookInstalled then
		return
	end
	if not fnHookMetamethod or not fnGetNamecallMethod then
		return
	end
	local oldNamecall
	local ok = pcall(function()
		oldNamecall = fnHookMetamethod(game, "__namecall", wrapCClosure(function(self, ...)
			local okMethod, method = pcall(fnGetNamecallMethod)
			if not okMethod or method ~= "FireServer" then
				return oldNamecall(self, ...)
			end
			if not HookActive or HookBusy or isOwnCaller() then
				return oldNamecall(self, ...)
			end
			if typeof(self) ~= "Instance" or not self:IsA("RemoteEvent") or self.Name ~= "Item_Paintball" then
				return oldNamecall(self, ...)
			end
			if typeof(client.IsSilentAimActive) == "function" and not client.IsSilentAimActive() then
				return oldNamecall(self, ...)
			end

			local args = { ... }
			if args[1] ~= "Shoot" or typeof(args[4]) ~= "table" then
				return oldNamecall(self, ...)
			end

			local cam = Workspace.CurrentCamera
			if not cam then
				return oldNamecall(self, ...)
			end

			local origin = typeof(args[3]) == "Vector3" and args[3] or cam.CFrame.Position
			HookBusy = true
			local okCand, cand = pcall(client.GetAssistTarget, origin, cam.CFrame.LookVector)
			HookBusy = false

			if okCand and cand and typeof(cand.Position) == "Vector3" then
				local rewritten = transformShotPayload(args[4], origin, cand.Position)
				if rewritten then
					args[4] = rewritten
					return oldNamecall(self, table.unpack(args))
				end
			end

			return oldNamecall(self, ...)
		end))
	end)
	if ok and typeof(oldNamecall) == "function" then
		HookInstalled = true
	end
end

local CombatClient = env.CombatClient
if not CombatClient then
	warn("[CombatClient:BB] Core CombatClient not found.")
	return nil
end

CombatClient._AdapterGetLocalCharacter = getBBLocalCharacter
CombatClient._AdapterIsLocalAlive = function()
	return Workspace.CurrentCamera ~= nil
end
CombatClient._AdapterIsAlive = isBBModelAlive
CombatClient._AdapterClassifyRole = classifyBBModel
CombatClient._AdapterGetCandidates = getBBCandidates
CombatClient._AdapterInit = function(client)
	HookActive = true
	installBBHookOnce(client)
end
CombatClient._AdapterDestroy = function()
	HookActive = false
	HookBusy = false
	CachedMarkers.expiresAt = 0
end

CombatClient._AdapterInit(CombatClient)
return CombatClient
