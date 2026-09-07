#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "numpy",
#     "scipy",
# ]
# ///

import os
import glob
import hashlib
import random
import shutil
import sys
import time
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, lfilter

# ==============================================================================
# PARAMETER CONFIGURATION
# ==============================================================================
# Each source root => exactly one output category (strict provenance).
# Folders are scanned recursively, so new subfolders (e.g. EXP_SHATTER)
# are picked up automatically and inherit their zone's category.
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_ROOT = os.path.join(PROJECT_DIR, "ADSR_ENVELOPES")
ZONE_CATEGORIES = {
    "M=0 n5-n6-n7": "sonic_blast_m0",
    "ZONE A INSPIR": "inhale",
    "ZONE B EXPIR": "exhale",
}
OUTPUT_FOLDER = os.path.join(PROJECT_DIR, "output_xenakis_installation")

# Output mirrors the source subfolders: inhale/mid, inhale/high, etc.
# The short names below are just for readability — a new subfolder
# automatically gets a slug from its name, without touching anything here.
SUBFOLDER_NAMES = {
    "M=0 n5-n6-n7": "n5_n6_n7",
    "IMSP_MID corp si densitate": "mid",
    "INSP_HIGH localizare si atac": "high",
    "EXP_LOW PRESSURE eliberare si drone": "low_pressure",
    "EXP_SHATTER fascicule si raze": "shatter",
}


def auto_slug(name):
    """Slug derived from the folder name, for unregistered subfolders."""
    keep = [c.lower() if c.isalnum() else "_" for c in name]
    slug = "".join(keep)
    while "__" in slug:
        slug = slug.replace("__", "_")
    return slug.strip("_") or "other"


def subfolder_slug(file_path):
    """Output subfolder name for a source."""
    leaf = os.path.basename(os.path.dirname(os.path.abspath(file_path)))
    return SUBFOLDER_NAMES.get(leaf, auto_slug(leaf))


def folder_keys(file_path):
    """The keys a source's folder can be targeted by in ZONE_KEEP.

    Both the full relative path and just the folder name work — write
    either one, the most specific match wins.
    """
    directory = os.path.dirname(os.path.abspath(file_path))
    return [os.path.relpath(directory, PROJECT_DIR),
            os.path.basename(directory)]

THRESHOLD_MULTIPLIER = 2.2
WINDOW_MS = 10
MIN_GRANULE_MS = 20
MAX_GRANULE_MS = 150
FADE_OUT_MS = 5

LOW_CUT = 120.0
HIGH_CUT = 8000.0

# ==============================================================================
# SEMANTIC ANALYSIS WITH CLAP (free-form language prompts)
# ==============================================================================
# Sources are indexed on a time grid, not grain by grain: each
# window of CLAP_WINDOW_S seconds gets an embedding, and a grain
# inherits the score of the window it was cut from.
#
# Why: an 85 ms grain is far too short for CLAP (trained on
# 10 s clips), and grains change on every run — so they could never be
# cached. The per-source index is stable and computed only once.
#
#   ./clap_index.py            builds the index (slow, once)
#   ./clap_index.py --prompts  only re-encodes the prompts (seconds)
#   ./clap_index.py --status   what's indexed
CLAP_MODEL = "laion/larger_clap_general"
CLAP_WINDOW_S = 5.0
CLAP_HOP_S = 2.5
CLAP_CACHE_DIRNAME = ".clap_cache"

