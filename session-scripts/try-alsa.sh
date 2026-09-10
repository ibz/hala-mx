#!/usr/bin/env bash
# One-shot: point Sonic Pi at the UMC's RAW ALSA device (4 ch, 512-sample
# callbacks) instead of the PipeWire node (4 ch, 8192-sample callbacks).
# The GUI ini overrides v5-audio-settings.toml, so both are set together.
set -eu
ALSA_NAME="UMC404HD 192k, USB Audio; Direct hardware device without any conversions"
INI="$HOME/.sonic-pi/config/v5-gui-settings.ini"
TOML="$HOME/.sonic-pi/config/v5-audio-settings.toml"
pgrep -f sonic-pi >/dev/null && { echo "Quit Sonic Pi first."; exit 1; }
cp -n "$INI" "$INI.pre-alsa" 2>/dev/null || true
cp -n "$TOML" "$TOML.pre-alsa" 2>/dev/null || true
python3 - "$INI" "$TOML" "$ALSA_NAME" <<'PY'
import sys,re
ini,toml,name=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(ini).read()
for k,v in (("audio-driver","ALSA"),("audio-output-device",name),
            ("audio-buffer-size","1024"),("audio-sample-rate","48000")):
    s=re.sub(rf"^{k}=.*$",f"{k}={v}",s,flags=re.M)
open(ini,"w").write(s)
t=open(toml).read()
t=re.sub(r'^sound_card_name = .*$',f'sound_card_name = "{name}"',t,flags=re.M)
open(toml,"w").write(t)
PY
echo "set:"; grep -E "^audio-" "$INI"; grep -E "^sound_card_name" "$TOML"
