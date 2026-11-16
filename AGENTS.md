# AGENTS.md

Notes for the next agent session on the nullcast mod. The user-facing docs
are in README.md; this file covers state, test setup and open work.

## State (2026-11-14)

On a norns shield (v3.0.1, armv7l, 10.0.0.138):

- Transmit works end to end: token request, darkice install through
  norns-deps, on air with countdown and unit number, stream audible on
  nullband.org, stop with confirm.
- Listen works: mpg123 + nullcast-rx install through norns-deps, station
  list from `/health`, play into `crone:input_1/2`, tuning with E2 (LOAD
  over the FIFO), level with E3, route change to headphones, K3 stop,
  playing on across a script load, the `nullcast_listen` param.
- The FFT visualiser runs (scsynth about +1.5% DSP); band data reaches Lua.
- Pages switch with K1+E1 (norns only passes E1 to a menu page while K1 is
  held, `lua/core/menu.lua` `_menu.enc`). Settings E2/E3 and saving work.
- The ticker used to cancel another mod's clock on every script load: clock
  ids are reused and nb_* pre_init hooks run before ours, so our stale id
  could point at their new clock (`clock.lua:62 ... thread expected`). It
  now cancels only while `clock.threads[id]` is still its own coroutine.

On a fates (rp4, norns 2.x update 250926, armv7l, 10.0.0.2):

- Install needed norns-deps' archived-Raspbian-buster repair (the old
  raspbian.raspberrypi.org host is gone); then listen works.
- Listening caused xruns (`!!!` on the home screen, ~16 per minute, audio
  dropouts). jackd runs synchronously (`-S`) and 2.x's
  norns-matron.service has no `LimitRTPRIO`, so jack-stdin (started from
  matron) got a non-realtime JACK thread. The launchers now raise their
  shell's limits with `sudo -n prlimit` (`Listen.RT_LIMITS`, also in
  transmit.lua for darkice): the JACK process thread is SCHED_FIFO 90 and
  listening runs without xruns. The shield on norns 3 never showed it:
  norns-main.service sets `LimitRTPRIO=95`.
- jack-stdin took ~20% of a core (its reader thread calls `read()` once
  per 8-byte frame) plus ~9% for mpg123. mpg123's own JACK output
  (`-o jack`) was tried and dropped: its close unregisters the ports and
  frees the ring buffer *before* `jack_client_close`, so the realtime
  callback can run on freed memory ("jack_port_get_buffer called with an
  incorrect port", then SIGSEGV). mpg123 opens/closes the device several
  times at startup to probe formats (twice with `-r`, ~18 times without),
  and segfaulted on 10-30% of starts on the shield (1.26.4); with `-b` its
  buffer process fails too ("buffer overflow detected", "out123 error 8").
  Each crash is a burst of xruns for every client.
- Now: `mpg123 -s -r 48000 -e f32 --stereo | nullcast-rx` (lib/nullcast_rx.c,
  built by a norns-deps `cmd` step into `~/dust/data/nullcast/bin/`
  `nullcast-rx-N`; bump N in `Listen.RX` when the source changes). Reads
  64 kB blocks into a 1 s ring buffer, prebuffers 0.5 s (and again after
  running dry), mlockall()s, deactivates before closing. ~1% CPU for rx,
  ~1-5% for mpg123. Tested on both devices: install/build through the
  installer, 6/6 stop-start cycles, route changes there and back, retune,
  no leftover processes, 30 s capture with no gaps.
- Stopping: STOP+QUIT to mpg123 through the pipeline's own FIFO (files are
  per pipeline, `listen.<pgid>.*`, so nothing reaches the next pipeline);
  rx sees EOF and closes cleanly. A reaper SIGKILLs the process group after
  6 s. The pidfile is written by `start()` itself (from `$!`), and starts
  wait for pipelines still quitting. dash's `kill` has no `--`.
- Residual: on the fates about one 3-cycle burst (all clients late) per
  10 min of listening with the listen page open, none with it hidden or
  with the pipeline run by hand. `running()` used to fork matron
  (`kill -0`) every tick; it reads `/proc/<pid>/stat` now, which removed
  bursts that came every ~10 s.
- Measuring xruns: don't count while a non-realtime JACK client of your
  own runs (jack-stdout from ssh shows up as `jstdout was not finished`),
  nor during a service restart.
- `RemoveIPC` was on (systemd default): an ssh logout wiped JACK's shared
  memory ("audio system fail"). `loginctl enable-linger we` is set there
  now. Services: norns-jack/crone/sclang/matron (no norns-main); restart
  sclang, crone, matron in that order, like SYSTEM > RESTART.

## Testing on the shield

Use the noseda skill (`references/tasks/debug.md`).

- ssh `we@10.0.0.138`, passwordless sudo. `RemoveIPC` is off, so ssh
  logouts don't break JACK.
- Deploy: `git archive --prefix=nullcast/ HEAD | gzip > x.tgz`, copy, untar
  in `~/dust/code`. The mod loads its modules with `dofile` at startup, so
  any Lua change needs `sudo systemctl restart norns-sclang norns-main`.
  A change to `nullcast_vis.sc` needs the same (sclang compiles it).
- Always restart both. Restarting norns-main alone brings crone back as
  `crone-01` with SuperCollider unconnected (no engine audio, no bands).
  Check with `jack_lsp | grep crone-01`; fix with the JACK recovery below.