# Write here what you want to detect. The name becomes a feature `ai_<name>`.
# NOTE: raw CLAP similarities are compressed (~0.0–0.25) and differ from one
# prompt to another, so absolute thresholds are meaningless. Use the
# normalized variants instead: `ai_<name>_pct` = percentile within the corpus (0–100).
# Prompts are chosen from measurements, not intuition: each one was
# checked for how much it varies WITHIN a single file (not just between files).
# A prompt that only separates files is useless for filtering — the folder
# already tells you which file a grain came from. The percentage below is that measure.
AI_PROMPTS = {
    # attack / localization        within-file
    "onset": "a single sharp transient with a clear sudden onset",        # 83%
    "shards": "bright metallic shards scattering outward",                # 81%
    # body / density
    "thick": "a thick full-bodied rushing sound, rich and heavy",         # 73%
    "resonant": "a full resonant body of sound with depth",               # 64%
    # release / pressure
    "whistle": "thin air whistling through a narrow gap",                 # 80%
    "sparse": "sparse isolated clicks with long silences between them",   # 86%
    # shards / rays
    "shatter": "glass shattering into sharp fragments",                   # 82%
    "metallic": "inharmonic metallic ringing and scraping",               # 78%
    # breathing
    "inhale": "a human inhaling sharply through the nose",                # 84%

    # --- DRAMATURGICAL ROLES (for the hall's choreography) ---
    # M=0 = SONIC BLAST: the tunnel between zones. The percentages are
    # measured WITHIN the M=0 files, where they're also applied.
    "blast": "an explosive blast with a shockwave of air",                # 93% in M=0, z+1.95
    "surge": "a roaring surge of pressure bursting outward",              # 90% in M=0, z+1.62
    "shockwave": "a shockwave passing through the body",                  # 94% in M=0, z+1.25
    "compressed": "compressed air released violently in a burst",         # 91% in M=0, z+1.32
    # the funnel: top to bottom, pulling you into the tectonic movement of the ground
    "suction": "being sucked downward, an inescapable pull into the earth",   # 88% M=0, z+1.83
    "spiral": "a descending spiral drawing inward and down",                 # 95% M=0, z+1.72
    "vortex": "a vortex pulling everything downward into a spinning core",   # 92% M=0, z+1.53
    "funnel": "a funnel of sound spiralling down from above to the ground",  # 94% M=0, z+1.13
    "tectonic": "deep tectonic grinding of shifting earth",                  # 89% M=0, z+0.52
    # leviathan / DNA — the breathing mass of the hall
    "leviathan": "an enormous creature groaning in deep water",           # 89%
    "lungs": "the deep rhythm of enormous lungs filling and emptying",    # 74%
    "swelling": "a slow swelling and receding of air, breathing in and out",  # 78%
    "organic": "wet organic biological texture, living tissue",           # 77%
    # convergence — the ear localizes by transients, not by sustain
    "impact": "a sharp precise impact with a clear location",             # 84%
    "points": "isolated points of sound separated by empty space",        # 76%

    # spurious noise — for now, just observe it in --analyze
    "handling": "microphone handling noise and bumps",                    # 82%
}


def clap_cache_dir():
    return os.path.join(PROJECT_DIR, CLAP_CACHE_DIRNAME)


# ==============================================================================
# WHITELIST — WHAT IS KEPT
# ==============================================================================
# The logic is the INVERSE of a blacklist: a grain is discarded by default
# and must QUALIFY for us to keep it.
#
# Two mechanisms, with different roles:
#
#   require    mandatory gates — the grain must pass ALL of them (AND).
#              For technical conditions: loud enough, no distortion.
#
#   match_any  semantic matches — matching ONE is enough (OR).
#              {"attack": 80} = "ai_attack puts it in the top 20% of the corpus".
#              Here you write what you WANT to hear, not what to avoid.
#
# The thresholds in match_any are PERCENTILES (0–100) computed over the whole
# corpus, not raw similarities — raw CLAP scores aren't comparable across prompts.
#
#   src_peak  peak BEFORE normalization. Low = grain from a quiet passage;
#             normalization brings it up to 1.0 and pushes background noise forward.
#   clip_pct  % of samples at the ceiling in the source — digital distortion.
#   rms       AFTER normalization. Low = transient/sharp, high = dense/sustained.
#   centroid  spectral center of mass, Hz. High = bright, low = dull.
#   flatness  0 = tonal, 1 = white noise.
#
# Real-world reference points (./grains_slice.py --analyze):
#   src_peak median  0.008 exhale | 0.022 inhale | 0.274 M=0
#   centroid median  3884 exhale | 2201 inhale | 2387 M=0  (Hz)
#
# WITH BOTH EMPTY nothing gets filtered — an empty whitelist = everything passes.
# Behavior stays as-is until you add the first criterion.
KEEP = {
    "require": {
        "min_src_peak": None,
        "max_clip_pct": None,
        "min_rms": None,
        "max_rms": None,
        "min_centroid": None,
        "max_centroid": None,
        "min_flatness": None,
        "max_flatness": None,
    },
    "match_any": {
        # "attack": 80,     # in the top 20% for ai_attack
        # "breath": 70,
    },
}

