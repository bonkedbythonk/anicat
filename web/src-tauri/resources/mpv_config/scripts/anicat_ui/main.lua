local mp = mp
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
  skip_times = '',
  auto_next = 'no',
  autoskip = 'yes',
  current_episode = 0,
  total_episodes = 0,
  shader_profile = 'on',
  -- Only a fallback. The backend passes the port it actually bound; this value
  -- is what the script would use if it somehow arrived without one, and it is
  -- the port the proxy prefers.
  proxy_port = 13370,
  media_id = 0,
}

options.read_options(opts, 'anicat_ui')
msg.info("anicat_ui loaded, skip_times='" .. opts.skip_times .. "', autoskip=" .. opts.autoskip)

local function get_autoskip_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.autoskip
  if script_opts and script_opts["anicat_ui-autoskip"] ~= nil then
    val = script_opts["anicat_ui-autoskip"]
  end
  return val
end

local function get_auto_next_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.auto_next
  if script_opts and script_opts["anicat_ui-auto_next"] ~= nil then
    val = script_opts["anicat_ui-auto_next"]
  end
  return val
end

local function get_skip_times_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.skip_times
  if script_opts and script_opts["anicat_ui-skip_times"] ~= nil then
    val = script_opts["anicat_ui-skip_times"]
  end
  return val
end

local function get_current_episode_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.current_episode
  if script_opts and script_opts["anicat_ui-current_episode"] ~= nil then
    val = tonumber(script_opts["anicat_ui-current_episode"]) or val
  end
  return val
end

local function get_proxy_port_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.proxy_port
  if script_opts and script_opts["anicat_ui-proxy_port"] ~= nil then
    val = tonumber(script_opts["anicat_ui-proxy_port"]) or val
  end
  return val
end

local function get_media_id_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.media_id
  if script_opts and script_opts["anicat_ui-media_id"] ~= nil then
    val = tonumber(script_opts["anicat_ui-media_id"]) or val
  end
  return val
end

local function get_total_episodes_opt()
  local script_opts = mp.get_property_native("script-opts")
  local val = opts.total_episodes
  if script_opts and script_opts["anicat_ui-total_episodes"] ~= nil then
    val = tonumber(script_opts["anicat_ui-total_episodes"]) or val
  end
  return val
end

local state = {
  overlay = mp.create_osd_overlay('ass-events'),
  width = 1280,
  height = 720,
  position = 0,
  duration = 0,
  skips = {},
  active_skip = nil,
  shaders_on = false,
  file_loaded = false,
  next_triggered = false,
  first_play = false,
  last_pos = 0,
  preload_sent = false,
  end_reported = false,
  early_eof_reported = false,
  rebuffer_wait_restored = false,
  rebuffer_baseline = nil,
}

local function parse_skip_times(raw)
  raw = raw:gsub('%%2C', ',')
  local parsed = {}
  if not raw or raw == '' then
    msg.info("parse_skip_times: no skip times provided")
    return parsed
  end
  for part in string.gmatch(raw, '([^;]+)') do
    local skip_type, start_s, end_s = part:match('([^,]+),([^,]+),([^,]+)')
    if skip_type and start_s and end_s then
      parsed[#parsed + 1] = {
        type = skip_type,
        start = tonumber(start_s) or 0,
        endt = tonumber(end_s) or 0,
        notified = false,
      }
      msg.info("parse_skip_times: " .. skip_type .. " " .. start_s .. "-" .. end_s)
    end
  end
  return parsed
end

-- Chapter titled literally "OP"/"ED" (optionally with a number or extra
-- word around it, e.g. "OP2", "OP 2", "Part OP") -- the scene-release
-- convention, and unambiguous: nothing else gets called that.
local function match_strict_skip_type(title)
  title = (title or ''):lower()

  if title == 'op' or title:find('^op%s') or title:find('^op%d') or title:find('%sop%s') or title:find('%sop%d') or title:find('%sop$') then
    return 'op'
  end

  if title == 'ed' or title:find('^ed%s') or title:find('^ed%d') or title:find('%sed%s') or title:find('%sed%d') or title:find('%sed$') then
    return 'ed'
  end

  return nil
end

-- Looser wording ("Intro", "Opening", "Ending", "Outro", "Credits") that
-- USUALLY also means the OP/ED, but not always: some BD releases chapter a
-- cold-open/recap segment as "Intro" *and* the real opening song as a
-- separate "OP" chapter right after it -- two different segments, only the
-- second of which is the opening. Kept separate from the strict matcher
-- above so parse_chapters_for_skips can tell "the only candidate in this
-- file" from "a same-named rival to a more specific chapter" and prefer the
-- specific one -- see the comment there.
local function match_loose_skip_type(title)
  title = (title or ''):lower()

  if title:find('intro') or title:find('opening') then
    return 'op'
  end

  if title:find('ending') or title:find('outro') or title:find('credits') then
    return 'ed'
  end

  return nil
end

local function match_skip_type(title)
  return match_strict_skip_type(title) or match_loose_skip_type(title)
end

