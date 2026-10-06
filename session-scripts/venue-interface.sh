#!/usr/bin/env bash
#
# venue-interface.sh - work out, by ear, which interface a venue's rig is on
# and which of its ports carry which output, then write that down so it is
# only ever done once.
#
#   ./venue-interface.sh <venue>            configure (or re-configure)
#   ./venue-interface.sh <venue> -n 12      configure for a different count
#   ./venue-interface.sh <venue> --show     print the saved configuration
#   ./venue-interface.sh <venue> --path     print where it lives
#
# <venue> is a bare name - tnb, nicapetre - used only to name the config file
# and to address the operator. Nothing in here knows what a venue sounds like.
#
# WHY THIS EXISTS: Hala MX's two interfaces are known quantities - start-46.sh
# names the Focusrite by pattern and the UMC by node name, and both have had
# their port maps confirmed by ear. A touring venue's rack has not, so there is
# nothing to hard code - and a venue is the one place where getting it wrong is
# silent and expensive, which is the argument that made the mode a required
# argument in the first place.
#
# So those modes ask once, the first time, and never again. What gets asked is
# exactly the three things that were WRONG at Hala MX before somebody put a
# tone on each jack and listened (README 7d):
#
# 1. THE ALSA PROFILE. A multichannel USB interface usually boots in a consumer
#    "HiFi"/"Analog Stereo" profile and presents a pile of 2-channel sinks, not
#    one multichannel node. Only "pro-audio" exposes discrete playback_AUX0..N
#    ports. WirePlumber remembers the choice per card, but the saved config
#    records it anyway and start-46.sh re-applies it every run - nothing
#    guarantees it survives a power cycle or somebody else's poke.
#
# 2. THE PORT ORDER. PipeWire's "Line Output N+M" labels are an ACP guess and
#    are often wrong, and this script's own sort -V over the port names is also
#    only a guess. On the 18i20 the first 12 AUX ports would have put four
#    channels of the piece into a headphone socket. Hence the sweep, and hence
#    being able to answer it with an explicit, out-of-order list.
#
# 3. THE INTERFACE'S OWN ROUTING MATRIX. The 18i20 needed `amixer` work beyond
#    anything PipeWire could see. This script cannot know the equivalent on an
#    interface it has never met, so it does not pretend to: if the sweep is
#    silent on some channels, that is the layer to go and look at, and the
#    sweep is what tells you to look.
#
# Nothing here is guessed on the operator's behalf. The script proposes, plays
# the tones, and only writes the file once somebody says they heard the right
# thing out of the right speaker.

set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
TONE="$HERE/tone-test.sh"

# The venue comes first and is required: a config file that does not say which
# rack it describes is the beginning of playing one venue's port map in another.
VENUE="${1:-}"
case "$VENUE" in
  ''|-*)         echo "usage: $(basename "$0") <venue> [-n N] [--show] [--path]"
                 echo "       venue is a bare name, e.g. tnb or nicapetre"; exit 1 ;;
  *[!a-z0-9_-]*) echo "venue name must be lowercase letters, digits, - or _"; exit 1 ;;
esac
shift
LABEL=$(printf '%s' "$VENUE" | tr '[:lower:]' '[:upper:]')

# Machine-local, not in the repo: the node name embeds the interface's USB
# serial number, so this describes one physical rack rather than the piece.
# start-46.sh asks for it with `venue-interface.sh <venue> --path` rather than
# rebuilding the expression, so there is one definition of where it lives.
CONF="${HALA_VENUE_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/hala-mx/${VENUE}-card.conf}"

N=8
ACTION=configure
while [ $# -gt 0 ]; do
  case "$1" in
    --path)     ACTION=path; shift ;;
    --show)     ACTION=show; shift ;;
    -n)         N="${2:-}"; shift 2 || { echo "-n needs a number"; exit 1; } ;;
    -h|--help)  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "unknown argument: $1"; exit 1 ;;
  esac
done
case "$N" in ''|*[!0-9]*|0) echo "-n: not a positive number: $N"; exit 1 ;; esac

if [ "$ACTION" = path ]; then echo "$CONF"; exit 0; fi
if [ "$ACTION" = show ]; then
  [ -r "$CONF" ] || { echo "no $LABEL configuration yet ($CONF)"; exit 1; }
  cat "$CONF"; exit 0
fi

