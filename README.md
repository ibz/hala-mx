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
  wrong, and a bleep in front of an audience is not recoverable. It also
  **reaps a previous session's backend** before launching — see below.
- **The desk has a hard size ceiling of 16320 bytes, and going past it makes
  Run do nothing at all.** Pressing Run sends the *whole buffer* to the runtime
  as one OSC string argument (`/run-code`, `spider-server.rb:286`), and the
  listener reads it with `recvfrom(16384)` (`osc/udp_server.rb:89`). A larger
  datagram is silently **truncated** on read, the trailing string loses its NUL
  terminator, and the decoder throws:

  ```
  Critical: UDP Server Spider API Server ... had issues receiving
  undefined method `%' for nil        (osc/oscdecode.rb:100)
  ```

  The listener `redo`s and survives, which is what makes this so nasty: no
  crash, nothing in the GUI, and no job — just **one log entry per Run press and
  otherwise silence**, while Sonic Pi reports "Booted Successfully" and looks
  perfectly healthy. Diagnosed 2026-09-16 after the desk grew from 13979 to
  19326 bytes, and reproduced directly against Sonic Pi's own encoder/decoder.
  `start-46.sh` now refuses to install an oversized desk and warns within 512
  bytes of the line. **Long-form rationale belongs in this file, not on the
  desk** — that is what the ceiling is telling you.

- **A dead Sonic Pi also leaves its backend running.** Quitting normally is
  fine; a session that *dies* is not — the GUI is the part that goes, while
  tau/beam, `spider-server`, `daemon.rb` and `scsynth` outlive it. The old
  `pgrep -x sonic-pi` guard only ever saw the GUI, so the next launch started on
  top of the corpse, with two taus on different port maps and tokens. That was
  *not* the cause of the silence above — it was found while chasing it — but it
  is a real hazard, so `start-46.sh` now reaps remnants first. A *running* GUI
  is still refused rather than killed, because its autosave would take Buffer 0
  with it. Note `beam.smp` **ignores SIGTERM** and holds its ports, so the reap
  escalates to `SIGKILL` and verifies rather than assuming TERM was enough.

  To check by hand:

  ```bash
  pgrep -af '[s]onic-pi|[s]csynth|[s]pider-server|[d]aemon\.rb|[t]au/_build'
  wc -c sonic-pi-buffer.rb      # must stay under 16320
  ```

  > Unrelated and harmless: `gui.log` fills with `Failed to connect to shared
  > audio memory`. That is exactly what `patch_shm_crash` in
  > `build-sonicpi-46.sh` is built to produce — the system scsynth never creates
  > that segment, and the patch turns what used to be a `std::terminate` into a
  > 1 s retry that logs forever. It is not a fault and not the cause of silence.
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

The work is spread out rather than dumped in one instant, and the loop still
consumes **exactly `cycle_dur`** in total — it has to stay in phase with the
breath, or the set would switch underneath a cycle that is still playing it.

What is held constant is **the gap between operations**, not the width of the
window. The original pairing was 12 operations in a 3.0 s window — one every
250 ms — and that is the only pace with hours behind it, so `xen_atmos_load_gap`
keeps it and the *window* grows with the set instead. That matters because
`xen_atmos_decorr` changes the set size: at 3 there are 14 files to load and 14
to free, and 28 operations in the old fixed 3.0 s window would be one every
**107 ms — faster than the burst that stopped the device**.

The set is therefore chosen *before* the sleep, not after: choosing costs no
time (it is only shuffles), so the count is known in time to size the window.

```ruby
upcoming   = atmos_set.call
up_files   = upcoming.values.flatten
free_files = to_free ? to_free.to_h.values.flatten : []
n_ops      = up_files.size + free_files.size

op_gap  = get(:xen_atmos_load_gap, 0.25)
window  = [n_ops * op_gap, cycle_dur - 2.0].min
stagger = window / n_ops

