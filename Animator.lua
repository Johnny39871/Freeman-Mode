local RunService    = game:GetService("RunService")
local TweenService  = game:GetService("TweenService")

local ModuleAnimator = {}
ModuleAnimator.__index = ModuleAnimator
ModuleAnimator.Version = "1.0.0"

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	assert(type(fn) == "function", "Connect expects a function")
	local handler = { Fn = fn, Connected = true }
	table.insert(self._handlers, handler)

	local connection = { Connected = true }
	function connection:Disconnect()
		handler.Connected = false
		self.Connected = false
	end
	connection.disconnect = connection.Disconnect
	return connection
end

Signal.connect = Signal.Connect

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Wait()
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Fire(...)
	local handlers = self._handlers
	local alive, n = {}, 0
	for i = 1, #handlers do
		local h = handlers[i]
		if h.Connected then
			n += 1
			alive[n] = h
		end
	end
	self._handlers = alive
	for i = 1, n do
		task.spawn(alive[i].Fn, ...)
	end
end

function Signal:Destroy()
	for _, h in ipairs(self._handlers) do h.Connected = false end
	self._handlers = {}
end

ModuleAnimator.Signal = Signal

local PRIORITY_RANK = {
	Core     = 0,
	Idle     = 1,
	Movement = 2,
	Action   = 3,
	Action2  = 4,
	Action3  = 5,
	Action4  = 6,
}

local function RankOf(priority)
	if typeof(priority) == "EnumItem" then
		return PRIORITY_RANK[priority.Name] or 3
	elseif type(priority) == "string" then
		return PRIORITY_RANK[priority] or 3
	elseif type(priority) == "number" then
		return priority
	end
	return 3
end

ModuleAnimator.PriorityRank = PRIORITY_RANK

local EASING_STYLE_BY_NAME = {
	Linear      = Enum.EasingStyle.Linear,
	Cubic       = Enum.EasingStyle.Cubic,
	Elastic     = Enum.EasingStyle.Elastic,
	Bounce      = Enum.EasingStyle.Bounce,
	Sine        = Enum.EasingStyle.Sine,
	Quad        = Enum.EasingStyle.Quad,
	Quart       = Enum.EasingStyle.Quart,
	Quint       = Enum.EasingStyle.Quint,
	Exponential = Enum.EasingStyle.Exponential,
	Circular    = Enum.EasingStyle.Circular,
	Back        = Enum.EasingStyle.Back,
}

local EASING_DIR_BY_NAME = {
	In    = Enum.EasingDirection.In,
	Out   = Enum.EasingDirection.Out,
	InOut = Enum.EasingDirection.InOut,
}

local function ResolveEasing(style, direction)
	local styleName = typeof(style) == "EnumItem" and style.Name or (type(style) == "string" and style or nil)
	local dirName   = typeof(direction) == "EnumItem" and direction.Name or (type(direction) == "string" and direction or nil)

	if styleName == "Constant" then
		return "Constant", nil
	end
	return EASING_STYLE_BY_NAME[styleName or ""] or Enum.EasingStyle.Linear,
		EASING_DIR_BY_NAME[dirName or ""] or Enum.EasingDirection.Out
end

local function ApplyEasing(alpha, style, direction)
	if style == "Constant" then
		return alpha >= 1 and 1 or 0
	end
	if style == Enum.EasingStyle.Linear then
		return alpha
	end
	return TweenService:GetValue(alpha, style, direction)
end

local RESERVED = {
	CFrame = true, Weight = true, EasingStyle = true, EasingDirection = true,
	Name = true, Time = true, Poses = true, Markers = true, Marker = true,
}

local ParseCache = setmetatable({}, { __mode = "k" })

local function ResolveSource(source)
	if typeof(source) == "Instance" then
		if source:IsA("ModuleScript") then
			return require(source)
		end
		error("Expected a ModuleScript, got a " .. source.ClassName, 3)
	elseif type(source) == "function" then
		return source()
	elseif type(source) == "table" then
		return source
	end
	error("LoadAnimation expects a ModuleScript, table, or function", 3)
end

