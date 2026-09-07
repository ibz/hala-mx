#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "numpy",
#     "scipy",
#     "soundfile",
# ]
# ///
"""ATMOS: 16 s slices, stereo, 24-bit.

A separate chain from grains_slice.py — no granulation, no CLAP, no whitelist.
Sources stay STEREO (the folders are Doppler A/B, Front/Rear: the spatial
information is the whole point here) and are normalized per file, not per
slice, so the breathing dynamics survive.

    read 96k stereo
      -> BPF 120-8000            (same as the grains)
      -> presence bell           (clarity in 2-6 kHz)
      -> exciter                 (harmonics generated from 200-1200 Hz)
      -> normalize per file      (after the boost, so we don't clip 0 dBFS)
      -> 96k -> 48k              (exact 2:1)
      -> 16 s slices + fade
      -> 24-bit stereo

    ./atmos_slice.py              runs everything
    ./atmos_slice.py --limit 2    only the first 2 files (test)
    ./atmos_slice.py --dry-run    report only, don't write
"""

import os
import shutil
import sys
import time
import warnings

import numpy as np
import soundfile as sf
from scipy.io import wavfile
from scipy.signal import butter, lfilter, resample_poly, sosfilt

warnings.filterwarnings("ignore")

import grains_slice as slicer

# ==============================================================================
# CONFIGURATION
# ==============================================================================
ATMOS_ROOT = "ATMOS"
OUTPUT_SUBDIR = "atmos"

TARGET_SR = 48000
SLICE_S = 16.0
HOP_S = 16.0          # = SLICE_S -> back-to-back slices; smaller -> overlap
FADE_MS = 250.0       # 5 ms would click on a 16 s slice
SILENCE_DBFS = -60.0  # slices quieter than this get dropped

# The presence bell: articulation, breathing detail.
PRESENCE = {"fc": 3500.0, "q": 0.7, "gain_db": 3.0}

# The exciter: the material has almost nothing in 2-6 kHz, so we can't just
# boost it — we SYNTHESIZE it. We take the low-mid band (where the FX
# character actually lives), distort it gently to spawn harmonics, keep only
# the harmonics that fall in the presence band, and mix them back in.
EXCITER = {
    "in_band": (200.0, 1200.0),
    "drive": 4.0,
    "out_band": (2000.0, 6000.0),
    "mix_db": -14.0,
}


# ==============================================================================
# DSP
# ==============================================================================
def peaking_eq(fc, q, gain_db, fs):
    """Biquad peaking (RBJ cookbook)."""
    a_gain = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * fc / fs
    alpha = np.sin(w0) / (2.0 * q)
    cos_w0 = np.cos(w0)

    b = np.array([1 + alpha * a_gain, -2 * cos_w0, 1 - alpha * a_gain])
    a = np.array([1 + alpha / a_gain, -2 * cos_w0, 1 - alpha / a_gain])
    return b / a[0], a / a[0]


def bandpass_sos(lo, hi, fs, order=4):
    nyq = 0.5 * fs
    return butter(order, [lo / nyq, min(hi / nyq, 0.99)],
                  btype="band", output="sos")


def apply_per_channel(x, fn):
    """Filters channel by channel, in place, keeping float32.

    scipy's coefficients are float64 and would promote the whole signal to
    float64: on a 7-minute file at 96 k that means 634 MB per array instead
    of 317, and the chain becomes tens of times slower from the memory
    pressure alone.
    """
    out = np.empty_like(x, dtype=np.float32)
    for c in range(x.shape[1]):
        out[:, c] = fn(x[:, c]).astype(np.float32, copy=False)
    return out


def presence_bell(x, fs):
    b, a = peaking_eq(PRESENCE["fc"], PRESENCE["q"], PRESENCE["gain_db"], fs)
    return apply_per_channel(x, lambda ch: lfilter(b, a, ch))


def exciter(x, fs):
    """Harmonics generated from the low-mid band, returned into the presence band."""
    sos_in = bandpass_sos(*EXCITER["in_band"], fs)
    sos_out = bandpass_sos(*EXCITER["out_band"], fs)
    mix = np.float32(10.0 ** (EXCITER["mix_db"] / 20.0))
    drive = np.float32(EXCITER["drive"])

    harmonics = np.empty_like(x, dtype=np.float32)
    for c in range(x.shape[1]):
        driven = np.tanh(drive * sosfilt(sos_in, x[:, c]))
        harmonics[:, c] = sosfilt(sos_out, driven).astype(np.float32, copy=False)

    peak = np.max(np.abs(harmonics))
    if peak > 0:
        harmonics *= np.float32(1.0 / peak)   # level independent of the input
    harmonics *= mix
    x += harmonics                            # in place, no new array
    return x


# ==============================================================================
# I/O
# ==============================================================================
def zone_and_slug(path):
    """ATMOS is three levels deep: the zone (Inhale/Exhale/M0) + the leaf folder.

    The leaf alone would lose the grouping — 'Exhale' doesn't appear in its name.
    """
    rel = os.path.relpath(path, os.path.join(slicer.PROJECT_DIR, ATMOS_ROOT))
    parts = rel.split(os.sep)
    zone = slicer.auto_slug(parts[0]) if parts else "other"
    leaf = parts[-2] if len(parts) > 2 else parts[0]
    for junk in (" 24 96", " 24 96k", "24 96"):
        leaf = leaf.replace(junk, "")
    return zone, slicer.auto_slug(leaf)