sleep cycle_dur - window - 1.0   # let the current cycle keep sounding
up_files.each { |f| load_sample f; sleep stagger }
...
free_files.each { |f| sample_free f; sleep stagger }
sleep 1.0
```

| `xen_atmos_decorr` | files/set | ops | window | gap | sleep first | total |
|---|---|---|---|---|---|---|
| 1 | 6 | 12 | 3.0 s | 250 ms | 12.0 s | 16.0 s |
| 2 | 10 | 20 | 5.0 s | 250 ms | 10.0 s | 16.0 s |
| 3 | 14 | 28 | 7.0 s | 250 ms | 8.0 s | 16.0 s |

At `decorr 1` this reproduces the old constants exactly.

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

### The beds' own enhancer — `xen_atmos_enhance`

Expansion is the **only process in the bed chain that makes the texture less
dense**. It pulls quiet frames further down, so the material's own gaps deepen
instead of resting on a floor. Everything else measured goes the other way —
the +10 dB partial fills gaps by 0.75 dB, the `tanh` by another 0.04 — and the
chain nets +0.18 dB. So the enhancer is split off from the clouds', and the
beds' side opens further than the shared knob does.

Measured on `inh_b` through `bed_amp → band_eq → tanh`, at threshold 0.2,
against no expander at all (−5.49 dB of gap depth):

| `xen_atmos_enhance` | `slope_below` | gap depth | gained | RMS cost | ratio |
|---|---|---|---|---|---|
| 0.4 (shared default) | 1.2 | −6.10 dB | +0.61 | −0.82 dB | 0.74 |
| 1.0 | 1.5 | −7.19 dB | +1.70 | −1.98 dB | 0.86 |
| 2.0 | 2.0 | −8.75 dB | +3.26 | −3.75 dB | 0.87 |
| 3.0 | 2.5 | −10.58 dB | +5.09 | −5.34 dB | 0.95 |

About **1 dB of level per 1 dB of gap**, and the rate does not fall off — the
ratio *improves* across the range, so there is no knee to stop at. Stop where
the level loss stops being affordable.

**The threshold is not the knob.** At 0.4 the gap depths are identical to those
at 0.2 to within 0.01 dB (−6.10, −7.19, −8.75, −10.59) while the RMS cost
multiplies by 2.5×: once the threshold clears the material the gain law is a
pure power law on the envelope, so raising it rescales everything and reshapes
nothing. Below the material it does the opposite — at 0.05 most frames sit in
the `slope_above` region, which is 1.0, so even slope 2.5 only reaches −7.97 dB.
0.2 is already where it wants to be.

The knob goes past +1.0 deliberately, unlike the shared one. Expansion leaves
`slope_above` at 1.0, so it can only ever pull **down** — it cannot clip outputs
that bypass the master limiter. The compression side stays clamped at −1.0,
where `slope_above` is 0.5; past −2.0 it would reach zero and invert.

It pairs with `xen_atmos_decorr`: at 3 each speaker plays a different file, so
each expander works on its own material and the gaps deepen **independently per
speaker**. At 1 the three channels are the same signal and expand in lockstep,
which deepens the gap without opening the texture.

### Decorrelating the beds — `xen_atmos_decorr`

A bed plays on three speakers. Up to now all three read the **same buffer,
sample-locked**, and three coherent copies of one recording do not sound like
three sources — they sound like one thick one. They sum into a fixed
interference field, and every gap in the file is a gap on all three speakers
at the same instant, so the material's own silences never open the texture up;
they just move the whole hexagon down together. That is heard as **density**,
and nothing downstream can undo it.

Measured on `inh_b`, the bed under channels 2, 4 and 6, using the depth of the
quiet 10% of 20 ms frames relative to the median (more negative = more space):

| | gap depth | vs raw |
|---|---|---|
| raw bed | −6.24 dB | — |
| `band_eq` partial, res 0.94 (shipping) | −5.49 dB | +0.75 |
| res 0.80 (Q5) | −5.78 dB | +0.46 |
| res 0.50 (Q2) | −6.01 dB | +0.23 |
| + `tanh` | −5.45 dB | +0.79 |
| + expander 1.2 (shipping) | −6.06 dB | **+0.18** |

**The entire FX chain moves density by 0.18 dB.** Across the 108-file `inh_b`
pool the same measure runs from −14.0 dB at the first quartile to −4.8 dB at
the third — so *which file* is worth roughly 12 dB and *every knob in the
chain together* is worth a fifth of one. The coherence and the material sit
upstream of all of it, which is why this knob exists and why widening the
resonance does not work.

`xen_atmos_decorr` is how many distinct files a bed draws, one per speaker —
`1` is the old behaviour exactly, `3` is one per speaker. It uses
`shuffle.take(n)` rather than `choose` n times, because `choose` can repeat and
two speakers sharing a file is the coherence being paid for in buffers;
Sonic Pi's `Array#shuffle` draws from the same seeded RNG as `choose`
(`core.rb:1084`), so runs stay reproducible. A pool shorter than *n* yields
fewer files and the speakers share again — the old behaviour, arrived at by
degrading rather than by crashing.

Two costs, both real:

- **Buffers.** At 3 a set is 14 files rather than 6, and about three sets are
  live at once (sounding, previous, loading) — roughly 258 MB of atmosphere in
  scsynth instead of 110. The loader re-paces itself (§4) rather than firing
  the bigger set at the old rate.
- **Level — but not the simple loss it looks like.** Three *coherent* copies
  sum to +9.5 dB where they arrive in phase and cancel where they don't; three
  *decorrelated* ones sum to +4.8 dB **everywhere**. Averaged over the room the
  power is the **same** either way — the cross terms average to zero — so this
  does not turn the bed down. What collapses is the **variance**: hot spots lose
  up to 4.8 dB, nulls fill in. The beds live in 125–500 Hz — wavelengths of
  0.7–2.7 m against speakers about a metre apart — so that field is strong and
  strongly position-dependent, and which way a given seat moves depends on where
  in it that seat sat. **Don't pre-compensate `xen_atmos_amp`**; walk the room
  first. The likely result is a bed that is steadier and slightly fuller, not
  quieter.

