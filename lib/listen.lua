-- listen.lua: play a nullband signal into norns.
--
-- mpg123 in remote mode decodes the stream and writes raw 48 kHz audio to
-- jack-stdin, which plays it into JACK (client "jstdin"). Stations are
-- switched and the level changed through mpg123's command FIFO, so the
-- JACK side stays connected while tuning. mpg123's status lines (@S stream
-- started, @E error, @P 0 stopped) go to a log that the mod reads.
--
-- Like darkice, the pipeline runs detached and keeps playing while scripts
-- are loaded and unloaded.

local Listen = {}

Listen.dir = _path.data .. "nullcast/"
Listen.fifo = Listen.dir .. "listen.fifo"
Listen.pidfile = Listen.dir .. "listen.pid"
Listen.logfile = Listen.dir .. "listen.log"

-- plain http: mpg123 has no TLS. The Icecast port serves the same mounts
-- as https://nullband.org/icecast/<mount>.
Listen.BASE = "http://nullband.org:8000/"

Listen.ROUTES = {
  { name = "norns in", ports = { "crone:input_1", "crone:input_2" } },
  { name = "headphones", ports = { "system:playback_1", "system:playback_2" } },
}

local function sh(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, s)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

local log_pos = 0

function Listen.pid()
  local s = read_file(Listen.pidfile)
  return s and tonumber(s:match("%d+"))
end

function Listen.running()
  local pid = Listen.pid()
  return pid ~= nil and sh("kill -0 " .. pid .. " 2>/dev/null")
end

-- Send command lines to mpg123. Never blocks matron: the lines go into a
-- temp file and a background shell copies it into the FIFO, with a
-- timeout in case mpg123 is gone and nobody reads. The shell waits for
-- mpg123's "@R" greeting in the log: mpg123 replaces the FIFO while it
-- starts, and anything written before that is lost. Writes take turns
-- (flock) with a pause after each: mpg123 reopens the FIFO when a writer
-- closes it, and a second write landing in that moment is dropped.
local seq = 0
local function command(...)
  seq = seq + 1
  local tmp = Listen.dir .. "cmd." .. seq
  if not write_file(tmp, table.concat({ ... }, "\n") .. "\n") then return end
  sh("(timeout 5 flock " .. Listen.dir .. "listen.lock sh -c 'until grep -q ^@R "
    .. Listen.logfile .. " && [ -p " .. Listen.fifo .. " ]; do sleep 0.1; done; "
    .. "cat " .. tmp .. " > " .. Listen.fifo .. "; sleep 0.2'; rm -f " .. tmp
    .. ") >/dev/null 2>&1 &")
end

-- jackd runs synchronously (-S): every cycle waits for every client, so a
-- client whose process thread isn't realtime causes xruns for crone,
-- softcut and SuperCollider alike. libjack makes that thread SCHED_FIFO
-- only if the process may: on norns 2.x norns-matron.service has no
-- LimitRTPRIO, so whatever matron starts gets rtprio 0 (norns 3's
-- norns-main.service sets 95). The launchers raise their shell's limits
-- with passwordless sudo, and the clients they start inherit them. Where
-- sudo -n isn't available (desktop) nothing changes.
Listen.RT_LIMITS = "sudo -n prlimit --pid $$ --rtprio=95:95"
  .. " --memlock=unlimited:unlimited >/dev/null 2>&1"

-- route: index into ROUTES, volume: 0-100, mount: first station (checked
-- with api.safe), loaded in the same write as the setup commands
function Listen.start(route, volume, mount)
  Listen.stop()
  sh("mkdir -p '" .. Listen.dir .. "'")
  local r = Listen.ROUTES[route] or Listen.ROUTES[1]
  -- setsid makes the shell a process group leader, so stop() can signal
  -- the whole pipeline
  local script = table.concat({
    "echo $$ > '" .. Listen.pidfile .. "'",
    Listen.RT_LIMITS,
    "rm -f '" .. Listen.fifo .. "'",
    -- mpg123 ignores SIGTERM in remote mode. When systemd stops norns it
    -- sends SIGTERM to everything in the unit and then waits 90 s for
    -- mpg123 (and JACK is left with a stale crone client). setpriv makes
    -- the kernel SIGKILL mpg123 as soon as this shell dies, which it does
    -- on SIGTERM. (A trap here proved unreliable.)
    "PD=; command -v setpriv >/dev/null && PD='setpriv --pdeathsig KILL'",
    -- float32 on both sides, explicitly: in remote mode mpg123 picks f32
    -- for raw output, while jack-stdin defaults to 16-bit, which turns the
    -- stream into static. -b/--preload fill 0.6 of a 512 kB (~1.3 s) buffer
    -- before playing, again after each LOAD, so starts and retunes don't
    -- underrun jack-stdin.
    "$PD mpg123 -R --remote-err --fifo '" .. Listen.fifo .. "' -s -r 48000 --stereo"
      .. " -e f32 -b 512 --preload 0.6"
      .. " 2>>'" .. Listen.logfile .. "'"
      .. " | jack-stdin -q -e float -S 32768 " .. r.ports[1] .. " " .. r.ports[2]
      .. " 2>/dev/null &",
    "wait",
  }, "\n")
  local launcher = Listen.dir .. "listen.sh"
  if not write_file(launcher, script .. "\n") then
    return false, "can't write launcher"
  end
  write_file(Listen.logfile, "")
  log_pos = 0
  sh("setsid sh '" .. launcher .. "' >/dev/null 2>&1 </dev/null &")
  command("SILENCE", "VOLUME " .. math.floor(util.clamp(volume, 0, 100)),
    "LOAD " .. Listen.BASE .. mount)
  return true
end

-- mount must already be checked with api.safe
function Listen.load(mount)
  command("LOAD " .. Listen.BASE .. mount)
end

function Listen.volume(v)
  command("VOLUME " .. math.floor(util.clamp(v, 0, 100)))
end

-- mpg123 catches SIGTERM in remote mode and keeps going, so it gets
-- SIGKILL; it holds nothing worth a clean exit. Synchronous, so it also
-- works from system_pre_shutdown.
function Listen.stop()
  local pid = Listen.pid()
  if pid then sh("kill -TERM -" .. pid .. " 2>/dev/null") end
  sh("pkill -KILL -f 'mpg123 -R --remote-err --fifo " .. Listen.fifo .. "' 2>/dev/null")
  os.remove(Listen.pidfile)
  os.remove(Listen.fifo)
end

-- New status events since the last call: a list of "started", "error"
-- and "stopped".
function Listen.events()
  local f = io.open(Listen.logfile, "r")
  if not f then return {} end
  local size = f:seek("end")
  if size < log_pos then log_pos = 0 end
  f:seek("set", log_pos)
  local s = f:read("*a") or ""
  f:close()
  -- keep a partial last line for next time
  local last_nl = s:match(".*()\n")
  if not last_nl then return {} end
  log_pos = log_pos + last_nl
  local out = {}
  for line in s:sub(1, last_nl):gmatch("[^\n]+") do
    if line:match("^@S ") then out[#out + 1] = "started"
    elseif line:match("^@E ") then out[#out + 1] = "error"
    elseif line:match("^@P 0") then out[#out + 1] = "stopped" end
  end
  return out
end

return Listen