# --- preflight --------------------------------------------------------------
miss=
for t in "pactl:pulseaudio-utils" "pw-link:pipewire-bin" "pw-play:pipewire-bin" "python3:python3"; do
  bin=${t%%:*}; pkg=${t##*:}
  command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin   (apt install $pkg)"; miss=1; }
done
[ -n "$miss" ] && { echo; echo "install the package(s) above and try again."; exit 1; }
[ -x "$TONE" ] || { echo "missing: $TONE - cannot run the tone test"; exit 1; }
pactl info >/dev/null 2>&1 || {
  echo "pactl cannot reach a sound server - is PipeWire running for this user?"
  echo "  systemctl --user status pipewire pipewire-pulse wireplumber"
  exit 1; }

# This is a conversation, not a batch job: it plays tones and waits to be told
# what was heard. Failing early beats hanging on a read that can never return.
[ -t 0 ] || { echo "venue-interface.sh needs a terminal - run it by hand at the venue."; exit 1; }

# --- what the graph has -----------------------------------------------------
# `pactl list` is prose, not a format. Parsed here once, into TSV, rather than
# grepped at six call sites with six slightly different regexes.
#
# Two traps, both found against the live graph rather than the man page:
#   - `pactl list cards sinks` does NOT list both. It honours the LAST type
#     given and silently drops the other, so these are two separate calls.
#   - a sink's block has no `Card: #N` line under pipewire-pulse. What ties a
#     sink to its card is the `device.name` property, which holds the card's
#     own `Name:`. That is the join used below.
SEP=$'\037'    # see the note in pactl_tsv's python below
pactl_tsv() {   # $1 = cards|sinks  ->  name SEP active SEP has_pro_audio SEP desc SEP card
  pactl list "$1" 2>/dev/null | python3 -c '
import re, sys
kind = sys.argv[1]
head = "Card" if kind == "cards" else "Sink"
items, cur, section = [], None, None
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if re.match(r"^%s #\d+" % head, line):
        cur = {"name": "", "active": "", "pro": "0", "desc": "", "card": ""}
        items.append(cur); section = None; continue
    if cur is None:
        continue
    s = line.strip()
    if line.startswith("\t") and not line.startswith("\t\t"):
        section = s[:-1] if re.match(r"^(Profiles|Ports|Properties|Formats):$", s) else None
    if section is not None and line.startswith("\t\t"):
        if section == "Profiles" and s.startswith("pro-audio:"):
            cur["pro"] = "1"
        elif section == "Properties" and s.startswith("device.name = "):
            cur["card"] = s.split("=", 1)[1].strip().strip(chr(34))
        elif section == "Properties" and s.startswith("device.description = ") and not cur["desc"]:
            cur["desc"] = s.split("=", 1)[1].strip().strip(chr(34))
        continue
    if s.startswith("Name: "):             cur["name"] = s[6:]
    elif s.startswith("Description: "):    cur["desc"] = s[13:]
    elif s.startswith("Active Profile: "): cur["active"] = s[16:]
for it in items:
    if not it["name"]:
        continue
    # \x1f, not \t: tab counts as IFS whitespace in bash, so `read` COALESCES
    # runs of it and an empty field shifts every later one left. A sink with no
    # Active Profile silently handed its card name to the description variable.
    print("\x1f".join([it["name"], it["active"], it["pro"], it["desc"], it["card"]]))
' "$1"
}

sink_ports() {   # $1 = sink node name -> its playback port suffixes, natural order
  pw-link -i 2>/dev/null | awk -F: -v s="$1" '
    index($0, s ":playback_") == 1 { print substr($0, length(s) + 11) }' | sort -V
}

ask() {          # $1 = prompt, $2 = default -> answer on stdout
  local a
  read -r -p "$1" a || { echo; echo "aborted."; exit 1; }
  printf '%s' "${a:-$2}"
}

# "1-8,13-16" / "1,2,3" / "" -> one index per line. Rejects anything else, and
# anything out of range, rather than silently dropping it.
expand_spec() {
  local spec="$1" max="$2" part a b i
  spec="${spec//[[:space:]]/}"
  [ -n "$spec" ] || return 1
  local IFS=','
  for part in $spec; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
      { [ "$a" -ge 1 ] && [ "$b" -le "$max" ] && [ "$a" -le "$b" ]; } || return 1
      for ((i=a; i<=b; i++)); do echo "$i"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      { [ "$part" -ge 1 ] && [ "$part" -le "$max" ]; } || return 1
      echo "$part"
    else
      return 1
    fi
  done
}

echo "$LABEL interface setup - $N outputs"
echo "config file: $CONF"
if [ -r "$CONF" ]; then
  echo
  echo "there is already a configuration; this run replaces it:"
  sed 's/^/    /' "$CONF"
fi
echo

# --- 1. the card ------------------------------------------------------------
# The card comes before the sink because switching its profile DESTROYS and
# recreates the sinks under a different node name - picking a sink first and
# then changing the profile would leave us holding a name that no longer exists.
mapfile -t CARDS < <(pactl_tsv cards)
[ "${#CARDS[@]}" -gt 0 ] || { echo "no sound cards found."; exit 1; }

echo "sound cards on this machine:"
i=1
for row in "${CARDS[@]}"; do
  IFS="$SEP" read -r name active pro desc _ <<< "$row"
  printf '  %2d) %s\n' "$i" "${desc:-$name}"
  printf '      card:    %s\n' "$name"
  printf '      profile: %s%s\n' "$active" \
    "$( [ "$pro" = 1 ] && [ "$active" != pro-audio ] && echo '   (a pro-audio profile is available)' )"
  i=$((i + 1))
done
echo

sel=$(ask "which card is the $LABEL rig on? [1-${#CARDS[@]}] " "")
case "$sel" in ''|*[!0-9]*) echo "not a number: $sel"; exit 1 ;; esac
{ [ "$sel" -ge 1 ] && [ "$sel" -le "${#CARDS[@]}" ]; } || { echo "out of range: $sel"; exit 1; }
IFS="$SEP" read -r CARD CARD_ACTIVE CARD_PRO CARD_DESC _ <<< "${CARDS[$((sel - 1))]}"
echo
echo "card: ${CARD_DESC:-$CARD}"

