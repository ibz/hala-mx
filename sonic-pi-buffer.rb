# ============================================
# XENAKIS / HALA MX - CONFIGURATION DESK
# The only place anything gets configured.
# xenakis.rb is a library and doesn't get touched.
# ============================================

set :xen_rig_outputs, 12   # 12 = Hala MX, 4 = UMC404HD in the studio
set :xen_focus, :all       # :inhale :exhale :m0 :m0_ceil :m0_floor :all
set :xen_layers, :both     # :both :atmos (beds only) :grains (granular only)
set :xen_cycle_dur, 32.0   # one breath, in seconds. Read once per Run, so it
                           # needs Stop + Run. M=0 stays the midpoint, the phases
                           # stretch to fit, and the beds are pitch_stretched over
                           # the cycle (not looped, not transposed). Any length
                           # works; over 4x refused. Min ~6 s. README 8a.
set :xen_density, 1.0      # grain density multiplier. 0.5 was the workaround for
                           # 5.0's watchdog; 4.6 runs full density (see README 7)
set :xen_sched_ahead, 3.0  # scheduling lookahead for the breath loop. M=0 fires
                           # 16 threads inside 35 ms and overruns the 0.5 default
                           # by ~1.1 s (measured 1041/1192/1116 ms across three
                           # runs); 3.0 takes that to 4 ms.
                           # NOT free: lookahead is also queue depth, so this is
                           # ~6x more timestamped bundles parked in scsynth and
                           # ~228 nodes stranded per Stop rather than ~76. See
                           # README 4, "Lookahead, and why Stop is dangerous" -
                           # on 4.6 the tradeoff is spikes vs. Stop safety, not
                           # spikes vs. the piece dying, which is what it was on 5.0
set :xen_atmos_amp, 1.30   # the atmosphere bed - sits OVER the granular material
                           # rig-compensated: the same number is the same balance
                           # on 4 outputs in the studio and on 12 in the hall
                           # tuned by ear on the live desk, 2026-09-16
set :xen_atmos_inhale_amp, 1.41 # the inhale hexagon's beds (1-6), +3.0 dB over
                           # xen_atmos_amp - the two phases trim against each
                           # other, not just against the granular. Clipping is
                           # handled by xen_out_headroom now. README 8c.
set :xen_atmos_exhale_amp, 1.0  # the exhale hexagon's beds (7-12). Untouched.
set :xen_grains_amp, 0.75  # ALL granular material, UNDER the atmosphere - clouds
                           # AND M=0's grains. Lowered from 1.0 with the
                           # xen_atmos_amp raise; the funnel gets its own knob
                           # instead of raising this back. README 8b.
set :xen_atmos_m0_amp, 1.0 # tuned by ear on the live desk, 2026-09-16
set :xen_atmos_rotate, 0.0 # off
                           # the beds TURN. Depth 0.0-1.0 of a travelling
                           # amplitude wave around the channels each bed
                           # occupies (3 in the hall, 2 folded). Until this,
                           # the atmosphere was the one thing in the piece
                           # with no motion at all - inh_a sat on 1, 3, 5 at
                           # equal level for the whole 16 s.
                           # CONSTANT POWER by construction: the channel
                           # phases are equally spaced, so the sum of amp^2
                           # is identical at every instant (measured 0.000 dB
                           # ripple at any depth). The level never pumps,
                           # only its distribution turns. 0.6 gives a 6 dB
                           # per-channel swing
set :xen_atmos_rotate_period, 41.0 # seconds, and deliberately NOT a divisor
                           # of the 16 s cycle - it has to be a second clock
                           # or it just locks to the breath. 41 against 16
                           # repeats every 656 s. Re-check this against
                           # xen_cycle_dur if you change the cycle.
                           # A hall feature: on 4 outputs the beds fold to 2
                           # channels and the rotation is only an L-R sway # the atmosphere accent at M=0 - over the bed
set :xen_m0_ceil_amp, 1.4  # M=0's granular scalpel. Was 0.85 to leave room for the
                           # atmosphere accent; raised by ear 2026-09-17, which the
                           # accent affords now - it sits on quad_accent, not here.
set :xen_m0_confine, true  # EVERY M=0 grain on 5-8, nothing elsewhere. Costs the
                           # funnel-vs-scalpel separation; applies 1/sqrt(2) to
                           # each half automatically or it clips. README 8e.
set :xen_m0_fade, 1.5      # seconds for M=0 to ramp to silence, on the tanh amp -
                           # the only fade the room hears. 5.0 -> 2.5 -> 1.5 by ear:
                           # M=0 is done before the exhale, not across it. README 8d.
set :xen_m0_floor_amp, 2.5 # M=0's funnel, +7.9 dB - wins back most of what the
                           # xen_atmos_amp raise cost it. Past the old 1.66 ceiling,
                           # safe only because xen_out_headroom catches the sum.
