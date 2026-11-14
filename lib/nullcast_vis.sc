// nullcast_vis.sc: band levels for the nullcast listen page.
//
// sclang compiles every class under ~/dust, so this loads even when the mod
// is off. It only sets up OSC responders; the analysis synth runs while the
// mod keeps pinging it (the listen page is open and a station is playing)
// and frees itself a few seconds after the pings stop.
//
// The synth reads SuperCollider's inputs (what crone sends to the engine:
// the audio inputs plus a stream routed to "norns in"), splits each channel
// into `bands` FFT sub-bands (1024 points) and sends their levels to matron
// as /nullcast/bands, left channel first, then right. About 1.5% of the
// server's DSP time on a Pi 3.

NullcastVis {
	const <bands = 20;
	classvar synth, matron, deadline = 0, watching = false;

	*initClass {
		StartUp.add {
			OSCdef(\nullcastVisPing, { |msg|
				NullcastVis.ping(msg[1] ? 15);
			}, '/nullcast/vis/ping').permanent_(true);

			OSCdef(\nullcastVisStop, {
				NullcastVis.stop;
			}, '/nullcast/vis/stop').permanent_(true);

			OSCdef(\nullcastVisBands, { |msg|
				NullcastVis.matron.sendMsg('/nullcast/bands', *msg[3..]);
			}, '/nullcast/bands').permanent_(true);
		};
	}

	// matron's general OSC port, which reaches Lua (Crone.remoteAddr is
	// matron's crone-only port and doesn't)
	*matron {
		^matron ?? { matron = NetAddr("127.0.0.1", 10111) };
	}

	*ping { |rate|
		deadline = Main.elapsedTime + 4;
		if(synth.isNil) { this.start(rate) };
		if(watching.not) {
			watching = true;
			SystemClock.sched(1, {
				if(Main.elapsedTime > deadline) {
					this.stop;
					watching = false;
					nil
				} { 1 }
			});
		};
	}

	*start { |rate|
		var server = Server.default;
		var me;
		if(server.serverRunning.not) { ^nil };
		// mark as starting so pings in the meantime don't start another
		synth = \starting;
		fork {
			SynthDef(\nullcast_vis, { |rate = 15|
				var in = SoundIn.ar([0, 1]);
				var amps;
				// FFTSubbandPower is in sc3-plugins (part of norns); looked up
				// by name so a system without it still compiles this class
				var subband = \FFTSubbandPower.asClass;
				if(subband.notNil) {
					// bands - 1 cut frequencies make `bands` bands. The plugin
					// sums the bins of a band, so divide by the square root of
					// the bin count: pink noise then reads flat.
					var cuts = Array.geom(bands - 1, 60, (7000 / 60) ** (1 / (bands - 2)));
					var binHz = (server.sampleRate ? 48000) / 1024;
					var edges = [0] ++ cuts ++ [(server.sampleRate ? 48000) / 2];
					var norm = edges.differentiate.drop(1).collect { |w|
						(w / binHz).max(1).sqrt.reciprocal
					};
					amps = in.collect { |c|
						subband.kr(FFT(LocalBuf(1024), c, 0.5), cuts, 0, 1) * norm
					}.flat;
				} {
					// fallback: a mono band-pass bank, the same on both sides
					var freqs = Array.geom(bands, 50, (12000 / 50) ** (1 / (bands - 1)));
					amps = freqs.collect { |f|
						Amplitude.kr(BPF.ar(in.sum, f, 0.3), 0.01, 0.2)
					};
					amps = amps ++ amps;
				};
				SendReply.kr(Impulse.kr(rate), '/nullcast/bands', amps);
			}).send(server);
			server.sync;
			// skip if stopped while the def was on its way
			if(synth == \starting) {
				me = Synth(\nullcast_vis, [\rate, rate], RootNode(server), \addToTail);
				me.onFree { if(synth === me) { synth = nil } };
				synth = me;
			};
		};
	}

	*stop {
		if(synth.isKindOf(Synth)) { synth.free };
		synth = nil;
		deadline = 0;
	}
}
