-- The chunk clock. Nothing here touches Luanti.
local h = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/helpers.lua")
local check = h.check
local S = require("schedule")

local CFG = {
	chunk_seconds = 6.0,
	blend_seconds = 0.08,
	lead_seconds = 2.0,
	live = true,
	max_backlog = 2,
}

local function fresh(over)
	local cfg = {}
	for k, v in pairs(CFG) do cfg[k] = v end
	for k, v in pairs(over or {}) do cfg[k] = v end
	return S.new(cfg)
end

-- anchoring -----------------------------------------------------------------
local s = fresh()
local plan = S.plan(s, {1}, 100)
check("first chunk is pushed", plan[1].action, "push")
check("first chunk anchors the clock", plan[1].sync, "sync")
check("anchor leaves the lead free", s.epoch, 102)
check("due one blend before the slot", S.due_at(s, 1), 101.92)

-- the grid ------------------------------------------------------------------
check("chunks are one chunk_len apart", S.due_at(s, 2) - S.due_at(s, 1), 6)
check("a chunk expires as the next is due", S.expires_at(s, 1), S.due_at(s, 2))
check("the blend never accumulates",
	S.due_at(s, 11) - S.due_at(s, 1), 60)

-- start_time ----------------------------------------------------------------
check("on time means no offset", S.offset(s, 1, 101.92), 0)
check("early means no offset", S.offset(s, 2, 103), 0)
check("late seeks in by exactly the lateness", S.offset(s, 1, 104), 2.08)

-- falling behind ------------------------------------------------------------
s = fresh()
S.plan(s, {1}, 100)
plan = S.plan(s, {2}, 110)        -- its slot was 107.92, so we are late
check("a chunk handed over late resyncs", plan[1].sync, "resync")
check("resync is counted", s.resyncs, 1)
check("resync re-anchors on that chunk", s.base, 2)
check("resync gives delivery the lead again", s.epoch, 112)

-- staying near live ---------------------------------------------------------
s = fresh()
plan = S.plan(s, {1, 2, 3, 4}, 100)
check("a live backlog is dropped", #plan, 4)
check("all but the newest is skipped", plan[1].action, "skip")
check("the newest is pushed", plan[4].action, "push")
check("the newest becomes the anchor", s.base, 4)
check("skips are counted", s.skipped, 3)

-- a playlist plays everything ----------------------------------------------
s = fresh({live = false})
plan = S.plan(s, {1, 2, 3, 4}, 100)
check("a playlist pushes the backlog", #plan, 4)
check("a playlist skips nothing", s.skipped, 0)
check("playlist chunk 4 is due three lengths on",
	S.due_at(s, 4) - S.due_at(s, 1), 18)

-- nothing to do -------------------------------------------------------------
s = fresh()
check("no chunks, no plan", #S.plan(s, {}, 100), 0)
check("an empty plan leaves the clock cold", s.base, nil)

-- room mode gain ------------------------------------------------------------
check("full volume at the speaker", S.room_gain(0, 48, 0.6), 1.0)
check("full volume out to the knee", S.room_gain(28.8, 48, 0.6), 1.0)
check("quarter volume halfway down the skirt", S.room_gain(38.4, 48, 0.6), 0.25)
check("silent at the radius", S.room_gain(48, 48, 0.6), 0)
check("silent beyond the radius", S.room_gain(100, 48, 0.6), 0)
check("a zero knee still peaks at the speaker", S.room_gain(0, 10, 0), 1.0)

h.done("SCHEDULE")