local function WalkPoses(node, time, tracks)
	for key, value in pairs(node) do
		if not RESERVED[key] and type(value) == "table" then
			if value.CFrame ~= nil then
				local list = tracks[key]
				if not list then
					list = {}
					tracks[key] = list
				end
				local style, direction = ResolveEasing(value.EasingStyle, value.EasingDirection)
				table.insert(list, {
					Time      = time,
					CFrame    = value.CFrame,
					Weight    = value.Weight or 1,
					Style     = style,
					Direction = direction,
				})
			end
			WalkPoses(value.Poses or value, time, tracks)
		end
	end
end

local function ParseAnimation(data, name)
	assert(type(data) == "table", "Animation module must return a table")
	local keyframes = data.Keyframes or data.keyframes
	assert(type(keyframes) == "table", "Module has no Keyframes table")

	local props = data.Properties or data.properties or {}

	local anim = {
		Name          = name or data.Name or "ModuleAnimation",
		Tracks        = {},
		JointNames    = {},
		Length        = 0,
		Looped        = props.Looping == true or props.Looped == true,
		Priority      = props.Priority or Enum.AnimationPriority.Action,
		Markers       = {},
		KeyframeNames = {},
	}
	local entries = {}
	for key, value in pairs(keyframes) do
		if type(value) == "table" then
			local time = tonumber(value.Time) or tonumber(key)
			if time then
				table.insert(entries, { Time = time, Data = value })
			end
		end
	end
	table.sort(entries, function(a, b) return a.Time < b.Time end)

	for _, entry in ipairs(entries) do
		local time, kf = entry.Time, entry.Data
		if time > anim.Length then anim.Length = time end

		if type(kf.Name) == "string" and kf.Name ~= "" and kf.Name ~= "Keyframe" then
			table.insert(anim.KeyframeNames, { Time = time, Name = kf.Name })
		end
		if type(kf.Markers) == "table" then
			for markerName, param in pairs(kf.Markers) do
				table.insert(anim.Markers, { Time = time, Name = markerName, Param = param })
			end
		end

		WalkPoses(kf.Poses or kf, time, anim.Tracks)
	end

	for jointName, list in pairs(anim.Tracks) do
		table.sort(list, function(a, b) return a.Time < b.Time end)
		table.insert(anim.JointNames, jointName)
	end
	table.sort(anim.JointNames)
	table.sort(anim.Markers, function(a, b) return a.Time < b.Time end)
	table.sort(anim.KeyframeNames, function(a, b) return a.Time < b.Time end)

	return anim
end

local function SampleTrack(keys, time)
	local n = #keys
	if n == 0 then return nil end
	if n == 1 or time <= keys[1].Time then return keys[1].CFrame, keys[1].Weight end
	if time >= keys[n].Time then return keys[n].CFrame, keys[n].Weight end

	local low, high = 1, n
	while high - low > 1 do
		local mid = (low + high) // 2
		if keys[mid].Time <= time then low = mid else high = mid end
	end

	local a, b = keys[low], keys[high]
	local span = b.Time - a.Time
	if span <= 0 then return b.CFrame, b.Weight end

	local alpha = ApplyEasing((time - a.Time) / span, b.Style, b.Direction)
	return a.CFrame:Lerp(b.CFrame, alpha), a.Weight + (b.Weight - a.Weight) * alpha
end

ModuleAnimator.ParseAnimation = ParseAnimation

local AnimationTrack = {}

local TrackGetters = {
	Length       = function(self) return self._anim.Length end,
	IsPlaying    = function(self) return self._playing end,
	Speed        = function(self) return self._speed end,
	WeightCurrent= function(self) return self._weight end,
	WeightTarget = function(self) return self._weightTarget end,
	Animation    = function(self) return self._anim end,
	Priority     = function(self) return rawget(self, "_priority") end,
}

local TrackSetters = {
	TimePosition = function(self, value)
		value = tonumber(value) or 0
		rawset(self, "_time", value)
		rawset(self, "_lastTime", value)
	end,
	Priority = function(self, value)
		rawset(self, "_priority", value)
		rawset(self, "_rank", RankOf(value))
	end,
	Speed        = function(self, value) self:AdjustSpeed(value) end,
	WeightTarget = function(self, value) self:AdjustWeight(value, 0) end,
	Length       = function() error("Length is read-only", 2) end,
	IsPlaying    = function() error("IsPlaying is read-only", 2) end,
	WeightCurrent= function() error("WeightCurrent is read-only", 2) end,
}

