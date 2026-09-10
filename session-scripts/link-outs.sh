#!/usr/bin/env bash
#
# link-outs.sh - patch scsynth's outputs to the interface, undoing Sonic Pi's
# own (wrong) auto-patching.
#
# WHY THIS EXISTS: five seconds after scsynth boots, Sonic Pi patches the
# outputs itself. From app/server/ruby/bin/daemon.rb, run_post_start_commands:
#
#     inputs   = `pw-link -iI`.lines
#     left_id  = inputs.grep(/alsa_output.*playback_FL$/).first.to_i
#     right_id = inputs.grep(/alsa_output.*playback_FR$/).first.to_i
#     system("pw-link #{sco1} #{left_id}")
#     system("pw-link #{sco2} #{right_id}")
#
# FL/FR are the port names of a consumer STEREO profile. The UMC runs in the
# Pro Audio profile, so its ports are playback_AUX0..AUX3 and never match.
# The only node in the graph that does match is the built-in HDA Intel PCH -
# so Sonic Pi patches out_1/out_2 to the LAPTOP SPEAKERS regardless of what
# the PipeWire default sink is set to. It does not consult the default sink
# at all; audio-settings.toml's comment to the contrary is wrong for 4.6.
#
# This happens even when SC_JACK_DEFAULT_OUTPUTS has already put the outputs
# on the interface correctly (see start-46.sh) - daemon.rb ADDS its links, it
# does not replace them, so the piece ends up playing out of both devices at
# once. Hence the teardown below.
#
# Second bug, independent of the first: that code only ever touches out_1 and
# out_2. Channels 3+ are left dangling, so on a 4- or 12-out rig it silently
# drops everything above the first pair.
#
#   ./link-outs.sh                     studio: 4 outputs on the UMC404HD
#   ./link-outs.sh a:p_AUX0,a:p_AUX1   explicit port list, in channel order
#   ./link-outs.sh --wait [ports]      block until scsynth is up, then patch
#
# --wait is what start-46.sh uses: it waits for SuperCollider to appear in the
# graph, then sleeps past daemon.rb's 5 s timer before patching. Patching any
# earlier just gets overwritten.
#
# Idempotent - safe to re-run at any point during a session.

set -uo pipefail

UMC="alsa_output.usb-BEHRINGER_UMC404HD_192k-00.pro-output-0"

WAIT=0
if [ "${1:-}" = "--wait" ]; then WAIT=1; shift; fi
PORTS="${1:-}"

command -v pw-link >/dev/null || { echo "pw-link not found"; exit 1; }

if [ "$WAIT" = 1 ]; then
  # Up to 60 s for scsynth to register. The GUI has to start the daemon, which
  # boots scsynth, so this is a good deal later than the launch itself.
  for _ in $(seq 60); do
    pw-link -o 2>/dev/null | grep -q '^SuperCollider:out_1$' && break
    sleep 1
  done
  # daemon.rb's thread is Kernel.sleep 5 from just after that point; 8 clears
  # it with margin. Undershooting means our links get clobbered by its.
  sleep 8
fi

pw-link -o 2>/dev/null | grep -q '^SuperCollider:out_1$' || {
  echo "SuperCollider not in the graph - is scsynth running?"; exit 1; }

# Default port list: the UMC's four pro-audio outputs, in channel order.
if [ -z "$PORTS" ]; then
  PORTS="$UMC:playback_AUX0,$UMC:playback_AUX1,$UMC:playback_AUX2,$UMC:playback_AUX3"
fi

# Tear down every existing SuperCollider link, whatever it points at. Without
# this daemon.rb's internal-speaker links survive alongside ours.
pw-link -l | awk '
  /^[^ ]/    { src = $0; next }
  /^  \|-> / { sub(/^  \|-> /, ""); if (src ~ /^SuperCollider:out_/) print src, $0 }
' | while read -r out in; do
  echo "  unlink $out -> $in"
  pw-link -d "$out" "$in"
done

# SuperCollider out_N (1-based) -> Nth entry of the port list.
n=1
IFS=,
for dst in $PORTS; do
  unset IFS
  out="SuperCollider:out_${n}"
  if ! pw-link -o | grep -qx "$out"; then
    echo "  skip   $dst - no $out (scsynth has fewer outputs than ports given)"
  elif ! pw-link -i | grep -qx "$dst"; then
    echo "  skip   $out - port not in graph: $dst"
  else
    echo "  link   $out -> $dst"
    pw-link "$out" "$dst" || echo "    FAILED"
  fi
  n=$((n + 1))
  IFS=,
done
unset IFS

echo
echo "current SuperCollider routing:"
pw-link -l | grep -A1 '^SuperCollider:out_' | sed 's/^/  /'
