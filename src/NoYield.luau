--!strict
--!optimize 2

--[=[
	NoYield: runs a transform that must not yield, as an UpdateAsync transform must not. A transform that
	yields is stopped where it yielded, and comes back as a Stopped value that prints as its trace;
	Yielded tells it from a throw by what it is, never by its text. Only two arguments reach the
	transform.

	Return type: The NoYield module.
	Example usage:
		local NoYield = require("./NoYield")
		local Ran, Result = NoYield.Try(Transform, Current, Info)
--]=]

type StoppedData = { Message: string }

local YIELDED_MESSAGE = "the transform must complete without yielding"

local FINISHED = newproxy(false)

local StoppedMeta = {
	__tostring = function(Raised: StoppedData): string
		return Raised.Message
	end,
}

type Stopped = setmetatable<StoppedData, typeof(StoppedMeta)>

local IdleThreads: { thread } = {}

local function RunTransform(Transform: (...any) -> ...any, First: any, Second: any): ...any
	return coroutine.yield(FINISHED, Transform(First, Second))
end

local function Worker(): ()
	local Transform, First, Second = coroutine.yield()
	while true do
		Transform, First, Second = RunTransform(Transform, First, Second)
	end
end

local function TakeThread(): thread
	local Count = #IdleThreads
	if Count == 0 then
		local Fresh = coroutine.create(Worker)
		coroutine.resume(Fresh)
		return Fresh
	end

	local Thread = IdleThreads[Count]
	IdleThreads[Count] = nil
	return Thread
end

local function IsStopped(Raised: unknown): boolean
	return type(Raised) == "table" and getmetatable(Raised :: any) == StoppedMeta
end

local function StopThread(Thread: thread): Stopped
	local Data: StoppedData = { Message = debug.traceback(Thread, YIELDED_MESSAGE) }
	coroutine.close(Thread)
	return setmetatable(Data, StoppedMeta)
end

local function Settle(Thread: thread, IsResumed: boolean, Signal: any, ...: any): (boolean, ...any)
	if not IsResumed then
		if IsStopped(Signal) then
			return false, Signal
		end

		return false, debug.traceback(Thread, tostring(Signal))
	end

	if Signal ~= FINISHED then
		return false, StopThread(Thread)
	end

	table.insert(IdleThreads, Thread)
	return true, ...
end

local NoYield = {}

function NoYield.Try(Transform: (...any) -> ...any, First: any?, Second: any?): (boolean, ...any)
	local Thread = TakeThread()
	return Settle(Thread, coroutine.resume(Thread, Transform, First, Second))
end

function NoYield.Yielded(Raised: unknown): boolean
	return IsStopped(Raised)
end

return NoYield
