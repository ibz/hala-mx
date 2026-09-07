# Extreme Xenakian Installation - Hala MX (12 Channels)
#
# LIBRARY - not configured here.
# All runtime parameters are set from the Sonic Pi workspace:
#
#   set :xen_rig_outputs, 4        # 12 = Hala MX, 4 = UMC404HD in the studio
#   set :xen_focus, :inhale        # :inhale :exhale :m0 :m0_ceil :m0_floor :all
#
# They're read at the start of every breath, so they can change on the fly.

# project_dir: set by the workspace via `set :xen_project_dir` (see
# sonic-pi-buffer.rb) from wherever it points `piece` at. run_file doesn't
# execute this file as a real Ruby file, so __FILE__ can't self-locate here -
# the fallback below is only a safety net if this is ever run standalone.
project_dir = get(:xen_project_dir, "/home/ibz/src/hala-mx")
path_base   = project_dir + "/output_xenakis_installation/"
path_inhale = path_base + "inhale/"
path_blast  = path_base + "sonic_blast_m0/"
path_exhale = path_base + "exhale/"

use_bpm 60

# Lookahead: the M=0 rain is a short, very dense burst, and with the default
# 0.5s the threads can't queue it in time (TimingError). For an installation,
# latency doesn't matter.
#
# NOTE: `use_sched_ahead_time`, NOT `set_sched_ahead_time!`.
# The `!` variant writes to a global state, and reading it back
# (__current_sched_ahead_time, runtime.rb:507) calls `.val` on the result
# WITHOUT checking for nil - hence "undefined method `val' for nil". The
# variant without `!` sets a thread-local, which is checked FIRST (`||`) and
# can never be nil. System thread-locals are inherited, so the live_loop and
# all of its per-channel threads pick it up automatically.
use_sched_ahead_time 2.0

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
# One cycle = 16.0 s, exactly as long as one atmos file. The granular phases
# were stretched to fit, keeping the inhale:exhale ratio of 1 : 1.2 from the
# earlier, shorter version. The densities (lambda) DIDN'T change: being
# grains/second, the texture stays the same and so does the scheduler's event
# rate - only the gesture takes longer. The ramps (pitch, lpf, blend,
# entry_amp) are normalized on f = t/duration, so they stretch on their own.
cycle_dur    = 16.0
# Atmos holds the whole cycle; the granular material sits INSIDE it, with a
# margin at each end. That way atmos really does start before and end after.
atmos_margin = 1.0
# M=0 falls exactly at the midpoint of the cycle - the same point as node S6
# and the geometric midpoint of the bridge between the hexagons (N_6, Y = 500
# cm). The atmos and granular centers have to coincide.
m0_center    = 8.0
cloud_positive = { span0: [1.0, 3.0], span1: [4.0, 6.0], lambda: 24.0 }
cloud_negative = { span0: [2.0, 4.0], span1: [3.0, 5.0], lambda:  8.0 }

