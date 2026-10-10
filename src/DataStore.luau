--!strict
--!optimize 2

--[=[
	DataStore: one mock data store. It keeps each key's versions for VersionKeepSeconds, and a removed key
	still lists for that long. UpdateAsync gives up its turn between its read and its write, as a real
	request does, so two writes on one key can meet; the transform then runs again. A transform that
	yields raises, and one that throws answers nil and writes nothing, as a real one does.

	Key listings come back in a fixed order that is not key order, since a real listing promises no
	order: by a hash of the key, then by the key. A cursor names the last key of its page. A listing that
	excludes removed keys ends a page after KeysScannedPerPage keys, as a real one does, so a page can come
	back short or empty while more follow.

	It spends its budgets through the Host its service gives it, and reads the time there.

	Return type: The DataStore class.
	Example usage:
		local DataStore = require("./DataStore")
		local Store = DataStore.New("PlayerData", "global", Host)
--]=]

local DataStoreLimits = require("./DataStoreLimits")
local Json = require("./Json")
local NoYield = require("./NoYield")
local Pages = require("./Pages")

type Pages = Pages.Pages

export type Host = {
	read Now: () -> number,
	read Wait: (Seconds: number) -> (),
	read SpendRequest: (Kind: Enum.DataStoreRequestType) -> (),
	read SpendKeyBytes: (Direction: "Read" | "Write", Key: string, Bytes: number) -> (),
	read CountConflict: () -> (),
}

export type KeyInfo = {
	read Version: string,
	read CreatedTime: number,
	read UpdatedTime: number,
	read GetUserIds: (self: KeyInfo) -> { number },
	read GetMetadata: (self: KeyInfo) -> { [string]: any },
}

export type Transform = (Current: any, Info: KeyInfo?) -> ...any

type KeptVersion = {
	Text: string?,
	WrittenAt: number,
	CreatedTime: number,
	IsDeleted: boolean,
	Name: string,
}

type KeyRecord = {
	LiveText: string?,
	Versions: { KeptVersion },
}

type DataStoreData = {
	Name: string,
	Scope: string,
	Host: Host,
	Records: { [string]: KeyRecord },
	SortedKeys: { string },
	Writes: number,
}

local EncodingService = game:GetService("EncodingService")

local ORDER_HASH = Enum.HashAlgorithm.Blake3
local ORDER_RANGE = 2 ^ 32

local CURSOR_PREFIX = "k"

local DEFAULT_KEYS_PER_PAGE = 50
local DEFAULT_VERSIONS_PER_PAGE = 25

local ListOrderByKey: { [string]: number } = {}

local function NoUserIds(_Info: KeyInfo): { number }
	return {}
end

local function NoMetadata(_Info: KeyInfo): { [string]: any }
	return {}
end

local function NewKeyInfo(Version: KeptVersion): KeyInfo
	return table.freeze({
		Version = Version.Name,
		CreatedTime = Version.CreatedTime,
		UpdatedTime = Version.CreatedTime,
		GetUserIds = NoUserIds,
		GetMetadata = NoMetadata,
	})
end

local function CheckKey(Key: string): ()
	if type(Key) ~= "string" or #Key == 0 then
		error("Mock: key must be a non empty string", 0)
	end

	if #Key > DataStoreLimits.MaxKey then
		error(`Mock: key name exceeds the {DataStoreLimits.MaxKey} character limit`, 0)
	end
end

