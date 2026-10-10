--!strict
--!optimize 2

--[=[
	Service: the mock DataStoreService and MemoryStoreService, in one object that answers both services'
	methods. It owns this server's data store request budget, the experience's MemoryStore units and the
	memory its maps hold.

	Every budget is a token bucket that refills against the scheduler's clock, so a test that owns its
	clock owns the refill. A data store request short of budget waits in a queue, and fails once MaxQueued
	are waiting. A MemoryStore request short of units, or a write past the memory quota, fails at once.
	With Throttled false no limit applies, and only the counters move.

	Queued, Conflicts, Units, UnitsByMap, Calls, Bytes and PeakBytes are counters for tests to read;
	nothing is decided from them.

	Return type: The Service class.
	Example usage:
		local Service = require("./Service")
		local Mock = Service.New({ Players = 20 }, nil)
		local Store = Mock:GetDataStore("PlayerData")
--]=]

local Budget = require("./Budget")
local DataStore = require("./DataStore")
local DataStoreLimits = require("./DataStoreLimits")
local HashMap = require("./HashMap")
local MemoryStoreLimits = require("./MemoryStoreLimits")

type DataStore = DataStore.DataStore
type HashMap = HashMap.HashMap

export type Options = {
	Players: number?,
	CCU: number?,
	Throttled: boolean?,
}

export type Scheduler = {
	read Now: () -> number,
	read Wait: (Seconds: number) -> (),
}

type TokenBucket = {
	read Id: string,
	read Cap: number,
}

type ServiceData = {
	Scheduler: Scheduler,
	Stores: { [string]: DataStore },
	Maps: { [string]: HashMap },
	Tokens: { [string]: number },
	RefilledAt: { [string]: number },
	Players: number,
	CCU: number,
	Throttled: boolean,

	Queued: number,
	Conflicts: number,
	Units: number,
	UnitsByMap: { [string]: number },
	Calls: { [string]: number },
	Bytes: number,
	PeakBytes: number,
}

local EXPERIENCE_UNITS_BUCKET = "m\0units"

local REAL_SCHEDULER: Scheduler = table.freeze({
	Now = function(): number
		return os.time()
	end,
	Wait = function(Seconds: number): ()
		task.wait(Seconds)
	end,
})

local function CheckStoreName(Name: string): ()
	if type(Name) ~= "string" or #Name == 0 then
		error("Mock: a data store name must be a non empty string", 0)
	end

	if #Name > DataStoreLimits.MaxName then
		error(`Mock: data store name exceeds the {DataStoreLimits.MaxName} character limit`, 0)
	end
end

local function CheckScope(Scope: string?): ()
	if Scope ~= nil and #Scope > DataStoreLimits.MaxScope then
		error(`Mock: scope exceeds the {DataStoreLimits.MaxScope} character limit`, 0)
	end
end

local function CheckMapName(Name: string): ()
	if type(Name) ~= "string" or #Name == 0 then
		error("Mock: a MemoryStore map name must be a non empty string", 0)
	end

	if #Name > MemoryStoreLimits.MaxName then
		error(`Mock: MemoryStore map name exceeds the {MemoryStoreLimits.MaxName} character limit`, 0)
	end
end

local function ServerBucketId(Kind: Enum.DataStoreRequestType): string
	return `s\0{Kind.Name}`
end

local Service = {}
Service.__index = Service

export type Service = setmetatable<ServiceData, typeof(Service)>

local function ServerCap(Mock: Service, Kind: Enum.DataStoreRequestType): number
	return Budget.Ceiling(Budget.AllowanceFor(Kind).Server, Mock.Players)
end

local function RequestBuckets(Mock: Service, Kind: Enum.DataStoreRequestType): { TokenBucket }
	local Allowance = Budget.AllowanceFor(Kind)
	return {
		{ Id = ServerBucketId(Kind), Cap = Budget.Ceiling(Allowance.Server, Mock.Players) },
		{ Id = `x\0{Kind.Name}`, Cap = Budget.Ceiling(Allowance.Experience, Mock.CCU) },
	}