# M=0: how long the burst lasts at full density. The density and tail are
# baked into the renders (render_m0.py: M0_TAIL, K_DENS, K_AMP).
m0_dur = 0.45
# How long we wait after the burst before the exhale. The rendered tail is
# still sounding at this point and has dropped ~20 dB, so the exhale doesn't
# start from dead silence - it emerges from under the thinning rain. Too
# short = the tail covers the exhale (which is very soft anyway); too long =
# the gap comes back abruptly.
m0_tail = 1.2
# M=0's long volume ramp. Applied to the tanh's amp, i.e. AFTER the
# distortion/hpf - a saturator flattens any level drop that happens before
# it, so a ramp baked into the render would barely be audible. Runs over the
# whole exhale, so the transition is a cross-fade, not a cut.
m0_fade = 5.0
# M=0's overall level. Also applied to the tanh's amp, for the same reason as
# the ramp: the amps before the distortion/hpf are the ATTACK stage of a
# saturator, not the output level - you could cut them in half and barely
# hear it. This is the one place where a reduction is actually audible.
# 1.0 = what it used to be; 0.7 ~= -3 dB.
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
# The granular phases, equal and symmetric around m0_center.
inhale_dur = m0_center - m0_dur / 2.0 - atmos_margin - inhale_pause - 0.035
exhale_dur = cycle_dur - atmos_margin - (m0_center + m0_dur / 2.0 + m0_tail)
cloud_exhale_positive = { span0: [7.0,  9.0], span1: [10.0, 12.0], lambda: 32.0, shape: 3 }
cloud_exhale_negative = { span0: [8.0, 10.0], span1: [ 9.0, 11.0], lambda: 11.0, shape: 3 }

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
  # --- the drawing's bounds, so we can fold it onto a smaller rig ---
  lo_d = o[:clouds].map { |c| [c[:span0][0], c[:span1][0]].min }.min
  hi_d = o[:clouds].map { |c| [c[:span0][1], c[:span1][1]].max }.max

  # --- 1. the whole timeline is built in the parent thread ---
  events = []
  o[:clouds].each do |c|
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
      pos = rrand(lo, hi)
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

      pool = c[:pool]
      cut = pool[:cuts].choose
      rate = o[:pitch_from] + (o[:pitch_to] - o[:pitch_from]) * f + rrand(-o[:pitch_jit], o[:pitch_jit])
      lpf  = o[:lpf_from] + (o[:lpf_to] - o[:lpf_from]) * f + rrand(-o[:lpf_jit], o[:lpf_jit])

      ev = { t: t, wav: pool[:wav], start: cut[:start], finish: cut[:finish],
             rate: rate, lpf: lpf }
      events << ev.merge(chan: ch,     amp: amp_a) if amp_a > 0.05
      events << ev.merge(chan: ch + 1, amp: amp_b) if amp_b > 0.05
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
        # The same soft ceiling as M=0. tanh sees the SUM of the grains
        # overlapping on a channel, so it catches exactly the unpredictable
        # pileups of the Poisson process - the only place the clouds could
        # exceed 1.0.
        with_fx :tanh, krunch: 0.25 do
          prev = 0.0
          mine.each do |e|
            sleep e[:t] - prev
            prev = e[:t]
            # lpf: this is the sampler's INTERNAL filter, not a separate FX.
            # Every grain carries its own cutoff, so there's no need for
            # either an :lpf synth per channel or a `control` message per
            # grain - exactly the per-event work that was leaving the
            # threads behind.
            sample e[:wav], start: e[:start], finish: e[:finish],
                   amp: e[:amp], rate: e[:rate], lpf: e[:lpf],
                   attack: 0.01, release: 0.06
          end
          sleep o[:dur] - prev
        end
      end
    end
  end

  sleep o[:dur]
end

# 1d. THE ATMOSPHERE LOADER THREAD
# Prepares the next cycle's set and frees the set from TWO cycles ago - not
# the previous one, which might still be sounding on its tail.
live_loop :atmos_loader do
  # Administrative loop: triggers no sound, so it needs no precision.
  # Without this it would get killed by a TimingError right during loading.
  use_sched_ahead_time 60

  sleep cycle_dur - 4.0        # let the current cycle keep sounding
  upcoming = atmos_set.call
  upcoming.each_value { |f| load_sample f }

  to_free = get(:atmos_n1)
  set :atmos_n1, get(:atmos_n0)
  set :atmos_n0, upcoming
  sample_free(*to_free.values) if to_free

  sleep 4.0
end

