# AGENTS.md

Notes for the next agent session on the nullband mod. The user-facing docs
are in README.md; this file covers state, test setup and open work.

## State (2026-11-12)

Transmit works end to end on a norns shield (260616, armv7l, 10.0.0.138):
token request, darkice install through norns-deps, on air with countdown
and unit number, stream audible on nullband.org, stop with confirm. The
ticker survives script loads (fixed in 98de3b3).

## Testing on the shield

Use the noseda skill (`references/tasks/debug.md`).

- ssh `we@10.0.0.138`, passwordless sudo. `RemoveIPC` is off, so ssh
  logouts don't break JACK.
- Deploy: `git archive --prefix=nullband/ HEAD | gzip > x.tgz`, copy, untar
  in `~/dust/code`. The mod loads its modules with `dofile` at startup, so
  any Lua change needs `sudo systemctl restart norns-sclang norns-main`.
- Drive the page from the REPL: `_menu.set_mode(true); _menu.set_page("nullband")`,
  then `_menu.key(3,1); _menu.key(3,0)`. Read state through the menu's upvalue:
  `debug.getupvalue(_menu.m.nullband.key, i)` named `S`.
- `screen.export_screenshot("x")` writes to `norns.state.data`, which is the
  current script's data folder, not `~/dust/data/`. Delete it afterwards.
- Load a script that makes sound first (`awake`), otherwise the stream is
  silence.
- Check the stream from outside: `curl -m 6 https://nullband.org/icecast/<mount>`
  and `ffmpeg -af volumedetect`.
- **Every on-air test uses up a single-use token and is public on
  nullband.org.** Ask the user before tests that go on air.
- If norns-main hangs at "setting up jack clients..", JACK is wedged (seen
  once, likely nb_fluid's fluidsynth service; separate issue). Recover:
  stop norns-main and norns-sclang, restart norns-jack, sleep 4, start
  norns-sclang and norns-main.

## Not tested yet

- [ ] Settings page: E1 switch, E2/E3 edits, saving to
      `~/dust/data/nullband/settings.lua`, locked items while on air.
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
- [ ] Uninstall through modhousekeeper: `lib/uninstall.lua` removes darkice
      (it is in the manifest), stops transmission, deletes
      `~/dust/data/nullband`.
- [ ] curl install path: curl was already on the shield.
- [ ] A fresh install from git (`;install`), once there is a public repo.

## Next feature: listen page

Discussed, not started. Nullband serves every signal, ghosts included, at
`https://nullband.org/icecast/<mount>`. The live list is in `/health`
(`signals`) or the `wss://nullband.org/ws` push (`type: "signals"`).

Plan: a LISTEN page in this mod. Decode with `mpg123 -o jack` (light on a
Pi 3; a norns-deps dependency), route to `crone:input_1/2` so scripts can
process it, or to `system:playback` to just listen. E2/K3 choose a station
from `/health`. Add a params group in `script_post_init` (station,
play/stop, level) so it can be MIDI-mapped. Guard against feedback: if
listening goes into norns while transmit source is `norns out`, ask for a
confirm before going on air (rebroadcasting others breaks nullband's
original-material rule).

## Repo

- Commit as vehka <vehka@iki.fi> (set in this repo's git config).
- `lib/deps.lua` and `lib/deps/` are vendored from vehka/norns-deps at
  6dbc4a6; don't edit them here, update from upstream.
- Remote `hw` = `hw.iki.fi:git/nullband` (a working copy with
  `receive.denyCurrentBranch=updateInstead`). No GitHub repo yet.
