-- transmit.lua: run darkice as the Icecast source client.
--
-- darkice reads from JACK (client "nullcast", ports left/right) and sends
-- MP3 straight to nullband.org. It runs detached, so it keeps going while
-- scripts are loaded and unloaded. It never reconnects by itself: a
-- nullband token is single use, so a dropped stream needs a new one.

local Transmit = {}

Transmit.dir = _path.data .. "nullcast/"
Transmit.cfg = Transmit.dir .. "darkice.cfg"
Transmit.pidfile = Transmit.dir .. "darkice.pid"
Transmit.logfile = Transmit.dir .. "darkice.log"

Transmit.CLIENT = "nullcast"

Transmit.SOURCES = {
  { name = "norns out", ports = { "crone:output_1", "crone:output_2" } },
  { name = "inputs", ports = { "system:capture_1", "system:capture_2" } },
}

local function sh(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function write_file(path, s)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- c: { server, port, user, token, mount }, opts: { bitrate }
local function config(c, opts)
  return table.concat({
    "[general]",
    "duration = 0",
    "bufferSecs = 2",
    "reconnect = no",
    "realtime = no",
    "",
    "[input]",
    "device = jack", -- darkice: "jack" does not auto-connect, "jack_auto" does
    "jackClientName = " .. Transmit.CLIENT,
    "sampleRate = 48000",
    "bitsPerSample = 16",
    "channel = 2",
    "",
    "[icecast2-0]",
    "bitrateMode = cbr",
    "bitrate = " .. opts.bitrate,
    "format = mp3",
    "quality = 0.8",
    "server = " .. c.server,
    "port = " .. c.port,
    "password = " .. c.token,
    "mountPoint = " .. c.mount,
    "name = norns",
    "description = transmitted from norns",
    "public = no",
    "",
  }, "\n")
end

function Transmit.pid()
  local s = read_file(Transmit.pidfile)
  return s and tonumber(s:match("%d+"))
end

-- Looks in /proc instead of running kill -0: this is called on every
-- tick, and each os.execute forks matron, which on norns 2.x also runs a
-- non-realtime JACK client (matron-clock).
function Transmit.running()
  local pid = Transmit.pid()
  local f = pid and io.open("/proc/" .. pid .. "/stat", "r")
  if not f then return false end
  local state = (f:read("*l") or ""):match("^%d+ %b() (%a)")
  f:close()
  return state ~= nil and state ~= "Z"
end

-- Last lines of darkice's log, for the error screen.
function Transmit.log_tail(n)
  local s = read_file(Transmit.logfile) or ""
  local lines = {}
  for line in s:gmatch("[^\n]+") do
    if line:match("%S") then lines[#lines + 1] = line end
  end
  local out = {}
  for i = math.max(1, #lines - (n or 4) + 1), #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

-- Start darkice and connect the source ports to it once it is up.
function Transmit.start(c, opts)
  Transmit.stop()
  sh("mkdir -p '" .. Transmit.dir .. "'")
  if not write_file(Transmit.cfg, config(c, opts)) then
    return false, "can't write config"
  end
  sh("chmod 600 '" .. Transmit.cfg .. "'") -- holds the token
  local src = Transmit.SOURCES[opts.source] or Transmit.SOURCES[1]
  local cl = Transmit.CLIENT
  local script = table.concat({
    -- realtime limits for darkice's JACK thread, see Listen.RT_LIMITS
    "sudo -n prlimit --pid $$ --rtprio=95:95"
      .. " --memlock=unlimited:unlimited >/dev/null 2>&1",
    "darkice -c '" .. Transmit.cfg .. "' > '" .. Transmit.logfile .. "' 2>&1 &",
    "echo $! > '" .. Transmit.pidfile .. "'",
    "i=0",
    "while [ $i -lt 40 ]; do",
    "  jack_lsp 2>/dev/null | grep -q '^" .. cl .. ":left$' && break",
    "  sleep 0.25; i=$((i+1))",
    "done",
    "jack_connect " .. src.ports[1] .. " " .. cl .. ":left",
    "jack_connect " .. src.ports[2] .. " " .. cl .. ":right",
  }, "\n")
  local launcher = Transmit.dir .. "start.sh"
  if not write_file(launcher, script .. "\n") then
    return false, "can't write launcher"
  end
  sh("nohup sh '" .. launcher .. "' >/dev/null 2>&1 &")
  return true
end

-- Stop darkice (ours, or one left over from before a restart).
function Transmit.stop()
  local pid = Transmit.pid()
  if pid then sh("kill " .. pid .. " 2>/dev/null") end
  sh("pkill -f 'darkice -c " .. Transmit.cfg .. "' 2>/dev/null")
  os.remove(Transmit.pidfile)
  os.remove(Transmit.cfg)
end

return Transmit