local function NewestVersion(Record: KeyRecord?): KeptVersion?
	if Record == nil then
		return nil
	end

	return Record.Versions[#Record.Versions]
end

local function NewestVersionName(Record: KeyRecord?): string?
	local Newest = NewestVersion(Record)
	if Newest == nil then
		return nil
	end

	return Newest.Name
end

local function ListOrderOf(Key: string): number
	local Cached = ListOrderByKey[Key]
	if Cached ~= nil then
		return Cached
	end

	local Hash = EncodingService:ComputeStringHash(Key, ORDER_HASH)
	local LeadingWord = bit32.byteswap(buffer.readu32(buffer.fromstring(Hash), 0))
	local Order = LeadingWord % ORDER_RANGE
	ListOrderByKey[Key] = Order
	return Order
end

local function ListsBefore(Left: string, Right: string): boolean
	local LeftOrder = ListOrderOf(Left)
	local RightOrder = ListOrderOf(Right)
	if LeftOrder ~= RightOrder then
		return LeftOrder < RightOrder
	end

	return Left < Right
end

local function FirstIndexNotBelow(SortedKeys: { string }, Key: string): number
	local Low = 1
	local High = #SortedKeys + 1
	while Low < High do
		local Middle = (Low + High) // 2
		if SortedKeys[Middle] < Key then
			Low = Middle + 1
		else
			High = Middle
		end
	end
	return Low
end

local function CursorAfter(Listed: { string }, Index: number): string
	local Key = Listed[Index]
	if Key == nil then
		return ""
	end

	return CURSOR_PREFIX .. Key
end

local function ResumeIndexFor(Listed: { string }, Cursor: string?): number
	if type(Cursor) ~= "string" or string.sub(Cursor, 1, #CURSOR_PREFIX) ~= CURSOR_PREFIX then
		return 1
	end

	local LastListed = string.sub(Cursor, #CURSOR_PREFIX + 1)
	local Low = 1
	local High = #Listed + 1
	while Low < High do
		local Middle = (Low + High) // 2
		local Key = Listed[Middle]
		if Key == LastListed or ListsBefore(Key, LastListed) then
			Low = Middle + 1
		else
			High = Middle
		end
	end
	return Low
end

local function PageSizeFor(PageSize: number?, Default: number): number
	local Asked = if PageSize ~= nil and PageSize > 0 then PageSize else Default
	return math.clamp(Asked, 1, DataStoreLimits.MaxPageSize)
end

local function SplitIntoPages(Rows: { any }, Size: number): { { any } }
	local PageRows: { { any } } = {}
	for First = 1, #Rows, Size do
		local Page: { any } = {}
		table.move(Rows, First, math.min(First + Size - 1, #Rows), 1, Page)
		table.insert(PageRows, Page)
	end

	if #PageRows == 0 then
		local Empty: { any } = {}
		table.insert(PageRows, Empty)
	end
	return PageRows
end

local function NewestFirst(Rows: { any }): { any }
	local Reversed: { any } = {}
	for Index = #Rows, 1, -1 do
		table.insert(Reversed, Rows[Index])
	end
	return Reversed
end

local DataStore = {}
DataStore.__index = DataStore

export type DataStore = setmetatable<DataStoreData, typeof(DataStore)>

local function SpendRequest(Store: DataStore, Kind: Enum.DataStoreRequestType): ()
	Store.Host.SpendRequest(Kind)
	Store.Host.Wait(0)
end

local function RecordFor(Store: DataStore, Key: string): KeyRecord
	local Found = Store.Records[Key]
	if Found ~= nil then
		return Found
	end

	local Fresh: KeyRecord = { LiveText = nil, Versions = {} }
	Store.Records[Key] = Fresh
	table.insert(Store.SortedKeys, FirstIndexNotBelow(Store.SortedKeys, Key), Key)
	return Fresh
end

local function DropExpiredVersions(Record: KeyRecord, Now: number): ()
	local KeepFrom = Now - DataStoreLimits.VersionKeepSeconds
	local Newest = #Record.Versions
	local Kept: { KeptVersion } = {}
	for Index, Version in Record.Versions do
		if Version.WrittenAt >= KeepFrom or Index == Newest then
			table.insert(Kept, Version)
		end
	end
	Record.Versions = Kept
end

local function AddVersion(Store: DataStore, Key: string, Text: string?, IsDeleted: boolean): KeptVersion
	local Record = RecordFor(Store, Key)
	Store.Writes += 1

	local WrittenAt = Store.Host.Now()
	local Previous = NewestVersion(Record)
	local EarliestCreatedTime = if Previous ~= nil then Previous.CreatedTime + 1 else 0
	local Fresh: KeptVersion = {
		Text = Text,
		WrittenAt = WrittenAt,
		CreatedTime = math.max(WrittenAt * 1000, EarliestCreatedTime),
		IsDeleted = IsDeleted,
		Name = `{Store.Writes}`,
	}
	Record.LiveText = Text
	table.insert(Record.Versions, Fresh)
	DropExpiredVersions(Record, WrittenAt)

	assert(NewestVersion(Record) == Fresh, "the mock wrote a version that is not the one a read would hand back")
	return Fresh
end

local function ReadLatest(Store: DataStore, Key: string): (any, KeyInfo?)
	local Record = Store.Records[Key]
	local Newest = NewestVersion(Record)
	if Record == nil or Newest == nil then
		return nil, nil
	end

	local Text = Record.LiveText
	if Text == nil then
		return nil, nil
	end

	Store.Host.SpendKeyBytes("Read", Key, #Text)
	return Json.Decode(Text), NewKeyInfo(Newest)
end

local function WriteValue(Store: DataStore, Key: string, Value: any): KeptVersion
	local Text = Json.Encode(Value)
	Store.Host.SpendKeyBytes("Write", Key, #Text)
	return AddVersion(Store, Key, Text, false)
end

local function IsListed(Record: KeyRecord?, KeepFrom: number): boolean
	local Newest = NewestVersion(Record)
	if Record == nil or Newest == nil then
		return false
	end

	return Record.LiveText ~= nil or Newest.WrittenAt >= KeepFrom
end

local function ListedKeys(Store: DataStore, Prefix: string): { string }
	local SortedKeys = Store.SortedKeys
	local KeepFrom = Store.Host.Now() - DataStoreLimits.VersionKeepSeconds

	local Listed: { string } = {}
	for Index = FirstIndexNotBelow(SortedKeys, Prefix), #SortedKeys do
		local Key = SortedKeys[Index]
		if Prefix ~= "" and string.sub(Key, 1, #Prefix) ~= Prefix then
			break
		end

		if IsListed(Store.Records[Key], KeepFrom) then
			table.insert(Listed, Key)
		end
	end

	table.sort(Listed, ListsBefore)
	return Listed
end

local function PagesOfEveryKey(Listed: { string }, From: number, Size: number, SpendPage: () -> ()): Pages
	local Rows: { any } = {}
	local NextCursors: { string } = {}
	for Index = From, #Listed do
		table.insert(Rows, { KeyName = Listed[Index] })
		if #Rows % Size == 0 then
			table.insert(NextCursors, CursorAfter(Listed, Index))
		end
	end

	return Pages.New(SplitIntoPages(Rows, Size), NextCursors, SpendPage)
end

local function PagesOfLiveKeys(
	Store: DataStore,
	Listed: { string },
	From: number,
	Size: number,
	SpendPage: () -> ()
): Pages
	local PageRows: { { any } } = {}
	local NextCursors: { string } = {}
	local Page: { any } = {}
	local Scanned = 0
	for Index = From, #Listed do
		local Key = Listed[Index]
		Scanned += 1
		if Store.Records[Key].LiveText ~= nil then
			table.insert(Page, { KeyName = Key })
		end

		if #Page >= Size or Scanned >= DataStoreLimits.KeysScannedPerPage then
			table.insert(PageRows, Page)
			table.insert(NextCursors, CursorAfter(Listed, Index))
			Page = {}
			Scanned = 0
		end
	end

	if Scanned > 0 or #PageRows == 0 then
		table.insert(PageRows, Page)
	end
	return Pages.New(PageRows, NextCursors, SpendPage)
end

function DataStore.New(Name: string, Scope: string, Host: Host): DataStore
	local Data: DataStoreData = {
		Name = Name,
		Scope = Scope,
		Host = Host,
		Records = {},
		SortedKeys = {},
		Writes = 0,
	}
	return setmetatable(Data, DataStore)
end

function DataStore.GetAsync(self: DataStore, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	SpendRequest(self, Enum.DataStoreRequestType.GetAsync)
	return ReadLatest(self, Key)
end

function DataStore.UpdateAsync(self: DataStore, Key: string, Transform: Transform): (any, KeyInfo?)
	CheckKey(Key)

	for _ = 1, DataStoreLimits.MaxTransformRuns do
		SpendRequest(self, Enum.DataStoreRequestType.UpdateAsync)
		local ReadVersionName = NewestVersionName(self.Records[Key])

		local Current, Info = ReadLatest(self, Key)
		self.Host.Wait(0)

		local Ran, Result = NoYield.Try(Transform, Current, Info)
		if not Ran then
			if NoYield.Yielded(Result) then
				error(`Mock: the UpdateAsync transform on '{Key}' yielded, take the wait out of it: {Result}`, 0)
			end
			return nil, nil
		end

		if Result == nil then
			return nil, nil
		end

		if NewestVersionName(self.Records[Key]) ~= ReadVersionName then
			self.Host.CountConflict()
			continue
		end

		local Fresh = WriteValue(self, Key, Result)
		local Stored = Json.Decode(Fresh.Text)
		assert(Stored ~= nil, "the mock stored a transform result it cannot read back, so a round trip loses data")
		return Stored, NewKeyInfo(Fresh)
	end

	error(`Mock: UpdateAsync on '{Key}' could not settle, too many conflicting writes`, 0)
end

function DataStore.SetAsync(self: DataStore, Key: string, Value: any): string
	CheckKey(Key)
	SpendRequest(self, Enum.DataStoreRequestType.SetIncrementAsync)
	return WriteValue(self, Key, Value).Name
end

function DataStore.RemoveAsync(self: DataStore, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	SpendRequest(self, Enum.DataStoreRequestType.SetIncrementAsync)

	local Current, Info = ReadLatest(self, Key)
	if Info == nil then
		return nil, nil
	end

	AddVersion(self, Key, nil, true)
	return Current, Info
end

function DataStore.GetVersionAsync(self: DataStore, Key: string, Version: string): (any, KeyInfo?)
	CheckKey(Key)
	SpendRequest(self, Enum.DataStoreRequestType.GetVersionAsync)

	local Record = self.Records[Key]
	if Record ~= nil then
		for _, Kept in Record.Versions do
			if Kept.Name == Version then
				return Json.Decode(Kept.Text), NewKeyInfo(Kept)
			end
		end
	end

	error(`Mock: no version '{Version}' for key '{Key}'`, 0)
end

function DataStore.ListVersionsAsync(
	self: DataStore,
	Key: string,
	Direction: Enum.SortDirection?,
	MinDate: number?,
	MaxDate: number?,
	PageSize: number?
): Pages
	CheckKey(Key)
	SpendRequest(self, Enum.DataStoreRequestType.ListAsync)

	local Rows: { any } = {}
	local Record = self.Records[Key]
	if Record ~= nil then
		for _, Kept in Record.Versions do
			if MinDate ~= nil and Kept.CreatedTime < MinDate then
				continue
			end

			if MaxDate ~= nil and Kept.CreatedTime > MaxDate then
				continue
			end

			table.insert(Rows, {
				Version = Kept.Name,
				CreatedTime = Kept.CreatedTime,
				IsDeleted = Kept.IsDeleted,
			})
		end
	end

	if Direction ~= Enum.SortDirection.Ascending then
		Rows = NewestFirst(Rows)
	end

	local Size = PageSizeFor(PageSize, DEFAULT_VERSIONS_PER_PAGE)
	return Pages.New(SplitIntoPages(Rows, Size), {}, nil)
end

function DataStore.ListKeysAsync(
	self: DataStore,
	Prefix: string?,
	PageSize: number?,
	Cursor: string?,
	ExcludeDeleted: boolean?
): Pages
	SpendRequest(self, Enum.DataStoreRequestType.ListAsync)

	local Listed = ListedKeys(self, Prefix or "")
	local From = ResumeIndexFor(Listed, Cursor)
	local Size = PageSizeFor(PageSize, DEFAULT_KEYS_PER_PAGE)
	local function SpendPage(): ()
		SpendRequest(self, Enum.DataStoreRequestType.ListAsync)
	end

	if ExcludeDeleted == true then
		return PagesOfLiveKeys(self, Listed, From, Size, SpendPage)
	end

	return PagesOfEveryKey(Listed, From, Size, SpendPage)
end

return DataStore