# More specific whitelist. The key can be:
#   - a CATEGORY            "inhale", "exhale", "sonic_blast_m0"
#   - a SUB-FOLDER           "EXP_SHATTER fascicule si raze"  (or the relative path)
# The sub-folder beats the category, the category beats the global default. That
# way you can ask for something different from "attack and localization" than
# from "body and density", even though both end up in inhale/.
# Each sub-folder demands its own character, and the threshold is calibrated
# against the real distribution so the zones come out comparable in number.
# Without this, shatter alone would be 47% of everything (19451 grains versus
# 1221 for M=0).
#
# Grains kept at each threshold (measured PER GRAIN, not per window —
# grains pile up where there are attacks, so quiet windows shouldn't
# carry the same weight):
#
# Threshold    50    60    70    80    85    90        out of available
# high       3314  2731  2293  1788  1479  1062        5337
# mid        4320  4066  3711  3420  3222  2723        4641
# low_press  4331  3226  2377  1699  1301   859       10368
# shatter   16421 14503 11417  8049  6212  4321       19433
# n5_n6_n7   1204  1168  1074   749   616   332        1209
ZONE_KEEP = {
    # attack and localization -> clear transients, shards
    "INSP_HIGH localizare si atac": {
        "match_any": {"shards": 67, "onset": 67},          # ~2400 grains
    },
    # body and density -> mass, fullness.
    # The threshold is high because almost the whole folder matches: at 50,
    # 4320 of 4641 would pass. Here the threshold selects, not just filters.
    # leviathan has a real affinity here (z+0.46), not in M=0 (z+0.01) —
    # the hall's breathing mass lives in body/density, not the tunnel.
    # Set higher than the other two so the folder stays balanced:
    # thick|resonant alone give 2330; leviathan at 94 adds 325, at 98 gives 100.
    "IMSP_MID corp si densitate": {
        "match_any": {"thick": 94, "resonant": 94, "leviathan": 98},
    },
    # release and drone -> pressure, air, space between events
    "EXP_LOW PRESSURE eliberare si drone": {
        "match_any": {"whistle": 69, "sparse": 69},        # ~2400
    },
    # shards and rays -> the richest folder (19433), so the strictest
    "EXP_SHATTER fascicule si raze": {
        "match_any": {"shatter": 94, "metallic": 94},      # ~2500
    },
    # M=0 = SONIC BLAST, the tunnel between zones. Not gentle material: we
    # select the explosions. This is the rarest material (1209), hence the
    # permissive threshold. The explosion + the funnel pulling down toward
    # the ground.
    # Note: M=0 dominates the corpus for these prompts, and match_any is OR —
    # with 8 prompts, even a threshold of 95 lets 93% through. Since the
    # percentile is over the WHOLE corpus, it can't select WITHIN the folder;
    # 97 only cuts the least characteristic 13%.
    # surge / shockwave / tectonic were removed: they had 0 "sole" matches,
    # meaning no grain depended on them alone. leviathan took their place.
    "M=0 n5-n6-n7": {
        "match_any": {
            "blast": 97,                                     # the explosion
            "suction": 97, "spiral": 97, "vortex": 97,       # the funnel
            "funnel": 97,
        },
    },
}

# ==============================================================================
# DSP FUNCTIONS
# ==============================================================================
def butter_bandpass(lowcut, highcut, fs, order=4):
    nyq = 0.5 * fs
    low = lowcut / nyq
    high = highcut / nyq
    b, a = butter(order, [low, high], btype='band')
    return b, a

def apply_filter(data, lowcut, highcut, fs):
    b, a = butter_bandpass(lowcut, highcut, fs)
    return lfilter(b, a, data)

# ==============================================================================
# CLAP SCORES FROM THE PER-SOURCE INDEX
# ==============================================================================
def _clap_key(path):
    """Same identity as in clap_index.py — keep them in sync."""
    st = os.stat(path)
    raw = (f"{os.path.relpath(path, PROJECT_DIR)}|{st.st_mtime_ns}|{st.st_size}"
           f"|{CLAP_WINDOW_S}|{CLAP_HOP_S}|{CLAP_MODEL}")
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def load_prompt_embeddings():
    """(names, matrix) for the prompts, or (None, None) if missing."""
    path = os.path.join(clap_cache_dir(), "prompts.npz")
    if not os.path.exists(path):
        return None, None
    data = np.load(path, allow_pickle=False)
    return [str(n) for n in data["names"]], data["embeddings"]


def load_clap_scores(file_path, prompt_names, prompt_embeddings):
    """Per-window scores for a source: (times, {name: scores}).

    Returns (None, None) if the source isn't indexed — the run continues
    normally, just without ai_* features.
    """
    if prompt_embeddings is None:
        return None, None
    path = os.path.join(clap_cache_dir(), _clap_key(file_path) + ".npz")
    if not os.path.exists(path):
        return None, None

    data = np.load(path, allow_pickle=False)
    # Both sets are normalized, so the dot product = cosine similarity.
    sims = data["embeddings"] @ prompt_embeddings.T
    return data["times"], {n: sims[:, i] for i, n in enumerate(prompt_names)}


