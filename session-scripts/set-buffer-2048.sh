#!/usr/bin/env bash
set -u
pgrep -f "sonic-pi" >/dev/null && { echo "Quit Sonic Pi first."; exit 1; }
cp -n ~/.sonic-pi/config/v5-gui-settings.ini  ~/.sonic-pi/config/v5-gui-settings.ini.pre2048  2>/dev/null
cp -n ~/.sonic-pi/config/v5-audio-settings.toml ~/.sonic-pi/config/v5-audio-settings.toml.pre2048 2>/dev/null
sed -i 's/^audio-buffer-size=.*/audio-buffer-size=2048/' ~/.sonic-pi/config/v5-gui-settings.ini
sed -i -E 's|^[[:space:]]*#?[[:space:]]*linux_pipewire_buffsize[[:space:]]*=.*|linux_pipewire_buffsize = 2048|' ~/.sonic-pi/config/v5-audio-settings.toml
pw-metadata -n settings 0 clock.force-quantum 2048 >/dev/null
echo "buffer -> 2048 (GUI ini + toml + force-quantum). Launch Sonic Pi and check:"
echo "  grep aboutToStart ~/.sonic-pi/log/supersonic.log | tail -1   # want bs=2048"
