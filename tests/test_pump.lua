-- The push-and-play state machine, against a stub engine.
--
-- Everything this covers is invisible until someone is standing in the world
-- with a working stream, which is a slow and unreliable way to find out that a
-- chunk was started twice or that a mute was ignored. The stubs record what
-- would have been sent instead.
local h = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/helpers.lua")
local check = h.check

local schedule = require("schedule")
local oggmeta = require("oggmeta")
local tracks = require("tracks")

-- The playlist tests use a real file, so the duration really is parsed.
local function fixture(name)
	local f = assert(io.open(h.dir .. "/fixtures/" .. name, "rb"))
	local head = f:read(256)
	f:seek("end", -65536)
	local tail = f:read("*a")
	f:close()
	return head, tail
end
local FIX_HEAD, FIX_TAIL = fixture("mono_2s.ogg")   -- 2.000 s, mono, 22050

-- ------------------------------------------------------------- stub engine --

local NOW = 1000
local sent = {}          -- dynamic_add_media calls
local played = {}        -- sound_play calls
local faded = {}         -- sound_fade calls
local stopped = {}       -- sound_stop calls
local chat = {}
local next_handle = 0

local function reset()
	sent, played, faded, stopped, chat = {}, {}, {}, {}, {}
end

core = {
	log = function() end,
	get_us_time = function() return NOW * 1000000 end,
	chat_send_player = function(name, msg) chat[#chat + 1] = {name, msg} end,
	dynamic_add_media = function(opts, cb)
		sent[#sent + 1] = {opts = opts, cb = cb}
		return true
	end,
	sound_play = function(spec, params)
		next_handle = next_handle + 1
		played[#played + 1] = {name = spec.name, params = params, handle = next_handle}
		return next_handle
	end,
	sound_fade = function(handle, step, gain)
		faded[#faded + 1] = {handle = handle, step = step, gain = gain}
	end,
	sound_stop = function(handle) stopped[#stopped + 1] = handle end,
	get_connected_players = function() return core._players end,
	_players = {},
}

vector = {
	distance = function(a, b)
		local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end,
}

local function player(name, pos)
	return {
		get_player_name = function() return name end,
		get_pos = function() return pos end,
	}
end

-- ---------------------------------------------------------------- stub mod --

local CFG = {
	chunk_root = "/chunks",
	ready_mode = "manifest",
	chunk_seconds = 6.0,
	lead_seconds = 2.0,
	blend_seconds = 0.08,
	live = true,
	max_backlog = 2,
	room_knee = 0.6,
	client_cache = false,
	warn_old_clients = true,

	playlist_root = "/music",
	playlist_rescan = 10,
	playlist_shuffle = false,
	playlist_loop = true,
	track_crossfade = 0.5,
	playlist_client_cache = true,
}

local function build(over)
	reset()
	local cfg = {}
	for k, v in pairs(CFG) do cfg[k] = v end
	for k, v in pairs(over and over.cfg or {}) do cfg[k] = v end

	local sb = {
		schedule = schedule,
		oggmeta = oggmeta,
		tracks = tracks,
		cfg = cfg,
		state = {mutes = (over and over.mutes) or {}, volumes = (over and over.volumes) or {}},
		-- a fake chunk directory: whatever the test says is finished
		source = {
			scan = function() return over and over.avail or {} end,
			header = function(path)
				if path and path:match("broken") then
					return "this is not an Ogg file"
				end
				return (over and over.files) and FIX_HEAD or nil
			end,
			tail = function(path)
				if path and path:match("broken") then
					return "nor is this"
				end
				return FIX_TAIL
			end,
			list = function() return over and over.files or nil end,
		},
		compat = {
			player = function(name)
				local proto = (over and over.protos and over.protos[name]) or 53
				return {proto = proto, version = "stub", media = proto >= 39,
					start_time = proto >= 43}
			end,
		},
		speakers = {
			list = function() return (over and over.speakers) or {} end,
		},
	}
	return dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../pump.lua")(sb), sb
end

local WORLD = {key = "(0,0,0)", pos = {x = 0, y = 0, z = 0}, stream = "live",
	gain = 1.0, radius = 48, mode = "world"}
local ROOM = {key = "(0,0,0)", pos = {x = 0, y = 0, z = 0}, stream = "live",
	gain = 1.0, radius = 48, mode = "room"}

local function deliver(i, name)
	sent[i].cb(name)
end

-- pushing ------------------------------------------------------------------
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
local pump = build({avail = {{seq = 7, name = "00000007.ogg"}}, speakers = {WORLD}})
pump.tick()
check("a finished chunk is pushed", #sent, 1)
check("pushed as ephemeral", sent[1].opts.ephemeral, true)
check("pushed without the client cache", sent[1].opts.client_cache, false)
check("pushed from the stream directory",
	sent[1].opts.filepath, "/chunks/live/00000007.ogg")
check("media name carries the extension",
	sent[1].opts.filename:match("%.ogg$") ~= nil, true)
check("nothing plays before the clock says so", #played, 0)

-- playing ------------------------------------------------------------------
deliver(1, "ann")
NOW = 1002                   -- due at 1002 - blend
pump.tick()
check("a delivered chunk plays when due", #played, 1)
check("played to that player alone", played[1].params.to_player, "ann")
check("played without the .ogg", played[1].name:match("%.ogg$") == nil, true)
check("world mode is positional", played[1].params.pos.x, 0)
check("world mode carries the radius", played[1].params.max_hear_distance, 48)
check("started at the blend offset", played[1].params.start_time, 0.08)
check("faded in over the blend", played[1].params.fade, 1.0 / 0.08)

pump.tick()
check("the same chunk is not started twice", #played, 1)

-- a late copy is seeked into, not played from the top ----------------------
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({avail = {{seq = 7, name = "00000007.ogg"}}, speakers = {WORLD}})
pump.tick()
NOW = 1004.5                 -- 2.58s after its slot opened
deliver(1, "ann")
pump.tick()
check("a late start seeks in by the lateness",
	played[1].params.start_time, 2.58)

-- the handover -------------------------------------------------------------
-- The availability table is shared with the stub, so appending to it is the
-- encoder finishing another chunk.
local avail = {{seq = 7, name = "00000007.ogg"}}
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({avail = avail, speakers = {WORLD}})
pump.tick()
deliver(1, "ann")
NOW = 1002
pump.tick()
local first = played[1].handle
avail[2] = {seq = 8, name = "00000008.ogg"}
pump.tick()
check("the next chunk is pushed too", #sent, 2)
deliver(2, "ann")
NOW = 1008
pump.tick()
check("the next chunk starts", #played, 2)
check("the outgoing chunk is faded out", #faded, 1)
check("faded out by handle", faded[1].handle, first)
check("faded all the way to zero", faded[1].gain, 0)
check("faded over the blend", faded[1].step, 1.0 / 0.08)

-- a restarted encoder ------------------------------------------------------
avail = {{seq = 41, name = "00000041.ogg"}}
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({avail = avail, speakers = {WORLD}})
pump.tick()
check("a chunk well into a run is pushed", #sent, 1)
-- ffmpeg restarts: its numbering begins at zero again
avail[1] = {seq = 0, name = "00000000.ogg"}
pump.tick()
check("numbering going backwards is followed", #sent, 2)
check("from the new first chunk",
	sent[2].opts.filepath, "/chunks/live/00000000.ogg")
-- and it does not then replay the chunk it just took
pump.tick()
check("the restarted chunk is pushed once", #sent, 2)

-- gating -------------------------------------------------------------------
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({avail = {{seq = 1, name = "00000001.ogg"}}, speakers = {WORLD},
	mutes = {ann = true}})
pump.tick()
check("a muted player is not pushed to at all", #sent, 0)

NOW = 1000
pump = build({avail = {{seq = 1, name = "00000001.ogg"}}, speakers = {WORLD},
	protos = {ann = 38}})
pump.tick()
check("a pre-5.3 client is not pushed to", #sent, 0)
check("and is told why, once", #chat, 1)
pump.tick()
check("told only once", #chat, 1)

NOW = 1000
core._players = {player("far", {x = 200, y = 0, z = 0})}
pump = build({avail = {{seq = 1, name = "00000001.ogg"}}, speakers = {WORLD}})
pump.tick()
deliver(1, "far")
NOW = 1002
pump.tick()
check("a listener out of radius hears nothing", #played, 0)

-- room mode ---------------------------------------------------------------
NOW = 1000
core._players = {player("ann", {x = 10, y = 0, z = 0})}
pump = build({avail = {{seq = 1, name = "00000001.ogg"}}, speakers = {ROOM}})
pump.tick()
deliver(1, "ann")
NOW = 1002
pump.tick()
check("room mode plays", #played, 1)
check("room mode is locationless", played[1].params.pos, nil)
check("room mode is flat near the speaker", played[1].params.gain, 1.0)

core._players = {player("ann", {x = 40, y = 0, z = 0})}
pump.tick()
check("walking down the skirt refades the live sound", #faded, 1)
check("to the curve's value",
	faded[1].gain, schedule.room_gain(40, 48, 0.6))

core._players = {player("ann", {x = 60, y = 0, z = 0})}
pump.tick()
check("walking out of the room fades it away", faded[2].gain, 0)

-- a listener's own volume -------------------------------------------------
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({avail = {{seq = 1, name = "00000001.ogg"}}, speakers = {WORLD},
	volumes = {ann = 0.25}})
pump.tick()
deliver(1, "ann")
NOW = 1002
pump.tick()
check("a player's own volume scales the gain", played[1].params.gain, 0.25)

-- playlists -----------------------------------------------------------------
local PL = {key = "(0,0,0)", pos = {x = 0, y = 0, z = 0}, kind = "playlist",
	stream = "", gain = 1.0, radius = 48, mode = "world"}

NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({files = {"a.ogg", "b.ogg", "sleeve.jpg"}, speakers = {PL}})
pump.tick()
check("a playlist pushes its first track", #sent, 1)
check("from the playlist root", sent[1].opts.filepath, "/music/a.ogg")
check("a track may be cached: it comes round again",
	sent[1].opts.client_cache, true)
check("nothing plays until it has arrived", #played, 0)

deliver(1, "ann")
pump.tick()
check("it plays as soon as it has", #played, 1)
check("from the start", played[1].params.start_time, 0)
check("faded in over the crossfade", played[1].params.fade, 1.0 / 0.5)
local track1 = played[1].handle

pump.tick()
check("the next track is fetched a whole track ahead", #sent, 2)
check("and it is the next one in order", sent[2].opts.filepath, "/music/b.ogg")

-- a listener who turns up mid-track joins it where it is
core._players = {player("ann", {x = 1, y = 0, z = 0}),
	player("bob", {x = 2, y = 0, z = 0})}
NOW = 1001
deliver(1, "bob")
pump.tick()
check("a mid-track arrival joins where it is", #played, 2)
check("seeked to the playing position", played[2].params.start_time, 1.0)
check("and it was bob", played[2].params.to_player, "bob")

-- the handover happens one crossfade before the end, not after it
NOW = 1001.4                 -- the 2 s track ends at 1002, crossfade 0.5
deliver(2, "ann")
pump.tick()
check("the next track waits for its moment", #played, 2)
NOW = 1001.6
pump.tick()
check("then it takes over", #played, 3)
check("the outgoing track is faded out", faded[1].handle, track1)
check("over the crossfade", faded[1].step, 1.0 / 0.5)

-- /speaker next
NOW = 1002
pump.tick()                  -- fetches the track after that
check("a third track is queued", #sent, 3)
check("the playlist wrapped round", sent[3].opts.filepath, "/music/a.ogg")
local ok, what = pump.next_track("playlist:")
check("next is refused until the queued track has arrived", ok, false)
deliver(3, "ann")
ok, what = pump.next_track("playlist:")
check("next hands over early once it has", ok, true)
check("and says what is playing", what, "a.ogg")

-- an unreadable file is stepped over rather than blocking the playlist
NOW = 1000
core._players = {player("ann", {x = 1, y = 0, z = 0})}
pump = build({files = {"1-broken.ogg", "2-good.ogg"}, speakers = {PL}})
pump.tick()
check("an unreadable track is not pushed", #sent, 0)
pump.tick()
check("the playlist steps past it", #sent, 1)
check("on to the next file", sent[1].opts.filepath, "/music/2-good.ogg")

-- a directory with nothing playable in it
NOW = 1000
pump = build({files = {"track.mp3", "cover.png"}, speakers = {PL}})
pump.tick()
check("a folder of mp3s pushes nothing", #sent, 0)

h.done("PUMP")
