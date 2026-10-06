#!/usr/bin/env bash
#
# channel-levels.sh - what is ACTUALLY reaching each speaker, in dB.
#
# Records the sink's own monitor and prints RMS and peak per channel. This
# answers "I cannot hear monitor 3" without involving ears, the amplifier or
# anything else downstream: if a channel reads -inf here, nothing is being sent
# to it and the fault is in the piece. If it reads a healthy level and you
# still hear nothing, the fault is downstream - cable, amp, speaker - and no
# amount of editing the desk will help.
#
#   ./channel-levels.sh              5 s of the UMC
#   ./channel-levels.sh 10           10 s
#   ./channel-levels.sh 5 <sink>     another interface
#
# Leave the piece playing; recording a monitor does not disturb it.
#
# parec on <sink>.monitor, not `pw-record --target <sink>`: the latter attaches
# to nothing here and writes a zero-length file.
set -uo pipefail
SECS="${1:-5}"
SINK="${2:-}"
[ -n "$SINK" ] || SINK=$(pactl list short sinks 2>/dev/null | cut -f2 | grep -m1 UMC404HD)
[ -n "$SINK" ] || { echo "no sink given and no UMC found"; exit 1; }
command -v parec >/dev/null || { echo "missing: parec (apt install pulseaudio-utils)"; exit 1; }

N=$(pactl list short sources 2>/dev/null | grep -F "${SINK}.monitor" | grep -oE '[0-9]+ch' | grep -oE '[0-9]+')
[ "${N:-0}" -gt 0 ] || N=2

RAW=$(mktemp); trap 'rm -f "$RAW"' EXIT
echo "recording ${SECS}s x ${N}ch from ${SINK}.monitor ..."
# head -c, not timeout: parec buffers, and a SIGTERM throws away everything it
# has not flushed - a 2 s request came back with 0.17 s. head closes the pipe
# the instant it has exactly the bytes asked for.
BYTES=$((48000 * 2 * N * SECS))
parec -d "${SINK}.monitor" --channels="$N" --format=s16le --rate=48000 --raw 2>/dev/null \
  | head -c "$BYTES" > "$RAW"
[ -s "$RAW" ] || { echo "  captured nothing"; exit 1; }

python3 - "$RAW" "$N" <<'INNER'
import struct, sys, math
raw = open(sys.argv[1], "rb").read()
ch  = int(sys.argv[2])
n   = len(raw) // (2 * ch)
if n == 0:
    print("  captured nothing"); sys.exit(1)
d = struct.unpack("<%dh" % (n * ch), raw[:n * ch * 2])
print("  %d frames, %d channels, %.2f s" % (n, ch, n / 48000.0))
print()
print("  ch |     RMS |    peak | bar")
for c in range(ch):
    s   = d[c::ch]
    rms = math.sqrt(sum(x * x for x in s) / len(s)) / 32768.0
    pk  = max(abs(x) for x in s) / 32768.0
    f   = lambda v: "%7.1f" % (20 * math.log10(v)) if v > 1e-9 else "   -inf"
    bar = int(max(0, (20 * math.log10(rms) + 70) / 2)) if rms > 1e-9 else 0
    print("  %2d | %s | %s | %s" % (c + 1, f(rms), f(pk), "#" * bar))
INNER
