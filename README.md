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

One service answers both services' methods, so pass the same object wherever the code under test
takes a `DataStoreService` or a `MemoryStoreService`. Two pieces of code given the same service act
like two servers on one experience.

### Options

| Option | Default | What it does |
| --- | --- | --- |
| `Players` | 0 | Players in this server. The server's request budget grows with it. |
| `CCU` | `Players` | Players across the experience. The experience's budget and MemoryStore quotas grow with it. |
| `Throttled` | `true` | `false` turns every budget, quota and byte limit off. |

## What it supports

**Data stores** (`Service:GetDataStore(Name, Scope?)`): `GetAsync`, `SetAsync`, `UpdateAsync`,
`RemoveAsync`, `GetVersionAsync`, `ListVersionsAsync`, `ListKeysAsync`, and
`Service:GetRequestBudgetForRequestType`.

**Hash maps** (`Service:GetHashMap(Name)`): `GetAsync`, `SetAsync`, `UpdateAsync`, `RemoveAsync`.

## Limits it keeps

- Names, scopes and keys up to their real lengths; values up to 4 MB as JSON; MemoryStore items up to 32 KB.
- The data store request budget, per server and per experience, refilled over a minute. A request
  short of budget waits in a queue, and fails once 30 are waiting.
- How many bytes one key can be read and written per minute.
- MemoryStore request units, for the experience and per map, and the memory quota. Both fail at once.
- Versions kept for 30 days; a removed key still lists for that long.
- Two writes on one key can meet: `UpdateAsync` runs its transform again, as the real one does.

## Where it's stricter than the real services

- An `UpdateAsync` transform that yields throws, on both services.
- A MemoryStore item has to read back exactly as it went in. A buffer, a mixed table, a sparse
  array or NaN is refused, where the real service would quietly mangle it.
- Key listings come back in a fixed order that isn't key order, so code can't come to rely on an order.

## Reading what happened

The service keeps counters a test can read: `Calls` (data store requests by type), `Conflicts`
(transforms that ran again), `Units` and `UnitsByMap` (MemoryStore units spent), `Bytes` and
`PeakBytes` (MemoryStore memory), and `Queued`. `Service:Reset()` forgets everything.
