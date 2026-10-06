#!/usr/bin/env bash
#
# tone-test.sh - play a rising 3-note chime on one output port at a time, so
# you can confirm by ear which physical jack (or ADAT-expander channel) each
# one actually reaches. Neither PipeWire's ACP labels nor the Focusrite's own
# scarlett2 driver control names are trustworthy enough to skip this - see
# README 7d, "Production's interface is the Scarlett 18i20."
#
#   ./tone-test.sh                  test the confirmed 12: AUX0-7, AUX12-15
#   ./tone-test.sh AUX2 AUX3        test only specific ports, in the order given
#   ./tone-test.sh --all-adat       AUX0-7 plus all 8 ADAT channels (AUX12-19)
#
#   ./tone-test.sh --sink <node> [ports...]
#                                   test any interface, not just the Focusrite.
#                                   With no ports, every playback port the node
#                                   has, in sort -V order. A port may be given
#                                   bare (AUX2, FL) or fully qualified
#                                   (node:playback_AUX2) - the latter is how
#                                   venue-interface.sh passes a hand-ordered list,
#                                   since on an unknown card the channel order
#                                   is exactly what is in question.
#
#   --label-from N                  number the ports from N when announcing
#                                   them, so the sweep reads "output 1, output
#                                   2, ..." against the rig rather than against
#                                   whatever the port happens to be called.
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

# --sink/--label-from are stripped first, so what is left in "$@" is the port
# list in both the Focusrite case and the arbitrary-interface one.
SINK=""
LABEL_FROM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sink)        SINK="${2:-}"; shift 2 || { echo "--sink needs a node name"; exit 1; } ;;
    --label-from)  LABEL_FROM="${2:-}"; shift 2 || { echo "--label-from needs a number"; exit 1; } ;;
    *)             break ;;
  esac
done
case "$LABEL_FROM" in ''|*[!0-9]*) echo "--label-from: not a number: $LABEL_FROM"; exit 1 ;; esac

if [ -n "$SINK" ]; then
  if ! pactl list short sinks 2>/dev/null | cut -f2 | grep -qx "$SINK"; then
    echo "no such sink: $SINK"
    echo "  available:"
    pactl list short sinks 2>/dev/null | cut -f2 | sed 's/^/    /'
    exit 1
  fi
else
  SINK=$(pactl list short sinks 2>/dev/null | cut -f2 | grep -E "$FOCUSRITE_RE" | head -1)
  if [ -z "$SINK" ]; then
    echo "no Focusrite pro-audio sink found."
    echo "  is it plugged in, and switched to the pro-audio ALSA profile?"
    echo "    pactl set-card-profile alsa_card.usb-Focusrite_Scarlett_18i20_USB_*-00 pro-audio"
    echo "  for any other interface, name it: ./tone-test.sh --sink <node>"
    exit 1
  fi
fi

PORTS=()
case "${1:-}" in
  --all-adat)
    PORTS=(AUX0 AUX1 AUX2 AUX3 AUX4 AUX5 AUX6 AUX7 AUX12 AUX13 AUX14 AUX15 AUX16 AUX17 AUX18 AUX19)
    ;;
  "")
    if [[ "$SINK" =~ $FOCUSRITE_RE ]]; then
      # The confirmed-by-ear 12 that start-46.sh --production actually uses.
      PORTS=(AUX0 AUX1 AUX2 AUX3 AUX4 AUX5 AUX6 AUX7 AUX12 AUX13 AUX14 AUX15)
    else
      # Unknown interface: everything it has, in the order pw-link lists it
      # after a natural sort. That order is a GUESS - confirming or refuting it
      # is the whole point of the sweep.
      mapfile -t PORTS < <(pw-link -i 2>/dev/null \
        | sed -n "s/^$(printf '%s' "$SINK" | sed 's/[][\.*^$\/]/\\&/g'):playback_//p" | sort -V)
      [ "${#PORTS[@]}" -gt 0 ] || { echo "no playback ports on $SINK"; exit 1; }
    fi
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

ch=$LABEL_FROM
for aux in "${PORTS[@]}"; do
  # Bare suffix (AUX2, FL) or a fully qualified node:port - the second form
  # lets a caller sweep a hand-ordered list without this script re-deriving it.
  case "$aux" in
    *:*) dst="$aux" ;;
    *)   dst="$SINK:playback_$aux" ;;
  esac

  pw-play --target 0 --channels 1 "$BEEP" >/dev/null 2>&1 &
  pid=$!

  # wait for its port to appear before linking, up to ~1s
  for _ in $(seq 20); do
    pw-link -o 2>/dev/null | grep -qx "pw-play:output_MONO" && break
    sleep 0.05
  done

  if pw-link "pw-play:output_MONO" "$dst" 2>/dev/null; then
    echo "### NOW PLAYING: output $ch   ($aux)"
  else
    echo "### LINK FAILED: output $ch   ($aux) - not in the graph? pw-link -i | grep '${aux##*:}'"
  fi

  wait "$pid" 2>/dev/null
  sleep 0.5
  ch=$((ch + 1))
done

echo
echo "done. compare what you heard, in order, against the rig's channel map."
