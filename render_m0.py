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
import glob, math, os, random, struct, sys, wave, zlib

BASE   = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "output_xenakis_installation")
OUT    = os.path.join(BASE, "m0_render")
SR     = 48000
M0_DUR  = 0.45         # burst at full density; equal to m0_dur in xenakis.rb
M0_TAIL = 2.60         # tail: the rain THINS OUT, long, over the whole exhale
K_DENS  = 1.2          # how fast the rain thins out (e^-k*t) - gentle

# THE TAIL STRETCHES. Over the second half of M=0, as it hands over to the
# exhale, each grain is played SLOWER - the same source, a lower rate, so it
# lasts longer - and the rain thins in proportion. The two are one gesture:
# the rain stops being rain and becomes a few long smears before it goes.
#
# It has to happen HERE and not in Sonic Pi, because `rate` is an :ir
# parameter in the player synthdef (samplers.clj) - fixed when the synth
# starts, not modulatable - so a playing sample cannot be slowed down.
#
# s(t) is exponential in the tail's progress, not linear: stretch is a RATIO,
# so equal steps of it are equal musical steps. s = 1.0 at the burst's end,
# STRETCH_END at the end of the tail.
STRETCH_END = 4.0      # grain length multiplier at the end of the tail; 1.0 = off

# DENSITY FOLLOWS THE STRETCH, exactly. The accept probability carries a 1/s
# factor on top of the existing exponential thinning, so the event rate is
# lam * exp(-K_DENS*dt) / s(t). Proportional is the right coupling and not an
# arbitrary one: grains s times longer arriving s times more rarely occupy the
# same total sounding time, so the texture keeps its continuity while the
# events inside it become long and slow. Without it the stretched tail turns
# to mush - s times longer at the same rate is s times the overlap.
#
# THE CLOUD FADES OUT. A cosine taper over the whole buffer from FADE_FROM to
# the end, so the rendered material dissolves instead of stopping. Note what
# the K_AMP comment below says though: both M=0 chains saturate, so a fade in
# the render is largely flattened by the time it reaches the output. The fade
# that is actually AUDIBLE is xen_m0_fade in xenakis.rb, on the tanh's amp,
# after the saturation. This one keeps the render itself honest - and stops
# the last, longest grains being cut off mid-flight by the buffer's end.
FADE_FROM = M0_DUR + M0_TAIL * 0.5
# NOTE: the AMPLITUDE decay is almost inaudible at the output, because both
# M=0 chains saturate (distortion / hpf amp 6 -> tanh), and a saturator
# flattens level changes. The real volume ramp happens in xenakis.rb, with
# `control` on the tanh's amp, AFTER saturation. Here we leave only a slight
# decrease, so the late grains are both rarer and softer.
K_AMP   = 0.5

# THE ONSET. Measured on the render as it stood: the first 60 ms of a channel
# were digitally SILENT and it took ~100 ms to reach 90 % of peak. The cause is
# the channel draw - `random.randrange(4)` sends each grain to one speaker, so
# any single channel's first grain arrives at a mean 4/lam (33 ms on the floor,
# and the tail of that distribution is long). An impact that fades up over
# 100 ms is not an impact, and no amount of gain fixes it: both chains saturate,
# so the burst is a flat wall at the ceiling either way. What was missing was an
# EDGE, not level.
#
# So each channel gets ONSET_GRAINS placed deterministically at t = 0, at the
# top of the layer's amplitude range and with the attack forced to ONSET_ATK -
# every speaker fires on the downbeat instead of waiting for the dice. The
# saturation flattens their level with everything else, which is fine: what
# survives saturation is the RISE TIME, and that is what reads as mass.
ONSET_GRAINS = 5       # per channel, placed at t=0; 0 restores the old soft onset
ONSET_ATK    = 0.0005  # 0.5 ms - a real edge, still long enough not to click
NVAR   = 8             # how many variants, so M=0 isn't identical every breath
POOL   = 256           # how many distinct files enter the selection

# The layers are now folders, not fragments of a filename.
LAYERS = {
    # inspir/, not inhale/ - the folder was renamed and this was never updated,
    # so pool_for() returned nothing and the script exited on "no files for
    # layer ceil". It could not have run at all as it stood.
    "ceil":  dict(sub="inspir/high",             lam=180.0,
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
    data = struct.pack("<%df" % len(samples), *samples)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, SR, SR * 4, 4, 32))
        f.write(b"data" + struct.pack("<I", len(data)))
        f.write(data)

