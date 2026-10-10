--!strict
--!optimize 2

--[=[
	HashMap: one mock MemoryStore hash map. It is stricter than a real one in one way: an item has to read
	back exactly as it went in. A real map quietly mangles a buffer, a mixed table, a sparse array and NaN,
	so the mock refuses them rather than hide the bug.

	Items expire by os.time. UpdateAsync gives up its turn between its read and its write, so two
	writes on one key can meet; the transform then runs again. An item's WriteNumber is how the meeting
	is noticed. A transform that yields or throws raises, and nothing is written.

	It spends its units and memory through the Host its service gives it.

	Return type: The HashMap class.
	Example usage:
		local HashMap = require("./HashMap")
		local Map = HashMap.New("Sessions", Host)
--]=]

local MemoryStoreLimits = require("./MemoryStoreLimits")
local NoYield = require("./NoYield")
local Storable = require("./Storable")

export type Host = {
	read SpendUnits: (Cost: number) -> (),
	read ReserveMemory: (Bytes: number) -> (),
	read AddMemory: (Bytes: number) -> (),
	read CountConflict: () -> (),
}

export type Transform = (Current: any) -> any

type Item = {
	Text: string,
	ExpiresAt: number,
	WriteNumber: number,
}

type HashMapData = {
	Name: string,
	Host: Host,
	Items: { [string]: Item },
	Writes: number,
}

local HttpService = game:GetService("HttpService")

local function CheckKey(Key: any): ()
	if type(Key) ~= "string" or #Key == 0 then
		error("Mock: a MemoryStore key must be a non empty string", 0)
	end

	if #Key > MemoryStoreLimits.MaxKey then
		error(`Mock: MemoryStore key exceeds the {MemoryStoreLimits.MaxKey} character limit`, 0)
	end

	for Index = 1, #Key do
		if (string.byte(Key, Index) :: number) < MemoryStoreLimits.LowestKeyByte then
			error("Mock: a MemoryStore key cannot hold a byte below a space", 0)
		end
	end
end

local function CheckExpiry(Expiry: any): ()
	if type(Expiry) ~= "number" then
		error("Mock: a MemoryStore write needs an expiry in seconds", 0)
	end

	if Expiry ~= Expiry or Expiry < 0 or Expiry > MemoryStoreLimits.MaxExpiry then
		error(`Mock: a MemoryStore expiry must be between 0 and {MemoryStoreLimits.MaxExpiry} seconds`, 0)
	end
end

local function CountKeys(Value: { [any]: any }): number
	local Count = 0
	for _ in Value do
		Count += 1
	end
	return Count
end

local function IsSameValue(Left: any, Right: any): boolean
	if Left == Right then
		return true
	end

	if type(Left) == "buffer" and type(Right) == "buffer" then
		return buffer.tostring(Left) == buffer.tostring(Right)
	end

	if type(Left) ~= "table" or type(Right) ~= "table" then
		return false
	end

	for Key, Value in Left do
		if not IsSameValue(Value, Right[Key]) then
			return false
		end
	end
	return CountKeys(Left) == CountKeys(Right)
end

local function Decode(Text: string): any
	return HttpService:JSONDecode(Text)
end

local function Encode(Value: any): string
	if Value == nil then
		error("Mock: a MemoryStore item cannot be nil", 0)
	end

	local Fits, Where = Storable.Check(Value)
	if not Fits then
		error(`Mock: a MemoryStore item has to read back as it went in, {Where}`, 0)
	end

	local Encoded, Text = pcall(function(): string
		return HttpService:JSONEncode(Value)
	end)
	if not Encoded or type(Text) ~= "string" then
		error("Mock: a MemoryStore item has to be json", 0)
	end

	if #Text > MemoryStoreLimits.MaxItem then
		error(`Mock: a MemoryStore item is larger than the {MemoryStoreLimits.MaxItem} byte limit`, 0)
	end

	local Decoded, Back = pcall(Decode, Text)
	if not Decoded or not IsSameValue(Back, Value) then
		error("Mock: a MemoryStore item has to read back as it went in", 0)
	end
	return Text
end

