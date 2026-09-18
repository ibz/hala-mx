# Extreme Xenakian Installation - Hala MX (12 Channels)
#
# LIBRARY - not configured here.
# All runtime parameters are set from the Sonic Pi workspace:
#
#   set :xen_rig_outputs, 4        # 12 = Hala MX, 4 = UMC404HD in the studio
#   set :xen_focus, :inhale        # :inhale :exhale :m0 :m0_ceil :m0_floor :all
#   set :xen_layers, :both         # :both :atmos (beds only) :grains (granular only)
#
# They're read at the start of every breath, so they can change on the fly.

# project_dir: set by the workspace via `set :xen_project_dir` (see
# sonic-pi-buffer.rb) from wherever it points `piece` at. run_file doesn't
# execute this file as a real Ruby file, so __FILE__ can't self-locate here -
# the fallback below is only a safety net if this is ever run standalone.
project_dir = get(:xen_project_dir, "/home/mx/src/hala-mx")
path_base   = project_dir + "/output_xenakis_installation/"
path_inhale = path_base + "inhale/"
path_blast  = path_base + "sonic_blast_m0/"
path_exhale = path_base + "exhale/"

# run_tag: also from the workspace, one value per Run (see sonic-pi-buffer.rb
# for why). Every named live_loop below carries it, so the loops of a new Run
# never collide with the still-dying loops of the previous one - a collision
# gets the new loop killed silently, before its block ever runs.
run_tag = get(:xen_run_tag, 0)

use_bpm 60

# Lookahead. This is ALSO how many grain triggers sit queued inside scsynth
# at any moment, and that is what makes Stop dangerous: on Stop the group dies
# first, every already-queued /s_new then fails ("Group N not found"), and
# those nodes never get an /n_go - so they stay in the group's @pending_nodes
# forever. Group#initialize (group.rb:26) registers an on_destroyed callback
# that emits one synthetic /n_end per pending node, and it runs ON Sonic Pi's
# event-consumer thread, pushing into the same 50-slot SizedQueue that thread
# is the only consumer of (incomingevents.rb:23). Enough pending nodes and the
# consumer blocks on its own queue for good: the scsynth reader stops being
# read, Node/Group creation blocks, and no later Run can start a live_loop -
# silent, no error, until Sonic Pi is restarted.
#
# At 2.0 that was ~76 grains/s x 2s ~= 150 stranded nodes per Stop. 1.0 halves
# it. The original reason for a large value is gone: the M=0 rain that could
# not be queued at 0.5s is pre-rendered now (8 triggers, not ~144).
#
# NOTE: `use_sched_ahead_time`, NOT `set_sched_ahead_time!`.
# The `!` variant writes to a global state, and reading it back
# (__current_sched_ahead_time, runtime.rb:507) calls `.val` on the result
# WITHOUT checking for nil - hence "undefined method `val' for nil". The
# variant without `!` sets a thread-local, which is checked FIRST (`||`) and
# can never be nil. System thread-locals are inherited, so the live_loop and
# all of its per-channel threads pick it up automatically.
use_sched_ahead_time 1.0

# 0. GRAIN POOLS - A SINGLE BUFFER PER FAMILY
#
# Each family is concatenated by build_pools.py into a single WAV, plus a
# cut-table. Sonic Pi allocates one scsynth buffer per FILE and never frees
# it; with one file per grain, preloading meant thousands of OSC allocations
# (each with a 5 s timeout) that scsynth couldn't keep up with. This way, all
# the material - ~10,700 grains - lives in 5 buffers, and a grain is picked
# with start:/finish:, exactly the mechanism `onset:` uses internally.
# There's no pool limit anymore: ALL the material is used.
path_concat = path_base + "concat/"

load_pool = lambda do |name, long_only = false|
  wav = path_concat + name + ".wav"
  txt = path_concat + name + ".txt"
  unless File.exist?(wav) && File.exist?(txt)
    raise "Missing pool #{name} - run: python3 build_pools.py"
  end
  cuts = File.readlines(txt).map do |line|
    a, b, ms = line.split
    { start: a.to_f, finish: b.to_f, ms: ms.to_f }
  end
  # long_only: at the same density, long grains overlap more, so the texture
  # coheres - with no extra events. Only used for exhale.
  if long_only
    threshold = cuts.map { |t| t[:ms] }.sort[cuts.size / 2]
    cuts = cuts.select { |t| t[:ms] >= threshold }
  end
  { wav: wav, cuts: cuts }
end

# INHALE descends and darkens -> the material moves from "high" to "mid".
pool_inhale_high = load_pool.call("inhale_high")
pool_inhale_mid  = load_pool.call("inhale_mid")
# EXHALE rises and opens up -> the pressure turns into a shatter.
pool_exhale_pressure = load_pool.call("exhale_low_pressure", true)
pool_exhale_shatter  = load_pool.call("exhale_shatter", true)
# M=0 is the pivot point; nothing is directed here.
pool_blast = load_pool.call("blast")

# 0d. THE M=0 BURST - PRE-RENDERED OFFLINE
# ~144 grains in 0.45 s overran the Sonic Pi scheduler. The burst is rendered
# by render_m0.py, one file per channel, in several variants so M=0 isn't
# identical every breath. Here it comes down to 8 triggers instead of ~144.
# The M=0 density is changed in render_m0.py, then the script is run again.
path_m0 = path_base + "m0_render/"
m0_variants = lambda do |layer|
  Dir[path_m0 + layer + "_v*_ch0.wav"].sort.map do |f|
    v = File.basename(f)[/_v(\d+)_/, 1]
    (0...4).map { |c| path_m0 + layer + "_v" + v + "_ch" + c.to_s + ".wav" }
  end
end
m0_ceil_variants  = m0_variants.call("ceil")
m0_floor_variants = m0_variants.call("floor")
raise "Missing M=0 renders - run: python3 render_m0.py" if m0_ceil_variants.empty?

# 0f. THE ATMOSPHERE - a rotating set, loaded one cycle ahead
# 434 files, 1.9 GB: CANNOT be preloaded. We keep a small set in memory and
# rotate it. Sonic Pi allocates one buffer per file and never frees it on its
# own (@buffers has no eviction), so without `sample_free` we'd accumulate
# ~225 buffers per hour and hit the scsynth limit of 4096 in ~2.5 hours.
# Loading happens one cycle AHEAD, in an administrative thread, so there's
# never any silence; Promise#get releases the GIL while it waits, so the
# granular threads keep going during the load.
path_atmos = path_base + "atmos/"
atmos_folders = {
  inh_a: "inhale/inhale_doppler_a_front",
  inh_b: "inhale/inhale_doppler_b_back",
  exh_a: "exhale/breathing_front_8_doppler_a_ch",
  exh_b: "exhale/breathing_rear_8_doppler_b_ch",
  m0_up: "m0/above_inhale",
  m0_pz: "m0/above_3_upper_piezzos",
}
atmos_lists = {}
atmos_folders.each do |k, sub|
  atmos_lists[k] = Dir[path_atmos + sub + "/*.wav"].sort
  raise "Atmos: no file in #{sub}" if atmos_lists[k].empty?
end
puts "XENAKIS: atmos #{atmos_lists.values.sum(&:size)} files in #{atmos_lists.size} families"

# THE SLICE LENGTH, measured rather than assumed - the beds are stretched to
# the cycle further down and this is what they are stretched FROM.
# atmos_slice.py cuts every family at the same SLICE_S, so one file per
# family is enough to know it; every family is checked against that anyway,
# because a half-rebuilt atmos/ directory is exactly the state this catches.
# The M=0 accents are included: they are read fractionally (finish: 0.35), so
# their length matters too even though they are not beds.
bed_len = sample_duration atmos_lists[:inh_a].first
atmos_lists.each do |k, l|
  d = sample_duration l.first
  raise "Atmos: #{k} slices are #{'%.3f' % d} s but #{'%.3f' % bed_len} s elsewhere. " \
        "atmos/ is half-rebuilt - re-run atmos_slice.py." if (d - bed_len).abs > 0.01
end

# A set = one file from each family.
atmos_set = lambda { atmos_lists.map { |k, l| [k, l.choose] }.to_h }

# The set for the FIRST cycle loads synchronously, otherwise there'd be
# nothing to play.
atmos_initial = atmos_set.call
atmos_initial.each_value { |f| load_sample f }
set :atmos_n0, atmos_initial
set :atmos_n1, nil

# 0e. PRELOADING
# Now there are only 5 large buffers + the M=0 renders, so batching is no
# longer needed.
pools = [pool_inhale_high, pool_inhale_mid, pool_exhale_pressure, pool_exhale_shatter, pool_blast]
puts "XENAKIS: preloading #{pools.size} pools (#{pools.sum { |b| b[:cuts].size }} grains) + M=0 renders..."
pools.each { |b| load_sample b[:wav] }
(m0_ceil_variants + m0_floor_variants).flatten.each { |f| load_sample f }
puts "XENAKIS: loaded"

# 0c. THE INHALE'S STOCHASTIC CLOUDS
# Two masses that start at the extremes, head toward the center, and cross
# each other.
# The POSITIVE mass is dense and travels the whole way (1-3 -> 4-6).
# The NEGATIVE mass is sparse and barely moves (2-4 -> 3-5).
# At t = 0.5 the intervals coincide exactly (2.5-4.5, center 3.5): that's
# where they annihilate each other - M=0 as a spatial event, not just an
# impact.
# One cycle = 16.0 s by default, exactly as long as one atmos slice. The
# granular phases were stretched to fit. The densities (lambda) DIDN'T
# change: being grains/second, the texture stays the same and so does the
# scheduler's event rate - only the gesture takes longer. The ramps (pitch,
# lpf, blend, entry_amp) are normalized on f = t/duration, so they stretch on
# their own - which is the property that makes the length a knob at all.
#
# READ ONCE PER RUN. This line is top-level, like xen_density below, so
# changing it needs Stop + Run - it is not a live tweak the way the amps are.
cycle_dur    = get(:xen_cycle_dur, 16.0)
# The beds' fade time at each end of the cycle. It used to be the granular
# material's margin too - grains sat INSIDE the beds, one atmos_margin clear
# of each edge - and that pair of margins is what xen_void now sets; see the
# void derivation below.
atmos_margin = 1.0

# THE BEDS OVERLAP ACROSS THE CYCLE BOUNDARY.
#
# A bed is one slice pitch_stretched over its whole life, with attack:
# atmos_margin and release: atmos_margin, and the cycle's sleeps sum to
# exactly cycle_dur (README 8a). So while a bed lasted exactly cycle_dur, the
# outgoing set's RELEASE and the incoming set's ATTACK met END TO END at the
# boundary rather than overlapping: both sets passed through zero at the same
# instant, once a breath, and that zero was most of what the pause at the
# boundary actually was. The grains were the other half.
#
# Giving a bed one atmos_margin MORE life turns that into a cross-fade: the
# outgoing release now runs over the incoming attack. Cheap, because it adds
# no messages - the same twelve triggers happen at the same instant they
# always did, and only the previous set's nodes linger a second longer.
#
# What it does NOT give is a constant sum: two envelopes of the same shape
# crossing mid-fade leave a dip (-3 dB in power at the midpoint if the curve
# is linear, these beds being decorrelated and therefore summing by power).
# A dip in one layer while the other plays through it is not a hole, which is
# what it replaces. env_curve on the two `sample` calls below is the lever if
# it ever wants shaping.
#
# THE ONE THING IT COSTS: bed_dur is no longer cycle_dur, so the stretch is no
# longer exactly 1.0 when the cycle matches the slice length - at 16 s it is
# 1.06, i.e. PitchShift now engages (by +1.0 semitone) where the default path
# used to be untouched. At the 32 s this piece runs, the correction goes from
# +12 to +12.5 semitones and the difference is nothing. Set this to 0.0 to get
# the old arithmetic back exactly, and the zero-crossing with it.
bed_overlap = atmos_margin
# M=0 falls exactly at the midpoint of the cycle - the same point as node S6
# and the geometric midpoint of the bridge between the hexagons (N_6, Y = 500
# cm). The atmos and granular centers have to coincide.
#
# DERIVED, not written down. It used to be a literal 8.0 sitting next to a
# literal 16.0, and the two drifting apart is exactly the failure a cycle
# knob invites. Holding it at the midpoint is also what keeps the two
# granular phases equal: both reduce to cycle_dur / 2 - 2.425 (see the
# inhale_dur / exhale_dur derivation further down).
m0_center    = cycle_dur / 2.0

