local mp = mp
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
  top_size = 56,
  bottom_size = 104,
  accent = '00f2fe',
  font = 'Sans',
  title = '${media-title}',
  skip_times = '',
  auto_next = 'yes',
}

options.read_options(opts, 'anicat_ui')

local function to_bool(value, default_value)
  if value == nil then
    return default_value
  end

  local normalized = tostring(value):lower()
  return normalized == 'yes' or normalized == 'true' or normalized == '1' or normalized == 'on'
end

local function hex_to_ass_color(hex)
  if not hex or hex == '' then
    return '&H00FFFFFF&'
  end

  hex = hex:gsub('#', '')
  if #hex ~= 6 then
    return '&H00FFFFFF&'
  end

  local r = hex:sub(1, 2)
  local g = hex:sub(3, 4)
  local b = hex:sub(5, 6)
  return string.format('&H00%s%s%s&', b, g, r)
end

local accent_ass = hex_to_ass_color(opts.accent)
local render

local state = {
  overlay = mp.create_osd_overlay('ass-events'),
  width = 1280,
  height = 720,
  paused = false,
  position = 0,
  duration = 0,
  title = '',
  volume = 100,
  muted = false,
  speed = 1,
  fullscreen = false,
  mouse = nil,
  skips = {},
  active_skip = nil,
  buttons = {},
  auto_next = to_bool(opts.auto_next, true),
}

local function escape_ass(text)
  if text == nil then
    return ''
  end

  local ok, escaped = pcall(mp.command_native, { 'escape-ass', tostring(text) })
  if ok and type(escaped) == 'string' then
    return escaped
  end

  return tostring(text)
    :gsub('\\', '\\\\')
    :gsub('{', '\\{')
    :gsub('}', '\\}')
end

local function format_time(secs)
  if not secs or secs ~= secs then
    return '00:00'
  end

  local total = math.max(0, math.floor(secs))
  local s = total % 60
  local m = math.floor((total % 3600) / 60)
  local h = math.floor(total / 3600)

  if h > 0 then
    return string.format('%d:%02d:%02d', h, m, s)
  end

  return string.format('%02d:%02d', m, s)
end

local function format_speed(speed)
  speed = speed or 1
  if math.abs(speed - 1) < 0.01 then
    return '1.0x'
  end

  return string.format('%.2fx', speed)
end

local function format_volume(volume)
  volume = volume or 0
  return string.format('%d%%', math.floor(volume + 0.5))
end

local function round_rect(ass, x1, y1, x2, y2)
  ass:draw_start()
  ass:rect_cw(x1, y1, x2, y2)
  ass:draw_stop()
end

local function in_rect(x, y, x1, y1, x2, y2)
  return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function parse_skip_times(raw)
  local parsed = {}
  if not raw or raw == '' then
    return parsed
  end

  for part in string.gmatch(raw, '([^;]+)') do
    local skip_type, start_s, end_s = part:match('([^,]+),([^,]+),([^,]+)')
    if skip_type and start_s and end_s then
      parsed[#parsed + 1] = {
        type = skip_type,
        start = tonumber(start_s) or 0,
        endt = tonumber(end_s) or 0,
      }
    end
  end

  return parsed
end

local function get_skip_for(skip_type)
  for _, entry in ipairs(state.skips) do
    if entry.type == skip_type then
      return entry
    end
  end
  return nil
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

local function refresh_state()
  local w, h = mp.get_osd_size()
  state.width = w or 1280
  state.height = h or 720
  state.position = mp.get_property_number('time-pos') or 0
  state.duration = mp.get_property_number('duration') or 0
  state.paused = mp.get_property_bool('pause', false)
  state.mouse = mp.get_property_native('mouse-pos')
  state.volume = mp.get_property_number('volume') or 100
  state.muted = mp.get_property_bool('mute', false)
  state.speed = mp.get_property_number('speed') or 1
  state.fullscreen = mp.get_property_bool('fullscreen', false)
  state.active_skip = get_active_skip(state.position)

  local title = mp.get_property('media-title') or mp.get_property('filename') or ''
  if opts.title and opts.title ~= '' then
    local ok, expanded = pcall(mp.command_native, { 'expand-text', opts.title })
    if ok and type(expanded) == 'string' and expanded ~= '' then
      title = expanded
    end
  end
  state.title = title
end

local function draw_panel(ass, x1, y1, x2, y2, fill_color, border_color, alpha)
  ass:new_event()
  ass:append(string.format([[{\an7\1c%s\3c%s\bord1\shad0\alpha&H%s&}]], fill_color, border_color or fill_color, alpha or '40'))
  round_rect(ass, x1, y1, x2, y2)
