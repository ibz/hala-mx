#!/usr/bin/env bash
#
# start-46.sh - launch Sonic Pi 4.6.0 for a stated venue, with output routed to
# the right interface and the checked-in desk installed.
#
#   ./start-46.sh --production     Hala MX: 12 outputs on the Focusrite 18i20, bleep OFF
#   ./start-46.sh --simulation     studio:   4 outputs on the UMC404HD, bleep ON
#
#   --keep        launch with whatever Buffer 0 already had (no desk install)
#   <number>      override the output count for this run:
#                   --simulation 2   work on a laptop's built-in stereo
#                   --production 8   a partially patched hall rig
#                 Without a number, --simulation DEGRADES to whatever the sink
#                 actually has (with a warning) while --production ABORTS - a
#                 concert must not start silently under-routed, a desk session
#                 should just work.
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
# THE PRODUCTION INTERFACE (Focusrite Scarlett 18i20) needs its own care, in
# two independent ways - confirmed by an actual per-channel tone test against
# the hall wiring on 2026-09-16, not just read off a label:
#
# 1. ALSA PROFILE. In the default "HiFi" profile it splits into a pile of
#    small stereo sinks, not one multichannel node - switch it once with
#    `pactl set-card-profile alsa_card.usb-Focusrite_Scarlett_18i20_USB_*-00
#    pro-audio` (WirePlumber remembers the choice per card, like it does for
#    the UMC). That profile exposes 20 discrete "playback_AUX0..19" ports,
#    which are raw PCM channels 1-20 in order (AUX0 = PCM 1, etc). PipeWire's
#    own "Line Output N+M" labels for these are an ACP guess and often WRONG.
#    Confirmed by ear: AUX0-7 (PCM 1-8) are the 8 real rear analog outs in
#    use here; AUX8-9 (PCM 9-10) are unused front headphone jacks; AUX10-11
#    are S/PDIF (untested); AUX12-19 are ADAT.
#
# 2. ROUTING MATRIX. Separately from all of the above, the 18i20 has its own
#    internal source-routing matrix - EVERY physical output (analog, S/PDIF,
#    ADAT) has an `amixer` "... Playback Enum" control picking what feeds it,
#    independent of which raw PCM channel PipeWire/ALSA thinks it's writing
#    to. `Analogue Output 01-10` happened to already be wired straight to
#    `PCM 1-10` on this unit, but `ADAT Output 1-8` was NOT wired to
#    `PCM 13-20` - it was pointed at unrelated inputs/PCM channels, so ADAT
#    was silent even though everything upstream (PipeWire routing, ALSA
#    channel count, mute/volume) was correct. fix_focusrite_adat_routing()
#    below sets it every run, since there is no guarantee this survives a
#    power cycle or a Focusrite Control change made by someone else.
#
# CONFIRMED WORKING (2026-09-16): 8 analog (AUX0-7) + the hall's ADAT
# expander's first 4 channels (AUX12-15) = the 12 channels production uses.
# The expander's other 4 channels (AUX16-19) are wired in software but
# UNTESTED against real hardware - only relevant if someone later runs
# `--production` with N > 12.
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
# Must agree with build-sonicpi-46.sh, which produces this binary. Both
# default to ~/src/sonic-pi and both honour $SONIC_PI_SRC.
SP="${SONIC_PI_SRC:-$HOME/src/sonic-pi}/app/build/gui/sonic-pi"
BUFFER="$HERE/../sonic-pi-buffer.rb"
WS="$HOME/.sonic-pi/store/default/workspace_zero.spi"
BAKDIR="$HOME/.sonic-pi/workspace-backups"
TOML="$HOME/.sonic-pi/config/audio-settings.toml"
UMC="alsa_output.usb-BEHRINGER_UMC404HD_192k-00.pro-output-0"
# Scarlett 18i20 (production, in the hall). Matched by pattern, not exact
# name - the serial number in the middle is specific to one physical unit.
FOCUSRITE_RE='^alsa_output\.usb-Focusrite_Scarlett_18i20_USB_[^.]+-00\.pro-output-0$'

