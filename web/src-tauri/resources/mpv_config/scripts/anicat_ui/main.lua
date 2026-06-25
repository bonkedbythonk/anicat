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
  local active = get_active_skip(pos)
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

-- Ctrl+1: toggle upscaling on/off (session only, no config write)
local function toggle_shaders()
  local current = mp.get_property('glsl-shaders') or ''
  if current == '' then
    enable_standard_shaders()
    mp.osd_message("Upscaling: On  (temp — settings unchanged)", 2.0)
  else
    disable_shaders()
    mp.osd_message("Upscaling: Off  (temp — settings unchanged)", 2.0)
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
  mp.commandv("change-list", "script-opts", "set", "anicat_ui-auto_next=" .. val)
  render(true)
end

local function toggle_auto_next()
  local current = get_auto_next_opt()
  if current == 'yes' then
    set_auto_next('no')
    mp.osd_message('Auto-play next: Off', 1.5)
  else
    set_auto_next('yes')
    mp.osd_message('Auto-play next: On', 1.5)
  end
end

local function notify_backend(action, sync, manual)
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
    mp.command_native(cmd)
  else
    mp.command_native_async(cmd, function(success, result, error)
      if not success then
        msg.error("Failed to notify backend: " .. (error or "unknown error"))
      end
    end)
  end
end

-- "Up Next" countdown state, declared early so the navigation paths below can
-- cancel a running countdown before they act.
local UP_NEXT_SECONDS = 5
local up_next_timer = nil

local function stop_up_next()
  if up_next_timer then
    up_next_timer:kill()
    up_next_timer = nil
  end
  if mp.remove_key_binding then
    pcall(mp.remove_key_binding, 'anicat-upnext-now')
    pcall(mp.remove_key_binding, 'anicat-upnext-cancel')
  end
end

local function play_next(sync, manual)
  if manual == nil then
    manual = true
  end
  stop_up_next()
  local current_ep = get_current_episode_opt()
  local total_eps = get_total_episodes_opt()
  if total_eps > 0 and current_ep >= total_eps then
    mp.osd_message('Already at the last episode.', 3.0)
    return
  end

  state.next_triggered = true
  mp.osd_message('Loading next episode...', 3.0)
  notify_backend("next", sync, manual)
end

local function play_prev(sync)
  stop_up_next()
  local current_ep = get_current_episode_opt()
  if current_ep <= 1 then
    mp.osd_message('Already at the first episode.', 3.0)
    return
  end

  state.next_triggered = true
  mp.osd_message('Loading previous episode...', 3.0)
  notify_backend("prev", sync)
end

local function toggle_translation()
  mp.osd_message("Switching Translation (Sub/Dub)...", 3.0)
  notify_backend("toggle-translation")
end

-- "Up Next" countdown shown at the end of an episode before auto-advancing, so
-- the jump isn't abrupt and can be skipped or cancelled. Paired with the
-- backend stream preload, the actual load is instant once the countdown ends.
-- (UP_NEXT_SECONDS / up_next_timer / stop_up_next are declared above play_next.)
local function advance_now()
  stop_up_next()
  play_next(nil, false)
  -- Clear a stuck "Loading next episode" if nothing loads within 10s.
  mp.add_timeout(10, function()
    if state.next_triggered and not state.file_loaded then
      state.next_triggered = false
      mp.osd_message('No more episodes available.', 3.0)
    end
  end)
end

local function start_up_next_countdown()
  local current_ep = get_current_episode_opt()
  local total_eps = get_total_episodes_opt()
  if total_eps > 0 and current_ep >= total_eps then
    state.next_triggered = false
    mp.osd_message('No more episodes available.', 3.0)
    return
  end
  local next_ep = current_ep + 1
  state.next_triggered = true

  if mp.add_forced_key_binding then
    mp.add_forced_key_binding('ENTER', 'anicat-upnext-now', advance_now)
    mp.add_forced_key_binding('ESC', 'anicat-upnext-cancel', function()
      stop_up_next()
      state.next_triggered = false
      mp.osd_message('Auto-play cancelled', 2.0)
    end)
  end

  local remaining = UP_NEXT_SECONDS
  local function tick()
    if remaining <= 0 then
      advance_now()
      return
    end
    mp.osd_message(string.format('Up Next: Episode %d in %ds     [Enter] play now     [Esc] cancel', next_ep, remaining), 1.5)
    remaining = remaining - 1
  end
  tick()
  up_next_timer = mp.add_periodic_timer(1, tick)
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
  mp.register_script_message('anicat-next-episode', play_next)
  mp.register_script_message('anicat-previous-episode', play_prev)
  mp.register_script_message('anicat-toggle-translation', toggle_translation)
  mp.register_script_message('anicat-cancel-next', function()
    stop_up_next()
    state.next_triggered = false
  end)

  -- Force bind the skip keys directly in the player
  if mp.add_forced_key_binding then
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
    local skips = parse_skip_times(get_skip_times_opt())
    local chapter_skips = parse_chapters_for_skips()
    for _, cs in ipairs(chapter_skips) do
      local duplicate = false
      for _, s in ipairs(skips) do
        if math.abs(s.start - cs.start) < 2.0 then
          duplicate = true
          break
        end
      end
      if not duplicate then
        skips[#skips + 1] = cs
      end
    end
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
  stop_up_next()
  state.duration = mp.get_property_number('duration') or 0
  
  local skips = parse_skip_times(get_skip_times_opt())
  local chapter_skips = parse_chapters_for_skips()
  for _, cs in ipairs(chapter_skips) do
    local duplicate = false
    for _, s in ipairs(skips) do
      if math.abs(s.start - cs.start) < 2.0 then
        duplicate = true
        break
      end
    end
    if not duplicate then
      skips[#skips + 1] = cs
    end
  end

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
    end
  end
end)

-- Periodically report playback position to Rust backend for crash recovery
local progress_timer = mp.add_periodic_timer(30, function()
  notify_backend("progress")

  -- Once we're most of the way through, ask the backend to resolve the next
  -- episode's stream ahead of time so auto-next is instant. One-shot per file.
  if not state.preload_sent and get_auto_next_opt() == 'yes' then
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
end)

mp.register_event('shutdown', function()
  progress_timer:stop()
  notify_backend("stop", true)
end)

mp.observe_property('eof-reached', 'bool', function(name, val)
  if val and get_auto_next_opt() == 'yes' and not state.next_triggered then
    -- Show the Up Next countdown instead of jumping immediately; it handles the
    -- last-episode case and the actual advance (with stuck-load recovery).
    start_up_next_countdown()
  end
end)

mp.observe_property('pause', 'bool', function(name, val)
  if state.file_loaded then
    local action = val and "pause" or "resume"
    notify_backend(action)
  end
end)

register_script_messages()

msg.info('Anicat overlay loaded: ctrl+1 = Toggle Upscaling')
