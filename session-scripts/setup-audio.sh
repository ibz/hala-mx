#!/usr/bin/env bash
#
# setup-audio.sh - SONIC PI 5.0 ONLY. Kept for reference; do not run it on 4.6.
#
# ====================================================================
#  THIS SCRIPT IS OBSOLETE FOR THE CURRENT SETUP.
#
#  It defends against two failure modes that belong to Sonic Pi 5.0's
#  cold-swap/watchdog machinery - the exact machinery the piece moved to
#  4.6 to escape (README 7a). On 4.6 it is at best useless and at worst
#  harmful:
#
#    * It patches v5-audio-settings.toml. 4.6 reads audio-settings.toml,
#      with no v5- prefix, and start-46.sh manages that file now,
#      including setting num_outputs to match the venue mode.
#    * It writes a STRICTER PipeWire pinning than the one in use:
#      min = max = quantum-limit = 1024 plus a pinned rate, against the
#      current 1024/1024/2048 with neither. Running it silently reverts a
#      relaxation that was made deliberately.
#
#  On 4.6 use: ./start-46.sh --production | --simulation
#  It refuses to run unless v5-audio-settings.toml exists; --anyway
#  overrides, --check is read-only and always allowed.
# ====================================================================
#
# What it was for. Two things ended the piece mid-installation on 5.0, and
# neither looked like a bug in the piece: it just went silent, with nothing
# in the Sonic Pi GUI.
#
#   1. A PipeWire RATE renegotiation. Sonic Pi answers a device change with a
#      cold-swap reinit that nukes the running job's scsynth state. The
#      live_loop then raises inside with_fx ("The audio engine is still
#      reinitialising after a device change") and a raised live_loop is dead
#      for good - it does not retry.
#   2. A quantum of 256. The piece runs stably at 1024 (21 ms) and falls over
#      at 256 (5.3 ms): LATE callbacks pile up until the device stops, which
#      then triggers exactly the same cold swap as (1).
#
# Run this before a session. The permanent part is idempotent; the runtime
# forces have to be re-applied after every PipeWire restart, which is the
# main reason this is a script and not a paragraph in the README.
#
#   ./setup-audio.sh            write config + apply runtime forces
#   ./setup-audio.sh --check    verify only, change nothing (always allowed)
#   ./setup-audio.sh --restart  also restart PipeWire (INTERRUPTS ALL AUDIO)
#   ./setup-audio.sh --anyway   run despite the 5.0 guard above
#
# After a --restart, restart Sonic Pi too: it latches its buffer size when it
# opens the device, so changing the quantum under a running instance does
# nothing at all.

set -uo pipefail

QUANTUM=1024
RATE=48000
CARD="UMC404HD 192k Pro"
CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF="$CONF_DIR/99-hala-mx.conf"

DO_WRITE=1 DO_FORCE=1 DO_RESTART=0 ANYWAY=0
for a in "$@"; do
  case "$a" in
    --check)   DO_WRITE=0; DO_FORCE=0 ;;
    --restart) DO_RESTART=1 ;;
    --anyway)  ANYWAY=1 ;;
    *) echo "usage: $0 [--check|--restart|--anyway]" >&2; exit 2 ;;
  esac
done

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

fail=0

command -v pw-metadata >/dev/null || {
  red "pw-metadata not found - is PipeWire installed? (apt install pipewire-bin)"; exit 1; }

# ------------------------------------------------------------------ guard ---
# The 5.0 check. --check writes nothing, so it is always allowed; anything
# that would touch the config or the graph has to pass this first.
V5_TOML="$HOME/.sonic-pi/config/v5-audio-settings.toml"
TOML_46="$HOME/.sonic-pi/config/audio-settings.toml"
# Test the 4.6 file, NOT the absence of the 5.0 one. A machine that ran 5.0
# before keeps v5-audio-settings.toml (and its .bak, .pre2048, .pre-alsa
# siblings) forever, so "no v5 file" is false on exactly the machines this
# guard exists to protect - it let the script through here and it overwrote a
# live, deliberately relaxed PipeWire pinning. The presence of
# audio-settings.toml means 4.6 has run, and that is the thing to refuse on.
if [ "$ANYWAY" = 0 ] && [ "$((DO_WRITE + DO_FORCE + DO_RESTART))" -gt 0 ] \
   && [ -f "$TOML_46" ]; then
  red "REFUSING TO RUN - this is the Sonic Pi 5.0 setup script."
  echo
  echo "  $TOML_46 exists, so 4.6 is the version set up on this machine."
  [ -f "$V5_TOML" ] && echo "  ($V5_TOML is also present - a leftover from the 5.0 era.)"
  echo
  echo "  On 4.6 this script would patch a file nothing reads, and would"
  echo "  overwrite the PipeWire pinning with a stricter 5.0-era version."
  echo "  Use instead:  ./start-46.sh --production | --simulation"
  echo
  echo "  ./setup-audio.sh --check    inspect without changing anything"
  echo "  ./setup-audio.sh --anyway   override this guard"
  exit 1