# See "ROUTING MATRIX" above. Idempotent - safe to call every run.
fix_focusrite_adat_routing() {
  local card
  card=$(aplay -l 2>/dev/null | sed -n 's/^card \([0-9]*\): .*Scarlett 18i20.*/\1/p' | head -1)
  if [ -z "$card" ]; then
    echo "WARNING: could not find the Scarlett 18i20's ALSA card number - ADAT routing not checked"
    return
  fi
  command -v amixer >/dev/null 2>&1 || {
    echo "WARNING: amixer not found (apt install alsa-utils) - ADAT routing not checked"; return; }
  local i pcm before after
  for i in 1 2 3 4 5 6 7 8; do
    pcm="PCM $((12 + i))"
    before=$(amixer -c "$card" cget "name='ADAT Output $i Playback Enum'" 2>/dev/null \
      | sed -n "s/.*: values=\([0-9]*\)/\1/p")
    amixer -c "$card" cset "name='ADAT Output $i Playback Enum'" "$pcm" >/dev/null 2>&1
    after=$(amixer -c "$card" cget "name='ADAT Output $i Playback Enum'" 2>/dev/null \
      | sed -n "s/.*: values=\([0-9]*\)/\1/p")
    if [ "$before" = "$after" ]; then
      echo "  ADAT Output $i: already $pcm"
    else
      echo "  ADAT Output $i: -> $pcm (was item #$before)"
    fi
  done
}

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

# PREFLIGHT. Everything below drives PipeWire through these two binaries, and
# neither is a build dependency - a machine can compile Sonic Pi perfectly and
# still not have them. Their absence used to be indistinguishable from a real
# fault: `pactl get-default-sink` with stderr suppressed just returns nothing,
# which surfaced as "no default sink - is PipeWire running?" on a box where
# PipeWire was running fine.
miss=
for t in "pactl:pulseaudio-utils" "pw-link:pipewire-bin"; do
  bin=${t%%:*}; pkg=${t##*:}
  command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin   (apt install $pkg)"; miss=1; }
done
[ -n "$miss" ] && { echo; echo "install the package(s) above and try again."; exit 1; }

# Refuse while Sonic Pi is up: it autosaves the workspace on its own schedule,
# so anything written underneath a running GUI is overwritten by the copy the
# editor still holds in memory. That failure is silent and looks like the
# script not working.
if pgrep -x sonic-pi >/dev/null 2>&1; then
  echo "Sonic Pi is already running - quit it first, or its autosave will"
  echo "overwrite Buffer 0 with the copy the editor still has in memory."
  exit 1
fi

# REAP A PREVIOUS SESSION'S BACKEND.
#
# The check above has to stay a REFUSAL rather than a kill: Sonic Pi autosaves
# Buffer 0 on its own schedule, so killing a live editor can lose what is in
# it. But `pgrep -x sonic-pi` only ever sees the GUI, and when a session dies
# badly the GUI is precisely the part that goes - the backend survives it.
# tau/beam, spider-server, daemon.rb and scsynth all outlive their window, so
# the guard passes and the next launch starts on top of the corpse.
#
# That is not cosmetic. Measured on this machine 2026-09-16: an orphaned tau
# from a launch one minute earlier (reparented to systemd --user) sat there
# while a fresh session came up beside it, and every OSC packet arriving at the
# new spider's API port died in the decoder -
#
#     Critical: UDP Server Spider API Server for port [...37330...]
#     undefined method `%' for nil        (osc/oscdecode.rb:100)
#
# two taus with different port maps and tokens talking at one runtime. The GUI
# opened, scsynth booted, the log said "Booted Successfully", and Run did
# nothing at all - no error, no job, nothing anywhere near the piece. The only
# symptom was silence.
#
# So: no GUI, but backend remnants => clear them before launching.
SPROOT="${SONIC_PI_SRC:-$HOME/src/sonic-pi}"

# Matched by PATH under the Sonic Pi tree, then filtered by process name.
# Both halves matter: the path alone would also match an editor that happens
# to have one of these files open, and killing somebody's editor is a far
# worse failure than the one this is fixing.
sp_remnants() {
  local pids p comm out=
  pids=$( { pgrep -x scsynth
            pgrep -f "$SPROOT/app/build/gui/sonic-pi"
            pgrep -f "$SPROOT/app/server/ruby/bin/daemon\.rb"
            pgrep -f "$SPROOT/app/server/ruby/bin/spider-server\.rb"
            pgrep -f "$SPROOT/app/server/beam/tau"; } 2>/dev/null | sort -un)
  for p in $pids; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$comm" in
      sonic-pi|scsynth|beam.smp|erl_child_setup|ruby|ruby3.3|sh|epmd) out="$out $p" ;;
    esac
  done
  echo $out
}