AnimationTrack.__index = function(self, key)
	if key == "TimePosition" then return rawget(self, "_time") end
	local getter = TrackGetters[key]
	if getter then return getter(self) end
	return rawget(AnimationTrack, key)
end

AnimationTrack.__newindex = function(self, key, value)
	local setter = TrackSetters[key]
	if setter then setter(self, value) return end
	rawset(self, key, value)
end

AnimationTrack.__tostring = function(self)
	return ("ModuleAnimationTrack(%s)"):format(tostring(rawget(self, "Name")))
end

local function NewTrack(rigger, anim)
	local self = setmetatable({}, AnimationTrack)

	rawset(self, "_rigger", rigger)
	rawset(self, "_anim", anim)
	rawset(self, "_playing", false)
	rawset(self, "_time", 0)
	rawset(self, "_lastTime", 0)
	rawset(self, "_speed", 1)
	rawset(self, "_weight", 0)
	rawset(self, "_weightTarget", 0)
	rawset(self, "_fadeRate", 0)
	rawset(self, "_stopping", false)
	rawset(self, "_markerSignals", {})
	rawset(self, "_destroyed", false)

	rawset(self, "Name", anim.Name)
	rawset(self, "Looped", anim.Looped)
	rawset(self, "_priority", anim.Priority)
	rawset(self, "_rank", RankOf(anim.Priority))

	rawset(self, "DidLoop", Signal.new())
	rawset(self, "Stopped", Signal.new())
	rawset(self, "Ended", Signal.new())
	rawset(self, "KeyframeReached", Signal.new())

	return self
end

function AnimationTrack:Play(fadeTime, weight, speed)
	if rawget(self, "_destroyed") then return end
	fadeTime = tonumber(fadeTime) or 0.1
	weight   = tonumber(weight) or 1
	speed    = tonumber(speed) or rawget(self, "_speed") or 1

	rawset(self, "_speed", speed)
	rawset(self, "_stopping", false)

	if not rawget(self, "_playing") then
		rawset(self, "_playing", true)
		local startTime = (speed < 0) and self._anim.Length or 0
		rawset(self, "_time", startTime)
		rawset(self, "_lastTime", startTime)
		rawset(self, "_weight", fadeTime > 0 and 0 or weight)
	end

	self:AdjustWeight(weight, fadeTime)
	self._rigger:_Register(self)
	return self
end

function AnimationTrack:Stop(fadeTime)
	if not rawget(self, "_playing") then return end
	fadeTime = tonumber(fadeTime) or 0.1

	if fadeTime <= 0 then
		self:_FinishStop()
		return
	end

	rawset(self, "_stopping", true)
	rawset(self, "_weightTarget", 0)
	rawset(self, "_fadeRate", rawget(self, "_weight") / fadeTime)
end

function AnimationTrack:_FinishStop(reachedEnd)
	if not rawget(self, "_playing") then return end
	rawset(self, "_playing", false)
	rawset(self, "_stopping", false)
	rawset(self, "_weight", 0)
	rawset(self, "_weightTarget", 0)
	self._rigger:_Unregister(self)
	self.Stopped:Fire()
	if reachedEnd then
		self.Ended:Fire()
	end
end

function AnimationTrack:AdjustSpeed(speed)
	rawset(self, "_speed", tonumber(speed) or 1)
end

function AnimationTrack:AdjustWeight(weight, fadeTime)
	weight   = math.max(tonumber(weight) or 1, 0)
	fadeTime = tonumber(fadeTime) or 0.1

	rawset(self, "_weightTarget", weight)
	if fadeTime <= 0 then
		rawset(self, "_weight", weight)
		rawset(self, "_fadeRate", 0)
	else
		rawset(self, "_fadeRate", math.abs(weight - rawget(self, "_weight")) / fadeTime)
	end
end

function AnimationTrack:GetMarkerReachedSignal(markerName)
	local signals = rawget(self, "_markerSignals")
	local signal = signals[markerName]
	if not signal then
		signal = Signal.new()
		signals[markerName] = signal
	end
	return signal
end

