--!strict
--!optimize 2

--[=[
	Storable: whether a value survives a trip to a MemoryStore and back unchanged. A buffer passes here;
	whether the encoding can carry one is the caller's to check.

	Return type: The Storable module.
	Example usage:
		local Storable = require("./Storable")
		local Fits, Where = Storable.Check(Value)
--]=]

local DataStoreLimits = require("./DataStoreLimits")

local CheckValue: (Value: any, Path: string, Seen: { [any]: boolean }, Depth: number) -> (boolean, string)

local function CheckTable(
	Value: { [any]: any },
	Path: string,
	Seen: { [any]: boolean },
	Depth: number
): (boolean, string)
	local ArrayKeys = 0
	local StringKeys = 0
	for Key in Value do
		local KeyType = type(Key)
		if KeyType == "number" then
			if Key % 1 ~= 0 or Key < 1 then
				return false, `{Path} has a non integer or non positive key`
			end
			ArrayKeys += 1
		elseif KeyType == "string" then
			if utf8.len(Key) == nil then
				return false, `{Path} has a key that is not valid utf8`
			end
			StringKeys += 1
		else
			return false, `{Path} has a {typeof(Key)} key`
		end
	end

	if ArrayKeys > 0 and StringKeys > 0 then
		return false, `{Path} mixes array and string keys`
	end

	for Index = 1, ArrayKeys do
		if Value[Index] == nil then
			return false, `{Path} is a sparse array`
		end
	end

	for Key, Inner in Value do
		local Fits, Where = CheckValue(Inner, `{Path}.{Key}`, Seen, Depth + 1)
		if not Fits then
			return false, Where
		end
	end

	return true, Path
end

function CheckValue(Value: any, Path: string, Seen: { [any]: boolean }, Depth: number): (boolean, string)
	local ValueType = type(Value)

	if ValueType == "number" then
		if Value ~= Value or Value == math.huge or Value == -math.huge then
			return false, `{Path} is nan or inf`
		end
		return true, Path
	end

	if ValueType == "string" then
		if utf8.len(Value) == nil then
			return false, `{Path} is not valid utf8`
		end
		return true, Path
	end

	if ValueType == "boolean" or ValueType == "buffer" then
		return true, Path
	end

	if ValueType ~= "table" then
		return false, `{Path} is a {typeof(Value)}`
	end

	if Depth > DataStoreLimits.MaxDepth then
		return false, `{Path} nests deeper than {DataStoreLimits.MaxDepth} levels`
	end

	if getmetatable(Value) ~= nil then
		return false, `{Path} has a metatable`
	end

	if Seen[Value] then
		return false, `{Path} is cyclic`
	end

	Seen[Value] = true
	local Fits, Where = CheckTable(Value, Path, Seen, Depth)
	Seen[Value] = nil
	return Fits, Where
end

local Storable = {}

function Storable.Check(Value: any): (boolean, string?)
	local Fits, Where = CheckValue(Value, "value", {}, 0)
	if not Fits then
		return false, Where
	end

	return true, nil
end

return Storable