The knob is read by the loader when it builds the set, one cycle ahead, so a
change shows in the log one breath before it is audible.

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
                           # gates BOTH layers - beds and granular alike
set :xen_layers, :both     # which material: :both :atmos (beds only) :grains (granular only)
set :xen_atmos_decorr, 3   # distinct files per bed, one per speaker — 1 = one file on all three
set :xen_atmos_load_gap, 0.25 # seconds between atmos load/free ops (§4)
set :xen_atmos_enhance, 0.4   # the BEDS' enhancer, split from the clouds' (§5)
set :xen_atmos_enhance_threshold, 0.2
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

`focus` gates **both** layers. The beds are phase material like the clouds
are: `:inhale` keeps `inh_a`/`inh_b` on hexagon A and drops `exh_a`/`exh_b`,
`:exhale` does the reverse, and the three M=0 values keep **no bed at all** —
M=0 is a point in the breath, not a phase of it, so what the atmosphere plays
there is its `quad_ceil` accent, which follows `:m0_ceil` and is dropped by
`:m0_floor`. Soloing a phase does not change what that phase sounds like in
`:all`: the rig compensation `bed_scale` and the beds' partial numbers are
both computed over the unfiltered four, so a soloed bed keeps its level and
its pitch. Note that M=0's own quads span both hexagons by design —
`quad_ceil` is `1, 2, 11, 12` and `quad_floor` is `5, 6, 7, 8` — so under
`focus: :m0` the exhale-end monitors still carry the scalpel and the funnel.

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

