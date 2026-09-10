#!/usr/bin/env bash
#
# start-46.sh - launch Sonic Pi 4.6.0 for a stated venue, with output routed to
# the right interface and the checked-in desk installed.
#
#   ./start-46.sh --production     Hala MX: 12 outputs, bleep OFF
#   ./start-46.sh --simulation     studio:   4 outputs on the UMC404HD, bleep ON
#
#   --keep        launch with whatever Buffer 0 already had (no desk install)
#   <number>      override the output count for this run (e.g. --production 8)
#
# THE MODE IS REQUIRED, deliberately. The two venues differ in ways that are
# silent when wrong - 12 vs 4 outputs changes how the spatial drawing folds,
# and the reference bleep belongs in the studio and nowhere near an audience -
# so the venue gets said out loud rather than inherited from whatever the last
# session happened to leave behind.
#
# WHY THIS EXISTS AT ALL: on Linux, scsynth's -H (sound_card_name in the toml)
# is the JACK SERVER name, not a device - it cannot select the interface, and
# setting it to "UMC404HD 192k Pro" makes scsynth hunt for a JACK server of
# that name. SC_JACK_DEFAULT_OUTPUTS names the ports explicitly instead, so the
# outputs land on the interface at boot rather than being re-patched by hand.
#
# That alone is NOT enough. Five seconds after scsynth boots, Sonic Pi patches
# the outputs itself (daemon.rb, run_post_start_commands) by grepping the graph
# for /alsa_output.*playback_FL$/. Those are consumer stereo port names; the
# UMC's pro-audio profile calls its ports playback_AUX0..AUX3, so the only node
# that matches is the built-in analog and out_1/out_2 get linked to the LAPTOP
# SPEAKERS - in ADDITION to the correct links, since daemon.rb adds rather than
# replaces. Result: the piece plays out of both devices at once, and channels
# 3+ are never touched at all.
#
# So this script also fires link-outs.sh in the background, which waits out
# daemon.rb's timer and then repatches to exactly $PORTS. Both mechanisms use
# the same port list computed below, so there is one source of truth.
#
# It also installs the desk. Sonic Pi's workspaces are its OWN storage - plain
# text at ~/.sonic-pi/store/default/workspace_<n>.spi, Buffer 0 being "zero" -
# and it AUTOSAVES them while running. So the buffer you edited in the GUI last
# session is what comes back, not sonic-pi-buffer.rb, and the two drift apart
# silently: the repo copy was once four settings behind a desk that had been
# live for days. Before launching, this script copies sonic-pi-buffer.rb into
# Buffer 0 and applies the mode's rig/bleep on top, so what starts is always
# what is checked in, configured for the venue you named.
#
# Nothing is thrown away: the outgoing buffer is backed up under
# ~/.sonic-pi/workspace-backups/, and Sonic Pi keeps its own git history of
# every autosave in ~/.sonic-pi/store/default/.git.

set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
SP="$HOME/src/sonic-pi/app/build/gui/sonic-pi"
BUFFER="$HERE/../sonic-pi-buffer.rb"
WS="$HOME/.sonic-pi/store/default/workspace_zero.spi"
BAKDIR="$HOME/.sonic-pi/workspace-backups"
TOML="$HOME/.sonic-pi/config/audio-settings.toml"
UMC="alsa_output.usb-BEHRINGER_UMC404HD_192k-00.pro-output-0"

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

MODE=""; KEEP=0; N=""
for arg in "$@"; do
  case "$arg" in
    --production|--prod|-p)   MODE=production ;;
    --simulation|--sim|-s)    MODE=simulation ;;
    --keep|--keep-workspace)  KEEP=1 ;;
    -h|--help)                usage 0 ;;
    ''|*[!0-9]*)              echo "unknown argument: $arg"; echo; usage 1 ;;
    *)                        N="$arg" ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "no mode given - say which venue this is."; echo
  usage 1
fi

# The venue profile. Only two things differ, but both are silent when wrong.
if [ "$MODE" = production ]; then
  N="${N:-12}"; BLEEP=false
else
  N="${N:-4}";  BLEEP=true
fi
echo "MODE: $MODE  ($N outputs, bleep $BLEEP)"
echo

[ -x "$SP" ] || { echo "not built: $SP"; exit 1; }

# Refuse while Sonic Pi is up: it autosaves the workspace on its own schedule,
# so anything written underneath a running GUI is overwritten by the copy the
# editor still holds in memory. That failure is silent and looks like the
# script not working.
if pgrep -x sonic-pi >/dev/null 2>&1; then
  echo "Sonic Pi is already running - quit it first, or its autosave will"
  echo "overwrite Buffer 0 with the copy the editor still has in memory."
  exit 1
fi

# --- routing, resolved FIRST ------------------------------------------------
# The desk's xen_rig_outputs has to match the ports actually found, not the
# ports we hoped for: it is what the piece folds the spatial drawing onto, so a
# desk claiming 12 over an 8-port graph draws into channels that do not exist.
# Resolving here means the install below writes the real number.
if [ "$MODE" = simulation ] && pw-link -i 2>/dev/null | grep -q "^$UMC:playback_"; then
  SINK="$UMC"
else
  SINK=$(pactl get-default-sink 2>/dev/null)
