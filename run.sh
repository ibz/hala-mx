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
# For the studio rig use session-scripts/start-46.sh --simulation instead.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/session-scripts/start-46.sh" --production "$@"
