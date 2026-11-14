/*
 * nullcast-rx: play raw stereo float32 from stdin into JACK.
 *
 *   mpg123 -s -r 48000 -e f32 --stereo URL | nullcast-rx <client> <left> <right>
 *
 * Connects its ports "left" and "right" to the given ports. Reads stdin in
 * large blocks into a ring buffer (jack-stdin reads one frame per read(),
 * which takes ~20% of a core on a Pi 4). Waits for PRELOAD seconds of
 * audio before playing, and again after running dry, so stream starts and
 * retunes don't stutter. On EOF (the decoder quit) or SIGTERM/SIGINT/SIGHUP
 * it deactivates before closing, so JACK never calls into freed memory
 * (mpg123's own JACK output gets that order wrong and crashes).
 *
 * Built on the device by the mod's installer:
 *   gcc -O2 -o nullcast-rx nullcast_rx.c -ljack
 */

#include <errno.h>
#include <signal.h>
#include <sys/mman.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <jack/jack.h>
#include <jack/ringbuffer.h>

#define CHANNELS 2
#define FRAME (CHANNELS * sizeof(float))
#define RATE 48000
#define RING_SECONDS 1.0
#define PRELOAD_SECONDS 0.5
#define MAX_NFRAMES 8192

static jack_client_t *client;
static jack_port_t *ports[CHANNELS];
static jack_ringbuffer_t *ring;
static size_t preload_bytes;
static int buffering = 1; /* only touched by the process callback */
static float procbuf[MAX_NFRAMES * CHANNELS];
static volatile sig_atomic_t quit;

static int process(jack_nframes_t n, void *arg)
{
	float *out[CHANNELS];
	jack_nframes_t got = 0;
	(void)arg;

	for (int c = 0; c < CHANNELS; c++)
		out[c] = jack_port_get_buffer(ports[c], n);

	size_t avail = jack_ringbuffer_read_space(ring);
	if (buffering && avail >= preload_bytes)
		buffering = 0;

	if (!buffering) {
		jack_nframes_t want = n > MAX_NFRAMES ? MAX_NFRAMES : n;
		jack_nframes_t have = avail / FRAME;
		got = have < want ? have : want;
		jack_ringbuffer_read(ring, (char *)procbuf, got * FRAME);
		for (jack_nframes_t i = 0; i < got; i++)
			for (int c = 0; c < CHANNELS; c++)
				out[c][i] = procbuf[i * CHANNELS + c];
		if (got < n)
			buffering = 1; /* ran dry: wait for the preload again */
	}
	for (int c = 0; c < CHANNELS; c++)
		memset(out[c] + got, 0, (n - got) * sizeof(float));
	return 0;
}

static void on_shutdown(void *arg)
{
	(void)arg;
	quit = 1;
}

static void on_signal(int sig)
{
	(void)sig;
	quit = 1;
}

int main(int argc, char **argv)
{
	static char buf[65536];
	size_t off = 0, pending = 0;
	jack_status_t status;

	if (argc != 4) {
		fprintf(stderr, "usage: %s <client> <left port> <right port>\n", argv[0]);
		return 2;
	}

	/* no SA_RESTART: a signal interrupts the blocking read() */
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	client = jack_client_open(argv[1], JackNoStartServer, &status);
	if (!client) {
		fprintf(stderr, "nullcast-rx: can't connect to JACK (status 0x%x)\n", status);
		return 1;
	}
	if (jack_get_sample_rate(client) != RATE) {
		fprintf(stderr, "nullcast-rx: JACK runs at %u Hz, expected %d\n",
			jack_get_sample_rate(client), RATE);
		jack_client_close(client);
		return 1;
	}

	ring = jack_ringbuffer_create((size_t)(RATE * RING_SECONDS) * FRAME);
	if (!ring) {
		fprintf(stderr, "nullcast-rx: out of memory\n");
		jack_client_close(client);
		return 1;
	}
	preload_bytes = (size_t)(RATE * PRELOAD_SECONDS) * FRAME;

	/* No page faults in the realtime callback: lock what's mapped now and
	   later (the launcher raises RLIMIT_MEMLOCK; without it this fails and
	   the ring buffer lock below still helps), and touch procbuf once. */
	mlockall(MCL_CURRENT | MCL_FUTURE);
	jack_ringbuffer_mlock(ring);
	memset(procbuf, 0, sizeof procbuf);

	const char *names[CHANNELS] = { "left", "right" };
	for (int c = 0; c < CHANNELS; c++) {
		ports[c] = jack_port_register(client, names[c], JACK_DEFAULT_AUDIO_TYPE,
			JackPortIsOutput, 0);
		if (!ports[c]) {
			fprintf(stderr, "nullcast-rx: can't register port %s\n", names[c]);
			jack_client_close(client);
			jack_ringbuffer_free(ring);
			return 1;
		}
	}

	jack_set_process_callback(client, process, NULL);
	jack_on_shutdown(client, on_shutdown, NULL);
	if (jack_activate(client)) {
		fprintf(stderr, "nullcast-rx: can't activate the JACK client\n");
		jack_client_close(client);
		jack_ringbuffer_free(ring);
		return 1;
	}
	for (int c = 0; c < CHANNELS; c++)
		if (jack_connect(client, jack_port_name(ports[c]), argv[2 + c]))
			fprintf(stderr, "nullcast-rx: can't connect to %s\n", argv[2 + c]);

	while (!quit) {
		if (pending == 0) {
			ssize_t r = read(STDIN_FILENO, buf, sizeof buf);
			if (r == 0)
				break; /* EOF: the decoder is gone */
			if (r < 0) {
				if (errno == EINTR)
					continue;
				break;
			}
			off = 0;
			pending = (size_t)r;
		}
		size_t w = jack_ringbuffer_write(ring, buf + off, pending);
		off += w;
		pending -= w;
		if (pending) {
			/* ring full: let the callback play some of it */
			struct timespec ts = { 0, 5000000 };
			nanosleep(&ts, NULL);
		}
	}

	jack_deactivate(client); /* no callbacks after this */
	jack_client_close(client);
	jack_ringbuffer_free(ring);
	return 0;
}
