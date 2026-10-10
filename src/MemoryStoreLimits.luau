--!strict
--!optimize 2

--[=[
	MemoryStoreLimits: the limits a real MemoryStore keeps, which the mock keeps as well. ItemMemoryFactor
	is an estimate, not a published limit: Roblox does not publish how it counts an item's memory, and it
	measured at about twice the item's JSON.

	Return type: A frozen table of limits.
	Example usage:
		local MemoryStoreLimits = require("./MemoryStoreLimits")
		local IsTooLong = #Key > MemoryStoreLimits.MaxKey
--]=]

return table.freeze({
	MaxName = 128,
	MaxKey = 128,
	LowestKeyByte = 32,
	MaxItem = 32 * 1024,
	MaxExpiry = 3888000,

	RequestCost = 1,
	UpdateCost = 2,

	UnitsBase = 1000,
	UnitsPerUser = 120,
	UnitsPerMap = 100000,

	MemoryBase = 64 * 1024,
	MemoryPerUser = 1.2 * 1024,
	ItemMemoryFactor = 2,

	MaxTransformRuns = 32,
})