sp_wait_gone() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(sp_remnants)" ] && return 0
    sleep 0.3
  done
  [ -z "$(sp_remnants)" ]
}

leftovers=$(sp_remnants)
if [ -n "$leftovers" ]; then
  echo "leftover Sonic Pi processes from a previous session:"
  # shellcheck disable=SC2086
  ps -o pid=,cmd= -p $leftovers 2>/dev/null | cut -c1-100 | sed 's/^/  /'
  # shellcheck disable=SC2086
  kill $leftovers 2>/dev/null
  # beam.smp does NOT die on SIGTERM - it ignores it and holds its ports.
  # Confirmed here: TERM took the GUI, daemon.rb, scsynth and both boot
  # scripts and left BOTH Erlang VMs running. So TERM, wait, then KILL
  # whatever is still standing rather than assuming TERM was enough.
  if ! sp_wait_gone; then
    still=$(sp_remnants)
    # shellcheck disable=SC2086
    kill -9 $still 2>/dev/null
    sp_wait_gone
  fi
  if [ -n "$(sp_remnants)" ]; then
    echo
    echo "ERROR: could not clear them - refusing to launch on top:"
    # shellcheck disable=SC2086
    ps -o pid=,cmd= -p $(sp_remnants) 2>/dev/null | cut -c1-100 | sed 's/^/  /'
    exit 1
  fi
  echo "  cleared."
fi

# --- routing, resolved FIRST ------------------------------------------------
# The desk's xen_rig_outputs has to match the ports actually found, not the
# ports we hoped for: it is what the piece folds the spatial drawing onto, so a
# desk claiming 12 over an 8-port graph draws into channels that do not exist.
# Resolving here means the install below writes the real number.
FOCUSRITE=$(pactl list short sinks 2>/dev/null | cut -f2 | grep -E "$FOCUSRITE_RE" | head -1)
if [ "$MODE" = simulation ] && pw-link -i 2>/dev/null | grep -q "^$UMC:playback_"; then
  SINK="$UMC"
elif [ "$MODE" = production ] && [ -n "$FOCUSRITE" ]; then
  # Same idea as the UMC above: the hall interface, when present, is always
  # the right choice for production - do not depend on whatever WirePlumber
  # happened to pick as the system default (that can drift, e.g. after a
  # reboot picks the HDMI monitor's sink instead).
  SINK="$FOCUSRITE"
  echo "Focusrite ADAT routing (its own internal matrix, separate from PipeWire):"
  fix_focusrite_adat_routing
  echo
else
  SINK=$(pactl get-default-sink 2>/dev/null)
fi
# Sinks present but no DEFAULT set is a recoverable state, not a fault: it
# happens when WirePlumber has not chosen one, or when its stored default
# points at a device that has since been unplugged - an absent UMC does
# exactly that. Falling back to the first sink beats refusing to start, as
# long as the choice is stated out loud. The routing line below prints it, and
# production still aborts if the port count is wrong.
if [ -z "$SINK" ] && [ "$(pactl list short sinks 2>/dev/null | wc -l)" -gt 0 ]; then
  SINK=$(pactl list short sinks 2>/dev/null | head -1 | cut -f2)
  echo "no default sink is set - falling back to the first one:"
  echo "    $SINK"
  echo "  (set one properly with: wpctl set-default <id>, see wpctl status)"
fi

