#!/usr/bin/env bash
#
# tone-test.sh - play a rising 3-note chime on one Focusrite output port at a
# time, so you can confirm by ear which physical jack (or ADAT-expander
# channel) each one actually reaches. Neither PipeWire's ACP labels nor the
# Focusrite's own scarlett2 driver control names are trustworthy enough to
# skip this - see README 7d, "Production's interface is the Scarlett 18i20."
#
#   ./tone-test.sh                  test the confirmed 12: AUX0-7, AUX12-15
#   ./tone-test.sh AUX2 AUX3        test only specific ports, in the order given
#   ./tone-test.sh --all-adat       AUX0-7 plus all 8 ADAT channels (AUX12-19)
#
# WHY NOT `pw-play --target <sink>:<port>`: it looks like it should work, but
# --target only accepts a node name/serial, not a port suffix - it silently
# falls back to auto-connect and every "test" lands on the same one or two
# ports. This script does what actually works: start the stream with
# `--target 0` ("don't auto-link"), then `pw-link` its port to the exact
# port under test - the same mechanism link-outs.sh uses for real.
#
# WHY NOT raw ALSA (`speaker-test -D hw:X,Y`): PipeWire holds the card
# exclusively, so it fails with "device busy" while PipeWire is running.

set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
FOCUSRITE_RE='^alsa_output\.usb-Focusrite_Scarlett_18i20_USB_[^.]+-00\.pro-output-0$'

command -v pw-play >/dev/null 2>&1 || { echo "missing: pw-play (apt install pipewire-bin)"; exit 1; }
command -v pw-link >/dev/null 2>&1 || { echo "missing: pw-link (apt install pipewire-bin)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "missing: python3 (needed to synthesise the test tone)"; exit 1; }

SINK=$(pactl list short sinks 2>/dev/null | cut -f2 | grep -E "$FOCUSRITE_RE" | head -1)
if [ -z "$SINK" ]; then
  echo "no Focusrite pro-audio sink found."
  echo "  is it plugged in, and switched to the pro-audio ALSA profile?"
  echo "    pactl set-card-profile alsa_card.usb-Focusrite_Scarlett_18i20_USB_*-00 pro-audio"
  exit 1
fi

PORTS=()
case "${1:-}" in
  --all-adat)
    PORTS=(AUX0 AUX1 AUX2 AUX3 AUX4 AUX5 AUX6 AUX7 AUX12 AUX13 AUX14 AUX15 AUX16 AUX17 AUX18 AUX19)
    ;;
  "")
    # The confirmed-by-ear 12 that start-46.sh --production actually uses.
    PORTS=(AUX0 AUX1 AUX2 AUX3 AUX4 AUX5 AUX6 AUX7 AUX12 AUX13 AUX14 AUX15)
    ;;
  *)
    PORTS=("$@")
    ;;
esac

BEEP=$(mktemp --suffix=.wav)
trap 'rm -f "$BEEP"' EXIT
python3 - "$BEEP" <<'PY'
import wave, math, struct, sys
path = sys.argv[1]
rate = 48000
beep_dur, gap_dur, fade = 0.25, 0.15, 240
freqs = [329.63, 440.0, 554.37]  # rising chime - distinct from a flat tone/hum
n_beep, n_gap = int(rate*beep_dur), int(rate*gap_dur)

def beep(freq):
    out = []
    for i in range(n_beep):
        env = min(1.0, i/fade, (n_beep-i)/fade)
        out.append(int(32767 * 0.5 * env * math.sin(2*math.pi*freq*i/rate)))
    return out

seq = []
for f in freqs:
    seq += beep(f)
    seq += [0]*n_gap

with wave.open(path, "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(b"".join(struct.pack("<h", s) for s in seq))
PY

echo "sink: $SINK"
echo "testing ${#PORTS[@]} port(s) in order, ~1.3s apart"
echo

for aux in "${PORTS[@]}"; do
  pw-play --target 0 --channels 1 "$BEEP" >/dev/null 2>&1 &
  pid=$!

  # wait for its port to appear before linking, up to ~1s
  for _ in $(seq 20); do
    pw-link -o 2>/dev/null | grep -qx "pw-play:output_MONO" && break
    sleep 0.05
  done

  if pw-link "pw-play:output_MONO" "$SINK:playback_$aux" 2>/dev/null; then
    echo "### NOW PLAYING: $aux"
  else
    echo "### LINK FAILED: $aux (port not in the graph? check pw-link -i | grep $aux)"
  fi

  wait "$pid" 2>/dev/null
  sleep 0.5
done

echo
echo "done. compare what you heard, in order, against monitors.tsv."
