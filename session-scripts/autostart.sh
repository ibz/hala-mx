#!/bin/bash
# autostart.sh - what the XDG autostart entry runs on graphical login.
#
# Not a replacement for start-46.sh, just a porch for it. Two things have to
# be true before start-46.sh can work, and neither is guaranteed at the moment
# a desktop session hands control to ~/.config/autostart:
#
#   1. PipeWire has to be up for THIS user. It is a user service started around
#      the same time we are, so on a cold login we can easily win the race.
#   2. The INTERFACE has to have enumerated. USB audio interfaces take a few
#      seconds after the session starts, and the venue modes ABORT rather than
#      starting under-routed (which is correct - it just needs to be given the
#      chance).
#
# So: wait for the sink to appear, then hand over. If it never appears we still
# run start-46.sh, because its own error message is better than anything this
# script could invent, and it lands in the log below.
#
# WHICH sink to wait for depends on the mode, and waiting for the wrong one
# just burns the full 60 s before handing over anyway - so it is resolved from
# the mode below rather than hard coded to the hall's Focusrite.
#
# A discovering venue's FIRST run cannot happen here. It has to establish the interface by
# ear, which means a terminal and somebody listening; from autostart it will
# refuse with that message in the log. Run `./start-46.sh --<venue>` by hand once
# at the venue, and every login after that is unattended like the others.
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
UMC_RE='alsa_output\.usb-BEHRINGER_UMC404HD_192k-00\.pro-output-0'

case " $MODE " in
  *" --tnb "*|*" --nicapetre "*|*" --nica "*)
    # A venue whose interface was established by ear: wait for ITS saved sink.
    # An unconfigured one has nothing to wait for - hand straight over and let
    # start-46.sh say so properly.
    case " $MODE " in
      *" --tnb "*) V=tnb ;;
      *)           V=nicapetre ;;
    esac
    WANT="$V's interface"
    conf=$("$HERE/venue-interface.sh" "$V" --path 2>/dev/null)
    SINK_RE=$(sed -n "s/^VENUE_SINK='\(.*\)'$/\1/p" "$conf" 2>/dev/null | head -1 \
              | sed 's/[][\.*^$+?(){}|]/\\&/g')
    [ -n "$SINK_RE" ] || { WANT=""; echo "$V is not configured yet - not waiting"; }
    ;;
  *" --simulation "*|*" --sim "*|*" -s "*|*"-simulation "*|*" --tnb-sim "*|*" --nica-sim "*)
    WANT="the UMC404HD"; SINK_RE="$UMC_RE" ;;
  *)
    WANT="the Focusrite"; SINK_RE="$FOCUSRITE_RE" ;;
esac

if [ -n "$WANT" ]; then
  for i in $(seq 60); do            # up to 60 s, checked every second
    if pactl list short sinks 2>/dev/null | cut -f2 | grep -qE "^$SINK_RE$"; then
      echo "$WANT present after ${i}s"
      break
    fi
    [ "$i" = 60 ] && echo "WARNING: no sink for $WANT after 60s - handing over anyway"
    sleep 1
  done
fi

echo "exec start-46.sh $MODE"
exec "$HERE/start-46.sh" $MODE
