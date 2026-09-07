# hala-mx — Xenakian Installation, Hala MX

A generative 12-channel sound installation ("breathing" — inhale / M=0 /
exhale), built from an offline pipeline (Python) that slices and renders the
material, plus a live player in Sonic Pi (Ruby) that orchestrates it
spatially in real time.

```
source .wav files (ATMOS/, ADSR_ENVELOPES/)
    │
    ├─ grains_slice.py  ──▶ output_xenakis_installation/{inhale,exhale,sonic_blast_m0}/
    │  (+ clap_index.py)
    │
    ├─ atmos_slice.py   ──▶ output_xenakis_installation/atmos/
    │
    ├─ build_pools.py   ──▶ output_xenakis_installation/concat/   (pooled .wav + .txt)
    │
    └─ render_m0.py     ──▶ output_xenakis_installation/m0_render/

sonic-pi-buffer.rb (config + reloader, workspace)
    └─▶ run_file xenakis.rb (library, main live_loop)
```

All the Python scripts are `uv run --script` — their dependencies are
declared in the header, no separate venv needed: `./grains_slice.py`,
`./atmos_slice.py`, etc. run directly if you have `uv` installed.

## 1. Grain slicer — `grains_slice.py`

Cuts short grains (20–150 ms) from the mono sources in `ADSR_ENVELOPES/`, based on
onset detection (energy above a threshold over a 10 ms window), band-pass
filters them 120–8000 Hz, normalizes each to peak 1.0, and writes them to
`output_xenakis_installation/<category>/<subfolder>/`.

- **Zones → categories** (`ZONE_CATEGORIES`): each root folder under
  `ADSR_ENVELOPES/` strictly inherits one output category —
  `"M=0 n5-n6-n7"` → `sonic_blast_m0`, `"ZONE A INSPIR"` → `inhale`,
  `"ZONE B EXPIR"` → `exhale`. New subfolders are picked up automatically.
- **Inverse whitelist** (`KEEP` / `ZONE_KEEP`): everything is discarded by
  default; a grain has to *qualify* through mandatory technical gates
  (`require`: level floor, clipping, RMS, spectral centroid, flatness)
  and/or a semantic match (`match_any`, thresholded on **percentile** within
  the corpus, not on the raw score).
- **CLAP** (optional, via `clap_index.py`): each source is indexed on a
  grid of 5 s windows (not grain-by-grain — a grain is too short for CLAP),
  comparing embeddings against free-text prompts (`AI_PROMPTS`, e.g.
  `"a single sharp transient with a clear sudden onset"`). A grain inherits
  the score of the window it was cut from.

```
./clap_index.py              # build the CLAP index (slow, once)
./clap_index.py --prompts    # only re-encode the prompts (seconds)
./clap_index.py --status     # what's indexed

./grains_slice.py --analyze         # reports the feature distribution, writes nothing
./grains_slice.py                   # slices + filters, writes to output_xenakis_installation/
```

`--analyze` is the calibration step: it shows the real percentiles (min/p05/
p25/median/p75/p95/max) for every feature and every `ai_*_pct`, so the
thresholds in `KEEP`/`ZONE_KEEP` are chosen from data, not intuition.

## 2. ATMOS slicer — `atmos_slice.py`

A separate chain, for the stereo atmospheric bed in `ATMOS/` (Inhale/Exhale/
M0, Doppler A/B pairs) — no granulation, no CLAP, no whitelist. Sources stay
stereo (the Doppler spatial information is the whole point here).

```
read 96k stereo
  → BPF 120–8000 Hz              (same filter as the grains)
  → presence bell                (clarity 2–6 kHz, +3 dB @ 3.5 kHz)
  → exciter                      (harmonics synthesized from 200–1200 Hz,
                                   injected back into 2000–6000 Hz — the
                                   material has almost nothing there to boost)
  → normalize per file           (after the boost, so it doesn't clip 0 dBFS)
  → resample 96k → 48k
  → 16 s slices + 250 ms fade    (slices quieter than -60 dBFS are dropped)
  → written 24-bit stereo
```

```
./atmos_slice.py              # run everything
./atmos_slice.py --limit 2    # only the first 2 files (test)
./atmos_slice.py --dry-run    # report only, write nothing
```

Outputs to `output_xenakis_installation/atmos/<zone>/<folder>/`, grouped
into the 6 families that `xenakis.rb` loads (`inh_a`, `inh_b`, `exh_a`,
`exh_b`, `m0_up`, `m0_pz`).

## 3. Pools + M=0 rendering (intermediate steps, before Sonic Pi)

- **`build_pools.py`** — concatenates each grain family (`inhale_high`,
  `inhale_mid`, `exhale_low_pressure`, `exhale_shatter`, `blast`) into a
  single `.wav` plus a `.txt` of offsets (`start_frac finish_frac
  duration_ms`). Why: Sonic Pi allocates one scsynth buffer per file and
  never frees it — with ~10,000 individual files, preloading would mean
  thousands of OSC allocations. Concatenated, all the material fits in 5
  buffers, and a grain is picked with `start:`/`finish:`, exactly how
  `onset:` works internally.
