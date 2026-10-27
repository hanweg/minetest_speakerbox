-- Pushing chunks to clients and starting them on a shared clock.
--
-- Delivery and playback are deliberately separate. A chunk is pushed the
-- moment the encoder has finished writing it, so the bytes are already on the
-- client when its slot comes round; it is started per player when the clock
-- says so, with `start_time` set to however late that player's copy arrived.
-- That is what keeps a room of clients on one beat instead of each hearing its
-- own ping. The same per-player loop covers three cases with no special
-- casing: an on-time start, a late delivery, and a player who walks into
-- range halfway through a chunk.
--
-- There are two kinds of source and they share everything below the point
-- where a sound is started:
--
--   stream    a directory of numbered chunks an encoder is still writing.
--             Live, seamed every chunk_seconds, never repeats.
--   playlist  a directory of whole Ogg Vorbis tracks. One sound per track, so
--             no seams at all inside one; the next track is pushed a whole
--             track ahead and crossfaded in over track_crossfade.
--
-- A playlist does not use the chunk clock. It cannot: track lengths are not
-- uniform and there is no "sound finished" callback, so the schedule comes
-- from each file's own length, read out of its last Ogg page.

return function(sb)

local schedule, source, oggmeta, compat, tracks =
	sb.schedule, sb.source, sb.oggmeta, sb.compat, sb.tracks

local pump = {}

local streams = {}         -- id -> stream state
local caps = {}            -- player name -> compat.player(), cached
local warned_old = {}      -- player name -> told once that it is too old
local push_counter = 0     -- media names come from here, never from the file
                           -- name, so a producer that reuses names is harmless

pump.streams = streams
-- speaker.lua's panel and the commands both need these, and they must agree
-- with the grouping in pump.tick
function pump.key_for(spk)
	local kind = spk.kind or "stream"
	if kind == "playlist" then
		return "playlist:" .. (spk.stream or "")
	end
	return spk.stream or ""
end
pump.stopped = {}          -- id -> true, set by /speaker stop

local function log(level, fmt, ...)
	core.log(level, "[speakerbox] " .. string.format(fmt, ...))
end

function pump.clock()
	return core.get_us_time() / 1000000
end

local function tag_for(id)
	return (id:lower():gsub("[^%a%d_]", "_")):sub(1, 16)
end

-- Where a speaker's source lives. A playlist with no name is the playlist
-- root itself, so dropping files in one directory is the whole setup.
local function dir_for(kind, name)
	if kind == "playlist" then
		if name == nil or name == "" then
			return sb.cfg.playlist_root
		end
		return sb.cfg.playlist_root .. "/" .. name
	end
	return sb.cfg.chunk_root .. "/" .. name
end

pump.dir_for = dir_for

local function new_stream(key, kind, name)
	return {
		key = key,
		kind = kind,
		name = name,
		tag = tag_for(key),
		dir = dir_for(kind, name),
		handles = {},      -- player name -> speaker key -> live sound
		warned_dir = false,
		warned_stereo = false,
		stats = {pushed = 0, played = 0, late = 0, missed = 0, skipped_tracks = 0,
			deliveries = 0, delivery_total = 0, delivery_worst = 0},

		-- stream kind
		sched = schedule.new(sb.cfg),
		pending = {},      -- seq -> chunk
		last_seq = -1,     -- everything up to here has been dealt with
		meta = nil,        -- codec/channels/rate of the first chunk we saw

		-- playlist kind
		order = nil,       -- the track names, in playing order
		index = 0,         -- which of them is current; 0 is "nothing yet"
		signature = nil,   -- the file set the order was built from
		seed = math.floor(core.get_us_time() % 1000000),
		scanned_at = -1e9,
		ready = nil,       -- pushed, waiting for its turn
		current = nil,     -- sounding now
	}
end

-- ---------------------------------------------------------------- listeners --

local function note_old_client(name, cap)
	if warned_old[name] or not sb.cfg.warn_old_clients then
		return
	end
	warned_old[name] = true
	core.chat_send_player(name, ("*** Your client (%s, protocol %d) is older " ..
		"than 5.3.0 and cannot receive streamed audio, so speakers will be " ..
		"silent for you."):format(cap.version, cap.proto))
	log("action", "%s on protocol %d cannot receive dynamic media", name, cap.proto)
end

