local mp = mp
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
  skip_times = '',
  auto_next = 'no',
  autoskip = 'yes',
  current_episode = 0,
  total_episodes = 0,
  shader_profile = 'eco',
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

local function match_skip_type(title)
  title = (title or ''):lower()
  
  if title:find('intro') or title:find('opening') then
    return 'op'
  end
  
  if title:find('ending') or title:find('outro') or title:find('credits') then
    return 'ed'
  end
  
  if title == 'op' or title:find('^op%s') or title:find('^op%d') or title:find('%sop%s') or title:find('%sop%d') or title:find('%sop$') then
    return 'op'
  end

  if title == 'ed' or title:find('^ed%s') or title:find('^ed%d') or title:find('%sed%s') or title:find('%sed%d') or title:find('%sed$') then
    return 'ed'
  end
  
  return nil
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

  for i, chapter in ipairs(chapters) do
    local title = chapter.title or ''
    local skip_type = match_skip_type(title)
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

local function enable_standard_shaders()
  mp.commandv("change-list", "glsl-shaders", "set", table.concat(SHADERS, ":"))
  refresh_shaders_state()
end

local function enable_shaders()
  enable_standard_shaders()
end

local function disable_shaders()
  mp.commandv("set", "glsl-shaders", "")
  refresh_shaders_state()
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
  local url = "http://127.0.0.1:13370/player/" .. action .. "?pos=" .. math.floor(pos) .. "&duration=" .. math.floor(duration)
  if manual then
    url = url .. "&manual=true"
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

  if sync then
    local ok, err = pcall(mp.command_native, cmd)
    if not ok then
      msg.error("Failed to notify backend (sync): " .. tostring(err))
      mp.osd_message('AniCat connection failed.', 3.0)
    end
  else
    mp.command_native_async(cmd, function(success, result, error)
      if not success then
        msg.error("Failed to notify backend: " .. (error or "unknown error"))
        mp.osd_message('AniCat connection failed.', 3.0)
      end
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
    if state.next_triggered and not state.file_loaded then
      state.next_triggered = false
      mp.osd_message(fallback_message or 'Failed to load episode.', 3.0)
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
    notify_backend("stop", true)
    mp.osd_message('Already at the last episode.', 3.0)
    return
  end

  state.next_triggered = true
  arm_next_timeout('No more episodes available.')
  mp.osd_message('Loading next episode...', 3.0)
  notify_backend("next", sync, manual)
end

local function play_prev(sync)
  local current_ep = get_current_episode_opt()
  if current_ep <= 1 then
    mp.osd_message('Already at the first episode.', 3.0)
    return
  end

  state.next_triggered = true
  arm_next_timeout('Failed to load previous episode.')
  mp.osd_message('Loading previous episode...', 3.0)
  notify_backend("prev", sync)
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
local function check_near_end_auto_next()
  if not state.file_loaded or state.next_triggered then
    return
  end
  if get_auto_next_opt() ~= 'yes' then
    return
  end
  local pos = mp.get_property_number('time-pos')
  local dur = mp.get_property_number('duration')
  local near_end = pos and dur and dur > 0 and (dur - pos) < 1.5
  if mp.get_property_native('eof-reached') or near_end then
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
  mp.register_script_message('anicat-set-auto-next', set_auto_next)
  mp.register_script_message('anicat-toggle-auto-next', toggle_auto_next)
  mp.register_script_message('anicat-toggle-autoskip', toggle_autoskip)
  mp.register_script_message('anicat-toggle-sideways', toggle_sideways)
  mp.register_script_message('anicat-next-episode', play_next)
  mp.register_script_message('anicat-previous-episode', play_prev)
  mp.register_script_message('anicat-toggle-translation', toggle_translation)
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

mp.observe_property('time-pos', 'number', function(name, val)
  if val and val > 0 then
    state.last_pos = val
    state.position = val
  end
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

mp.register_event('file-loaded', function()
  state.file_loaded = true
  state.first_play = true
  state.next_triggered = false
  state.preload_sent = false
  state.duration = mp.get_property_number('duration') or 0
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
      check_preload()
      check_near_end_auto_next()
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

mp.register_event('shutdown', function()
  progress_timer:stop()
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