def main():
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "*.wav")):
        os.remove(old)
    pools = {}
    for layer, cfg in LAYERS.items():
        pools[layer] = pool_for(cfg["sub"], POOL)
        if not pools[layer]:
            sys.exit("no files for layer %s" % layer)

    # RENDER is DERIVED now, not a written-down 3.60. The slowest grain is the
    # longest source in the pool played at the lowest rate the stretch
    # produces, and it can start as late as `span`. Guessing this truncates
    # exactly the grains the gesture is about, and silently - the mixdown just
    # stops writing past the end of the buffer.
    span = M0_DUR + M0_TAIL
    longest = 0.0
    for layer, cfg in LAYERS.items():
        src_s = max(len(load(f)) for f in pools[layer]) / SR
        slowest = min(abs(r) for r in cfg["rate"]) / STRETCH_END
        longest = max(longest, src_s / slowest)
    RENDER = span + longest
    nframes = int(RENDER * SR)
    print("span %.2f s + longest stretched grain %.2f s -> render %.2f s"
          % (span, longest, RENDER))
    print("tail stretch 1.0 -> %.1fx, density thinned by the same factor\n"
          % STRETCH_END)

    total_peak = {}
    for layer, cfg in LAYERS.items():
        pool = pools[layer]
        peaks, counts = [], []
        for v in range(NVAR):
            # crc32, not hash(): str hashing is salted per process unless
            # PYTHONHASHSEED is set, so this "seed" produced DIFFERENT variants
            # on every run and no render was ever reproducible. Now it is.
            random.seed(zlib.crc32(("%s%d" % (layer, v)).encode()))
            chans = [[0.0] * nframes for _ in range(4)]
            t, n = 0.0, 0
            span = M0_DUR + M0_TAIL

            # The onset, before the stochastic rain starts - see ONSET_GRAINS.
            for c in range(4):
                for _ in range(ONSET_GRAINS):
                    g = grain(random.choice(pool),
                              random.uniform(*cfg["rate"]),
                              cfg["amp"][1],            # top of the range, not a draw
                              ONSET_ATK, cfg["rel"])
                    buf = chans[c]
                    for k, s in enumerate(g):
                        if k < nframes:
                            buf[k] += s
                    n += 1
            while True:
                # Non-homogeneous Poisson process: density decays
                # exponentially in the tail. Generated at the max rate and
                # thinned by rejecting events with the missing probability -
                # the correct method for a rate that varies over time.
                t += -math.log(1 - random.random()) / cfg["lam"]
                if t >= span:
                    break
                if t > M0_DUR:
                    u = (t - M0_DUR) / M0_TAIL            # 0 .. 1 across the tail
                    stretch = STRETCH_END ** u            # 1 .. STRETCH_END
                    # Thinned by the exponential AND by 1/stretch, so the event
                    # rate is lam * exp(-K_DENS*dt) / stretch - density falls
                    # exactly as fast as the grains lengthen.
                    decay = math.exp(-K_DENS * (t - M0_DUR)) / stretch
                    if random.random() > decay:
                        continue                          # rejected: the rain has thinned
                    amp_scale = math.exp(-K_AMP * (t - M0_DUR))
                else:
                    stretch, amp_scale = 1.0, 1.0
                c = random.randrange(4)                   # rain: random channel
                # rate DIVIDED by the stretch: lower rate, longer grain. The
                # ceil rates are negative (reversed) and stay negative.
                # atk/rel stay absolute, as they are in the real sampler - a
                # stretched grain gets a proportionally shorter envelope.
                g = grain(random.choice(pool),
                          random.uniform(*cfg["rate"]) / stretch,
                          random.uniform(*cfg["amp"]) * amp_scale,
                          cfg["atk"], cfg["rel"])
                off = int(t * SR)
                buf = chans[c]
                for k, s in enumerate(g):
                    if off + k < nframes:
                        buf[off + k] += s
                n += 1

            # THE CLOUD DISSOLVES. Raised cosine from FADE_FROM to the end of
            # the buffer, so the rendered tail reaches silence instead of
            # stopping, and the last long grains ring out inside the fade
            # rather than being cut by the buffer's edge.
            fs = int(FADE_FROM * SR)
            for c in range(4):
                buf = chans[c]
                for i in range(fs, nframes):
                    buf[i] *= 0.5 * (1 + math.cos(math.pi * (i - fs) / (nframes - fs)))
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