# THE BEDS STRETCH TO FIT, so the cycle is free of the slice length: any
# duration works, not just a multiple of 16 s.
#
# pitch_stretch, NOT rate. Both stretch the buffer, but rate is varispeed -
# at a 32 s cycle it would drop the whole bed an octave, and spec_f0 below is
# MIDI 48 because 131 Hz is where the material's energy was MEASURED to sit.
# Varispeed would walk the material out from under every tuned number in the
# piece. pitch_stretch applies the same rate and then compensates the
# transposition back with pitch:, so the spectrum stays where it was
# measured and the resonances keep landing on it.
#
# The cost is that pitch: is SuperCollider's PitchShift - a granular shifter
# on a 0.2 s window, not a phase vocoder (there is no PV_/FFT FX in Sonic
# Pi at all; see the spectral note further down). On broadband breath
# material a large correction smears and warbles, so the stretch is bounded
# below. At cycle_dur == bed_len this used to resolve to rate 1.0 and a 0
# semitone compensation - PitchShift doing nothing at all - but bed_overlap
# ended that: the bed is a second longer than the cycle, so the shortest
# stretch is now 1.06 and the shifter is always in circuit. See bed_overlap.
#
# pitch_stretch takes BEATS; use_bpm 60 at the top of this file makes a beat
# one second, so bed_dur passes straight through.
#
# bed_dur, not cycle_dur: a bed outlives its cycle by bed_overlap so that
# consecutive sets cross-fade instead of both passing through zero at the
# boundary. The stretch follows the bed's real life, or the PitchShift
# compensation below would be correcting for the wrong rate.
bed_dur     = cycle_dur + bed_overlap
bed_stretch = bed_dur / bed_len
bed_semis   = 12.0 * Math.log2(bed_stretch)
if bed_stretch > 4.0 || bed_stretch < 0.25
  raise "xen_cycle_dur #{cycle_dur} s (#{'%.1f' % bed_dur} s of bed) against " \
        "#{'%.3f' % bed_len} s atmos slices is a " \
        "#{'%.2f' % bed_stretch}x stretch (#{'%+.1f' % bed_semis} semitones of PitchShift " \
        "correction). Past 4x that is warble, not atmosphere - re-slice at a length " \
        "closer to the cycle (SLICE_S = HOP_S in atmos_slice.py) and rebuild the pools."
end
# Envelopes follow the stretch on their own: sustain -1 resolves inside the
# player synthdef against (1/rate) * buf-dur, so the atmos_margin fades still
# land on the bed's own edges at any stretch. Nothing here has to scale them.
if bed_stretch != 1.0
  puts "XENAKIS: beds stretched #{'%.2f' % bed_stretch}x " \
       "(#{'%.1f' % bed_len} s slice -> #{'%.1f' % bed_dur} s bed, " \
       "#{'%+.1f' % bed_semis} semitones corrected)"
end
# Density multiplier. Each layer runs clean alone; only beds+grains together
# drive the device below real-time (0.90x at bs=1024, 0.92x at 2048 - barely
# helped by doubling the buffer, so it is voice COUNT, not burst headroom).
# lambda is grains/second and each grain is panned across two channels, so
# 24+8 = 32/s becomes ~64 voices/s created and freed. This scales all of it.
xen_density = get(:xen_density, 1.0)
cloud_positive = { span0: [1.0, 3.0], span1: [4.0, 6.0], lambda: 24.0 * xen_density }
cloud_negative = { span0: [2.0, 4.0], span1: [3.0, 5.0], lambda:  8.0 * xen_density }

# 0c-bis. THE BREATH'S HEIGHT - the only slope that is real
#
# The score sheet annotates the inhale "-25 deg" and the exhale "-30 deg".
# Those are ANGLES ON THE PAGE, not angles in the hall: they are what the
# hall's LENGTH axis measures once an axonometric projection tips it up the
# sheet. Two independent checks say so.
#
#   1. They don't fit. The inhale run S1 -> S6 is 10.20 m horizontally
#      (nodes.tsv). At -25 deg that is dZ = -4.76 m, landing at Z = -0.76 m;
#      the exhale at -30 deg lands at Z = -1.89 m. Both are under the floor.
#   2. They carry no height at all. Reconstruct the drawing's viewpoint
#      (elev ~21 deg, azim ~-49 deg) and the node coordinates reproduce them
#      - the exhale chord S6 -> S11 projects to 30.0 deg on the nose - while
#      S1, S5, S6 and S11 all sit at Z = 4.00 in nodes.tsv. Force every Z in
#      those chords flat and the page angle does not move a tenth of a degree.
#
# The alpha/beta annotation, -12 deg / +12 deg, is the one that means
# something, and it isn't decorative either:
#
#   4.00 m (S1, the theoretical start) - 10.20 m * tan(12 deg)
#     = 4.00 - 2.17 = 1.83 m  ~=  1.80 m, the plane of all twelve monitors
#
# and +12 deg over the exhale's identical run comes back to exactly 4.00 m,
# which is S11's Z. So the breath DESCENDS from the theoretical node height
# onto the physical speaker plane, touches it at M=0 - the one moment the
# piece renders height physically, the funnel at the feet - and rises back.
#
# Until now that descent was a sentence in a comment and nothing else: the
# inhale and the exhale had no elevation cue whatsoever, and the only thing
# drifting downward was the lpf ramp, which darkens as a side effect of
# timbre rather than as a slope anyone set. Below, the angle is voiced.
speaker_z  = 1.80    # monitors.tsv - Z = 180 cm, all twelve
node_z     = 4.00    # nodes.tsv - S1 and S11, the start and the peak
breath_run = 10.20   # m - the S1 -> S6 horizontal run, same as S6 -> S11

# Height is SPECTRUM on this rig and nothing else - no speaker is overhead -
# so the slope is carried by the same Blauert pair M=0 states its "above"
# with (see the ceiling scalpel): MIDI 120 = 8372 Hz reads as above, MIDI
# 103 = 3136 Hz as behind/below. Tilt 1.0 is exactly M=0's chord, tilt 0.0
# is flat. That makes M=0 the full-scale reference for the whole piece: the
# breath can never claim more height than the critical point does.
blauert_hi_note = 120
blauert_lo_note = 103
blauert_hi_db   =  9.0
blauert_lo_db   = -6.0
# Band WIDTH, and the one number in this file that was quietly wrong for a
# long time. The old comment at M=0 read "res = 1/Q: higher = wider band",
# and both bands sat at 0.8 on that understanding. The synthdef says
# otherwise: fx_band_eq is MidEQ(in, freq, rq, db) with `rq = 1 - res`, and
# rq IS 1/Q - so higher res is a NARROWER band, the exact opposite. At 0.8
# these were Q 5.0, about 0.29 octaves: a third of the width they were meant
# to have, and a third of the width Blauert's bands actually are.
#
#   bandwidth_octaves = (2 / ln2) * asinh(1 / 2Q),  Q = 1 / (1 - res)
#   res 0.293 -> rq 0.707 -> Q 1.414 -> 1.000 octave
#
# Blauert's directional bands are broad - they are a property of the pinna,
# not a filter someone chose - so a narrow peak is the wrong shape for the
# cue no matter how much gain it has. Everything Blauert in the piece uses
# this: the M=0 scalpel, the M=0 atmosphere accent, and the ramped pair that
# carries the breath's slope.
blauert_res     = 0.293

# Height -> tilt: how far above the speaker plane the breath is, normalized
# so the theoretical node height is 1.0. Clamped, because this path never
# goes below the speakers - an angle that drives it there is the -25 deg
# mistake coming back, and xen_breath_slope says so out loud when it does.
breath_tilt = lambda { |z| [[(z - speaker_z) / (node_z - speaker_z), 0.0].max, 1.0].min }

# The band pair for a phase running from tilt a to tilt b. Built at the call
# site, where these constants are in scope: `define` makes a method, so
# play_cloud_phase cannot see any of them.
blauert_ramp = lambda { |a, b, amt|
  { hi_note: blauert_hi_note,          lo_note: blauert_lo_note,
    res: blauert_res,
    hi_from: blauert_hi_db * amt * a,  hi_to: blauert_hi_db * amt * b,
    lo_from: blauert_lo_db * amt * a,  lo_to: blauert_lo_db * amt * b }
}

# M=0: how long the burst lasts at full density. The density and tail are
# baked into the renders (render_m0.py: M0_TAIL, K_DENS, K_AMP).
m0_dur = 0.45
# How long we wait after the burst before the exhale. The rendered tail is
# still sounding at this point and has dropped ~20 dB, so the exhale doesn't
# start from dead silence - it emerges from under the thinning rain. Too
# short = the tail covers the exhale (which is very soft anyway); too long =
# the gap comes back abruptly.
m0_tail = 1.2
# M=0's volume ramp. Applied to the tanh's amp, i.e. AFTER the distortion/hpf
# - a saturator flattens any level drop that happens before it, so a ramp
# baked into the render would barely be audible. This is the ONLY fade on
# M=0 that the room actually hears; render_m0.py's own cosine taper keeps the
# rendered material honest but is mostly eaten by the saturation.
#
# It used to be a flat 5.0 - "runs over the whole exhale, so the transition is
# a cross-fade, not a cut". That was a deliberate overlap, and this knob is
# how you take it back: at 32 s the exhale is 13.575 s, so 5.0 spends 37% of
# it with M=0 still sounding underneath, which is what blurs the handover.
# Shorter = the exhale starts in clearer air; too short and the burst is
# chopped instead of dissolving.
#
# It does NOT affect cycle timing - both M=0 halves ramp inside in_thread, so
# the main loop's sleep is unchanged whatever this is.
m0_fade = get(:xen_m0_fade, 5.0)
# M=0's overall level. Also applied to the tanh's amp, for the same reason as
# the ramp: the amps before the distortion/hpf are the ATTACK stage of a
# saturator, not the output level - you could cut them in half and barely
# hear it. This is the one place where a reduction is actually audible.
# 1.0 = what it used to be; 0.7 ~= -3 dB.
#
# The two halves of M=0 are trimmed SEPARATELY on top of this - see
# xen_m0_ceil_amp / xen_m0_floor_amp - because only one of them is ever in
# the atmosphere accent's way.
m0_amp = 0.7

# THE EXHALE'S CLOUDS - the same construction, mirrored.
# Spatial mirror around the center of the vault (x -> 13 - x) PLUS reversing
# the direction of travel: the exhale rises from the ground toward the
# ceiling, on 7-12.
# The crossing is preserved - they overlap at t = 0.5 on 8.5-10.5 (center
# 9.5).
# The densities are higher than the inhale's: at 18/6 the exhale stayed 5.9
# dB below the inhale in total energy across the speakers - too little
# presence.
# shape: 3 makes the pauses more even at the same density. The inhale stays
# pure Poisson (scattered, searching); the exhale flows.
# The silence before the implosion. Kept symmetric with m0_tail, so the burst
# sits exactly on m0_center. It's also the "suction" called for in the
# choreography - and the directional bands (the false verticality) are much
# more audible on an empty stage.
inhale_pause = m0_tail - 0.035

# THE VOID AT THE CYCLE BOUNDARY - how much granular silence there is between
# the exhale's last grain and the inhale's first.
#
# It used to be hard-wired at one atmos_margin either side of the granular
# material, i.e. 2 s: the beds led it in and followed it out. Two seconds is
# a long time to hear nothing in a 32 s breath, and it landed on top of the
# beds' own crossing through zero (see bed_overlap above), so the two silences
# coincided and the breath stopped instead of turning. At 0.0 the exhale now
# runs to the boundary and the inhale starts on it: the phases TOUCH, and the
# breath has no seam left to hear.
#
# What 0.0 costs: the beds no longer start before the grains and end after
# them, so the piece's very first second is no longer a bed alone - the
# inhale enters with it. Set it back to 2.0 for exactly the old behaviour,
# and to anything between for a breath that pauses without stopping (the
# spill, 1c, fills whatever void is left here - it is what keeps a nonzero
# void from being the hole it used to be).
#
# READ ONCE PER RUN, like cycle_dur and for the same reason: the phase budget
# below is computed from it. Changing it needs Stop + Run.
void  = get(:xen_void, 0.0)
lead  = void / 2.0     # silence before the inhale's first grain
trail = void / 2.0     # silence after the exhale's last