function AnimationTrack:GetTimeOfKeyframe(keyframeName)
	for _, entry in ipairs(self._anim.KeyframeNames) do
		if entry.Name == keyframeName then return entry.Time end
	end
	error(("[ModuleAnimator] no keyframe named '%s'"):format(tostring(keyframeName)), 2)
end

function AnimationTrack:AddMarker(markerName, time, param)
	table.insert(self._anim.Markers, { Time = time, Name = markerName, Param = param })
	table.sort(self._anim.Markers, function(a, b) return a.Time < b.Time end)
end

function AnimationTrack:SetToTime(time, weight)
	rawset(self, "_time", math.clamp(tonumber(time) or 0, 0, self._anim.Length))
	rawset(self, "_lastTime", rawget(self, "_time"))
	self._rigger:_ApplySingle(self, weight or 1)
end

function AnimationTrack:Destroy()
	if rawget(self, "_destroyed") then return end
	self:_FinishStop(false)
	rawset(self, "_destroyed", true)
	self.DidLoop:Destroy()
	self.Stopped:Destroy()
	self.Ended:Destroy()
	self.KeyframeReached:Destroy()
	for _, signal in pairs(rawget(self, "_markerSignals")) do signal:Destroy() end
	rawset(self, "_markerSignals", {})
end

function AnimationTrack:_FireEventsBetween(fromTime, toTime, forward)
	local anim = self._anim
	local markerSignals = rawget(self, "_markerSignals")

	local function crossed(t)
		if forward then
			return t > fromTime and t <= toTime
		else
			return t < fromTime and t >= toTime
		end
	end

	for _, entry in ipairs(anim.KeyframeNames) do
		if crossed(entry.Time) then
			self.KeyframeReached:Fire(entry.Name)
		end
	end
	for _, entry in ipairs(anim.Markers) do
		if crossed(entry.Time) then
			local signal = markerSignals[entry.Name]
			if signal then signal:Fire(entry.Param) end
		end
	end
end

function AnimationTrack:_Step(dt)
	local weight, target, rate = rawget(self, "_weight"), rawget(self, "_weightTarget"), rawget(self, "_fadeRate")
	if weight ~= target then
		if rate <= 0 then
			weight = target
		else
			local step = rate * dt
			if math.abs(target - weight) <= step then
				weight = target
			else
				weight += (target > weight) and step or -step
			end
		end
		rawset(self, "_weight", weight)
	end

	if rawget(self, "_stopping") and weight <= 0 then
		self:_FinishStop(false)
		return
	end

	local length = self._anim.Length
	local speed = rawget(self, "_speed")
	local from = rawget(self, "_time")
	local to = from + dt * speed
	local forward = speed >= 0

	if length <= 0 then
		rawset(self, "_time", 0)
		return
	end

	if forward then
		if to >= length then
			if self.Looped then
				self:_FireEventsBetween(from, length, true)
				local wrapped = length > 0 and (to % length) or 0
				rawset(self, "_time", wrapped)
				rawset(self, "_lastTime", 0)
				self.DidLoop:Fire()
				self:_FireEventsBetween(0, wrapped, true)
			else
				self:_FireEventsBetween(from, length, true)
				rawset(self, "_time", length)
				rawset(self, "_lastTime", length)
				self:_FinishStop(true)
			end
			return
		end
	else
		if to <= 0 then
			if self.Looped then
				self:_FireEventsBetween(from, 0, false)
				local wrapped = to % length
				rawset(self, "_time", wrapped)
				rawset(self, "_lastTime", length)
				self.DidLoop:Fire()
				self:_FireEventsBetween(length, wrapped, false)
			else
				self:_FireEventsBetween(from, 0, false)
				rawset(self, "_time", 0)
				rawset(self, "_lastTime", 0)
				self:_FinishStop(true)
			end
			return
		end
	end

	rawset(self, "_time", to)
	self:_FireEventsBetween(from, to, forward)
	rawset(self, "_lastTime", to)
end

local Rigger = {}
Rigger.__index = Rigger

local IDENTITY = CFrame.identity