fi

# ---------------------------------------------------------------- config ---
if [ "$DO_WRITE" = 1 ]; then
  hdr "Writing $CONF"
  mkdir -p "$CONF_DIR"
  cat > "$CONF" <<EOF
# Xenakis / Hala MX - PipeWire pinning. Written by setup-audio.sh.
#
# Two separate hazards, one file. Keep it that way: PipeWire merges every
# *.conf in this directory alphabetically, so a second file setting the same
# clock.* keys silently wins or loses depending on its NAME.
context.properties = {
    # Rate. A renegotiation restarts the device, and Sonic Pi answers a
    # device change with a cold-swap reinit that nukes the running job -
    # the piece stops dead and does not come back.
    default.clock.rate          = $RATE
    default.clock.allowed-rates = [ $RATE ]

    # Quantum. The piece runs stably at 1024 (21 ms) and falls over at
    # 256 (5.3 ms). min == max so nothing can drag the graph down mid-show;
    # a floor alone was NOT enough - see README 7a.
    default.clock.quantum       = $QUANTUM
    default.clock.min-quantum   = $QUANTUM
    default.clock.max-quantum   = $QUANTUM

    # The ceiling on what a quantum may be AT ALL. Without this the device
    # negotiated bs=1024 and then delivered 8192-sample callbacks - 170 ms,
    # measured as 612 callbacks over 105.8 s. Sonic Pi schedules grains in
    # milliseconds, so a 170 ms callback makes half the piece late by
    # construction. force-quantum sets the target; this sets what is
    # possible. Needs a PipeWire RESTART - it is not runtime-settable.
    default.clock.quantum-limit = $QUANTUM
}
EOF
  grn "  ok"
fi