set :xen_atmos_spectral, 10.0 # depth in dB of the beds' resonant partials
                           # turns the four broadband beds into four partials of
                           # one spectrum: noise in, pitch out.
                           # 10 measured: tonal prominence at the partial goes
                           # 2.3 -> 11.6 dB (clearly pitched, not a whistle) for
                           # +0.57 dB RMS. Headroom is NOT the limit here - two
                           # beds summing on one speaker at 4 outputs peak 0.250
                           # with this on, and the tanh takes 0.18 dB. Even 15
                           # only reaches 0.287, so this is a taste knob, not a
                           # safety one
set :xen_atmos_f0, 48      # MIDI - C3, 130.8 Hz, measured: 81.5% of the beds'
                           # energy is in 125-500 Hz and the family peaks are
                           # 145 / 192 / 132 / 127 Hz.
                           # Re-checked against alternatives and 48 is the right
                           # one: at MIDI 36 partial 1 lands on 65 Hz where the
                           # bed has -27 dB and does not ring at all (prominence
                           # 0.2 dB); MIDI 43 weakens partial 1 the same way.
                           # At 48 all four partials ring 9.7-13.4 dB
set :xen_atmos_stretch, 1.0 # 1.0 = harmonic partials, >1 = stretched/bell-like
set :xen_atmos_res, 0.94   # band width: HIGHER = NARROWER (rq = 1 - res), 0.94 ~ Q 17
set :xen_breath_slope, 12.0 # the score's alpha/beta, in degrees - the breath drops
                           # from 4.00 m to the 1.80 m speaker plane by M=0.
                           # NOT the -25/-30 on the drawing: those are page
                           # angles of the axonometric and land under the floor
set :xen_blauert, 0.75     # how strongly the slope is voiced
                           # 1.0 = the same band tilt M=0 states its 'above'
                           # with. 0.75 because the pair is NOT symmetric on
                           # this material: the inhale ends at lpf 8372, right
                           # on the +9 dB band, so it gains (+2.4 dB peak at
                           # 1.0), while the exhale ends at lpf 5274 - the
                           # +9 dB sits ABOVE its knee and only the -6 dB at
                           # 3136 Hz lands, where the shatter actually lives.
                           # At 1.0 that costs the exhale -3.5 dB RMS, which
                           # works against a phase whose job is to open up.
                           # 0.75 holds it to -2.7 dB and still swings the
                           # band ratio 4-6 dB, well inside Blauert's range.
                           # Raise to 1.0 if the exhale can afford it - that
                           # restores tilt 1.0 == M=0's chord exactly
set :xen_pan_mode, :discrete # :continuous | :discrete
                           # how a grain is placed. :continuous splits it
                           # across the two channels either side of its
                           # position (a phantom image gliding between
                           # speakers); :discrete sends it whole to ONE,
                           # picked with that channel's power share.
                           # The in-situ capture argues for trying :discrete
                           # in the hall: reflections at 0.62/1.60/4.96 ms
                           # (-14..-16 dB) broaden a phantom, 2-3 m/s of air
                           # phase-modulates 8 kHz, and a phantom collapses
                           # off-axis while a real source does not - which
                           # matters when the audience walks around.
                           # Energy per channel is IDENTICAL either way, so
                           # an A/B is about placement, not level. Discrete
                           # also halves the voice count (0.58x measured)
set :xen_traj_mode, :scatter # :scatter | :sweep
                           # WHERE a grain sits inside the moving span. The
                           # span itself was always deterministic - it slides
                           # from span0 to span1 across the phase on rails -
                           # and :scatter randomises only the position within
                           # it. :sweep replaces that with a parametric curve:
                           # the Metastaseis / Philips Pavilion reading of the
                           # same drawing, a ruled surface traced by glissandi
                           # instead of a cloud filling a volume. Both are
                           # Xenakis (the clouds are the Pithoprakta lineage),
                           # so this is a choice of idiom, not a correction.
                           # Orthogonal to xen_pan_mode - all four combinations
                           # are legal and sound like four different pieces
set :xen_traj_cycles, 3.0  # sweeps across one phase for the first cloud; the
                           # second runs at twice this, so the two families of
                           # lines cross instead of moving in lockstep - the
                           # crossings ARE the surface. Phase-relative, so it
                           # keeps its shape if the breath timing changes
set :xen_traj_width, 0.12  # thickness of the swept line, as a fraction of the
                           # span's half-width. 0.0 = a single travelling
                           # POINT (one speaker at a time under :discrete -
                           # a line, not a cloud). Metastaseis is 46 separate
                           # glissandi, not one, so the default keeps a narrow
                           # scatter around the swept centre and reads as a
                           # thick line. 1.0 melts back into :scatter
