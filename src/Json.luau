--!strict
--!optimize 2

--[=[
	Json: the JSON trip a real data store puts a value through. A buffer has no JSON form, so it is stored
	compressed, as base64 under BUFFER_KEY, the way a real data store stores one; only a table holding
	that one key reads back as a buffer. Decode answers nil for text that is not JSON.

	Return type: The Json module.
	Example usage:
		local Json = require("./Json")
		local Text = Json.Encode(Value)
--]=]

local DataStoreLimits = require("./DataStoreLimits")

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local BUFFER_KEY = "__Buffer"

local ZSTD = Enum.CompressionAlgorithm.Zstd
local ZSTD_LEVEL = 1

local function WithBuffersPacked(Value: any): any
	if type(Value) == "buffer" then
		local Compressed = EncodingService:CompressBuffer(Value, ZSTD, ZSTD_LEVEL)
		return { [BUFFER_KEY] = buffer.tostring(EncodingService:Base64Encode(Compressed)) }
	end

	if type(Value) ~= "table" then
		return Value
	end

	local Packed: { [any]: any } = {}
	for Key, Inner in Value do
		Packed[Key] = WithBuffersPacked(Inner)
	end
	return Packed
end

local function IsPackedBuffer(Value: { [any]: any }): boolean
	local First = next(Value)
	return type(Value[BUFFER_KEY]) == "string" and next(Value, First) == nil
end

local function WithBuffersUnpacked(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end

	if IsPackedBuffer(Value) then
		local Compressed = EncodingService:Base64Decode(buffer.fromstring(Value[BUFFER_KEY]))
		return EncodingService:DecompressBuffer(Compressed, ZSTD)
	end

	local Unpacked: { [any]: any } = {}
	for Key, Inner in Value do
		Unpacked[Key] = WithBuffersUnpacked(Inner)
	end
	return Unpacked
end

local Json = {}

function Json.Encode(Value: any): string
	local Packed = WithBuffersPacked(Value)
	local Encoded, Text = pcall(function(): string
		return HttpService:JSONEncode(Packed)
	end)
	if not Encoded or type(Text) ~= "string" then
		error("Mock: value cannot be stored, a data store only holds json", 0)
	end

	if #Text > DataStoreLimits.MaxValue then
		error(`Mock: value is larger than the {DataStoreLimits.MaxValue} byte limit`, 0)
	end

	local Decoded, Back = pcall(function(): any
		return HttpService:JSONDecode(Text)
	end)
	assert(Decoded and Back ~= nil, "the mock encoded a value it cannot decode again, so a round trip would lose it")
	return Text
end

function Json.Decode(Text: string?): any
	if Text == nil then
		return nil
	end

	local Decoded, Value = pcall(function(): any
		return HttpService:JSONDecode(Text)
	end)
	if not Decoded then
		return nil
	end

	return WithBuffersUnpacked(Value)
end

return Json
