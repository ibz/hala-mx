#!/usr/bin/env bash
# Put the machine back exactly as it was before this debugging session.
# HEAD's code ran on that machine; it does not run on this one, so the
# difference is here, not in xenakis.rb.
set -u
echo "== 1. PipeWire drop-in -> the original (quantum only, no rate/limit pinning)"
cat > ~/.config/pipewire/pipewire.conf.d/99-hala-mx.conf <<'CONF'
context.properties = {
    default.clock.quantum     = 1024
    default.clock.min-quantum = 1024
    default.clock.max-quantum = 2048
}
CONF

echo "== 2. remove the headroom rule I added"
rm -fv ~/.config/wireplumber/main.lua.d/51-umc404hd-headroom.lua
rmdir ~/.config/wireplumber/main.lua.d ~/.config/wireplumber 2>/dev/null

echo "== 3. clear the runtime clock forces (both were 0 before)"
pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1 && echo "   force-quantum -> 0"
pw-metadata -n settings 0 clock.force-rate 0    >/dev/null 2>&1 && echo "   force-rate -> 0"

echo "== 4. default sink -> built-in analog (what it was)"
pactl set-default-sink alsa_output.pci-0000_00_1f.3.analog-stereo 2>/dev/null && echo "   ok"

if pgrep -f "sonic-pi" >/dev/null 2>&1; then
  echo "== 5. SKIPPED - Sonic Pi is running. Quit it and re-run for its config."
else
  echo "== 5. Sonic Pi config -> originals"
  cp -v ~/.sonic-pi/config/v5-audio-settings.toml.bak ~/.sonic-pi/config/v5-audio-settings.toml
  cp -v ~/.sonic-pi/config/v5-gui-settings.ini.bak   ~/.sonic-pi/config/v5-gui-settings.ini
fi

echo "== 6. restart pipewire stack"
systemctl --user restart wireplumber pipewire pipewire-pulse && sleep 3 && echo "   ok"

echo; echo "== resulting state =="
pw-metadata -n settings 2>/dev/null | grep -E "force-quantum|force-rate|clock.rate"
pw-cli info 0 2>/dev/null | grep -E "quantum-limit|default.clock.quantum ="
echo "default sink: $(pactl get-default-sink 2>/dev/null)"
grep -E "^audio-" ~/.sonic-pi/config/v5-gui-settings.ini 2>/dev/null | tr '\n' ' '; echo
grep -E "^linux_pipewire|^sound_card_name" ~/.sonic-pi/config/v5-audio-settings.toml 2>/dev/null
