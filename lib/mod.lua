-- nullband
-- v0.1.0 by vehka
-- Transmit norns to nullband.org: request a one-time token, go on air,
-- stop. 45-minute transmission window.
--
-- SYSTEM > MODS > NULLBAND
--   E1        transmit / settings page
--   K3        request token, start, stop
--   K2        back (cancel)

local mod = require 'core/mods'

local NAME = mod.this_name or "nullband"
local ROOT = _path.code .. NAME .. "/lib/"

local api = dofile(ROOT .. "api.lua")
local transmit = dofile(ROOT .. "transmit.lua")
local deps_lib = dofile(ROOT .. "deps.lua")

local WINDOW = 45 * 60      -- seconds of air time per token
local DETECT_TIMEOUT = 60   -- seconds to wait for nullband to see us
local START_GRACE = 4       -- seconds before a missing darkice counts
local HEALTH_EVERY_START = 3
local HEALTH_EVERY_LIVE = 10

local BITRATES = { 96, 128, 192, 256, 320 }
local SETTINGS_FILE = _path.data .. "nullband/settings.lua"

local deps = deps_lib.new { name = "nullband", dir = _path.data .. "nullband/deps" }
deps:add { id = "darkice", label = "darkice", check = "darkice",
           pkg = "darkice", size = "2 MB",
           why = "streams JACK audio to Icecast" }
deps:add { id = "curl", label = "curl", check = "curl", pkg = "curl",
           size = "1 MB", why = "talks to nullband.org" }

local function uninstalled()
  return not util.file_exists(ROOT .. "mod.lua")
end

--
-- state
--

local S = {
  state = "idle", -- idle requesting ready starting live confirm_stop error
  page = 1,       -- 1 transmit, 2 settings
  creds = nil,
  started = nil,  -- util.time() when darkice was launched
  on_air = nil,   -- util.time() when nullband first saw us
  unit = nil,
  msg = nil,
  detail = {},
  last_health = 0,
  health_busy = false,
  settings_sel = 1,
  last_tick = 0,
  ticker = nil,
}

local settings = { source = 1, bitrate = 2, ghost = true, autostop = false }

