# Call health

Open call details, then Call health. The browser shows measured round-trip delay, packet loss, jitter, concealed audio, jitter-buffer delay and receiving bitrate. Unsupported metrics stay unavailable. It samples at five-second intervals for at most eight peers, keeps twelve samples in memory, and requests analysis at most every ten seconds per peer. No recordings or audio samples are sent to the worker, logged, or stored in PostgreSQL.

## Optional native analysis

Install a C compiler and gfortran on the build host, then run:

```sh
./scripts/build-media-quality.sh
python3 test/native_quality.py
PLAINWIRE_TEST_NATIVE=1 rebar3 eunit
rebar3 release
```

Build before creating the Erlang release so `priv/bin/pw-media-quality` is included. The native executable is intentionally excluded from the portable source archive. The target host needs the matching libgfortran runtime. `FC` and `CC` may select compiler executables.

`PLAINWIRE_MEDIA_QUALITY=auto` uses an installed worker. `off` disables it. `PLAINWIRE_MEDIA_QUALITY_BIN` may specify an absolute executable path. Missing or failed workers leave ordinary calling and browser measurements working. `pw_media_quality:available()` reports availability in the Erlang shell.

Fortran performs rolling statistics, percentile calculation, dispersion, and time-based trends. A small C wrapper handles a length-prefixed, big-endian binary64 protocol. It validates counts, finite numbers, units and sample order. Each request contains at most 24 rows of nine numbers; each response contains nineteen numbers (the backend also accepts the old thirteen-field response during upgrades). The BEAM port has one active request, 31 queued requests, a 250 ms analysis timeout and a one-second queue deadline. Failed workers restart with bounded backoff. An OS alarm also terminates a stuck native calculation.

The quality score is a transparent heuristic, **not MOS, a learned model, or an audio-quality guarantee**. Starting at 100, it subtracts bounded penalties for mean loss, jitter p95 above 20 ms, RTT above 150 ms, concealment and buffer delay above 80 ms. Two relevant metrics must each have at least three observations spanning ten seconds. Coverage counts actual observations, not merely metrics seen once. A separate evidence percentage combines coverage with the observed time span; it is not a statistical confidence interval. Bitrate variation is reported separately so ordinary speech/silence changes do not lower the score. Median pairwise slopes use actual elapsed time and resist one-off outliers. A recent score covers the last twenty seconds, and a separate outgoing score uses repeated remote loss feedback. Loss-burst analysis measures observed intervals with at least 3% loss, excluding missing samples and gaps over twenty seconds. Delay p95 exposes latency spikes. Counter resets and long browser suspension discard invalid rate history; stale analysis is cleared.

Erlang owns recommendations. `PLAINWIRE_ADAPTIVE_SCREEN=true` optionally permits a conservative per-peer screen limit after three consecutive poor upstream recommendations: no more than 750 kb/s and 15 fps. Six healthy analyses with a good outgoing score restore the normal participant-based tier. The default is false. This never changes microphone tracks, permissions, codecs, mute state, or call ownership. It does not replace WebRTC congestion control.

The browser reads remote RTCP timestamps to avoid counting the same feedback repeatedly, and selects the active ICE pair for fallback RTT. See the [W3C WebRTC statistics definitions](https://www.w3.org/TR/webrtc-stats/). Call details show the new numerical measurements. No audio content is analyzed by Fortran.
