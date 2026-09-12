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
#   * DO installing the PipeWire RUNTIME tools, which are not build deps at all
#     but which start-46.sh and link-outs.sh cannot work without: pactl
#     (pulseaudio-utils) and pw-link/pw-top (pipewire-bin). Leaving them out
#     produced a build that compiled perfectly and then failed at launch with
#     "no default sink - is PipeWire running?" on a machine where PipeWire was
#     running fine - pactl simply was not installed, and its absence looked
#     identical to an empty answer.
#   * NOT forcing gcc-12 any more. Two reasons, and the second is fatal.
#     The stated one was "vcpkg's dependencies do not build with gcc-13" -
#     true, but not of the LINUX path: app/CMakeLists.txt gates the vcpkg
#     toolchain to `if (WIN32 OR APPLE)` and linux-build-all.sh never touches
#     it (prebuild -> config -> build-gui -> tau-release, all system libs).
#     The second: the compiler has to MATCH THE SYSTEM libstdc++. GCC 13
#     re-versioned __cxa_call_terminate and dropped the old symbol - a current
#     libstdc++ exports it ONLY at CXXABI_1.3.15, with no CXXABI_1.3.5 compat
#     entry - while code from an older gcc still references the 1.3.5 form.
#     Mixing them links fine until Qt, then fails with
#         undefined reference to `__cxa_call_terminate@CXXABI_1.3.5'
#     Set CC/CXX yourself to override; otherwise the distro default is used,
#     which is the one the distro's Qt and libstdc++ were built against.
#   * PATCHING app/api/src/audio/audio_processor.cpp (patch_shm_crash, below).
#     The GUI's scope/spectrum view unconditionally re-enables itself every
#     time scsynth boots and then crashes the whole app, because it expects a
#     shared-memory interface that only Sonic Pi's own bundled SuperCollider
#     fork creates - never the system scsynth this build uses. See
#     patch_shm_crash for the full chain.
#
#   ./build-sonicpi-46.sh deps    install missing apt packages (needs sudo)
#   ./build-sonicpi-46.sh clone   fetch v4.6.0 source
#   ./build-sonicpi-46.sh build   compile (long - 30-60 min)
#   ./build-sonicpi-46.sh clean   delete app/build (forces a full reconfigure)
#
# `build` also repairs two things that bite on a fresh install: a CMake cache
# holding a stale Boost NOTFOUND, and the `system` Boost component that newer
# releases no longer ship a config for. Both are explained at their functions.
#   ./build-sonicpi-46.sh all     deps + clone + build
#
# SOURCE LOCATION: must agree with start-46.sh, which launches the binary this
# produces. Both default to ~/src/sonic-pi and both honour $SONIC_PI_SRC.
# They used to disagree - this script cloned to ~/Development/sonic-pi while
# the launcher looked in ~/src/sonic-pi - which on a fresh machine builds
# perfectly and then reports "not built".

set -uo pipefail
SRC="${SONIC_PI_SRC:-$HOME/src/sonic-pi}"
LOG="$SRC-build.log"
# The GUI binary lands in build/gui/, NOT build/. Checking the wrong path made
# this script print BUILD FAILED after a perfectly good build, then dump twenty
# lines of compiler noise from the log grep below.
BIN="$SRC/app/build/gui/sonic-pi"

PKGS="build-essential git libssl-dev ruby-dev elixir erlang-dev erlang-xmerl
      qt6-tools-dev qt6-tools-dev-tools libqt6svg6-dev libqt6opengl6-dev
      supercollider-server sc3-plugins-server alsa-utils libasound2-dev
      cmake ninja-build qt6-wayland libwayland-dev libxkbcommon-dev
      libegl1-mesa-dev libx11-dev libxft-dev libxext-dev qpwgraph compton m4
      libaubio-dev libpng-dev libboost-all-dev librtmidi-dev
      libjack-jackd2-dev
      pipewire pipewire-pulse wireplumber pipewire-bin pulseaudio-utils"


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