function ModuleAnimator.new(rig, config)
	assert(typeof(rig) == "Instance", ".new expects an Instance (the rig model)")
	config = config or {}

	local self = setmetatable({}, Rigger)
	self.Rig             = rig
	self.Tracks          = {}
	self.Playing         = {}
	self.Joints          = {}
	self._touched        = {}
	self._animCache      = {}
	self.WarnMissing     = config.WarnMissing ~= false
	self._warned         = {}
	self.Destroyed       = false

	self:RebuildJointMap()
	ModuleAnimator._AddRigger(self)
	return self
end

function Rigger:RebuildJointMap()
	local joints = {}
	local motors = {}

	for _, descendant in ipairs(self.Rig:GetDescendants()) do
		if descendant:IsA("Bone") then
			joints[descendant.Name] = descendant
		elseif descendant:IsA("Motor6D") then
			table.insert(motors, descendant)
		end
	end

	for _, motor in ipairs(motors) do
		local part1 = motor.Part1
		if part1 and not joints[part1.Name] then
			joints[part1.Name] = motor
		end
		if not joints[motor.Name] then
			joints[motor.Name] = motor
		end
	end

	self.Joints = joints
	return joints
end

function Rigger:LoadAnimation(source, name)
	local data = ResolveSource(source)

	local cached = self._animCache[data] or ParseCache[data]
	if not cached then
		local sourceName = name
		if not sourceName and typeof(source) == "Instance" then sourceName = source.Name end
		cached = ParseAnimation(data, sourceName)
		self._animCache[data] = cached
		ParseCache[data] = cached
	end

	local track = NewTrack(self, cached)
	if name then rawset(track, "Name", name) end
	table.insert(self.Tracks, track)

	if self.WarnMissing then
		for _, jointName in ipairs(cached.JointNames) do
			if not self.Joints[jointName] and not self._warned[jointName] then
				self._warned[jointName] = true
				warn(("[ModuleAnimator] '%s' has no matching Bone/Motor6D in %s - skipping")
					:format(jointName, self.Rig:GetFullName()))
			end
		end
	end

	return track
end

function Rigger:_Register(track)
	for _, t in ipairs(self.Playing) do
		if t == track then return end
	end
	table.insert(self.Playing, track)
end

function Rigger:_Unregister(track)
	for i, t in ipairs(self.Playing) do
		if t == track then
			table.remove(self.Playing, i)
			return
		end
	end
end

