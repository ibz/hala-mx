#!/usr/bin/env bash
#
# check-session.sh - is the piece actually healthy RIGHT NOW?
#
# setup-audio.sh checks SETTINGS. This checks DELIVERY, which is a different
# question and the one that matters: during the 14:04 failure every setting
# was green (forced quantum 1024, forced rate 48000, rtprio 95) while the
# device was handing Sonic Pi 8192-sample callbacks and the piece was dying.
# Settings being right is not evidence that audio is arriving on time.
#
#   ./check-session.sh          one report
#   ./check-session.sh -w       re-report every 60 s until Ctrl-C

set -uo pipefail
SS="$HOME/.sonic-pi/log/supersonic.log"
SP="$HOME/.sonic-pi/log/spider.log"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

report() {
  printf '\n\033[1m=== %s ===\033[0m\n' "$(date +%H:%M:%S)"
  [ -r "$SS" ] || { red "no supersonic.log - is Sonic Pi running?"; return 1; }

  # Scope everything to the CURRENT device session. Counting the whole log
  # reports stops and LATE spikes from runs that already ended, which reads
  # as "still broken" when the thing you just changed is in fact working.
  open_ts=$(grep "aboutToStart" "$SS" 2>/dev/null | tail -1 | grep -o "^\[[0-9:.]*")
  if [ -n "$open_ts" ]; then
    cur=$(awk -v t="$open_ts" '$0>=t' "$SS")
    printf '    (since the device opened at %s)\n' "${open_ts#[}"
  else
    cur=$(cat "$SS")
  fi

  # --- did the device die? this is the failure that kills the piece ---
  stops=$(printf '%s\n' "$cur" | grep -c "audioDeviceStopped"); stops=${stops:-0}
  if [ "$stops" -eq 0 ]; then
    grn "device stops           0"
  else
    red "device stops           $stops   <- each one nukes the running job"
    printf '%s\n' "$cur" | grep "audioDeviceStopped\|state: running ->" | tail -2 | sed 's/^/    /'
  fi

  # --- lateness. small and rare is fine; hundreds of ms is the warning ---
  worst=$(printf '%s\n' "$cur" | grep -o "LATE: [0-9.]*ms" | awk '{print $2+0}' | sort -g | tail -1)
  n=$(printf '%s\n' "$cur" | grep -c "LATE"); n=${n:-0}
  worst=${worst:-0}
  if awk "BEGIN{exit !($worst < 50)}"; then
    grn "LATE   worst ${worst}ms  (n=$n)"
  elif awk "BEGIN{exit !($worst < 400)}"; then
    ylw "LATE   worst ${worst}ms  (n=$n)   <- margin is thin"
  else
    red "LATE   worst ${worst}ms  (n=$n)   <- heading for a device stop"
  fi

  # --- callback granularity, inferred from the drift counter ---
  # DRIFT reports "<hits> hits since last report" once a minute, one hit per
  # callback, so hits/60 is the callback rate and 48000/that is its size.
  hits=$(printf '%s\n' "$cur" | grep "DRIFT" | tail -1 |
         sed -n "s/.*, \\([0-9]*\\) hits since.*/\\1/p")
  if [ -n "${hits:-}" ] && [ "$hits" -gt 0 ] 2>/dev/null; then
    size=$(awk "BEGIN{printf \"%d\", 48000/($hits/60)}")
    ms=$(awk "BEGIN{printf \"%.1f\", ($size/48000)*1000}")
    if [ "$size" -le 2048 ]; then
      grn "callback ~${size} samples (${ms}ms)"
    else
      ylw "callback ~${size} samples (${ms}ms)  <- coarse; Sonic Pi schedules in ms"
    fi
  fi

  # --- is the Ruby side still doing anything, and how hard is it working? ---
  heap=$(grep "HEAP" "$SP" 2>/dev/null | tail -1)
  if [ -n "$heap" ]; then
    gc=$(printf '%s' "$heap" | sed -n 's/.*majorGC\/min=\([0-9.]*\).*/\1/p')
    alloc=$(printf '%s' "$heap" | sed -n 's/.*alloc\/min=\([0-9]*\).*/\1/p')
    if [ "${alloc:-0}" -lt 10000 ] 2>/dev/null; then
      ylw "ruby   alloc/min=${alloc}  <- idle: Stopped, or the loop died"
      ylw "       a live_loop death leaves [ruby-error] in spider.log; Stop leaves nothing"
    elif awk "BEGIN{exit !(${gc:-0} < 20)}"; then
      grn "ruby   alloc/min=${alloc} majorGC/min=${gc}"
    else
      ylw "ruby   alloc/min=${alloc} majorGC/min=${gc}  <- GC pauses show up as LATE"
    fi
  fi
}

if [ "${1:-}" = "-w" ]; then
  while true; do report; sleep 60; done
else
  report
fi
