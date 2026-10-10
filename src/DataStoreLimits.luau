--!strict
--!optimize 2

--[=[
	DataStoreLimits: the limits a real data store keeps, which the mock keeps as well. The request budget
	refills over RefillSeconds, and the per-key byte budgets refill over the same window.

	Return type: A frozen table of limits.
	Example usage:
		local DataStoreLimits = require("./DataStoreLimits")
		local IsTooLong = #Key > DataStoreLimits.MaxKey
--]=]

local SecondsPerDay = 86400

return table.freeze({
	MaxName = 50,
	MaxScope = 50,
	MaxKey = 50,
	MaxValue = 4 * 1024 * 1024,
	MaxDepth = 64,

	VersionKeepSeconds = 30 * SecondsPerDay,
	MaxPageSize = 50,
	KeysScannedPerPage = 512,
	MaxTransformRuns = 32,

	RefillSeconds = 60,
	MaxQueued = 30,
	QueuePollSeconds = 0.05,

	ReadBytesPerKey = 25 * 1024 * 1024,
	WriteBytesPerKey = 4 * 1024 * 1024,
})
