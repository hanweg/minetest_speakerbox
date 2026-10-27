-- Finding finished chunks on disk.
--
-- The hard part is not listing files, it is knowing which of them the encoder
-- has finished writing. Three answers, because producers differ:
--
--   manifest  ffmpeg's -segment_list: a text file it appends to as each
--             segment is closed, so anything named in it is complete. Lowest
--             latency, and the default.
--   lag       assume the highest-numbered file is the one being written now.
--             Works with any sequential writer, costs one chunk of latency.
--   all       the producer renames each file into place when it is done, so
--             everything visible is complete.
--
-- source.select() is pure and covered by tests/test_source.lua; the rest is
-- the filesystem half.

local source = {}

local CHUNK_PATTERN = "^(%d+)%.ogg$"
local MANIFEST = "chunks.list"
local HEADER_BYTES = 256
local TAIL_BYTES = 65536

-- Pure. `files` is a directory listing, `listed` a set of filenames the
-- manifest vouches for (or nil). Returns {{seq, name}, ...} ascending.
function source.select(files, listed, mode)
	local found = {}
	for _, name in ipairs(files) do
		local digits = name:match(CHUNK_PATTERN)
		if digits then
			found[#found + 1] = {seq = tonumber(digits), name = name}
		end
	end
	table.sort(found, function(a, b)
		return a.seq < b.seq
	end)

	if mode == "manifest" then
		local out = {}
		for _, chunk in ipairs(found) do
			if listed and listed[chunk.name] then
				out[#out + 1] = chunk
			end
		end
		return out
	end
	if mode == "lag" then
		table.remove(found)
		return found
	end
	return found
end

-- The set of filenames the manifest says are finished, or nil if there is no
-- manifest yet. Paths in the list are reduced to their basename, because
-- ffmpeg writes whatever it was given on the command line.
function source.manifest(dir)
	local f = io.open(dir .. "/" .. MANIFEST, "rb")
	if not f then
		return nil
	end
	local set = {}
	for line in f:lines() do
		local name = line:gsub("%s+$", ""):gsub("^.*/", "")
		if name ~= "" then
			set[name] = true
		end
	end
	f:close()
	return set
end

local function dir_list(path, want_dirs)
	local ok, list = pcall(core.get_dir_list, path, want_dirs)
	if not ok or type(list) ~= "table" then
		return nil
	end
	return list
end

-- Everything in a directory, or nil if there is no such directory -- which is
-- not the same answer as "no files" and is worth keeping distinct.
function source.list(dir)
	return dir_list(dir, false)
end

function source.scan(dir, mode)
	local files = dir_list(dir, false)
	if not files then
		return nil          -- no such directory: not the same as "no chunks"
	end
	local listed = nil
	if mode == "manifest" then
		listed = source.manifest(dir)
	end
	return source.select(files, listed, mode)
end

-- Stream ids are the subdirectory names under the chunk root.
function source.streams(root)
	return dir_list(root, true) or {}
end

-- First bytes of a chunk, for oggmeta.parse.
function source.header(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local blob = f:read(HEADER_BYTES)
	f:close()
	return blob
end

-- Last bytes of a file, for oggmeta.duration: the length of an Ogg stream is
-- the granule position of its final page, so a playlist has to read both ends.
function source.tail(path, bytes)
	bytes = bytes or TAIL_BYTES
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local size = f:seek("end")
	f:seek("set", math.max(0, size - bytes))
	local blob = f:read("*a")
	f:close()
	return blob
end

return source
