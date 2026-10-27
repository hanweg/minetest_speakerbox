-- The order a playlist plays in.
--
-- No Luanti API here, so tests/test_tracks.lua can run it under a plain Lua
-- interpreter. The shuffle is seeded and deterministic for the same reason:
-- "it came out in a different order" is not a bug report anyone can act on.

local tracks = {}

-- Only Ogg files are playable, so the rest of a mixed folder is reported
-- rather than silently ignored -- that is what tools/playlist.sh is for.
-- Returns the playable list (sorted by name) and the count of the rest.
function tracks.select(files)
	local playable, others = {}, 0
	for _, name in ipairs(files) do
		if name:lower():match("%.ogg$") then
			playable[#playable + 1] = name
		elseif not name:match("^%.") and not name:lower():match("%.list$") then
			others = others + 1
		end
	end
	table.sort(playable)
	return playable, others
end

-- A small seeded generator, so a shuffle is reproducible and the global
-- math.random is left alone -- a mod has no business reseeding that.
local function lcg(seed)
	local state = math.floor(seed) % 2147483647
	if state <= 0 then
		state = state + 2147483646
	end
	return function()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

function tracks.order(list, shuffle, seed)
	local out = {}
	for i, name in ipairs(list) do
		out[i] = name
	end
	if not shuffle or #out < 3 then
		return out
	end
	local rand = lcg(seed or 1)
	for i = #out, 2, -1 do
		local j = math.floor(rand() * i) + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- The index after `index`, or nil at the end of a playlist that does not loop.
-- `index` 0 means "nothing has played yet".
function tracks.step(index, count, loop)
	if count <= 0 then
		return nil
	end
	if index < count then
		return index + 1
	end
	return loop and 1 or nil
end

return tracks