-- Players who can hear anything at all, with their positions sampled once.
local function listeners()
	local out = {}
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local cap = caps[name]
		if not cap then
			cap = compat.player(name)     -- nil for a tick or two after joining
			caps[name] = cap
		end
		if cap then
			if not cap.media then
				note_old_client(name, cap)
			elseif not sb.state.mutes[name] then
				out[#out + 1] = {
					name = name,
					pos = player:get_pos(),
					volume = sb.state.volumes[name] or 1.0,
				}
			end
		end
	end
	return out
end

-- ------------------------------------------------------------------ pushing --

-- Chunks are Vorbis or they do not play, and they are mono or they are not
-- panned. Both failures are quiet, so the first chunk of every stream gets its
-- header read and the answer logged once.
local function check_header(st, filename, speakers)
	if st.meta then
		return
	end
	local blob = source.header(st.dir .. "/" .. filename)
	if not blob then
		return
	end
	local meta, err = oggmeta.parse(blob)
	if not meta then
		log("warning", "stream %q: %s (%s)", st.name, err, filename)
		st.meta = {codec = "?", channels = 0, rate = 0}
		return
	end
	st.meta = meta
	log("action", "stream %q: %s, %d channel(s), %d Hz",
		st.name, meta.codec, meta.channels, meta.rate)
	if meta.codec ~= "vorbis" then
		log("error", "stream %q: Luanti decodes Ogg Vorbis only, so %s chunks " ..
			"will not play. Re-encode with -c:a libvorbis.", st.name, meta.codec)
	end
	if meta.channels > 1 then
		for _, spk in ipairs(speakers) do
			if spk.mode == "world" and not st.warned_stereo then
				st.warned_stereo = true
				log("warning", "stream %q is stereo and speaker %s is in world " ..
					"mode: OpenAL will not pan a stereo buffer, and every client " ..
					"logs a warning per chunk. Encode mono (-ac 1) for world " ..
					"mode, or set the speaker to room mode.", st.name, spk.key)
			end
		end
	end
end

local function push(st, seq, filename, now)
	push_counter = push_counter + 1
	local media = string.format("spkb_%s_%08d", st.tag, push_counter)
	local chunk = {
		seq = seq,
		media = media,                                  -- no extension: the
		                                                -- engine groups a sound
		                                                -- under the name minus
		                                                -- ".ogg"
		due = schedule.due_at(st.sched, seq),
		expires = schedule.expires_at(st.sched, seq),
		pushed_at = now,
		delivered = {},
		started = {},
	}

	local accepted = core.dynamic_add_media({
		filepath = st.dir .. "/" .. filename,
		filename = media .. ".ogg",
		ephemeral = true,
		client_cache = sb.cfg.client_cache,
	}, function(name)
		local live = st.pending[seq]
		if not live or live.media ~= media then
			return                      -- reaped before this client caught up
		end
		live.delivered[name] = true
		local took = pump.clock() - live.pushed_at
		local s = st.stats
		s.deliveries = s.deliveries + 1
		s.delivery_total = s.delivery_total + took
		if took > s.delivery_worst then
			s.delivery_worst = took
		end
	end)

	if not accepted then
		log("error", "stream %q: dynamic_add_media refused %s", st.name, filename)
		return
	end
	st.pending[seq] = chunk
	st.stats.pushed = st.stats.pushed + 1
end

