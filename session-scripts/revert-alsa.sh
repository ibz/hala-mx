#!/usr/bin/env bash
# Undo try-alsa.sh - back to the PipeWire Pro Audio node (the only path that
# has reliably given 4 discrete channels).
set -eu
INI="$HOME/.sonic-pi/config/v5-gui-settings.ini"
TOML="$HOME/.sonic-pi/config/v5-audio-settings.toml"
pgrep -f sonic-pi >/dev/null && { echo "Quit Sonic Pi first."; exit 1; }
[ -f "$INI.pre-alsa" ] && cp "$INI.pre-alsa" "$INI"
[ -f "$TOML.pre-alsa" ] && cp "$TOML.pre-alsa" "$TOML"
sed -i 's/^audio-driver=.*/audio-driver=/' "$INI"
sed -i 's/^audio-output-device=.*/audio-output-device=UMC404HD 192k Pro/' "$INI"
sed -i 's|^sound_card_name = .*|sound_card_name = "UMC404HD 192k Pro"|' "$TOML"
echo "reverted:"; grep -E "^audio-" "$INI"; grep -E "^sound_card_name" "$TOML"
