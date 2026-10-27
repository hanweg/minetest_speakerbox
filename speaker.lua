-- The node, and the register of where the speakers are.
--
-- The register is kept in mod storage rather than found by scanning the map:
-- a stream has to ask "where are my speakers" several times a second, and
-- find_nodes_in_area over even a modest area is the kind of thing that eats a
-- server tick. Entries are validated on a slow timer instead, which is also
-- what catches a node another mod moved or replaced.

return function(sb)

local speakers = {}

local register = {}        -- key -> {key, pos, stream, gain, radius, mode}
local order = {}           -- array of keys, so list() has a stable order
local dirty = false

local MODES = {"world", "room"}
local KINDS = {"stream", "playlist"}

local function log(level, fmt, ...)
	core.log(level, "[speakerbox] " .. string.format(fmt, ...))
end

local function key_of(pos)
	return core.pos_to_string(vector.round(pos))
end

-- ------------------------------------------------------------- persistence --

local function save()
	local list = {}
	for _, key in ipairs(order) do
		local e = register[key]
		if e then
			list[#list + 1] = {pos = e.pos, kind = e.kind, stream = e.stream,
				gain = e.gain, radius = e.radius, mode = e.mode}
		end
	end
	sb.storage:set_string("speakers", core.write_json(list))
	dirty = false
end