function Rigger:GetPlayingAnimationTracks()
	local list = table.create(#self.Playing)
	table.move(self.Playing, 1, #self.Playing, 1, list)
	return list
end

function Rigger:StopAll(fadeTime)
	for _, track in ipairs(self:GetPlayingAnimationTracks()) do
		track:Stop(fadeTime)
	end
end

function Rigger:ResetJoints()
	for joint in pairs(self._touched) do
		if joint.Parent then joint.Transform = IDENTITY end
	end
	table.clear(self._touched)
end

function Rigger:_ApplySingle(track, weight)
	local anim = track._anim
	local time = track.TimePosition
	weight = math.clamp(weight or 1, 0, 1)

	for _, jointName in ipairs(anim.JointNames) do
		local joint = self.Joints[jointName]
		if joint and joint.Parent then
			local cf = SampleTrack(anim.Tracks[jointName], time)
			if cf then
				joint.Transform = (weight >= 1) and cf or IDENTITY:Lerp(cf, weight)
				self._touched[joint] = true
			end
		end
	end
end

function Rigger:_Apply()
	local playing = self.Playing
	if #playing == 0 then
		if next(self._touched) then self:ResetJoints() end
		return
	end

	local joints = self.Joints
	local buckets = {}
	local rankSet = {}

	for _, track in ipairs(playing) do
		local weight = track.WeightCurrent
		if weight > 0 then
			local anim = track._anim
			local time = track.TimePosition
			local rank = rawget(track, "_rank")
			rankSet[rank] = true

			for _, jointName in ipairs(anim.JointNames) do
				if joints[jointName] then
					local cf, poseWeight = SampleTrack(anim.Tracks[jointName], time)
					if cf then
						local effective = weight * (poseWeight or 1)
						if effective > 0 then
							local perJoint = buckets[jointName]
							if not perJoint then
								perJoint = {}
								buckets[jointName] = perJoint
							end
							local bucket = perJoint[rank]
							if not bucket then
								perJoint[rank] = { CF = cf, W = effective }
							else
								local total = bucket.W + effective
								bucket.CF = bucket.CF:Lerp(cf, effective / total)
								bucket.W = total
							end
						end
					end
				end
			end
		end
	end

	local ranks = {}
	for rank in pairs(rankSet) do table.insert(ranks, rank) end
	table.sort(ranks)

	local touched = self._touched
	local stillTouched = {}

	for jointName, perJoint in pairs(buckets) do
		local joint = joints[jointName]
		if joint and joint.Parent then
			local result = IDENTITY
			for _, rank in ipairs(ranks) do
				local bucket = perJoint[rank]
				if bucket then
					local alpha = math.clamp(bucket.W, 0, 1)
					result = (alpha >= 1) and bucket.CF or result:Lerp(bucket.CF, alpha)
				end
			end
			joint.Transform = result
			stillTouched[joint] = true
		end
	end

	for joint in pairs(touched) do
		if not stillTouched[joint] then
			if joint.Parent then joint.Transform = IDENTITY end
		end
	end
	self._touched = stillTouched
end

function Rigger:StepAnimations(dt)
	if self.Destroyed then return end
	if not self.Rig or not self.Rig.Parent then return end

	for _, track in ipairs(self:GetPlayingAnimationTracks()) do
		track:_Step(dt)
	end
	self:_Apply()
end

function Rigger:Destroy()
	if self.Destroyed then return end
	self.Destroyed = true
	for _, track in ipairs(self.Tracks) do
		track:Destroy()
	end
	self.Tracks = {}
	self.Playing = {}
	pcall(function() self:ResetJoints() end)
	ModuleAnimator._RemoveRigger(self)
end

local ENV = (typeof(getgenv) == "function" and getgenv()) or _G

if ENV.__ModuleAnimator then
	local old = ENV.__ModuleAnimator
	if old.Connection then pcall(function() old.Connection:Disconnect() end) end
	for _, rigger in ipairs(old.Riggers or {}) do
		pcall(function() rigger:Destroy() end)
	end
end

local Scheduler = {
	Riggers = {},
	Connection = nil,
}
ENV.__ModuleAnimator = Scheduler
ModuleAnimator.Scheduler = Scheduler

local function Step(dt)
	local riggers = Scheduler.Riggers
	for i = #riggers, 1, -1 do
		local rigger = riggers[i]
		if rigger.Destroyed or not rigger.Rig or not rigger.Rig.Parent then
			table.remove(riggers, i)
		else
			local ok, err = pcall(rigger.StepAnimations, rigger, dt)
			if not ok then
				warn("[ModuleAnimator] step error: " .. tostring(err))
			end
		end
	end
	if #riggers == 0 and Scheduler.Connection then
		Scheduler.Connection:Disconnect()
		Scheduler.Connection = nil
	end
end

local function EnsureConnection()
	if Scheduler.Connection then return end
	local signal = RunService:IsClient() and RunService.RenderStepped or RunService.Heartbeat
	Scheduler.Connection = signal:Connect(Step)
end

function ModuleAnimator._AddRigger(rigger)
	table.insert(Scheduler.Riggers, rigger)
	EnsureConnection()
end

function ModuleAnimator._RemoveRigger(rigger)
	for i, r in ipairs(Scheduler.Riggers) do
		if r == rigger then
			table.remove(Scheduler.Riggers, i)
			break
		end
	end
end

function ModuleAnimator.StopEverything()
	for _, rigger in ipairs(Scheduler.Riggers) do
		pcall(function() rigger:Destroy() end)
	end
	Scheduler.Riggers = {}
	if Scheduler.Connection then
		Scheduler.Connection:Disconnect()
		Scheduler.Connection = nil
	end
end

function ModuleAnimator.Play(rig, source, options)
	options = options or {}
	local rigger = ModuleAnimator.new(rig, options)
	local track = rigger:LoadAnimation(source, options.Name)
	if options.Looped ~= nil then track.Looped = options.Looped end
	if options.Priority then track.Priority = options.Priority end
	track:Play(options.FadeTime or 0.1, options.Weight or 1, options.Speed or 1)
	return track, rigger
end

return ModuleAnimator
