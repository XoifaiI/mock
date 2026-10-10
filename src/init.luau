--!strict
--!optimize 2

--[=[
	Mock: an in-memory DataStoreService and MemoryStoreService that keep the real services' limits, so code
	tested against it meets the refusals it would meet live. One service answers both services' methods.
	Players sizes this server's request budget and CCU the experience's (it defaults to Players); Throttled
	false turns every limit off. Without a Scheduler the mock runs on os.time and task.wait.

	Return type: The Mock module.
	Example usage:
		local Mock = require("./Mock")
		local Service = Mock.New({ Players = 10 }, nil)
		local Store = Service:GetDataStore("PlayerData")
--]=]

local DataStore = require("@self/DataStore")
local HashMap = require("@self/HashMap")
local Pages = require("@self/Pages")
local Service = require("@self/Service")

export type Options = Service.Options
export type Scheduler = Service.Scheduler
export type Service = Service.Service
export type DataStore = DataStore.DataStore
export type KeyInfo = DataStore.KeyInfo
export type HashMap = HashMap.HashMap
export type Pages = Pages.Pages

local Mock = {}

function Mock.New(Options: Options?, Scheduler: Scheduler?): Service
	return Service.New(Options, Scheduler)
end

return Mock