def reset_output(out_root):
    """Deletes ONLY atmos/ — the grain folders from grains_slice.py stay untouched."""
    parent = os.path.abspath(slicer.OUTPUT_FOLDER)
    if os.path.dirname(os.path.abspath(out_root)) != parent:
        raise SystemExit(f"Refusing to delete an unexpected path: {out_root}")

    if os.path.isdir(out_root):
        old = sum(len(files) for _, _, files in os.walk(out_root))
        shutil.rmtree(out_root)
        print(f"Deleted {old} slices from {OUTPUT_SUBDIR}/.")
    os.makedirs(out_root, exist_ok=True)


def collect():
    root = os.path.join(slicer.PROJECT_DIR, ATMOS_ROOT)
    found = []
    for dirpath, _, files in os.walk(root):
        for name in sorted(files):
            if name.lower().endswith(".wav") and not name.startswith("._"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def load_stereo(path):
    fs, data = wavfile.read(path)
    if data.ndim == 1:
        data = np.column_stack([data, data])       # mono -> duplicated to stereo
    data = data.astype(np.float32)
    peak = np.max(np.abs(data))
    if peak > 0:
        data = data / peak
    return fs, data[:, :2]


def process_file(path, out_root, dry_run=False):
    fs, audio = load_stereo(path)
    zone, slug = zone_and_slug(path)

    # Same BPF as the grains, but on each channel separately.
    audio = apply_per_channel(audio, lambda ch: slicer.apply_filter(
        ch, slicer.LOW_CUT, slicer.HIGH_CUT, fs))

    audio = presence_bell(audio, fs)
    audio = exciter(audio, fs)

    peak = np.max(np.abs(audio))                   # normalize AFTER the boost
    if peak > 0:
        audio = audio / peak * 0.98

    if fs != TARGET_SR:
        if fs % TARGET_SR == 0:
            audio = resample_poly(audio, 1, fs // TARGET_SR, axis=0)
        else:
            from math import gcd
            g = gcd(int(fs), TARGET_SR)
            audio = resample_poly(audio, TARGET_SR // g, int(fs) // g, axis=0)
        audio = audio.astype(np.float32, copy=False)

    win = int(SLICE_S * TARGET_SR)
    hop = int(HOP_S * TARGET_SR)
    fade = int(FADE_MS / 1000.0 * TARGET_SR)
    ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)
    floor = 10.0 ** (SILENCE_DBFS / 20.0)

    base = os.path.splitext(os.path.basename(path))[0].replace(" ", "_")
    out_dir = os.path.join(out_root, zone, slug)
    if not dry_run:
        os.makedirs(out_dir, exist_ok=True)

    written = skipped = 0
    for idx, start in enumerate(range(0, max(len(audio) - win + 1, 0), hop)):
        chunk = audio[start:start + win].copy()
        if np.sqrt(np.mean(chunk ** 2)) < floor:
            skipped += 1
            continue
        chunk[:fade] *= ramp[:, None]
        chunk[-fade:] *= ramp[::-1][:, None]
        if not dry_run:
            sf.write(os.path.join(out_dir, f"{base}_{idx:03d}.wav"),
                     chunk, TARGET_SR, subtype="PCM_24")
        written += 1

    return zone, slug, written, skipped, len(audio) / TARGET_SR


if __name__ == "__main__":
    dry_run = "--dry-run" in sys.argv
    files = collect()
    if "--limit" in sys.argv:
        files = files[:int(sys.argv[sys.argv.index("--limit") + 1])]

    out_root = os.path.join(slicer.OUTPUT_FOLDER, OUTPUT_SUBDIR)
    if not dry_run:
        reset_output(out_root)
    print(f"ATMOS: {len(files)} files -> {OUTPUT_SUBDIR}/"
          + ("   [DRY RUN]" if dry_run else ""))
    print(f"slices of {SLICE_S:.0f}s, hop {HOP_S:.0f}s, fade {FADE_MS:.0f}ms, "
          f"{TARGET_SR//1000}k stereo 24-bit\n")

    started = time.time()
    totals, skipped_total = {}, 0
    for n, path in enumerate(files, 1):
        t0 = time.time()
        zone, slug, written, skipped, dur = process_file(path, out_root, dry_run)
        skipped_total += skipped
        totals[(zone, slug)] = totals.get((zone, slug), 0) + written
        print(f"  [{n}/{len(files)}] {os.path.basename(path)[:44]:<44} "
              f"{dur:6.0f}s -> {written:3d} slices"
              + (f" ({skipped} silent)" if skipped else "")
              + f"   {time.time()-t0:.0f}s")

    print(f"\n{'zone / folder':<44}{'slices':>7}")
    print("-" * 52)
    for (zone, slug), count in sorted(totals.items()):
        print(f"  {zone}/{slug:<40}{count:>7}")
    total = sum(totals.values())
    size_mb = total * SLICE_S * TARGET_SR * 3 * 2 / 1e6
    print("-" * 52)
    print(f"  {'TOTAL':<42}{total:>7}   ~{size_mb/1000:.1f} GB"
          + (f", {skipped_total} silent slices skipped" if skipped_total else ""))
    print(f"  in {(time.time()-started)/60:.1f} min")
