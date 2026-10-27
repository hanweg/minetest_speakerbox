-- When each chunk should sound, and how loud.
--
-- No Luanti API is touched in this file, so tests/test_schedule.lua can run it
-- under a plain Lua interpreter. Everything here is arithmetic on a wall clock
-- in seconds; the caller decides where that clock comes from.
--
-- The model: chunk `base` is due at `epoch`, and every later chunk follows one
-- `chunk_len` after the one before it. Playback is therefore pinned to a clock
-- rather than to "whenever the last chunk finished", which is what keeps a room
-- of clients on the same beat however differently their copies arrive.

local schedule = {}

function schedule.new(cfg)
	return {
		chunk_len = cfg.chunk_seconds,
		blend = cfg.blend_seconds,
		lead = cfg.lead_seconds,
		live = cfg.live,
		max_backlog = cfg.max_backlog,
		base = nil,            -- seq the clock is anchored on
		epoch = nil,           -- wall time that seq is due at (before blend)
		resyncs = 0,
		skipped = 0,
	}
end

-- Wall time this chunk should start sounding. The blend is subtracted so the
-- chunk starts slightly early and overlaps the tail of its predecessor; each
-- chunk is placed from `epoch` independently, so that early start is a constant
-- offset and never accumulates into drift.
function schedule.due_at(s, seq)
	return s.epoch + (seq - s.base) * s.chunk_len - s.blend
end

-- After this there is no point starting it: its audio is entirely in the past.
function schedule.expires_at(s, seq)
	return schedule.due_at(s, seq) + s.chunk_len
end

-- What to pass as sound_play's `start_time`: how far into the chunk we already
-- are. Zero when it starts on time, positive when this client's copy was late,
-- which is how a late client stays on the room's clock instead of trailing it.
function schedule.offset(s, seq, now)
	local off = now - schedule.due_at(s, seq)
	if off < 0 then
		return 0
	end
	return off
end

-- Anchor the clock on this chunk, giving delivery `lead` seconds of head start.
function schedule.sync(s, seq, now)
	s.base = seq
	s.epoch = now + s.lead
end

-- Decide what to do with the finished chunks the encoder has made available.
--
-- `avail` is an ascending list of sequence numbers not pushed yet. Returns a
-- list of {seq = n, action = "push" | "skip", sync = "sync" | "resync" | nil},
-- in the order they should be handled, and advances the clock as a side effect.
function schedule.plan(s, avail, now)
	local out = {}
	local n = #avail
	if n == 0 then
		return out
	end

	-- A live stream that has fallen behind -- the server was lagging, or nobody
	-- was listening for a while -- throws away everything but the newest chunk
	-- rather than playing a backlog that is already stale.
	local from = 1
	if s.live and n > s.max_backlog then
		from = n
		for i = 1, n - 1 do
			out[#out + 1] = {seq = avail[i], action = "skip"}
			s.skipped = s.skipped + 1
		end
		s.base = nil        -- the kept chunk becomes the new anchor
	end

	for i = from, n do
		local seq = avail[i]
		local sync = nil
		if not s.base then
			schedule.sync(s, seq, now)
			sync = "sync"
		elseif now > schedule.due_at(s, seq) then
			-- handed to us after its slot had passed: the encoder is slower
			-- than chunk_seconds, or we stalled. Re-anchor and carry on.
			s.resyncs = s.resyncs + 1
			schedule.sync(s, seq, now)
			sync = "resync"
		end
		out[#out + 1] = {seq = seq, action = "push", sync = sync}
	end
	return out
end

-- Gain for room mode: flat out to `knee` of the radius, then eased down to
-- silence at the edge. Positional sound gives you 1/distance, which is a tenth
-- of the volume ten nodes out -- far too steep for a dance floor. This is the
-- curve you actually want for a room, at the cost of stereo placement.
function schedule.room_gain(dist, radius, knee)
	local flat = radius * knee
	if dist <= flat then
		return 1.0
	end
	if dist >= radius then
		return 0.0
	end
	local t = (dist - flat) / (radius - flat)
	return (1.0 - t) * (1.0 - t)
end

return schedule
