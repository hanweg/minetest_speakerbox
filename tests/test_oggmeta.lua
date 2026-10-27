-- Reading an Ogg identification header.
local h = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/helpers.lua")
local check = h.check
local O = require("oggmeta")

local function le32(n)
	return string.char(n % 256, math.floor(n / 256) % 256,
		math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- 27-byte page header, one segment, then the first packet.
local function page(packet, segments)
	segments = segments or 1
	return "OggS" .. string.char(0, 2) .. string.rep("\0", 8)
		.. le32(1) .. le32(0) .. le32(0)
		.. string.char(segments) .. string.rep(string.char(255), segments)
		.. packet
end

local function vorbis(channels, rate)
	return page("\1vorbis" .. le32(0) .. string.char(channels) .. le32(rate)
		.. string.rep("\0", 32))
end

local function opus(channels, rate)
	return page("OpusHead" .. string.char(1, channels, 0, 0) .. le32(rate)
		.. string.rep("\0", 32))
end

local m = O.parse(vorbis(1, 22050))
check("vorbis is recognised", m and m.codec, "vorbis")
check("mono is read", m and m.channels, 1)
check("22050 Hz is read", m and m.rate, 22050)

m = O.parse(vorbis(2, 48000))
check("stereo is read", m and m.channels, 2)
check("48000 Hz is read", m and m.rate, 48000)

-- a longer segment table moves the packet, which is the easiest thing to get
-- wrong and the reason the offset is computed rather than assumed
m = O.parse(page("\1vorbis" .. le32(0) .. string.char(6) .. le32(44100)
	.. string.rep("\0", 32), 9))
check("segment table length is honoured", m and m.channels, 6)

m = O.parse(opus(2, 48000))
check("opus is recognised", m and m.codec, "opus")
check("opus channels are read", m and m.channels, 2)

local _, err = O.parse("not an ogg file at all, truly not one here")
check("a non-Ogg file is refused", err, "not an Ogg stream")

_, err = O.parse("OggS")
check("a short file is refused", err, "too short to be an Ogg stream")

_, err = O.parse(page("\1FLAC" .. string.rep("\0", 40)))
check("an unknown codec is refused", err, "unrecognised codec in Ogg stream")

_, err = O.parse(nil)
check("nil is refused", err, "too short to be an Ogg stream")

-- the duration parser, against files ffmpeg made and ffprobe measured -------
local function slurp(name)
	local f = assert(io.open(h.dir .. "/fixtures/" .. name, "rb"))
	local head = f:read(256)
	f:seek("end", -65536)
	local tail = f:read("*a")
	f:close()
	return head, tail
end

local head, tail = slurp("mono_2s.ogg")
local secs, info = O.duration(head, tail)
check("a real mono file's length", secs and math.floor(secs * 1000 + 0.5), 2000)
check("and its channel count", info and info.channels, 1)
check("and its rate", info and info.rate, 22050)

head, tail = slurp("stereo_1s5.ogg")
secs, info = O.duration(head, tail)
check("a real stereo file's length", secs and math.floor(secs * 1000 + 0.5), 1500)
check("and its channel count", info and info.channels, 2)
check("and its rate", info and info.rate, 44100)

check("the final page is found", O.last_granule(tail), 66150)
local _, derr = O.last_granule("no ogg pages in here at all")
check("a file with no pages is refused", derr,
	"no Ogg page found at the end of the file")

_, derr = O.duration(opus(2, 48000), opus(2, 48000))
check("opus has no playable duration",
	derr, "opus is not Ogg Vorbis, which is all Luanti decodes")

h.done("OGGMETA")