local function MemoryOf(Key: string, Text: string): number
	return (#Key + #Text) * MemoryStoreLimits.ItemMemoryFactor
end

local HashMap = {}
HashMap.__index = HashMap

export type HashMap = setmetatable<HashMapData, typeof(HashMap)>

local function SpendUnits(Map: HashMap, Cost: number): ()
	Map.Host.SpendUnits(Cost)
	task.wait(0)
end

local function RemoveItem(Map: HashMap, Key: string, Item: Item): ()
	Map.Items[Key] = nil
	Map.Host.AddMemory(-MemoryOf(Key, Item.Text))
end

local function LiveItem(Map: HashMap, Key: string): Item?
	local Item = Map.Items[Key]
	if Item == nil then
		return nil
	end

	if os.time() >= Item.ExpiresAt then
		RemoveItem(Map, Key, Item)
		return nil
	end

	return Item
end

local function WriteItem(Map: HashMap, Key: string, Value: any, Expiry: number): any
	local Text = Encode(Value)
	local Previous = LiveItem(Map, Key)
	local Freed = if Previous ~= nil then MemoryOf(Key, Previous.Text) else 0
	Map.Host.ReserveMemory(MemoryOf(Key, Text) - Freed)

	if Previous ~= nil then
		RemoveItem(Map, Key, Previous)
	end

	Map.Writes += 1
	Map.Items[Key] = {
		Text = Text,
		ExpiresAt = os.time() + Expiry,
		WriteNumber = Map.Writes,
	}
	Map.Host.AddMemory(MemoryOf(Key, Text))
	return Decode(Text)
end

local function WriteNumberOf(Item: Item?): number?
	if Item == nil then
		return nil
	end

	return Item.WriteNumber
end

function HashMap.New(Name: string, Host: Host): HashMap
	local Data: HashMapData = {
		Name = Name,
		Host = Host,
		Items = {},
		Writes = 0,
	}
	return setmetatable(Data, HashMap)
end

function HashMap.RemoveExpired(self: HashMap): ()
	local Now = os.time()
	for Key, Item in self.Items do
		if Now >= Item.ExpiresAt then
			RemoveItem(self, Key, Item)
		end
	end
end

function HashMap.GetAsync(self: HashMap, Key: string): any
	CheckKey(Key)
	SpendUnits(self, MemoryStoreLimits.RequestCost)

	local Item = LiveItem(self, Key)
	if Item == nil then
		return nil
	end

	return Decode(Item.Text)
end

function HashMap.SetAsync(self: HashMap, Key: string, Value: any, Expiry: number): boolean
	CheckKey(Key)
	CheckExpiry(Expiry)
	SpendUnits(self, MemoryStoreLimits.RequestCost)

	WriteItem(self, Key, Value, Expiry)
	return true
end

function HashMap.UpdateAsync(self: HashMap, Key: string, Transform: Transform, Expiry: number): any
	CheckKey(Key)
	CheckExpiry(Expiry)
	SpendUnits(self, MemoryStoreLimits.UpdateCost)

	for _ = 1, MemoryStoreLimits.MaxTransformRuns do
		local Read = LiveItem(self, Key)
		local ReadWriteNumber = WriteNumberOf(Read)
		local Current = if Read ~= nil then Decode(Read.Text) else nil
		task.wait(0)

		local Ran, Result = NoYield.Try(Transform, Current)
		if not Ran then
			if NoYield.Yielded(Result) then
				error(`Mock: the UpdateAsync transform on '{Key}' yielded, take the wait out of it: {Result}`, 0)
			end
			error(`Mock: the UpdateAsync transform on '{Key}' threw, so nothing was written: {Result}`, 0)
		end

		if Result == nil then
			return nil
		end

		if WriteNumberOf(LiveItem(self, Key)) ~= ReadWriteNumber then
			self.Host.CountConflict()
			continue
		end

		return WriteItem(self, Key, Result, Expiry)
	end

	error(`Mock: UpdateAsync on '{Key}' could not settle, too many conflicting writes`, 0)
end

function HashMap.RemoveAsync(self: HashMap, Key: string): ()
	CheckKey(Key)
	SpendUnits(self, MemoryStoreLimits.RequestCost)

	local Item = self.Items[Key]
	if Item ~= nil then
		RemoveItem(self, Key, Item)
	end
end

return HashMap