# A second drop-in touching clock.* is the failure that started all this:
# 99-sonic-pi.conf pinned 256 and sorted AFTER 99-hala-mx.conf, so on the
# next PipeWire restart it would have won.
hdr "Checking for conflicting drop-ins"
conflict=0
for f in "$CONF_DIR"/*.conf; do
  [ -e "$f" ] || continue
  [ "$f" = "$CONF" ] && continue
  if grep -q "clock\." "$f" 2>/dev/null; then
    red "  CONFLICT: $(basename "$f") also sets clock.* keys"
    red "            PipeWire merges these alphabetically - one of them wins silently."
    conflict=1; fail=1
  fi
done
[ "$conflict" = 0 ] && grn "  none - $(basename "$CONF") is the only file setting clock.*"

# --------------------------------------------------------------- restart ---
if [ "$DO_RESTART" = 1 ]; then
  hdr "Restarting PipeWire (this interrupts all audio)"
  # wireplumber too. PipeWire is only the daemon - WirePlumber is the session
  # manager that creates the device nodes and picks the defaults. Restarting
  # the daemon without it leaves a server that answers `pactl info` perfectly
  # and has ZERO sinks, which reads as "no default sink" and sends you looking
  # in the wrong place entirely.
  systemctl --user restart pipewire pipewire-pulse wireplumber \
    && grn "  ok" || { red "  failed"; fail=1; }
  sleep 2
fi

# ------------------------------------------------------- runtime forcing ---
# The config above sets DEFAULTS. On this machine defaults were observed not
# to hold: with min-quantum already at 1024, Sonic Pi still opened the device
# at bs=256 and died 55 minutes later. force-quantum/force-rate are the ones
# that actually clamp the graph - and they are lost on every PipeWire restart.
if [ "$DO_FORCE" = 1 ]; then
  hdr "Forcing quantum=$QUANTUM rate=$RATE at runtime"
  pw-metadata -n settings 0 clock.force-quantum "$QUANTUM" >/dev/null \
    && grn "  clock.force-quantum = $QUANTUM" || { red "  failed"; fail=1; }
  pw-metadata -n settings 0 clock.force-rate "$RATE" >/dev/null \
    && grn "  clock.force-rate    = $RATE" || { red "  failed"; fail=1; }
fi

# ------------------------------------------------ Sonic Pi's OWN settings ---
# The one that actually decides the buffer. Everything above configures
# PipeWire; none of it stops Sonic Pi from ASKING for 256. On a cold device
# switch it logs
#     [device-setup] calling setAudioDeviceSetup: ... sr=48000 buf=256
# and 256 is where it lands, whatever the graph is pinned to. This file is
# read at BOOT, so it needs a full Sonic Pi restart, not a Run.
hdr "Sonic Pi audio settings"
TOML="$HOME/.sonic-pi/config/v5-audio-settings.toml"
if [ ! -f "$TOML" ]; then
  ylw "  $TOML not found - start Sonic Pi once to create it"
else
  for kv in "linux_pipewire_buffsize=$QUANTUM" "linux_pipewire_samplerate=$RATE"; do
    k=${kv%%=*}; v=${kv#*=}
    if grep -qE "^${k}[[:space:]]*=[[:space:]]*${v}\b" "$TOML"; then
      grn "  $k = $v"
    elif [ "$DO_WRITE" = 1 ]; then
      cp -n "$TOML" "$TOML.bak" 2>/dev/null || true
      if grep -qE "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=" "$TOML"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$TOML"
      else
        printf '\n%s = %s\n' "$k" "$v" >> "$TOML"
      fi
      grn "  $k = $v   (set; needs a Sonic Pi restart)"
    else
      red "  $k is not $v   <- Sonic Pi will reopen the device at its own default"
      fail=1
    fi
  done
fi

# ------------------------------------------- Sonic Pi's GUI device pin ------
# The GUI keeps its own device selector, SEPARATE from the TOML above, and
# when they disagree Sonic Pi "retargets" on every device-list refresh:
#     [reopen] retargeting pinned device 'UMC404HD 192k Pro' (current is 'System Default')
#     [reopen] forceCold switch ...
#     [device-setup] calling setAudioDeviceSetup: ... buf=256
# A forceCold switch nukes the running job, and it reopens at 256 whatever
# the rest of this script has pinned. An empty audio-output-device means
# "System Default", which never matches the TOML's sound_card_name.
# Sonic Pi REWRITES this file when it exits, so it can only be edited while
# Sonic Pi is closed.
hdr "Sonic Pi GUI device pin"
INI="$HOME/.sonic-pi/config/v5-gui-settings.ini"
if [ ! -f "$INI" ]; then
  ylw "  $INI not found - start Sonic Pi once to create it"
elif pgrep -f "sonic-pi" >/dev/null 2>&1; then
  ylw "  Sonic Pi is running - cannot edit (it rewrites this file on exit)."
  ylw "  Quit Sonic Pi and re-run this script if the values below are wrong:"
  grep -E "^audio-(output-device|buffer-size)" "$INI" | sed 's/^/     /'
else
  dev=$(grep "^audio-output-device=" "$INI" | cut -d= -f2-)
  buf=$(grep "^audio-buffer-size=" "$INI" | cut -d= -f2-)
  if [ "$dev" = "$CARD" ] && [ "$buf" = "$QUANTUM" ]; then
    grn "  audio-output-device=$dev  audio-buffer-size=$buf"
  elif [ "$DO_WRITE" = 1 ]; then
    cp -n "$INI" "$INI.bak" 2>/dev/null || true
    sed -i "s|^audio-output-device=.*|audio-output-device=$CARD|; \
            s|^audio-buffer-size=.*|audio-buffer-size=$QUANTUM|" "$INI"
    grn "  audio-output-device=$CARD  audio-buffer-size=$QUANTUM   (set)"
  else
    red "  audio-output-device='$dev' audio-buffer-size='$buf'  (want '$CARD' / $QUANTUM)"
    fail=1
  fi
fi

# --------------------------------------------------- default sink ----------
# Sonic Pi pins a device by name, but when the device list churns it compares
# against the SYSTEM DEFAULT, and if they differ it force-cold-switches back:
#     [reopen] retargeting pinned device 'UMC404HD 192k Pro' (current is 'System Default')
#     [reopen] forceCold switch ...
# That cold switch nukes the running job - the piece stops dead. Making the
# interface the system default removes the mismatch, so there is nothing to
# retarget to. On a dedicated installation machine this is what you want
# anyway; the side effect is that all system audio goes to the rig.
hdr "Default sink"
sink=$(pactl get-default-sink 2>/dev/null)
want=$(pactl list short sinks 2>/dev/null | awk '/UMC404HD/ && /pro-output/ {print $2; exit}')
want=${want:-$(pactl list short sinks 2>/dev/null | awk '/UMC404HD/ {print $2; exit}')}
if [ -z "$want" ]; then
  red "  no UMC404HD sink found - is the interface plugged in?"; fail=1
elif [ "$sink" = "$want" ]; then
  grn "  $sink"
elif [ "$DO_WRITE" = 1 ]; then
  pactl set-default-sink "$want" && grn "  -> $want" || { red "  failed"; fail=1; }
else
  red "  $sink   (want $want)"
  ylw "     a device-list change will cold-switch Sonic Pi and kill the job"
  fail=1
fi

# --------------------------------------------------------------- verify ----
hdr "Verifying"
settings=$(pw-metadata -n settings 2>/dev/null)
get() { printf '%s\n' "$settings" | sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" | tail -1; }

check() { # name  actual  wanted
  if [ "$2" = "$3" ]; then grn "  $1 = $2"; else red "  $1 = ${2:-<unset>}  (want $3)"; fail=1; fi
}
check "clock.rate         " "$(get clock.rate)"          "$RATE"
check "clock.force-rate   " "$(get clock.force-rate)"    "$RATE"
check "clock.force-quantum" "$(get clock.force-quantum)" "$QUANTUM"

# quantum-limit is a context property, not runtime metadata, so it only
# changes on a PipeWire restart - and it is the ceiling that allowed the
# 8192-sample callbacks that killed two sessions.
qlim=$(pw-cli info 0 2>/dev/null | sed -n 's/.*default\.clock\.quantum-limit = "\([0-9]*\)".*/\1/p' | tail -1)
if [ "${qlim:-0}" -le "$QUANTUM" ] 2>/dev/null; then
  grn "  clock.quantum-limit = ${qlim}"
