-- nullcast
-- v0.2.0 by vehka
-- Listen to and transmit on nullband.org from the mod menu.
--
-- SYSTEM > MODS > NULLCAST
--   K1+E1     page: listen / transmit / settings
--   listen:   E2 tune, E3 level, K3 listen / stop, K2 back
--   transmit: K3 request token, go on air, stop; K2 back (cancel)
--   settings: E2 select, E3 change, K2 back

local mod = require 'core/mods'

local NAME = mod.this_name or "nullcast"
local ROOT = _path.code .. NAME .. "/lib/"

local api = dofile(ROOT .. "api.lua")
local transmit = dofile(ROOT .. "transmit.lua")
local listen = dofile(ROOT .. "listen.lua")
local deps_lib = dofile(ROOT .. "deps.lua")

local WINDOW = 45 * 60      -- seconds of air time per token
local DETECT_TIMEOUT = 60   -- seconds to wait for nullband to see us
local START_GRACE = 4       -- seconds before a missing darkice counts
local HEALTH_EVERY_START = 3
local HEALTH_EVERY = 10     -- while live, listening or on the listen page
local TUNE_TIMEOUT = 20     -- seconds from LOAD to the first frame
local TUNE_DEBOUNCE = 0.35  -- wait for E2 to settle before loading
local FPS = 15              -- listen page frame rate (and band updates)

local BITRATES = { 96, 128, 192, 256, 320 }
local DATA = _path.data .. "nullcast/"
local SETTINGS_FILE = DATA .. "settings.lua"

local deps = deps_lib.new { name = "nullcast", dir = DATA .. "deps" }
deps:add { id = "darkice", label = "darkice", check = "darkice",
           pkg = "darkice", size = "2 MB",
           why = "streams JACK audio to Icecast" }
deps:add { id = "curl", label = "curl", check = "curl", pkg = "curl",
           size = "1 MB", why = "talks to nullband.org" }
deps:add { id = "mpg123", label = "mpg123", check = "mpg123", pkg = "mpg123",
           size = "1 MB", why = "decodes the stations" }
deps:add { id = "jack-stdio", label = "jack-stdio", check = "jack-stdin",
           pkg = "jack-stdio", size = "1 MB", why = "plays them into JACK" }
local TX_DEPS = { "darkice", "curl" }
local RX_DEPS = { "curl", "mpg123", "jack-stdio" }

local function uninstalled()
  return not util.file_exists(ROOT .. "mod.lua")
end

--
-- state
--

local PAGES = { "listen", "transmit", "settings" }

local S = {
  state = "idle", -- transmit: idle requesting ready starting live confirm_stop error
  page = 1,
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
  last_slow = 0,
  ticker = nil,
  save_at = nil,
}

-- every signal on air, from /health: { [mount] = { unit, listeners, looping } }
local signals = nil
-- signals in dial order: { { mount =, x =, info = }, ... }
local dial = {}

local L = {
  state = "off",  -- off tuning playing lost
  mount = nil,    -- what the decoder is on (or about to load)
  sel = nil,      -- mount under the focus square
  started = 0,    -- util.time() when the pipeline was launched
  load_at = nil,  -- util.time() to send LOAD (debounced tuning)
  loaded = 0,     -- util.time() of the last LOAD
  msg = nil,      -- shown on the bottom line until msg_until
  msg_until = 0,
  fx = nil,       -- focus square x, glides to the selected dot
  bands = nil,    -- latest band levels from SuperCollider, 2 * BANDS
  bands_at = 0,
  up = {}, down = {},
  frame = 0,
}

local BANDS = 20
for i = 1, BANDS do L.up[i], L.down[i] = 0, 0 end

local settings = {
  source = 1, bitrate = 2, ghost = true, autostop = false,
  route = 1, level = 80, feedback = false,
}

local function transmitting()
  local st = S.state
  return st == "starting" or st == "live" or st == "confirm_stop"
end

local function own_mount()
  return transmitting() and S.creds and S.creds.mount or nil
end