# The granular phases, equal and symmetric around m0_center.
inhale_dur = m0_center - m0_dur / 2.0 - lead - inhale_pause - 0.035
exhale_dur = cycle_dur - trail - (m0_center + m0_dur / 2.0 + m0_tail)

# With m0_center = cycle_dur / 2 both of the above reduce to
# cycle_dur / 2 - 1.425 - void / 2 (so 2.425 at the old void of 2.0), which is
# how they stay equal to each other on their own - but they go NEGATIVE once
# the cycle gets short enough, and a negative sleep is a TimingError thrown
# from inside a Run rather than a sentence here. The floor is derived from the
# constants, not written down, so it follows m0_dur / m0_tail / void if any of
# those ever move.
phase_floor = 0.5
if inhale_dur < phase_floor
  fixed = cycle_dur - inhale_dur - exhale_dur
  raise "xen_cycle_dur #{cycle_dur} s leaves only #{'%.3f' % inhale_dur} s per granular " \
        "phase. The fixed costs - the #{void} s void, the " \
        "#{'%.3f' % inhale_pause} s pause, m0_dur #{m0_dur}, m0_tail #{m0_tail} - take " \
        "#{'%.3f' % fixed} s, so the shortest usable cycle is about " \
        "#{'%.2f' % (fixed + 2 * phase_floor)} s."
end
cloud_exhale_positive = { span0: [7.0,  9.0], span1: [10.0, 12.0], lambda: 32.0 * xen_density, shape: 3 }
cloud_exhale_negative = { span0: [8.0, 10.0], span1: [ 9.0, 11.0], lambda: 11.0 * xen_density, shape: 3 }

# 0b-bis. WHERE THE PHASES START AND STOP, NAMED
#
# Numbers that used to be literals at the two play_cloud_phase call sites.
# The spill (1c) has to LEAVE where the exhale stops and ARRIVE where the
# inhale starts, so the same values now appear in more than one place - which
# is exactly the drift m0_center's derivation exists to prevent. Change a
# phase's endpoint here and the seam follows it.
inhale_rate_from = 1.4    # the inhale enters pitched up, and darkens as it descends
exhale_rate_to   = 1.34   # the exhale leaves pitched up too - the two nearly meet
inhale_lpf_from  = 120    # MIDI: 8372 Hz
exhale_lpf_to    = 112    # MIDI: 5274 Hz
exhale_amp_lo    = 0.138  # the exhale's QUIETEST grain - where the spill starts

# How far past the boundary the spill (1c) reaches, ON TOP of whatever void
# xen_void leaves. This is the part that survives at void 0.0, where the two
# phases already touch and there is no silence left to fill: a second of the
# exhale's residue thinning out UNDER the inhale's entrance, so the breath
# turns rather than cuts. m0_tail is the same idea at the same scale (1.2 s)
# on the other side of M=0.
spill_into = 1.0

# 0b-ter. THE VACUUM - a travelling hole in the atmosphere, 5-6 -> 9-10
#
# The piece has exactly one physical event and it is an ADDITION: M=0, an
# implosion that saturates every chain it touches (12.2 dB of crest flattened
# to 2.1). This is its inverse, and it is made of subtraction - which is also
# the only kind of gesture this room can carry across that distance. The 17
# September capture measured D50 at 4.1 / 4.5 / 0.1 % (README 10a): there is
# no direct field to build a phantom in, so a travelling SOURCE will not read
# as travelling. A travelling ABSENCE does not need to localise. The beds are
# continuous and diffuse; when a piece of one leaves and reappears displaced,
# the ear registers the change even when it cannot point at it.
#
# THE PATH, off the floor plan (monitors.tsv, cm, projected onto the line
# joining the centroid of 5-6 to the centroid of 9-10):
#
#     ch 5  (400,152)    0.0 m    f 0.000
#     ch 6  (487,200)    0.3 m    f 0.042
#     ch 10 (313,700)    5.4 m    f 0.850
#     ch 9  (313,800)    6.5 m    f 1.000
#
# 6.51 m end to end, crossed in vac_cross seconds - 3.3 m/s at the default
# 2.0, which is the same 2-3 m/s of real air movement the capture found
# phase-modulating 8 kHz in this hall. It is also the ONE path that goes
# THROUGH the audience rather than round it: hexagon A ends at Y 348 and B
# starts at Y 652, so the middle 3 m of the crossing has no speaker in it at
# all, and people stand in that gap. Nothing can glide across it - the hole
# leaves A and arrives in B - which is the other reason the gesture is a
# removal.
#
# 5-6 is also where the piece already melts the floor: quad_floor is
# [5, 6, 7, 8], M=0's funnel. The vacuum opens on the funnel's own corner.
vac_path  = [[5, 0.000], [6, 0.042], [10, 0.850], [9, 1.000]]
vac_cross = 2.0        # s to cross the 6.51 m -> 3.3 m/s
vac_in    = 0.35       # the hole opening: fast, or it is a swell, not a suck
vac_hold  = 0.25       # how long it stays open
# Closing is slower than opening - refilling, not a gate letting go - and the
# length is DERIVED rather than chosen: it is exactly long enough that the near
# pair is still coming back when the far pair opens, so the hole is never
# nowhere. Any faster and the gesture reads as two ducks instead of one thing
# crossing. The floor is for a vac_cross short enough to make this negative.
vac_out   = [vac_cross * (vac_path[2][1] - vac_path[0][1]) - vac_in - vac_hold, 0.4].max
#
# THE DEPTHS WERE RAISED x1.9 ON 2026-09-18 - the first build was -12.0 dB,
# -5.0 semitones and a flat 1.0 of the Blauert chord, and it was not enough.
# All three scale together off xen_vacuum, so what changes here is what 1.0
# MEANS; the desk keeps its 0.8 and gets 1.9 times the gesture it had.
#
# They do not all deliver the same way, and it is worth knowing which is which
# before reaching for more:
#
#   vac_db     delivers nearly all of it, and is closest to its own ceiling.
#              A hole is a hole: past about -20 dB there is nothing left to
#              remove, and deeper stops reading as deeper. At -22.8 the bed on
#              those channels is 7% of its level, i.e. gone.
#   vac_semis  delivers all of it and costs nothing. Counter-intuitively it
#              gets CLEANER as it grows: the bed sits at +12.53 semitones of
#              stretch compensation, so PitchShift is running an octave up,
#              and dragging it down to +3.03 moves the shifter TOWARD unity.
#              The deeper the drop, the fewer artefacts during it.
#   vac_tilt   delivers least. README 10c measured it on the M=0 scalpel:
#              +9 dB of extra Blauert EQ bought +3.07 dB of actual 8k-to-3k
#              contrast, because the pair sits inside the tanh and a saturator
#              compresses spectral contrast exactly as it compresses dynamic
#              contrast. Expect about a third of what the number says. It also
#              costs timbre - +11.4 dB at 3136 Hz on a bed with 81.5% of its
#              energy in 125-500 Hz is audible as honk before it is audible as
#              height - so this is the first one to back off if the vacuum
#              starts sounding like a wah pedal rather than a hole.
vac_db    = -22.8      # how deep the hole is at xen_vacuum 1.0 (was -12.0)
vac_semis = -9.5       # how far the material is dragged down with it (was -5.0)
vac_tilt  = 1.9        # the below-cue, in multiples of the piece's own Blauert
                       # chord: 1.0 would be M=0's +9/-6 read backwards, and
                       # this is that chord and then some (was a flat 1.0)

# 0b. RE-SCALING A GESTURE OVER A SMALLER RIG
# count positions distributed over n outputs, wrapping in a circle, so every
# gesture can be heard alone across all the speakers - not crammed into one
# corner.
define :xen_spread do |n, count|
  (0...count).map { |i| (i % n) + 1 }
end