end

local function draw_text(ass, text, x, y, size, color, align, bold)
  ass:new_event()
  ass:append(string.format([[{\an%d\fn%s\fs%d\1c%s\bord0\shad0%s\pos(%d,%d)}]], align or 5, opts.font, size, color or '&H00FFFFFF&', bold and '\\b1' or '', x, y))
  ass:append(text)
end

local function add_button(ass, name, x1, y1, x2, y2, label, config)
  config = config or {}
  local active = config.active == true
  local fill = active and (config.active_fill or hex_to_ass_color('1c2833')) or (config.fill or hex_to_ass_color('15151b'))
  local border = active and (config.active_border or accent_ass) or (config.border or hex_to_ass_color('2f2f37'))
  local alpha = config.alpha or (active and '18' or '38')
  local color = config.color or (active and accent_ass or '&H00FFFFFF&')
  local text_size = config.text_size or 16

  state.buttons[name] = {
    x1 = x1,
    y1 = y1,
    x2 = x2,
    y2 = y2,
    action = config.action,
  }

  draw_panel(ass, x1, y1, x2, y2, fill, border, alpha)
  draw_text(ass, label, math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2) + 1, text_size, color, 5, active)
end

local function button_text_metrics(text, width_min, width_scale)
  local label = text or ''
  return math.max(width_min, math.floor(#label * width_scale + 26))
end

local function draw_meter(ass, x1, y1, x2, y2, value, active_color, inactive_color)
  local clamped = math.max(0, math.min(1, value or 0))
  local filled_x = math.floor(x1 + (x2 - x1) * clamped)
  draw_panel(ass, x1, y1, x2, y2, inactive_color, inactive_color, '38')
  draw_panel(ass, x1, y1, filled_x, y2, active_color, active_color, '20')
  if filled_x > x1 then
    draw_panel(ass, filled_x - 2, y1 - 1, filled_x + 2, y2 + 1, active_color, active_color, '8')
  end
end

local function show_status(text)
  if text and text ~= '' then
    mp.osd_message(text, 1.2)
  end
end

local function seek_relative(amount)
  mp.commandv('seek', tostring(amount), 'relative+exact')
  render()
end

local function jump_to(time_pos)
  local duration = state.duration or 0
  if duration <= 0 then
    return
  end

  local clamped = math.max(0, math.min(duration, time_pos))
  mp.set_property_number('time-pos', clamped)
  render()
end

local function toggle_play()
  mp.commandv('cycle', 'pause')
  render()
end

local function toggle_fullscreen()
  mp.commandv('cycle', 'fullscreen')
  render()
end

local function next_episode()
  mp.commandv('playlist-next', 'force')
end

local function previous_episode()
  mp.commandv('playlist-prev', 'force')
end

local function reload_episode()
  local path = mp.get_property('path') or mp.get_property('stream-open-filename')
  if path and path ~= '' then
    mp.commandv('loadfile', path, 'replace')
  end
end

local function toggle_auto_next()
  state.auto_next = not state.auto_next
  show_status(state.auto_next and 'AniCat Auto-Play: On' or 'AniCat Auto-Play: Off')
  render()
end

local function toggle_translation()
  mp.commandv('cycle', 'audio')
  show_status('AniCat: switched audio track')
  render()
end

local function toggle_mute()
  mp.commandv('cycle', 'mute')
  render()
end

local function volume_step(amount)
  local volume = mp.get_property_number('volume') or 100
  volume = math.max(0, math.min(100, volume + amount))
  mp.set_property_number('volume', volume)
  render()
end

local function skip_current_segment()
  local skip = state.active_skip or get_skip_for('op') or get_skip_for('ed')
  if skip and skip.endt and skip.endt > state.position then
    jump_to(skip.endt)
    return
  end

  seek_relative(90)
end

local function quit_player()
  mp.commandv('quit')
end

local function render()
  refresh_state()
  state.buttons = {}

  local w = state.width
  local h = state.height
  if w <= 0 or h <= 0 then
    return
  end

  local ass = assdraw.ass_new()
  local top_h = tonumber(opts.top_size) or 56
  local bottom_h = tonumber(opts.bottom_size) or 104

  local top_y1 = 12
  local top_y2 = top_y1 + top_h
  local bottom_y1 = h - bottom_h - 12
  local bottom_y2 = h - 12
  local panel_fill = hex_to_ass_color('111116')
  local panel_border = hex_to_ass_color('2e2f38')
  local bar_fill = hex_to_ass_color('1a1a21')
  local bar_border = hex_to_ass_color('2f3038')
  local accent_fill = hex_to_ass_color(opts.accent)
  local accent_soft = hex_to_ass_color('1f2937')
  local white = '&H00FFFFFF&'
  local muted = '&H00B7B7C5&'

  draw_panel(ass, 12, top_y1, w - 12, top_y2, panel_fill, panel_border, '42')
  draw_panel(ass, 12, bottom_y1, w - 12, bottom_y2, panel_fill, panel_border, '40')

  local badge_x1 = 24
  local badge_x2 = 108
  local badge_y1 = top_y1 + 10
  local badge_y2 = top_y1 + top_h - 10
  draw_panel(ass, badge_x1, badge_y1, badge_x2, badge_y2, accent_fill, accent_fill, '20')
  draw_text(ass, 'AniCat', math.floor((badge_x1 + badge_x2) / 2), math.floor((badge_y1 + badge_y2) / 2) + 1, 14, white, 5, true)

  local title = escape_ass(state.title ~= '' and state.title or 'AniCat')
  draw_text(ass, title, 126, top_y1 + 21, 20, white, 7, true)

  local subtitle = ''
  if state.active_skip then
    subtitle = state.active_skip.type == 'op' and 'Skip Intro available' or 'Skip Outro available'
  else
    subtitle = mp.get_property('chapter-metadata/by-key/title') or mp.get_property('chapter') or ''
  end
  if subtitle ~= '' then
    draw_text(ass, escape_ass(subtitle), 126, top_y1 + 41, 12, muted, 7, false)
  end

  local top_chip_y1 = top_y1 + 10
  local top_chip_y2 = top_y1 + top_h - 10
  local speed_text = format_speed(state.speed)
  local speed_width = button_text_metrics(speed_text, 54, 8)
  local chip_x = w - 24

  draw_panel(ass, chip_x - speed_width, top_chip_y1, chip_x, top_chip_y2, bar_fill, bar_border, '28')
  draw_text(ass, speed_text, chip_x - math.floor(speed_width / 2), top_y1 + 21, 13, white, 5, true)

  local duration = math.max(0, state.duration)
  local progress = 0
  if duration > 0 then
    progress = math.max(0, math.min(1, state.position / duration))
  end

  local timeline_x1 = 24
  local timeline_x2 = w - 24
  local timeline_y = h - bottom_h + 24
  local timeline_h = 8
  local filled_x = math.floor(timeline_x1 + (timeline_x2 - timeline_x1) * progress)

  draw_panel(ass, timeline_x1, timeline_y - math.floor(timeline_h / 2), timeline_x2, timeline_y + math.floor(timeline_h / 2), bar_fill, bar_border, '30')
  draw_panel(ass, timeline_x1, timeline_y - math.floor(timeline_h / 2), filled_x, timeline_y + math.floor(timeline_h / 2), accent_fill, accent_fill, '18')

  draw_text(ass, format_time(state.position), timeline_x1, timeline_y + 20, 12, muted, 7, false)
  draw_text(ass, format_time(duration), timeline_x2, timeline_y + 20, 12, muted, 9, false)

  local center_y = h - 42
  local button_gap = 8
  local left_x = 24

  add_button(ass, 'play', left_x, center_y - 15, left_x + 54, center_y + 15, state.paused and '▶' or '⏸', {
    action = toggle_play,
    active = true,
    text_size = 22,
    active_fill = hex_to_ass_color('1e2430'),
    active_border = accent_fill,
  })
  left_x = left_x + 54 + button_gap

  add_button(ass, 'back', left_x, center_y - 15, left_x + 38, center_y + 15, '⏪', {
    action = function()
      seek_relative(-10)
    end,
    text_size = 16,
  })
  left_x = left_x + 38 + button_gap

  if state.paused then
    draw_panel(ass, math.floor(w / 2) - 54, math.floor(h / 2) - 54, math.floor(w / 2) + 54, math.floor(h / 2) + 54, accent_fill, accent_fill, '30')
    draw_text(ass, '▶', math.floor(w / 2), math.floor(h / 2) + 1, 32, white, 5, true)
  end

  local volume_meter_x1 = left_x
  local volume_meter_x2 = volume_meter_x1 + 82
  local volume_button_x2 = volume_meter_x1 - 8
  add_button(ass, 'mute', volume_button_x2 - 38, center_y - 15, volume_button_x2, center_y + 15, state.muted and '🔇' or '🔊', {
    action = toggle_mute,
    active = state.muted,
    text_size = 15,
    active_fill = hex_to_ass_color('1e2430'),
    active_border = accent_fill,
  })
  draw_meter(ass, volume_meter_x1, center_y - 4, volume_meter_x2, center_y + 4, state.muted and 0 or (state.volume / 100), accent_fill, accent_soft)
  draw_text(ass, format_volume(state.volume), volume_meter_x2 + 26, center_y + 1, 11, muted, 7, false)

  local right_x = w - 24
  local close_w = 40
  add_button(ass, 'fullscreen', right_x - close_w, center_y - 15, right_x, center_y + 15, '⛶', {
    action = toggle_fullscreen,
    active = state.fullscreen,
    text_size = 16,
    active_fill = hex_to_ass_color('1e2430'),
    active_border = accent_fill,
  })
  right_x = right_x - close_w - button_gap

  add_button(ass, 'next', right_x - 38, center_y - 15, right_x, center_y + 15, '⏭', {
    action = next_episode,
    text_size = 16,
  })
  right_x = right_x - 38 - button_gap

  add_button(ass, 'autoplay', right_x - 78, center_y - 15, right_x, center_y + 15, 'Auto', {
    action = toggle_auto_next,
    active = state.auto_next,
    text_size = 13,
    active_fill = hex_to_ass_color('1e2430'),
    active_border = accent_fill,
  })

  add_button(ass, 'speed', volume_meter_x2 + 66, center_y - 15, volume_meter_x2 + 118, center_y + 15, speed_text, {
    action = function()
      mp.commandv('cycle-values', 'speed', '0.75', '1', '1.25', '1.5', '2')
      render()
    end,
    text_size = 13,
  })

  add_button(ass, 'forward', volume_meter_x2 + 130, center_y - 15, volume_meter_x2 + 168, center_y + 15, '⏩', {
    action = function()
      seek_relative(10)
    end,
    text_size = 16,
  })

  if state.active_skip then
    local skip_label = state.active_skip.type == 'op' and 'Skip Intro' or 'Skip Segment'
    local skip_width = math.max(108, math.floor(#skip_label * 7.6 + 26))
    add_button(ass, 'skip', volume_meter_x2 + 194, center_y - 15, volume_meter_x2 + 194 + skip_width, center_y + 15, skip_label, {
      action = skip_current_segment,
      active = true,
      text_size = 13,
      active_fill = accent_fill,
      active_border = accent_fill,
      color = hex_to_ass_color('0b0b10'),
    })
  end

  state.overlay.data = ass.text
  state.overlay.res_x = w
  state.overlay.res_y = h
  state.overlay.hidden = false
  state.overlay:update()
end

local function hide()
  state.overlay:remove()
end

local function on_left_click()
  refresh_state()
  local mouse = state.mouse
  if not mouse then
    return
  end

  local x = mouse.x or 0
  local y = mouse.y or 0
  for _, button in pairs(state.buttons) do
    if in_rect(x, y, button.x1, button.y1, button.x2, button.y2) then
      if button.action then
        button.action()
      end
      return
    end
  end
end

local function on_event()
  render()
end

local function register_script_messages()
  if not mp.register_script_message then
    return
  end

  mp.register_script_message('anicat-next-episode', next_episode)
  mp.register_script_message('anicat-previous-episode', previous_episode)
  mp.register_script_message('anicat-toggle-auto-next', toggle_auto_next)
  mp.register_script_message('anicat-toggle-translation', toggle_translation)
  mp.register_script_message('anicat-reload-episode', reload_episode)
  mp.register_script_message('anicat-skip-intro', skip_current_segment)
end

mp.observe_property('time-pos', 'number', on_event)
mp.observe_property('duration', 'number', on_event)
mp.observe_property('pause', 'bool', on_event)
mp.observe_property('media-title', 'string', on_event)
mp.observe_property('mouse-pos', 'native', on_event)
mp.observe_property('volume', 'number', on_event)
mp.observe_property('mute', 'bool', on_event)
mp.observe_property('speed', 'number', on_event)
mp.observe_property('fullscreen', 'bool', on_event)
mp.register_event('file-loaded', on_event)
mp.register_event('playback-restart', on_event)
mp.register_event('end-file', function(event)
  if state.auto_next and event and event.reason == 'eof' then
    next_episode()
  end
end)
mp.register_event('shutdown', hide)

register_script_messages()

mp.add_periodic_timer(0.25, render)

local ok, err = pcall(function()
  mp.add_forced_key_binding('MBTN_LEFT', 'anicat-left-click', on_left_click)
end)
if not ok then
  msg.warn('Could not bind MBTN_LEFT: ' .. tostring(err))
end

msg.info('AniCat single-file UI loaded')
render()