local function discover(st, now, speakers, have_listeners)
	local avail = source.scan(st.dir, sb.cfg.ready_mode)
	if not avail then
		if not st.warned_dir then
			st.warned_dir = true
			log("warning", "stream %q: nothing at %s", st.name, st.dir)
		end
		return
	end
	st.warned_dir = false

	-- ffmpeg numbers segments from zero on every run, so a restarted encoder
	-- looks like a stream that has gone backwards. Without this the mod sits
	-- silent until the new numbering passes the old high-water mark, which on
	-- a long first run is a very long time.
	local newest = avail[#avail]
	if newest and newest.seq < st.last_seq then
		log("action", "stream %q: numbering restarted at %d, following it",
			st.name, newest.seq)
		st.last_seq = -1
		st.sched.base = nil
	end

	local fresh, names = {}, {}
	for _, chunk in ipairs(avail) do
		if chunk.seq > st.last_seq then
			fresh[#fresh + 1] = chunk.seq
			names[chunk.seq] = chunk.name
		end
	end
	if #fresh == 0 then
		return
	end

	-- With nobody to hear it there is no point pushing: swallow what the
	-- encoder has made and let the clock go cold, so the next listener starts
	-- from what is live rather than from a backlog.
	if not have_listeners then
		st.last_seq = fresh[#fresh]
		st.sched.base = nil
		return
	end

	local before_skipped = st.sched.skipped
	for _, step in ipairs(schedule.plan(st.sched, fresh, now)) do
		if step.seq > st.last_seq then
			st.last_seq = step.seq
		end
		if step.action == "push" then
			if step.sync == "resync" then
				log("action", "stream %q: behind its own clock, re-anchoring on " ..
					"chunk %d", st.name, step.seq)
			end
			check_header(st, names[step.seq], speakers)
			push(st, step.seq, names[step.seq], now)
		end
	end
	if st.sched.skipped > before_skipped then
		log("action", "stream %q: skipped %d chunk(s) to stay near live",
			st.name, st.sched.skipped - before_skipped)
	end
end

-- ------------------------------------------------------------------ playing --

local function forget_started(st, name, key)
	for _, chunk in pairs(st.pending) do
		local started = chunk.started[name]
		if started then
			started[key] = nil
		end
	end
end

local function hand_over(st, name, key, handle, gain, spk, fade)
	local held = st.handles[name]
	if not held then
		held = {}
		st.handles[name] = held
	end
	local prev = held[key]
	if prev then
		if fade > 0 then
			-- fading to zero deletes the sound, which is exactly the handover:
			-- the outgoing tail crosses the incoming head
			core.sound_fade(prev.handle, prev.gain / fade, 0)
		else
			core.sound_stop(prev.handle)
		end
	end
	held[key] = {handle = handle, gain = gain, spk = spk}
end

-- `sounding` is a chunk or a track: both carry a media name, the wall time
-- they were due to start, and a per-player record of who has been started.
-- `start_time` comes from that due time, so a copy that arrived late is seeked
-- into rather than played from its beginning.
local function start_one(st, sounding, listener, spk, now, fade)
	local started = sounding.started[listener.name]
	if started and started[spk.key] then
		return
	end

	local dist = vector.distance(listener.pos, spk.pos)
	local gain = spk.gain * listener.volume
	local params = {
		to_player = listener.name,
		start_time = math.max(0, now - sounding.due),
	}

	if spk.mode == "room" then
		gain = gain * schedule.room_gain(dist, spk.radius, sb.cfg.room_knee)
		if gain <= 0 then
			return               -- outside the room; try again when they move
		end
	else
		if dist > spk.radius then
			return               -- the server would drop the packet anyway
		end
		params.pos = spk.pos
		params.max_hear_distance = spk.radius
	end

	params.gain = gain
	if fade > 0 then
		-- `fade` makes the client start at silence and ramp, in the same packet
		params.fade = gain / fade
	end

	local handle = core.sound_play({name = sounding.media}, params)
	if not handle or handle <= 0 then
		return                   -- -1: the server found nobody to send it to
	end

	hand_over(st, listener.name, spk.key, handle, gain, spk, fade)
	started = started or {}
	started[spk.key] = true
	sounding.started[listener.name] = started

	st.stats.played = st.stats.played + 1
	if params.start_time > 0.05 then
		st.stats.late = st.stats.late + 1
	end
end

local function play(st, now, who, speakers)
	for _, chunk in pairs(st.pending) do
		if now >= chunk.due and now < chunk.expires then
			for _, listener in ipairs(who) do
				if chunk.delivered[listener.name] then
					for _, spk in ipairs(speakers) do
						start_one(st, chunk, listener, spk, now, sb.cfg.blend_seconds)
					end
				end
			end
		end
	end
end

-- Room mode owns its own falloff, so it has to keep up with walking. One fade
-- packet per meaningful change, not per tick.
local GAIN_EPSILON = 0.03
local GAIN_RAMP = 0.3

local function follow(st, who)
	for _, listener in ipairs(who) do
		local held = st.handles[listener.name]
		if held then
			for key, live in pairs(held) do
				local spk = live.spk
				if spk.mode == "room" then
					local want = spk.gain * listener.volume * schedule.room_gain(
						vector.distance(listener.pos, spk.pos), spk.radius,
						sb.cfg.room_knee)
					if math.abs(want - live.gain) > GAIN_EPSILON then
						if want <= 0 then
							core.sound_fade(live.handle, live.gain / GAIN_RAMP, 0)
							held[key] = nil
							forget_started(st, listener.name, key)
						else
							core.sound_fade(live.handle,
								math.abs(want - live.gain) / GAIN_RAMP, want)
							live.gain = want
						end
					end
				end
			end
		end
	end
end

local function reap(st, now)
	for seq, chunk in pairs(st.pending) do
		if now >= chunk.expires then
			if not next(chunk.started) then
				st.stats.missed = st.stats.missed + 1
			end
			st.pending[seq] = nil
		end
	end
end

local function silence(st)
	for name, held in pairs(st.handles) do
		for key, live in pairs(held) do
			core.sound_stop(live.handle)
			held[key] = nil
		end
		st.handles[name] = nil
	end
end

-- ----------------------------------------------------------------- playlist --

local function rescan(st, now)
	if now - st.scanned_at < sb.cfg.playlist_rescan then
		return
	end
	st.scanned_at = now

	local files = source.list(st.dir)
	if not files then
		if not st.warned_dir then
			st.warned_dir = true
			log("warning", "playlist %q: nothing at %s", st.name, st.dir)
		end
		return
	end
	st.warned_dir = false

	local playable, others = tracks.select(files)
	local signature = table.concat(playable, "\n")
	if signature == st.signature then
		return
	end
	st.signature = signature
	st.order = tracks.order(playable, sb.cfg.playlist_shuffle, st.seed)
	st.index = math.min(st.index, #st.order)
	log("action", "playlist %q: %d track(s)%s in %s", st.name, #st.order,
		sb.cfg.playlist_shuffle and ", shuffled" or "", st.dir)
	if others > 0 then
		log("action", "playlist %q: %d other file(s) here are not Ogg and are " ..
			"ignored -- tools/playlist.sh converts them if they are music",
			st.name, others)
	end
end

local function push_track(st, now)
	local index = tracks.step(st.index, #st.order, sb.cfg.playlist_loop)
	if not index then
		return                   -- the end of a playlist that does not loop
	end
	local file = st.order[index]
	local path = st.dir .. "/" .. file

	-- The length has to come out of the file itself: there is no callback for
	-- a sound ending, so the next track is scheduled from this one's duration.
	local secs, info = oggmeta.duration(source.header(path) or "",
		source.tail(path) or "")
	if not secs then
		log("error", "playlist %q: skipping %s -- %s", st.name, file, tostring(info))
		st.index = index         -- never get stuck on one unreadable file
		st.stats.skipped_tracks = st.stats.skipped_tracks + 1
		return
	end
	if info.channels > 1 and not st.warned_stereo then
		st.warned_stereo = true
		log("warning", "playlist %q: %s is stereo, so a world-mode speaker " ..
			"will not pan it and every client logs a warning per track. " ..
			"tools/playlist.sh converts to mono by default; room mode is the " ..
			"other answer.", st.name, file)
	end

	push_counter = push_counter + 1
	local media = string.format("spkb_%s_%08d", st.tag, push_counter)
	local track = {
		media = media,
		file = file,
		index = index,
		duration = secs,
		channels = info.channels,
		rate = info.rate,
		pushed_at = now,
		delivered = {},
		started = {},
	}

	local accepted = core.dynamic_add_media({
		filepath = path,
		filename = media .. ".ogg",
		ephemeral = true,
		-- A track comes round again, unlike a chunk, and the client's media
		-- cache is keyed by content hash -- so letting it keep the bytes makes
		-- the second time round free even though the name is new.
		client_cache = sb.cfg.playlist_client_cache,
	}, function(name)
		if st.ready ~= track and st.current ~= track then
			return
		end
		track.delivered[name] = true
		local took = pump.clock() - track.pushed_at
		local s = st.stats
		s.deliveries = s.deliveries + 1
		s.delivery_total = s.delivery_total + took
		if took > s.delivery_worst then
			s.delivery_worst = took
		end
	end)
	if not accepted then
		log("error", "playlist %q: the engine refused %s", st.name, file)
		st.index = index
		return
	end
	st.ready = track
	st.stats.pushed = st.stats.pushed + 1
end

local function promote(st, now)
	local track = st.ready
	st.ready = nil
	track.due = now
	track.ends_at = now + track.duration
	st.current = track
	st.index = track.index
	log("action", "playlist %q: now playing %s (%d:%02d)", st.name, track.file,
		math.floor(track.duration / 60), math.floor(track.duration % 60))
end

local function tick_playlist(st, now, speakers, who)
	rescan(st, now)
	if not st.order or #st.order == 0 then
		return
	end

	if st.current and now >= st.current.ends_at then
		st.current = nil
	end

	-- A track is fetched a whole track ahead, which is the delivery budget for
	-- a file that may be megabytes. Only the first one ever waits.
	if not st.ready and #who > 0 then
		push_track(st, now)
	end

	local crossfade = sb.cfg.track_crossfade
	if st.ready and next(st.ready.delivered) then
		if not st.current or now >= st.current.ends_at - crossfade then
			promote(st, now)
		end
	end

	-- Starting a track with less than half a second left is not worth a packet.
	if st.current and now < st.current.ends_at - 0.5 then
		for _, listener in ipairs(who) do
			if st.current.delivered[listener.name] then
				for _, spk in ipairs(speakers) do
					start_one(st, st.current, listener, spk, now, crossfade)
				end
			end
		end
	end
	follow(st, who)
end

-- /speaker next: hand over to the queued track now instead of at the end of
-- this one.
function pump.next_track(key)
	local st = streams[key]
	if not st then
		return false, "no such playlist is running"
	end
	if st.kind ~= "playlist" then
		return false, ("%q is a chunk stream, not a playlist"):format(st.name)
	end
	if not st.ready then
		return false, "the next track has not been fetched yet -- try again in a moment"
	end
	if not next(st.ready.delivered) then
		return false, ("%q is still being delivered"):format(st.ready.file)
	end
	promote(st, pump.clock())
	return true, st.current.file
end

-- The keys of the playlists currently running, so a command with no argument
-- can pick the obvious one.
function pump.playlist_keys()
	local out = {}
	for key, st in pairs(streams) do
		if st.kind == "playlist" then
			out[#out + 1] = key
		end
	end
	return out
end

-- --------------------------------------------------------------------- tick --

function pump.tick()
	local now = pump.clock()
	local who = listeners()
	local have = #who > 0

	-- Speakers are the on switch: a source with none does no work at all.
	local groups = {}
	for _, spk in ipairs(sb.speakers.list()) do
		local kind = spk.kind or "stream"
		local name = spk.stream or ""
		local key = (kind == "playlist") and ("playlist:" .. name) or name
		local into = groups[key]
		if not into then
			into = {kind = kind, name = name, speakers = {}}
			groups[key] = into
		end
		table.insert(into.speakers, spk)
	end

	for key, st in pairs(streams) do
		if not groups[key] then
			silence(st)
			streams[key] = nil
			log("action", "%s %q: no speakers left", st.kind, st.name)
		end
	end

	for key, group in pairs(groups) do
		if not pump.stopped[key] then
			local st = streams[key]
			if not st then
				st = new_stream(key, group.kind, group.name)
				streams[key] = st
				log("action", "%s %q: watching %s", group.kind,
					group.name ~= "" and group.name or "(root)", st.dir)
			end
			if st.kind == "playlist" then
				tick_playlist(st, now, group.speakers, who)
			else
				discover(st, now, group.speakers, have)
				play(st, now, who, group.speakers)
				follow(st, who)
				reap(st, now)
			end
		end
	end
end

function pump.forget_player(name)
	caps[name] = nil
	warned_old[name] = nil
	for _, st in pairs(streams) do
		st.handles[name] = nil
		for _, sounding in pairs(st.pending) do
			sounding.started[name] = nil
			sounding.delivered[name] = nil
		end
		if st.ready then
			st.ready.started[name] = nil
			st.ready.delivered[name] = nil
		end
		if st.current then
			st.current.started[name] = nil
			st.current.delivered[name] = nil
		end
	end
end

function pump.stop_stream(id)
	pump.stopped[id] = true
	local st = streams[id]
	if st then
		silence(st)
		streams[id] = nil
	end
end

function pump.start_stream(id)
	pump.stopped[id] = nil
end

-- Push the newest finished chunk once and say what the engine made of it.
-- The quickest answer to "is my encoder producing something this server can
-- actually send", and it needs no client: dynamic_add_media still reads,
-- hashes and accepts the file when nobody is connected.
function pump.push_newest(id)
	-- a playlist is asked the same question in a different way: push the track
	-- that would play next, and report what came out of its header
	local playlist_name = id:match("^playlist:(.*)$")
	if playlist_name or (streams[id] and streams[id].kind == "playlist") then
		local key = playlist_name and id or id
		local st = streams[key]
		if not st then
			st = new_stream(key, "playlist", playlist_name or "")
		end
		local report = {dir = st.dir, kind = "playlist"}
		st.scanned_at = -1e9
		rescan(st, pump.clock())
		if not st.order or #st.order == 0 then
			report.reason = "no .ogg tracks there -- tools/playlist.sh converts " ..
				"the formats Luanti cannot decode"
			return report
		end
		report.finished = #st.order
		local before = st.stats.pushed
		push_track(st, pump.clock())
		local track = st.ready
		if st.stats.pushed > before and track then
			report.file = track.file
			report.codec = "vorbis"
			report.channels = track.channels
			report.rate = track.rate
			report.duration = track.duration
			report.pushed = true
		else
			report.reason = "the track could not be read or was refused; " ..
				"see the server log"
		end
		return report
	end

	local st = streams[id]
	if not st then
		st = new_stream(id, "stream", id)
	end
	local report = {dir = st.dir, kind = "stream"}

	local avail = source.scan(st.dir, sb.cfg.ready_mode)
	if not avail then
		report.reason = "no such directory"
		return report
	end
	report.finished = #avail
	if #avail == 0 then
		-- "nothing there at all" and "something there that does not count yet"
		-- are different problems with the same symptom
		local raw = source.scan(st.dir, "all") or {}
		if #raw == 0 then
			report.reason = "the directory is empty -- nothing has written " ..
				"chunks into it yet"
		elseif sb.cfg.ready_mode == "manifest" then
			report.reason = ("%d chunk file(s) are there, but chunks.list " ..
				"vouches for none of them: is the encoder writing a manifest " ..
				"(ffmpeg -segment_list)? Otherwise use ready_mode = lag.")
				:format(#raw)
		else
			report.reason = ("%d chunk file(s) are there, but none counts as " ..
				"finished under ready_mode = %s"):format(#raw, sb.cfg.ready_mode)
		end
		return report
	end

	local chunk = avail[#avail]
	report.file = chunk.name
	report.seq = chunk.seq

	local blob = source.header(st.dir .. "/" .. chunk.name)
	local meta, err = oggmeta.parse(blob or "")
	if meta then
		report.codec, report.channels, report.rate = meta.codec, meta.channels, meta.rate
	else
		report.reason = err
		return report
	end

	local now = pump.clock()
	if not st.sched.base then
		schedule.sync(st.sched, chunk.seq, now)
	end
	local before = st.stats.pushed
	push(st, chunk.seq, chunk.name, now)
	report.pushed = st.stats.pushed > before
	if not report.pushed then
		report.reason = "the engine refused the file; see the server log"
	end
	return report
end

-- Everything /speaker info needs, in one place, because "it plays and there is
-- no sound" has too many causes to debug by reading code.
function pump.info()
	local out = {streams = {}, players = {}}
	for key, st in pairs(streams) do
		local s = st.stats
		local entry = {
			key = key,
			kind = st.kind,
			id = st.name ~= "" and st.name or "(root)",
			dir = st.dir,
			stats = s,
			mean_delivery = s.deliveries > 0
				and (s.delivery_total / s.deliveries) or nil,
		}
		if st.kind == "playlist" then
			entry.count = st.order and #st.order or 0
			entry.index = st.index
			if st.current then
				entry.track = st.current.file
				entry.duration = st.current.duration
				entry.position = pump.clock() - st.current.due
				entry.channels = st.current.channels
				entry.rate = st.current.rate
			end
			if st.ready then
				entry.queued = st.ready.file
				entry.queued_ready = next(st.ready.delivered) ~= nil
			end
		else
			entry.meta = st.meta
			entry.pending = (function()
				local n = 0
				for _ in pairs(st.pending) do n = n + 1 end
				return n
			end)()
			entry.last_seq = st.last_seq
			entry.anchored = st.sched.base ~= nil
			entry.resyncs = st.sched.resyncs
			entry.skipped = st.sched.skipped
		end
		out.streams[#out.streams + 1] = entry
	end
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		out.players[#out.players + 1] = {
			name = name,
			cap = caps[name],
			muted = sb.state.mutes[name] == true,
			volume = sb.state.volumes[name] or 1.0,
		}
	end
	return out
end

return pump

end