- **`render_m0.py`** — pre-renders the M=0 burst offline (the stochastic
  rain at the inhale/exhale transition): ~144 grains in 0.45 s across 8
  channels overran the Sonic Pi scheduler (TimingError). Rendered offline
  (`NVAR` variants × 4 channels × 2 layers `ceil`/`floor`), it becomes 8
  files triggered directly. Only the dry grain layer is rendered — the FX
  chains (hpf/flanger for the ceiling, lpf/distortion for the floor, tanh
  throughout) stay live in Sonic Pi.

```
python3 build_pools.py
python3 render_m0.py
```

Full pipeline run, in order:

```
./clap_index.py        # once, or whenever new sources are added
./grains_slice.py
./atmos_slice.py
python3 build_pools.py
python3 render_m0.py
```

## 4. The Sonic Pi code — `xenakis.rb`

The library (not edited for day-to-day tuning — see §5). A main
`live_loop` renders a 16 s "breathing" cycle across 12 physical monitors,
arranged in two horizontal hexagons at Z = 1.8 m (`monitors.tsv`): zone 1
= inhale (channels 1–6), zone 2 = exhale (channels 7–12). The verticality
of the 11 theoretical nodes (`nodes.tsv`, Z between 2.5–4.0 m) is entirely
psychoacoustic — Blauert directional cues (~7–10 kHz boosted = above,
~3 kHz boosted = behind/below) — there is no speaker actually overhead.

Structure of one cycle:

1. **Atmosphere** — a continuous bed (`atmos/`) across all 12 channels,
   with `attack`/`release` equal to the cycle margin so it fades in before
   and out after the granular material; a rotating set (not the whole
   corpus — 434 files / 1.9 GB won't fit in memory at once) is preloaded
   one cycle ahead by `live_loop :atmos_loader` and freed with
   `sample_free` so it doesn't hit the scsynth 4096-buffer limit.
2. **Inhale** — stochastic clouds (a Poisson process, `play_cloud_phase`)
   that descend and darken, panned continuously (not across discrete
   channels) at constant power.
3. **M=0** — the critical point: a psychoacoustic "scalpel" above (HPF cut,
   flanger, 8 kHz Blauert accent) and a "funnel" below (LPF, distortion),
   offset by 35 ms (Haas effect), riding on the burst pre-rendered by
   `render_m0.py`.
4. **Exhale** — mirrored stochastic clouds, rising and opening toward a
   shatter.

Runtime parameters (rig, focus, amplitudes, studio bleep) are read from
**Time State** (`get :xen_*`) at the start of every breath — they can be
changed on the fly, without Stop/Run — and are set from the configuration
workspace, not edited here directly.

## 5. The reloader — `sonic-pi-buffer.rb`

The only workspace that gets edited during a session/installation. It sets
the live parameters (output rig, focus, master amplitude, studio bleep,
seed) via `set`, then contains `live_loop :reloader`, which:

- checks `File.mtime` on `xenakis.rb` every 0.5 s and, if it changed, does
  `run_file` on the library — so you edit `xenakis.rb` in an external
  editor and the changes land in Sonic Pi without a manual Stop/Run;
- runs with `use_sched_ahead_time 60`: preloading the library (over 1500
  files, allocations serialized on a single mutex) keeps the Ruby process
  busy for a few seconds, and with the default tolerance Sonic Pi would
  kill the loop with `TimingError` right in the middle of loading;
- keeps `last_mtime` as a local variable (not in Time State), so that every
  `Run` reloads the library for certain, even though Time State survives
  `Stop`.

```ruby
set :xen_rig_outputs, 4    # 12 = Hala MX, 4 = UMC404HD in the studio
set :xen_focus, :inhale    # :inhale :exhale :m0 :m0_ceil :m0_floor :all
set :xen_master_amp, 1.0
set :xen_bleep, true       # studio reference bleep at cycle boundaries (off in the hall)
set :xen_seed, 0           # changing this needs Stop + Run
```

Run: open `sonic-pi-buffer.rb` as a workspace in Sonic Pi and hit **Run**.
`xenakis.rb` is never run directly.

## Layout

```
ADSR_ENVELOPES/                    mono sources for grains_slice.py
ATMOS/                              stereo sources for atmos_slice.py
output_xenakis_installation/       generated, not checked into git
  inhale/ exhale/ sonic_blast_m0/   output of grains_slice.py
  atmos/                            output of atmos_slice.py
  concat/                           output of build_pools.py (pools + cut tables)
  m0_render/                        output of render_m0.py
monitors.tsv                       physical positions of the 12 monitors (cm)
nodes.tsv                          theoretical breathing path, 11 nodes
TODO.md                            open tuning items
```