-- Merge chapter-derived skips into AniSkip times.
-- Chapter timestamps WIN when both cover the same type, because high-quality
-- torrents have perfectly accurate OP/ED chapters, whereas AniSkip relies
-- on official broadcast timings that might be misaligned on other files.
local function merge_skips(aniskip_list, chapter_list)
  local result = {}
  local chapter_types = {}
  for _, cs in ipairs(chapter_list) do
    result[#result + 1] = cs
    chapter_types[cs.type] = true
  end
  for _, s in ipairs(aniskip_list) do
    if not chapter_types[s.type] then
      result[#result + 1] = s
    end
  end
  return result
end

local function parse_chapters_for_skips()
  local skips = {}
  local chapters = mp.get_property_native('chapter-list')
  if not chapters or #chapters == 0 then
    return skips
  end

  local duration = mp.get_property_number('duration') or 0

  -- Whether this file has an unambiguous "OP"/"ED" chapter for each type.
  -- Checked across the whole list before classifying anything: a "Intro"
  -- chapter three entries before an "OP" chapter is a cold open, not the
  -- opening, and must lose to the chapter that is unambiguously the real
  -- one. Without this, both got typed 'op' -- observed live on a real BD
  -- release, chapters "Intro" (0:00-1:51) and "OP" (1:51-3:21) -- and the
  -- skip prompt fired at 0:00 on the cold open instead of 1:51 on the
  -- actual song, which is what "it skips the wrong thing, too early"
  -- reported as.
  local has_strict = {}
  for _, chapter in ipairs(chapters) do
    local strict_type = match_strict_skip_type(chapter.title or '')
    if strict_type then
      has_strict[strict_type] = true
    end
  end

  for i, chapter in ipairs(chapters) do
    local title = chapter.title or ''
    local strict_type = match_strict_skip_type(title)
    local skip_type = strict_type
    if not skip_type then
      local loose_type = match_loose_skip_type(title)
      -- Only fall back to the loose match when nothing more specific claims
      -- this same type anywhere in the file. When something does, this
      -- chapter is whatever the loose wording actually says it is (a cold
      -- open, a recap) rather than the segment that name usually means.
      if loose_type and not has_strict[loose_type] then
        skip_type = loose_type
      end
    end
    if skip_type then
      local start_time = chapter.time or 0
      local end_time = duration
      if i < #chapters then
        local next_ch = chapters[i + 1]
        end_time = next_ch.time or duration
      end

      skips[#skips + 1] = {
        type = skip_type,
        start = start_time,
        endt = end_time,
      }
      msg.info(string.format("Found built-in chapter skip: %s (%ds to %ds)", title, start_time, end_time))
    end
  end
  return skips
end

local function get_active_skip(position)
  for _, entry in ipairs(state.skips) do
    if position >= entry.start and position <= entry.endt then
      return entry
    end
  end
  return nil
end

state.skips = parse_skip_times(opts.skip_times)

local function refresh_shaders_state()
  local current_shaders = mp.get_property('glsl-shaders') or ''
  state.shaders_on = (current_shaders ~= '')
end

local function refresh_state()
  local w, h = mp.get_osd_size()
  state.width = w or 1280
  state.height = h or 720
  state.position = mp.get_property_number('time-pos') or 0
  state.duration = mp.get_property_number('duration') or 0
  state.active_skip = get_active_skip(state.position)
end

local function jump_to(time_pos)
  local duration = mp.get_property_number('duration') or 0
  if duration <= 0 then
    return
  end
  local clamped = math.max(0, math.min(duration, time_pos))
  mp.set_property_number('time-pos', clamped)
end

local function check_active_skip()
  if mp.get_property_native("seeking") then
    return false
  end
  local pos = mp.get_property_number('time-pos')
  if pos then
    state.position = pos
  end
  local dur = mp.get_property_number('duration')
  if dur and dur > 0 then
    state.duration = dur
  end
  local active = get_active_skip(state.position)
  if active ~= state.active_skip then
    state.active_skip = active
    if active and not active.notified then
      active.notified = true
      msg.info("check_active_skip: entering skip zone type=" .. active.type .. " at pos=" .. pos .. " (end=" .. active.endt .. "), autoskip=" .. get_autoskip_opt())
      local skip_label = active.type == 'ed' and 'Outro' or 'Intro'
      mp.osd_message(skip_label .. ' — Shift+S to skip', 3.0)
    end
    if active and get_autoskip_opt() == 'yes' then
      local skip_label = active.type == 'ed' and 'Outro' or 'Intro'
      jump_to(active.endt)
      mp.osd_message('Skipping ' .. skip_label, 1.5)
    end
    return true
  end
  return false
end

local function skip_current_segment()
  msg.info("skip_current_segment called, active_skip=" .. (state.active_skip and state.active_skip.type or "nil") .. " position=" .. (state.position or 0))
  local skip = state.active_skip
  if skip and skip.endt and skip.endt > state.position then
    msg.info("skip_current_segment: jumping to " .. skip.endt)
    jump_to(skip.endt)
    mp.osd_message('Skipped segment', 1.5)
  else
    msg.info("skip_current_segment: nothing to skip")
  end
end

-- Anime4K official "Mode A (Fast)" low-end preset — keep in sync with the
-- shader_names list in commands/playback.rs (the launch-time args).
local SHADERS = {
  "~~/shaders/Anime4K_Clamp_Highlights.glsl",
  "~~/shaders/Anime4K_Restore_CNN_M.glsl",
  "~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl",
  "~~/shaders/Anime4K_AutoDownscalePre_x2.glsl",
  "~~/shaders/Anime4K_AutoDownscalePre_x4.glsl",
  "~~/shaders/Anime4K_Upscale_CNN_x2_S.glsl",
}

-- mpv path-list options split on ";" on Windows and ":" on Unix (drive
-- letters collide with ":") -- same reason the launch-time --glsl-shaders arg
-- in commands/playback.rs picks its separator per-OS. package.config's first
-- line is the platform's directory separator ("\\" on Windows, "/" elsewhere),
-- so it doubles as a reliable OS check without shelling out.
local PATH_LIST_SEP = (package.config:sub(1, 1) == '\\') and ';' or ':'

local function enable_standard_shaders()
  mp.commandv("change-list", "glsl-shaders", "set", table.concat(SHADERS, PATH_LIST_SEP))
  refresh_shaders_state()
end

local function enable_shaders()
  enable_standard_shaders()
end

local function disable_shaders()
  mp.commandv("set", "glsl-shaders", "")
  refresh_shaders_state()
end

-- Bring mpv in line with the app's stored shader_profile, sent by the backend
-- at the start of every episode a reused mpv plays. Compared against the live
-- property first because writing glsl-shaders rebuilds the render graph even
-- when the value is unchanged -- and unchanged is the normal case, since
-- Ctrl+1 already writes its flip back to config. The case this exists for is
-- the setting being changed in Settings while mpv is open: only the launch
-- path applied it, so the running player kept the old graph for the rest of
-- the session.
local function set_shader_profile(profile)
  local want_on = profile ~= nil and profile ~= '' and profile ~= 'off'
  local current_on = (mp.get_property('glsl-shaders') or '') ~= ''
  if want_on == current_on then
    return
  end
  msg.info("set_shader_profile: '" .. tostring(profile) .. "' -> upscaling "
    .. (want_on and "on" or "off"))
  if want_on then
    enable_standard_shaders()
  else
    disable_shaders()
  end
end

-- Forward declaration: notify_backend is defined further down (it needs
-- `state`, which is already in scope by here, but its own definition sits
-- after these toggle functions in file order). Lua resolves `local`
-- upvalues lexically at closure-creation time, so without this the toggle
-- functions below would silently capture a stale nil instead of the real
-- function once notify_backend is assigned.
local notify_backend

-- Ctrl+1: toggle upscaling on/off. Also persists the flip into the app's
-- actual config (via the backend) so Settings and the detail-page toggle
-- reflect it too, not just mpv's current session.
local function toggle_shaders()
  local current = mp.get_property('glsl-shaders') or ''
  if current == '' then
    enable_standard_shaders()
    mp.osd_message("Upscaling: Enabled", 2.0)
  else
    disable_shaders()
    mp.osd_message("Upscaling: Disabled", 2.0)
  end
  notify_backend("toggle-upscale")
end

-- Shift+V: sideways mode. --video-rotate spins only the video plane, leaving
-- libass subs on the unrotated OSD (sideways/squished subs). The `sub` video
-- filter instead bakes subtitle rendering into the frames BEFORE the
-- transpose, so subs rotate with the picture — hardsubs at playback time,
-- works with any softsub release. Session-only on purpose: it tracks how the
-- screen is physically turned right now, not a per-show preference.
--
-- Hardware decode must be off while sideways: with videotoolbox frames the
-- `sub` filter silently claims subtitle rendering without drawing anything
-- (subs vanish) and lavfi fails to configure entirely ("Impossible to
-- convert between the formats"), so the transpose is dropped too. Verified
-- on mpv 0.41/macOS. Software decode of anime is cheap; hwdec is restored
-- when leaving sideways mode.
local sideways_state = 0 -- 0 = off, 1 = 90 CW, 2 = 90 CCW
local sideways_saved_hwdec = nil
local function toggle_sideways()
  sideways_state = (sideways_state + 1) % 3
  if sideways_state == 1 then
    sideways_saved_hwdec = mp.get_property('hwdec')
    mp.set_property('hwdec', 'no')
  end
  if sideways_state == 0 then
    mp.commandv('vf', 'clr', '')
    if sideways_saved_hwdec then
      mp.set_property('hwdec', sideways_saved_hwdec)
      sideways_saved_hwdec = nil
    end
    mp.osd_message('Sideways: Off', 2.0)
  elseif sideways_state == 1 then
    mp.commandv('vf', 'set', 'sub,lavfi=[transpose=clock]')
    mp.osd_message('Sideways: 90 CW', 2.0)
  else
    mp.commandv('vf', 'set', 'sub,lavfi=[transpose=cclock]')
    mp.osd_message('Sideways: 90 CCW', 2.0)
  end
end

local function render(force)
  if not state.file_loaded then
    state.overlay:remove()
    return
  end

  local w, h = mp.get_osd_size()
  w = w or 1280
  h = h or 720

  if w ~= state.width or h ~= state.height then
    state.width = w
    state.height = h
    force = true
  end

  local active_changed = check_active_skip()

  if not force and not active_changed then
    return
  end

  if w <= 0 or h <= 0 then
    return
  end

end

local function render_forced()
  render(true)
end

local function render_unforced()
  render(false)
end

-- Mouse clicks handled by ModernZ OSC and keyboard shortcuts

local function set_auto_next(val)
  opts.auto_next = val
  -- "append" updates just this key. "set" would replace the entire script-opts
  -- map, wiping current_episode/total_episodes/skip_times and breaking the
  -- next/prev guards that read them.
  mp.commandv("change-list", "script-opts", "append", "anicat_ui-auto_next=" .. val)
  render(true)
end

-- Ctrl+4: toggle auto-play-next. Persists into the real config (like the
-- other Ctrl+number toggles above) so Settings reflects it too, instead of
-- resetting to whatever Settings said every time an episode launches.
local function toggle_auto_next()
  local current = get_auto_next_opt()
  if current == 'yes' then
    set_auto_next('no')
    mp.osd_message('Auto-play next: Off', 1.5)
  else
    set_auto_next('yes')
    mp.osd_message('Auto-play next: On', 1.5)
  end
  notify_backend("toggle-auto-next")
end

local function set_autoskip(val)
  opts.autoskip = val
  -- "append" like set_auto_next above so the rest of the script-opts map
  -- (current_episode/total_episodes/skip_times) survives the update.
  mp.commandv("change-list", "script-opts", "append", "anicat_ui-autoskip=" .. val)
end

local function toggle_autoskip()
  local current = get_autoskip_opt()
  if current == 'yes' then
    set_autoskip('no')
    mp.osd_message('Auto-skip intro: Off', 1.5)
  else
    set_autoskip('yes')
    mp.osd_message('Auto-skip intro: On', 1.5)
  end
  notify_backend("toggle-autoskip")
end

notify_backend = function(action, sync, manual)
  local pos = mp.get_property_number('time-pos')
  if not pos or pos <= 0 then
    pos = state.last_pos or state.position or 0
  end
  local duration = state.duration or 0
  local url = "http://127.0.0.1:" .. get_proxy_port_opt() .. "/player/" .. action
    .. "?pos=" .. math.floor(pos) .. "&duration=" .. math.floor(duration)
  if manual then
    url = url .. "&manual=true"
  end
  if action == "loaded" then
    -- What actually opened. Both halves come from script-opts, which the
    -- backend set in the same IPC batch as the loadfile, so they name what mpv
    -- was asked for -- and this is only ever sent when the open succeeded.
    --
    -- The media id is reported rather than looked up on the other side because
    -- the backend's own record of it is written a moment after the batch is
    -- sent: reading it there would race this callback, and losing that race
    -- would look exactly like a transition that never happened.
    url = url .. "&episode=" .. get_current_episode_opt()
      .. "&media_id=" .. get_media_id_opt()
  end
  msg.info("notify_backend called: action=" .. tostring(action) .. ", url=" .. url .. ", sync=" .. tostring(sync) .. ", manual=" .. tostring(manual))
  
  -- curl ships in System32 on modern Windows and in the base system on
  -- macOS/Linux. The whole progress pipeline (resume position, watched
  -- detection, AniList advancement) depends on these callbacks reaching the
  -- backend, so keep this on the simple, reliable curl path everywhere.
  local cmd = {
    name = "subprocess",
    args = { "curl", "-s", url },
    capture_stdout = false,
    capture_stderr = false
  }

  -- mpv reports a subprocess that ran and exited nonzero as a *success*: the
  -- command did what it was asked. curl's exit code lands in `result.status`,
  -- and nothing used to read it -- so a callback going to a port nothing was
  -- listening on (curl exit 7) looked identical to one that worked, and the
  -- whole progress pipeline could be dead with no message anywhere. Report the
  -- exit code, not just whether mpv managed to launch curl.
  local function report(success, result, err)
    if not success then
      msg.error("Failed to notify backend: " .. tostring(err or "unknown error"))
      mp.osd_message('AniCat connection failed.', 3.0)
      return
    end
    local status = type(result) == "table" and result.status or 0
    if status ~= 0 then
      msg.error(string.format(
        "Backend callback '%s' failed: curl exited %s for %s", tostring(action), tostring(status), url))
      mp.osd_message('AniCat connection failed.', 3.0)
    end
  end

  if sync then
    local ok, result = pcall(mp.command_native, cmd)
    report(ok, result, ok and nil or result)
  else
    mp.command_native_async(cmd, function(success, result, error)
      report(success, result, error)
    end)
  end
end



local next_timeout = nil

-- The nyaa (torrent) provider's resolve can legitimately take up to ~85s
-- worst case: a 45s metadata-init timeout plus a 40s pre-buffer timeout
-- (see INIT_TIMEOUT / PREBUFFER_TIMEOUT in torrent/mod.rs). The old 12s
-- timeout fired long before a cold torrent resolve could finish, flipping
-- next_triggered back to false and showing a false "failed" message while
-- the real backend request was still in flight — a second button press at
-- that point raced the original request instead of just waiting on it.
local NEXT_TIMEOUT_SECS = 100

local function arm_next_timeout(fallback_message)
  if next_timeout then
    next_timeout:kill()
    next_timeout = nil
  end
  next_timeout = mp.add_timeout(NEXT_TIMEOUT_SECS, function()
    -- `state.next_triggered` alone is the right condition, and the
    -- `not state.file_loaded` that used to sit beside it was the bug: during a
    -- transition the *outgoing* episode is still loaded, because nothing has
    -- reached mpv yet. So on the case this timer exists for -- the backend
    -- taking longer than the window, or never answering -- the callback
    -- no-op'd. The OSD text simply expired at its own duration and the player
    -- sat there with no message and no episode, for as long as the resolve
    -- chain kept running. A successful transition can't reach here: file-loaded
    -- clears next_triggered and kills this timer.
    if state.next_triggered then
      state.next_triggered = false
      msg.warn(string.format(
        'transition still unresolved after %ds; releasing the retry guard', NEXT_TIMEOUT_SECS))
      mp.osd_message(fallback_message or 'Still loading. Press N to retry.', 6.0)
    end
  end)
end

local function play_next(sync, manual)
  if manual == nil then
    manual = true
  end
  local current_ep = get_current_episode_opt()
  local total_eps = get_total_episodes_opt()
  if total_eps > 0 and current_ep >= total_eps then
    -- There's no next episode to load, but the one that just finished still
    -- needs its final position recorded — every other transition (stop/prev/
    -- a mid-series next) does this via notify_backend, but this early return
    -- used to skip it entirely. The fallbacks that could otherwise catch it
    -- (the pause-property observer, the mpv-exit monitor) are racy: end-file
    -- can flip state.file_loaded to false before the pause event fires,
    -- silently skipping that notification too. Record explicitly (sync, so
    -- it lands before the OSD/return) instead of trusting that chain.
    --
    -- Guard the re-entry with a flag of its own: this branch returns without
    -- setting next_triggered, so on the last episode every pause event and
    -- every eof-reached flip re-entered check_near_end_auto_next and landed
    -- back here — firing a *synchronous* curl on the mpv thread (a visible
    -- hitch) and re-showing the OSD, over and over while the finished episode
    -- sat on its last frame. next_triggered can't be that flag: end-file reads
    -- it to decide whether to print the "Playback finished" hint, and no
    -- further file-loaded ever clears it here, so reusing it would silence
    -- that hint exactly when it matters.
    --
    -- The guard is on the *work*, not on the whole branch. It used to return
    -- before the OSD too, which meant the auto-next poll -- firing a second
    -- after the episode ends, before the viewer has touched anything -- burned
    -- the one message this branch ever showed. Pressing N after that did
    -- nothing at all, with no OSD and nothing in the log: the key looked
    -- broken at exactly the moment someone was checking whether the show had
    -- more.
    if not state.end_reported then
      state.end_reported = true
      notify_backend("stop", true)
    end
    if manual then
      -- Ask the backend even though the answer is known to be "no next
      -- episode". It owns the one thing worth saying here -- whether AniList
      -- knows a sequel -- and replies straight onto the OSD. That reply was
      -- previously unreachable for any show whose episode count is known,
      -- because this branch returned before anything asked.
      state.next_triggered = true
      arm_next_timeout('Already at the last episode.')
      notify_backend("next", nil, true)
    else
      -- The auto path must not: it re-enters every second while the finished
      -- episode sits on its last frame, and each entry would be another
      -- request and another OSD.
      mp.osd_message('Already at the last episode.', 3.0)
    end
    return
  end

  state.next_triggered = true
  -- Not "No more episodes available." -- this fires when the transition ran
  -- out of time, which says nothing about whether the show has more episodes.
  -- The backend sends its own, more specific reason when it knows one (see
  -- `transition_failure_message`); this is only for the case where it never
  -- answered at all.
  arm_next_timeout('Still loading the next episode. Press N to retry.')
  -- Held for as long as arm_next_timeout's own window (a cold torrent
  -- resolve can legitimately take most of that), not the old fixed 3s --
  -- that expired long before a slow transition finished, leaving the user
  -- staring at the outgoing episode's last frame with no indication
  -- anything was still happening. Reported as "auto-next didn't do
  -- anything" followed by a manual press that (correctly, per already-
  -- updated backend state) skipped straight past the episode that *was*
  -- loading. file-loaded clears this the moment the new episode actually
  -- appears, so it never lingers once there's something to show instead.
  -- Deliberately longer than the timer that replaces it: at exactly
  -- NEXT_TIMEOUT_SECS the two race, and the message losing means a blank
  -- player. file-loaded clears this the moment there's something to show.
  mp.osd_message('Loading next episode...', NEXT_TIMEOUT_SECS + 10)
  notify_backend("next", sync, manual)
end

local function play_prev(sync)
  local current_ep = get_current_episode_opt()
  if current_ep <= 1 then
    mp.osd_message('Already at the first episode.', 3.0)
    return
  end

  state.next_triggered = true
  arm_next_timeout('Still loading the previous episode. Press P to retry.')
  mp.osd_message('Loading previous episode...', NEXT_TIMEOUT_SECS + 10)
  notify_backend("prev", sync)
end

-- Shift+R. input.conf has always bound this to `anicat-reload-episode`, but
-- nothing ever registered that message name, so the key did nothing. Reload
-- the same URL in place and resume where it was: enough to recover a stalled
-- HLS segment or a torrent read that gave up, without a round-trip through
-- the backend (which would re-resolve the stream and drop the mpv window).
local function reload_episode()
  local path = mp.get_property('path')
  if not path or path == '' then
    mp.osd_message('Nothing to reload.', 2.0)
    return
  end
  local pos = math.floor(mp.get_property_number('time-pos') or state.last_pos or 0)
  mp.osd_message('Reloading episode...', 2.0)
  mp.commandv('loadfile', path, 'replace', '0', 'start=' .. pos)
end

local function toggle_translation()
  mp.osd_message("Switching Translation (Sub/Dub)...", 3.0)
  notify_backend("toggle-translation")
end

-- eof-reached only goes true once the decoder actually runs out of data.
-- Seeking/skipping straight to (or past) the last position lands mpv on the
-- last frame without ever decoding through to real end-of-stream, so
-- eof-reached stays false. Treat "settled within a hair of duration" as
-- done too, regardless of that flag or whether playback is paused — this is
-- what lets auto-next fire while the user is scrubbing/skipping through the
-- end of an episode instead of only on a clean pause-at-end.
-- An episode has to have actually played before "it ended" is believable.
-- eof-reached goes true whenever the demuxer runs out of data, including when
-- a stream dies the moment it opens — and at that point position is ~0 while
-- duration is already known from the container header. Auto-next honoured that
-- as a finished episode and advanced, so a broken stream silently *skipped*
-- the episode rather than reporting a failure. Half the runtime is far below
-- the 85% watched threshold, so this never blocks a genuine ending, including
-- one reached by seeking.
local MIN_PLAYED_FRACTION = 0.5

local function check_near_end_auto_next()
  if state.is_shutting_down or not state.file_loaded or state.next_triggered then
    return
  end
  if get_auto_next_opt() ~= 'yes' then
    return
  end
  local pos = mp.get_property_number('time-pos')
  local dur = mp.get_property_number('duration')
  -- Unknown duration means there is no way to tell a finished episode from a
  -- dead stream, so don't advance on guesswork.
  if not pos or not dur or dur <= 0 then
    return
  end
  local eof = mp.get_property_native('eof-reached')
  if pos < dur * MIN_PLAYED_FRACTION then
    if eof and not state.early_eof_reported then
      state.early_eof_reported = true
      msg.warn(string.format(
        'end-of-file at %.1fs of %.1fs — treating as a failed stream, not a finished episode', pos, dur))
      mp.osd_message('Stream ended early. Shift+R to reload, or pick another source.', 5.0)
    end
    return
  end
  if eof or (dur - pos) < 1.5 then
    play_next(nil, false)
  end
end



local function register_script_messages()
  if not mp.register_script_message then
    return
  end
  mp.register_script_message('anicat-skip-intro', skip_current_segment)
  mp.register_script_message('anicat-toggle-upscale', enable_shaders)
  mp.register_script_message('anicat-disable-upscale', disable_shaders)
  mp.register_script_message('anicat-toggle-shaders', toggle_shaders)
  mp.register_script_message('anicat-set-shader-profile', set_shader_profile)
  mp.register_script_message('anicat-set-auto-next', set_auto_next)
  mp.register_script_message('anicat-toggle-auto-next', toggle_auto_next)
  mp.register_script_message('anicat-toggle-autoskip', toggle_autoskip)
  mp.register_script_message('anicat-toggle-sideways', toggle_sideways)
  mp.register_script_message('anicat-next-episode', play_next)
  mp.register_script_message('anicat-previous-episode', play_prev)
  mp.register_script_message('anicat-toggle-translation', toggle_translation)
  mp.register_script_message('anicat-reload-episode', reload_episode)
  mp.register_script_message('anicat-cancel-next', function()
    state.next_triggered = false
  end)

  -- Force bind action keys directly so other scripts / user input.conf can't
  -- shadow the AniCat next/prev/skip bindings.
  if mp.add_forced_key_binding then
    mp.add_forced_key_binding('N', 'anicat-next-key', function() play_next(nil, true) end)
    mp.add_forced_key_binding('P', 'anicat-prev-key', function() play_prev(nil) end)
    mp.add_forced_key_binding('S', 'anicat-skip-shifts', skip_current_segment)
  end
end

-- Rebuffer runway for a torrent stream, restored once playback is under way.
--
-- The backend launches torrent streams with a much shorter cache-pause-wait
-- (see is_torrent_stream in commands/playback.rs) because mpv reuses that one
-- number for two unrelated jobs: the initial cache-pause-initial gate, where
-- 30s of media is ~19MB and a thin swarm spends a minute frozen on the first
-- frame earning it, and the mid-playback rebuffer, where resuming too early
-- is what produced the old play/freeze/play stutter loop. Only the startup
-- gate needs the small value, and it has done its job the moment frames are
-- actually moving -- so put the generous one back here. Keep this in step
-- with the launch-side constant; they are a pair.
local TORRENT_REBUFFER_WAIT = 30
-- Seconds of *elapsed* playback, not an absolute position: an episode resumed
-- at 10:00 opens with time-pos already there, and an absolute threshold would
-- hand over before a single frame had actually been played. Measured from the
-- first position seen after file-loaded, and time-pos only advances while
-- frames move -- a file still sitting behind the initial cache gate never
-- reaches it.
local REBUFFER_HANDOVER_SECS = 3

local function restore_rebuffer_wait(pos)
  if state.rebuffer_wait_restored or not pos then
    return
  end
  -- Both loadfile branches set cache-pause-initial explicitly (torrent yes,
  -- everything else no), so it reads as a reliable "is this episode coming
  -- off the torrent proxy" marker even on an mpv process that launched on a
  -- stream of the other kind.
  if not mp.get_property_bool('cache-pause-initial') then
    state.rebuffer_wait_restored = true
    return
  end
  if not state.rebuffer_baseline then
    state.rebuffer_baseline = pos
    return
  end
  if pos - state.rebuffer_baseline < REBUFFER_HANDOVER_SECS then
    return
  end
  state.rebuffer_wait_restored = true
  mp.set_property_number('cache-pause-wait', TORRENT_REBUFFER_WAIT)
  msg.info('playback under way: cache-pause-wait raised to ' .. TORRENT_REBUFFER_WAIT)
end

mp.observe_property('time-pos', 'number', function(name, val)
  if val and val > 0 then
    state.last_pos = val
    state.position = val
  end
  restore_rebuffer_wait(val)
  render_unforced()
end)
mp.observe_property('duration', 'number', render_unforced)
mp.observe_property('mouse-pos', 'native', render_unforced)
mp.observe_property('seeking', 'native', render_unforced)
mp.observe_property('script-opts', 'native', function()
  if state.file_loaded then
    -- The background AniSkip resolver pushes skip_times here well after
    -- file-loaded already ran merge_skips once; redo the same merge (not the
    -- old ad-hoc start-time proximity check) so chapter-sourced entries keep
    -- winning and every entry still carries its source tag for autoskip.
    local skips = merge_skips(parse_skip_times(get_skip_times_opt()), parse_chapters_for_skips())
    state.skips = skips
    msg.info("script-opts updated: total skip segments = " .. #skips)
  end
  render(true)
end)
mp.observe_property('glsl-shaders', 'string', function()
  refresh_shaders_state()
  render(true)
end)

-- Some BD/batch releases bundle a "signs & songs only" subtitle track
-- (on-screen text translations, meant to run alongside dub audio) *and* the
-- full dialogue subtitle tracks, but flag the signs-only one "default" in
-- the container. mpv's own auto-selection honors that flag over anything
-- else that matches --slang, so the signs-only track wins outright and
-- dialogue scenes play with no subtitles at all -- reported on Chivalry of a
-- Failed Knight: "subtitles but partly" (only signs/songs show, no dialogue
-- lines). mpv has no option to deprioritize a default-flagged forced track
-- in favor of a non-forced one with equal language match, so this corrects
-- it after mpv's own selection has already run.
local function fixup_forced_subtitle_track()
  local sid = mp.get_property_number('sid')
  if not sid then return end
  local tracks = mp.get_property_native('track-list')
  if not tracks then return end
  local current, candidates = nil, {}
  for _, t in ipairs(tracks) do
    if t.type == 'sub' then
      if t.id == sid then current = t end
      table.insert(candidates, t)
    end
  end
  if not current then return end
  local title = (current.title or ''):lower()
  local looks_signs_only = current.forced
    and (title:find('sign') or title:find('song'))
  if not looks_signs_only then return end
  for _, t in ipairs(candidates) do
    local t_title = (t.title or ''):lower()
    if t.id ~= current.id and not t.forced
      and not t_title:find('sign') and not t_title:find('song') then
      msg.info("fixup_forced_subtitle_track: swapping sid " .. current.id
        .. " ('" .. (current.title or '') .. "', forced signs/songs-only) for sid "
        .. t.id .. " ('" .. (t.title or '') .. "')")
      mp.set_property('sid', tostring(t.id))
      return
    end
  end
end

mp.register_event('file-loaded', function()
  state.file_loaded = true
  state.first_play = true
  state.next_triggered = false
  state.preload_sent = false
  state.end_reported = false
  state.early_eof_reported = false
  -- Each episode arrives with the short startup gate re-applied (a fresh
  -- launch via CLI args, an auto-next via loadfile's per-file options), so
  -- the handover has to re-arm per file rather than once per process.
  state.rebuffer_wait_restored = false
  state.rebuffer_baseline = nil
  state.duration = mp.get_property_number('duration') or 0
  -- Tell the backend the file really opened. Sending the loadfile only proves
  -- the bytes reached mpv's socket; this is the half that proves mpv acted on
  -- them, and without it a transition that failed here advanced the episode
  -- counter anyway and silently skipped an episode on the next press.
  notify_backend("loaded")
  fixup_forced_subtitle_track()
  -- Dismiss the "Loading next/previous episode..." message the moment
  -- there's something new to look at instead, rather than leaving it to
  -- run out its own (now much longer) timeout.
  mp.osd_message('', 0)
  -- Belt-and-suspenders against a real ordering hazard: the backend's
  -- IPC batch queues `set_property pause false` right after `loadfile`,
  -- but `loadfile` only queues the open -- it doesn't wait for the file to
  -- actually be ready -- so that unpause can execute before keep-open's
  -- auto-pause-at-the-previous-file's-EOF has been superseded by this new
  -- file, landing the episode paused on its first frame. Once file-loaded
  -- fires the file is unambiguously current, so force it here too.
  mp.set_property_bool('pause', false)
  if next_timeout then
    next_timeout:kill()
    next_timeout = nil
  end
  
  local skips = parse_skip_times(get_skip_times_opt())
  skips = merge_skips(skips, parse_chapters_for_skips())

  state.skips = skips
  msg.info("file-loaded: total skip segments = " .. #skips)
  for _, s in ipairs(skips) do
    s.notified = false
    msg.info("  skip: type=" .. s.type .. " start=" .. s.start .. " end=" .. s.endt)
  end
  refresh_shaders_state()
  render(true)
end)

mp.register_event('end-file', function(event)
  state.file_loaded = false
  state.overlay:remove()
  if not state.next_triggered then
    mp.osd_message('Playback finished. Press Q or close the window to return to Anicat.', 5)
  end
end)

-- Once we're most of the way through, ask the backend to resolve the next
-- episode's stream ahead of time so auto-next is instant. One-shot per file.
-- Checked both on the 30s progress tick (normal playback) and right after a
-- seek settles (skipping/scrubbing straight past the 85% mark shouldn't have
-- to wait on the next timer tick to start warming the next episode).
local function check_preload()
  if state.preload_sent or get_auto_next_opt() ~= 'yes' then
    return
  end
  local pos = mp.get_property_number('time-pos') or 0
  local dur = mp.get_property_number('duration') or 0
  if dur > 0 and pos / dur >= 0.85 then
    local cur = get_current_episode_opt()
    local total = get_total_episodes_opt()
    if total <= 0 or cur < total then
      state.preload_sent = true
      notify_backend("preload")
    end
  end
end

mp.register_event('playback-restart', function()
  if state.file_loaded then
    if state.first_play then
      state.first_play = false
      state.active_skip = nil
      render(true)
    else
      -- Fires after a seek settles: report the new position so the backend
      -- (and Discord countdown) re-anchor immediately instead of drifting
      -- until the next periodic progress tick.
      notify_backend("progress")
      -- Auto-next is checked before the preload, and the preload is skipped
      -- once it has fired. During normal playback these are minutes apart --
      -- the preload warms the next episode at 85% and auto-next consumes it
      -- at the end -- but a seek past the end runs both in the same event,
      -- microseconds apart. In that order the preload claimed the next
      -- episode a moment before the transition asked for it, so the backend
      -- spent the transition polling for a resolve that had no head start on
      -- the one it would otherwise have run itself.
      check_near_end_auto_next()
      if not state.next_triggered then
        check_preload()
      end
    end
  end
end)

-- Periodically report playback position to Rust backend for crash recovery.
-- Skipped while paused: position can't have changed, so a paused/idle mpv
-- window (which can sit for a long time) would otherwise ping the backend
-- with the same stale pos/duration every 30s indefinitely.
local progress_timer = mp.add_periodic_timer(30, function()
  if mp.get_property_native("pause") then
    return
  end
  notify_backend("progress")
  check_preload()
end)

-- Every other trigger for the near-end check is an mpv event that fires only
-- once mpv *finishes* something: eof-reached needs the decoder to run out of
-- data at a real end-of-stream, playback-restart needs a seek to settle into
-- playback, and the pause observer needs a user pause. Skipping to the end of
-- a torrent stream is the case where none of the three ever arrives, because
-- the tail of the file has not been downloaded yet and the seek it needs
-- simply never completes.
--
-- Measured against mpv over an HTTP source that serves the first 60% of a
-- file and then stops, which is what a torrent stream looks like to mpv while
-- its tail pieces are missing. Seeking to 59.6s of a 60.0s file and reading
-- the properties once a second for eight seconds:
--
--   time-pos 59.6  duration 60.023  seeking true
--   eof-reached false   pause false   paused-for-cache false
--
-- unchanged on every sample. So `seeking` never clears (no playback-restart),
-- the decoder never reaches end-of-stream (no eof-reached), and `pause` stays
-- false the whole time -- but `time-pos` does report the seek target
-- immediately, so the position says the episode is over even though mpv is
-- still trying to get there. Polling reads exactly that, which is why it
-- advances where the events cannot. The check's own guards (not loaded,
-- already triggered, auto-next off, unknown duration) make a tick with
-- nothing to do free.
local near_end_timer = mp.add_periodic_timer(1, check_near_end_auto_next)

mp.register_event('shutdown', function()
  state.is_shutting_down = true
  progress_timer:stop()
  near_end_timer:stop()
  notify_backend("stop", true)
end)

mp.observe_property('eof-reached', 'bool', function(name, val)
  if val then
    check_near_end_auto_next()
  end
end)

mp.observe_property('pause', 'bool', function(name, val)
  if state.file_loaded then
    local action = val and "pause" or "resume"
    notify_backend(action)
  end
  if val then
    check_near_end_auto_next()
  end
end)

register_script_messages()

msg.info('Anicat overlay loaded: ctrl+1 = Toggle Upscaling')
