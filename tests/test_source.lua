-- Which files on disk count as finished chunks.
local h = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/helpers.lua")
local check = h.check
local S = require("source")

local DIR = {
	"00000003.ogg", "00000001.ogg", "00000002.ogg",
	"chunks.list", "notes.txt", "00000004.part", "stray.ogg",
}

local all = S.select(DIR, nil, "all")
check("only numbered .ogg files count", #all, 3)
check("they come back ascending", all[1].seq, 1)
check("ascending to the end", all[3].seq, 3)
check("the name comes back too", all[2].name, "00000002.ogg")

local lag = S.select(DIR, nil, "lag")
check("lag drops the file being written", #lag, 2)
check("lag keeps the rest", lag[2].seq, 2)

local listed = {["00000001.ogg"] = true, ["00000002.ogg"] = true}
local manifest = S.select(DIR, listed, "manifest")
check("manifest takes only what it vouches for", #manifest, 2)
check("manifest keeps the order", manifest[1].seq, 1)

check("no manifest yet means no chunks", #S.select(DIR, nil, "manifest"), 0)
check("an empty directory is no chunks", #S.select({}, nil, "all"), 0)
check("lag on one file holds it back", #S.select({"00000001.ogg"}, nil, "lag"), 0)

h.done("SOURCE")
