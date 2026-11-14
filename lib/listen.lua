-- listen.lua: play a nullband signal into norns.
--
-- mpg123 in remote mode decodes the stream to raw 48 kHz float, and
-- nullcast-rx (lib/nullcast_rx.c, built at install) plays that into JACK
-- (client "nullcast_listen"). Stations are switched and the level changed
-- through mpg123's command FIFO, so the JACK side stays connected while
-- tuning. mpg123's status lines (@S stream
-- started, @E error, @P 0 stopped) go to a log that the mod reads.
--
-- Like darkice, the pipeline runs detached and keeps playing while scripts
-- are loaded and unloaded.

local Listen = {}

Listen.dir = _path.data .. "nullcast/"
Listen.pidfile = Listen.dir .. "listen.pid"
Listen.CLIENT = "nullcast_listen"
-- the version in the name makes a changed nullcast_rx.c build anew
Listen.RX = Listen.dir .. "bin/nullcast-rx-2"

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

-- Each pipeline has its own FIFO, log and lock, named after its process
-- group (listen.<pgid>.fifo), so a command or QUIT still on its way can't
-- reach the pipeline started after it, and an old pipeline's "@P 0" as it
-- quits isn't read as the new one stopping.
local function files(pid)
  local base = Listen.dir .. "listen." .. pid
  return { fifo = base .. ".fifo", log = base .. ".log", lock = base .. ".lock" }
end

local log_pid, log_pos = nil, 0
local quitting = {} -- { pid, at } of pipelines stop() sent QUIT to

function Listen.pid()
  local s = read_file(Listen.pidfile)
  return s and tonumber(s:match("%d+"))
end

-- Looks in /proc instead of running kill -0: this is called on every
-- tick, and each os.execute forks matron, which on norns 2.x also runs a
-- non-realtime JACK client (matron-clock).
function Listen.running()
  local pid = Listen.pid()
  local f = pid and io.open("/proc/" .. pid .. "/stat", "r")
  if not f then return false end
  local state = (f:read("*l") or ""):match("^%d+ %b() (%a)")
  f:close()
  return state ~= nil and state ~= "Z"
end

-- Send command lines to a pipeline's mpg123. Never blocks matron: the
-- lines go into a temp file and a background shell copies it into the
-- FIFO, with a timeout in case mpg123 is gone and nobody reads. The shell
-- waits for mpg123's "@R" greeting in the log: mpg123 replaces the FIFO
-- while it starts, and anything written before that is lost. Writes take
-- turns (flock) with a pause after each: mpg123 reopens the FIFO when a
-- writer closes it, and a second write landing in that moment is dropped.
local seq = 0
local function send(pid, ...)
  local f = files(pid)
  seq = seq + 1
  local tmp = Listen.dir .. "cmd." .. seq
  if not write_file(tmp, table.concat({ ... }, "\n") .. "\n") then return end
  sh("(timeout 5 flock " .. f.lock .. " sh -c 'until grep -q ^@R "
    .. f.log .. " 2>/dev/null && [ -p " .. f.fifo .. " ]; do sleep 0.1; done; "
    .. "cat " .. tmp .. " > " .. f.fifo .. "; sleep 0.2'; rm -f " .. tmp
    .. ") >/dev/null 2>&1 &")
end