def build_score_reference(prompt_names, prompt_embeddings):
    """The score distribution over the WHOLE corpus, for converting to percentiles.

    Computed from the windows already in cache, not from grains: it's instant
    and doesn't depend on the random cut. Without this, `match_any` would have
    nothing to compare against at runtime.
    """
    if prompt_embeddings is None:
        return None
    columns = {name: [] for name in prompt_names}
    for path in glob.glob(os.path.join(clap_cache_dir(), "*.npz")):
        if os.path.basename(path) == "prompts.npz":
            continue
        data = np.load(path, allow_pickle=False)
        sims = data["embeddings"] @ prompt_embeddings.T
        for i, name in enumerate(prompt_names):
            columns[name].append(sims[:, i])
    if not any(columns.values()):
        return None
    return {name: np.sort(np.concatenate(cols))
            for name, cols in columns.items() if cols}


def score_percentile(reference, name, value):
    """Where a raw score falls in the corpus distribution (0–100)."""
    sorted_values = reference.get(name)
    if sorted_values is None or not len(sorted_values):
        return None
    return 100.0 * np.searchsorted(sorted_values, value) / len(sorted_values)


def clap_scores_at(offset_s, times, scores, reference=None):
    """Scores of the window closest to a given moment in the source."""
    idx = int(np.argmin(np.abs(times - offset_s)))
    out = {}
    for name, values in scores.items():
        raw = float(values[idx])
        out[f"ai_{name}"] = raw
        if reference is not None:
            pct = score_percentile(reference, name, raw)
            if pct is not None:
                out[f"ai_{name}_pct"] = float(pct)
    return out


def add_percentile_features(features_by_category):
    """Adds `ai_<name>_pct` — the corpus percentile, comparable across prompts.

    Raw CLAP similarities aren't comparable from one prompt to another;
    percentiles are.
    """
    everything = [f for feats in features_by_category.values() for f in feats]
    if not everything:
        return

    # The index can be partial: grains from unindexed sources have no ai_* keys.
    # The percentile is computed only over the ones that do.
    ai_keys = sorted({k for f in everything for k in f
                      if k.startswith("ai_") and not k.endswith("_pct")})
    for key in ai_keys:
        having = [f for f in everything if key in f]
        values = np.array([f[key] for f in having])
        order = values.argsort().argsort()
        pct = 100.0 * order / max(len(values) - 1, 1)
        for f, p in zip(having, pct):
            f[key + "_pct"] = float(p)


# ==============================================================================
# GRAIN ANALYSIS
# ==============================================================================
FEATURE_NAMES = ("src_peak", "clip_pct", "rms", "centroid", "flatness")


def granule_features(granule, src_peak, fs):
    """Feature vector of a grain (already normalized to peak 1.0)."""
    magnitudes = np.abs(np.fft.rfft(granule))
    frequencies = np.fft.rfftfreq(len(granule), 1.0 / fs)

    sum_mag = np.sum(magnitudes)
    centroid = float(np.sum(magnitudes * frequencies) / sum_mag) if sum_mag > 0 else 0.0

    # Spectral flatness = geometric mean / arithmetic mean of the power.
    power = magnitudes ** 2 + 1e-20
    flatness = float(np.exp(np.mean(np.log(power))) / np.mean(power))

    # The grain arrives already normalized to peak 1.0, so clipping is
    # measured on the signal reconstructed at the source scale (grain * src_peak).
    return {
        "src_peak": float(src_peak),
        "clip_pct": float(np.mean(np.abs(granule) * src_peak >= 0.99) * 100.0),
        "rms": float(np.sqrt(np.mean(granule ** 2))),
        "centroid": centroid,
        "flatness": flatness,
    }


def whitelist_for(category, keys=()):
    """The effective whitelist, from general to specific.

    Layers: global KEEP -> ZONE_KEEP[category] -> ZONE_KEEP[folder].
    `require` is merged key by key; `match_any` is fully replaced
    by the most specific layer that defines it.
    """
    layers = [KEEP, ZONE_KEEP.get(category, {})]
    for key in keys:                       # the folder beats the category
        if key in ZONE_KEEP:
            layers.append(ZONE_KEEP[key])

    require = {}
    match_any = KEEP.get("match_any", {})
    for layer in layers:
        require.update(layer.get("require", {}))
        if "match_any" in layer:
            match_any = layer["match_any"]
    return require, match_any


