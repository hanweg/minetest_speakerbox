-- Shared scaffolding for the plain-Lua tests. Run them from anywhere:
--     lua5.1 mods/speakerbox/tests/test_schedule.lua
--     mods/speakerbox/tests/run.sh
local testdir = (arg and arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path = testdir .. "/../?.lua;" .. package.path

local h = {fails = 0, dir = testdir}

local function approx(a, b)
	return math.abs(a - b) < 1e-6
end

function h.check(name, got, want)
	local ok = (type(want) == "number" and type(got) == "number" and approx(got, want))
		or got == want
	if ok then
		print(("ok   %-40s %s"):format(name, tostring(got)))
	else
		print(("FAIL %-40s got %s want %s"):format(name, tostring(got), tostring(want)))
		h.fails = h.fails + 1
	end
end

function h.done(label)
	print(h.fails == 0 and ("\nALL " .. label .. " TESTS PASSED")
		or ("\n" .. h.fails .. " FAILURES"))
	os.exit(h.fails == 0 and 0 or 1)
end

return h
