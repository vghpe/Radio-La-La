-- radio-live-resume.lua
-- On every resume: mute immediately, reload the stream URL via
-- loadfile replace (closes the old TCP connection so stale data in the
-- OS network buffer is discarded), then unmute when mpv signals the
-- fresh buffer is ready (paused-for-cache → false).
--
-- NEXT/PREV media keys cycle through stations by calling radio-ctl.sh.
--
-- Loaded via --script= from radio-ctl.sh.

local is_reloading = false
local was_muted = false
local safety_timer = nil
local initialized = false  -- skip the initial pause=false at mpv startup

local function do_unmute()
    is_reloading = false
    if safety_timer then
        safety_timer:kill()
        safety_timer = nil
    end
    if not was_muted then
        mp.set_property("mute", "no")
        mp.msg.info("unmuted: live stream ready")
    end
end

-- Unmute as soon as fresh data is buffered from the new connection.
mp.observe_property("paused-for-cache", "bool", function(_, buffering)
    if is_reloading and buffering == false then
        do_unmute()
    end
end)

mp.observe_property("pause", "bool", function(_, paused)
    if not initialized then
        initialized = true
        return
    end
    -- Ignore pause events triggered by the reload itself.
    if is_reloading then return end
    if paused == false then
        local url = mp.get_property("path")
        if not url then return end
        local title = mp.get_property("force-media-title") or ""
        was_muted = mp.get_property("mute") == "yes"
        if not was_muted then
            mp.set_property("mute", "yes")
        end
        is_reloading = true
        mp.commandv("loadfile", url, "replace")
        -- Restore title (loadfile replace clears the property).
        if title ~= "" then
            mp.set_property("force-media-title", title)
        end
        -- Safety net: unmute after 5s if paused-for-cache never clears.
        safety_timer = mp.add_timeout(5, function()
            safety_timer = nil
            mp.msg.warn("safety unmute after 5s timeout")
            do_unmute()
        end)
        mp.msg.info("reloading stream for live resume")
    end
end)

-- ─── Station cycling via NEXT / PREV media keys ───────────────────────────

local stations = {"fip", "kcrw", "kexp"}
local state_dir = os.getenv("HOME") .. "/.radio"
local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)")
local ctl = script_dir .. "radio-ctl.sh"

local function current_index()
    local f = io.open(state_dir .. "/current-station", "r")
    if not f then return 1 end
    local s = f:read("*l"); f:close()
    for i, name in ipairs(stations) do
        if name == s then return i end
    end
    return 1
end

local function switch_station(delta)
    local i = ((current_index() - 1 + delta) % #stations) + 1
    mp.msg.info("switching to station: " .. stations[i])
    mp.command_native_async({"run", ctl, "play", stations[i]}, function() end)
end

mp.add_key_binding("NEXT", "next-station", function() switch_station(1)  end)
mp.add_key_binding("PREV", "prev-station", function() switch_station(-1) end)
