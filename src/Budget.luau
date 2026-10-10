--!strict
--!optimize 2

--[=[
	Budget: the data store request allowances of a real server. Each request type has this server's
	allowance and the whole experience's, and a request has to afford both.

	Return type: The Budget module.
	Example usage:
		local Budget = require("./Budget")
		local Cap = Budget.Ceiling(Budget.AllowanceFor(Kind).Server, Players)
--]=]

export type Allowance = {
	read Base: number,
	read PerPlayer: number,
}

export type RequestBudget = {
	read Server: Allowance,
	read Experience: Allowance,
}

local STANDARD: RequestBudget = {
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

local BY_REQUEST_TYPE: { [string]: RequestBudget } = {
	GetAsync = STANDARD,
	UpdateAsync = WRITING,
	SetIncrementAsync = WRITING,
	GetSortedAsync = STANDARD,
	SetIncrementSortedAsync = WRITING,
	GetVersionAsync = STANDARD,
	RemoveVersionAsync = STANDARD,
	OnUpdate = STANDARD,
	ListAsync = LISTING,
}

local Budget = {}

function Budget.Ceiling(Allowance: Allowance, Players: number): number
	return Allowance.Base + Allowance.PerPlayer * Players
end

function Budget.AllowanceFor(Kind: Enum.DataStoreRequestType): RequestBudget
	return BY_REQUEST_TYPE[Kind.Name] or STANDARD
end

return Budget