else
  red "  clock.quantum-limit = ${qlim:-<unset>}  (want <= $QUANTUM)"
  ylw "     the config sets it, but it needs a PipeWire restart to take:"
  ylw "     $0 --restart"
  fail=1
fi

# Realtime priority (README 7b). The hard limit is fixed at login, so a fresh
# terminal proves nothing about the session Sonic Pi is running in.
hard_rt=$(ulimit -Hr 2>/dev/null || echo 0)
if [ "${hard_rt:-0}" -ge 95 ] 2>/dev/null; then
  grn "  ulimit -Hr = $hard_rt"
else
  red "  ulimit -Hr = ${hard_rt:-0}  (want 95)"
  ylw "     sudo usermod -aG pipewire \$USER, then LOG OUT and back in."
  ylw "     A new terminal is not enough - pam_limits applies rtprio at login."
  fail=1
fi

if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx pipewire; then
  grn "  in group 'pipewire'"
else
  red "  not in group 'pipewire'"; fail=1
fi

hdr "Result"
if [ "$fail" = 0 ]; then
  grn "Audio system pinned. Now (re)start Sonic Pi - it latches its buffer"
  grn "size when it opens the device, so a running instance keeps the old one."
  echo
  echo "Confirm with, after Sonic Pi has started:"
  echo "  grep -E 'aboutToStart|realtime' ~/.sonic-pi/log/supersonic.log | tail -2"
  echo "  want bs=$QUANTUM and err=0; bad state is bs=256 / policy=0 prio=0 err=1"
else
  red "Something above is not right - fix it before starting a session."
fi
exit "$fail"