local function load()
	local raw = sb.storage:get_string("speakers")
	if raw == "" then
		return
	end
	local list = core.parse_json(raw)
	if type(list) ~= "table" then
		log("warning", "stored speaker list is unreadable, starting empty")
		return
	end
	for _, e in ipairs(list) do
		if type(e) == "table" and type(e.pos) == "table" then
			local pos = vector.new(e.pos.x, e.pos.y, e.pos.z)
			local key = key_of(pos)
			register[key] = {
				key = key,
				pos = pos,
				-- speakers saved before playlists existed have no kind
				kind = (e.kind == "playlist") and "playlist" or "stream",
				stream = tostring(e.stream or "default"),
				gain = tonumber(e.gain) or sb.cfg.default_gain,
				radius = tonumber(e.radius) or sb.cfg.default_radius,
				mode = (e.mode == "room") and "room" or "world",
			}
			order[#order + 1] = key
		end
	end
	log("action", "loaded %d speaker(s)", #order)
end

-- ------------------------------------------------------------------- access --

function speakers.list()
	local out = {}
	for _, key in ipairs(order) do
		local e = register[key]
		if e then
			out[#out + 1] = e
		end
	end
	return out
end

function speakers.get(pos)
	return register[key_of(pos)]
end

function speakers.add(pos)
	local key = key_of(pos)
	if not register[key] then
		order[#order + 1] = key
	end
	register[key] = {
		key = key,
		pos = vector.round(pos),
		kind = sb.cfg.default_kind,
		stream = sb.cfg.default_kind == "playlist" and "" or sb.cfg.default_stream,
		gain = sb.cfg.default_gain,
		radius = sb.cfg.default_radius,
		mode = sb.cfg.default_mode,
	}
	dirty = true
	return register[key]
end

function speakers.remove(pos)
	local key = key_of(pos)
	if not register[key] then
		return false
	end
	register[key] = nil
	for i, k in ipairs(order) do
		if k == key then
			table.remove(order, i)
			break
		end
	end
	dirty = true
	return true
end

function speakers.set(pos, fields)
	local e = register[key_of(pos)] or speakers.add(pos)
	for k, v in pairs(fields) do
		e[k] = v
	end
	dirty = true
	return e
end

-- A node someone else moved, replaced or dug while the mod was not loaded.
-- Unloaded blocks say nothing, so they are left alone.
function speakers.validate()
	local gone = {}
	for _, key in ipairs(order) do
		local e = register[key]
		if e then
			local node = core.get_node_or_nil(e.pos)
			if node and node.name ~= "speakerbox:speaker" then
				gone[#gone + 1] = e.pos
			end
		end
	end
	for _, pos in ipairs(gone) do
		speakers.remove(pos)
		log("action", "forgot the speaker at %s: the node is gone",
			core.pos_to_string(pos))
	end
	if dirty then
		save()
	end
	return #gone
end

-- ----------------------------------------------------------------- formspec --

local function mode_index(mode)
	return mode == "room" and 2 or 1
end

local function kind_index(kind)
	return kind == "playlist" and 2 or 1
end

local function names(e)
	if e.kind == "playlist" then
		return "playlist " .. (e.stream ~= "" and e.stream or "(root)")
	end
	return "stream " .. e.stream
end

local function describe(e)
	return ("Speaker: %s, %s mode, gain %.2f, radius %d")
		:format(names(e), e.mode, e.gain, math.floor(e.radius + 0.5))
end

-- Which directory this speaker is actually reading, spelled out: "where do
-- the files go" is the question the panel exists to answer.
local function where(e)
	if sb.pump and sb.pump.dir_for then
		return sb.pump.dir_for(e.kind, e.stream)
	end
	return "?"
end

-- Classic coordinates and no formspec_version line, so this renders the same
-- on a 5.3 client as on a current one.
local function formspec(e)
	local esc = core.formspec_escape
	return table.concat({
		"size[8,7]",
		"label[0,0;Speaker Box]",
		"label[0.3,0.5;Source]",
		"dropdown[0.3,0.9;3.6;kind;stream,playlist;", kind_index(e.kind), "]",
		"field[4.2,1.1;3.6,1;stream;Directory (blank = the root);", esc(e.stream), "]",
		"label[0.3,2;", esc(where(e)), "]",
		"label[0.3,2.5;Placement]",
		"dropdown[0.3,2.9;3.6;mode;world,room;", mode_index(e.mode), "]",
		"field[4.2,3.1;3.6,1;gain;Gain;", esc(("%.2f"):format(e.gain)), "]",
		"field[0.3,4.4;3.6,1;radius;Radius in nodes;",
		esc(("%d"):format(math.floor(e.radius + 0.5))), "]",
		"label[4.2,4.1;world: panned by the client (mono only)]",
		"label[4.2,4.5;room: our own falloff, no panning]",
		"button_exit[2.5,5.8;3,1;save;Save]",
	})
end

local function refresh(pos, e)
	local meta = core.get_meta(pos)
	meta:set_string("formspec", formspec(e))
	meta:set_string("infotext", describe(e))
end

-- --------------------------------------------------------------------- node --

local function may_edit(pos, player)
	if not player or not player:is_player() then
		return false, "No player"
	end
	local name = player:get_player_name()
	if core.is_protected(pos, name) then
		core.record_protection_violation(pos, name)
		return false, "This block is protected"
	end
	if not (sb.cfg.open_access or core.check_player_privs(name, {speaker = true})) then
		return false, "You need the 'speaker' privilege to change a speaker"
	end
	return true, name
end

core.register_node("speakerbox:speaker", {
	description = "Speaker Box",
	tiles = {
		"speakerbox_speaker_top.png",
		"speakerbox_speaker_top.png",
		"speakerbox_speaker_side.png",
		"speakerbox_speaker_side.png",
		"speakerbox_speaker_side.png",
		"speakerbox_speaker_front.png",
	},
	paramtype2 = "facedir",
	is_ground_content = false,
	-- dig_immediate keeps it diggable by hand in any game, cracky is there for
	-- games that care about the right tool
	groups = {cracky = 2, dig_immediate = 2},

	on_construct = function(pos)
		local e = speakers.get(pos) or speakers.add(pos)
		refresh(pos, e)
		save()
	end,

	on_destruct = function(pos)
		if speakers.remove(pos) then
			save()
		end
	end,

	on_receive_fields = function(pos, _, fields, sender)
		if not fields.save and not fields.key_enter then
			return
		end
		local ok, who = may_edit(pos, sender)
		if not ok then
			if sender and sender:is_player() then
				core.chat_send_player(sender:get_player_name(), who)
			end
			return
		end

		local e = speakers.get(pos) or speakers.add(pos)
		local changes = {}

		if fields.kind == "stream" or fields.kind == "playlist" then
			changes.kind = fields.kind
		end
		local kind = changes.kind or e.kind

		local stream = (fields.stream or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if stream == "" then
			if kind == "playlist" then
				changes.stream = ""          -- the playlist root itself
			else
				core.chat_send_player(who, "A stream needs the name of a " ..
					"directory under the chunk root.")
			end
		elseif stream:match("^[%w_%-]+$") then
			changes.stream = stream
		else
			core.chat_send_player(who, "Directory names may use letters, " ..
				"digits, '-' and '_' only.")
		end

		local gain = tonumber(fields.gain)
		if gain then
			changes.gain = math.max(0, math.min(4, gain))
		end

		local radius = tonumber(fields.radius)
		if radius then
			local cap = sb.cfg.max_radius
			if core.check_player_privs(who, {server = true}) then
				cap = 500
			end
			changes.radius = math.max(1, math.min(cap, radius))
			if radius > cap then
				core.chat_send_player(who,
					("Radius capped at %d."):format(math.floor(cap)))
			end
		end

		if fields.mode == "room" or fields.mode == "world" then
			changes.mode = fields.mode
		end

		e = speakers.set(pos, changes)
		refresh(pos, e)
		save()
		log("action", "%s set the speaker at %s to %s",
			who, core.pos_to_string(pos), describe(e))
	end,
})

-- Only register a recipe if the game has something to make one from; this mod
-- should not care which game it is in.
local function craft_from(ingredient, frame)
	if core.registered_items[ingredient] and core.registered_items[frame] then
		core.register_craft({
			output = "speakerbox:speaker",
			recipe = {
				{frame, frame, frame},
				{frame, ingredient, frame},
				{frame, frame, frame},
			},
		})
		return true
	end
	return false
end

core.after(0, function()
	local made = craft_from("default:copper_ingot", "default:wood")
		or craft_from("mcl_core:iron_ingot", "mcl_core:wood")
	if not made then
		log("info", "no craft recipe registered for this game; use /giveme " ..
			"speakerbox:speaker")
	end
end)

speakers.MODES = MODES
speakers.KINDS = KINDS
speakers.names = names
speakers.save = save
speakers.describe = describe
speakers.refresh = refresh
load()

return speakers

end
