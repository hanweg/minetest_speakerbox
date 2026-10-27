-- speakerbox: speaker nodes that play a live audio stream, placed in the world.
--
-- No client mod, no client build, no second window: an encoder writes finished
-- Ogg Vorbis chunks into a directory, the mod pushes each one to the connected
-- clients with core.dynamic_add_media, and starts it on a shared clock so a
-- room of listeners hears the same beat at the same moment.
--
-- What it is good for: a PA, a radio, a DJ set, a listening room. What it is
-- not good for: playing an instrument together. End-to-end latency is a chunk
-- plus the delivery lead -- seconds, not milliseconds -- which rules out
-- ensemble playing however the rest is tuned. See README.md.
--
-- Modules are loaded with dofile and wired through one table rather than a
-- global, so that the two with no Luanti API in them -- schedule.lua and
-- oggmeta.lua -- can be run by tests/ under a plain Lua interpreter.

local modpath = core.get_modpath(core.get_current_modname())

local sb = {}

sb.version = "1.0.0"
sb.schedule = dofile(modpath .. "/schedule.lua")
sb.oggmeta = dofile(modpath .. "/oggmeta.lua")
sb.source = dofile(modpath .. "/source.lua")
sb.tracks = dofile(modpath .. "/tracks.lua")
sb.compat = dofile(modpath .. "/compat.lua")

local function log(level, fmt, ...)
	core.log(level, "[speakerbox] " .. string.format(fmt, ...))
end

-- ------------------------------------------------------------------- config --

local settings = core.settings

local function num(key, default, min, max)
	local v = tonumber(settings:get("speakerbox." .. key)) or default
	if min and v < min then v = min end
	if max and v > max then v = max end
	return v
end

local function str(key, default)
	local v = settings:get("speakerbox." .. key)
	if v == nil or v == "" then
		return default
	end
	return v
end

local function flag(key, default)
	return settings:get_bool("speakerbox." .. key, default)
end

local chunk_dir = str("chunk_dir", "speakerbox")
local chunk_root = chunk_dir
if chunk_dir:sub(1, 1) ~= "/" then
	chunk_root = core.get_worldpath() .. "/" .. chunk_dir
end

-- The playlist lives in the mod by default, because that is where you can
-- drop files without thinking about where the world directory is. An absolute
-- path is taken as given; anything else is relative to the world, like
-- chunk_dir.
local playlist_dir = str("playlist_dir", "")
local playlist_root
if playlist_dir == "" then
	playlist_root = modpath .. "/playlist"
elseif playlist_dir:sub(1, 1) == "/" then
	playlist_root = playlist_dir
else
	playlist_root = core.get_worldpath() .. "/" .. playlist_dir
end

local ready_mode = str("ready_mode", "manifest")
if ready_mode ~= "manifest" and ready_mode ~= "lag" and ready_mode ~= "all" then
	log("warning", "unknown ready_mode %q, using manifest", ready_mode)
	ready_mode = "manifest"
end

sb.cfg = {
	chunk_root = chunk_root,
	ready_mode = ready_mode,
	chunk_seconds = num("chunk_seconds", 6.0, 0.5, 60.0),
	lead_seconds = num("lead_seconds", 2.0, 0.0, 30.0),
	blend_seconds = num("blend_seconds", 0.08, 0.0, 1.0),
	live = flag("live", true),
	max_backlog = math.floor(num("max_backlog", 2, 1, 100)),
	-- set below, once chunk_seconds is known
	scan_interval = 0.25,

	playlist_root = playlist_root,
	playlist_shuffle = flag("playlist_shuffle", false),
	playlist_loop = flag("playlist_loop", true),
	playlist_rescan = num("playlist_rescan", 10.0, 1.0, 300.0),
	playlist_client_cache = flag("playlist_client_cache", true),
	track_crossfade = num("track_crossfade", 1.0, 0.0, 10.0),

	default_kind = str("default_kind", "stream") == "playlist"
		and "playlist" or "stream",
	default_stream = str("default_stream", "live"),
	default_mode = str("default_mode", "world") == "room" and "room" or "world",
	default_gain = num("default_gain", 1.0, 0.0, 4.0),
	default_radius = num("default_radius", 48.0, 1.0, 200.0),
	room_knee = num("room_knee", 0.6, 0.0, 0.99),
	max_radius = num("max_radius", 96.0, 1.0, 500.0),

	client_cache = flag("client_cache", false),
	warn_old_clients = flag("warn_old_clients", true),
	open_access = flag("open_access", false),
}

