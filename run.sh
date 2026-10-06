#!/usr/bin/env bash
#
# run.sh - start the installation in the hall.
#
# The one command for the venue: 12 outputs on the Focusrite 18i20, bleep off,
# the checked-in desk installed into Buffer 0. Everything it does lives in
# session-scripts/start-46.sh - this is only the short name for the production
# mode, so nobody has to remember the flag or the directory at load-in.
#
# Anything passed here goes straight through, so the one case that needs it
# still works:
#
#   ./run.sh 8      a partially patched rig - state the real output count
#   ./run.sh --keep launch with whatever Buffer 0 already had
#
# This is Hala MX's name only. The other venues and the studio get said out
# loud, because there is nothing about this command that could tell them
# apart:
#
#   session-scripts/start-46.sh --tnb              TNB, 8 outputs
#   session-scripts/start-46.sh --simulation       the studio rig
#   session-scripts/start-46.sh --tnb-simulation   the studio rig, rehearsing TNB
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/session-scripts/start-46.sh" --production "$@"
