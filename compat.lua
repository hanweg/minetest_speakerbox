-- What this server and each connected client can actually do.
--
-- The protocol numbers come from src/network/networkprotocol.cpp in the engine
-- source, where each bump is annotated with the release that shipped it:
--
--   39  5.3.0   TOCLIENT_MEDIA_PUSH exists. Below this a client is skipped
--               outright by Server::dynamicAddMedia and hears nothing.
--   40  5.5.0   media push v2: the server sends a hash and the client fetches
--               the file. Proto 39 clients get the bytes thrown at them inline,
--               which still works.
--   43  5.8.0   "start_time" added to TOCLIENT_PLAY_SOUND. Older clients ignore
--               the field -- the server appends it to the packet for everyone
--               and short reads are harmless -- so they play each chunk from
--               its beginning, however late their copy arrived, and drift by
--               that much at every seam.
--
-- Server-side the floor is 5.5.0, for the table form of dynamic_add_media.

local compat = {}

compat.PROTO_MEDIA = 39
compat.PROTO_START_TIME = 43

function compat.server()
	local features = core.features or {}
	return {
		dynamic_media = features.dynamic_add_media_table == true,
		start_time = features.sound_params_start_time == true,
		version = (core.get_version and core.get_version().string) or "unknown",
	}
end

-- nil if the client has not told us yet, which happens for a tick or two after
-- it connects; callers should simply try again.
function compat.player(name)
	if not core.get_player_information then
		return nil
	end
	local ok, info = pcall(core.get_player_information, name)
	if not ok or type(info) ~= "table" or not info.protocol_version then
		return nil
	end
	local proto = info.protocol_version
	return {
		proto = proto,
		version = info.version_string or "?",
		media = proto >= compat.PROTO_MEDIA,
		start_time = proto >= compat.PROTO_START_TIME,
	}
end

return compat