end

local function Refill(Mock: Service, Id: string, Cap: number): number
	local Now = Mock.Scheduler.Now()
	local Held = math.min(Cap, Mock.Tokens[Id] or Cap)
	local Elapsed = Now - (Mock.RefilledAt[Id] or Now)

	local Refilled = math.min(Cap, Held + Elapsed * (Cap / DataStoreLimits.RefillSeconds))
	Mock.Tokens[Id] = Refilled
	Mock.RefilledAt[Id] = Now
	return Refilled
end

local function CanAfford(Mock: Service, Buckets: { TokenBucket }, Cost: number): boolean
	for _, Bucket in Buckets do
		if Refill(Mock, Bucket.Id, Bucket.Cap) < Cost then
			return false
		end
	end
	return true
end

local function Deduct(Mock: Service, Buckets: { TokenBucket }, Cost: number): ()
	for _, Bucket in Buckets do
		Mock.Tokens[Bucket.Id] -= Cost
		assert(
			Mock.Tokens[Bucket.Id] >= 0,
			"the mock spent request budget it did not have, so it is more generous than a real server"
		)
	end
end

local function WaitForBudget(Mock: Service, Buckets: { TokenBucket }, Cost: number): ()
	if CanAfford(Mock, Buckets, Cost) then
		Deduct(Mock, Buckets, Cost)
		return
	end

	if Mock.Queued >= DataStoreLimits.MaxQueued then
		error("Mock: DataStore request dropped, the queue is full and this server is out of budget", 0)
	end

	Mock.Queued += 1
	while not CanAfford(Mock, Buckets, Cost) do
		Mock.Scheduler.Wait(DataStoreLimits.QueuePollSeconds)
	end
	Mock.Queued -= 1
	assert(Mock.Queued >= 0, "the mock let more requests off its queue than it ever put on")

	Deduct(Mock, Buckets, Cost)
end

local function SpendRequest(Mock: Service, Kind: Enum.DataStoreRequestType): ()
	Mock.Calls[Kind.Name] = (Mock.Calls[Kind.Name] or 0) + 1
	if not Mock.Throttled then
		return
	end

	WaitForBudget(Mock, RequestBuckets(Mock, Kind), 1)
end

local function SpendKeyBytes(Mock: Service, Direction: "Read" | "Write", Store: string, Key: string, Bytes: number): ()
	if not Mock.Throttled or Bytes <= 0 then
		return
	end

	local Cap = if Direction == "Write" then DataStoreLimits.WriteBytesPerKey else DataStoreLimits.ReadBytesPerKey
	local Bucket: TokenBucket = { Id = `{Direction}\0{Store}\0{Key}`, Cap = Cap }
	WaitForBudget(Mock, { Bucket }, math.min(Bytes, Cap))
end

local function SpendUnits(Mock: Service, Map: string, Cost: number): ()
	Mock.Units += Cost
	Mock.UnitsByMap[Map] = (Mock.UnitsByMap[Map] or 0) + Cost
	if not Mock.Throttled then
		return
	end

	local ExperienceCap = MemoryStoreLimits.UnitsBase + MemoryStoreLimits.UnitsPerUser * Mock.CCU
	local Buckets: { TokenBucket } = {
		{ Id = EXPERIENCE_UNITS_BUCKET, Cap = ExperienceCap },
		{ Id = `{EXPERIENCE_UNITS_BUCKET}\0{Map}`, Cap = MemoryStoreLimits.UnitsPerMap },
	}
	if not CanAfford(Mock, Buckets, Cost) then
		error("Mock: MemoryStore request dropped, this experience is out of request units", 0)
	end

	Deduct(Mock, Buckets, Cost)
end

local function AddMemory(Mock: Service, Bytes: number): ()
	Mock.Bytes += Bytes
	Mock.PeakBytes = math.max(Mock.PeakBytes, Mock.Bytes)
end

