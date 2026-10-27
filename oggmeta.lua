-- Reading the codec, channel count and sample rate out of the front of an Ogg
-- file. Pure string arithmetic, so tests/test_oggmeta.lua can run it without
-- Luanti.
--
-- Worth doing because two mistakes here are silent and expensive:
--
--  * Luanti decodes Ogg *Vorbis* only (src/client/sound/ogg_file.h includes
--    vorbisfile and nothing else). Hand it Opus in an Ogg container and every
--    chunk fails to load, with nothing on the server to say why.
--  * A positional sound with a stereo buffer is not panned by OpenAL, and the
--    client logs a warning naming the sound. Chunk names are unique, so that
--    warning is new every time: a stereo stream on a world-mode speaker fills
--    every listener's log at one line per chunk.

local oggmeta = {}

local function u8(s, i)
	return s:byte(i)
end

local function le32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	if not d then
		return nil
	end
	return a + b * 256 + c * 65536 + d * 16777216
end

-- `blob` is the first few hundred bytes of the file. Returns
-- {codec = "vorbis" | "opus", channels = n, rate = hz} or nil plus a reason.
function oggmeta.parse(blob)
	if type(blob) ~= "string" or #blob < 28 then
		return nil, "too short to be an Ogg stream"
	end
	if blob:sub(1, 4) ~= "OggS" then
		return nil, "not an Ogg stream"
	end

	-- Ogg page header is 27 bytes plus one byte per segment; the first packet
	-- starts after the segment table.
	local segments = u8(blob, 27)
	local p = 28 + segments
	if #blob < p + 15 then
		return nil, "truncated before the identification header"
	end

	if blob:sub(p, p + 6) == "\1vorbis" then
		return {
			codec = "vorbis",
			channels = u8(blob, p + 11),
			rate = le32(blob, p + 12),
		}
	end
	if blob:sub(p, p + 7) == "OpusHead" then
		return {
			codec = "opus",
			channels = u8(blob, p + 9),
			rate = le32(blob, p + 12),
		}
	end
	return nil, "unrecognised codec in Ogg stream"
end

local function le64(s, i)
	local b = {s:byte(i, i + 7)}
	if #b < 8 then
		return nil
	end
	local n = 0
	for k = 8, 1, -1 do
		n = n * 256 + b[k]
	end
	-- a page that ends no packet carries -1 here, and Lua's doubles stop being
	-- exact above 2^53 anyway, so anything that big is not a sample count
	if n > 9007199254740992 then
		return nil
	end
	return n
end

-- The granule position of the last page in `tail`, which for Vorbis is the
-- total number of samples. "OggS" can occur inside packet data by chance, so
-- candidates are checked for a zero version byte, and the end-of-stream page is
-- preferred over merely the last plausible one.
function oggmeta.last_granule(tail)
	if type(tail) ~= "string" then
		return nil, "no data"
	end
	local best, eos = nil, nil
	local at = 1
	while true do
		local p = tail:find("OggS", at, true)
		if not p then
			break
		end
		at = p + 1
		if tail:byte(p + 4) == 0 then                 -- version
			local granule = le64(tail, p + 6)
			if granule then
				best = granule
				local flags = tail:byte(p + 5) or 0
				if flags >= 4 and math.floor(flags / 4) % 2 == 1 then
					eos = granule                      -- end-of-stream page
				end
			end
		end
	end
	local granule = eos or best
	if not granule then
		return nil, "no Ogg page found at the end of the file"
	end
	return granule
end

-- Length in seconds, from the head of the file (for the sample rate) and the
-- tail (for the sample count). A playlist needs this because there is no
-- "sound finished" callback to wait for: the next track is scheduled from the
-- current one's length.
function oggmeta.duration(head, tail)
	local info, err = oggmeta.parse(head)
	if not info then
		return nil, err
	end
	if info.codec ~= "vorbis" then
		return nil, ("%s is not Ogg Vorbis, which is all Luanti decodes")
			:format(info.codec)
	end
	if not info.rate or info.rate <= 0 then
		return nil, "no sample rate in the identification header"
	end
	local granule, gerr = oggmeta.last_granule(tail)
	if not granule then
		return nil, gerr
	end
	return granule / info.rate, info
end

return oggmeta
