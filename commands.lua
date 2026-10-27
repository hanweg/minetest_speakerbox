-- /speaker, and the privilege.
--
-- `info` exists because "it plays and there is no sound" has too many causes
-- to debug by reading code: a client too old for media push, a stream whose
-- chunks are Opus, a clock that never anchored because nobody was listening,
-- or simply a muted player. One command answers all of them.

return function(sb)

local commands = {}

local function log(level, fmt, ...)
	core.log(level, "[speakerbox] " .. string.format(fmt, ...))
end

core.register_privilege("speaker", {
	description = "Can place and configure speaker boxes",
	give_to_singleplayer = true,
	give_to_admin = true,
})

local function may_edit(name)
	return sb.cfg.open_access or core.check_player_privs(name, {speaker = true})
end

local function save_state()
	sb.storage:set_string("mutes", core.write_json(sb.state.mutes))
	sb.storage:set_string("volumes", core.write_json(sb.state.volumes))
end

local function mmss(seconds)
	if not seconds then
		return "-"
	end
	return ("%d:%02d"):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

local function fmt_ms(seconds)
	if not seconds then
		return "-"
	end
	return ("%d ms"):format(math.floor(seconds * 1000 + 0.5))
end

local function report(name)
	local info = sb.pump.info()
	local out = {"--- speakerbox ---"}

	local srv = sb.compat.server()
	out[#out + 1] = ("server %s: dynamic media %s, start_time %s")
		:format(srv.version,
			srv.dynamic_media and "yes" or "NO (needs 5.5.0)",
			srv.start_time and "yes" or "no (needs 5.8.0; chunks cannot be " ..
				"seeked, so seams will drift)")
	out[#out + 1] = ("chunks: %s, %s mode, %.1fs each, %.1fs lead, %.2fs blend, %s")
		:format(sb.cfg.chunk_root, sb.cfg.ready_mode, sb.cfg.chunk_seconds,
			sb.cfg.lead_seconds, sb.cfg.blend_seconds,
			sb.cfg.live and "live" or "playlist")

	if #info.streams == 0 then
		out[#out + 1] = "nothing is running: place a speaker and point it at a " ..
			"stream or a playlist"
	end
	for _, st in ipairs(info.streams) do
		if st.kind == "playlist" then
			out[#out + 1] = ("playlist %q: %d track(s) in %s")
				:format(st.id, st.count, st.dir)
			if st.track then
				out[#out + 1] = ("  playing %s -- %s of %s, %dch %dHz")
					:format(st.track, mmss(st.position), mmss(st.duration),
						st.channels or 0, st.rate or 0)
			else
				out[#out + 1] = "  nothing playing yet"
			end
			if st.queued then
				out[#out + 1] = ("  next up %s (%s)"):format(st.queued,
					st.queued_ready and "delivered" or "still fetching")
			end
			out[#out + 1] = ("  pushed %d, started %d, unreadable %d")
				:format(st.stats.pushed, st.stats.played, st.stats.skipped_tracks)
		else
			local meta = st.meta and
				("%s %dch %dHz"):format(st.meta.codec, st.meta.channels, st.meta.rate)
				or "no chunk read yet"
			out[#out + 1] = ("stream %q: %s, %s, %d held, last chunk %d")
				:format(st.id, meta, st.anchored and "on the clock" or "idle",
					st.pending, st.last_seq)
			out[#out + 1] = ("  pushed %d, started %d (%d late), never heard %d, " ..
				"resyncs %d, skipped %d")
				:format(st.stats.pushed, st.stats.played, st.stats.late,
					st.stats.missed, st.resyncs, st.skipped)
		end
		out[#out + 1] = ("  delivery: mean %s, worst %s over %d deliveries")
			:format(fmt_ms(st.mean_delivery), fmt_ms(st.stats.delivery_worst),
				st.stats.deliveries)
	end

	for _, p in ipairs(info.players) do
		local cap = p.cap
		local how
		if not cap then
			how = "protocol not reported yet"
		elseif not cap.media then
			how = ("protocol %d: TOO OLD for streamed audio (needs 5.3.0)")
				:format(cap.proto)
		elseif not cap.start_time then
			how = ("protocol %d (%s): plays, but ignores start_time, so its " ..
				"seams drift by however late a chunk arrives")
				:format(cap.proto, cap.version)
		else
			how = ("protocol %d (%s): in sync"):format(cap.proto, cap.version)
		end
		out[#out + 1] = ("%s -- %s%s, volume %.2f"):format(p.name, how,
			p.muted and ", MUTED" or "", p.volume)
	end

	for _, line in ipairs(out) do
		core.chat_send_player(name, line)
	end
end

core.register_chatcommand("speaker", {
	params = "info | list | next | mute | unmute | volume <0-2> | " ..
		"start <source> | stop <source> | test [stream] | rescan",
	description = "Inspect and control the speaker boxes",
	func = function(name, param)
		local sub, rest = param:match("^(%S*)%s*(.-)$")

		if sub == "" or sub == "help" then
			return true, "/speaker info | list | next | mute | unmute | " ..
				"volume <0-2> | start <source> | stop <source> | " ..
				"test [stream] | rescan"
		end

		if sub == "info" then
			report(name)
			return true

		elseif sub == "list" then
			local list = sb.speakers.list()
			if #list == 0 then
				return true, "No speakers placed."
			end
			local lines = {}
			for _, e in ipairs(list) do
				lines[#lines + 1] = ("%s: %s%s"):format(core.pos_to_string(e.pos),
					sb.speakers.describe(e),
					sb.pump.stopped[sb.pump.key_for(e)] and " [stopped]" or "")
			end
			return true, table.concat(lines, "\n")

		elseif sub == "mute" then
			sb.state.mutes[name] = true
			save_state()
			return true, "Speakers muted for you. /speaker unmute to undo."

		elseif sub == "unmute" then
			sb.state.mutes[name] = nil
			save_state()
			return true, "Speakers unmuted. You will hear the next chunk."

		elseif sub == "volume" then
			local v = tonumber(rest)
			if not v then
				return false, "Give a number from 0 to 2."
			end
			v = math.max(0, math.min(2, v))
			sb.state.volumes[name] = v
			save_state()
			return true, ("Your speaker volume is now %.2f (from the next " ..
				"chunk)."):format(v)

		elseif sub == "next" then
			if not may_edit(name) then
				return false, "You need the 'speaker' privilege for that."
			end
			local keys = sb.pump.playlist_keys()
			local key
			if rest ~= "" then
				key = rest:match("^playlist:") and rest or ("playlist:" .. rest)
			elseif #keys == 1 then
				key = keys[1]
			elseif #keys == 0 then
				return false, "No playlist is running."
			else
				return false, "Which one? " .. table.concat(keys, ", ")
			end
			local ok, what = sb.pump.next_track(key)
			if not ok then
				return false, what
			end
			log("action", "%s skipped to %s", name, what)
			return true, "Now playing " .. what

		elseif sub == "start" or sub == "stop" then
			if not core.check_player_privs(name, {server = true}) then
				return false, "You need the 'server' privilege for that."
			end
			if rest == "" then
				return false, "Which source? A stream name, or playlist:<name>."
			end
			-- accept either the key as /speaker list prints it, or a bare name
			local key = rest
			if not sb.pump.streams[key] then
				local as_playlist = rest:match("^playlist:") and rest
					or ("playlist:" .. rest)
				if sb.pump.streams[as_playlist] then
					key = as_playlist
				end
			end
			if sub == "stop" then
				sb.pump.stop_stream(key)
				log("action", "%s stopped %q", name, key)
				return true, ("%q stopped."):format(key)
			end
			sb.pump.start_stream(key)
			log("action", "%s started %q", name, key)
			return true, ("%q will resume shortly."):format(key)

		elseif sub == "test" then
			if not core.check_player_privs(name, {server = true}) then
				return false, "You need the 'server' privilege for that."
			end
			local id = rest ~= "" and rest or sb.cfg.default_stream
			local r = sb.pump.push_newest(id)
			local lines = {("%s %q in %s")
				:format(r.kind or "stream", id, r.dir)}
			if r.file then
				lines[#lines + 1] = (r.kind == "playlist")
					and ("next track: %s (%d in the playlist)")
						:format(r.file, r.finished or 0)
					or ("newest finished chunk: %s (%d finished)")
						:format(r.file, r.finished or 0)
			end
			if r.codec then
				lines[#lines + 1] = ("%s, %d channel(s), %d Hz%s%s"):format(r.codec,
					r.channels, r.rate,
					r.duration and (", " .. mmss(r.duration)) or "",
					r.codec ~= "vorbis" and "  <- Luanti decodes Vorbis only" or "")
			end
			lines[#lines + 1] = r.pushed
				and "the engine accepted it: delivery is on its way to everyone connected"
				or ("not pushed: " .. tostring(r.reason))
			return true, table.concat(lines, "\n")

		elseif sub == "rescan" then
			if not core.check_player_privs(name, {server = true}) then
				return false, "You need the 'server' privilege for that."
			end
			local gone = sb.speakers.validate()
			return true, ("Checked %d speaker(s), forgot %d.")
				:format(#sb.speakers.list() + gone, gone)
		end

		return false, "Unknown subcommand. Try /speaker help."
	end,
})

commands.may_edit = may_edit
return commands

end