# --- 2. the profile ---------------------------------------------------------
# Reason 1 in the header: without pro-audio, a multichannel interface shows up
# as a handful of stereo sinks and channels 3+ have nowhere to go at all.
if [ "$CARD_PRO" = 1 ] && [ "$CARD_ACTIVE" != pro-audio ]; then
  echo
  echo "this card is in the '$CARD_ACTIVE' profile."
  echo "  Consumer profiles split a multichannel interface into stereo sinks,"
  echo "  so outputs 3+ would have no port to land on. 'pro-audio' exposes the"
  echo "  discrete playback_AUX* ports the piece needs."
  yn=$(ask "switch it to pro-audio? [Y/n] " y)
  case "$yn" in
    [Nn]*) echo "  left on $CARD_ACTIVE - continuing, but expect fewer ports than outputs." ;;
    *)
      pactl set-card-profile "$CARD" pro-audio || { echo "  FAILED to set the profile."; exit 1; }
      CARD_ACTIVE=pro-audio
      # The sinks are torn down and rebuilt; give WirePlumber a moment before
      # asking what exists, or the list below comes back empty or half-built.
      sleep 1
      echo "  profile -> pro-audio"
      ;;
  esac
fi
CARD_PROFILE="$CARD_ACTIVE"

# --- 3. the sink ------------------------------------------------------------
mapfile -t SINKS < <(pactl_tsv sinks | awk -F"$SEP" -v c="$CARD" '$5==c')
if [ "${#SINKS[@]}" -eq 0 ]; then
  # The device.name join failed - an unusual driver, or a sink that genuinely
  # has no card. Rather than dead-ending at the venue, fall back to the whole
  # list and let the operator pick; the sweep is what proves the choice anyway.
  mapfile -t SINKS < <(pactl_tsv sinks)
  if [ "${#SINKS[@]}" -eq 0 ]; then
    echo
    echo "no output sinks at all - is the interface connected and un-muted?"
    echo "  pactl list short sinks"
    exit 1
  fi
  echo
  echo "could not tie any sink to that card; showing all of them instead."
fi

if [ "${#SINKS[@]}" -eq 1 ]; then
  IFS="$SEP" read -r SINK _ _ SINK_DESC _ <<< "${SINKS[0]}"
else
  echo
  echo "output sinks to choose from:"
  i=1
  for row in "${SINKS[@]}"; do
    IFS="$SEP" read -r name _ _ desc _ <<< "$row"
    printf '  %2d) %s\n      %s\n' "$i" "${desc:-$name}" "$name"
    i=$((i + 1))
  done
  sel=$(ask "which one? [1-${#SINKS[@]}] " "")
  case "$sel" in ''|*[!0-9]*) echo "not a number: $sel"; exit 1 ;; esac
  { [ "$sel" -ge 1 ] && [ "$sel" -le "${#SINKS[@]}" ]; } || { echo "out of range: $sel"; exit 1; }
  IFS="$SEP" read -r SINK _ _ SINK_DESC _ <<< "${SINKS[$((sel - 1))]}"
fi
echo "sink: ${SINK_DESC:-$SINK}"
echo "      $SINK"

mapfile -t ALL < <(sink_ports "$SINK")
[ "${#ALL[@]}" -gt 0 ] || { echo "no playback ports on that sink - is it connected?"; exit 1; }
if [ "${#ALL[@]}" -lt "$N" ]; then
  echo
  echo "WARNING: that sink has only ${#ALL[@]} playback port(s), $N outputs are wanted."
  echo "  Either the profile is still a stereo one, or this is not the interface"
  echo "  the rig is patched to. Continuing so you can hear what is there."