# 1b. PHASE WITH STOCHASTIC CLOUDS THAT CROSS THE HALL
#
# A cloud = a Poisson process of grains with density lambda (grains/second),
# whose position interval moves continuously from span0 to span1.
# A grain's position is a real number, not a speaker index: panning happens
# between neighboring speakers, at constant power (cos/sin), so the movement
# is heard as motion, not as a series of jumps.
define :play_cloud_phase do |o|
  # The enhancer settings have to be handed in: `define` makes a method, so
  # the breath loop's locals are not in scope here.
  enh_thr   = o[:enh_thr]   || 0.2
  enh_below = o[:enh_below] || 1.0
  enh_above = o[:enh_above] || 1.0
  # The slope, handed in the same way and for the same reason. Defaults to a
  # flat pair, so a caller that says nothing about height gets exactly the
  # phase this method produced before the slope existed.
  bl = o[:blauert] || { hi_note: 120, lo_note: 103, res: 0.293,
                        hi_from: 0.0, hi_to: 0.0, lo_from: 0.0, lo_to: 0.0 }
  # Placement mode, handed in for the same reason as the rest. Defaults to
  # :continuous, so a caller that says nothing gets the phantom-image panning
  # this method has always produced.
  discrete = o[:pan_mode] == :discrete
  # WHERE a grain sits inside the moving span - :scatter or :sweep. Same
  # defaults-to-the-old-behaviour rule.
  sweep      = o[:traj_mode] == :sweep
  traj_cyc   = o[:traj_cycles] || 3.0
  traj_width = o[:traj_width]  || 0.12
  # --- the drawing's bounds, so we can fold it onto a smaller rig ---
  lo_d = o[:clouds].map { |c| [c[:span0][0], c[:span1][0]].min }.min
  hi_d = o[:clouds].map { |c| [c[:span0][1], c[:span1][1]].max }.max

  # --- 1. the whole timeline is built in the parent thread ---
  events = []
  o[:clouds].each_with_index do |c, ci|
    # shape = the Erlang order: the sum of `shape` exponential intervals, at
    # the same mean density. shape 1 = pure Poisson - natural, but CLUMPY:
    # exponential gaps have no upper bound, so long silences appear on a
    # speaker. Higher shape = same density, much more even pauses.
    shape = c[:shape] || 1
    t = 0.0
    # NOTE: `while`, not `loop`. Sonic Pi overrides `loop` with a version
    # that requires sleep/sync on every iteration (ZeroTimeLoopError). This
    # is pure computation, no time consumed, so it needs a real Ruby loop.
    while true
      dt = 0.0
      shape.times { dt += -Math.log(1 - rand) / (c[:lambda] * shape) }
      t += dt
      break if t >= o[:dur]
      f = t / o[:dur]

      lo = c[:span0][0] + (c[:span1][0] - c[:span0][0]) * f
      hi = c[:span0][1] + (c[:span1][1] - c[:span0][1]) * f
      # THE SPAN ITSELF WAS ALWAYS DETERMINISTIC. lo and hi above are a plain
      # linear interpolation from span0 to span1 across the phase - the window
      # travels down the inhale slope on rails. What :scatter randomises is
      # only WHERE INSIDE that window each grain lands.
      #
      # :sweep replaces that scatter with a parametric curve, which is the
      # Metastaseis / Philips Pavilion reading of the same drawing: a ruled
      # surface traced by glissandi rather than a cloud filling a volume.
      # Both are Xenakis - the clouds are the Pithoprakta/Achorripsis
      # stochastic lineage, this is the glissando lineage - so it is a choice
      # of idiom, not a correction.
      #
      # traj_width is the dial that matters. At 0.0 the phase collapses to a
      # single travelling POINT: one grain position at any instant, which with
      # pan_mode :discrete means one speaker at a time. That is a line, not a
      # cloud. Metastaseis is 46 separate string glissandi, not one - a BUNDLE
      # of nearby lines - so the default keeps a narrow scatter around the
      # swept centre and reads as a thick line. Widen it and it melts back
      # toward :scatter.
      #
      # Each cloud gets its own rate and a quadrature phase offset, so the two
      # families of lines cross instead of moving in lockstep - the crossings
      # ARE the surface. With two clouds that is 1x and 2x traj_cycles.
      #
      # sin() gives smooth turnarounds. A ruled surface is strictly made of
      # STRAIGHT lines, so a triangle wave is the more literal reading; it
      # costs a sharper reversal at each extreme. Swap the sin() below if you
      # want it.
      if sweep
        mid  = (lo + hi) / 2.0
        half = (hi - lo) / 2.0
        rate = traj_cyc * (ci + 1)
        ph   = ci * Math::PI / 2
        centre = mid + half * Math.sin(2 * Math::PI * rate * f + ph)
        pos = centre + rrand(-traj_width, traj_width) * half
        # Clamp: the centre already reaches lo and hi at the extremes, so the
        # scatter would push past them. Unclamped, the rig fold below can then
        # produce pos < 1 or > rig, and `ch = pos.floor` would address a
        # channel that does not exist. :scatter never needed this because
        # rrand(lo, hi) is bounded by construction.
        pos = [[pos, lo].max, hi].min
      else
        pos = rrand(lo, hi)
      end
      # on a smaller rig, compress the whole drawing onto the outputs available
      pos = 1.0 + (pos - lo_d) * (o[:rig] - 1) / (hi_d - lo_d) if o[:rig] < hi_d

      ch   = pos.floor
      frac = pos - ch
      # entry_amp: gain at the START of the phase, which ramps down to 1.0
      # by the end. The exhale opens with rate 0.8 (pitched down) and the
      # filter at 622 Hz - doubly darkened - so it comes in 2.9 dB below the
      # inhale's entrance, right after M=0, the loudest moment in the piece.
      # This ramp compensates the LEVEL, so the timbre keeps opening up
      # further while the perceived loudness stays flat from the very first
      # grain.
      entry_cap = o[:entry_amp] || 1.0
      gain = entry_cap + (1.0 - entry_cap) * f
      intensity = rrand(o[:amp_lo], o[:amp_hi]) * gain
      # constant power: amp_a^2 + amp_b^2 = intensity^2
      amp_a = intensity * Math.cos(frac * Math::PI / 2)
      amp_b = intensity * Math.sin(frac * Math::PI / 2)
      # PROBABILISTIC FOLD (discrete mode). The grain goes WHOLE to one of the
      # two channels, picked with the probability equal to the POWER share the
      # continuous law would have given it: cos^2 for the lower, sin^2 for the
      # upper. That is not a detail - it is what makes the two modes
      # comparable. The expected power on channel `ch` is
      #     P(ch) * intensity^2 = cos^2(...) * intensity^2 = amp_a^2
      # which is exactly what continuous mode puts there. So over a phase the
      # spatial distribution of energy is IDENTICAL; only its granularity
      # changes, and an A/B tells you about placement rather than about level.
      # Carrying the full `intensity` (not intensity/sqrt2) is the other half
      # of that: all the power goes to the one speaker, so total radiated
      # power per grain is unchanged too.
      #
      # A linear P(ch+1) = frac would have been the obvious guess and is
      # subtly wrong: it matches the AMPLITUDE law, not the power law, and
      # would pull energy toward the channel boundaries.
      #
      # Side effect worth knowing: discrete emits ONE event per grain instead
      # of two, measured at 0.58x over 130k events - the inhale's ~64 voices/s
      # become ~37. (Not exactly half: continuous already drops the events
      # that fall under the 0.05 amp threshold near a channel's own position.)
      # Free headroom on the layer that has historically been the expensive
      # one (see xen_density).
      p_upper = Math.sin(frac * Math::PI / 2) ** 2

      pool = c[:pool]
      cut = pool[:cuts].choose
      rate = o[:pitch_from] + (o[:pitch_to] - o[:pitch_from]) * f + rrand(-o[:pitch_jit], o[:pitch_jit])
      lpf  = o[:lpf_from] + (o[:lpf_to] - o[:lpf_from]) * f + rrand(-o[:lpf_jit], o[:lpf_jit])

      ev = { t: t, wav: pool[:wav], start: cut[:start], finish: cut[:finish],
             rate: rate, lpf: lpf }
      if discrete
        # At the very top of the range pos == rig exactly, so frac == 0 and
        # p_upper == 0: the pick can never be ch + 1, which is off the rig.
        # Same guard the continuous branch gets from `amp_b > 0.05`.
        pick = (rand < p_upper) ? ch + 1 : ch
        events << ev.merge(chan: pick, amp: intensity) if intensity > 0.05
      else
        events << ev.merge(chan: ch,     amp: amp_a) if amp_a > 0.05
        events << ev.merge(chan: ch + 1, amp: amp_b) if amp_b > 0.05
      end
    end
  end
  events.sort_by! { |e| e[:t] }

  # --- 2. a persistent FX chain per channel, for the whole phase ---
  # Grains now fall on unpredictable channels, so the chains can no longer be
  # held per speaker-pair: each channel gets its own thread, which only
  # walks through its own grains.
  events.group_by { |e| e[:chan] }.each do |ch, mine|
    in_thread do
      with_fx :sound_out, output: ch, amp: 0 do
        with_fx :compressor, threshold: enh_thr, slope_below: enh_below,
                            slope_above: enh_above, clamp_time: 0.01,
                            relax_time: 0.25 do
          # The same soft ceiling as M=0. tanh sees the SUM of the grains
          # overlapping on a channel, so it catches exactly the unpredictable
          # pileups of the Poisson process - the only place the clouds could
          # exceed 1.0.
          # get, not a handed-in opt: this is a per-run global, and `define`
          # puts the breath loop's locals out of scope here (see the note at
          # the top of play_cloud_phase).
          with_fx :tanh, krunch: 0.25, amp: get(:xen_out_headroom, 1.0) do
            # THE SLOPE, voiced (see "THE BREATH'S HEIGHT"). The descent is
            # the "above" band draining out of the phase while the
            # "behind/below" band returns to flat - M=0's chord, ramped
            # instead of held.
            #
            # Both slides are started once, here, and run the length of the
            # phase, so the slope costs two nodes and two messages per
            # CHANNEL no matter how many grains land on it. That is the only
            # reason this is affordable: the chain is already persistent for
            # the whole phase, and per-grain EQ would be exactly the
            # per-event work the lpf note below explains we avoid.
            #
            # Inside the tanh deliberately, as at M=0: the boost is part of
            # what the ceiling has to catch, not something added after it.
            # It costs less headroom than it looks like it should - the
            # +9 dB sits at 8372 Hz, right at the lpf knee where this
            # material is already rolling off, while the -6 dB comes out of
            # 3136 Hz, where the measurement found 22.7% of the RMS.
            # The grain schedule itself, independent of whether the slope
            # is voiced - so the band pair can be SKIPPED entirely at 0 dB
            # rather than instantiated flat. Two transparent FX per channel
            # still cost per-sample work, which made xen_blauert useless as
            # an off switch exactly when we needed it to A/B DSP load.
            play_grains = lambda do
              prev = 0.0
              mine.each do |e|
                sleep e[:t] - prev
                prev = e[:t]
                # lpf: this is the sampler's INTERNAL filter, not a separate
                # FX. Every grain carries its own cutoff, so there's no need
                # for either an :lpf synth per channel or a `control`
                # message per grain - exactly the per-event work that was
                # leaving the threads behind.
                sample e[:wav], start: e[:start], finish: e[:finish],
                       amp: e[:amp], rate: e[:rate], lpf: e[:lpf],
                       attack: 0.01, release: 0.06
              end
              sleep o[:dur] - prev
            end

            if bl[:hi_from].abs < 0.01 && bl[:hi_to].abs < 0.01
              play_grains.call
            else
              with_fx :band_eq, freq: bl[:hi_note], res: bl[:res],
                                db: bl[:hi_from], db_slide: o[:dur] do |eq_hi|
                with_fx :band_eq, freq: bl[:lo_note], res: bl[:res],
                                  db: bl[:lo_from], db_slide: o[:dur] do |eq_lo|
                  control eq_hi, db: bl[:hi_to]
                  control eq_lo, db: bl[:lo_to]
                  play_grains.call
                end
              end
            end
          end
        end
      end
    end
  end

  sleep o[:dur]
end

# 1c. THE SPILL - the exhale's last grains carried over the boundary
#
# The exhale stops dead. Whatever void xen_void leaves after it - 0.0 by
# default - the next thing the room hears is the inhale's first grain, up an
# octave of filter and at the other end of the hall. The spill is the seam:
# a handful of the exhale's own grains that keep going over the boundary and
# dissolve UNDER the inhale's entrance, spill_into seconds past it.
#
# It is m0_tail's trick at the other junction. The exhale doesn't start from
# dead silence because M=0's rendered rain is still thinning over it, 20 dB
# down; this does the same for the inhale, and it does it whether the void is
# two seconds wide or nothing at all. A nonzero void NEEDS it - that is what
# keeps the pause from being the hole it used to be - and at void 0.0 it is
# what keeps the turn from being a splice.
#
# NOT a phase. The grains are placed one per even slot with a jitter of +-0.4
# of a slot rather than drawn from a Poisson process: at five events over a
# second or two the exponential's long tail IS what you hear - a clump and
# then a hole, which is the artefact being fixed. (+-0.4 against a spacing
# of 1.0 cannot reorder two neighbours, 0.9 < 1.1, so the times are sorted
# by construction and nothing has to sort them.)
#
# A spill grain is the exhale's last state sliding into the inhale's first:
# rate exhale_rate_to -> inhale_rate_from, lpf exhale_lpf_to ->
# inhale_lpf_from (5274 -> 8372 Hz, and the two phases were already that
# close), and a position running from the exhale's closing span to the
# inhale's opening one - on the full rig, the walk from hexagon B back to
# hexagon A, the breath returning to where it starts. Amplitude is the one
# thing that does NOT continue: it decays, because this is a residue.
define :play_spill do |o|
  discrete = o[:pan_mode] == :discrete
  bl       = o[:blauert]
  n        = o[:n]
  # The drawing's bounds, folded onto a smaller rig exactly as a phase folds
  # (play_cloud_phase, step 1) - the spill spans both hexagons, so on 4
  # outputs it is the same walk compressed onto 1..4.
  lo_d = [o[:from_span][0], o[:to_span][0]].min
  hi_d = [o[:from_span][1], o[:to_span][1]].max
  slot = o[:dur].to_f / n
  head = get(:xen_out_headroom, 1.0)

  # Detached: the cycle's timing must not depend on this. The thread outlives
  # the live_loop iteration that started it and goes on sounding into the next
  # one, like the atmosphere beds and M=0's accent.
  in_thread do
    prev = 0.0
    n.times do |i|
      t = (i + 0.5 + rrand(-0.4, 0.4)) * slot
      sleep t - prev
      prev = t
      f = (n == 1) ? 0.0 : i.to_f / (n - 1)

      lo  = o[:from_span][0] + (o[:to_span][0] - o[:from_span][0]) * f
      hi  = o[:from_span][1] + (o[:to_span][1] - o[:from_span][1]) * f
      pos = rrand(lo, hi)
      pos = 1.0 + (pos - lo_d) * (o[:rig] - 1) / (hi_d - lo_d) if o[:rig] < hi_d
      ch   = pos.floor
      frac = pos - ch

      amp  = o[:amp_from] + (o[:amp_to] - o[:amp_from]) * f
      rate = o[:rate_from] + (o[:rate_to] - o[:rate_from]) * f + rrand(-o[:rate_jit], o[:rate_jit])
      lpf  = o[:lpf_from]  + (o[:lpf_to]  - o[:lpf_from])  * f + rrand(-o[:lpf_jit],  o[:lpf_jit])
      # ONE cut per grain, chosen before the fold below: in continuous mode
      # the two events are the same grain split across two speakers, not two
      # grains.
      cut = o[:pool][:cuts].choose

      # NO ENHANCER on this chain, unlike a phase. The 118 is set to expand
      # (slope_below 1.2 at the desk default), a spill grain sits at or under
      # the exhale's amp_lo, and that is below enh_thr - so the expander would
      # push the one layer whose whole job is to stay just audible under the
      # inhale's entrance about a dB further down. The tanh stays: xen_out_headroom is the only
      # trim that catches the summed bus, and it is post-tanh on every other
      # chain in the piece.
      fire = lambda do |c, a|
        in_thread do
          with_fx :sound_out, output: c, amp: 0 do
            with_fx :tanh, krunch: 0.25, amp: head do
              grain = lambda do
                sample o[:pool][:wav], start: cut[:start], finish: cut[:finish],
                       amp: a, rate: rate, lpf: lpf,
                       attack: 0.01, release: 0.06
              end
              # The slope, held rather than ramped - the exhale ends at the
              # top of it and the inhale starts there too, so the height cue
              # is flat across the handover. Skipped entirely at 0 dB, for the
              # reason the phase skips it: a transparent band_eq is still a
              # node doing per-sample work.
              if bl[:hi_from].abs < 0.01
                grain.call
              else
                with_fx :band_eq, freq: bl[:hi_note], res: bl[:res], db: bl[:hi_from] do
                  with_fx :band_eq, freq: bl[:lo_note], res: bl[:res], db: bl[:lo_from] do
                    grain.call
                  end
                end
              end
            end
          end
        end
      end

      # The same power-law fold as a phase - cos^2 / sin^2 of the position's
      # fraction - so a spill grain is placed by exactly the law the rest of
      # the piece places grains with, and the two pan modes stay comparable
      # here too. At the very top of the range frac is exactly 0, which is
      # what keeps ch + 1 from addressing a channel off the rig.
      #
      # What is NOT carried over is the phase's `> 0.05` cull of quiet halves.
      # That is a voice-count economy worth having at 64 events a second and
      # WRONG at five: a spill grain starts near the exhale's amp_lo and ends
      # a third of that, so the cull would silently delete the end of the
      # bridge - the half of it that matters most, being the half nearest the
      # inhale.
      if discrete
        fire.call((rand < Math.sin(frac * Math::PI / 2) ** 2) ? ch + 1 : ch, amp)
      else
        fire.call(ch, amp * Math.cos(frac * Math::PI / 2))
        amp_b = amp * Math.sin(frac * Math::PI / 2)
        fire.call(ch + 1, amp_b) if amp_b > 0.0
      end
    end
  end