if [ -z "$SINK" ]; then
  # Three different faults used to share one message. Separate them.
  if ! pactl info >/dev/null 2>&1; then
    echo "pactl cannot reach a sound server."
    echo "  Is PipeWire running for THIS user?"
    echo "    systemctl --user status pipewire pipewire-pulse wireplumber"
    echo "  Over SSH or on a bare TTY you also need an active user session -"
    echo "  XDG_RUNTIME_DIR must be set and the user systemd instance running."
  else
    echo "a sound server is up, but it reports no default sink."
    echo "  Is the interface connected and un-muted?"
    echo "    pactl list short sinks"
    echo "    wpctl status"
  fi
  exit 1
fi

# NB: this trusts pw-link to emit ports in channel order. It does for the UMC,
# but the tool does not guarantee it - on a 12-out interface check the result
# against monitors.tsv before trusting the assignment.
if [[ "$SINK" =~ $FOCUSRITE_RE ]]; then
  # Scarlett 18i20's 20 "playback_AUX*" ports (raw PCM channels 1-20, in
  # order). CONFIRMED BY EAR on 2026-09-16 against the actual hall wiring:
  #   AUX0-7    the 8 real rear analog outs in use here
  #   AUX8/9    front headphone jack ("Headphones 2") - unused, not wired
  #   AUX10/11  S/PDIF - untested, not currently used
  #   AUX12-19  ADAT - first 4 (AUX12-15) confirmed via the hall's expander,
  #             the other 4 (AUX16-19) wired in software but untested
  # Both headphone-jack ports (AUX8-11, which also covers S/PDIF) must still
  # be excluded from the auto-built list even though the analog block turned
  # out to be 8 wide rather than the 6 first assumed from PipeWire's ACP
  # labels alone.
  PORTS=$(pw-link -i 2>/dev/null \
    | grep -E "^$SINK:playback_AUX[0-9]+$" \
    | grep -vE ":playback_AUX(8|9|10|11)$" \
    | sort -V | head -n "$N" | paste -sd,)
else
  PORTS=$(pw-link -i 2>/dev/null | grep "^$SINK:playback_" | head -n "$N" | paste -sd,)
fi
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

# --- the desk has a HARD SIZE CEILING ---------------------------------------
#
# Pressing Run sends the WHOLE buffer to the runtime as one OSC string argument
# (/run-code, spider-server.rb:286), and the listener reads it with
# `recvfrom(16384)` (osc/udp_server.rb:89). A datagram bigger than that is
# silently TRUNCATED by the kernel on read, the trailing string argument loses
# its NUL terminator, and the decoder dies:
#
#     Critical: UDP Server Spider API Server ... had issues receiving
#     undefined method `%' for nil        (osc/oscdecode.rb:100)
#
# The listener `redo`s, so it survives and keeps serving - which is exactly what
# makes this so nasty. There is no crash, no message in the GUI, and no job:
# Run just does NOTHING, once per press, forever. Sonic Pi boots perfectly and
# the log says "Booted Successfully". Diagnosed 2026-09-16 after the desk grew
# past the line, having first blamed a stale tau.
#
# So: refuse to install a desk that cannot be run, and say so with the number.
# Reproduced directly against Sonic Pi's own encoder/decoder, not inferred.
OSC_LIMIT=16384          # osc/udp_server.rb:89, recvfrom buffer
OSC_OVERHEAD=64          # /run-code + type tags + token + workspace name, padded
DESK_MAX=$(( OSC_LIMIT - OSC_OVERHEAD ))
desk_bytes=$(wc -c < "$BUFFER")
if [ "$desk_bytes" -gt "$DESK_MAX" ]; then
  echo "ERROR: the desk is too big to run."
  echo "  $BUFFER is $desk_bytes bytes; the limit is $DESK_MAX."
  echo
  echo "  Run sends the whole buffer as one OSC string and the runtime reads"
  echo "  only $OSC_LIMIT bytes, so this would install fine and then Run would do"
  echo "  nothing at all, with no error anywhere. Trim $(( desk_bytes - DESK_MAX ))"
  echo "  bytes of comments - the long-form rationale belongs in README.md."
  exit 1
fi
if [ "$desk_bytes" -gt $(( DESK_MAX - 512 )) ]; then
  echo "WARNING: desk is $desk_bytes bytes, within 512 of the $DESK_MAX limit."
  echo "  Past it, Run silently does nothing. Move commentary to README.md."
  echo
fi

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