fi
[ -n "$SINK" ] || { echo "no default sink - is PipeWire running?"; exit 1; }

# NB: this trusts pw-link to emit ports in channel order. It does for the UMC,
# but the tool does not guarantee it - on a 12-out interface check the result
# against monitors.tsv before trusting the assignment.
PORTS=$(pw-link -i 2>/dev/null | grep "^$SINK:playback_" | head -n "$N" | paste -sd,)
[ -n "$PORTS" ] || { echo "no playback ports on $SINK - is the interface connected?"; exit 1; }
found=$(printf '%s' "$PORTS" | tr ',' '\n' | grep -c .)

if [ "$found" -lt "$N" ]; then
  # head -n returns what exists and says nothing, which in the hall would mean
  # discovering mid-concert that 8 of 12 channels were never routed.
  if [ "$MODE" = production ]; then
    echo "ABORT: asked for $N outputs, $SINK has $found."
    echo "       Production will not start under-routed. Check the interface,"
    echo "       or state the real count: ./start-46.sh --production $found"
    exit 1
  fi
  echo "WARNING: asked for $N outputs, $SINK has $found - continuing on $found."
  N="$found"
fi
echo "routing $N outputs -> $SINK"

# --- scsynth's own output count ---------------------------------------------
# num_outputs in audio-settings.toml becomes scsynth's -o. If it stays at 4 in
# the hall, channels 5-12 have no bus to land on and the routing above is
# irrelevant - the piece would play a third of itself, silently.
if [ -r "$TOML" ]; then
  cur=$(grep -oE '^num_outputs[[:space:]]*=[[:space:]]*[0-9]+' "$TOML" | grep -oE '[0-9]+$')
  if [ -z "$cur" ]; then
    echo "WARNING: no num_outputs in $TOML - scsynth may not get $N busses"
  elif [ "$cur" != "$N" ]; then
    cp "$TOML" "$TOML.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i -E "s/^num_outputs[[:space:]]*=[[:space:]]*[0-9]+/num_outputs = $N/" "$TOML"
    echo "audio-settings.toml: num_outputs $cur -> $N (backed up alongside)"
  fi
else
  echo "WARNING: $TOML not found - scsynth will use its own default"
fi
echo

# --- install the desk into Buffer 0 -----------------------------------------
if [ "$KEEP" = 1 ]; then
  echo "Buffer 0: left as-is (--keep)"
elif [ ! -r "$BUFFER" ]; then
  echo "WARNING: $BUFFER not found - launching with whatever Buffer 0 had"
else
  # Build the intended buffer first, mode applied, then compare against what is
  # there. Comparing before the overrides would report as drift the very
  # changes we are about to make ourselves.
  want=$(mktemp); trap 'rm -f "$want"' EXIT
  cp "$BUFFER" "$want"
  sed -i -E "s/^set :xen_rig_outputs, *[0-9]+/set :xen_rig_outputs, $N/" "$want"
  sed -i -E "s/^set :xen_bleep, *[a-z]+/set :xen_bleep, $BLEEP/" "$want"
  for k in xen_rig_outputs xen_bleep; do
    grep -q "^set :$k," "$want" || echo "WARNING: no 'set :$k' in the desk - mode not applied to it"
  done

  if [ -r "$WS" ] && cmp -s "$want" "$WS"; then
    echo "Buffer 0: already exactly this"
  else
    if [ -s "$WS" ]; then
      mkdir -p "$BAKDIR"
      bak="$BAKDIR/workspace_zero.$(date +%Y%m%d-%H%M%S).spi"
      cp "$WS" "$bak"
      # Show the settings that change, not the whole file - this is where by-ear
      # tuning done in the GUI, and never committed, shows up.
      d=$(diff <(grep -oE '^set :xen_[a-z_0-9]+, *[^ #]*' "$WS"   | sed 's/ *$//' | sort) \
               <(grep -oE '^set :xen_[a-z_0-9]+, *[^ #]*' "$want" | sed 's/ *$//' | sort))
      if [ -n "$d" ]; then
        echo "Buffer 0: settings changing (< live desk, > what is being installed)"
        printf '%s\n' "$d" | grep '^[<>]' | sed 's/^/    /'
      else
        echo "Buffer 0: same settings, comments/formatting differ"
      fi
      echo "    backup: $bak"
    fi
    mkdir -p "$(dirname "$WS")"
    cp "$want" "$WS"
    echo "Buffer 0: installed from sonic-pi-buffer.rb ($MODE)"
  fi
fi
echo

echo "SC_JACK_DEFAULT_OUTPUTS=$PORTS"
echo

# Repatch once Sonic Pi has finished its own wrong auto-patching. Detached, so
# it survives the exec below; output is tagged since it lands in this terminal
# alongside the GUI's, ~15 s in.
LINKER="$HERE/link-outs.sh"
if [ -x "$LINKER" ]; then
  ( "$LINKER" --wait "$PORTS" 2>&1 | sed 's/^/[link-outs] /' ) &
else
  echo "WARNING: $LINKER missing - outputs will stay on the internal speakers"
fi

echo "After it boots, verify with:"
echo "    pw-link -l | grep -A2 '^SuperCollider:out'"
echo
exec env SC_JACK_DEFAULT_OUTPUTS="$PORTS" "$SP"