local SETTINGS = {
  { id = "source", name = "transmit source", tx = true,
    show = function() return transmit.SOURCES[settings.source].name end,
    delta = function(d) settings.source = util.clamp(settings.source + d, 1, #transmit.SOURCES) end },
  { id = "bitrate", name = "bitrate", tx = true,
    show = function() return BITRATES[settings.bitrate] .. " kbps" end,
    delta = function(d) settings.bitrate = util.clamp(settings.bitrate + d, 1, #BITRATES) end },
  { id = "ghost", name = "ghost transmission", tx = true,
    show = function() return settings.ghost and "on" or "off" end,
    delta = function(d) settings.ghost = d > 0 end },
  { id = "autostop", name = "stop at 00:00",
    show = function() return settings.autostop and "on" or "off" end,
    delta = function(d) settings.autostop = d > 0 end },
  { id = "route", name = "listen into",
    show = function() return listen.ROUTES[settings.route].name end,
    delta = function(d) settings.route = util.clamp(settings.route + d, 1, #listen.ROUTES) end },
  { id = "feedback", name = "own signal",
    show = function() return settings.feedback and "allow" or "skip" end,
    delta = function(d) settings.feedback = d > 0 end },
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
  S.save_at = nil
  if uninstalled() then return end
  os.execute("mkdir -p '" .. DATA .. "'")
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

local function listen_page_visible()
  return menu_visible() and PAGES[S.page] == "listen"
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

local function flash(msg)
  L.msg = msg
  L.msg_until = util.time() + 1.5
end

--
-- dial: each signal gets a place from a hash of its mount, so it keeps its
-- spot while it's on air and new ones appear without shuffling the others
--

local DIAL_X0, DIAL_X1, DIAL_GAP = 6, 121, 6

local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) & 0xffffff end
  return h
end

local function rebuild_dial()
  dial = {}
  for mount, info in pairs(signals or {}) do
    local pos = (hash(mount) % 1000) / 999
    dial[#dial + 1] = { mount = mount, info = info,
      x = DIAL_X0 + pos * (DIAL_X1 - DIAL_X0) }
  end
  table.sort(dial, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.mount < b.mount
  end)
  for i = 2, #dial do
    dial[i].x = math.max(dial[i].x, dial[i - 1].x + DIAL_GAP)
  end
  for i = #dial, 1, -1 do
    local limit = i == #dial and DIAL_X1 or dial[i + 1].x - DIAL_GAP
    dial[i].x = math.max(DIAL_X0, math.min(dial[i].x, limit))
  end
  for _, d in ipairs(dial) do d.x = math.floor(d.x + 0.5) end
end

local function dial_index(mount)
  for i, d in ipairs(dial) do
    if d.mount == mount then return i end
  end
end

local function tunable(mount)
  return mount ~= own_mount() or settings.feedback
end

-- nearest tunable station from index i in direction dir (or i itself)
local function step_from(i, dir)
  while i >= 1 and i <= #dial do
    if tunable(dial[i].mount) then return i end
    i = i + dir
  end
end

local function first_tunable()
  local i = step_from(1, 1)
  return i and dial[i].mount
end

--
-- listen
--

local poll_health -- defined with transmit below

-- the analysis reads SuperCollider's inputs, which only carry the stream
-- when it goes into norns
local function vis_ping()
  if settings.route ~= 1 then return end
  osc.send({ "localhost", 57120 }, "/nullcast/vis/ping", { FPS })
end

local function vis_stop()
  osc.send({ "localhost", 57120 }, "/nullcast/vis/stop", {})
end

local function sync_param()
  if params.lookup and params.lookup["nullcast_listen"] then
    params:set("nullcast_listen", L.state == "off" and 0 or 1, true)
  end
end

local function listen_stop(msg)
  listen.stop()
  L.state, L.mount, L.load_at = "off", nil, nil
  vis_stop()
  if msg then flash(msg) end
  sync_param()
  redraw()
end

local function tune(mount, now)
  L.mount = mount
  L.state = "tuning"
  L.load_at = now and util.time() or util.time() + TUNE_DEBOUNCE
end

local function listen_start(interactive)
  if uninstalled() then return end
  if #deps:missing(RX_DEPS) > 0 then
    if interactive then
      deps:ensure(RX_DEPS, { on_done = function(ok)
        if ok and #deps:missing(RX_DEPS) == 0 then listen_start(false) end
        redraw()
      end })
    else
      flash("install first: K3 on listen")
      sync_param()
    end
    return
  end
  if not (L.sel and signals and signals[L.sel] and tunable(L.sel)) then
    L.sel = first_tunable()
  end
  if not L.sel then
    if signals then
      flash("no signals")
      sync_param()
    else
      -- the list isn't in yet: start when it arrives
      L.autostart = true
      poll_health()
    end
    redraw()
    return
  end
  local ok, err = listen.start(settings.route, settings.level, L.sel)
  if not ok then
    flash(err)
    return
  end
  L.started = util.time()
  L.mount, L.state, L.load_at, L.loaded = L.sel, "tuning", nil, util.time()
  if listen_page_visible() then vis_ping() end
  sync_param()
  redraw()
end

-- route changed: same station through a new pipeline
local function listen_restart()
  if L.state == "off" then return end
  local mount = L.mount
  if not listen.start(settings.route, settings.level, mount) then
    listen_stop("can't restart")
    return
  end
  L.started = util.time()
  L.state, L.load_at, L.loaded = "tuning", nil, util.time()
end

local function move_selection(d)
  if #dial == 0 then return end
  local dir = d > 0 and 1 or -1
  local i = dial_index(L.sel)
  local target
  if not i then
    target = step_from(dir > 0 and 1 or #dial, dir)
  else
    target = step_from(i + dir, dir)
  end
  if not target then return end
  L.sel = dial[target].mount
  if L.state ~= "off" and L.sel ~= L.mount then tune(L.sel) end
end

local function set_level(d)
  settings.level = util.clamp(settings.level + d, 0, 100)
  S.level_dirty = true
  S.save_at = util.time() + 2
  flash("level " .. settings.level)
  if params.lookup and params.lookup["nullcast_level"] then
    params:set("nullcast_level", settings.level, true)
  end
end

local function listen_events(now)
  if L.state == "off" then return end
  for _, ev in ipairs(listen.events()) do
    if not L.load_at then
      if ev == "started" and (L.state == "tuning" or L.state == "lost") then
        L.state = "playing"
      elseif ev == "error" or ev == "stopped" then
        if L.state == "tuning" or L.state == "playing" then
          L.state = "lost"
        end
      end
    end
  end
  if L.load_at and now >= L.load_at then
    L.load_at = nil
    L.loaded = now
    listen.load(L.mount)
  end
  if L.state == "tuning" and not L.load_at and now - L.loaded > TUNE_TIMEOUT then
    L.state = "lost"
  end
  -- FIFO writes take turns, so don't send every E3 step
  if S.level_dirty and now - (S.level_sent or 0) >= 0.3 then
    S.level_dirty = false
    S.level_sent = now
    listen.volume(settings.level)
  end
end

-- SuperCollider sends band levels through sclang to matron. Catch them
-- before the script's osc.event; this wrapper lives for the whole session.
local core_osc_event = _norns.osc.event
_norns.osc.event = function(path, args, from)
  if path == "/nullcast/bands" then
    L.bands = args
    L.bands_at = util.time()
    return
  end
  return core_osc_event(path, args, from)
end

--
-- transmit
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
  if #deps:missing(TX_DEPS) > 0 then
    deps:ensure(TX_DEPS, { on_done = function() redraw() end })
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

function poll_health()
  if S.health_busy then return end
  S.health_busy = true
  S.last_health = util.time()
  api.signals(function(list, err)
    S.health_busy = false
    if not list then
      if L.autostart then
        L.autostart = false
        flash(err or "no connection")
        sync_param()
      end
      return
    end
    signals = list
    rebuild_dial()
    if not L.sel then L.sel = first_tunable() end
    if L.autostart then
      L.autostart = false
      if L.state == "off" then listen_start(false) end
    end
    if S.creds then
      local mine = list[S.creds.mount]
      if S.state == "starting" and mine then
        went_live(mine.unit)
      elseif (S.state == "live" or S.state == "confirm_stop")
          and mine and mine.unit and mine.unit ~= S.unit then
        S.unit = mine.unit
      end
    end
    redraw()
  end)
end

--
-- ticker: survives script changes by being restarted from hooks and menu
-- events (norns cancels every clock when a script is cleared). It runs at
-- FPS while the listen page is open and four times a second otherwise.
--

local function slow_tick(now)
  local st = S.state
  if transmitting() then
    local alive = transmit.running()
    if not alive and now - S.started > START_GRACE then
      stop(st == "starting" and "darkice stopped" or "dropped",
        transmit.log_tail(4))
      return
    end
  end
  if st == "starting" and now - S.started > DETECT_TIMEOUT then
    stop("no signal detected", { "nullband didn't see the stream" })
    return
  end
  if (st == "live" or st == "confirm_stop") and settings.autostop
      and now - S.on_air >= WINDOW then
    stop()
    return
  end

  if L.state ~= "off" and now - L.started > 3 and not listen.running() then
    listen_stop("decoder stopped")
  end
  if L.state ~= "off" and not tunable(L.mount) then
    listen_stop("own signal skipped")
  end

  local every
  if st == "starting" then every = HEALTH_EVERY_START
  elseif transmitting() or L.state ~= "off" or listen_page_visible() then
    every = HEALTH_EVERY
  end
  if every and now - S.last_health >= every then poll_health() end

  if listen_page_visible() and (L.state == "playing" or L.state == "tuning") then
    vis_ping()
  end
  if S.save_at and now >= S.save_at then save_settings() end
  if menu_visible() and (st ~= "idle" or PAGES[S.page] == "listen") then
    redraw()
  end
end

-- one frame of the listen page: smooth the bars toward the band levels.
-- Heights are relative to a slow peak over all bands, so quiet and loud
-- stations both move, and the spectrum keeps its shape.
local WINDOW_DB = 36
local function animate(now)
  L.frame = L.frame + 1
  local fresh = L.state == "playing" and L.bands and now - L.bands_at < 1
  local db = {}
  if fresh then
    local peak = -90
    for i = 1, 2 * BANDS do
      db[i] = 20 * math.log((tonumber(L.bands[i]) or 0) + 1e-6, 10)
      peak = math.max(peak, db[i])
    end
    -- fast up, ~6 dB per second down, never below -50 dB so near
    -- silence stays flat
    L.ref = math.max(peak, (L.ref or peak) - 6 / FPS, -50)
  end
  for i = 1, BANDS do
    local up, down = 0, 0
    if fresh then
      local function h(d)
        return util.clamp((d - L.ref + WINDOW_DB) / WINDOW_DB, 0, 1) ^ 2 * 18
      end
      up, down = h(db[i]), h(db[BANDS + i])
    end
    L.up[i] = math.max(up, L.up[i] * 0.75)
    L.down[i] = math.max(down, L.down[i] * 0.75)
  end
  local i = dial_index(L.sel)
  if i then
    local tx = dial[i].x
    L.fx = L.fx and (L.fx + (tx - L.fx) * 0.35) or tx
    if math.abs(L.fx - tx) < 0.5 then L.fx = tx end
  end
  redraw()
end

local function tick()
  local now = util.time()
  listen_events(now)
  if now - S.last_slow >= 1 then
    S.last_slow = now
    slow_tick(now)
  end
  if listen_page_visible() then animate(now) end
end

-- force: start a new clock even if the old one ticked recently. The script
-- hooks need it: norns cancels all clocks right around them, so a clock
-- that ticked a moment ago may already be gone.
-- Clock ids are reused: after a script change our old id may belong to
-- another mod's new clock, so only treat it as ours (or cancel it) while
-- it still holds our coroutine.
local function ticker_alive()
  return S.ticker ~= nil and clock.threads ~= nil
    and S.ticker_co ~= nil and clock.threads[S.ticker] == S.ticker_co
end

local function ensure_ticker(force)
  if not force and util.time() - S.last_tick < 3 then return end
  if ticker_alive() then clock.cancel(S.ticker) end
  S.last_tick = util.time()
  S.ticker = clock.run(function()
    while true do
      clock.sleep(listen_page_visible() and 1 / FPS or 0.25)
      S.last_tick = util.time()
      local ok, err = pcall(tick)
      if not ok then print("nullcast: " .. tostring(err)) end
    end
  end)
  S.ticker_co = clock.threads and clock.threads[S.ticker]
end

--
-- params, for MIDI mapping. Added to every script after its init; they
-- reflect the mod's state and aren't saved in PSETs.
--

local function add_params()
  if params.lookup["nullcast_listen"] then return end
  params:add_group("nullcast_group", "NULLCAST", 4)
  params:add_binary("nullcast_listen", "listen", "toggle", L.state == "off" and 0 or 1)
  params:set_action("nullcast_listen", function(v)
    if v == 1 and L.state == "off" then listen_start(false)
    elseif v == 0 and L.state ~= "off" then listen_stop() end
  end)
  params:add_number("nullcast_level", "listen level", 0, 100, settings.level)
  params:set_action("nullcast_level", function(v)
    if v ~= settings.level then set_level(v - settings.level) end
  end)
  params:add_trigger("nullcast_prev", "previous station")
  params:set_action("nullcast_prev", function() move_selection(-1) end)
  params:add_trigger("nullcast_next", "next station")
  params:set_action("nullcast_next", function() move_selection(1) end)
  if params.set_save then
    for _, id in ipairs { "nullcast_listen", "nullcast_level" } do
      params:set_save(id, false)
    end
  end
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

local function key_transmit(n)
  local st = S.state
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

m.key = function(n, z)
  ensure_ticker()
  if z ~= 1 then return end
  local page = PAGES[S.page]
  if page == "transmit" then
    key_transmit(n)
  elseif n == 2 then
    mod.menu.exit()
  elseif n == 3 and page == "listen" then
    if L.state == "off" then listen_start(true) else listen_stop() end
  end
  redraw()
end

local function settings_change(d)
  local item = SETTINGS[S.settings_sel]
  -- source, bitrate and ghost go into the transmission when it starts
  if item.tx and transmitting() then return end
  local before = settings[item.id]
  item.delta(d)
  if settings[item.id] == before then return end
  save_settings()
  if item.id == "route" then listen_restart() end
end

m.enc = function(n, d)
  ensure_ticker()
  local page = PAGES[S.page]
  if n == 1 then
    -- norns only passes E1 on while K1 is held
    S.page = util.clamp(S.page + (d > 0 and 1 or -1), 1, #PAGES)
    if PAGES[S.page] == "listen" and L.state ~= "off" then vis_ping() end
  elseif page == "listen" then
    if n == 2 then move_selection(d)
    elseif n == 3 then set_level(d) end
  elseif page == "settings" then
    if n == 2 then
      S.settings_sel = util.clamp(S.settings_sel + d, 1, #SETTINGS)
    elseif n == 3 then
      settings_change(d)
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

local function page_dots(y)
  for i = 1, #PAGES do
    screen.level(i == S.page and 15 or 2)
    screen.rect(58 + (i - 1) * 5, y, 2, 2)
    screen.fill()
  end
end

local function draw_settings()
  text(0, 8, "NULLCAST", 4)
  text(127, 8, "SETTINGS", 4, "right")
  page_dots(3)
  local rows = 5
  local first = util.clamp(S.settings_sel - rows + 1, 1, math.max(1, #SETTINGS - rows + 1))
  for i = first, math.min(#SETTINGS, first + rows - 1) do
    local item = SETTINGS[i]
    local y = 20 + (i - first) * 10
    local sel = i == S.settings_sel
    local dim = item.tx and transmitting()
    text(0, y, item.name, sel and 15 or 4)
    text(127, y, item.show(), dim and 2 or (sel and 15 or 4), "right")
  end
end

local function draw_transmit()
  local st = S.state
  text(0, 8, "NULLCAST", 4)
  page_dots(3)
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

local CY, RIBBON_Y = 22, 50

-- the focus square; while tuning its outline crawls around
local function draw_focus(x)
  local x0, y0, w = math.floor(x) - 4, RIBBON_Y - 4, 8
  if L.state ~= "tuning" then
    screen.level(15)
    screen.rect(x0 + 0.5, y0 + 0.5, w, w)
    screen.stroke()
    return
  end
  screen.level(15)
  local phase = L.frame // 2
  for k = 0, 4 * w - 1 do
    if (k + phase) % 4 < 2 then
      local px, py
      if k < w then px, py = x0 + k, y0
      elseif k < 2 * w then px, py = x0 + w, y0 + k - w
      elseif k < 3 * w then px, py = x0 + 3 * w - k, y0 + w
      else px, py = x0, y0 + 4 * w - k end
      screen.pixel(px, py)
    end
  end
  screen.fill()
end

local function draw_listen()
  local now = util.time()
  page_dots(0)

  -- bars: left channel up, right channel down; static while tuning
  local x0 = 7
  for i = 1, BANDS do
    local x = x0 + (i - 1) * 6
    local up, down = L.up[i], L.down[i]
    if L.state == "tuning" then
      up, down = math.random() * 3, math.random() * 3
      screen.level(3)
    else
      screen.level(10)
    end
    local u, dn = math.floor(up + 0.5), math.floor(down + 0.5)
    if u + dn < 1 then
      screen.level(2)
      screen.rect(x, CY, 1, 1)
    else
      screen.rect(x, CY - u, 1, u + dn + 1)
    end
    screen.fill()
  end

  -- the dial
  screen.level(2)
  screen.rect(2, RIBBON_Y, 124, 1)
  screen.fill()
  local own = own_mount()
  for _, d in ipairs(dial) do
    local level = d.info.looping and 5 or 15
    if d.mount == own then
      level = settings.feedback and 15 or 2
      screen.level(level)
      screen.rect(d.x, RIBBON_Y - 4, 1, 2) -- a tick over your own signal
      screen.fill()
    end
    screen.level(level)
    screen.rect(d.x - 1, RIBBON_Y - 1, 3, 3)
    screen.fill()
  end
  if L.fx and dial_index(L.sel) then draw_focus(L.fx) end

  -- on air reminder
  if transmitting() and math.floor(now) % 2 == 0 then
    screen.level(15)
    screen.rect(125, 0, 2, 2)
    screen.fill()
  end

  -- bottom line: station, then state
  local left, right, rlevel = nil, nil, 4
  local d = dial[dial_index(L.sel) or 0]
  if d then
    left = d.mount == own and "you" or d.mount
  elseif signals == nil or L.autostart then
    left = "searching..."
  elseif #dial == 0 then
    left = "no signals"
  end
  if now < L.msg_until then
    right, rlevel = L.msg, 15
  elseif L.state == "off" then
    right = "K3 listen"
  elseif L.state == "tuning" then
    right = "tuning"
  elseif L.state == "lost" then
    right, rlevel = "no signal", 8
  elseif L.state == "playing" then
    local info = signals and signals[L.mount]
    right = info and info.looping and "ghost" or "live"
    if L.mount ~= L.sel then right = "on " .. L.mount end
  end
  if left then
    text(0, 62, util.trim_string_to_width(left, right and 70 or 127),
      L.state == "playing" and L.mount == L.sel and 15 or 6)
  end
  if right then text(127, 62, right, rlevel, "right") end
end

m.redraw = function()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  local page = PAGES[S.page]
  if page == "listen" then draw_listen()
  elseif page == "transmit" then draw_transmit()
  else draw_settings() end
  screen.update()
end

m.init = function()
  ensure_ticker()
  if PAGES[S.page] == "listen" then
    if L.state ~= "off" then vis_ping() end
    if util.time() - S.last_health > 5 then poll_health() end
  end
end

m.deinit = function() end

mod.menu.register(NAME, m)

--
-- hooks
--

mod.hook.register("system_post_startup", "nullcast_startup", function()
  load_settings()
  -- processes left over from before a matron restart have lost their state
  transmit.stop()
  listen.stop()
  vis_stop()
end)

mod.hook.register("system_pre_shutdown", "nullcast_shutdown", function()
  transmit.stop()
  listen.stop()
  vis_stop()
end)

-- clocks are cancelled when a script is cleared; start ours again
-- (post_cleanup runs before clock.cleanup, so a clock started there would
-- die; pre_init runs after it, post_init again once init has finished)
mod.hook.register("script_pre_init", "nullcast_pre_init",
  function() ensure_ticker(true) end)
mod.hook.register("script_post_init", "nullcast_post_init", function()
  -- cancelling a clock whose resume is already queued makes core resume a
  -- missing thread, so only replace the ticker if it's really gone
  if not ticker_alive() then ensure_ticker(true) end
  local ok, err = pcall(add_params)
  if not ok then print("nullcast: params: " .. tostring(err)) end
end)