local function command(...)
  local pid = Listen.pid()
  if pid then send(pid, ...) end
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
  -- One pipeline at a time: wait for the ones stop() sent off in the last
  -- 10 s (the reaper ends them within 6 s), so the JACK client keeps its
  -- name instead of becoming nullcast_listen-01 for a moment.
  local now, waits = util.time(), {}
  for i = #quitting, 1, -1 do
    if now - quitting[i].at > 10 then table.remove(quitting, i)
    else waits[#waits + 1] = quitting[i].pid end
  end
  local script = table.concat({
    "B='" .. Listen.dir .. "listen.'$$", -- files(pid): $$ is the group id
    "for p in " .. table.concat(waits, " ") .. "; do i=0;"
      .. " while [ $i -lt 140 ] && pgrep -g $p >/dev/null; do"
      .. " sleep 0.05; i=$((i+1)); done; done",
    Listen.RT_LIMITS,
    -- mpg123 ignores SIGTERM in remote mode. When systemd stops norns it
    -- sends SIGTERM to everything in the unit and then waits 90 s for
    -- mpg123 (and JACK is left with a stale crone client). setpriv makes
    -- the kernel SIGKILL mpg123 as soon as this shell dies, which it does
    -- on SIGTERM. (A trap here proved unreliable.)
    "PD=; command -v setpriv >/dev/null && PD='setpriv --pdeathsig KILL'",
    -- Not mpg123's own JACK output (-o jack): its close frees the ports
    -- and ring buffer before closing the client, so the realtime callback
    -- can run on freed memory. mpg123 opens and closes the device several
    -- times at startup to probe formats, and segfaulted on 10-30% of
    -- starts on a shield (1.26.4), each crash a burst of xruns for every
    -- JACK client. jack-stdin works but reads one frame per read() call
    -- (~20% of a core). nullcast-rx reads in blocks and prebuffers 0.5 s,
    -- also after running dry, which covers starts and retunes. It quits
    -- cleanly on EOF, i.e. when mpg123 does.
    "$PD mpg123 -R --remote-err --fifo \"$B.fifo\" -s -r 48000 -e f32 --stereo"
      .. " 2>>\"$B.log\" | '" .. Listen.RX .. "' " .. Listen.CLIENT
      .. " " .. r.ports[1] .. " " .. r.ports[2] .. " 2>>\"$B.log\" &",
    "wait",
  }, "\n")
  local launcher = Listen.dir .. "listen.sh"
  if not write_file(launcher, script .. "\n") then
    return false, "can't write launcher"
  end
  -- setsid makes the shell a process group leader (a background job of a
  -- non-interactive shell isn't one, so setsid execs in place and $! is
  -- the group id), and stop() can signal the whole pipeline. The pidfile
  -- is written before this returns, so a stop() right after finds it.
  sh("setsid sh '" .. launcher .. "' >/dev/null 2>&1 </dev/null & echo $! > '"
    .. Listen.pidfile .. "'")
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

-- The JACK client has to close itself: killed, it leaves JACK
-- (synchronous mode) waiting on a dead client, a burst of xruns for every
-- client. So stop() sends STOP and QUIT to mpg123 through the pipeline's
-- FIFO, the way commands go, which also covers a pipeline that is still
-- starting (the write waits for mpg123); nullcast-rx then sees EOF and
-- closes its client. None of it blocks matron. A background shell SIGKILLs
-- the pipeline's process group if it is still there after 6 s, and
-- removes its files, keeping the log as listen.last.log for when a
-- pipeline stopped by itself. mpg123 ignores SIGTERM in remote mode.
--
-- leftovers: also kill by name any of our mpg123s without a pidfile
-- (from before a matron restart, or for uninstall). Not for a normal stop:
-- it would kill an earlier pipeline that is still quitting cleanly.
function Listen.stop(leftovers)
  local pid = Listen.pid()
  if pid then
    quitting[#quitting + 1] = { pid = pid, at = util.time() }
    local f = files(pid)
    send(pid, "STOP", "QUIT")
    sh("(i=0; while [ $i -lt 120 ]; do"
      .. " pgrep -g " .. pid .. " >/dev/null || break;"
      .. " sleep 0.05; i=$((i+1)); done;"
      .. " [ $i -lt 120 ] || kill -KILL -" .. pid .. ";" -- dash: no "--"
      .. " sleep 1; mv -f " .. f.log .. " " .. Listen.dir .. "listen.last.log;"
      .. " rm -f " .. f.fifo .. " " .. f.lock
      .. ") >/dev/null 2>&1 &")
  elseif leftovers then
    -- rm first: pkill -f also matches this shell's own command line
    local d = Listen.dir
    sh("rm -f " .. d .. "listen.[0-9]*.fifo " .. d .. "listen.[0-9]*.log " .. d
      .. "listen.*.lock " .. d .. "listen.fifo " .. d .. "listen.log " .. d
      .. "listen.lock; pkill -KILL -f 'mpg123 -R --remote-err --fifo " .. d
      .. "listen.' 2>/dev/null")
  end
  os.remove(Listen.pidfile)
end

-- New status events since the last call: a list of "started", "error"
-- and "stopped".
function Listen.events()
  local pid = Listen.pid()
  if not pid then return {} end
  if pid ~= log_pid then log_pid, log_pos = pid, 0 end
  local f = io.open(files(pid).log, "r")
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
