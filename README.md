# nullband

A norns mod that transmits to [nullband](https://nullband.org). Request a
one-time token, go on air, and stop from the mod menu. A 45-minute countdown
shows the time left in the transmission window. The stream keeps running while
you load and play other scripts.

Nullband is for original transmissions: field recordings, live performance,
generative systems, ambient sound. Commercial music will be removed.

## Install

```
;install https://github.com/vehka/nullband
```

Enable it in SYSTEM > MODS, then restart norns. The first time you request a
token, the mod offers to install what it needs: `darkice` (and `curl` if it's
missing), through [norns-deps](https://github.com/vehka/norns-deps).

## Use

SYSTEM > MODS > NULLBAND

| control | |
|---|---|
| E1 | transmit / settings page |
| K3 | request token → go on air → stop (asks to confirm) |
| K2 | back; cancels or discards a token before going on air |

1. **K3 request token**: fetches single-use credentials from nullband.org.
2. **K3 go on air**: starts darkice and connects the audio. The mod waits up
   to 60 s for nullband to detect the signal.
3. **ON AIR**: the countdown runs from 45:00 and the screen shows your unit
   number. Press K2 to leave the page; the transmission keeps going.
4. **K3 stop**, then K3 again to confirm.

Each token is single use. If the stream drops (network, server), it does not
reconnect. Request a new token instead.

### Settings (E1 → page 2, E2 select, E3 change)

- **source**: `norns out` (everything norns plays, `crone:output_1/2`) or
  `inputs` (the raw audio inputs, `system:capture_1/2`)
- **bitrate**: 96–320 kbps MP3, default 128
- **ghost transmission**: on by default; off asks nullband not to keep a
  ghost of your transmission
- **stop at 00:00**: stop by itself when the window is over (default off;
  nullband lets a stream run on past it)

Source and bitrate can't change while on air.

## How it works

`darkice` reads stereo audio from JACK (client `nullband`) and sends MP3
straight to `nullband.org:8000` as an Icecast source, with the token as the
password and `live-<token>` as the mount. Nothing runs locally besides
darkice. The mod polls `https://nullband.org/health` to see when the stream is
on air and which unit it got.

Files live in `~/dust/data/nullband/`: `settings.lua`, and while
transmitting, `darkice.cfg` (holds the token; mode 600), `darkice.log` and
`darkice.pid`.

## Uninstall

Removing the mod with [modhousekeeper](https://github.com/vehka/modhousekeeper)
runs `lib/uninstall.lua`. It stops any transmission, removes the packages the
mod installed (never ones that were there before), and deletes its data.

## Credits

The idea of streaming norns' JACK output with darkice comes from
[broadcast](https://github.com/schollz/broadcast) by schollz and its
fork by aidanreilly. `lib/deps.lua` and `lib/deps/` are vendored from
norns-deps (MIT).