# Boost.System has been HEADER-ONLY since Boost 1.69, and newer packaging has
# stopped shipping a separate boost_system CMake config. app/api/CMakeLists.txt
# still asks for it:
#
#     find_package(Boost 1.74 REQUIRED COMPONENTS filesystem system thread)
#
# so on a release with a newer Boost that line fails against a COMPLETELY
# installed Boost - every other component is there, `system` alone is not, and
# REQUIRED turns a missing config into a hard error. The symptom is "cmake
# cannot find Boost" while every boost package is present.
#
# Dropping the component is safe: nothing in the api links boost::system (its
# own sources use the header-only algorithm/string), and Boost::filesystem
# carries its own transitive deps. Verified against 1.83 - the find still
# yields "Boost::filesystem;Boost::thread".
#
# Applied ONLY when boost_system is genuinely absent, so on 24.04, where it
# still ships, the tree is left exactly as upstream has it.
patch_boost() {
  f="$SRC/app/api/CMakeLists.txt"
  [ -f "$f" ] || return 0
  grep -q "COMPONENTS filesystem system thread" "$f" || return 0   # already done
  if ls -d /usr/lib/*/cmake/boost_system-* >/dev/null 2>&1; then
    return 0                                                       # not needed here
  fi
  cp "$f" "$f.orig"
  sed -i "s/COMPONENTS filesystem system thread/COMPONENTS filesystem thread/" "$f"
  echo "  no boost_system CMake config on this system (header-only since Boost 1.69)"
  echo "  -> dropped the 'system' component from app/api/CMakeLists.txt (.orig kept)"
}

# Sonic Pi's GUI scope/spectrum view reads scsynth's audio through a
# boost::interprocess shared-memory segment, and ScopeWindow::Booted()
# (app/gui/visualizer/scope_window.cpp) unconditionally re-enables it every
# time scsynth boots - AudioProcessor_Enable(true), independent of any
# show-scopes/show-spectrum GUI setting. That segment is only ever CREATED by
# Sonic Pi's own bundled/patched SuperCollider fork, never by the SYSTEM
# scsynth this script deliberately uses (see the header) - so
# server_shared_memory_client's constructor always throws
# std::runtime_error("Cannot connect to shared memory") on every boot.
#
# That throw happens on AudioProcessor's own std::thread with no try/catch
# anywhere in the call chain (app/api/src/audio/audio_processor.cpp), so it
# escapes into std::terminate and takes the whole GUI down a few seconds after
# every single launch - confirmed by running it under start-46.sh and reading
# the crash back through this exact call chain.
#
# Wrapping the connect attempt in try/catch turns that into what the existing
# failure path already handles: an invalid reader that the 1s retry loop in
# AudioProcessor::Run() just tries again forever. The scope/spectrum view
# never works against the system scsynth, but nothing crashes.
patch_shm_crash() {
  f="$SRC/app/api/src/audio/audio_processor.cpp"
  [ -f "$f" ] || return 0
  grep -q "catch (const std::exception& e)" "$f" && return 0   # already done

  cp "$f" "$f.orig"
  python3 - "$f" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

old = """void AudioProcessor::ResetConnection()
{
    m_shmClient.reset(new server_shared_memory_client(m_scSynthPort));
    m_shmReader = m_shmClient->get_scope_buffer_reader(0);

    if (m_shmReader.valid())"""

new = """void AudioProcessor::ResetConnection()
{
    // The system scsynth (unlike Sonic Pi's own bundled/patched build) never creates
    // this shared memory segment, so this throws on every attempt when running against
    // it. Uncaught, that escapes this background thread and calls std::terminate -
    // crashing the whole GUI as soon as scsynth boots. Treat it the same as an invalid
    // reader instead: the caller already retries on a 1s timer.
    try
    {
        m_shmClient.reset(new server_shared_memory_client(m_scSynthPort));
        m_shmReader = m_shmClient->get_scope_buffer_reader(0);
    }
    catch (const std::exception& e)
    {
        LOG(ERR, "Failed to connect to shared audio memory: " << e.what());
        return;
    }

    if (m_shmReader.valid())"""

if old not in src:
    sys.exit("patch_shm_crash: expected ResetConnection() body not found - upstream source may have changed, patch needs updating")

with open(path, "w") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

  echo "  system scsynth never creates the GUI's scope shared-memory segment (only the bundled fork does)"
  echo "  -> wrapped ResetConnection()'s connect attempt in try/catch so it retries instead of crashing the GUI (.orig kept)"
}

do_clean() {
  hdr "Removing build directory"
  rm -rf "$SRC/app/build" && echo "  gone - the next build reconfigures from scratch"
}

do_build() {
  hdr "Building (30-60 min; full log: $LOG)"
  [ -d "$SRC/app" ] || { echo "  no source - run '$0 clone' first"; return 1; }
  patch_boost
  patch_shm_crash

  # A POISONED CMAKE CACHE is the reason "boost is installed but cmake cannot
  # find it" survives reinstalling boost. linux-config.sh only does
  # `mkdir -p build; cd build; cmake ..` - it never wipes - so a configure that
  # ran before the dependency was present caches Boost_DIR:PATH=Boost_DIR-NOTFOUND,
  # and CMake NEVER RE-SEARCHES a cached NOTFOUND. Installing the package
  # afterwards changes nothing until the cache goes.
  cache="$SRC/app/build/CMakeCache.txt"
  if [ -f "$cache" ] && grep -qiE '^[A-Za-z_]*(Boost|BOOST)[A-Za-z_]*:(PATH|FILEPATH)=.*NOTFOUND' "$cache"; then
    echo "  stale cache: Boost is recorded as NOTFOUND - removing build/ so it searches again"
    rm -rf "$SRC/app/build"
  fi

  cd "$SRC/app" || return 1
  # The distro default, unless you say otherwise - see the header for why
  # pinning an older gcc breaks the Qt link. cmake honours CC/CXX from the
  # environment, so `CC=gcc-12 CXX=g++-12 ./build-sonicpi-46.sh build` still
  # works if a specific compiler is ever needed.
  if [ -n "${CC:-}" ] || [ -n "${CXX:-}" ]; then
    echo "  CC=${CC:-<default>} CXX=${CXX:-<default>} (from the environment)"
  else
    echo "  compiler: $(cc --version 2>/dev/null | head -1)"
    echo "  (libstdc++: $(readlink -f /usr/lib/*/libstdc++.so.6 2>/dev/null | head -1 | xargs -r basename))"
  fi
  ./linux-build-all.sh 2>&1 | tee "$LOG"
  rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ] && [ -x "$BIN" ]; then
    printf '\n\033[32m  BUILD OK -> %s\033[0m\n' "$BIN"
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
  clean) do_clean ;;
  all)   do_deps && do_clone && do_build ;;
  *) echo "usage: $0 [deps|clone|build|clean|all]" >&2; exit 2 ;;
esac