local SETTINGS = {
  { id = "source", name = "source",
    show = function() return transmit.SOURCES[settings.source].name end,
    delta = function(d) settings.source = util.clamp(settings.source + d, 1, #transmit.SOURCES) end },
  { id = "bitrate", name = "bitrate",
    show = function() return BITRATES[settings.bitrate] .. " kbps" end,
    delta = function(d) settings.bitrate = util.clamp(settings.bitrate + d, 1, #BITRATES) end },
  { id = "ghost", name = "ghost transmission",
    show = function() return settings.ghost and "on" or "off" end,
    delta = function(d) settings.ghost = d > 0 end },
  { id = "autostop", name = "stop at 00:00",
    show = function() return settings.autostop and "on" or "off" end,
    delta = function(d) settings.autostop = d > 0 end },
}

local function load_settings()
  if not util.file_exists(SETTINGS_FILE) then return end
  local ok, t = pcall(dofile, SETTINGS_FILE)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do
      if settings[k] ~= nil and type(v) == type(settings[k]) then settings[k] = v end
    end
  end
end

local function save_settings()
  if uninstalled() then return end
  os.execute("mkdir -p '" .. _path.data .. "nullband'")
  local f = io.open(SETTINGS_FILE, "w")
  if not f then return end
  f:write("return {\n")
  for k, v in pairs(settings) do
    f:write(string.format("  %s = %s,\n", k, tostring(v)))
  end
  f:write("}\n")
  f:close()
end

local function menu_visible()
  return _menu and _menu.mode and _menu.page == NAME
end

local function redraw()
  if menu_visible() then mod.menu.redraw() end
end

local function set_state(state, msg, detail)
  S.state = state
  S.msg = msg
  S.detail = detail or {}
  redraw()
end

local function fmt_time(secs)
  local neg = secs < 0
  secs = math.abs(math.floor(secs))
  return (neg and "+" or "") .. string.format("%02d:%02d", secs // 60, secs % 60)
end

--
-- actions
--

local function reset()
  S.creds, S.started, S.on_air, S.unit = nil, nil, nil, nil
  set_state("idle")
end

local function stop(msg, detail)
  transmit.stop()
  S.creds, S.started, S.on_air, S.unit = nil, nil, nil, nil
  if msg then set_state("error", msg, detail) else set_state("idle") end
end

local function request()
  if uninstalled() then return end
  if #deps:missing() > 0 then
    deps:ensure(nil, { on_done = function() redraw() end })
    return
  end
  set_state("requesting")
  api.request_credentials(function(creds, err)
    if S.state ~= "requesting" then return end -- cancelled meanwhile
    if not creds then
      set_state("error", "no token", { err })
      return
    end
    S.creds = creds
    set_state("ready")
  end)
end

local function start()
  if uninstalled() or not S.creds then return end
  local ok, err = transmit.start({
    server = api.SERVER, port = api.PORT, user = api.USER,
    token = S.creds.token, mount = S.creds.mount,
  }, { bitrate = BITRATES[settings.bitrate], source = settings.source })
  if not ok then
    set_state("error", "can't start", { err })
    return
  end
  S.started = util.time()
  S.last_health = 0
  set_state("starting")
end

local function went_live(unit)
  S.on_air = util.time()
  S.unit = unit
  set_state("live")
  if not settings.ghost then api.ghost_optout(S.creds.mount) end
end

local function poll_health()
  if S.health_busy or not S.creds then return end
  S.health_busy = true
  S.last_health = util.time()
  local mount = S.creds.mount
  api.health(mount, function(h)
    S.health_busy = false
    if not h or not S.creds or S.creds.mount ~= mount then return end
    if S.state == "starting" and h.live then
      went_live(h.unit)
    elseif (S.state == "live" or S.state == "confirm_stop") and h.unit then
      if h.unit ~= S.unit then
        S.unit = h.unit
        redraw()
      end
    end
  end)
end

--
-- ticker: survives script changes by being restarted from hooks and menu
-- events (norns cancels every clock when a script is cleared)
--

local function tick()
  local now = util.time()
  local st = S.state
  if st == "starting" or st == "live" or st == "confirm_stop" then
    local alive = transmit.running()
    if not alive and now - S.started > START_GRACE then
      stop(st == "starting" and "darkice stopped" or "dropped",
        transmit.log_tail(4))
      return
    end
  end
  if st == "starting" then
    if now - S.started > DETECT_TIMEOUT then
      stop("no signal detected", { "nullband didn't see the stream" })
      return
    end
    if now - S.last_health >= HEALTH_EVERY_START then poll_health() end
  elseif st == "live" or st == "confirm_stop" then
    if settings.autostop and now - S.on_air >= WINDOW then
      stop()
      return
    end
    if now - S.last_health >= HEALTH_EVERY_LIVE then poll_health() end
  end
  if menu_visible() and st ~= "idle" then redraw() end
end

-- force: start a new clock even if the old one ticked recently. The script
-- hooks need it: norns cancels all clocks right around them, so a clock
-- that ticked a moment ago may already be gone.
local function ensure_ticker(force)
  if not force and util.time() - S.last_tick < 3 then return end
  if S.ticker then pcall(clock.cancel, S.ticker) end
  S.last_tick = util.time()
  S.ticker = clock.run(function()
    while true do
      clock.sleep(1)
      S.last_tick = util.time()
      local ok, err = pcall(tick)
      if not ok then print("nullband: " .. tostring(err)) end
    end
  end)
end

--
-- menu page
--

local m = {}

local HINTS = {
  idle = { "back", "request token" },
  requesting = { "cancel", nil },
  ready = { "discard", "go on air" },
  starting = { "cancel", nil },
  live = { "back", "stop" },
  confirm_stop = { "no", "yes, stop" },
  error = { "back", "ok" },
}

m.key = function(n, z)
  ensure_ticker()
  if z ~= 1 then return end
  local st = S.state
  if S.page == 2 then
    if n == 2 then S.page = 1 end
    redraw()
    return
  end
  if n == 2 then
    if st == "idle" or st == "live" then mod.menu.exit()
    elseif st == "requesting" or st == "ready" or st == "error" then reset()
    elseif st == "starting" then stop()
    elseif st == "confirm_stop" then set_state("live") end
  elseif n == 3 then
    if st == "idle" then request()
    elseif st == "ready" then start()
    elseif st == "live" then set_state("confirm_stop")
    elseif st == "confirm_stop" then stop()
    elseif st == "error" then reset() end
  end
end

m.enc = function(n, d)
  ensure_ticker()
  if n == 1 then
    S.page = util.clamp(S.page + (d > 0 and 1 or -1), 1, 2)
  elseif S.page == 2 then
    if n == 2 then
      S.settings_sel = util.clamp(S.settings_sel + d, 1, #SETTINGS)
    elseif n == 3 then
      local st = S.state
      local item = SETTINGS[S.settings_sel]
      -- source and bitrate go into darkice at start; ghost is sent on air
      if (st == "idle" or st == "ready" or st == "error")
          or (item.id == "autostop") then
        item.delta(d)
        save_settings()
      end
    end
  end
  redraw()
end

local function text(x, y, s, level, align)
  screen.level(level or 15)
  screen.move(x, y)
  if align == "right" then screen.text_right(s)
  elseif align == "center" then screen.text_center(s)
  else screen.text(s) end
end

local function draw_settings()
  text(0, 8, "NULLBAND", 4)
  text(127, 8, "SETTINGS", 4, "right")
  local locked = not (S.state == "idle" or S.state == "ready" or S.state == "error")
  for i, item in ipairs(SETTINGS) do
    local y = 10 + i * 10
    local sel = i == S.settings_sel
    local dim = locked and item.id ~= "autostop"
    text(0, y, item.name, sel and 15 or 4)
    text(127, y, item.show(), dim and 2 or (sel and 15 or 4), "right")
  end
  if locked then text(0, 61, "on air: some locked", 2) end
end

local function draw_transmit()
  local st = S.state
  text(0, 8, "NULLBAND", 4)
  local label = ({
    idle = "OFF AIR", requesting = "REQUESTING", ready = "READY",
    starting = "CONNECTING", live = "ON AIR", confirm_stop = "ON AIR",
    error = "STOPPED",
  })[st]
  if st == "live" or st == "confirm_stop" then
    -- blink a dot next to ON AIR
    if math.floor(util.time()) % 2 == 0 then
      screen.level(15)
      screen.circle(127 - screen.text_extents(label) - 6, 5.5, 2)
      screen.fill()
    end
  end
  text(127, 8, label, st == "live" and 15 or 4, "right")

  if st == "idle" then
    text(64, 28, "original transmissions only", 4, "center")
    text(64, 40, "token gives " .. (WINDOW // 60) .. " minutes", 4, "center")
  elseif st == "requesting" then
    text(64, 34, "asking nullband.org...", 8, "center")
  elseif st == "ready" then
    text(64, 26, S.creds.mount, 8, "center")
    text(64, 40, transmit.SOURCES[settings.source].name .. "  "
      .. BITRATES[settings.bitrate] .. " kbps", 4, "center")
  elseif st == "starting" then
    local waited = math.floor(util.time() - S.started)
    text(64, 30, "detecting signal", 8, "center")
    text(64, 42, waited .. " / " .. DETECT_TIMEOUT .. " s", 4, "center")
  elseif st == "live" or st == "confirm_stop" then
    local left = WINDOW - (util.time() - S.on_air)
    screen.font_size(24)
    text(64, 40, fmt_time(left), left < 0 and 4 or 15, "center")
    screen.font_size(8)
    local unit = S.unit and string.format("unit %05d", S.unit) or "unit ..."
    text(64, 52, st == "confirm_stop" and "stop transmission?" or unit,
      st == "confirm_stop" and 15 or 4, "center")
  elseif st == "error" then
    text(64, 22, S.msg or "error", 15, "center")
    for i, line in ipairs(S.detail) do
      if i > 3 then break end
      text(0, 22 + i * 9, util.trim_string_to_width(tostring(line), 127), 4)
    end
  end

  local hint = HINTS[st] or {}
  if hint[1] then text(0, 63, hint[1], 4) end
  if hint[2] then text(127, 63, hint[2], 15, "right") end
end

m.redraw = function()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if S.page == 2 then draw_settings() else draw_transmit() end
  screen.update()
end

m.init = function()
  ensure_ticker()
end

m.deinit = function() end

mod.menu.register(NAME, m)

--
-- hooks
--

mod.hook.register("system_post_startup", "nullband_startup", function()
  load_settings()
  -- a darkice left over from before a matron restart has lost its state
  transmit.stop()
end)

mod.hook.register("system_pre_shutdown", "nullband_shutdown", function()
  transmit.stop()
end)

-- clocks are cancelled when a script is cleared; start ours again
-- (post_cleanup runs before clock.cleanup, so a clock started there would
-- die; pre_init runs after it, post_init again once init has finished)
mod.hook.register("script_pre_init", "nullband_pre_init",
  function() ensure_ticker(true) end)
mod.hook.register("script_post_init", "nullband_post_init",
  function() ensure_ticker(true) end)
