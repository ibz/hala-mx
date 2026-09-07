#!/usr/bin/env python3
"""
Pre-renders the M=0 burst (the stochastic rain) into WAV files, one per channel.

Why: in Sonic Pi the burst meant ~144 grains in 0.45 s across 8 channels, i.e.
~320 events/second. The scheduler (a single Ruby process) can't keep up and
kills the threads with a TimingError. Rendered offline, the same grains
become 8 files that Sonic Pi triggers with 8 events.

Only the dry grain layer is rendered. The FX chains (hpf+flanger for the
ceiling, lpf+distortion for the floor, tanh throughout) stay in Sonic Pi: we
don't try to reproduce the SuperCollider filters, and they stay tunable live.

Output: mono float32 WAV (not 16-bit) - the sum of the floor grains
intentionally exceeds 1.0, because it's the INPUT to a distortion stage, not
the final level.

Run:  python3 render_m0.py
"""
import glob, math, os, random, struct, sys, wave

BASE   = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "output_xenakis_installation")
OUT    = os.path.join(BASE, "m0_render")
SR     = 48000
M0_DUR  = 0.45         # burst at full density; equal to m0_dur in xenakis.rb
M0_TAIL = 2.60         # tail: the rain THINS OUT, long, over the whole exhale
RENDER  = 3.60         # + room for the last tail grains to sound out in full
K_DENS  = 1.2          # how fast the rain thins out (e^-k*t) - gentle
# NOTE: the AMPLITUDE decay is almost inaudible at the output, because both
# M=0 chains saturate (distortion / hpf amp 6 -> tanh), and a saturator
# flattens level changes. The real volume ramp happens in xenakis.rb, with
# `control` on the tanh's amp, AFTER saturation. Here we leave only a slight
# decrease, so the late grains are both rarer and softer.
K_AMP   = 0.5
NVAR   = 8             # how many variants, so M=0 isn't identical every breath
POOL   = 256           # how many distinct files enter the selection

# The layers are now folders, not fragments of a filename.
LAYERS = {
    "ceil":  dict(sub="inhale/high",             lam=180.0,
                  amp=(0.30, 0.40), rate=(-2.0, -1.5), atk=0.02,  rel=0.2),
    "floor": dict(sub="sonic_blast_m0/n5_n6_n7", lam=120.0,
                  amp=(1.0,  1.4),  rate=(0.35, 0.5),  atk=0.005, rel=0.22),
}

def pool_for(sub, limit):
    sel = sorted(glob.glob(os.path.join(BASE, sub, "*.wav")))
    if len(sel) <= limit:
        return sel
    st = len(sel) / limit
    return [sel[math.floor(i * st)] for i in range(limit)]

_cache = {}
def load(path):
    if path not in _cache:
        w = wave.open(path); n = w.getnframes()
        raw = w.readframes(n); w.close()
        _cache[path] = [v / 32768.0 for v in struct.unpack("<%dh" % n, raw)]
    return _cache[path]

def grain(path, rate, amp, atk, rel):
    """Reproduces the Sonic Pi sampler: negative rate = reversed; the
    attack/release envelope compresses if it doesn't fit in the grain's duration."""
    d = load(path)
    if rate < 0:
        d = d[::-1]
    r = abs(rate)
    n = max(1, int(len(d) / r))
    last = len(d) - 1
    y = [d[min(int(i * r), last)] * amp for i in range(n)]
    a, rl = int(atk * SR), int(rel * SR)
    if a + rl > n:
        sc = n / (a + rl); a = int(a * sc); rl = n - a
    for i in range(a):
        y[i] *= i / a
    for i in range(rl):
        y[n - rl + i] *= 1 - i / rl
    return y

def write_f32(path, samples):
    """Mono float32 WAV written by hand - the `wave` module doesn't support float."""
    data = b"".join(struct.pack("<f", s) for s in samples)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, SR, SR * 4, 4, 32))
        f.write(b"data" + struct.pack("<I", len(data)))
        f.write(data)

def main():
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "*.wav")):
        os.remove(old)
    nframes = int(RENDER * SR)
    total_peak = {}
    for layer, cfg in LAYERS.items():
        pool = pool_for(cfg["sub"], POOL)
        if not pool:
            sys.exit("no files for layer %s" % layer)
        peaks, counts = [], []
        for v in range(NVAR):
            random.seed(hash((layer, v)) & 0x7fffffff)
            chans = [[0.0] * nframes for _ in range(4)]
            t, n = 0.0, 0
            span = M0_DUR + M0_TAIL
            while True:
                # Non-homogeneous Poisson process: density decays
                # exponentially in the tail. Generated at the max rate and
                # thinned by rejecting events with the missing probability -
                # the correct method for a rate that varies over time.
                t += -math.log(1 - random.random()) / cfg["lam"]
                if t >= span:
                    break
                if t > M0_DUR:
                    decay = math.exp(-K_DENS * (t - M0_DUR))
                    if random.random() > decay:
                        continue                          # rejected: the rain has thinned
                    amp_scale = math.exp(-K_AMP * (t - M0_DUR))
                else:
                    amp_scale = 1.0
                c = random.randrange(4)                   # rain: random channel
                g = grain(random.choice(pool),
                          random.uniform(*cfg["rate"]),
                          random.uniform(*cfg["amp"]) * amp_scale,
                          cfg["atk"], cfg["rel"])
                off = int(t * SR)
                buf = chans[c]
                for k, s in enumerate(g):
                    if off + k < nframes:
                        buf[off + k] += s
                n += 1
            counts.append(n)
            for c in range(4):
                write_f32(os.path.join(OUT, "%s_v%02d_ch%d.wav" % (layer, v, c)),
                          chans[c])
                peaks.append(max(abs(x) for x in chans[c]))
        total_peak[layer] = (max(peaks), sum(counts) / len(counts))
        print("%-6s %d variants x 4 channels, ~%.0f grains/variant, dry peak %.2f"
              % (layer, NVAR, total_peak[layer][1], total_peak[layer][0]))
        # energy profile in 0.25 s windows, to see the curve
        win = int(0.25 * SR)
        prof = []
        for w in range(0, nframes - win, win):
            e = sum(x * x for ch in chans for x in ch[w:w + win])
            prof.append(10 * math.log10(e / (win * 4) + 1e-12))
        ref = prof[0]
        print("       curve: " + "  ".join("%.2fs %+.0f" % (i * 0.25, p - ref)
                                           for i, p in enumerate(prof)) + " dB")
    files = glob.glob(os.path.join(OUT, "*.wav"))
    print("\n%d files in %s  (%.1f MB)"
          % (len(files), OUT, sum(os.path.getsize(f) for f in files) / 1048576))
    print("Sonic Pi will trigger 8 samples per breath instead of ~144 grains.")

if __name__ == "__main__":
    main()
