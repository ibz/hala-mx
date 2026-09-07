#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "numpy",
#     "scipy",
#     "torch",
#     "transformers",
# ]
#
# [[tool.uv.index]]
# name = "pytorch-cpu"
# url = "https://download.pytorch.org/whl/cpu"
# explicit = true
#
# [tool.uv.sources]
# torch = { index = "pytorch-cpu" }
# ///
"""Indexes the sources with CLAP: a sliding window over each file,
one embedding per window, all cached to disk.

The cache depends ONLY on the source file (path + mtime + size) and the
window parameters — not on the random grains. It stays valid no matter how
many times you run grains_slice.py afterward.

    ./clap_index.py                 indexes the audio (slow, once)
    ./clap_index.py --prompts       only re-encodes the prompts (seconds)
    ./clap_index.py --status        what's indexed and what's missing
"""

import hashlib
import json
import os
import sys
import time
import warnings

import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly

warnings.filterwarnings("ignore")

import grains_slice as slicer

CLAP_SR = 48000
BATCH = 8


def cache_key(path):
    """A source's identity: content (mtime+size) + the window parameters."""
    st = os.stat(path)
    raw = (f"{os.path.relpath(path, slicer.PROJECT_DIR)}|{st.st_mtime_ns}|{st.st_size}"
           f"|{slicer.CLAP_WINDOW_S}|{slicer.CLAP_HOP_S}|{slicer.CLAP_MODEL}")
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def cache_path(path):
    return os.path.join(slicer.clap_cache_dir(), cache_key(path) + ".npz")


def load_mono_48k(path):
    fs, data = wavfile.read(path)
    if data.ndim > 1:
        data = data.mean(axis=1)
    data = data.astype(np.float32)
    peak = np.max(np.abs(data))
    if peak > 0:
        data /= peak
    if fs != CLAP_SR:
        data = resample_poly(data, CLAP_SR, fs)
    return data


def window_starts(num_samples):
    win = int(slicer.CLAP_WINDOW_S * CLAP_SR)
    hop = int(slicer.CLAP_HOP_S * CLAP_SR)
    if num_samples < win:
        return np.array([0]), win
    last = num_samples - win
    return np.arange(0, last + 1, hop), win


def embed_windows(audio, model, proc, torch):
    starts, win = window_starts(len(audio))
    out = np.empty((len(starts), 512), dtype=np.float32)

    for b in range(0, len(starts), BATCH):
        chunk = starts[b:b + BATCH]
        wins = []
        for s in chunk:
            w = audio[s:s + win]
            if len(w) < win:                       # last window, pad it out
                w = np.pad(w, (0, win - len(w)))
            wins.append(w)
        inputs = proc(audio=wins, sampling_rate=CLAP_SR,
                      return_tensors="pt", padding=True)
        with torch.no_grad():
            emb = model.get_audio_features(**inputs)
        if not torch.is_tensor(emb):
            emb = emb.pooler_output
        emb = torch.nn.functional.normalize(emb, dim=-1)
        out[b:b + len(chunk)] = emb.numpy()

    return starts / float(CLAP_SR), out


def load_clap():
    import torch
    from transformers import ClapModel, ClapProcessor
    torch.set_num_threads(os.cpu_count() or 4)
    print(f"Loading {slicer.CLAP_MODEL} ...")
    model = ClapModel.from_pretrained(slicer.CLAP_MODEL).eval()
    proc = ClapProcessor.from_pretrained(slicer.CLAP_MODEL)
    return model, proc, torch


def encode_prompts(model, proc, torch):
    """Encodes the prompts from grains_slice.py and writes them to cache."""
    names = sorted(slicer.AI_PROMPTS)
    if not names:
        print("No prompts defined in AI_PROMPTS.")
        return
    texts = [slicer.AI_PROMPTS[n] for n in names]
    inputs = proc(text=texts, return_tensors="pt", padding=True)
    with torch.no_grad():
        emb = model.get_text_features(**inputs)
    if not torch.is_tensor(emb):
        emb = emb.pooler_output
    emb = torch.nn.functional.normalize(emb, dim=-1).numpy().astype(np.float32)

    np.savez(os.path.join(slicer.clap_cache_dir(), "prompts.npz"),
             names=np.array(names), embeddings=emb,
             texts=np.array(texts), model=slicer.CLAP_MODEL)
    print(f"Encoded {len(names)} prompts: {', '.join(names)}")


def print_status(sources):
    total = missing = 0
    for path, _ in sources:
        total += 1
        if not os.path.exists(cache_path(path)):
            missing += 1
            print(f"  MISSING  {os.path.relpath(path, slicer.PROJECT_DIR)}")
    print(f"\n{total - missing}/{total} sources indexed.")
    pf = os.path.join(slicer.clap_cache_dir(), "prompts.npz")
    print(f"Prompts: {'yes' if os.path.exists(pf) else 'NO — run --prompts'}")


if __name__ == "__main__":
    os.makedirs(slicer.clap_cache_dir(), exist_ok=True)
    sources = slicer.collect_input_wavs()

    if "--status" in sys.argv:
        print_status(sources)
        raise SystemExit(0)

    model, proc, torch = load_clap()

    if "--prompts" in sys.argv:
        encode_prompts(model, proc, torch)
        raise SystemExit(0)

    todo = [(p, c) for p, c in sources if not os.path.exists(cache_path(p))]
    cached = len(sources) - len(todo)

    # --limit N: index only N files right now. The cache is incremental, so
    # you can resume anytime — it picks up exactly where it left off.
    if "--limit" in sys.argv:
        n = int(sys.argv[sys.argv.index("--limit") + 1])
        todo = sorted(todo, key=lambda pc: os.path.getsize(pc[0]))[:n]

    print(f"{len(sources)} sources, {cached} already cached, "
          f"{len(todo)} to index now.\n")

    started = time.time()
    done_windows = 0
    for n, (path, _) in enumerate(todo, 1):
        name = os.path.relpath(path, slicer.PROJECT_DIR)
        audio = load_mono_48k(path)
        t0 = time.time()
        times, emb = embed_windows(audio, model, proc, torch)
        done_windows += len(times)

        np.savez(cache_path(path), times=times, embeddings=emb,
                 source=name, duration=len(audio) / float(CLAP_SR),
                 window_s=slicer.CLAP_WINDOW_S, hop_s=slicer.CLAP_HOP_S)

        rate = done_windows / (time.time() - started)
        left = sum(1 for p, _ in todo[n:])
        print(f"  [{n}/{len(todo)}] {name}\n"
              f"          {len(times)} windows in {time.time()-t0:.0f}s "
              f"({rate:.1f} win/s, ~{left} files remaining)")

    encode_prompts(model, proc, torch)
    print(f"\nDone in {(time.time()-started)/60:.1f} min. "
          f"Cache: {slicer.clap_cache_dir()}")
