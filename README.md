# nullcast

A norns mod for [nullband](https://nullband.org): listen to the signals on
air, and transmit your own, from the mod menu. Listening plays a station into
norns like an audio input, so scripts, softcut and engines can process it.
Transmitting requests a one-time token and shows a 45-minute countdown. Both
keep running while you load and play other scripts, and both can run at once.

Nullband is for original transmissions: field recordings, live performance,
generative systems, ambient sound. Commercial music will be removed.

## Install

```
;install https://github.com/vehka/nullcast
```

Enable it in SYSTEM > MODS, then restart norns. The first time you listen or
request a token, the mod offers to install what that needs, through
[norns-deps](https://github.com/vehka/norns-deps): `mpg123` and `jack-stdio`
for listening, `darkice` for transmitting (and `curl` if it's missing).

## Use

SYSTEM > MODS > NULLCAST. Hold K1 and turn E1 to switch pages: listen,
transmit, settings (the dots at the top show where you are). K2 leaves the
menu; whatever is playing or transmitting keeps going.

### Listen

| control | |
|---|---|
| E2 | tune: move to the next station on the dial |
| E3 | level |
| K3 | listen / stop |

The dial at the bottom shows every signal on air: bright dots are live,
dim ones are ghosts (nullband replaying a past transmission). Each signal
keeps its place on the dial while it's on air, so new ones appear without
the others moving. There are no frequencies: signals come and go too often
for numbers to mean anything. The square is the tuner. It glides to the
station you pick, and its outline crawls while the station loads, with a
little static in the bars.

The bars show the incoming audio in 20 bands, low to high, the left channel
growing up and the right down. They come from a small SuperCollider analysis
that runs only while the listen page is open and a station is playing into
norns (`nullcast_vis.sc`, about 1.5% of the audio server's DSP time on a Pi 3).
They show what goes into norns, so a microphone on the inputs shows up too.

The station goes into norns' inputs, mixed with the audio inputs: you hear
it through the monitor (AUDIO > monitor), scripts and engines that take
input process it, and softcut can record it. Set **listen into** to
`headphones` to just listen, straight to the outputs; the bars stay flat then.

### Transmit

| control | |
|---|---|
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

Nullband is for original transmissions. Recasting other signals live is
fine: listen into norns, process the station with a script, and transmit
with source `norns out`. (`inputs` is the raw audio inputs only, without
the station.)

### Settings (E2 select, E3 change)

- **transmit source**: `norns out` (everything norns plays,
  `crone:output_1/2`) or `inputs` (the raw audio inputs,
  `system:capture_1/2`)
- **bitrate**: 96–320 kbps MP3, default 128
- **ghost transmission**: on by default; off asks nullband not to keep a
  ghost of your transmission
- **stop at 00:00**: stop by itself when the window is over (default off;
  nullband lets a stream run on past it)
- **listen into**: `norns in` (default) or `headphones`
- **own signal**: `skip` (default) or `allow`. While you transmit, your own
  signal is on the dial too, marked with a tick. Listening to it into norns
  while transmitting `norns out` makes a feedback loop through nullband, a
  delay of several seconds through the MP3 encoder each time around. With
  the monitor below unity it fades like a tape echo; at unity or above it
  builds up into loud clipped noise, which is what listeners hear. `allow`
  lets you tune to it; keep an eye on the levels.

Transmit source, bitrate and ghost can't change while on air.

### Params

Every script gets a NULLCAST group in PARAMS, for MIDI mapping: **listen**
(toggle), **listen level**, **previous station** and **next station**. They
follow the mod's state and aren't saved in PSETs.

## How it works

The mod polls `https://nullband.org/health` for the signals on air, and to
see when your own stream is on air and which unit it got.

Listening: `mpg123` in remote mode reads `http://nullband.org:8000/<mount>`
and decodes it to 48 kHz float, buffering about half a second before it
plays; `jack-stdin` plays that into JACK (client `jstdin`), connected to
`crone:input_1/2` or `system:playback_1/2`. Tuning and the level go to
mpg123 through a FIFO, so the JACK side stays connected.

Transmitting: `darkice` reads stereo audio from JACK (client `nullcast`) and
sends MP3 straight to `nullband.org:8000` as an Icecast source, with the
token as the password and `live-<token>` as the mount.

Files live in `~/dust/data/nullcast/`: `settings.lua`; while listening
`listen.sh`, `listen.fifo`, `listen.log` and `listen.pid`; while
transmitting `darkice.cfg` (holds the token; mode 600), `darkice.log` and
`darkice.pid`.

## Uninstall

Removing the mod with [modhousekeeper](https://github.com/vehka/modhousekeeper)
runs `lib/uninstall.lua`. It stops listening and transmitting, removes the
packages the mod installed (never ones that were there before), and deletes
its data. `lib/nullcast_vis.sc` goes with the mod's folder; sclang stops
loading it at the next restart.

## Credits

The idea of streaming norns' JACK output with darkice comes from
[broadcast](https://github.com/schollz/broadcast) by schollz and its
fork by aidanreilly. `lib/deps.lua` and `lib/deps/` are vendored from
norns-deps (MIT).