def active_criteria():
    """The criteria actually in effect, in any layer (non-None thresholds)."""
    req, match = set(), set()
    for layer in [KEEP] + list(ZONE_KEEP.values()):
        req |= {k for k, v in layer.get("require", {}).items() if v is not None}
        match |= {k for k, v in layer.get("match_any", {}).items()
                  if v is not None}
    return req, match


def keep_reason(features, category, keys=()):
    """(keep?, reason). Whitelist: discarded by default, must qualify.

    The reason is the name of the failed criterion, so it shows up in the
    statistics.
    """
    require, match_any = whitelist_for(category, keys)

    # 1. Mandatory gates — all must pass.
    for key, feature in (("min_src_peak", "src_peak"), ("min_rms", "rms"),
                         ("min_centroid", "centroid"), ("min_flatness", "flatness")):
        limit = require.get(key)
        if limit is not None and features.get(feature, float("inf")) < limit:
            return False, key, []

    for key, feature in (("max_clip_pct", "clip_pct"), ("max_rms", "rms"),
                         ("max_centroid", "centroid"), ("max_flatness", "flatness")):
        limit = require.get(key)
        if limit is not None and features.get(feature, float("-inf")) > limit:
            return False, key, []

    # 2. Semantic match — matching one is enough, but we collect them all
    #    so we know in the end which prompt actually pulls weight and which is decorative.
    wanted = {k: v for k, v in match_any.items() if v is not None}
    if wanted:
        matched = [name for name, min_pct in wanted.items()
                   if features.get(f"ai_{name}_pct", -1) >= min_pct]
        if matched:
            return True, None, matched
        # No match — but if the scores are missing, we can't judge.
        if not any(f"ai_{n}_pct" in features for n in wanted):
            return True, None, []
        return False, "no_prompt_match", []

    return True, None, []

# ==============================================================================
# PROCESSING PIPELINE — CATEGORY COMES FROM THE SOURCE FOLDER
# ==============================================================================
def process_wav(file_path, category, analyze_only=False,
                prompt_names=None, prompt_embeddings=None, reference=None):
    """Extracts the grains, analyzes them, and writes out the ones kept.

    Energy is used only to find onsets (onset detection), never to label:
    a blast buried inside an EXHALE file stays in exhale/.
    """
    fs, data = wavfile.read(file_path)
    
    if len(data.shape) > 1:
        data = np.mean(data, axis=1)
    if data.dtype != np.float32:
        data = data.astype(np.float32) / np.max(np.abs(data))

    filtered_data = apply_filter(data, LOW_CUT, HIGH_CUT, fs)
    
    window_samples = int((WINDOW_MS / 1000.0) * fs)
    hop_samples = window_samples // 2
    
    energy = np.array([np.sum(filtered_data[i:i+window_samples]**2) for i in range(0, len(filtered_data)-window_samples, hop_samples)])
    threshold = np.mean(energy) * THRESHOLD_MULTIPLIER
    
    base_name = os.path.splitext(os.path.basename(file_path))[0]

    extracted_granules = []

    i = 0
    while i < len(filtered_data) - int((MAX_GRANULE_MS/1000.0)*fs):
        current_energy = np.sum(filtered_data[i:i+window_samples]**2)
        
        if current_energy > threshold:
            random_duration_ms = random.uniform(MIN_GRANULE_MS, MAX_GRANULE_MS)
            granule_length_samples = int((random_duration_ms / 1000.0) * fs)
            
            granule = filtered_data[i : i + granule_length_samples].copy()
            
            # Gating & Fade-Out
            fade_samples = int((FADE_OUT_MS / 1000.0) * fs)
            if len(granule) > fade_samples:
                fade_window = np.ones(len(granule))
                fade_window[-fade_samples:] = np.linspace(1.0, 0.0, fade_samples)
                granule *= fade_window
            
            # The peak before normalization is the only trace of the real
            # source level — the normalization below erases it for good.
            max_val = np.max(np.abs(granule))
            if max_val > 0:
                granule = granule / max_val

            # `i` = position in the source; it's the key the grain uses to
            # look up its CLAP scores from the time index.
            extracted_granules.append((granule, max_val, i / float(fs)))

            i += granule_length_samples + int(random.uniform(10, 50) * (fs / 1000.0))
        else:
            i += hop_samples

    if not extracted_granules:
        print(f"     [{base_name}] no onset above threshold")
        return [], {}, [], {}, {}

    # --- ANALYSIS AND REJECTION ---
    times, scores = load_clap_scores(file_path, prompt_names, prompt_embeddings)
    keys = folder_keys(file_path)

    kept = []
    rejected = {}
    all_features = []
    matches = {}      # prompt -> how many kept grains it hit
    solo = {}         # prompt -> how many it saved on its own
    for granule, src_peak, offset_s in extracted_granules:
        features = granule_features(granule, src_peak, fs)
        if times is not None:
            features.update(clap_scores_at(offset_s, times, scores, reference))
        all_features.append(features)

        keep, reason, matched = keep_reason(features, category, keys)
        if not keep:
            rejected[reason] = rejected.get(reason, 0) + 1
            continue
        for name in matched:
            matches[name] = matches.get(name, 0) + 1
        # A prompt "standing alone": without it the grain would've been lost.
        if len(matched) == 1:
            solo[matched[0]] = solo.get(matched[0], 0) + 1
        kept.append(granule)

    if analyze_only:
        print(f"     [{base_name}] {len(extracted_granules)} extracted, "
              f"{len(kept)} would pass, {len(extracted_granules) - len(kept)} rejected")
        return ([len(g) / fs * 1000.0 for g in kept], rejected,
            all_features, matches, solo)

    # Physical save — category from the zone, subfolder from the source folder
    slug = subfolder_slug(file_path)
    cat_folder = os.path.join(OUTPUT_FOLDER, category, slug)
    os.makedirs(cat_folder, exist_ok=True)
    for idx, granule in enumerate(kept):
        out_filename = f"{base_name}_{category}_{idx:03d}.wav"
        out_path = os.path.join(cat_folder, out_filename)
        wavfile.write(out_path, fs, (granule * 32767).astype(np.int16))

    num_rejected = len(extracted_granules) - len(kept)
    suffix = f"  ({num_rejected} rejected)" if num_rejected else ""
    print(f"     [{base_name}] {len(kept)} grains -> "
          f"{category}/{slug}/{suffix}")
    return ([len(g) / fs * 1000.0 for g in kept], rejected,
            all_features, matches, solo)

