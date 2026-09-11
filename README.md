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

## Prerequisites

- **`uv`** — all the Python scripts are `uv run --script`, dependencies
  declared in their headers, no venv needed.
- **Sonic Pi 4.6.0, built from source** — *not* 5.0. 5.0's rate-skew watchdog
  destroys the running job on a 5% device dip; see §7a for the measurements.
  Build with `./session-scripts/build-sonicpi-46.sh`.
- **Launch with `./session-scripts/start-46.sh <mode>`**, not the binary
  directly, and **the mode is required** — `--production` for Hala MX (12
  outputs, bleep off) or `--simulation` for the studio (4 outputs on the
  UMC404HD, bleep on). It sets `SC_JACK_DEFAULT_OUTPUTS` so all outputs land on
  the interface rather than the built-in speakers (§7d), writes the venue's rig
  and bleep into Buffer 0, and sets `num_outputs` in `audio-settings.toml` to
  match. There is no default mode on purpose: both differences are silent when
  wrong, and a bleep in front of an audience is not recoverable.
- **The desk is not in Sonic Pi**, and `start-46.sh` installs it for you.
  Sonic Pi's workspaces are its own storage — plain text at
  `~/.sonic-pi/store/default/workspace_<n>.spi`, Buffer 0 being `zero` — and it
  **autosaves** them while running, so what comes back next session is whatever
  you last edited in the GUI, not `sonic-pi-buffer.rb`. The two drift apart
  silently and have: the repo copy was once four settings behind a desk that had
  been live for days. `start-46.sh` copies `sonic-pi-buffer.rb` into Buffer 0
  before launching, prints any settings that change, and backs the outgoing
  buffer up under `~/.sonic-pi/workspace-backups/` (Sonic Pi also keeps a git
  history of every autosave in `~/.sonic-pi/store/default/.git`). Use
  `./start-46.sh <mode> --keep` to launch with whatever Buffer 0 already had.
  Only `xenakis.rb` is read from disk, by `run_file`.

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

The library (not edited for day-to-day tuning — see §6). A main
`live_loop` renders a 16 s "breathing" cycle across 12 physical monitors,
arranged in two horizontal hexagons at Z = 1.8 m (`monitors.tsv`): zone 1
= inhale (channels 1–6), zone 2 = exhale (channels 7–12). The verticality
of the 11 theoretical nodes (`nodes.tsv`, Z between 2.5–4.0 m) is entirely
psychoacoustic — Blauert directional cues (~7–10 kHz boosted = above,
~3 kHz boosted = behind/below) — there is no speaker actually overhead.

Structure of one cycle:

1. **Atmosphere** — a continuous bed (`atmos/`) across all 12 channels
   (on a smaller rig the twelve vertices wrap modulo the outputs available
   and are deduplicated — on 4 outputs the two decorrelated `a` beds land on
   1,3 and the `b` beds on 2,4; level across rig sizes and the resonant
   partials it carries are both §5),
   with `attack`/`release` equal to the cycle margin so it fades in before
   and out after the granular material; a rotating set (not the whole
   corpus — 434 files / 1.9 GB won't fit in memory at once) is preloaded
   one cycle ahead by `live_loop :atmos_loader` and freed with
   `sample_free` so it doesn't hit the scsynth 4096-buffer limit — both
   staggered, not batched, for the reason below.
2. **Inhale** — stochastic clouds (a Poisson process, `play_cloud_phase`)
   that descend and darken, panned at constant power either continuously
   between neighbouring channels or discretely onto one (`xen_pan_mode`, §5),
   and carrying the breath's **slope** as a ramped Blauert band pair (§5).
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


### Lookahead, and why `Stop` is dangerous

`use_sched_ahead_time 1.0` at the top of the library — it was 2.0. Lookahead
is not only a timing tolerance: it is also **how many grain triggers sit
queued inside scsynth at any moment**, and that is what makes `Stop` a hazard
rather than a no-op.

On `Stop` the group dies first. Every already-queued `/s_new` then fails with
`Group N not found`, so those nodes never receive an `/n_go` and stay in the
group's `@pending_nodes` forever. `Group#initialize` (`group.rb:26`) registers
an `on_destroyed` callback that emits one synthetic `/n_end` per pending node
— and it runs **on Sonic Pi's event-consumer thread**, pushing into the same
50-slot `SizedQueue` that that thread is the only consumer of
(`incomingevents.rb:23`). Enough pending nodes and the consumer blocks on its
own queue for good: the scsynth reader stops being drained, `Node`/`Group`
creation blocks, and no later `Run` can start a live_loop — silent, no error,
until Sonic Pi is restarted.

At 2.0 that was ~76 grains/s × 2 s ≈ **150 stranded nodes per `Stop`**. 1.0
halves it. The original reason for a large value is gone anyway: the M=0 rain
that could not be queued at 0.5 s is pre-rendered now — 8 triggers, not ~144.

This is the same family of silent failure as the `run_tag` collision (§6), and
the two compound: a `Stop` that strands nodes and a `Run` that collides on a
still-held loop name both end in a piece that evaluates cleanly and makes no
sound. If that happens, restart Sonic Pi — nothing at the workspace level
recovers it.

Three different values are in play deliberately, so all three are correct:
the library's 1.0 above, the breath loop's own `get(:xen_sched_ahead, …)`, and
2.0 in the two administrative loops (§6).

The breath loop's is the one worth tuning, and **the desk sets it to 3.0**.
M=0 fires 16 threads inside 35 ms — the atmosphere accent (2 files × 4
`quad_ceil` channels), the ceiling scalpel (4) and the floor funnel (4) — each
building an FX chain and triggering a sample. Against the 0.5 s default that
measured as LATE spikes of 1041.9 / 1192.2 / 1116.8 ms across three separate
runs, always with the event count jumping by exactly 16. 3.0 takes them to
4 ms.

It is not free, and on 4.6 the trade is different from what it was on 5.0.
There, raising it made the piece **die sooner** (§7a) and the fix turned out to
be `xen_density`. Here the watchdog is gone, so what 3.0 costs is queue depth:
~6× more timestamped bundles parked in scsynth, and roughly 228 stranded nodes
per `Stop` rather than 76. Spikes versus `Stop` safety — not spikes versus the
run ending.

> `use_sched_ahead_time`, **not** `set_sched_ahead_time!` — the `!` variant
> writes to global state that reads back as `nil`. The variant without `!`
> sets a thread-local, which is checked first and can never be nil, and system
> thread-locals are inherited, so the live_loop and all of its per-channel
> threads pick it up automatically.

### The atmosphere loader is staggered

`live_loop :atmos_loader` prepares the next cycle's set and frees the set from
*two* cycles ago — not the previous one, which might still be sounding on its
tail. It used to fire all six `load_sample` calls back to back and then
`sample_free` the whole outgoing set in one go.

Six 16 s stereo files is **~37 MB of `/b_allocRead` landing on scsynth inside
200 ms**, on top of a cycle that is already sounding, and the device did not
survive it. Measured twice:

| atmos load burst | `audioDeviceStopped` |
|---|---|
| 14:46:51 | 14:47:09 |
| 14:53:05 | 14:53:22 |

The trivial device test, which loads nothing, ran for five minutes on the same
machine without a single stop. So this is a **load burst**, not DSP load and
not the watchdog — and unlike §7a's watchdog it is still a live hazard on 4.6.

The work is now spread across three of the four spare seconds. `stagger` is
computed from the actual number of operations, so the loop still consumes
**exactly `cycle_dur`** in total — it has to stay in phase with the breath, or
the set would switch underneath a cycle that is still playing it:

```ruby
n_ops   = upcoming.size + (to_free ? to_free.size : 0)
stagger = 3.0 / n_ops

upcoming.each_value { |f| load_sample f; sleep stagger }
...
to_free.to_h.values.each { |f| sample_free f; sleep stagger } if to_free
sleep 1.0                    # 3.0 spent staggering + 1.0 = the 4.0 above
```

Frees are staggered for the same reason and stay **after** the loads: the set
being freed is two cycles old, so nothing is still sounding it.

> The local is called **`stagger`, not `spread`** — `spread()` is a Sonic Pi
> built-in (the Euclidean rhythm generator), and a local of that name shadows
> it.


## 5. The psychoacoustic layer — level, height, spectrum

Everything vertical in this piece is a fiction, and most of its balance is
too. There is no speaker overhead — all twelve monitors sit at Z = 1.8 m
(`monitors.tsv`) — and the two layers reach the hardware through separate
`sound_out` chains that bypass the master limiter, so nothing downstream
fixes a mix. Height, and the relationship between the layers, has to be
constructed. This section is what that construction is and why each number
in it is the number it is.

Five things live here: the bed's level across rig sizes, the dynamics both
layers pass through, the breath's slope, the width of the Blauert bands that
carry it, and the spectrum of the atmosphere itself.

### Bed level across rig sizes

The beds and the clouds had **opposite** normalizations when folded onto
fewer than 12 outputs, and the mismatch was audible only in the studio.

`play_cloud_phase` keeps every grain when the spatial drawing compresses, so
the clouds' total radiated power is rig-independent and only the per-channel
density rises (the inhale spans positions 1–6, so ×1.5 at 4 outputs). The
beds did the reverse: each was divided by `sqrt(beds sharing that speaker)`,
holding every *speaker* at the level the material was measured at. At 4
outputs the twelve bed slots fold to eight and each was cut 3 dB, so the bed
radiated **4/12 of the hall's power** into the room while the granular
material radiated all of it — 4.8 dB of balance shift that exists only on the
reduced rig. That is also why raising `xen_atmos_amp` in the studio never
bought what it said it did.

It now normalizes on bed **slots**, referenced to the 12-output hall:

```ruby
bed_slots = atmos_beds.values.flatten.size
bed_scale = Math.sqrt(12.0 / bed_slots)
```

Total bed power is now 12 (the hall's) at every rig size, and **12 outputs is
untouched** — `bed_slots` is 12, the scale is exactly 1.0, one bed per
channel. At 4 outputs the eight surviving slots each come up sqrt(12/8) =
+1.8 dB which, with the 1/√2 gone, puts the bed +4.8 dB where you're sitting.
`xen_atmos_amp` is now honest on any rig: the same number is the same balance
in the studio and in the hall.

The trade is per-channel: at 4 outputs the beds now carry 3× the hall's power
per speaker. Each chain's `tanh` catches its own pileup, but beds and grains
sum *after* both tanhs, so if the sum spits in the studio that's
`xen_master_amp`, not `xen_atmos_amp`. The compensation is deliberately
**not capped** — on a rig below 4 it keeps climbing — because capping it
would silently reintroduce the exact imbalance it exists to fix.

### The enhancer — a dbx 118 in software

A single-band compressor/expander across **the beds and the clouds**, on one
knob: `xen_enhance` runs −1.0 compress … 0.0 unity … +1.0 expand.

Expansion is the side it is normally used on. It pushes quiet material further
*down* so transients regain their impact — it **restores** dynamic range
rather than taming it. Sonic Pi's `:compressor` is SuperCollider's `Compander`,
so `slope_below > 1` is exactly that downward expansion:

```ruby
enh_below = enhance > 0 ? 1.0 + enhance * 0.5 : 1.0
enh_above = enhance < 0 ? 1.0 + enhance * 0.5 : 1.0
```

At 0.0 both slopes are 1.0, which is a mathematical passthrough. **Nothing
here adds gain**, which matters because these outputs bypass the master
limiter: expansion only ever pulls quiet material down (`slope_above` stays
1.0), and compression, on the negative side of the knob, only holds peaks.

The threshold is placed against the material's measured levels:

| | level |
|---|---|
| grains | 0.155–0.345 per event, channel peaks ~0.65 at amp 1.0 |
| atmos beds | 0.5 sustained |
| M=0 bursts | ~0.9 ceiling, ~0.86 floor |

`xen_enhance_threshold` 0.2 therefore sits **inside** the grain range and
**below** everything else: the beds keep their body, and it is the sparse
grains and the tails that get opened up — which is the job the 118 exists to
do. `xen_enhance` +0.4 is `slope_below` 1.2, a 1.2:1 downward expansion:
clearly audible on the clouds, still gentle.

**M=0 is deliberately exempt.** The pivot runs at unity, as rehearsed, and the
inconsistency is not an oversight to be tidied away by patching the enhancer
in everywhere. Both M=0 bursts ramp the tanh's `amp` to zero over `m0_fade`,
placed on the tanh because a saturator flattens any ramp upstream of it — and
an expander sits **downstream** of that ramp. As the ramp carried the tail
under the threshold, it steepened a cross-fade that had been tuned by ear. The
vertical layer is out for the same reason: M=0 is one gesture and it stays
unprocessed.

### The beds turn — `xen_atmos_rotate`

Until this, the atmosphere was **the one thing in the piece with no motion at
all**: `inh_a` sat on channels 1, 3 and 5 at equal level for the whole 16
seconds and stayed there.

Everything else that moves is locked to one clock. Position, pitch, `lpf` and
the Blauert tilt are all monotonic ramps of exactly one traversal per phase —
which is precisely what makes the breath read as a single gesture rather than
four independent ones. Decoupling the *clouds* from that would fragment it.

The beds are different. They are the **ground, not the gesture**, so turning
them underneath costs the breath nothing and gives the Philips Pavilion effect
directly: the architecture rotating while the texture deforms. In the pavilion
the tape moved along "sound routes" across the array on a path independent of
the tape's own evolution — the same decoupling.

**The rotation is constant-power by construction**, which is what makes it
usable at all:

```ruby
th = 2 * Math::PI * (vt / rot_period - ch_i.to_f / n_ch)
g  = [1.0 + rot_depth * Math.cos(th), 0.0].max
control node, amp: bed_amp * Math.sqrt(g)
```

With the channel phases equally spaced by `2π/n`, `Σ cos(θ − 2πi/n) = 0` for
`n ≥ 2`, so `Σ amp²` over the bed's channels is `base²·n` at **every instant**.
Measured ripple: **0.000 dB** at any depth, on both n=3 (hall) and n=2 (folded
studio rig). The level never pumps; only its distribution turns. Depth 0.6
gives a 6 dB per-channel swing.

At `n = 1` there is nothing to rotate against and the sum degenerates to a
single cosine — 9.5 dB of pumping at depth 0.8, infinite at 1.0 — so the
rotation is guarded off below two channels.

**`vt`, not a local counter.** The phase has to stay continuous *across*
cycles; a per-cycle counter would reset every 16 s and collapse the second
clock back onto the breath. And the period must not divide into `cycle_dur` for
the same reason — 41 s against 16 s repeats only every 656 s.

> **A real bonus.** The same bed plays on three coherent speakers, so it builds
> an interference pattern with fixed nulls. Rotating the distribution walks
> those nulls slowly through the room instead of leaving them parked in one
> place — and unlike a fixed decorrelation delay, it comb-filters nothing.

**This is a hall feature.** On four outputs the beds fold to two channels each,
so the rotation is only a left–right sway. The studio cannot show what it
actually does — the same trap as `bed_scale` and the M=0 quads.

Cost is 12 bed nodes at 2 control messages a second — 24/s against the ~64
grain events/s the piece already sustains, with `amp_slide` interpolating
between them. At `xen_atmos_rotate 0` the bed is triggered exactly as before,
no slide is set and no control loop runs.

### Grain density — `xen_density`

A multiplier on every cloud's `lambda`. It exists because it was the only
thing that moved the needle when the piece was killing its audio device.

`lambda` is grains/second and each grain is panned across two channels, so the
inhale's 24 + 8 becomes ~64 voices/second created and freed, and the exhale's
32 + 11 more again. The bisect that found it:

| configuration | result |
|---|---|
| `xen_layers :atmos` (beds only, 8 voices) | clean indefinitely |
| `xen_layers :grains` (no beds) | clean indefinitely |
| `:both` at density 1.0 | died in 1–3 cycles on 5.0 |
| `:both` at density 0.5 | 10 h 40 min on 5.0 |

Neither layer is broken; the **combination** crossed a real-time budget. On
4.6 that ceiling is far away — full density measures a median `B/Q` of 0.24 —
so `xen_density` is back to **1.0** and is a compositional dial again rather
than a workaround.

### The slope

The score sheet annotates the inhale **−25°** and the exhale **−30°**. Neither
is a hall angle:

- **They don't fit.** The inhale run S1→S6 is 10.20 m horizontally
  (`nodes.tsv`). At −25° that is ΔZ = −4.76 m, landing at Z = −0.76 m; the
  exhale at −30° lands at Z = −1.89 m. Both are under the floor.
- **They carry no height.** Reconstructing the drawing's viewpoint
  (elev ≈ 21°, azim ≈ −49°) reproduces them from the node coordinates — the
  exhale chord S6→S11 projects to 30.0° exactly — and S1, S5, S6 and S11 all
  sit at Z = 4.00 in `nodes.tsv`. Force those Zs flat and the page angle
  doesn't move a tenth of a degree. They are the hall's *length* axis tipped
  up the sheet by the axonometric.

The **α/β annotation, ∓12°, is the real one**, and it is load-bearing:
4.00 m (S1) − 10.20 m · tan 12° = 1.83 m ≈ **1.80 m, the plane of all twelve
monitors** (`monitors.tsv`), and +12° over the exhale's identical run returns
to exactly 4.00 m = S11's Z. The breath descends from the theoretical node
height onto the speaker plane, touches it at M=0 — the one moment the piece
renders height physically, the funnel at the feet — and rises back.

That descent used to be a comment and nothing more: the inhale and exhale had
no elevation cue at all, and the only thing drifting downward was the `lpf`
ramp, which darkens as a side effect of timbre rather than as a slope anyone
set. It is now voiced. Height is spectrum on this rig, so `play_cloud_phase`
ramps the same Blauert pair M=0 states its "above" with — MIDI 120 (8372 Hz)
up, MIDI 103 (3136 Hz) down — from tilt 1.0 to tilt 0.0 across the inhale and
back across the exhale, a ~15 dB swing in the band ratio. Tilt is the height
above the speaker plane normalized to the node height, so **M=0 is the
full-scale reference**: the breath can never claim more height than the
critical point does.

The pair sits *inside* the `tanh`, as it does at M=0 — the boost is part of
what the ceiling catches, not something added after it — and it is two nodes
and two `control` messages **per channel, not per grain**, because the FX
chain is already persistent for the whole phase.

`xen_breath_slope` is live, so the angle can be found by ear (shallower leaves
more of the "above" cue standing at M=0; steeper drains it sooner), and an
angle that would drop the breath below the speaker plane is clamped *and
logged* — so the −25° mistake can't quietly return.

**`xen_blauert` 0.75, because the pair is not symmetric on this material.**
The two phases end on different filter cutoffs, and that decides how much of
the band pair actually lands. Measured on the concatenated pools, through the
sampler's own `lpf`, at full tilt:

| | lpf at full tilt | +9 dB @ 8372 Hz | peak | RMS |
|---|---|---|---|---|
| inhale | 8372 Hz — *on* the knee | lands | **+2.40 dB** | +0.53 dB |
| exhale | 5274 Hz — *below* the band | mostly wasted | −0.54 dB | **−3.46 dB** |

The inhale gains, as intended. The exhale can't: its `lpf_to` is 5274 Hz, so
the boost sits above the knee and effectively only the −6 dB at 3136 Hz
lands — right where the shatter material lives. At `xen_blauert` 1.0 that
costs the exhale **3.5 dB of RMS**, which works directly against a phase whose
job is to open up toward the shatter.

0.75 holds that loss to −2.7 dB and still swings the band ratio 4–6 dB
in-band, comfortably inside the range Blauert's cue operates over. The trade
is that tilt 1.0 no longer equals M=0's chord exactly — the breath tops out at
three quarters of the critical point's claim rather than matching it. If the
exhale turns out to carry the loss, **1.0 restores that reference** and is the
first thing to try; the knob is live either way.

> The "~15 dB swing" figure is the *nominal* difference between the two
> filters' gains (9 + 6). Measured in-band on real material it is 6–8 dB,
> because at Q 1.414 the response falls off inside the measurement band.

### Placing a grain — `xen_pan_mode`

Continuous panning splits every grain across the two channels either side of
its position, at constant power, so the cloud moves as a **phantom image**
gliding between speakers. That was the original design and it is still the
default. The in-situ measurements gave three reasons to have an alternative:

- **Early reflections sit inside the fusion window.** Arrivals at 0.62, 1.60
  and 4.96 ms at −14 to −16 dB re direct are exactly what broadens and shifts
  a phantom — and `C80` scores them as clarity, so the clarity plot looks
  excellent while the image is being smeared.
- **Moving air modulates the top end.** 2–3 m/s in the hall, against a 4.1 cm
  wavelength at 8372 Hz.
- **A phantom only holds in a sweet spot.** Off axis the precedence effect
  collapses it onto the nearer speaker. A real source cannot collapse — and
  this is an installation people walk through.

`:discrete` sends each grain **whole to one channel**, chosen probabilistically,
and lets the ear assemble the trajectory from the sequence the way it reads
apparent motion.

**The fold is by power share, not by position.** A grain at fractional position
`frac` between channels goes to the upper one with probability
`sin²(frac·π/2)` and the lower with `cos²(frac·π/2)` — the same weights the
continuous law uses, squared:

```ruby
p_upper = Math.sin(frac * Math::PI / 2) ** 2
pick    = (rand < p_upper) ? ch + 1 : ch
events << ev.merge(chan: pick, amp: intensity)
```

That makes the expected power on a channel `P(ch) · intensity² = cos²(…) ·
intensity²`, which is precisely what continuous mode puts there. **The spatial
distribution of energy is identical; only its granularity changes** — so an A/B
between the modes tells you about placement and nothing about level. Verified
by simulation over 130k events: per-channel power matches within 0.14 dB and
total within 0.03 dB, on both the 4- and 12-output rigs.

The obvious alternative — a linear `P(upper) = frac` — is subtly wrong: it
matches the *amplitude* law rather than the power law, and pulls energy toward
the channel boundaries.

Carrying the full `intensity` rather than `intensity/√2` is the other half of
the equivalence: all the power goes to the one speaker, so per-grain radiated
power is unchanged too.

> **It halves the voice count.** Discrete emits one event per grain instead of
> two, measured at **0.58×** — the inhale's ~64 voices/s become ~37. Free
> headroom on the layer that has historically been the expensive one (see
> *Grain density* above).

**M=0 is untouched** — its quads are already discrete placements, so the mode
applies only to the inhale and exhale clouds.

The trade is granularity: at low density a discrete cloud can start to read as
separate points rather than as movement. That can only be judged in the room,
which is why this is a live parameter — flip it mid-run while walking the hall.

### The trajectory — `xen_traj_mode`

**The span was always deterministic.** `lo` and `hi` in `play_cloud_phase` are a
plain linear interpolation from `span0` to `span1` across the phase — the window
travels down the inhale slope on rails. What `:scatter` randomises is only
*where inside that window* each grain lands.

`:sweep` replaces that scatter with a parametric curve — the *Metastaseis* /
Philips Pavilion reading of the same drawing: a ruled surface traced by
glissandi rather than a cloud filling a volume.

```ruby
centre = mid + half * Math.sin(2 * Math::PI * rate * f + ph)
pos    = centre + rrand(-traj_width, traj_width) * half
pos    = [[pos, lo].max, hi].min
```

Both idioms are Xenakis — the Poisson clouds are the *Pithoprakta* /
*Achorripsis* stochastic lineage, this is the glissando lineage — so it is a
**choice of idiom, not a correction**.

**`xen_traj_width` is the dial that matters.** At 0.0 the phase collapses to a
single travelling point: one grain position at any instant, which under
`xen_pan_mode :discrete` means one speaker at a time. That is a line, not a
cloud. *Metastaseis* is 46 separate string glissandi — a **bundle** of nearby
lines — so the default keeps a narrow scatter around the swept centre and reads
as a thick line. At 1.0 it melts back into `:scatter`, only phase-locked.

Each cloud gets its own rate and a quadrature phase offset, so the two families
of lines **cross** rather than moving in lockstep — the crossings are the
surface. With two clouds that is 1× and 2× `xen_traj_cycles`.

The two switches are orthogonal, and the four combinations sound like four
different pieces:

| | `:continuous` | `:discrete` |
|---|---|---|
| **`:scatter`** | the original — a cloud with a phantom image | a cloud, each grain on one speaker |
| **`:sweep`** | a glissando gliding between speakers | a glissando stepping speaker to speaker |

> `sin()` gives smooth turnarounds. A ruled surface is strictly made of
> **straight** lines, so a triangle wave is the more literal reading — at the
> cost of a sharper reversal at each extreme. It is a one-line swap in
> `play_cloud_phase`.

Bounds are clamped to the current span before the rig fold. Without that the
scatter can push `pos` past `lo`/`hi`, and the fold would then produce a channel
index off the end of the rig — `:scatter` never needed it, because
`rrand(lo, hi)` is bounded by construction. Verified across both rigs at widths
0.0 to 1.0.

### Blauert band width

The one number in the file that was quietly wrong, and it was wrong
everywhere Blauert appears.

The M=0 comment read *"res = 1/Q: higher = wider band"*, and both bands sat
at `res: 0.8` on that understanding. The synthdef says otherwise —
`fx_band_eq` is `MidEQ(in, freq, rq, db)` with `rq = 1 - res`, and `rq` **is**
1/Q, so higher `res` is a **narrower** band, the exact opposite:

```
bandwidth_octaves = (2 / ln2) · asinh(1 / 2Q),   Q = 1 / (1 − res)

  res 0.8   →  rq 0.200  →  Q 5.00   →  0.29 octaves   ← what it was
  res 0.293 →  rq 0.707  →  Q 1.414  →  1.00 octave    ← what it meant
```

So the bands were a third of the width they were meant to have. Blauert's
directional bands are broad — they are a property of the pinna, not a filter
anyone chose — so a narrow peak is the wrong *shape* for the cue however much
gain it carries. All of it now shares one constant, `blauert_res = 0.293`:
the M=0 ceiling scalpel, the M=0 atmosphere accent, and the ramped pair that
carries the slope.

This does change a gesture that was rehearsed narrow. Expect the M=0 cue to
read broader and less whistly, and the 3 kHz cut to take more of the
"behind" band with it.

### Hearing the atmosphere at M=0

M=0 is two gestures, not one, and they do not compete with the same thing.

The atmosphere's M=0 accent plays on `quad_ceil` — **the same speakers as the
granular scalpel** (1, 2, 11, 12), never the funnel's (5, 6, 7, 8) — and in
the same band. The scalpel is HPF'd to 2960–4186 Hz and then boosted +9 dB at
8372 Hz, which is exactly where the accent's Blauert band sits. The funnel is
LPF'd at 466 Hz.

| | speakers | band |
|---|---|---|
| atmosphere accent | 1, 2, 11, 12 | peaked 8372 Hz |
| granular **scalpel** | **1, 2, 11, 12** | **≥ 2960 Hz, +9 dB @ 8372** |
| granular funnel | 5, 6, 7, 8 | ≤ 466 Hz |

So it is the **scalpel** that buries the accent, with nearly three octaves of
clear air between the accent and the funnel, on different speakers. The two
halves are therefore trimmed separately on top of `m0_amp`:

```ruby
m0_ceil_trim  = get(:xen_m0_ceil_amp, 0.85)   # −15%, about −1.4 dB
m0_floor_trim = get(:xen_m0_floor_amp, 1.0)   # the funnel, untouched
```

Trimming the funnel would cost exactly the weight at the feet that makes M=0
land, and would not uncover one dB of the atmosphere — which is the whole
reason M=0 doesn't go soft as a single number. If the gesture as a whole wants
to come down, `xen_m0_floor_amp` is there; it just shouldn't be the first
thing reached for.

Note this holds in the hall. On a reduced rig `quad_ceil` and `quad_floor`
both collapse to the same outputs (`xen_spread`), so in the studio the two
halves share speakers — the band separation still keeps them apart, but the
spatial half of the argument is a 12-output property.

### Making the atmosphere spectral

The beds are field recordings — breath and doppler — so on their own they are
broadband noise, which is the most *granular* thing in the piece: no pitch,
all texture. Sonic Pi has no phase vocoder (there is no `PV_`/FFT FX in the
entire set, so a true spectral freeze is not available), but resonance does
the job: excite a narrow band and noise becomes pitch.

So the four beds stop being four recordings and become **four partials of one
spectrum**. Each gets a narrow peaking EQ — a peaking EQ rather than a band
pass, because it *adds* the partial to the bed instead of replacing the bed
with the filter's residue, and because it keeps the gain explicit in dB.
(`:nrbpf` would not: it ends in a SuperCollider `Normalizer` targeting 1.0,
which would drive the beds to full scale straight through the headroom
budget.)

**f0 is measured, not chosen.** Long-term average spectrum over three files
from each of the four families:

| band | share |
|---|---|
| 62–125 Hz | 11.9 % |
| **125–250 Hz** | **56.5 %** |
| **250–500 Hz** | **25.0 %** |
| 500 Hz–1 kHz | 5.8 % |
| 1–1.5 kHz | 0.7 % |

with per-family peaks at 145.0 / 191.9 / 131.8 / 127.4 Hz. 81.5% of the bed
lives in 125–500 Hz, and MIDI 48 (C3, 130.8 Hz) sits on the lowest of those
peaks; partials 1–4 land at 131 / 262 / 392 / 523 Hz, across the band where
the material actually has body — the difference between a resonance that
rings and one that boosts nothing.

Which bed gets which partial follows the breath: the inhale hexagon carries
partials 1 and 2, the exhale hexagon 3 and 4, so the exhale side sits
spectrally higher — the same direction its slope goes. Since the beds are
already four decorrelated sources on interleaved speakers, the chord is
distributed around the hall rather than summed at one point.

> **`res` is inverted from what you'd guess** — see *Blauert band width*
> above. `res: 0.94` → rq 0.06 → Q ≈ 17, about 0.09 octaves. Narrow is what
> we want here: a wide bump is a tone control, a narrow one sings.

**Depth: `xen_atmos_spectral` 10 dB, and headroom is not what limits it.**
Measured on three files from each family, with the EQ applied exactly as the
piece applies it:

| depth | tonal prominence | RMS | per-speaker peak (4 out, two beds summed) |
|---|---|---|---|
| 0 dB | 2.3 dB | — | 0.239 |
| 8 dB | 9.7 dB | +0.39 dB | 0.246 |
| **10 dB** | **11.6 dB** | **+0.57 dB** | **0.250** |
| 15 dB | 16.1 dB | +1.26 dB | 0.287 |

A Q ≈ 17 peak lifts such a sliver of the band that even 15 dB costs 1.3 dB of
RMS, and the tanh takes 0.18 dB at the chosen depth. So this is a **taste
knob, not a safety one** — 10 dB is where the bed reads as pitched without
starting to whistle, and the ceiling is far above it.

**f0 = MIDI 48 re-checked against the alternatives**, since the partials are a
chord imposed on four recordings rather than each bed's own peak. It holds:
at MIDI 36 the first partial lands on 65 Hz, where the bed has −27 dB of
energy and does not ring at all (prominence 0.2 dB); MIDI 43 weakens partial 1
the same way. At 48 all four ring between 9.7 and 13.4 dB, even the exhale
partials at 392 and 523 Hz where the material is 15–19 dB down.

## 6. The reloader — `sonic-pi-buffer.rb`

The only workspace that gets edited during a session/installation. It sets
the live parameters (output rig, focus, layers, amplitudes, enhancer, studio
bleep, seed) via `set`, then contains the reloader loop, which:

- checks `File.mtime` on `xenakis.rb` every 0.5 s and, if it changed, does
  `run_file` on the library — so you edit `xenakis.rb` in an external
  editor and the changes land in Sonic Pi without a manual Stop/Run;
- runs with `use_sched_ahead_time 2.0`. This was 60, to stop a `TimingError`
  killing the loop during the library load — but sched_ahead is also how long
  every `set` parks a raw `Thread.new` in Sonic Pi's GUI-message path. Those
  are not job subthreads, so `Stop` leaves them running; at 60 they piled up
  until the message queue backed up and a later `Run` could not start its
  live_loops at all. `run_file` returns as soon as it has spawned the piece's
  own Run, so this loop is never busy for seconds anyway;
- keeps `last_mtime` as a local variable (not in Time State), so that every
  `Run` reloads the library for certain, even though Time State survives
  `Stop`;
- computes a `run_tag` (also local, so fresh per `Run`, stable across hot
  reloads) and passes it to the library via Time State. **Every named
  live_loop carries it.** Sonic Pi's named-thread registry is global to the
  process and a name is released only once every subthread of the job that
  owns it has died; this piece leaves grain threads behind, so without a
  per-Run suffix the next `Run` evaluates the whole library and then quietly
  fails to start a single loop — silence, no error, until Sonic Pi is killed;
- calls `sample_free_all` on a fresh `Run` (never on a hot reload, which
  would free buffers that are currently sounding). A `load_sample` whose
  `/b_allocRead` misses scsynth's 5 s deadline leaves a half-allocated buffer
  in the sample cache forever, and anything that later asks it for
  `num_frames` blocks for good.

```ruby
set :xen_rig_outputs, 4    # 12 = Hala MX, 4 = UMC404HD in the studio
set :xen_focus, :all       # which phase: :inhale :exhale :m0 :m0_ceil :m0_floor :all
set :xen_layers, :both     # which material: :both :atmos (beds only) :grains (granular only)
set :xen_density, 1.0      # grain density multiplier (§5)
set :xen_sched_ahead, 3.0  # lookahead for the breath loop — spikes vs. Stop safety (§4)
set :xen_atmos_amp, 0.5    # the bed — sits OVER the granular material (rig-compensated)
set :xen_atmos_m0_amp, 0.75
set :xen_atmos_rotate, 0.0 # beds turn: depth 0.0-1.0, constant power (§5)
set :xen_atmos_rotate_period, 41.0 # seconds; not a divisor of the 16 s cycle
set :xen_m0_ceil_amp, 0.85 # M=0's granular scalpel, trimmed so the atmos accent shows
set :xen_m0_floor_amp, 1.0 # M=0's funnel — left alone on purpose
set :xen_atmos_spectral, 10.0 # depth in dB of the beds' resonant partials, 0 = off
set :xen_atmos_f0, 48      # MIDI — C3, on the beds' measured spectral peak
set :xen_atmos_stretch, 1.0 # 1.0 = harmonic, >1 = stretched
set :xen_atmos_res, 0.94   # HIGHER = NARROWER (rq = 1 − res)
set :xen_breath_slope, 12.0 # the score's α/β, in degrees — see "The slope"
set :xen_blauert, 0.75     # how strongly the slope is voiced, 0.0 = off
set :xen_pan_mode, :continuous # :continuous (phantom) | :discrete (one speaker per grain)
set :xen_traj_mode, :scatter  # :scatter (cloud) | :sweep (ruled-surface glissando)
set :xen_traj_cycles, 3.0     # sweeps per phase, first cloud; second runs at 2x
set :xen_traj_width, 0.12     # line thickness, fraction of the span half-width
set :xen_enhance, 0.4      # dbx 118: -1.0 compress .. 0.0 bypass .. +1.0 expand
set :xen_enhance_threshold, 0.2   # beds + clouds only; all of M=0 stays at unity
set :xen_master_amp, 1.0
set :xen_bleep, true       # studio reference bleep at cycle boundaries (off in the hall)
set :xen_seed, 0           # changing this needs Stop + Run
```

`focus` and `layers` are orthogonal: `focus: :inhale, layers: :grains` gives
the inhale clouds alone. Muting a layer never changes the length of a breath —
the phases hold their time either way, otherwise the 16 s atmosphere files
would be retriggered every couple of seconds.

Run: `./session-scripts/start-46.sh --simulation` (or `--production` in the
hall), which installs this file into Buffer 0 with the venue's rig and bleep
applied on top, then hit **Run**. `xenakis.rb` is never run directly.

`xen_rig_outputs` and `xen_bleep` are therefore **set by the mode, not by this
file** — editing them here only changes what a `--keep` launch would use.

**Tuning done in the GUI lives only in Buffer 0 until you copy it back here.**
The next `start-46.sh` overwrites it from this file — the backup and Sonic Pi's
autosave git history are what recover it, so commit anything you want to keep:

```sh
diff ~/.sonic-pi/store/default/workspace_zero.spi sonic-pi-buffer.rb
```

## 7. Audio system setup — Sonic Pi 4.6.0, not 5.0

**The piece runs on Sonic Pi 4.6.0, built from source. This is not a
preference — 5.0.0 destroys the running job by design.**

### 7a. Why not 5.0

Sonic Pi 5.0.0 (released 2026-08-07) introduced the SuperSonic engine, native
PipeWire output, and a **rate-skew watchdog**. When the audio device dips
below real-time, the watchdog does not ride it out — it performs a cold swap
that nukes scsynth state and kills the Run:

```
[watchdog] rate skew detected: device delivering 0.95x real-time (nominal 48000 Hz)
           — clock cannot converge, will recover with a cold swap
[watchdog] rate skew: recovering with a cold swap (0.95x real-time)
```

**A 5% dip ends the installation.** Measured: an overnight run at half density
survived 10 h 40 min (`callbackCount=224656`, 224656 × 8192 / 48000 = 38,341 s)
with *zero* skew events, then one 0.95x transient killed it. At full density it
died within 1–3 cycles, every time.

There is no way to turn it off. The binary exposes 11 command-line options and
5 environment variables; none touch it. Its parameters — `watchdogRateTolerance`,
`watchdogRateWindowMs`, `watchdogRateBadWindows`, `watchdogPollMs`,
`watchdogStallMs` — exist only as internal symbols, compiled in, unreachable
from `scsynth_opts` or anywhere else.

Things that did **not** fix it, all measured, so nobody re-treads them:

| tried | result |
|---|---|
| `clock.force-quantum` 1024, `force-rate`, `allowed-rates`, `quantum-limit` | no change |
| buffer 1024 → 2048 | skew moved 0.90x → 0.92x — a near-constant deficit, not burst overrun |
| `PIPEWIRE_LATENCY=1024/48000` | callback stayed ~8192 samples regardless |
| `api.alsa.headroom = 8192` | removed the skew, caused `spa.audioconvert: out of buffers` instead |
| ALSA driver instead of PipeWire | Sonic Pi falls back to the 64-channel default device |
| `use_sched_ahead_time 3.0` | fixed the M=0 LATE spikes (1116 ms → 4 ms) and made the piece die **sooner** |

Two things that did matter, both still true on 4.6: DSP load was never the
issue (~1% with occasional spikes), and **each layer alone runs clean** —
`xen_layers :atmos` and `:grains` each survived indefinitely; only both
together crossed the line. That is what `xen_density` exists for.

### 7b. Building 4.6.0

Every prerequisite is in Ubuntu 24.04's repos. `./session-scripts/build-sonicpi-46.sh`
does it, or by hand:

```sh
git clone --branch v4.6.0 https://github.com/sonic-pi-net/sonic-pi.git ~/src/sonic-pi
cd ~/src/sonic-pi/app && CC=gcc-12 CXX=g++-12 ./linux-build-all.sh
```

- **gcc-12, not 13.** 24.04 defaults to gcc-13 and vcpkg's dependencies don't
  build with it. `CC`/`CXX` in the environment is enough; cmake honours them.
- **Skip `pipewire-jack` only if you intend to run real jackd.** 4.6 detects
  PipeWire with `which pw-link` and then *will not start jackd for you* — it
  runs scsynth through `pw-jack`. Without that binary the launch is broken in
  a confusing way.
- On Debian the Qt dev packages are `libqt6svg6-dev` / `libqt6opengl6-dev`; on
  Ubuntu 24.04 the same files come from `qt6-svg-dev` / `qt6-base-dev`.

Binary lands at `~/src/sonic-pi/app/build/gui/sonic-pi`. scsynth is the
**system** one (`/usr/bin/scsynth`, 3.13.0) — on Linux `Paths.scsynth_path`
is just `"scsynth"` from PATH.

### 7c. Configuration — `audio-settings.toml`

4.6 reads `~/.sonic-pi/config/audio-settings.toml` (`Paths.user_audio_settings_path`).
Note **no `v5-` prefix**: it does not collide with 5.0's files, so both
versions can stay installed.

```toml
sound_card_sample_rate = 48000
num_outputs = 4                    # 12 in the hall; 4.6's own example ships 16
num_inputs = 0
linux_pipewire_buffsize = 1024
linux_pipewire_samplerate = 48000
```

> **Do not set `sound_card_name` on Linux.** It becomes scsynth's `-H`, which
> under JACK is the **server** name, not a device. Setting it to
> "UMC404HD 192k Pro" makes scsynth hunt for a JACK server of that name. The
> output device is chosen by routing (7d), not by this file.

`num_inputs = 0` is deliberate: the piece never reads audio in, and leaving
the UMC's capture stream open had it accumulating 154 xruns on a duplex USB
device that shares one clock with playback.

### 7d. Routing — this is the part that bites

The signal path is `scsynth → pw-jack → PipeWire → interface`. scsynth's JACK
client is named **`SuperCollider`** (not `scsynth` — grep accordingly).

`SC_JACK_DEFAULT_OUTPUTS` (honoured by `libscsynth.so.1`) names the output
ports explicitly, and it works. **It is not enough on its own**, because Sonic
Pi patches the outputs a second time — five seconds after scsynth boots — and
patches them wrong. From `daemon.rb`, `run_post_start_commands`:

```ruby
inputs   = `pw-link -iI`.lines
left_id  = inputs.grep(/alsa_output.*playback_FL$/).first.to_i
right_id = inputs.grep(/alsa_output.*playback_FR$/).first.to_i
system("pw-link #{sco1} #{left_id}")
system("pw-link #{sco2} #{right_id}")
```

`playback_FL`/`FR` are the port names of a consumer **stereo** profile. The
UMC runs in the **Pro Audio** profile, so its ports are `playback_AUX0..AUX3`
and never match that regex. The only node in the graph that does match is the
built-in `HDA Intel PCH`. Three consequences, each of which has bitten:

- **The PipeWire default sink is ignored entirely.** Pointing the default sink
  at the UMC changes nothing. 7c's note that the output device is "chosen by
  routing" means *this code*, not the default sink.
- **The symptom is both devices at once, not the wrong one.** daemon.rb *adds*
  links rather than replacing them, so even with `SC_JACK_DEFAULT_OUTPUTS` set
  correctly you get the UMC **and** the laptop speakers.
- **Only `out_1`/`out_2` are ever touched.** Channels 3+ are left dangling, so
  even an interface that did expose FL/FR would silently drop everything above
  the first pair.

`./session-scripts/start-46.sh` covers both halves: it sets
`SC_JACK_DEFAULT_OUTPUTS`, and it backgrounds `link-outs.sh`, which waits out
daemon.rb's 5 s timer, tears down whatever links exist, and repatches
`out_1..N` to the same port list the launcher computed — one source of truth
for both mechanisms.

```sh
./session-scripts/start-46.sh --simulation   # studio: 4 outputs on the UMC404HD
./session-scripts/start-46.sh --production   # hall: 12 outputs on the default sink
./session-scripts/start-46.sh --production 8 # override the count for one run
```

**Production refuses to start under-routed.** `head -n 12` on a sink with 8
ports returns 8 and says nothing, which in the hall means discovering
mid-concert that four channels were never patched — so if the graph has fewer
ports than the mode asked for, `--production` aborts and tells you the real
count. `--simulation` warns and continues on what it found, adjusting the
desk's `xen_rig_outputs` to match so the piece never folds its drawing onto
channels that do not exist.

Watch for the `[link-outs]` lines about 15 s in. Then verify — this is the
check that matters:

```sh
pw-link -l | grep -A2 '^SuperCollider:out'
```

You want `out_1..4` on `…UMC404HD…pro-output-0:playback_AUX0..3`. To repatch a
running instance without restarting, re-run the linker; it is idempotent, and
takes an explicit port list in channel order if the default is not what you
want:

```sh
./session-scripts/link-outs.sh
./session-scripts/link-outs.sh "$SINK:playback_AUX2,$SINK:playback_AUX3"
```

> **The hall path is untested against a real 12-out rig.** `start-46.sh` builds
> its port list with `pw-link -i | … | head -n "$N"`, which relies on `pw-link`
> emitting ports in channel order. It did for the UMC, and the production path
> has been exercised against a simulated 12-port sink, but the tool does not
> guarantee that order — check the assignment against `monitors.tsv` before
> trusting it.

### 7e. Verify

```sh
pgrep -a scsynth                    # want -i 0 -o 4 -S 48000
pw-link -l | grep -A2 '^SuperCollider:out'
pw-top -b -n 5 | grep SuperCollider # QUANT / BUSY / B/Q / ERR
```

Healthy, measured at **full density** on 4.6:

| metric | value | meaning |
|---|---|---|
| `QUANT` | 1024 @ 48000 | 21.3 ms real-time budget |
| `B/Q` | median 0.24, peak 0.52 | a quarter of the budget, half at peak |
| `ERR` | 0 new over 45 s | no xruns |
| `/s_new … Group not found` | ~83, all at startup, 0 new | leftover node cleanup, not dropped grains |

For comparison, 5.0 showed `B/Q` of 0.00–0.01 with `+++` overflows — the
number was meaningless there because the callback was 8192 samples rather
than 1024.

`ulimit -Hr` should be 95. `ulimit -l` reads **4194304 KB = 4 GB** from the
`@pipewire` group, which is ample — the `audio` group only adds `unlimited`,
and scsynth does not lock memory unless passed `-L`.

## Layout

```
ADSR_ENVELOPES/                    mono sources for grains_slice.py
ATMOS/                              stereo sources for atmos_slice.py
output_xenakis_installation/       generated, not checked into git
  inhale/ exhale/ sonic_blast_m0/   output of grains_slice.py
  atmos/                            output of atmos_slice.py
  concat/                           output of build_pools.py (pools + cut tables)
  m0_render/                        output of render_m0.py
session-scripts/                   build + launch + audio helpers
  build-sonicpi-46.sh              builds Sonic Pi 4.6.0 (gcc-12, system scsynth)
  start-46.sh                      --production | --simulation: desk, routing, launch
  link-outs.sh                     repatches scsynth onto the interface (start-46 calls it)
  check-session.sh                 is it healthy right now? (delivery, not settings)
  setup-audio.sh, revert-*.sh      5.0-era PipeWire pinning; kept for reference only
  restore-sonicpi-config.sh        puts audio-settings.toml back
  set-buffer-2048.sh, try-alsa.sh  5.0-era experiments; kept for reference only
  start-session.sh                 the 5.0 launcher, superseded by start-46.sh
monitors.tsv                       physical positions of the 12 monitors (cm)
nodes.tsv                          theoretical breathing path, 11 nodes
TODO.md                            open tuning items
```
