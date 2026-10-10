# Mock

An in-memory `DataStoreService` and `MemoryStoreService` for Roblox, for testing code that saves data
without touching real DataStores. It keeps the real services' limits, so code tested against it meets
the same refusals it would meet live.

It has no dependencies. It's a rewrite of Ledger v6's mock (XoifaiI/Ledger at `4c35319`) as a
package of its own, with the same behaviour.

## Use

```luau
local Mock = require(path.to.Mock)

local Service = Mock.New({ Players = 10 })

local Store = Service:GetDataStore("PlayerData")
Store:SetAsync("1", { Gold = 10 })
print(Store:GetAsync("1").Gold) --> 10

local Map = Service:GetHashMap("Sessions")
Map:SetAsync("1", "server-a", 60)
```