end

# 1d. THE ATMOSPHERE LOADER THREAD
# Prepares the next cycle's set and frees the set from TWO cycles ago - not
# the previous one, which might still be sounding on its tail.
live_loop "atmos_loader_#{run_tag}".to_sym do
  # Administrative loop: triggers no sound, so it needs no precision.
  # Was 60, to stop a TimingError killing the loop during the sample load.
  # But sched_ahead is also how long every `set` in this thread parks a raw
  # Thread.new in Sonic Pi's GUI-message path (runtime.rb:1919): at 60 each
  # cycle left threads sitting for a full minute, they are NOT job subthreads
  # so Stop does not touch them, and they pile up until the message queue
  # backs up and the next Run cannot start its loops. 2.0 matches the piece.
  use_sched_ahead_time 2.0

  sleep cycle_dur - 4.0        # let the current cycle keep sounding

  # STAGGERED, not batched. This loop used to fire all six load_sample calls
  # back to back and then sample_free the whole outgoing set in one go. Six
  # 16 s stereo files is ~37 MB of /b_allocRead landing on scsynth inside
  # 200 ms, on top of a cycle that is already sounding, and the device did
  # not survive it: measured twice, an atmos load burst at 14:46:51 and
  # 14:53:05 was followed by audioDeviceStopped at 14:47:09 and 14:53:22.
  # The trivial device test, which loads nothing, ran for five minutes on
  # the same machine without a single stop.
  #
  # So the work is spread across three of the four spare seconds instead of
  # being dumped in one instant. `spread` is computed from the actual number
  # of operations so the loop still consumes EXACTLY cycle_dur in total -
  # this loop has to stay in phase with the breath, or the set would switch
  # underneath a cycle that is still playing it.
  #
  # NB `stagger`, not `spread`: spread() is a Sonic Pi built-in (the
  # Euclidean rhythm generator) and a local of that name shadows it.
  upcoming = atmos_set.call
  to_free  = get(:atmos_n1)
  n_ops    = upcoming.size + (to_free ? to_free.size : 0)
  stagger  = 3.0 / n_ops

  upcoming.each_value { |f| load_sample f; sleep stagger }

  set :atmos_n1, get(:atmos_n0)
  set :atmos_n0, upcoming
  # Frees are staggered for the same reason, and stay AFTER the loads: the
  # set being freed is two cycles old, so nothing is still sounding it.
  to_free.to_h.values.each { |f| sample_free f; sleep stagger } if to_free

  sleep 1.0                    # 3.0 spent staggering + 1.0 = the 4.0 above
end

