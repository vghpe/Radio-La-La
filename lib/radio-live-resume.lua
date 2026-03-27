-- radio-live-resume.lua
-- Drop stale demuxer buffers when resuming after a long pause so mpv
-- reconnects to the live position instead of draining old audio.
-- Loaded via --script= from radio-ctl.sh.

local pause_start = nil
local MIN_PAUSE_SECS = 10

mp.observe_property("pause", "bool", function(_, paused)
    if paused then
        pause_start = mp.get_time()
    elseif pause_start then
        local elapsed = mp.get_time() - pause_start
        pause_start = nil
        if elapsed >= MIN_PAUSE_SECS then
            mp.command("drop-buffers")
            mp.msg.info(string.format(
                "dropped buffers after %.0fs pause", elapsed))
        end
    end
end)
