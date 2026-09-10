#!/usr/bin/env bash
#
# build-sonicpi-46.sh - build Sonic Pi 4.6.0 from source on Ubuntu 24.04.
#
# WHY: 5.0.0 (Aug 2026) introduced the SuperSonic engine, native PipeWire
# output, and a rate-skew watchdog. That watchdog fires when the device dips
# ~5% below real-time and "recovers" with a cold swap that DESTROYS the
# running job. Measured here: a 10h40m run ended on a single 0.95x dip.
# 4.6.0 has none of that machinery - scsynth on JACK, and a brief dip is a
# click rather than the end of the installation. It also keeps num_outputs,
# so the 12-channel hall rig still works (app/config/user-examples/
# audio-settings.toml ships "# num_outputs = 16").
#
# Deviations from the official BUILD-LINUX.md, deliberate:
#   * NOT installing pipewire-jack / libspa-0.2-jack. libjack-jackd2-dev is
#     already present, and pipewire-jack would route JACK back through
#     PipeWire - the exact path we are leaving.
#   * Forcing gcc-12. Ubuntu 24.04 defaults to gcc-13, and the docs say
#     vcpkg's dependencies do not build with it.
#
#   ./build-sonicpi-46.sh deps    install missing apt packages (needs sudo)
#   ./build-sonicpi-46.sh clone   fetch v4.6.0 source
#   ./build-sonicpi-46.sh build   compile (long - 30-60 min)
#   ./build-sonicpi-46.sh all     all three

set -uo pipefail
SRC="$HOME/Development/sonic-pi"
LOG="$HOME/Development/sonic-pi-build.log"

PKGS="build-essential git libssl-dev ruby-dev elixir erlang-dev erlang-xmerl
      qt6-tools-dev qt6-tools-dev-tools libqt6svg6-dev libqt6opengl6-dev
      supercollider-server sc3-plugins-server alsa-utils libasound2-dev
      cmake ninja-build qt6-wayland libwayland-dev libxkbcommon-dev
      libegl1-mesa-dev libx11-dev libxft-dev libxext-dev qpwgraph compton m4
      libaubio-dev libpng-dev libboost-all-dev librtmidi-dev
      libjack-jackd2-dev gcc-12 g++-12"

hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

do_deps() {
  hdr "Installing dependencies"
  missing=""
  for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
  if [ -z "$missing" ]; then echo "  nothing missing"; return 0; fi
  echo "  installing:$missing"
  sudo apt-get update && sudo apt-get install -y $missing
}

do_clone() {
  hdr "Fetching v4.6.0"
  if [ -d "$SRC/.git" ]; then
    echo "  $SRC exists; checking out v4.6.0"
    git -C "$SRC" fetch --tags --depth 1 origin tag v4.6.0 && git -C "$SRC" checkout v4.6.0
  else
    mkdir -p "$(dirname "$SRC")"
    git clone --branch v4.6.0 --depth 1 \
      https://github.com/sonic-pi-net/sonic-pi.git "$SRC"
  fi
  git -C "$SRC" log -1 --format='  at %h %d' 2>/dev/null
}

do_build() {
  hdr "Building (30-60 min; full log: $LOG)"
  [ -d "$SRC/app" ] || { echo "  no source - run '$0 clone' first"; return 1; }
  command -v gcc-12 >/dev/null || { echo "  gcc-12 missing - run '$0 deps' first"; return 1; }
  cd "$SRC/app" || return 1
  # vcpkg's dependencies do not compile under gcc-13, which is the 24.04
  # default; cmake honours CC/CXX from the environment.
  export CC=gcc-12 CXX=g++-12
  echo "  CC=$CC CXX=$CXX"
  ./linux-build-all.sh 2>&1 | tee "$LOG"
  rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ] && [ -x "$SRC/app/build/sonic-pi" ]; then
    printf '\n\033[32m  BUILD OK -> %s/app/build/sonic-pi\033[0m\n' "$SRC"
  else
    printf '\n\033[31m  BUILD FAILED (rc=%s). Last errors:\033[0m\n' "$rc"
    grep -iE "error|fatal|No such file" "$LOG" | tail -20
  fi
  return "$rc"
}

case "${1:-all}" in
  deps)  do_deps ;;
  clone) do_clone ;;
  build) do_build ;;
  all)   do_deps && do_clone && do_build ;;
  *) echo "usage: $0 [deps|clone|build|all]" >&2; exit 2 ;;
esac