local function RemoveExpiredItems(Mock: Service): ()
	for _, Map in Mock.Maps do
		Map:RemoveExpired()
	end
end

local function ReserveMemory(Mock: Service, Bytes: number): ()
	if not Mock.Throttled or Bytes <= 0 then
		return
	end

	local Cap = MemoryStoreLimits.MemoryBase + MemoryStoreLimits.MemoryPerUser * Mock.CCU
	if Mock.Bytes + Bytes <= Cap then
		return
	end

	RemoveExpiredItems(Mock)
	if Mock.Bytes + Bytes <= Cap then
		return
	end

	error("Mock: MemoryStore write refused, this experience is out of memory", 0)
end

local function CountConflict(Mock: Service): ()
	Mock.Conflicts += 1
end

local function StoreHost(Mock: Service, Name: string): DataStore.Host
	return table.freeze({
		Now = Mock.Scheduler.Now,
		Wait = Mock.Scheduler.Wait,
		SpendRequest = function(Kind: Enum.DataStoreRequestType): ()
			SpendRequest(Mock, Kind)
		end,
		SpendKeyBytes = function(Direction: "Read" | "Write", Key: string, Bytes: number): ()
			SpendKeyBytes(Mock, Direction, Name, Key, Bytes)
		end,
		CountConflict = function(): ()
			CountConflict(Mock)
		end,
	})
end

local function MapHost(Mock: Service, Name: string): HashMap.Host
	return table.freeze({
		Now = Mock.Scheduler.Now,
		Wait = Mock.Scheduler.Wait,
		SpendUnits = function(Cost: number): ()
			SpendUnits(Mock, Name, Cost)
		end,
		ReserveMemory = function(Bytes: number): ()
			ReserveMemory(Mock, Bytes)
		end,
		AddMemory = function(Bytes: number): ()
			AddMemory(Mock, Bytes)
		end,
		CountConflict = function(): ()
			CountConflict(Mock)
		end,
	})
end

function Service.New(Options: Options?, Scheduler: Scheduler?): Service
	local Given: Options = Options or {}
	local Players = Given.Players or 0

	local Data: ServiceData = {
		Scheduler = Scheduler or REAL_SCHEDULER,
		Stores = {},
		Maps = {},
		Tokens = {},
		RefilledAt = {},
		Players = Players,
		CCU = Given.CCU or Players,
		Throttled = Given.Throttled ~= false,

		Queued = 0,
		Conflicts = 0,
		Units = 0,
		UnitsByMap = {},
		Calls = {},
		Bytes = 0,
		PeakBytes = 0,
	}
	return setmetatable(Data, Service)
end

function Service.GetDataStore(self: Service, Name: string, Scope: string?): DataStore
	CheckStoreName(Name)
	CheckScope(Scope)

	local InScope = Scope or "global"
	local Id = `{Name}\0{InScope}`

	local Found = self.Stores[Id]
	if Found ~= nil then
		return Found
	end

	local Fresh = DataStore.New(Name, InScope, StoreHost(self, Name))
	self.Stores[Id] = Fresh
	return Fresh
end

function Service.GetHashMap(self: Service, Name: string): HashMap
	CheckMapName(Name)

	local Found = self.Maps[Name]
	if Found ~= nil then
		return Found
	end

	local Fresh = HashMap.New(Name, MapHost(self, Name))
	self.Maps[Name] = Fresh
	return Fresh
end

function Service.GetRequestBudgetForRequestType(self: Service, Kind: Enum.DataStoreRequestType): number
	return math.floor(Refill(self, ServerBucketId(Kind), ServerCap(self, Kind)))
end

function Service.Reset(self: Service): ()
	table.clear(self.Stores)
	table.clear(self.Maps)
	table.clear(self.Tokens)
	table.clear(self.RefilledAt)
	self.Queued = 0
	self.Conflicts = 0
	self.Units = 0
	table.clear(self.UnitsByMap)
	table.clear(self.Calls)
	self.Bytes = 0
	self.PeakBytes = 0
end

return Service
