--!strict
--!optimize 2

--[=[
	Pages: a page walker that behaves like a real DataStorePages. It is built from its pages up front, and
	there is always at least one page. A page's cursor resumes after it; the last page has none. Advancing
	can cost a request, as a real listing's does.

	Return type: The Pages class.
	Example usage:
		local Pages = require("./Pages")
		local Listing = Pages.New({ { Row } }, {}, nil)
--]=]

type PagesData = {
	PageRows: { { any } },
	NextCursors: { string },
	SpendPage: (() -> ())?,
	Page: number,
	Cursor: string,
	IsFinished: boolean,
}

local Pages = {}
Pages.__index = Pages

export type Pages = setmetatable<PagesData, typeof(Pages)>

local function UpdatePosition(Listing: Pages): ()
	Listing.IsFinished = Listing.Page >= #Listing.PageRows
	if Listing.IsFinished then
		Listing.Cursor = ""
		return
	end

	Listing.Cursor = Listing.NextCursors[Listing.Page] or ""
end

function Pages.New(PageRows: { { any } }, NextCursors: { string }, SpendPage: (() -> ())?): Pages
	assert(#PageRows > 0, "the mock built a listing with no pages, and a real listing always has one")

	local Data: PagesData = {
		PageRows = PageRows,
		NextCursors = NextCursors,
		SpendPage = SpendPage,
		Page = 1,
		Cursor = "",
		IsFinished = true,
	}
	local Listing = setmetatable(Data, Pages)
	UpdatePosition(Listing)
	return Listing
end

function Pages.GetCurrentPage(self: Pages): { any }
	return table.clone(self.PageRows[self.Page])
end

function Pages.AdvanceToNextPageAsync(self: Pages): ()
	if self.IsFinished then
		error("Mock: there are no pages left to advance to", 0)
	end

	local SpendPage: (() -> ())? = self.SpendPage
	if SpendPage then
		SpendPage()
	end

	self.Page += 1
	UpdatePosition(self)
end

return Pages
