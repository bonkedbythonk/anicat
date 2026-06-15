local mp = mp
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
  skip_times = '',
  auto_next = 'no',
  autoskip = 'yes',
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
  local pos = mp.get_property_number('time-pos') or 0
  state.position = pos
  local active = get_active_skip(pos)
  if active ~= state.active_skip then
    state.active_skip = active
    if active and not active.notified then
      active.notified = true
      msg.info("check_active_skip: entering skip zone type=" .. active.type .. " at pos=" .. pos .. " (end=" .. active.endt .. "), autoskip=" .. get_autoskip_opt())
      mp.osd_message('Intro - Shift+S to skip', 3.0)
    end
    if active and get_autoskip_opt() == 'yes' then
      jump_to(active.endt)
      mp.osd_message('Skipping intro', 1.5)
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

local function get_current_shader_mode()
  local current = mp.get_property('glsl-shaders') or ''
  if current == '' then
    return 'off'
  else
    return 'standard'
  end
end

local function enable_standard_shaders()
  local shader_paths = {
    "~~/shaders/Anime4K_Clamp_Highlights.glsl",
    "~~/shaders/Anime4K_Restore_CNN_M.glsl",
    "~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl",
    "~~/shaders/Anime4K_AutoDownscalePre_x2.glsl",
    "~~/shaders/Anime4K_AutoDownscalePre_x4.glsl"
  }
  local path_str = table.concat(shader_paths, ":")
  mp.commandv("change-list", "glsl-shaders", "set", path_str)
  refresh_shaders_state()
  mp.osd_message("Upscaling: Enabled (Sharp)", 2.0)
end

local function enable_shaders()
  enable_standard_shaders()
end

local function disable_shaders()
  mp.commandv("set", "glsl-shaders", "")
  refresh_shaders_state()
  mp.osd_message("Upscaling: Disabled", 2.0)
end

local function toggle_shaders()
  local mode = get_current_shader_mode()
  if mode == 'off' then
    enable_standard_shaders()
  else
    disable_shaders()
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

local function notify_backend(action, sync)
  local pos = state.position or 0
  local duration = state.duration or 0
  local url = "http://127.0.0.1:13370/player/" .. action .. "?pos=" .. math.floor(pos) .. "&duration=" .. math.floor(duration)
  msg.info("notify_backend called: action=" .. tostring(action) .. ", url=" .. url .. ", sync=" .. tostring(sync))
  
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

local function play_next(sync)
  state.next_triggered = true
  mp.osd_message('Loading next episode...', 3.0)
  notify_backend("next", sync)
end

local function play_prev(sync)
  state.next_triggered = true
  mp.osd_message('Loading previous episode...', 3.0)
  notify_backend("prev", sync)
end

local function toggle_translation()
  mp.osd_message("Switching Translation (Sub/Dub)...", 3.0)
  notify_backend("toggle-translation")
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

  -- Force bind the skip keys directly in the player
  if mp.add_forced_key_binding then
    mp.add_forced_key_binding('S', 'anicat-skip-shifts', skip_current_segment)
  end
end

mp.observe_property('time-pos', 'number', render_unforced)
mp.observe_property('duration', 'number', render_unforced)
mp.observe_property('mouse-pos', 'native', render_unforced)
mp.observe_property('seeking', 'native', render_unforced)
mp.observe_property('script-opts', 'native', function()
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
    end
  end
end)

mp.register_event('shutdown', function()
  notify_backend("stop", true)
end)

mp.observe_property('eof-reached', 'bool', function(name, val)
  if val and get_auto_next_opt() == 'yes' and not state.next_triggered then
    state.next_triggered = true
    mp.osd_message('Loading next episode...', 3.0)
    play_next()
  end
end)

register_script_messages()

msg.info('Anicat overlay loaded: ctrl+1 = Toggle Upscaling')