def collect_input_wavs():
    """Recursively scans the zone folders, ignoring AppleDouble files (._*).

    Returns (path, category) pairs, with category inherited from the zone.
    """
    found = []
    for zone, category in ZONE_CATEGORIES.items():
        zone_path = os.path.join(SOURCE_ROOT, zone)
        if not os.path.isdir(zone_path):
            print(f"  ! Folder missing, skipping: {zone}")
            continue
        pattern = os.path.join(zone_path, "**", "*.wav")
        for path in glob.glob(pattern, recursive=True):
            if os.path.basename(path).startswith("._"):
                continue
            found.append((path, category))
    return sorted(found)


def reset_output_folder():
    """Deletes ONLY the subfolders this script creates.

    That is, exactly the categories in ZONE_CATEGORIES. Whatever else writes
    into the same output — e.g. atmos/, written by atmos_slice.py — stays
    untouched. Each script only cleans up what it produces.
    """
    os.makedirs(OUTPUT_FOLDER, exist_ok=True)
    categories = sorted(set(ZONE_CATEGORIES.values()))

    removed = 0
    for category in categories:
        target = os.path.join(OUTPUT_FOLDER, category)
        # Safety net: the target must be exactly a direct child of the output.
        if os.path.dirname(os.path.abspath(target)) != os.path.abspath(OUTPUT_FOLDER):
            raise SystemExit(f"Refusing to delete an unexpected path: {target}")
        if os.path.isdir(target):
            removed += sum(len(files) for _, _, files in os.walk(target))
            shutil.rmtree(target)

    if removed:
        print(f"Deleted {removed} files from: {', '.join(categories)}")

    # Subfolders get created as sources appear — see process_wav.


def fmt_duration(seconds):
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60:02d}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60:02d}m {seconds % 60:02d}s"


def fmt_size(num_bytes):
    for unit in ("B", "KB", "MB", "GB"):
        if num_bytes < 1024 or unit == "GB":
            return f"{num_bytes:.0f} {unit}" if unit == "B" else f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024.0


def folder_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            total += os.path.getsize(os.path.join(root, name))
    return total