# 2. THE INSTALLATION'S MAIN LOOP
# seed: applied ONCE, when the loop's thread starts - so the random flow
# evolves from one breath to the next, but the whole run repeats identically
# on a new Run. Changing the seed requires Stop + Run.
live_loop :xenakis_installation, seed: get(:xen_seed, 0) do

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
  atmos_on    = get(:xen_atmos, true)
  atmos_amp   = get(:xen_atmos_amp, 0.25)      # the bed, under the granular
  atmos_m0amp = get(:xen_atmos_m0_amp, 0.5)    # at M=0, OVER the granular

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
    quad_ceil   = [1, 2, 11, 12]       # the "upper" scalpel - the two hexagons' far ends
    quad_floor  = [5, 6, 7, 8]         # the funnel - the middle, where the hexagons meet
  else
    quad_ceil   = xen_spread rig_outputs, 4
    quad_floor  = xen_spread rig_outputs, 4
  end

  play_inhale = [:all, :inhale].include?(focus)
  play_ceil   = [:all, :m0, :m0_ceil].include?(focus)
  play_floor  = [:all, :m0, :m0_floor].include?(focus)
  play_exhale = [:all, :exhale].include?(focus)

  # The final void: long for a full breath, short when repeating a single
  # gesture to tune it.
  # The final void. For a full breath it's computed as the REMAINDER of
  # cycle_dur, so the cycle stays a fixed 16 s even if we change one phase.
  # The trailing margin, the counterpart of atmos_margin at the start.
  gap = (focus == :all) ? atmos_margin : 1.0

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
    # attack/release = atmos_margin -> fades in before and out after the
    # granular material.
    { atm[:inh_a] => [1, 3, 5], atm[:inh_b] => [2, 4, 6],
      atm[:exh_a] => [7, 9, 11], atm[:exh_b] => [8, 10, 12] }.each do |f, channels|
      channels.each do |ch|
        in_thread do
          with_fx :sound_out, output: ch, amp: 0 do
            with_fx :tanh, krunch: 0.25 do
              sample f, amp: atmos_amp * master_amp,
                        attack: atmos_margin, release: atmos_margin
            end
          end
        end
      end
    end

    # The vertical layer from M=0: enters together with the burst, louder
    # than the grains, with the Blauert accent at 8 kHz so it's heard ABOVE.
    in_thread do
      sleep atmos_margin + inhale_dur + inhale_pause
      [atm[:m0_up], atm[:m0_pz]].each do |f|
        quad_ceil.each do |ch|
          in_thread do
            with_fx :sound_out, output: ch, amp: 0 do
              with_fx :tanh, krunch: 0.25 do
                with_fx :band_eq, freq: 120, res: 0.8, db: 9 do
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

  sleep atmos_margin   # atmos only - the granular material enters after

  # ==========================================
  # PHASE 1: INHALE (fluid descent along the -12° slope)
  # ==========================================
  if play_inhale
    play_cloud_phase dur: inhale_dur, rig: rig_outputs,
                     pitch_from: 1.4, pitch_to: 0.95, pitch_jit: 0.04,
                     lpf_from: 120,   lpf_to: 75,     lpf_jit: 3,
                     amp_lo: 0.155 * master_amp, amp_hi: 0.31 * master_amp,
                     clouds: [cloud_positive.merge(pool: pool_inhale_high),
                              cloud_negative.merge(pool: pool_inhale_mid)]
    sleep inhale_pause
  end

  # ==========================================
  # PHASE 2: THE CRITICAL POINT M=0 (FLOOR MELTS VS. CEILING SCALPEL)
  # ==========================================

  # A. THE UPPER QUAD - SHARP PSYCHOACOUSTIC SCALPEL EFFECT
  if play_ceil
    in_thread do
      # Surgically cutting the lows/mids: the HPF only lets very high, sharp
      # frequencies through. The cutoff is chosen once for the whole gesture,
      # as before.
      ceil_cutoff = rrand(102, 108)
      variant = m0_ceil_variants.choose
      quad_ceil.each_with_index do |quad_chan, i|
        in_thread do
          with_fx :sound_out, output: quad_chan, amp: 0 do
            with_fx :tanh, krunch: 0.25, amp: m0_amp, amp_slide: m0_fade do |vol|
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
                # res = 1/Q: higher = wider band. Blauert's bands are wide,
                # about an octave.
                with_fx :band_eq, freq: 120, res: 0.8, db: 9 do
                  with_fx :band_eq, freq: 103, res: 0.8, db: -6 do
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
  if play_floor
    in_thread do
      variant = m0_floor_variants.choose
      quad_floor.each_with_index do |floor_chan, i|
        in_thread do
        with_fx :sound_out, output: floor_chan, amp: 0 do
          with_fx :tanh, krunch: 0.25, amp: m0_amp, amp_slide: m0_fade do |vol|
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
  # PHASE 3: EXHALE (fluid stochastic rise along the +12° slope)
  # ==========================================
  if play_exhale
    # The POSITIVE mass (dense) is the shatter, which flies up to the
    # ceiling.
    # The NEGATIVE mass (sparse) is the pressure, which stays low, near the
    # ground.
    play_cloud_phase dur: exhale_dur, rig: rig_outputs,
                     pitch_from: 0.8, pitch_to: 1.34, pitch_jit: 0.06,
                     # lpf_from matters MORE than the amplitude here:
                     # the "shatter" material loses 10.5 dB through the
                     # filter at 75 (622 Hz) - practically making the
                     # entrance inaudible - versus 0 dB at the inhale's
                     # entrance, which starts at 120 (8372 Hz). At 88 (1568
                     # Hz) the loss drops to ~6 dB. Grain fusion is now
                     # handled by the "long only" pools, not by darkening
                     # the filter.
                     lpf_from: 88,    lpf_to: 112,    lpf_jit: 4,
                     amp_lo: 0.138 * master_amp, amp_hi: 0.345 * master_amp,
                     entry_amp: 2.4,
                     clouds: [cloud_exhale_positive.merge(pool: pool_exhale_shatter),
                              cloud_exhale_negative.merge(pool: pool_exhale_pressure)]
  end

  synth :pretty_bell, note: :c6, release: 0.8, amp: 0.35 if bleep  # the exhale has ended

  sleep gap # the stochastic breathing void
end
