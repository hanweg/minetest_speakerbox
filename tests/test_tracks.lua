-- The order a playlist plays in.
local h = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/helpers.lua")
local check = h.check
local T = require("tracks")

local MIXED = {
	"02-sleng-teng.ogg", "01-old-time-proverbs.ogg", "03-fat-thing.OGG",
	"cover.jpg", "notes.txt", "tracks.list", ".hidden", "original.mp3",
}

local playable, others = T.select(MIXED)
check("only ogg files are playable", #playable, 3)
check("sorted by name", playable[1], "01-old-time-proverbs.ogg")
check("an upper-case extension counts", playable[3], "03-fat-thing.OGG")
check("the rest are counted, not ignored", others, 3)
check("dotfiles are not counted", (function()
	local _, n = T.select({".DS_Store", "a.ogg"})
	return n
end)(), 0)

-- order ---------------------------------------------------------------------
local list = {"a.ogg", "b.ogg", "c.ogg", "d.ogg", "e.ogg"}
local plain = T.order(list, false)
check("unshuffled keeps the order", table.concat(plain, ","),
	"a.ogg,b.ogg,c.ogg,d.ogg,e.ogg")
check("ordering does not mutate the input", table.concat(list, ","),
	"a.ogg,b.ogg,c.ogg,d.ogg,e.ogg")

local s1 = table.concat(T.order(list, true, 12345), ",")
local s2 = table.concat(T.order(list, true, 12345), ",")
local s3 = table.concat(T.order(list, true, 999), ",")
check("the same seed shuffles the same way", s1, s2)
check("a different seed shuffles differently", s1 ~= s3, true)
check("every track survives a shuffle", #T.order(list, true, 7), 5)
check("a shuffle keeps the set", (function()
	local seen = {}
	for _, n in ipairs(T.order(list, true, 7)) do seen[n] = true end
	local n = 0
	for _ in pairs(seen) do n = n + 1 end
	return n
end)(), 5)

-- stepping ------------------------------------------------------------------
check("nothing played yet starts at one", T.step(0, 3, true), 1)
check("then two", T.step(1, 3, true), 2)
check("the end wraps when looping", T.step(3, 3, true), 1)
check("the end stops when not looping", T.step(3, 3, false), nil)
check("an empty playlist has no next track", T.step(0, 0, true), nil)
check("a one-track playlist repeats itself", T.step(1, 1, true), 1)

h.done("TRACKS")