def print_feature_distribution(features_by_category):
    """Percentiles for every feature — the basis for choosing thresholds."""
    line = "=" * 78
    print(f"\n{line}\n ANALYSIS — FEATURE DISTRIBUTION (nothing written)\n{line}")

    for category in sorted(features_by_category):
        features = features_by_category[category]
        if not features:
            continue
        ai_keys = sorted({k for f in features for k in f
                          if k.startswith("ai_") and not k.endswith("_pct")})
        print(f"\n {category}  ({len(features)} granule)")
        print(f"   {'feature':<16}{'min':>9}{'p05':>9}{'p25':>9}"
              f"{'median':>9}{'p75':>9}{'p95':>9}{'max':>9}{'':>4}")
        print("   " + "-" * 76)
        for name in tuple(FEATURE_NAMES) + tuple(ai_keys):
            values = np.array([f[name] for f in features if name in f])
            if not len(values):
                continue
            p = np.percentile(values, [0, 5, 25, 50, 75, 95, 100])
            fmt = "{:>9.0f}" if name == "centroid" else "{:>9.3f}"
            # Mark partial coverage: the CLAP index may be missing for some sources.
            cover = "" if len(values) == len(features) \
                else f"  {100.0*len(values)/len(features):.0f}%"
            print(f"   {name:<16}" + "".join(fmt.format(v) for v in p) + cover)

    print(f"\n{line}")
    print(" Put the criteria into KEEP / ZONE_KEEP, then run without --analyze.")
    print(" Thresholds in match_any are percentiles: 80 = the top 20% of the corpus.")
    print(line)


def print_statistics(per_category, per_zone, num_files, num_errors, elapsed,
                     rejected_by_category=None, prompt_stats=None):
    line = "=" * 66
    print(f"\n{line}\n STATISTICS\n{line}")

    print(f" Source files processed  : {num_files}"
          + (f"   ({num_errors} errors)" if num_errors else ""))
    print(f" Processing time         : {fmt_duration(elapsed)}")

    total_granules = sum(len(v) for v in per_category.values())
    if not total_granules:
        print("\n No grains generated.")
        return

    print(f"\n {'CATEGORY':<17}{'GRAINS':>9}{'AUDIO':>11}"
          f"{'AVG':>9}{'MIN':>8}{'MAX':>8}{'SHARE':>8}")
    print(" " + "-" * 64)
    for category in sorted(per_category, key=lambda c: -len(per_category[c])):
        durations = per_category[category]
        if not durations:
            continue
        total_ms = sum(durations)
        print(f" {category:<17}{len(durations):>9}"
              f"{fmt_duration(total_ms / 1000.0):>11}"
              f"{total_ms / len(durations):>7.0f}ms"
              f"{min(durations):>6.0f}ms{max(durations):>6.0f}ms"
              f"{100.0 * len(durations) / total_granules:>7.1f}%")

    all_durations = [d for v in per_category.values() for d in v]
    print(" " + "-" * 64)
    print(f" {'TOTAL':<17}{total_granules:>9}"
          f"{fmt_duration(sum(all_durations) / 1000.0):>11}")

    print("\n BY SOURCE FOLDER:")
    for zone in sorted(per_zone, key=lambda z: -per_zone[z]):
        count = per_zone[zone]
        print(f"   {zone:<48}{count:>7}{100.0 * count / total_granules:>7.1f}%")

    req_active, match_active = active_criteria()

    if not req_active and not match_active:
        print("\n WHITELIST: empty — no criteria, all grains kept.")
        print("   (analysis runs anyway; see ./grains_slice.py --analyze)")
    else:
        total_rejected = sum(sum(r.values()) for r in rejected_by_category.values())
        extracted = total_granules + total_rejected
        print(f"\n WHITELIST: {total_granules} kept out of {extracted} extracted"
              f"  ({100.0 * total_granules / extracted:.1f}% qualified)")

        by_reason = {}
        for reasons in rejected_by_category.values():
            for reason, count in reasons.items():
                by_reason[reason] = by_reason.get(reason, 0) + count
        for reason in sorted(by_reason, key=lambda r: -by_reason[r]):
            count = by_reason[reason]
            label = ("no semantic match" if reason == "no_prompt_match"
                     else f"failed {reason}")
            print(f"   {label:<32}{count:>8}"
                  f"{100.0 * count / extracted:>7.1f}%")

    if prompt_stats:
        matches_by_slug, solo_by_slug, kept_by_slug, thresholds = prompt_stats
        print("\n MATCHES PER PROMPT"
              "  (match_any is OR — a grain can hit more than one)")
        print(f"   {'prompt':<26}{'threshold':>6}{'matches':>11}"
              f"{'% kept':>12}{'alone':>9}")
        print("   " + "-" * 66)
        for slug in sorted(thresholds):
            kept = kept_by_slug.get(slug, 0)
            counts = matches_by_slug.get(slug, {})
            print(f"   {slug}/  ({kept} grains)")
            for name in sorted(thresholds[slug],
                               key=lambda n: -counts.get(n, 0)):
                only = solo_by_slug.get(slug, {}).get(name, 0)
                hits = counts.get(name, 0)
                share = 100.0 * hits / kept if kept else 0.0
                flag = "  <- the only one" if only and only == kept else ""
                print(f"     {name:<24}{thresholds[slug][name]:>6}"
                      f"{hits:>11}{share:>11.1f}%{only:>9}{flag}")

    print(f"\n Output: output_xenakis_installation/  "
          f"({fmt_size(folder_size(OUTPUT_FOLDER))})")
    print(line)