- **Use the distro's default compiler. Do not pin gcc-12.** The old advice
  came from "vcpkg's dependencies don't build with gcc-13", which is true but
  not of the *Linux* path — `app/CMakeLists.txt` gates the vcpkg toolchain to
  `if (WIN32 OR APPLE)` and `linux-build-all.sh` never touches it. More
  importantly, pinning an older compiler **breaks the Qt link**. GCC 13
  re-versioned `__cxa_call_terminate` and dropped the old symbol: a current
  libstdc++ exports it only at `CXXABI_1.3.15`, with no `CXXABI_1.3.5` compat
  entry, while code from an older gcc still references the 1.3.5 form. The
  result is

  ```
  undefined reference to `__cxa_call_terminate@CXXABI_1.3.5'
  ```

  surfacing against `libQt6Core`, which is simply the first big C++ library on
  the link line. The compiler has to match the libstdc++ that the distro's Qt
  was built against, so the script now leaves `CC`/`CXX` alone unless you set
  them — `CC=gcc-12 CXX=g++-12 ./build-sonicpi-46.sh build` still works if a
  specific compiler is ever genuinely needed.
- **If CMake says Boost is missing while every Boost package is installed**,
  there are two causes and the script now handles both.

  *The `system` component no longer exists.* Boost.System has been
  **header-only since Boost 1.69**, and newer packaging stopped shipping a
  separate `boost_system` CMake config. But `app/api/CMakeLists.txt:75` still
  asks for it:

  ```cmake
  find_package(Boost 1.74 REQUIRED COMPONENTS filesystem system thread)
  ```

  `REQUIRED` turns the missing config into a hard error, so a *completely*
  installed Boost fails because of the one component that isn't a library any
  more. Check with `ls -d /usr/lib/*/cmake/boost_system-*` — if that comes back
  empty while the other `boost_*` directories are there, this is it. Dropping
  the component is safe: nothing in the api links `boost::system` (its own
  sources use header-only `algorithm/string`), and `Boost::filesystem` carries
  its own transitive dependencies. Verified against 1.83 — the find still
  yields `Boost::filesystem;Boost::thread`. The build script patches this only
  when `boost_system` is genuinely absent, keeping `.orig` alongside, so on
  24.04 the tree stays exactly as upstream ships it.

- **A stale cache produces the same message.** `linux-config.sh` only does `mkdir -p build; cd build; cmake ..` —
  it never wipes — so a configure that ran before the dependency was present
  caches `Boost_DIR:PATH=Boost_DIR-NOTFOUND`, and **CMake never re-searches a
  cached NOTFOUND**. `./session-scripts/build-sonicpi-46.sh clean` removes the
  build directory; `build` also detects this particular poisoning and clears it
  automatically.
- **The PipeWire *runtime* tools are dependencies too, and they are not build
  deps.** `start-46.sh` and `link-outs.sh` drive the graph through `pactl`
  (`pulseaudio-utils`) and `pw-link` (`pipewire-bin`). Leaving them out gives a
  build that compiles perfectly and then fails at launch with *"no default sink
  — is PipeWire running?"* on a machine where PipeWire is running fine: `pactl`
  simply is not installed, and with stderr suppressed its absence looks exactly
  like an empty answer. `deps` now installs `pipewire pipewire-pulse
  wireplumber pipewire-bin pulseaudio-utils`, and the launcher checks for the
  binaries before it touches anything.
- **Skip `pipewire-jack` only if you intend to run real jackd.** 4.6 detects
  PipeWire with `which pw-link` and then *will not start jackd for you* — it
  runs scsynth through `pw-jack`. Without that binary the launch is broken in
  a confusing way.
- On Debian the Qt dev packages are `libqt6svg6-dev` / `libqt6opengl6-dev`; on
  Ubuntu 24.04 the same files come from `qt6-svg-dev` / `qt6-base-dev`.

Binary lands at `~/src/sonic-pi/app/build/gui/sonic-pi` — note the `gui/`
subdirectory, which is what `start-46.sh` launches. Both scripts default to
`~/src/sonic-pi` and honour `$SONIC_PI_SRC`; they must agree, since one
produces the binary the other runs. scsynth is the **system** one
(`/usr/bin/scsynth`, 3.13.0) — on Linux `Paths.scsynth_path` is just
`"scsynth"` from PATH.

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
./session-scripts/start-46.sh --production   # hall: 12 outputs on the Focusrite 18i20
./session-scripts/start-46.sh --simulation 2  # a laptop's built-in stereo
./session-scripts/start-46.sh --production 8  # a partially patched hall rig
```

**Production's interface is the Scarlett 18i20, found by name pattern** —
same idea as the UMC above, so it doesn't depend on whatever WirePlumber
happened to leave as the system default. It needs its ALSA profile switched
once: `pactl set-card-profile alsa_card.usb-Focusrite_Scarlett_18i20_USB_*-00
pro-audio` (WirePlumber remembers this per card and reapplies it on
reconnect/reboot — check with `cat ~/.local/state/wireplumber/default-profile`).
That profile exposes 20 discrete `playback_AUX0..19` ports, which are raw PCM
channels 1-20 in order (`AUX0` = PCM 1, etc). **Do not trust PipeWire's own
"Line Output N+M" labels for these** — they come from ACP's generic
profile-set guessing and were wrong on this device. Nor is the `scarlett2`
kernel driver's own control naming (`amixer -c <card> controls | grep -E
"Line [0-9]+ \("`) fully trustworthy either — it labels `AUX6/7` as
"Headphones 1 L/R", which reads as "not a real output," but on *this specific
unit* channels 1-8 are all wired to real rear analog jacks regardless of that
label. **The only thing that settled it was playing a tone on each port and
listening** — see the per-channel tone test below. Confirmed 2026-09-16:

| ports | confirmed by ear |
|---|---|
| `AUX0`–`AUX7` | the 8 real rear analog outs, in use |
| `AUX8`–`AUX9` | front headphone jack ("Headphones 2") — silent, not wired to anything |
| `AUX10`–`AUX11` | S/PDIF — untested, not currently used |
| `AUX12`–`AUX15` | ADAT channels 1-4 — confirmed via the hall's ADAT expander (a Behringer Ultragain, first 4 outputs) |
| `AUX16`–`AUX19` | ADAT channels 5-8 — wired in software, **untested**, only relevant above `--production 12` |

So `start-46.sh` excludes only `AUX8`–`AUX11` (the unused headphone pair and
S/PDIF) from production, not the wider range once assumed from the driver
label alone. `--production 12` (the default) is `AUX0..7` + `AUX12..15` — all
8 analog outs plus the expander's first 4 channels.

> **A second, independent surprise, found the same way**: the 18i20 also has
> its own internal source-routing matrix — every physical output (analog,
> S/PDIF, ADAT) has an `amixer` `"... Playback Enum"` control choosing what
> feeds it, separate from which raw PCM channel PipeWire thinks it's writing
> to. `Analogue Output 01-10` happened to already point at `PCM 1-10` on this
> unit, but `ADAT Output 1-8` did **not** point at `PCM 13-20` — every ADAT
> tone test was silent even though PipeWire, ALSA channel count, and
> mute/volume were all correct, because the matrix had those 8 outputs
> pointed at other inputs/PCM channels entirely. `start-46.sh`'s
> `fix_focusrite_adat_routing()` sets all 8 to `PCM 13`..`PCM 20` on every
> production run — it's idempotent, but do not assume it "must have stuck"
> from a prior run; this is exactly the kind of state a Focusrite Control
> change (by anyone, on any OS) or a firmware update could silently revert.

Without a number, **`--simulation` degrades to whatever the sink actually has**
— plug nothing in and it warns, drops to 2, and sets `xen_rig_outputs` and
`num_outputs` to match, so the piece folds its drawing onto the two speakers
that exist rather than drawing into channels that don't.

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

> **Channel order still relies on `pw-link` emitting ports in ascending
> order**, which it has for both the UMC and the Focusrite's `pro-audio`
> profile (checked 2026-09-16 — the string ordering of the 18i20's 20 `AUX*`
> ports is ascending), but the tool does not guarantee it. That is a *port
> naming* check, not proof that `AUX4` is wired to hall channel 5 — do the
> physical tone test below before trusting either.

**Per-channel tone test — do this before any real hall run, and again after
any firmware/driver update or Focusrite Control change.** Confirms which
physical jack (or ADAT-expander channel) each port actually reaches, since
neither PipeWire's ACP labels nor the driver's control names are a
substitute for listening. PipeWire holds the card exclusively, so raw ALSA
tools like `speaker-test -D hw:2,0` fail with "device busy" while it's
running — and **`pw-play --target <sink>:<port>` does not work either**: despite
looking like it should, `--target` only accepts a node name/serial, not a
port suffix, so it silently falls back to auto-connect and every "test"
lands on the same one or two ports. The only mechanism that actually works
is the same one `link-outs.sh` uses: start the stream with `--target 0`
("don't auto-link"), then `pw-link` its port to the exact one under test:

```sh
SINK="alsa_output.usb-Focusrite_Scarlett_18i20_USB_<serial>-00.pro-output-0"
BEEP="/path/to/a/short/mono/wav"   # a mono file - a stereo one creates two ports

for aux in AUX0 AUX1 AUX2 AUX3 AUX4 AUX5 AUX6 AUX7 AUX12 AUX13 AUX14 AUX15; do
  pw-play --target 0 --channels 1 "$BEEP" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 20); do  # wait for its port to appear, up to ~1s
    pw-link -o 2>/dev/null | grep -qx "pw-play:output_MONO" && break
    sleep 0.05
  done
  pw-link "pw-play:output_MONO" "$SINK:playback_$aux" \
    && echo "=== $aux — listening now ===" \
    || echo "=== $aux — LINK FAILED ==="
  wait "$pid" 2>/dev/null
  sleep 0.5
done
```

Walk the room (or the rack, for the ADAT expander) confirming each one
against `monitors.tsv`, in order. Write the confirmed mapping down once
verified; until then, treat any AUX-to-jack table as a hypothesis, not a
fact — the one above only became trustworthy after exactly this test.

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

## 8. Breath length and the M=0 balance

Both of these are desk knobs whose full reasoning would not fit in
`sonic-pi-buffer.rb` — the desk has a hard 16320-byte ceiling (see Prerequisites,
"The desk has a hard size ceiling"), so the long form lives here.

### 8a. Breath length — `xen_cycle_dur`

`cycle_dur` was a literal `16.0` next to a literal `m0_center = 8.0`. It is now
`get(:xen_cycle_dur, 16.0)`, with `m0_center` **derived** as `cycle_dur / 2`.
Deriving it is the point: the two numbers drifting apart is exactly what a
cycle knob invites, and holding M=0 at the midpoint is also what keeps the two
granular phases equal — both reduce to `cycle_dur / 2 - 2.425`.

It is read at the top level, so it takes effect on Run, not on a save.

**The beds are stretched, not looped.** The atmosphere has to hold the whole
cycle, and a bed is one slice — 16 s as built (`atmos_slice.py`, `SLICE_S`).
Playing it twice would leave a butt joint mid-breath, and each slice is faded
250 ms in and out, so the seam would dip to near-silence; at 32 s that seam
lands exactly on M=0. So the slice is stretched instead, with `pitch_stretch:`
rather than `rate:`.

That distinction matters. `rate:` is varispeed — at 32 s it would drop the
whole bed an octave, and `xen_atmos_f0` is MIDI 48 because 131 Hz is where the
material's energy was *measured* to sit. Varispeed walks the material out from
under every tuned number in the piece. `pitch_stretch:` applies the same rate
and compensates the transposition back, so the spectrum stays put.

The cost is that the compensation is SuperCollider's `PitchShift`, a granular
shifter on a 0.2 s window — there is no phase vocoder anywhere in Sonic Pi.
On broadband breath material a large correction smears, so the stretch is
refused past 4x. At `cycle_dur == bed_len` it resolves to rate 1.0 / pitch 0,
i.e. the default path is unchanged.

Envelopes follow the stretch without help: `sustain: -1` resolves inside the
player synthdef against `(1/rate) * buf-dur` (`samplers.clj:114-115`), so the
1 s `atmos_margin` fades still land on the cycle's edges at any stretch.

| `xen_cycle_dur` | rate | pitch | phases each |
|---|---|---|---|
| 16 s (default) | 1.000 | +0 | 5.575 s |
| 24 s | 0.667 | +7 | 9.575 s |
| 32 s (current) | 0.500 | +12 | 13.575 s |

M=0 itself does **not** stretch — `m0_dur`, `m0_tail` and the accent are
absolute, so a longer breath means longer phases around the same impact.
The floor is ~4.85 s of fixed costs, so nothing under about 6 s runs.
`xen_atmos_rotate_period` (41 s) was chosen coprime with 16; re-check it if
you change the cycle.

### 8b. Why M=0's funnel needed `xen_m0_floor_amp`

M=0 is two gestures on two disjoint speaker sets: the **scalpel**, HPF'd to
2960–4186 Hz with +9 dB at 8372 Hz, on `quad_ceil` = 1, 2, 11, 12; and the
**funnel**, LPF'd at 466 Hz, on `quad_floor` = 5, 6, 7, 8. Nothing granular
from M=0 reaches 9 or 10 at all.

The in-situ tuning of 2026-09-16 raised `xen_atmos_amp` 0.5 → 1.30 (+8.3 dB)
and introduced `xen_grains_amp` at 0.75 (−2.5 dB). Net: **−10.8 dB of funnel
against bed**, in the one band the two share — the beds are 81.5 % 125–500 Hz
with +10 dB resonances at 131/262/392/523 Hz, and every one of channels 5–8
carries a bed. The scalpel never noticed: it lives three octaves above
anything else on its speakers. So M=0 came apart — present at the hexagons'
far ends, gone at the feet.

It is *not* a routing fault. `pw-link` (SC `out_1..12` → `AUX0-7` + `AUX12-15`),
the Focusrite matrix (`Analogue 01-10` → `PCM 1-10`, `ADAT 1-8` → `PCM 13-20`)
and every Line Out mute/level were checked and are correct. Nor is the bed
literally masking it — measured, the funnel is still +14.3 dB over the bed
below 466 Hz. The mechanism is the 10.8 dB relative collapse plus the band
asymmetry: sub-466 Hz is barely localizable and sits where the ear is least
sensitive, while the scalpel is 3–8 kHz with nothing competing.

**The fix is on the funnel's own knob**, not by undoing the tuning:
`xen_m0_floor_amp` 1.0 → 2.0. The tanh's `amp` is applied to the FX *output*,
after the saturator (`fx.clj:322-326`), so it is clean linear gain rather than
drive — increases work, which is not true of the amps upstream of the
distortion.

`xen_grains_amp` stays at 0.75 deliberately. Raising it would lift the funnel
by the same amount, but it lifts the clouds and the scalpel with it, and the
clouds-vs-bed balance is what was set by ear.

**There is a hard ceiling.** These outputs bypass the master limiter, so the
burst's absolute peak is the constraint, and it depends on the *product*
`xen_m0_floor_amp × xen_grains_amp`, which must stay under 1.66:

| atmos | grains | floor | funnel/bed | burst peak |
|---|---|---|---|---|
| 0.50 | 1.00 | 1.0 | +25.1 dB | 0.602 |
| 1.30 | 0.75 | 1.0 | +14.3 dB | 0.451 |
| **1.30** | **0.75** | **2.0** | **+20.3 dB** | **0.903** |
| 1.30 | 0.75 | 2.216 | +21.2 dB | 1.000 — clips |

So this knob is worth 6.0 of the 10.8 dB and no more; the funnel lands 4.8 dB
under where it sat before the tuning. The rest is not available at this bed
level on any knob. Closing it needs `xen_atmos_amp` back toward 0.85, or
`xen_atmos_spectral` down from 10.0 — those resonances sit directly on the
funnel's band and cost nothing elsewhere, which is the one to try first.

### 8c. Inhale vs exhale beds — `xen_atmos_inhale_amp` / `xen_atmos_exhale_amp`

`xen_atmos_amp` moves all four beds together. These two trim the hexagons
against *each other* on top of it — the same arrangement as `xen_m0_ceil_amp`
/ `xen_m0_floor_amp`, and for the same reason: inhale and exhale are not the
same gesture and do not compete with the same thing. The inhale hexagon (1–6)
shares its channels with the inhale clouds, the exhale hexagon (7–12) with the
exhale clouds, and those two phases had never been balanced against each other
at all.

They key off the insertion order of `atmos_beds` — `inh_a, inh_b, exh_a,
exh_b` — which is the same index the spectral partials are taken from, so
`i < 2` is the inhale hexagon.

**The bed itself has plenty of room.** It runs into `tanh krunch: 0.25` with
no `amp:`, which ceilings it at 0.925, and the saturator is gentle over the
useful range — measured through the real chain (source → `band_eq` 131 Hz
Q 16.7 +10 dB → tanh):

| `inhale_amp` | asked | bed peak | realised |
|---|---|---|---|
| 1.00 | +0.0 dB | 0.432 | +0.0 dB |
| 1.41 | +3.0 dB | 0.567 | +2.9 dB |
| 2.00 | +6.0 dB | 0.709 | +5.8 dB |
| 4.00 | +12.0 dB | 0.893 | +11.0 dB |

**The channel is what runs out, not the bed.** Channels 1–6 also carry the
inhale clouds, and the two arrive through separate `sound_out` chains that sum
*after* both tanhs — nothing catches that sum, these outputs bypass the master
limiter. The clouds peak ~0.4875 there (0.65 at `master_amp` 1.0, × the 0.75
`xen_grains_amp`), so:

| `inhale_amp` | bed peak | coincident | power sum |
|---|---|---|---|
| 1.00 | 0.432 | 0.919 | 0.651 |
| 1.19 | 0.500 | 0.987 | 0.698 |
| 1.26 | 0.520 | 1.007 ✗ | 0.713 |
| **1.41** | **0.567** | **1.054 ✗** | **0.748** |

**1.19 (+1.5 dB) is the last setting that cannot clip. The piece runs at 1.41
(+3.0 dB) anyway** — chosen by ear on 2026-09-16 with the overflow understood
and accepted. Above 1.19 the overflow only happens when a grain peak and a bed
peak land in the same sample; the power sum stays around 0.75, so it is
intermittent rather than constant — but there is no limiter to catch it when
it does, and it clips the converter directly.

If it turns out to be audible as clipping rather than as weight, the ways back
are `xen_grains_amp` down (which undoes the clouds-vs-bed balance set by ear),
`xen_master_amp` under 1.0, or simply 1.19.

Getting more than +1.5 dB means giving something back: `xen_grains_amp` down
(which undoes the clouds-vs-bed balance set by ear), or `xen_master_amp` below
1.0. The inhale channels were already at 0.92 before this knob existed; it
does not create the headroom problem, it just spends what was left.

### 8d. M=0's tail — stretch, thinning, and the handover to the exhale

The last half of M=0 now *dissolves* rather than just getting quieter: each
grain is played slower so it lasts longer, the rain thins in exact proportion,
and the whole cloud fades out as the exhale arrives.

**It cannot be done in Sonic Pi.** `rate` is an `:ir` parameter in the player
synthdef (`samplers.clj:47`) — fixed when the synth starts, not modulatable —
so a playing sample cannot be slowed down. M=0 is a pre-rendered burst anyway
(`render_m0.py`, because ~320 grain events/second killed the scheduler), so
the stretch belongs in the render, where the grains still exist individually.

In the tail, with `u` the tail's progress 0→1:

```
stretch  s(u) = STRETCH_END ** u          exponential: stretch is a ratio,
                                          so equal steps are equal musical steps
rate          = drawn_rate / s(u)         lower rate, longer grain
density       = lam * exp(-K_DENS*dt) / s(u)
```

**The 1/s on the density is the whole point, not decoration.** Grains `s` times
longer arriving `s` times more rarely occupy the same total sounding time, so
the texture keeps its continuity while the events inside it become long and
slow. Without it, `s` times longer at the same rate is `s` times the overlap,
and the tail turns to mush.

At `STRETCH_END = 4.0`, measured on the floor layer:

| t | stretch | grain length | density |
|---|---|---|---|
| 0.45 s | 1.00x | 188 ms | 1.000 |
| 1.10 s | 1.41x | 266 ms | 0.324 |
| 1.75 s | 2.00x | 376 ms | 0.105 |
| 3.05 s | 4.00x | 753 ms | 0.011 |

`RENDER` is now **derived**, not the old fixed 3.60 s: the slowest grain is the
longest source played at the lowest rate the stretch produces, and it can start
as late as `span`. It comes out at 4.75 s. Guessing it truncates exactly the
grains the gesture is about, silently — the mixdown just stops writing past the
end of the buffer.

**The audible fade is `xen_m0_fade`, not the render.** Both M=0 chains saturate
(distortion, or hpf × 6, then tanh), and a saturator flattens any level change
upstream of it — so the cosine taper in `render_m0.py` keeps the rendered
material honest but is mostly eaten. The fade the room hears is the `control`
on the tanh's `amp`, after saturation. It was a flat 5.0 s, chosen when the
overlap was wanted ("a cross-fade, not a cut"); at a 32 s cycle that is 37 % of
the 13.575 s exhale spent with M=0 still underneath. 2.5 s lets the stretched
tail dissolve and then gets out of the way. It does not affect cycle timing —
both halves ramp inside `in_thread`.

**Two bugs fixed in passing.** `LAYERS["ceil"]["sub"]` was `inhale/high`; the
folder is `inspir/high`, so `pool_for()` returned nothing and the script
exited on "no files for layer ceil" — it could not have run at all as it
stood. And `random.seed(hash((layer, v)))` was not reproducible: string
hashing is salted per process unless `PYTHONHASHSEED` is set, so every run
produced different variants. Now `zlib.crc32`, so a render is repeatable.

Dry peaks rose (ceil 0.68 → 0.95, floor 2.68 → 3.37) because the variants are
different draws, but the saturators absorb it: the floor's tanh output went
0.8597 → 0.8693, +0.1 dB, so `xen_m0_floor_amp 2.0` still peaks 0.913 and the
level decisions in 8b stand unchanged.

### 8e. Confining M=0 to one quad — `xen_m0_confine`

M=0 normally splits across two disjoint sets: the scalpel on `quad_ceil`
(1, 2, 11, 12) and the funnel on `quad_floor` (5, 6, 7, 8). `xen_m0_confine`
puts **every M=0 grain on 5-8 and nothing anywhere else** — `quad_ceil` is
simply pointed at `quad_floor`.

The atmosphere's M=0 accent (`m0_up`, `m0_pz`) does *not* move. It follows a
separate `quad_accent`, fixed at 1, 2, 11, 12, because it is a bed and this
knob is about the granular layer.

**It is a level change, not just a placement one.** Both halves then land on
the same four channels and sum there, on outputs that bypass the master
limiter:

| | ch 1,2,11,12 | ch 5,6,7,8 | ch 9,10 |
|---|---|---|---|
| confine off | scalpel 0.413 + bed | funnel 0.913 + bed → **power 1.074** | bed only |
| confine on | bed + accent only | scalpel 0.292 + funnel 0.645 + bed → power **0.907** | bed only |

Without compensation the confined sum is a **power** of 1.151 — clipping before
any coincident peak. So each half is scaled by `1/sqrt(2)` automatically. That
is the same constant-power reasoning as `bed_scale`: two decorrelated sources
on one channel at `1/sqrt(2)` carry the total power one of them carried alone.
Coincident peaks still reach 1.50, so pull `xen_m0_floor_amp` down as well if
it reads as clipping rather than as weight.

**Note the confine-off row.** Channels 5 and 6 already sit at a power sum of
1.074 with the funnel at 2.0 against an inhale bed at `xen_atmos_inhale_amp`
1.41. Those two were sized separately — the bed against the inhale *clouds*
(8c), the funnel against the bed at M=0 (8b) — and at M=0 they coincide on the
same two channels. Confining is the one configuration that improves it, by
spreading the same energy over a `1/sqrt(2)` trim.

What it costs, by construction, is the funnel-vs-scalpel separation: the
sub-466 Hz weight at the feet and the 3-8 kHz scalpel arrive from the same
four cabinets, so M=0 stops being two gestures in two places and becomes one
event in one. That is the trade, taken deliberately.

### 8f. `xen_out_headroom` — the only trim that catches the sum

Every layer has its own `tanh` soft ceiling, but they reach the same hardware
output through **separate `sound_out` chains** and sum *after* all of them,
with no limiter. The HEADROOM note in section 5 says so; this is what to do
about it.

**Why no existing knob could fix a clipping channel.** `xen_atmos_amp`,
`xen_atmos_inhale_amp`, `m0_amp` and `xen_master_amp` all sit *before* a
saturator, so they flatten instead of trimming. Measured on channel 5 at M=0,
sweeping the bed down while the M=0 pair stayed put:

| `xen_atmos_inhale_amp` | bed peak | summed peak |
|---|---|---|
| 1.41 (+3.0 dB) | 0.858 | 1.314 |
| 1.00 (+0.0 dB) | 0.760 | 1.185 |
| 0.60 (−4.4 dB) | 0.558 | 1.073 |

A 7.4 dB cut moved the bed's peak by 3.7 dB and the sum was still clipping.
Trimming M=0 instead was no better: even `xen_m0_floor_amp` at 0.85 — *below*
its original 1.0, giving up everything 8b won — only reached 0.960, because
the bed alone peaks 0.858.

**The fix is a trim applied to the `tanh`'s `amp` in every chain** — the beds,
the clouds, the M=0 accent and both M=0 halves — i.e. after all the
saturation, where it is plain linear gain on what actually reaches the bus.
Because it scales all of them by the same factor, every ratio tuned by ear is
preserved exactly; it trades absolute level only, which the amps give back.

Measured on channel 5 at M=0, true summed peak across all 8 M=0 variants:

```
xen_out_headroom 1.00  ->  1.314   clips
xen_out_headroom 0.75  ->  0.986   ok    (-2.5 dB overall)
```

**Sum-of-peaks vs. true sum.** Earlier sections quote sum-of-peaks, which
assumes every source peaks in the same sample. Measured, the true sum runs
about 87 % of that (1.314 against 1.504), so those figures were conservative —
but the 0.567 bed peak in 8c was an *under*-measurement taken from one window;
across the file it reaches 0.858, which is why 8c's numbers looked safer than
they were.

The inhale phase (bed + clouds on the same channels) is estimated at 1.009
sum-of-peaks after the trim, so ~0.88 true — but that one is an estimate, not
a measurement: the clouds are synthesised at runtime from the grain pools and
cannot be measured statically the way the rendered beds and bursts can.

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
  build-sonicpi-46.sh              builds Sonic Pi 4.6.0 (deps|clone|build|clean|all)
  start-46.sh                      --production | --simulation: desk, routing, launch
  link-outs.sh                     repatches scsynth onto the interface (start-46 calls it)
  check-session.sh                 is it healthy right now? (delivery, not settings)
  setup-audio.sh                   5.0-era PipeWire pinning; REFUSES to run on a 4.6 setup
  revert-*.sh                      5.0-era; kept for reference only
  restore-sonicpi-config.sh        puts audio-settings.toml back
  set-buffer-2048.sh, try-alsa.sh  5.0-era experiments; kept for reference only
  start-session.sh                 the 5.0 launcher, superseded by start-46.sh
monitors.tsv                       physical positions of the 12 monitors (cm)
nodes.tsv                          theoretical breathing path, 11 nodes
TODO.md                            open tuning items
```