fi

# Starting guess: the first N in natural order. Reason 2 in the header - this
# is a GUESS, and the sweep below exists to break it.
CHOSEN=()
for ((i=0; i<N && i<${#ALL[@]}; i++)); do CHOSEN+=("${ALL[$i]}"); done

# --- 4. the sweep -----------------------------------------------------------
while :; do
  echo
  echo "all ${#ALL[@]} playback port(s) on this sink:"
  i=1
  for p in "${ALL[@]}"; do printf '  %2d) %s\n' "$i" "$p"; i=$((i + 1)); done
  echo
  echo "proposed channel order (output 1 -> ${#CHOSEN[@]}):"
  i=1
  for p in "${CHOSEN[@]}"; do printf '  output %-3d %s\n' "$i" "$p"; i=$((i + 1)); done
  echo
  echo "Listening to this is the only way to know. A rising 3-note chime plays"
  echo "on one output at a time, in order - follow it round the room."
  echo
  echo "  [t] play the proposed order   (output 1, 2, 3, ... as listed above)"
  echo "  [a] play ALL ${#ALL[@]} ports in list order, to find out what is where"
  echo "  [e] enter the order by hand   (e.g. 1-8  or  1-8,13-16  or  3,1,2,4)"
  echo "  [y] accept - these are outputs 1-${#CHOSEN[@]}"
  echo "  [q] quit without writing anything"
  a=$(ask "> " t)
  case "$a" in
    t|T)
      pre=(); for p in "${CHOSEN[@]}"; do pre+=("$SINK:playback_$p"); done
      echo
      "$TONE" --sink "$SINK" --label-from 1 "${pre[@]}"
      ;;
    a|A)
      pre=(); for p in "${ALL[@]}"; do pre+=("$SINK:playback_$p"); done
      echo
      echo "sweeping every port in the numbered list above - note which list"
      echo "number reached which speaker, then answer [e] with those numbers."
      echo
      "$TONE" --sink "$SINK" --label-from 1 "${pre[@]}"
      ;;
    e|E)
      spec=$(ask "list numbers, in channel order: " "")
      mapfile -t idx < <(expand_spec "$spec" "${#ALL[@]}")
      if [ "${#idx[@]}" -eq 0 ]; then
        echo "could not read that - use list numbers 1-${#ALL[@]}, e.g. 1-8 or 3,1,2,4"
        continue
      fi
      if [ "${#idx[@]}" -ne "$N" ]; then
        echo "that is ${#idx[@]} port(s); $N outputs are wanted."
        yn=$(ask "use it anyway, and run $LABEL on ${#idx[@]} outputs? [y/N] " n)
        case "$yn" in [Yy]*) N="${#idx[@]}" ;; *) continue ;; esac
      fi
      CHOSEN=(); for k in "${idx[@]}"; do CHOSEN+=("${ALL[$((k - 1))]}"); done
      ;;
    y|Y)
      if [ "${#CHOSEN[@]}" -ne "$N" ]; then
        echo "only ${#CHOSEN[@]} of $N outputs are assigned - fix that first, or [e] a shorter list."
        continue
      fi
      break
      ;;
    q|Q) echo "nothing written."; exit 1 ;;
    *)   echo "didn't catch that." ;;
  esac
done

# --- 5. write it down -------------------------------------------------------
PORTS=""
for p in "${CHOSEN[@]}"; do PORTS="${PORTS:+$PORTS,}$SINK:playback_$p"; done

mkdir -p "$(dirname "$CONF")" || { echo "cannot create $(dirname "$CONF")"; exit 1; }
if [ -r "$CONF" ]; then
  cp "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
fi
cat > "$CONF" <<EOF
# $LABEL's interface, confirmed by ear on $(date '+%Y-%m-%d %H:%M:%S').
# Written by session-scripts/venue-interface.sh; read by start-46.sh --$VENUE.
#
# Machine-local on purpose: VENUE_SINK embeds this interface's USB serial, so
# this describes one physical rack and not the piece. If the rack changes,
# re-run:  ./session-scripts/start-46.sh --$VENUE --reconfigure
#
# VENUE_PORTS is in CHANNEL ORDER - entry 1 is output 1 - and is used verbatim,
# not re-derived, because the order was established by listening and nothing
# in the graph records it.
VENUE_NAME='$VENUE'
VENUE_CARD='$CARD'
VENUE_PROFILE='$CARD_PROFILE'
VENUE_SINK='$SINK'
VENUE_OUTPUTS=$N
VENUE_PORTS='$PORTS'
EOF

echo
echo "written: $CONF"
sed 's/^/    /' "$CONF"
echo
echo "$LABEL is configured. From here on:  ./session-scripts/start-46.sh --$VENUE"
