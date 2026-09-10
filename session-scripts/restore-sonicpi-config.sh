#!/usr/bin/env bash
set -u
pgrep -f "sonic-pi" >/dev/null && { echo "Quit Sonic Pi first."; exit 1; }
cp -v ~/.sonic-pi/config/v5-audio-settings.toml.bak ~/.sonic-pi/config/v5-audio-settings.toml
cp -v ~/.sonic-pi/config/v5-gui-settings.ini.bak   ~/.sonic-pi/config/v5-gui-settings.ini
pactl set-default-sink alsa_output.pci-0000_00_1f.3.analog-stereo 2>/dev/null && echo "default sink -> built-in"
pw-metadata -n settings 0 clock.force-quantum 1024 >/dev/null && echo "force-quantum = 1024"
echo "--- now launch Sonic Pi normally (NOT start-session.sh) ---"
grep -E "^audio-" ~/.sonic-pi/config/v5-gui-settings.ini
