#!/bin/bash
# autostart.sh - what the XDG autostart entry runs on graphical login.
#
# Not a replacement for start-46.sh, just a porch for it. Two things have to
# be true before start-46.sh can work, and neither is guaranteed at the moment
# a desktop session hands control to ~/.config/autostart:
#
#   1. PipeWire has to be up for THIS user. It is a user service started around
#      the same time we are, so on a cold login we can easily win the race.
#   2. The Focusrite has to have enumerated. USB audio interfaces take a few
#      seconds after the session starts, and --production ABORTS rather than
#      starting under-routed (which is correct - it just needs to be given the
#      chance).
#
# So: wait for the sink to appear, then hand over. If it never appears we still
# run start-46.sh, because its own error message is better than anything this
# script could invent, and it lands in the log below.
#
# Everything goes to $LOG - a desktop session has nowhere to print.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
LOG="$HOME/.sonic-pi/autostart.log"
MODE="${1:---production}"
# NOT under ~/.sonic-pi/log/: Sonic Pi rotates that directory into history/ on
# every boot, which would take this file with it.
mkdir -p "$(dirname "$LOG")"

# Keep one previous run, so a failed login is still diagnosable after the next.
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== autostart $(date '+%F %T') mode=$MODE ==="

FOCUSRITE_RE='alsa_output\.usb-Focusrite_Scarlett_18i20_USB_[^.]+-00\.pro-output-0'
for i in $(seq 60); do            # up to 60 s, checked every second
  if pactl list short sinks 2>/dev/null | grep -qE "$FOCUSRITE_RE"; then
    echo "Focusrite present after ${i}s"
    break
  fi
  [ "$i" = 60 ] && echo "WARNING: no Focusrite sink after 60s - handing over anyway"
  sleep 1
done

echo "exec start-46.sh $MODE"
exec "$HERE/start-46.sh" $MODE