if __name__ == "__main__":
    analyze_only = "--analyze" in sys.argv or "-a" in sys.argv

    if analyze_only:
        print("ANALYZE mode — nothing is written or deleted.\n")
    else:
        reset_output_folder()

    wav_files = collect_input_wavs()
    if not wav_files:
        print(f"No .wav found in: {', '.join(ZONE_CATEGORIES)}")
    else:
        print(f"Found {len(wav_files)} source files.")
        prompt_names, prompt_embeddings = load_prompt_embeddings()
        if prompt_embeddings is None:
            print("CLAP: no index — run ./clap_index.py for ai_* features.\n")
        else:
            indexed = sum(1 for f, _ in wav_files
                          if os.path.exists(os.path.join(clap_cache_dir(),
                                                         _clap_key(f) + ".npz")))
            print(f"CLAP: {len(prompt_names)} prompts, "
                  f"{indexed}/{len(wav_files)} sources indexed.")
        reference = build_score_reference(prompt_names, prompt_embeddings)

        req_active, match_active = active_criteria()
        if not req_active and not match_active:
            print("WHITELIST: empty — nothing is filtered, everything passes.\n")
        else:
            print(f"WHITELIST: require={sorted(req_active) or '-'}  "
                  f"match_any={sorted(match_active) or '-'}")
            if match_active and reference is None:
                print("  ! No CLAP index: match_any can't be evaluated, "
                      "grains pass based on require.")
            print()

        started = time.time()
        categories = set(ZONE_CATEGORIES.values())
        per_category = {c: [] for c in categories}
        rejected_by_category = {c: {} for c in categories}
        features_by_category = {c: [] for c in categories}
        per_zone = {}
        matches_by_slug = {}
        solo_by_slug = {}
        kept_by_slug = {}
        thresholds_by_slug = {}
        num_errors = 0
        last_zone = None

        for f, category in wav_files:
            zone = os.path.relpath(os.path.dirname(f), PROJECT_DIR)
            if zone != last_zone:
                print(f"  -> {zone}  [{category}]")
                last_zone = zone
            try:
                durations, rejected, features, matches, solo = process_wav(
                    f, category, analyze_only, prompt_names, prompt_embeddings,
                    reference)
            except Exception as e:
                print(f"     ! Error, skipping {os.path.basename(f)}: {e}")
                num_errors += 1
                continue
            per_category[category].extend(durations)
            per_zone[zone] = per_zone.get(zone, 0) + len(durations)

            slug = subfolder_slug(f)
            kept_by_slug[slug] = kept_by_slug.get(slug, 0) + len(durations)
            if slug not in thresholds_by_slug:
                _, wanted = whitelist_for(category, folder_keys(f))
                thresholds_by_slug[slug] = {k: v for k, v in wanted.items()
                                            if v is not None}
            for name, count in matches.items():
                matches_by_slug.setdefault(slug, {})
                matches_by_slug[slug][name] = \
                    matches_by_slug[slug].get(name, 0) + count
            for name, count in solo.items():
                solo_by_slug.setdefault(slug, {})
                solo_by_slug[slug][name] = \
                    solo_by_slug[slug].get(name, 0) + count
            for reason, count in rejected.items():
                rejected_by_category[category][reason] = \
                    rejected_by_category[category].get(reason, 0) + count
            if analyze_only:
                features_by_category[category].extend(features)

        if analyze_only:
            add_percentile_features(features_by_category)
            print_feature_distribution(features_by_category)
        else:
            print_statistics(per_category, per_zone, len(wav_files),
                             num_errors, time.time() - started,
                             rejected_by_category,
                             (matches_by_slug, solo_by_slug, kept_by_slug,
                              thresholds_by_slug))

