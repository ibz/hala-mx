#!/usr/bin/env bash
#
# start-session.sh - launch Sonic Pi the way this piece needs it launched.
#
# PIPEWIRE_LATENCY is the one that is easy to lose: it has to be in the
# ENVIRONMENT of the Sonic Pi process, so starting Sonic Pi from the desktop
# menu, or from a terminal without it, silently gets you the bad behaviour
# back. That is the whole reason this file exists.
#
# HONEST NOTE ON WHAT IT DOES: setting it took the piece from dying after
# ~60 s (LATE spikes over 1000 ms, then audioDeviceStopped -> cold swap ->
# job nuked) to running. It did NOT change the callback granularity - the
# drift counter still reports ~5.7 callbacks/second, i.e. ~8192 samples per
# callback, and `first audio callback: numSamples=8192` still appears in the
# log. So this is a mitigation that works, not a root cause that is
# understood. Treat a long run as evidence, not the log line.
#
#   ./start-session.sh          check audio, then launch Sonic Pi
#   ./start-session.sh --no-check   skip the audio checks (not for the hall)

set -uo pipefail
cd "$(dirname "$0")"

APPIMAGE="${SONIC_PI_APPIMAGE:-$HOME/Downloads/Sonic-Pi-for-Linux-x64-v5.0.0.AppImage}"
LATENCY="${SONIC_PI_LATENCY:-1024/48000}"

if [ "${1:-}" != "--no-check" ]; then
  ./setup-audio.sh || {
    printf '\033[31m\nAudio checks failed - fix them before a session.\033[0m\n'
    printf 'Override with: %s --no-check\n' "$0"
    exit 1
  }
fi

[ -x "$APPIMAGE" ] || { echo "Sonic Pi not found or not executable: $APPIMAGE" >&2
                        echo "Set SONIC_PI_APPIMAGE=/path/to/it" >&2; exit 1; }

printf '\n\033[1mLaunching Sonic Pi with PIPEWIRE_LATENCY=%s\033[0m\n' "$LATENCY"
echo "Paste the desk into Buffer 0, then press Run:"
echo "    wl-copy < sonic-pi-buffer.rb"
echo
echo "Once it is playing, watch it with:"
echo "    ./check-session.sh"
echo

exec env PIPEWIRE_LATENCY="$LATENCY" "$APPIMAGE"