- The listen pipeline and darkice run in norns-main's cgroup, so a systemd
  stop kills them. mpg123 ignores SIGTERM in remote mode, so `listen.sh`
  starts it under `setpriv --pdeathsig KILL` (dies with the shell). A
  shell trap was tried first and failed intermittently: systemd then waits
  90 s and JACK ends up with a stale crone client.
- mpg123's raw output must be float (`-e f32`): nullcast-rx reads float32,
  and jack-stdin once turned 16-bit into static. jack-stdout writes float
  by default even though it prints "16bit". Check audio by capturing a port
  with `jack-stdout -e float <ports>` and comparing it with
  `curl .../icecast/<mount> | ffmpeg -f f32le`; energy above 14 kHz shows
  static or underrun clicks.
- Back-to-back writes to mpg123's FIFO can be lost (it reopens the FIFO
  when a writer closes). `command()` serialises them with flock.
- Never `pkill -f` a pattern from an ssh command line: it matches the ssh
  shell itself. Put the pkill in a script file on the shield.
- sclang REPL: websocket on 5556 like the Lua one on 5555, but end the code
  with `\x1b` (ESC), not a newline. Output comes back over the socket.
- `scripts/nrepl.py` needs `websocket-client`; a venv in the scratchpad
  works.
- `jack-stdout` from ssh for captures: raise its limits first
  (`sudo -n prlimit --pid $$ --rtprio=95:95 --memlock=unlimited:unlimited`)
  or it causes xruns itself. Count glitches as `XRun` *and*
  `Process error` lines in `journalctl -u norns-jack`.
- On norns 3, `_norns.screen_export_png` can catch a half-drawn frame.
- Drive the page from the REPL: `_menu.set_mode(true); _menu.set_page("nullcast")`,
  then `_menu.key(3,1); _menu.key(3,0)`. Read state through the menu's upvalue:
  `debug.getupvalue(_menu.m.nullcast.key, i)` named `S`.
- `screen.export_screenshot("x")` writes to `norns.state.data`, which is the
  current script's data folder, not `~/dust/data/`. Delete it afterwards.
- Load a script that makes sound first (`awake`), otherwise the stream is
  silence.
- Check the stream from outside: `curl -m 6 https://nullband.org/icecast/<mount>`
  and `ffmpeg -af volumedetect`.
- **Every on-air test uses up a single-use token and is public on
  nullband.org.** Ask the user before tests that go on air.
- If norns-main hangs at "setting up jack clients..", or `jack_lsp`
  hangs, JACK is wedged (seen when systemd had to SIGKILL sclang/scsynth).
  Recover: stop norns-main and norns-sclang, restart norns-jack, sleep 4,
  start norns-sclang and norns-main.
- Listening needs no token and isn't public; it's fine to test freely.

## Not tested yet

- [ ] Settings items locked while on air (dimmed, E3 ignored).
- [x] Listen and transmit at once, `norns out` source: the station is
      audible in the transmission (needs a token).
- [ ] Own signal: tick on the dial while live, skipped with `skip`,
      tunable with `allow`, listening stops if switched back to `skip`.
- [ ] Listen failure paths: station disappears while playing ("no
      signal"), mpg123 killed ("decoder stopped"), no network at K3.
- [ ] Visualiser fallback without FFTSubbandPower (mono BPF bank).
- [ ] Params: previous/next station while not on the listen page; MIDI
      mapping survives a script reload.
- [ ] Sleep while listening (`system_pre_shutdown` stops the pipeline).
- [ ] systemd stop while listening with the pdeathsig launcher: passed
      once (1 s, nothing left over); repeat a few times.
- [ ] Source `inputs` (`system:capture_1/2`) and bitrates other than 128.
- [ ] Ghost opt-out: setting off → `POST /admin/ghost-optout` once on air.
      Confirm the server accepts it (response, and whether the ghost is
      really suppressed).
- [ ] Stop at 00:00 (autostop): needs 45 minutes on air, or temporarily
      lower `WINDOW` on the device copy.
- [ ] Overtime display past 00:00 with autostop off (`+mm:ss`).
- [ ] Dropped stream: kill darkice or cut the network while live; expect
      the "dropped" error screen with the darkice log tail.
- [ ] Detection timeout: no signal within 60 s → "no signal detected"
      (e.g. a wrong mount on purpose).
- [ ] Token request failures: no network, curl timeout, unexpected reply.
- [ ] K2 paths: discard a token in READY, cancel while CONNECTING, back
      while live (transmission continues).
- [ ] Matron restart while live: `system_post_startup` should kill the
      orphaned darkice.
- [ ] Sleep (`system_pre_shutdown`) while live stops darkice.
- [ ] Uninstall through modhousekeeper: `lib/uninstall.lua` removes darkice,
      mpg123, jack-stdio (in the manifest), stops both, deletes
      `~/dust/data/nullcast`.
- [ ] curl install path: curl was already on the shield.
- [x] A fresh install from git (`;install`), once there is a public repo.

## Ideas

- The visualiser reads SuperCollider's inputs, so in `headphones` mode it
  shows nothing. Feeding it there would need another path into scsynth.
- Bars rise toward the highs on the `sky-*` stations even after the
  sqrt(bin count) normalisation; tune `WINDOW_DB`, the curve in `animate`
  or the cut frequencies in `nullcast_vis.sc` by eye.
- `wss://nullband.org/ws` pushes the signal list (`type: "signals"`);
  polling `/health` every 10 s is enough for now.

## Repo

- `lib/deps.lua` and `lib/deps/` are vendored from vehka/norns-deps at
  6dbc4a6; don't edit them here, update from upstream.