# 2. THE INSTALLATION'S MAIN LOOP
# seed: applied ONCE, when the loop's thread starts - so the random flow
# evolves from one breath to the next, but the whole run repeats identically
# on a new Run. Changing the seed requires Stop + Run.
live_loop "xenakis_installation_#{run_tag}".to_sym, seed: get(:xen_seed, 0) do

  # SCHEDULING LOOKAHEAD - left at Sonic Pi's default, deliberately.
  #
  # M=0 is the one place everything happens at once: the atmosphere accent
  # (2 files x 4 quad_ceil channels = 8 threads), the ceiling scalpel (4) and
  # the floor funnel (4) - SIXTEEN threads inside 35 ms, each building an FX
  # chain and triggering a sample. Against the 0.5 s default that measured as
  # LATE spikes of 1041.9 / 1192.2 / 1116.8 ms across three separate runs,
  # always with the event count jumping by exactly 16.
  #
  # Raising this to 3.0 removed those spikes (1116 ms -> 4 ms) and STILL made
  # the piece die sooner - 1 cycle instead of 2-3, twice in a row. A 3 s
  # lookahead means ~6x more timestamped bundles queued in scsynth for a piece
  # firing ~64 grain events a second, and that cost more than the spikes did.
  # The fix for M=0 turned out to be xen_density, not lookahead. Kept as a
  # knob because the measurement is worth being able to repeat.
  use_sched_ahead_time get(:xen_sched_ahead, 0.5)

  # ==========================================
  # CONFIGURATION (read from the workspace at every breath)
  # ==========================================
  rig_outputs = get(:xen_rig_outputs, 12)
  focus       = get(:xen_focus, :all)
  # The discrete outputs completely bypass Sonic Pi's master limiter, so the
  # levels below are all that protects us. Peaks measured on the real
  # material, with master_amp 0.8: inhale ~0.52, ceiling ~0.72, floor ~0.69.
  master_amp  = get(:xen_master_amp, 0.8)
  # Studio reference cue: two high bell tones marking the cycle boundaries -
  # one high at the start of the cycle, one an octave lower at the end of the
  # exhale. They go through the main stereo mix (monitors 1-2), NOT through
  # sound_out, so it's clearly audible that they're not part of the piece.
  # Kept off in the hall.
  bleep       = get(:xen_bleep, false)
  # Layer solo, orthogonal to focus: - focus picks WHICH phase of the breath
  # plays, layers picks WHICH of the two materials you hear in it.
  #   :both (default) :atmos (beds only) :grains (granular only)
  # Muting a layer never changes the length of the breath: the phases below
  # hold their time either way, otherwise the 16 s atmos files would be
  # retriggered every couple of seconds.
  layers      = get(:xen_layers, :both)
  # ENHANCER - a dbx 118 in software.
  #
  # The 118 is a single-band compressor/expander: one knob running from
  # compression, through unity at centre, into expansion. Expansion is the
  # side it is normally used on - it pushes quiet material further down so
  # transients regain their impact, i.e. it RESTORES dynamic range rather
  # than taming it. Sonic Pi's :compressor is SuperCollider's Compander, so
  # slope_below > 1 is exactly that downward expansion.
  #   xen_enhance: -1.0 compress .. 0.0 unity (bypass) .. +1.0 expand
  # At 0.0 both slopes are 1.0, which is a mathematical passthrough.
  #
  # Expansion only ever pulls quiet material DOWN (slope_above stays 1.0), so
  # it cannot push these unlimited outputs into clipping. Compression, on the
  # negative side of the knob, holds peaks instead - also safe. Nothing here
  # adds gain.
  # Defaults chosen against the measured levels of this material:
  #   grains       0.155 .. 0.345 per event, channel peaks ~0.65 at amp 1.0
  #   atmos beds   0.5 sustained
  #   M=0 bursts   ~0.9 ceiling, ~0.86 floor
  # A threshold of 0.2 therefore sits INSIDE the grain range and BELOW
  # everything else: the beds keep their body and it is the sparse grains and
  # the tails that get opened up - which is the job the 118 exists to do.
  # +0.4 is slope_below 1.2, a 1.2:1 downward expansion: clearly audible on
  # the clouds, still gentle.
  #
  # NOT patched anywhere at M=0 - the pivot runs at unity, as rehearsed. The
  # two bursts ramp the tanh's amp to zero over m0_fade, deliberately placed
  # on the tanh because a saturator flattens any ramp upstream of it, and an
  # expander sits DOWNSTREAM: as the ramp carried the tail under the threshold
  # it steepened a cross-fade that was tuned by ear. The vertical layer is out
  # for the same reason - M=0 is one gesture and it stays unprocessed.
  # The enhancer is on the beds and the clouds.
  enhance     = get(:xen_enhance, 0.4)
  enh_thr     = get(:xen_enhance_threshold, 0.2)
  enh_below   = enhance > 0 ? 1.0 + enhance * 0.5 : 1.0
  enh_above   = enhance < 0 ? 1.0 + enhance * 0.5 : 1.0
  atmos_on    = [:both, :atmos].include?(layers)
  grains_on   = [:both, :grains].include?(layers)
  # The bed now sits ABOVE the granular material, not under it. Both are read
  # every breath, so they can be trimmed by ear while the piece runs.
  #
  # HEADROOM: the beds and the granular channels each have their own tanh
  # soft ceiling, but they reach the same hardware output through SEPARATE
  # sound_out chains, so they sum AFTER both tanhs - and these outputs bypass
  # the master limiter. Nothing catches the sum. Measured granular peaks with
  # master_amp 0.8 were inhale ~0.52, ceiling ~0.72, floor ~0.69, and the desk
  # runs master_amp 1.0, so raising the bed eats directly into what is left.
  #
  # This knob is now honest on any rig: bed_scale below re-references the
  # beds to the 12-output hall, so a change made by ear in the studio is the
  # same change in the hall. Before that it wasn't - on 4 outputs the bed
  # arrived 4.8 dB under where the same number put it in the hall.
  atmos_amp   = get(:xen_atmos_amp, 0.5)       # the bed, OVER the granular
  # The two hexagons' beds, trimmed separately over atmos_amp - the same
  # arrangement as xen_m0_ceil_amp / xen_m0_floor_amp, and for the same
  # reason: inhale and exhale are not the same gesture and do not compete
  # with the same thing. The inhale hexagon (1-6) shares its channels with
  # the inhale clouds, the exhale hexagon (7-12) with the exhale clouds, and
  # those two phases were never balanced against each other.
  atmos_inh_amp = get(:xen_atmos_inhale_amp, 1.0)
  atmos_exh_amp = get(:xen_atmos_exhale_amp, 1.0)
  atmos_m0amp = get(:xen_atmos_m0_amp, 0.75)   # the M=0 accent, over the bed
  grains_amp  = get(:xen_grains_amp, 1.0)      # ALL granular material, UNDER the atmosphere -
                                                # inhale/exhale clouds AND M=0's ceil/floor grains.
                                                # Mirrors atmos_amp, so the two can be balanced
                                                # against each other independently of master_amp.
                                                # Does NOT touch atmos_m0amp (the M=0 atmosphere
                                                # accent) or the relative ceil:floor trim within
                                                # M=0 - those stay their own separate knobs.

  # M=0's two halves, trimmed separately over m0_amp. They are NOT the same
  # gesture and they do not compete with the same thing.
  #
  # The atmosphere's M=0 accent plays on quad_ceil - the SAME speakers as the
  # granular scalpel (1, 2, 11, 12) and never the funnel's (5, 6, 7, 8) - and
  # in the same band: the scalpel is HPF'd to 2960-4186 Hz and then boosted
  # +9 dB at 8372 Hz, which is exactly where the accent's Blauert band sits.
  # The funnel is LPF'd at 466 Hz. So it is the SCALPEL that buries the
  # accent, with nearly three octaves of clear air between the accent and the
  # funnel, on different speakers.
  #
  # Which is why the default trims the scalpel and leaves the funnel alone.
  # Pulling the funnel down would cost exactly the weight at the feet that
  # makes M=0 land, and would not uncover one dB of the atmosphere.
  m0_ceil_trim  = get(:xen_m0_ceil_amp, 0.85)   # -15%, about -1.4 dB
  m0_floor_trim = get(:xen_m0_floor_amp, 1.0)   # the funnel, untouched
  # CONFINING M=0 TO ONE QUAD IS A LEVEL CHANGE, not just a placement one.
  # Both halves then land on the same four channels and sum there, on outputs
  # that bypass the master limiter. Measured on the current renders: scalpel
  # 0.413 + funnel 0.913 + the bed already on 5-8 gives a POWER sum of 1.151,
  # i.e. clipping before any coincident peak. 1/sqrt(2) on each is the
  # principled amount - the same constant-power reasoning as bed_scale: two
  # decorrelated sources on one channel at 1/sqrt(2) carry the total power one
  # of them carried alone. That puts the power sum at 0.907. Coincident peaks
  # still reach 1.50, so pull xen_m0_floor_amp down too if it reads as
  # clipping rather than as weight.
  # THE ONE TRIM THAT CATCHES THE SUM. Every chain here has its own tanh, but
  # they reach the same hardware output through SEPARATE sound_out chains and
  # sum AFTER all of them, with no limiter - so no existing knob can fix a
  # clipping channel. Worse, the knobs that look like they should (atmos_amp,
  # m0_amp, master_amp) all sit BEFORE a saturator, so they flatten: measured,
  # cutting xen_atmos_inhale_amp by 7.4 dB moved the bed's peak only 0.858 ->
  # 0.558, and the sum still clipped.
  #
  # This one is applied to the tanh's amp in EVERY chain, i.e. after all the
  # saturation, so it is plain linear gain on what actually reaches the bus.
  # Because it scales all of them by the same factor it costs nothing in
  # balance - every ratio tuned by ear is preserved exactly - it only trades
  # absolute level, which the amps can give back.
  out_trim      = get(:xen_out_headroom, 1.0)
  m0_confine    = get(:xen_m0_confine, false)
  m0_pair_scale = m0_confine ? 1.0 / Math.sqrt(2) : 1.0

  # THE SLOPE. The score's alpha/beta - see "THE BREATH'S HEIGHT" for why it
  # is 12 and not the 25/30 written on the drawing. Read every breath like
  # the amplitudes, so it can be found by ear: shallower leaves more of the
  # "above" cue standing when the breath reaches M=0, steeper drains it
  # sooner. xen_blauert is how strongly it is voiced at all - 0.0 puts the
  # band pair at 0 dB, which is flat, and the phases sound exactly as they
  # did before any of this existed.
  # THE ATMOSPHERE'S SPECTRUM. The beds are field recordings - breath and
  # doppler - so on their own they are broadband noise, which is the most
  # granular thing in the piece: no pitch, all texture. To make them read as
  # SPECTRAL instead, the four beds stop being four recordings and become
  # four PARTIALS of one spectrum, each rung by a narrow resonance.
  #
  # Sonic Pi has no phase vocoder - there is no PV_/FFT FX in the whole set,
  # so a real spectral freeze is not on the table. What is on the table is
  # resonance: excite a narrow band and noise turns into pitch. A peaking EQ
  # is the right tool rather than a band pass, because it ADDS the partial to
  # the bed instead of replacing the bed with what is left after filtering -
  # the material keeps its identity and gains a spectrum. It also keeps the
  # gain explicit in dB, which :nrbpf would not: that one ends in a
  # SuperCollider Normalizer targeting 1.0, which would drive these beds to
  # full scale and walk straight through the headroom budget above.
  #
  # f0 is MEASURED, not chosen. Long-term average spectrum over three files
  # from each of the four families (24-bit, 48 kHz, mono-summed):
  #     62-125 Hz  11.9%    125-250 Hz  56.5%    250-500 Hz  25.0%
  #     500-1k Hz   5.8%    1k-1.5k Hz   0.7%
  # with the per-family peaks at 145.0 / 191.9 / 131.8 / 127.4 Hz. So 81.5%
  # of the bed lives in 125-500 Hz, and MIDI 48 (C3, 130.8 Hz) sits on the
  # lowest of those peaks. Partials 1..4 off it land at 131 / 262 / 392 /
  # 523 Hz - across the band where the material actually has body, which is
  # the difference between a resonance that rings and one that boosts
  # nothing.
  #
  # Which bed gets which partial follows the breath: the inhale hexagon
  # carries 1 and 2, the exhale hexagon 3 and 4, so the exhale side sits
  # spectrally higher, the same direction its slope goes.
  spec_db      = get(:xen_atmos_spectral, 10.0)  # depth of the resonance; 0 = off
  spec_f0      = get(:xen_atmos_f0, 48)          # MIDI - C3, on the measured peak
  spec_stretch = get(:xen_atmos_stretch, 1.0)    # 1.0 = harmonic, >1 = stretched
  # res on :band_eq is NOT what the M=0 comment claims. fx_band_eq is
  # MidEQ(in, freq, rq, db) with rq = 1 - res, and rq is 1/Q, so HIGHER res
  # is a NARROWER band: 0.94 -> rq 0.06 -> Q ~17, about 0.09 octaves. Narrow
  # is what we want here - a wide bump is a tone control, a narrow one sings.
  spec_res     = get(:xen_atmos_res, 0.94)

  # THE BEDS ROTATE. Until now the atmosphere was the one thing in the piece
  # with no motion at all: inh_a sat on channels 1, 3, 5 at equal level for
  # the whole 16 s and stayed there.
  #
  # Everything else that moves is locked to ONE clock - position, pitch, lpf
  # and the Blauert tilt are all monotonic ramps of exactly one traversal per
  # phase, which is what makes the breath read as a single gesture. Decoupling
  # the CLOUDS from that would fragment it. The beds are different: they are
  # the ground, not the gesture, so turning them underneath costs the breath
  # nothing and gives the Philips Pavilion effect directly - the architecture
  # rotating while the texture deforms. (In the pavilion the tape moved along
  # "sound routes" across the array on a path independent of the tape's own
  # evolution; this is the same decoupling.)
  #
  # The period must NOT divide into cycle_dur, or the rotation locks to the
  # breath and stops being a second clock. 41 s against the default 16 s
  # repeats only every 656 s. cycle_dur is a knob now (xen_cycle_dur), so
  # that coprimality is no longer guaranteed by the two literals sitting
  # next to each other - re-check this if you change the cycle.
  #
  # Bonus, and a real one: the same bed plays on three coherent speakers, so
  # it builds an interference pattern with fixed nulls. Rotating the
  # distribution walks those nulls slowly through the room instead of leaving
  # them parked on somebody's head - without comb-filtering anything, which a
  # fixed delay would.
  rot_depth  = [[get(:xen_atmos_rotate, 0.0), 0.0].max, 1.0].min
  rot_period = get(:xen_atmos_rotate_period, 41.0)
  # Control interval. 12 bed nodes x 2/s = 24 messages/s, against the ~64
  # grain events/s the piece already sustains - and amp_slide interpolates
  # between them, so at a 41 s period this is far finer than it needs to be.
  rot_step   = 0.5

  breath_slope = get(:xen_breath_slope, 12.0)
  # 0.75, not 1.0: the +9 dB band lands on the inhale's final lpf knee
  # (8372 Hz) but sits above the exhale's (5274 Hz), so at full amount
  # only the -6 dB cut reaches the exhale and costs it 3.5 dB of RMS.
  # 1.0 restores tilt 1.0 == M=0's chord exactly, if the exhale can pay.
  blauert_amt  = get(:xen_blauert, 0.75)
  slope_drop   = breath_run * Math.tan(breath_slope * Math::PI / 180.0)
  slope_end_z  = node_z - slope_drop
  tilt_top     = breath_tilt.call(node_z)      # 1.0 - the theoretical height
  tilt_bottom  = breath_tilt.call(slope_end_z) # ~0.0 at 12 deg - the speakers
  # The guardrail. -25 deg lands at -0.76 m and -30 deg at -1.89 m, both
  # under the floor of a hall whose speakers are all at 1.80 m; if an angle
  # like that ever gets typed in again, it should not fail silently into a
  # clamp. Only on change, like the rig/focus report.
  if slope_end_z < speaker_z - 0.001 && get(:xen_slope_warned) != breath_slope
    set :xen_slope_warned, breath_slope
    puts "XENAKIS: slope #{breath_slope} deg drops the breath to " \
         "#{slope_end_z.round(2)} m, under the #{speaker_z} m speaker plane - " \
         "clamped. That is a page angle from the drawing, not a hall angle."
  end

  # HOW A GRAIN IS PLACED - :continuous (the original) or :discrete.
  #
  # Continuous splits every grain across the two channels either side of its
  # position, at constant power, so the cloud moves as a phantom image gliding
  # between speakers. That image is the most fragile thing in the piece here.
  # The in-situ capture found reflections at 0.62 / 1.60 / 4.96 ms at -14 to
  # -16 dB re direct - inside the fusion window, where they broaden and shift
  # a phantom - and 2-3 m/s of air movement in the hall phase-modulates 8 kHz,
  # whose wavelength is 4.1 cm. A phantom also only holds in a sweet spot: off
  # axis the precedence effect collapses it onto the nearer speaker, and this
  # is an installation people walk through.
  #
  # Discrete sends each grain WHOLE to ONE speaker, chosen probabilistically
  # (see the fold below). A real source cannot collapse, so the image stays put
  # from every seat, and the ear reconstructs the trajectory from the sequence
  # the way it reads apparent motion. The trade is granularity: at low density
  # the cloud can start to read as separate points rather than as movement.
  #
  # Kept as a live switch precisely because that trade can only be judged in
  # the room. Flip it mid-run while walking the hall.
  pan_mode    = get(:xen_pan_mode, :continuous)

  # THE TRAJECTORY - :scatter (the original) or :sweep.
  #
  # Orthogonal to xen_pan_mode: pan_mode decides how a grain reaches the
  # speakers, traj_mode decides where in the drawing it is in the first place.
  # All four combinations are legal and they sound like four different pieces.
  #   scatter + continuous  the original: a cloud with a phantom image
  #   scatter + discrete    a cloud, each grain on one speaker
  #   sweep   + continuous  a glissando gliding between speakers
  #   sweep   + discrete    a glissando stepping speaker to speaker
  traj_mode   = get(:xen_traj_mode, :scatter)
  # Sweeps across one phase, for the first cloud; the second runs at twice
  # this. Phase-relative, not seconds, so it keeps its shape if the breath
  # timing ever changes.
  traj_cycles = get(:xen_traj_cycles, 3.0)
  # Thickness of the swept line, as a fraction of the span's half-width.
  # 0.0 = a single travelling point, 1.0 = as wide as the span (which is
  # :scatter again, only phase-locked).
  traj_width  = get(:xen_traj_width, 0.12)

  # THE VACUUM (0b-ter) - how hard the travelling hole is dug, 0.0 = off.
  # One knob for all three cues, so they cannot drift apart: the duck, the
  # drop and the below-tilt are all scaled by it.
  vac_amt = get(:xen_vacuum, 0.0)
  # The path folds like every other gesture on a smaller rig. At 12 it is the
  # floor plan's own 5 -> 6 -> 10 -> 9; below that xen_spread distributes four
  # positions round whatever is there, so the studio keeps the RELATIONSHIP -
  # a hole crossing from one pair to another - and loses only the geometry.
  # (The beds' own fold is modular AND deduped, so the absolute channels 5-10
  # simply do not exist under 12 outputs; matching on them would make this a
  # silent no-op in the studio, which is the worst of the three outcomes.)
  vac_chans = rig_outputs >= 12 ? vac_path.map(&:first) : xen_spread(rig_outputs, 4)
  vac_when  = vac_chans.zip(vac_path.map(&:last)).to_h
  # Linear gain for the duck. dB because a hole is heard in dB.
  vac_gain  = 10.0 ** (vac_db * vac_amt / 20.0)

  # THE SPILL - how many of the exhale's grains are carried over the cycle
  # boundary to cover the seam, and to fill whatever void xen_void leaves
  # before them. 0 is a bare turn. Live, unlike the void itself: what the
  # boundary sounds like can only be judged by standing in it. See play_spill
  # (1c) and README 8h.
  spill_n     = get(:xen_spill, 5).to_i

  # REAL GEOMETRY (Hala MX floor plan + the Aug 6 sketch):
  # 12 physical monitors, ALL at the same height, Z = 1.8 m, arranged in two
  # HORIZONTAL hexagons, side by side along the length of the hall:
  #
  #   ZONE 1 - INHALE (2D hexagon)      ZONE 2 - EXHALE (2D hexagon)
  #        channels 1..6                     channels 7..12
  #        all at Z = 1.8 m                  all at Z = 1.8 m
  #
  # There is NO speaker overhead. There is no vault, no physical slope.
  # (There used to be a ceiling/slope/floor scheme here, wrongly inferred
  # from the early comments - it was false and stayed in the code for a
  # while.)
  #
  # Verticality is ENTIRELY psychoacoustic. The 11 theoretical nodes
  # (nodes.tsv) have Z between 2.5 and 4.0 m, i.e. in open air above the
  # speakers; their height is conveyed through Blauert's directional bands,
  # not through speakers:
  #     ~7-10 kHz boosted  -> heard ABOVE
  #     ~3 kHz boosted     -> heard BEHIND / below
  # That's why "the upper quad" is a psychoacoustic statement, not a
  # position.
  # On fewer outputs: every gesture is re-scaled separately over what's
  # available.
  if rig_outputs >= 12
    # Both breath phases are now continuous clouds (see cloud_*); the
    # discrete map only remains for M=0's two quads.
    quad_ceil   = [1, 2, 11, 12]       # the "upper" scalpel
    quad_floor  = [5, 6, 7, 8]         # the funnel
    # The atmosphere's M=0 accent keeps the original upper set whatever the
    # grains do below: it is a bed, not a grain, and xen_m0_confine is about
    # the GRANULAR layer only.
    quad_accent = [1, 2, 11, 12]
    # CONFINE: every M=0 grain onto 5-8 and nothing anywhere else. Costs the
    # funnel-vs-scalpel separation by construction - both halves land on the
    # same four speakers and sum there - so it is off by default.
    quad_ceil = quad_floor.dup if m0_confine
  else
    quad_ceil   = xen_spread rig_outputs, 4
    quad_floor  = xen_spread rig_outputs, 4
    quad_accent = quad_ceil
  end

  play_inhale = [:all, :inhale].include?(focus)
  play_ceil   = [:all, :m0, :m0_ceil].include?(focus)
  play_floor  = [:all, :m0, :m0_floor].include?(focus)
  play_exhale = [:all, :exhale].include?(focus)

  # The trailing half of the void (xen_void), and the counterpart of `lead` at
  # the start. 0.0 by default: the exhale runs to the cycle boundary and the
  # next inhale starts on it. A single-gesture focus keeps a second of air
  # around the thing being tuned, which is a working convenience, not the
  # piece.
  gap = (focus == :all) ? trail : 1.0

  # Only log when something changes, so we always know what's active.
  cfg_now = [rig_outputs, focus]
  if cfg_now != get(:xen_cfg_reported)
    set :xen_cfg_reported, cfg_now
    puts "XENAKIS: rig=#{rig_outputs} outputs, focus=#{focus}"
  end

  synth :pretty_bell, note: :c7, release: 0.5, amp: 0.35 if bleep  # start of cycle

  # ==========================================
  # ATMOSPHERE - holds the whole cycle, the granular material fades in/out under it
  # ==========================================
  atm = get(:atmos_n0)
  if atmos_on && atm
    # The beds: inhale on hexagon A (1-6), exhale on hexagon B (7-12).
    # a/b are decorrelated (measured ~0.00), so we put them on alternating
    # vertices: two distinct sources enveloping the space, not one panned
    # source.
    # attack/release = atmos_margin, and the bed lives bed_overlap longer than
    # the cycle, so consecutive sets cross-fade at the boundary instead of
    # both passing through zero there.
    atmos_beds = { atm[:inh_a] => [1, 3, 5], atm[:inh_b] => [2, 4, 6],
                   atm[:exh_a] => [7, 9, 11], atm[:exh_b] => [8, 10, 12] }

    # On a smaller rig the twelve vertices wrap round the outputs available -
    # the same modular fold xen_spread uses for the M=0 quads. Unlike the
    # clouds, which compress their whole drawing, the beds are four fixed
    # sources: what has to survive is that a and b stay on DIFFERENT speakers,
    # and the wrap gives exactly that. On four outputs both a-beds land on
    # 1,3 and both b-beds on 2,4, so the two decorrelated sources still
    # envelop the space instead of collapsing onto one speaker.
    #
    # uniq is not cosmetic: 1,3,5 folds to 1,3,1 on four outputs, and without
    # it the same file would play twice on speaker 1 - correlated with itself,
    # so +6 dB rather than +3.
    if rig_outputs < 12
      atmos_beds = atmos_beds.map { |f, chans|
        [f, chans.map { |ch| ((ch - 1) % rig_outputs) + 1 }.uniq]
      }.to_h
    end

    # Constant TOTAL power, not constant per-speaker level.
    #
    # This used to divide each bed by sqrt(beds sharing its speaker), which
    # held every SPEAKER at the level the material was measured at. The
    # clouds do the OPPOSITE: folding the drawing onto fewer outputs keeps
    # every grain, so their total radiated power is rig-independent and only
    # the per-channel density goes up (inhale spans 1..6, so at 4 outputs
    # that is x1.5 per channel). The beds gave away exactly what the clouds
    # kept: at 4 outputs the twelve bed slots fold to eight and each was cut
    # 3 dB, so the bed radiated 4/12 of the hall's power into the room while
    # the granular material radiated all of it. That is 4.8 dB of balance
    # shift that exists ONLY on the reduced rig - which is why turning
    # xen_atmos_amp up in the studio never bought what it said it did, and
    # why the bed kept sounding under the grains here but not in the hall.
    #
    # So normalize on the number of bed SLOTS, referenced to the 12-output
    # hall: at 12 this is exactly 1.0 and nothing about the hall changes; at
    # 4 the eight surviving slots each come up by sqrt(12/8) = +1.8 dB and
    # the bed keeps its weight against the clouds.
    #
    # The beds sharing a speaker are decorrelated (measured ~0.00), so they
    # sum by power and not by amplitude, and the tanh below is the ceiling
    # for that pileup exactly as it is for the clouds. These outputs bypass
    # the master limiter, so on a rig much smaller than 4 (where the slots
    # collapse further and this factor keeps climbing) the beds want a lower
    # xen_atmos_amp - the compensation is deliberately not capped, because
    # capping it would silently reintroduce the imbalance it exists to fix.
    bed_slots = atmos_beds.values.flatten.size
    bed_scale = Math.sqrt(12.0 / bed_slots)

    # each_with_index, so the insertion order above IS the partial order:
    # inh_a, inh_b, exh_a, exh_b -> partials 1, 2, 3, 4.
    atmos_beds.each_with_index do |(f, channels), i|
      # The partial this bed rings at. Stretch 1.0 is a plain harmonic
      # series; above it the series widens the way a struck bar's does,
      # which is the usual way to keep a spectrum from sounding like an
      # organ chord.
      bed_note = hz_to_midi(midi_to_hz(spec_f0) * ((i + 1) ** spec_stretch))
      n_ch = channels.size
      channels.each_with_index do |ch, ch_i|
        in_thread do
          # The travelling amplitude wave, as a lambda so it can be called
          # from inside whichever FX nesting the spectral branch builds -
          # running it outside would tear the band_eq down underneath it.
          #
          # CONSTANT POWER, and this is the whole reason the shape is what it
          # is. With the channels' phases equally spaced by 2*pi/n,
          #     sum_i cos(theta - 2*pi*i/n) = 0   for n >= 2
          # so with amp_i^2 = base^2 * (1 + d*cos(...)), the sum of amp^2 over
          # the bed's channels is base^2 * n at EVERY instant. The level never
          # pumps; only its distribution turns. That holds at n = 3 in the
          # hall and n = 2 on the folded studio rig - but not at n = 1, where
          # there is nothing to rotate against, hence the guard.
          # i is the insertion order of atmos_beds - inh_a, inh_b, exh_a,
          # exh_b - the same index the partials are taken from, so 0..1 is
          # the inhale hexagon and 2..3 the exhale one.
          phase_trim = i < 2 ? atmos_inh_amp : atmos_exh_amp
          bed_amp = atmos_amp * phase_trim * master_amp * bed_scale
          rotate = lambda do |node|
            steps = (bed_dur / rot_step).floor
            steps.times do
              # vt, not a local counter: the phase has to stay continuous
              # ACROSS cycles, or the rotation resets every breath and the
              # second clock collapses back onto it.
              th = 2 * Math::PI * (vt / rot_period - ch_i.to_f / n_ch)
              g  = [1.0 + rot_depth * Math.cos(th), 0.0].max
              control node, amp: bed_amp * Math.sqrt(g)
              sleep rot_step
            end
          end
          # THE VACUUM (0b-ter), for the four channels on its path. Three
          # cues, all of them CONTROL messages on nodes that already exist,
          # so the whole gesture costs no voices at all:
          #
          #   1. the duck  - the tanh's own amp, which is post-saturation and
          #      linear (README 8f). Not the sample's amp: the rotation
          #      writes that one every rot_step and the two would fight.
          #   2. the drop  - pitch_slide on the bed. Free because bed_overlap
          #      put PitchShift permanently in circuit (README 8a): the
          #      shifter is already there, and sliding it costs a message.
          #      RELATIVE to bed_semis, which is EXACTLY the pitch the bed
          #      is already holding: pitch_stretch resolves to
          #      `pitch -= ratio_to_pitch(bed_len / bed_dur)` at trigger time
          #      (sound.rb:3745), which is the same +12.5 semitones at the
          #      32 s cycle. Writing an absolute pitch here would throw the
          #      compensation away and drop the bed an octave. It is exact
          #      only because every atmos slice is the same length - all 434
          #      of them are 16.000 s, atmos_slice.py cutting each family at
          #      the same SLICE_S - so one bed_len describes every bed.
          #   3. the tilt  - Blauert's pair INVERTED: -9 dB at 8372 Hz and
          #      +6 dB at 3136 Hz is the "above" chord read backwards, i.e.
          #      behind and below. This is the only place in the piece that
          #      voices anything under the speaker plane - breath_tilt
          #      deliberately clamps at it, and the comment there calls going
          #      below "the -25 deg mistake coming back". The exception is
          #      deliberate: the vacuum is not the breath's path, it is what
          #      the breath is being pulled into.
          #
          # It runs in its own thread so it does not race the rotation for
          # the bed thread's time. with_fx joins the threads its block
          # spawned before tearing the chain down (sound.rb:1818), so the
          # nodes are guaranteed to outlive the gesture.
          on_path = vac_amt > 0.001 && vac_when.key?(ch)
          vacuum = lambda do |bed, tanh_fx, eq_hi, eq_lo|
            in_thread do
              # The spill has to have landed first - this is the gesture that
              # answers it, not one that interrupts it.
              sleep lead + spill_into + vac_when[ch] * vac_cross
              control tanh_fx, amp: out_trim * vac_gain, amp_slide: vac_in
              control bed, pitch: bed_semis + vac_semis * vac_amt, pitch_slide: vac_in
              control eq_hi, db: -blauert_hi_db * vac_tilt * vac_amt, db_slide: vac_in
              control eq_lo, db: -blauert_lo_db * vac_tilt * vac_amt, db_slide: vac_in
              sleep vac_in + vac_hold
              control tanh_fx, amp: out_trim,  amp_slide: vac_out
              control bed, pitch: bed_semis,   pitch_slide: vac_out
              control eq_hi, db: 0,            db_slide: vac_out
              control eq_lo, db: 0,            db_slide: vac_out
              sleep vac_out
            end
          end

          with_fx :sound_out, output: ch, amp: 0 do
            with_fx :compressor, threshold: enh_thr, slope_below: enh_below,
                                slope_above: enh_above, clamp_time: 0.01,
                                relax_time: 0.25 do
              with_fx :tanh, krunch: 0.25, amp: out_trim do |tanh_fx|
                # Inside the tanh, like every other boost in the piece: the
                # resonance is part of what the ceiling has to catch. A
                # Q ~17 peak only lifts a sliver of the band, so the
                # broadband cost is far smaller than the dB figure looks -
                # but it is not zero, and it lands at 131 Hz where 56% of
                # the bed's energy already is.
                #
                # At 0 dB the FX is SKIPPED, not merely flat. A band_eq at
                # 0 dB is transparent but still a node doing per-sample
                # work, which made xen_atmos_spectral useless as an off
                # switch when we needed to A/B the DSP cost.
                # amp_slide is only set when the rotation is actually on -
                # at depth 0 the bed is triggered exactly as it always was,
                # the lambda returns without sleeping, and the thread ends
                # immediately, so nothing about the old path changes.
                rot_on = rot_depth > 0.001 && n_ch >= 2
                slide  = rot_on ? rot_step : 0
                # pitch_stretch: the bed is one slice stretched over the
                # whole breath AND the overlap into the next one, not a slice
                # plus silence - see bed_dur / bed_stretch. It no longer
                # resolves to rate 1.0 / pitch 0 at any cycle length: the
                # overlap makes the shortest stretch 1.06 (see bed_overlap).
                #
                # Lambdas rather than four nested branches: the bed is now
                # wrapped by two independent optional pairs (the spectral
                # partial, the vacuum's band pair), and spelling out every
                # combination would be four copies of the same `sample`.
                play_bed = lambda do |eq_hi, eq_lo|
                  bed = sample f, pitch_stretch: bed_dur,
                                  amp: bed_amp, amp_slide: slide,
                                  attack: atmos_margin, release: atmos_margin
                  vacuum.call(bed, tanh_fx, eq_hi, eq_lo) if on_path
                  rotate.call(bed) if rot_on
                end
                spectral = lambda do |eq_hi, eq_lo|
                  if spec_db.abs < 0.01
                    play_bed.call(eq_hi, eq_lo)
                  else
                    with_fx :band_eq, freq: bed_note, res: spec_res, db: spec_db do
                      play_bed.call(eq_hi, eq_lo)
                    end
                  end
                end
                # The vacuum's pair is instantiated FLAT and slid later, which
                # is the one place the piece cannot use its usual "skip at
                # 0 dB" rule - there is nothing to skip to when the value
                # arrives two seconds after the node does. It costs two nodes
                # on four channels, and only while xen_vacuum is up.
                if on_path
                  with_fx :band_eq, freq: blauert_hi_note, res: blauert_res, db: 0 do |eq_hi|
                    with_fx :band_eq, freq: blauert_lo_note, res: blauert_res, db: 0 do |eq_lo|
                      spectral.call(eq_hi, eq_lo)
                    end
                  end
                else
                  spectral.call(nil, nil)
                end
              end
            end
          end
        end
      end
    end

    # The vertical layer from M=0: enters together with the burst, louder
    # than the grains, with the Blauert accent at 8 kHz so it's heard ABOVE.
    in_thread do
      # lead, not atmos_margin: this has to be the same sum the main thread
      # sleeps to reach M=0 (lead + inhale_dur + inhale_pause), or the accent
      # lands beside the burst instead of on it.
      sleep lead + inhale_dur + inhale_pause
      [atm[:m0_up], atm[:m0_pz]].each do |f|
        quad_accent.each do |ch|
          in_thread do
            with_fx :sound_out, output: ch, amp: 0 do
              with_fx :tanh, krunch: 0.25, amp: out_trim do
                with_fx :band_eq, freq: blauert_hi_note, res: blauert_res,
                                  db: blauert_hi_db do
                  sample f, amp: atmos_m0amp * master_amp,
                            finish: 0.35, attack: 0.05, release: 3.0
                end
              end
            end
          end
        end
      end
    end
  end

  sleep lead   # granular silence before the inhale - 0.0 by default, so the
               # beds and the first grains now enter together (xen_void)

  # ==========================================
  # PHASE 1: INHALE (fluid descent along the -12° slope, now actually voiced)
  # ==========================================
  if play_inhale
    if grains_on
      play_cloud_phase dur: inhale_dur, rig: rig_outputs,
                       enh_thr: enh_thr, enh_below: enh_below, enh_above: enh_above,
                       pan_mode: pan_mode,
                       traj_mode: traj_mode, traj_cycles: traj_cycles,
                       traj_width: traj_width,
                       pitch_from: inhale_rate_from, pitch_to: 0.95, pitch_jit: 0.04,
                       # lpf_to was 75 - MIDI, so 622 Hz. The 17 Sep capture
                       # (README 10) measured clarity at four positions and
                       # NOTHING localises at all of them below 1 kHz: BACK has
                       # no usable clarity under 700 Hz, FRONT none under 150.
                       # So the descent used to hand the phase down INTO the
                       # dead band - the inhale became progressively harder to
                       # place exactly as it approached M=0, which is backwards
                       # for the one gesture that is supposed to be travelling.
                       #
                       # 88 is 1318 Hz: inside the 1-3 kHz window that works at
                       # every position, and the same value the exhale opens on
                       # (lpf_from: 88 below), so the two phases now meet at M=0
                       # instead of the inhale disappearing under it. Still 2.4
                       # octaves of darkening from 8372 Hz, so the descent reads
                       # as a descent; it just stops before it stops localising.
                       lpf_from: inhale_lpf_from, lpf_to: 88, lpf_jit: 3,
                       amp_lo: 0.155 * master_amp * grains_amp, amp_hi: 0.31 * master_amp * grains_amp,
                       # down the slope: full height at S1, the speaker plane
                       # by M=0.
                       blauert: blauert_ramp.call(tilt_top, tilt_bottom, blauert_amt),
                       clouds: [cloud_positive.merge(pool: pool_inhale_high),
                                cloud_negative.merge(pool: pool_inhale_mid)]
    else
      sleep inhale_dur   # grains muted - hold the phase
    end
    sleep inhale_pause
  end

  # ==========================================
  # PHASE 2: THE CRITICAL POINT M=0 (FLOOR MELTS VS. CEILING SCALPEL)
  # ==========================================

  # A. THE UPPER QUAD - SHARP PSYCHOACOUSTIC SCALPEL EFFECT
  if play_ceil && grains_on
    in_thread do
      # Surgically cutting the lows/mids: the HPF only lets very high, sharp
      # frequencies through. The cutoff is chosen once for the whole gesture,
      # as before.
      ceil_cutoff = rrand(102, 108)
      variant = m0_ceil_variants.choose
      quad_ceil.each_with_index do |quad_chan, i|
        in_thread do
          with_fx :sound_out, output: quad_chan, amp: 0 do
            with_fx :tanh, krunch: 0.25, amp: m0_amp * m0_ceil_trim * grains_amp * m0_pair_scale * out_trim,
                            amp_slide: m0_fade do |vol|
              # amp: 6 is makeup gain, placed AFTER the filter - the HPF cuts
              # ~76% of the energy; without it the scalpel would be the
              # weakest layer in the piece.
              with_fx :hpf, cutoff: ceil_cutoff, amp: 6.0 do
                # Directional bands (Blauert): height is suggested through
                # SPECTRUM, the only way - there's no speaker overhead.
                # The material had 22.7% of its RMS at 3 kHz (the "behind"
                # band) and only 12.6% at 8 kHz (the "above" band), so it was
                # pulling downward. We boost 8 kHz and cut 3 kHz to reverse
                # the ratio.
                # Blauert's bands are wide - about an octave - and these
                # now actually are. They used to sit at res 0.8 under the
                # belief that higher res meant wider; it means the reverse
                # (rq = 1 - res, rq = 1/Q), so they were Q 5, ~0.29 octaves.
                # See blauert_res for the derivation. This widens a gesture
                # that was rehearsed narrow: the cue gets broader and less
                # whistly, and the 3 kHz cut takes more of the "behind"
                # band with it.
                with_fx :band_eq, freq: blauert_hi_note, res: blauert_res,
                                  db: blauert_hi_db do
                  with_fx :band_eq, freq: blauert_lo_note, res: blauert_res,
                                    db: blauert_lo_db do
                    with_fx :flanger, phase: 0.04, depth: 0.85, feedback: 0.7 do
                      sample variant[i], amp: master_amp
                      sleep m0_dur                 # burst at full level
                      control vol, amp: 0.0        # then the long ramp
                      sleep m0_fade
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # Haas effect calibrated at 35 milliseconds to trick the localization of
  # the reflection off the building's ridge
  # (only matters when both layers are sounding)
  sleep 0.035 if play_ceil && play_floor

  # B. THE PHYSICAL FUNNEL AT THE FEET (the low monitors at 1.8m)
  if play_floor && grains_on
    in_thread do
      variant = m0_floor_variants.choose
      quad_floor.each_with_index do |floor_chan, i|
        in_thread do
        with_fx :sound_out, output: floor_chan, amp: 0 do
          with_fx :tanh, krunch: 0.25, amp: m0_amp * m0_floor_trim * grains_amp * m0_pair_scale * out_trim,
                          amp_slide: m0_fade do |vol|
            # The grain amplitudes are already baked into the render, as the
            # ATTACK stage of the distortion (dry peak ~3.1 - that's why the
            # renders are float32). The distortion's amp, which carries
            # master_amp, sets the final level.
            with_fx :distortion, distort: 0.8, amp: 1.3 * master_amp do
              with_fx :lpf, cutoff: 70 do # sub-bass and low-mids (466 Hz)
                sample variant[i]
                sleep m0_dur                 # burst at full level
                control vol, amp: 0.0        # then the long ramp
                sleep m0_fade
              end
            end
          end
        end
        end
      end
    end
  end

  sleep m0_dur + m0_tail if play_ceil || play_floor # shockwave absorbed into Hala MX's natural reverb

  # ==========================================
  # PHASE 3: EXHALE (fluid stochastic rise along the +12° slope, now voiced)
  # ==========================================
  if play_exhale
    if grains_on
      # The POSITIVE mass (dense) is the shatter, which flies up to the
      # ceiling.
      # The NEGATIVE mass (sparse) is the pressure, which stays low, near the
      # ground.
      play_cloud_phase dur: exhale_dur, rig: rig_outputs,
                       enh_thr: enh_thr, enh_below: enh_below, enh_above: enh_above,
                       pan_mode: pan_mode,
                       traj_mode: traj_mode, traj_cycles: traj_cycles,
                       traj_width: traj_width,
                       pitch_from: 0.8, pitch_to: exhale_rate_to, pitch_jit: 0.06,
                       # lpf_from matters MORE than the amplitude here:
                       # the "shatter" material loses 10.5 dB through the
                       # filter at 75 (622 Hz) - practically making the
                       # entrance inaudible - versus 0 dB at the inhale's
                       # entrance, which starts at 120 (8372 Hz). At 88 (1318
                       # Hz) the loss drops to ~6 dB. Grain fusion is now
                       # handled by the "long only" pools, not by darkening
                       # the filter.
                       lpf_from: 88, lpf_to: exhale_lpf_to, lpf_jit: 4,
                       amp_lo: exhale_amp_lo * master_amp * grains_amp, amp_hi: 0.345 * master_amp * grains_amp,
                       entry_amp: 2.4,
                       # back up it: the exhale is the inhale's ramp reversed,
                       # leaving M=0 on the plane and recovering S11's 4.00 m.
                       blauert: blauert_ramp.call(tilt_bottom, tilt_top, blauert_amt),
                       clouds: [cloud_exhale_positive.merge(pool: pool_exhale_shatter),
                                cloud_exhale_negative.merge(pool: pool_exhale_pressure)]
    else
      sleep exhale_dur   # grains muted - hold the phase
    end
  end

  synth :pretty_bell, note: :c6, release: 0.8, amp: 0.35 if bleep  # the exhale has ended

  # THE SPILL (1c). Fired here, at the exhale's last instant, and running
  # through `sleep gap`, the next cycle's `lead`, and spill_into seconds of
  # the inhale itself - hence that sum as its duration. At the default void
  # of 0.0 the first two terms are zero and the whole spill happens under the
  # inhale's entrance, which is the point: there is no silence left to fill,
  # only a seam to cover. play_spill detaches immediately, so this costs the
  # cycle no time at all.
  if play_exhale && grains_on && spill_n > 0
    play_spill n: spill_n, dur: gap + lead + spill_into, rig: rig_outputs,
               pan_mode: pan_mode, pool: pool_exhale_shatter,
               # the shatter, not the pressure: the pressure is the low layer
               # that stays near the ground, and what should still be in the
               # air when a breath ends is what flew up.
               from_span: cloud_exhale_positive[:span1],
               to_span:   cloud_positive[:span0],
               rate_from: exhale_rate_to, rate_to: inhale_rate_from, rate_jit: 0.04,
               lpf_from:  exhale_lpf_to,  lpf_to:  inhale_lpf_from,  lpf_jit: 3,
               # Starts at the exhale's amp_lo - its QUIETEST grain, not an
               # average - and decays 10.5 dB from there across the boundary.
               # It has to stay audible under a bed that is mid-crossfade and
               # an inhale that is entering, without ever reading as a sixth
               # phase of the breath: it ends 11.6 dB under the inhale's own
               # quietest grain, which is where a residue belongs.
               amp_from: exhale_amp_lo * master_amp * grains_amp,
               amp_to:   0.041 * master_amp * grains_amp,
               # Held at the top of the slope: the exhale arrives there and
               # the inhale leaves from there, so the height cue does not dip
               # in the middle of the handover.
               blauert: blauert_ramp.call(tilt_top, tilt_top, blauert_amt)
  end

  sleep gap # the stochastic breathing void
end
