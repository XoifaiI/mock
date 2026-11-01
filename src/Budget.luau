--!strict
--!optimize 2

--[=[
	Budget: the data store request allowances of a real server, by the eight request types the limits page
	counts (StandardRead to OrderedRemove) and RemoveVersionAsync. Each type has this server's allowance and
	the whole experience's, and a request has to afford both.

	A legacy name (GetAsync, UpdateAsync and the rest) reads the types its calls draw on: UpdateAsync draws on
	StandardRead and StandardWrite. OnUpdate draws on nothing the limits page counts, so it keeps an allowance
	of its own.

	Return type: The Budget module.
	Example usage:
		local Budget = require("./Budget")
		local Cap = Budget.Ceiling(Budget.AllowanceOf("StandardRead").Server, Players)
		local Names = Budget.DrawsOf(Enum.DataStoreRequestType.UpdateAsync) --> { "StandardRead", "StandardWrite" }
--]=]

export type Allowance = {
	read Base: number,
	read PerPlayer: number,
}

export type RequestBudget = {
	read Server: Allowance,
	read Experience: Allowance,
}

local READING: RequestBudget = {
	Server = { Base = 60, PerPlayer = 40 },
	Experience = { Base = 300, PerPlayer = 40 },
}

local WRITING: RequestBudget = {
	Server = { Base = 60, PerPlayer = 40 },
	Experience = { Base = 300, PerPlayer = 20 },
}

local LISTING: RequestBudget = {
	Server = { Base = 5, PerPlayer = 2 },
	Experience = { Base = 300, PerPlayer = 2 },
}

local REMOVING: RequestBudget = {
	Server = { Base = 60, PerPlayer = 40 },
	Experience = { Base = 300, PerPlayer = 40 },
}

local ORDERED_WRITING: RequestBudget = {
	Server = { Base = 30, PerPlayer = 5 },
	Experience = { Base = 300, PerPlayer = 20 },
}

local ORDERED_REMOVING: RequestBudget = {
	Server = { Base = 30, PerPlayer = 5 },
	Experience = { Base = 300, PerPlayer = 40 },
}

local VERSION_REMOVING: RequestBudget = {
	Server = { Base = 5, PerPlayer = 2 },
	Experience = { Base = 300, PerPlayer = 40 },
}

local BY_REQUEST_TYPE: { [string]: RequestBudget } = {
	StandardRead = READING,
	StandardWrite = WRITING,
	StandardList = LISTING,
	StandardRemove = REMOVING,
	OrderedRead = READING,
	OrderedWrite = ORDERED_WRITING,
	OrderedList = LISTING,
	OrderedRemove = ORDERED_REMOVING,
	RemoveVersionAsync = VERSION_REMOVING,
	OnUpdate = READING,
}

local LEGACY_DRAWS: { [string]: { string } } = {
	GetAsync = { "StandardRead" },
	SetIncrementAsync = { "StandardWrite" },
	UpdateAsync = { "StandardRead", "StandardWrite" },
	GetSortedAsync = { "OrderedList" },
	SetIncrementSortedAsync = { "OrderedWrite" },
	GetVersionAsync = { "StandardRead" },
	ListAsync = { "StandardList" },
}

local Budget = {}

function Budget.Ceiling(Allowance: Allowance, Players: number): number
	return Allowance.Base + Allowance.PerPlayer * Players
end

function Budget.AllowanceOf(Name: string): RequestBudget
	local Found = BY_REQUEST_TYPE[Name]
	if Found == nil then
		error(`Mock: no request budget is kept for {Name}`, 0)
	end
	return Found
end

function Budget.DrawsOf(Kind: Enum.DataStoreRequestType): { string }
	local Legacy = LEGACY_DRAWS[Kind.Name]
	if Legacy ~= nil then
		return Legacy
	end

	Budget.AllowanceOf(Kind.Name)
	return { Kind.Name }
end

return Budget
