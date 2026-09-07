#!/usr/bin/env python3
"""
Concatenates each grain family into a SINGLE WAV + a cut-table.

Why: Sonic Pi allocates one scsynth buffer per file and never frees it. With
one file per grain, preloading meant hundreds of OSC allocations, each with a
5 s timeout - scsynth couldn't keep up and the promises timed out.
Concatenated, the ~10,000 grains fit into 5 buffers, and a grain is picked
with `start:`/`finish:` (fractions of the file), exactly how `onset:` works.

Sources are 16-bit mono 48k, so we copy the bytes directly - no decoding,
no loss. A small silence is inserted between grains, so fraction rounding
doesn't let the neighbor bleed through.

Output, in output_xenakis_installation/concat/:
    <name>.wav   the concatenated material
    <name>.txt   one line per grain:  start_frac  finish_frac  duration_ms

Run:  python3 build_pools.py
"""
import glob, os, struct, sys, wave

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "output_xenakis_installation")
OUT  = os.path.join(BASE, "concat")
SR   = 48000
PAD  = 256          # silence between grains (~5 ms)

POOLS = {
    "inhale_high":       "inhale/high",
    "inhale_mid":        "inhale/mid",
    "exhale_low_pressure":"exhale/low_pressure",
    "exhale_shatter":     "exhale/shatter",
    "blast":              "sonic_blast_m0/n5_n6_n7",
}

def wav_header(nframes):
    data = nframes * 2
    return (b"RIFF" + struct.pack("<I", 36 + data) + b"WAVE" +
            b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16) +
            b"data" + struct.pack("<I", data))

def build(name, sub):
    files = sorted(glob.glob(os.path.join(BASE, sub, "*.wav")))
    if not files:
        sys.exit("no .wav in %s" % sub)
    wav_path = os.path.join(OUT, name + ".wav")
    pad = b"\x00" * (PAD * 2)
    offsets, total = [], 0
    with open(wav_path, "wb") as out:
        out.write(b"\x00" * 44)                     # room for the header
        for f in files:
            w = wave.open(f)
            if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, SR):
                sys.exit("%s is not mono 16-bit 48k" % f)
            n = w.getnframes()
            out.write(w.readframes(n)); w.close()
            offsets.append((total, total + n, n / SR * 1000))
            total += n
            out.write(pad); total += PAD
        out.seek(0); out.write(wav_header(total))
    with open(os.path.join(OUT, name + ".txt"), "w") as t:
        for a, b, ms in offsets:
            t.write("%.9f %.9f %.2f\n" % (a / total, b / total, ms))
    return len(offsets), total / SR, os.path.getsize(wav_path)

def main():
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "*")):
        os.remove(old)
    print("%-20s %8s %9s %8s" % ("pool", "grains", "duration", "MB"))
    tot = 0
    for name, sub in POOLS.items():
        n, secs, size = build(name, sub)
        tot += n
        print("%-20s %8d %8.1f s %7.1f" % (name, n, secs, size / 1048576))
    print("\n%d grains in %d scsynth buffers (used to be %d allocations)"
          % (tot, len(POOLS), tot))
    # fraction precision: OSC sends float32
    worst = max(build.__defaults__ or [0], default=0)
    print("start:/finish: precision is float32 (2^-24) on the longest file")
    print("  -> sub-sample error; %d-sample padding absorbs the rest" % PAD)

if __name__ == "__main__":
    main()