-- A scan interval that made sense for six-second chunks is a footgun at one
-- second: detection latency is part of the total, and there is no point
-- tuning chunk_seconds down while still looking for new chunks four times a
-- second. Scanning is a directory listing and a short file read, so paying
-- for a few more of them is the cheaper mistake.
local wanted_scan = num("scan_interval", 0.25, 0.05, 5.0)
local scan_cap = math.max(0.05, sb.cfg.chunk_seconds / 6)
sb.cfg.scan_interval = math.min(wanted_scan, scan_cap)

-- ------------------------------------------------------------------- state --

sb.storage = core.get_mod_storage()

local function read_map(key)
	local raw = sb.storage:get_string(key)
	if raw == "" then
		return {}
	end
	local t = core.parse_json(raw)
	return type(t) == "table" and t or {}
end

sb.state = {
	mutes = read_map("mutes"),
	volumes = read_map("volumes"),
}

-- ------------------------------------------------------------------ modules --

sb.speakers = dofile(modpath .. "/speaker.lua")(sb)
sb.pump = dofile(modpath .. "/pump.lua")(sb)
sb.commands = dofile(modpath .. "/commands.lua")(sb)

-- Other mods can read the register and the diagnostics; nothing here needs to
-- be written from outside, so nothing else is exposed.
speakerbox = {
	version = sb.version,
	cfg = sb.cfg,
	info = function() return sb.pump.info() end,
	speakers = function() return sb.speakers.list() end,
	-- the diagnostic behind /speaker test: push the newest finished chunk of a
	-- stream and report what the engine made of it
	push_newest = function(id) return sb.pump.push_newest(id) end,
}

-- ------------------------------------------------------------- startup gate --

local server = sb.compat.server()
local enabled = server.dynamic_media

if not enabled then
	-- The node is still registered, so nobody's world loses blocks on an old
	-- server; only the streaming is off.
	log("error", "this server is %s and core.dynamic_add_media's table form " ..
		"needs 5.5.0, so speakers will stay silent. Nodes still work.",
		server.version)
else
	core.mkdir(chunk_root)
	core.mkdir(chunk_root .. "/" .. sb.cfg.default_stream)
	-- Only create the playlist root if it is actually missing. The default is
	-- inside the mod, which is commonly read-only (a worldmods bind mount, a
	-- read-only install), and an attempt there logs a ScriptApiSecurity BLOCK
	-- line that reads far more alarmingly than it deserves. Nothing writes
	-- into the playlist directory at run time anyway.
	if not sb.source.list(playlist_root) then
		pcall(core.mkdir, playlist_root)
	end
	log("action", "ready: chunks from %s, %s mode, %.1fs chunks, %.1fs lead, " ..
		"%.2fs scan", chunk_root, ready_mode, sb.cfg.chunk_seconds,
		sb.cfg.lead_seconds, sb.cfg.scan_interval)
	if sb.cfg.scan_interval < wanted_scan then
		log("action", "scan interval cut from %.2fs to %.2fs to suit %.1fs " ..
			"chunks", wanted_scan, sb.cfg.scan_interval, sb.cfg.chunk_seconds)
	end
	log("action", "playlists from %s%s, crossfade %.2fs", playlist_root,
		sb.cfg.playlist_shuffle and ", shuffled" or "", sb.cfg.track_crossfade)
	if not server.start_time then
		log("warning", "this server predates 5.8.0, so sound start_time is " ..
			"unavailable: a late chunk cannot be seeked into and listeners " ..
			"will drift apart at every seam.")
	end
end

-- Nobody being able to touch a speaker is a confusing way to start, and it is
-- easy to walk into: the privilege is new, so it is in nobody's default_privs.
if not sb.cfg.open_access then
	local defaults = "," .. (settings:get("default_privs") or "") .. ","
	local has_admin = (settings:get("name") or "") ~= ""
	if not defaults:find(",speaker,", 1, true) and not has_admin then
		log("warning", "no player can configure a speaker here: add 'speaker' " ..
			"to default_privs, set a 'name' to have an admin, or set " ..
			"speakerbox.open_access = true for a private server.")
	end
end

-- --------------------------------------------------------------------- tick --

local since_tick = 0
local since_check = 0
local last_error = 0
local CHECK_INTERVAL = 10

core.register_globalstep(function(dtime)
	if not enabled then
		return
	end

	since_tick = since_tick + dtime
	if since_tick >= sb.cfg.scan_interval then
		since_tick = 0
		local ok, err = pcall(sb.pump.tick)
		if not ok then
			local now = sb.pump.clock()
			if now - last_error > 10 then
				last_error = now
				log("error", "tick failed: %s", tostring(err))
			end
		end
	end

	since_check = since_check + dtime
	if since_check >= CHECK_INTERVAL then
		since_check = 0
		sb.speakers.validate()
	end
end)

core.register_on_leaveplayer(function(player)
	sb.pump.forget_player(player:get_player_name())
end)