set :xen_void, 0.0         # granular silence between the exhale's last grain and
                           # the inhale's first, split either side of the cycle
                           # boundary. 0 = the phases touch. 2.0 = how it was.
                           # Needs Stop + Run. README 8h.
set :xen_vacuum, 0.8       # the travelling hole, 5-6 -> 9-10. 0 = off. README 8i.
set :xen_enhance, 0.4      # dbx 118: -1.0 compress .. 0.0 bypass .. +1.0 expand
                           # on beds + clouds; all of M=0 stays at unity
set :xen_enhance_threshold, 0.2 # where the 118 decides a signal is "quiet"
set :xen_out_headroom, 0.75 # the ONLY trim that catches the summed bus - post-tanh
                           # on every chain, so linear, and equal across all of
                           # them so no balance changes. Takes ch 5-6 at M=0 from
                           # a measured 1.314 to 0.986. README 8f.
set :xen_master_amp, 1.0   # overall trim - the discrete outputs do NOT go through the limiter
set :xen_bleep, false      # studio reference: a beep at the cycle boundaries (OFF in the hall)
set :xen_seed, 0           # which rendition of the piece; changing it needs Stop + Run
                           # for an installation that never repeats
                           # identically: set :xen_seed, Time.now.to_i

# ---- load + hot-reload the library ----
piece = "/home/mx/src/hala-mx/xenakis.rb"

# xenakis.rb can't self-locate: run_file doesn't execute it as a real Ruby
# file, so __FILE__ resolves to nothing inside it, and NOTHING but Time State
# crosses the run_file boundary - not even globals. So the workspace, which
# already knows where `piece` lives, hands the project directory over via
# Time State; xenakis.rb reads it back instead of hardcoding its own copy.
set :xen_project_dir, File.dirname(piece)

# last_mtime is local, NOT in Time State: on every Run it's created fresh as
# nil, so the library always reloads. (Time State survives Stop, so keeping
# an mtime there would have blocked the reload after Stop + Run.)
last_mtime = nil

# run_tag: local as well, so it's fresh on every Run and stable for the whole
# life of that Run. The piece suffixes its live_loop names with it.
#
# Sonic Pi's named-thread registry (@named_subthreads, runtime.rb) is global to
# the process, and `live_loop :foo` is just `in_thread name: :live_loop_foo`. If
# the name is already registered the new thread is KILLED before its block runs
# - the only trace is "Thread :live_loop_foo exists: skipping creation" in the
# log pane. A name is released only once EVERY subthread of the job that owns it
# has died, and that wait has no timeout. This piece leaves thousands of grain
# threads behind, so a few seconds after Stop the old names are still held: the
# next Run would evaluate the whole library (samples and all) and then quietly
# fail to start a single loop. Silence, with no error, until Sonic Pi is killed.
#
# A per-Run suffix means a new Run's loops can never collide with the previous
# Run's corpse. It stays constant across hot reloads, so those still hot-swap
# the loop body exactly as before.
#
# THIS LOOP NEEDS IT TOO, and it is the worse case of the two: if :reloader is
# the name that is still held, the new Run never even reaches `run_file`, so
# the library is never evaluated and NOTHING happens - the workspace's
# top-level code runs and that is all.
run_tag = (Time.now.to_f * 1000).to_i
set :xen_run_tag, run_tag

live_loop "reloader_#{run_tag}".to_sym do
  # Purely administrative loop: triggers no sound, so timing precision means
  # nothing here. This was 60 so a TimingError could not kill the reloader
  # while the library loaded - but sched_ahead is also how long each `set`
  # parks a raw Thread.new in the GUI-message path (runtime.rb:618/1919).
  # Those are not job subthreads, so Stop leaves them running; at 60 they
  # accumulated until the message queue backed up and a later Run could no
  # longer start its live_loops. run_file returns as soon as it has spawned
  # the piece's own Run, so this loop is never actually busy for seconds.
  use_sched_ahead_time 2.0
  m = File.mtime(piece).to_f
  if m != last_mtime
    fresh_run = last_mtime.nil?
    last_mtime = m
    # A load_sample whose /b_allocRead misses scsynth's hard-coded 5s deadline
    # dies in a detached thread: the half-allocated buffer stays in the
    # studio's @samples cache forever, and everything that later asks it for
    # num_frames blocks for good (LazyBuffer waits on a Promise with NO
    # timeout). The cache is only cleared on boot, so after a Stop + Run the
    # piece would stay silent until Sonic Pi was killed. Starting each Run from
    # an empty cache throws any such corpse away. Only on a fresh Run, never on
    # a hot reload - there it would free buffers that are currently sounding.
    sample_free_all if fresh_run
    run_file piece
  end
  sleep 0.5
end
