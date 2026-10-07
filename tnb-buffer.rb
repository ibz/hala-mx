# ============================================
# XENAKIS / TNB - CONFIGURATION DESK
# Two zones in the Hol, Corp B. The only place anything gets configured.
# xenakis.rb is a library and doesn't get touched.
# ============================================
#
# A different piece from Hala MX on the same engine. No breath, no M=0, no
# vacuum - two continuous states a visitor walks between.
#
#   Zone I   outputs 1-4   "nor stocastic comprimat"  - the mass
#   Zone IV  outputs 5-8   "camp fragmentat / retea"  - the cube
#
# THE REASONING FOR EVERY NUMBER HERE IS IN README 11, and it stays there:
# this file has a hard 16320-byte ceiling, past which Run silently does
# nothing at all. Keep the comments to one line.

set :xen_venue, :tnb       # :mx | :tnb - MUST be stated. README 11f.
set :xen_rig_outputs, 8    # 8 = TNB (two quads). 4 = UMC: the zones FOLD and sum.
set :xen_density, 1.0      # global grain-density multiplier, both zones
set :xen_master_amp, 1.0   # these outputs bypass the limiter
set :xen_out_headroom, 0.75 # the only trim that catches the summed bus
set :xen_enhance, 0.4      # dbx 118: -1.0 compress .. 0.0 bypass .. +1.0 expand
set :xen_enhance_threshold, 0.2
set :xen_sched_ahead, 3.0  # lookahead; also queue depth. README 4.
set :xen_bleep, false      # INERT here - TNB has no cycle to mark.
set :xen_seed, 0           # which rendition. Stop + Run to change.

set :tnb_focus, :all       # :all | :z1 | :z4 - SOLO, read live. README 11d.
                           # The studio has one quad and both zones fold onto
                           # it, so a solo is the only way to judge either.

# ---- ZONE I - the mass -----------------------------------------------------
# Four per-channel floor clouds under two drifting windows, on a RING of four.
# README 11b.
set :tnb_z1_block, 11.0    # seconds of schedule per block. Not a cycle.
set :tnb_z1_density, 56.0  # grains/s across the quad, ~14/s/channel.
                           # Was 26 (MX's inhale density) and left a channel
                           # silent for up to 898 ms. Now 195 ms.
set :tnb_z1_floor, 0.70    # share of that on the four PER-CHANNEL clouds.
                           # The knob that removed the holes: a shared process
                           # cannot promise any one speaker anything.
set :tnb_z1_floor_shape, 16 # Erlang order of the floor. 1 = Poisson, gaps
                           # unbounded; 16 is nearly even. Floor draws only
                           # cuts >= 110 ms so grains overlap, not adjoin.
set :tnb_z1_mix, 0.6       # how far the density SHIFTS between the two drifting
                           # windows. 0 = fixed at Hala MX's inhale ratio, which
                           # is 3:1 (its two clouds run lambda 24 and 8); 1 =
                           # the full swing, each window taking its turn as the
                           # dense one. The TOTAL never changes, so the mass
                           # does not thin and the per-channel floor is never
                           # robbed to pay for it.
set :tnb_z1_mix_period, 73.0 # seconds per exchange, on its own clock carried
                           # across blocks. Not a ratio of tnb_z1_block (11) or
                           # of the 9.8 s handover.
                           # Only 30% of the density is in the windows, so the
                           # swing moves at most that much - lower tnb_z1_floor
                           # if it needs to be more than a shimmer, and
                           # re-measure the channel gaps afterwards.
set :tnb_z1_shape, 6       # Erlang order of the drifting windows. Lower on
                           # purpose - even variation is not variation.
set :tnb_z1_xfade, 1.2     # seconds blocks OVERLAP. Without it the zone has a
                           # hole on every channel at each boundary - a PULSE on
                           # the block period. sqrt taper = constant power.
set :tnb_z1_fx_tail, 0.35  # seconds the channel chain outlives its last grain.
                           # It used to close at the block end and CUT a 150 ms
                           # grain fired just before it.
set :tnb_z1_amp, 1.0
set :tnb_z1_drift, 0.8     # ring units a window's centre walks per block
set :tnb_z1_lpf, 95        # MIDI, ~2.9 kHz. Pressure, not detail.
set :tnb_z1_rate, 0.9      # mass reads heavier slowed

# ---- ZONE IV - the cube ----------------------------------------------------
# Nomos Alpha: complexes, and the ROTATION GROUP OF THE CUBE acting on them.
# A vertex's (x,y) is which speaker; its z is Blauert tilt, above or below.
# README 11c.
set :tnb_z4_block, 13.0    # seconds of schedule per block. A complex is never
                           # cut at the boundary, so this is a target.
set :tnb_z4_amp, 1.0
set :tnb_z4_pace, 1.0      # scales every complex's duration together
set :tnb_z4_word, "Z X Z2 Y Z3 X2 Z Y3"
                           # rotations, applied cumulatively. X Y Z are 90 deg
                           # about each axis; a digit raises the power.
                           # A WORD OF Z ALONE IS THE OLD SQUARE, TURNING -
                           # X and Y are the whole third dimension.
set :tnb_z4_seq, "held point burst rest line point burst"
                           # point: a vertex. burst: an edge. line: 3
                           # vertices. held: a FACE. rest: silence, which is a
                           # complex and not a gap.
set :tnb_z4_height, 0.5    # how strongly the cube's z is voiced, as a fraction
                           # of the Blauert chord. 0 = off, pair skipped.
                           # Under MX's 0.75: README 10c, this cue costs timbre
                           # before it buys height.
set :tnb_z4_shear, 5       # complex index gains one extra step every N
set :tnb_z4_tilt, 4.0      # semitones of the register sieve. 0 = off.
set :tnb_z4_tilt_every, 13 # ...advancing every N complexes.
                           # shear/tilt_every WERE SEARCHED, not chosen: 2 s
                           # worst verbatim stretch, 34 min to a full return,
                           # a face taking 21 of 24 shapes. Re-measure if you
                           # change one - neighbours loop in 20 s.
set :tnb_z4_rate_max, 2.0  # hardest transposition, as a rate. 2.0 = +12 st.
                           # Three multipliers stack and reached x3.02 (+19 st):
                           # shatter up a twelfth is a shriek. Caps the STATIC
                           # part only, so each complex keeps its contour.
set :tnb_z4_bright, 0.7    # how far the filter follows transposition DOWN.
                           # 1.0 cancels the glissando, 0.0 is the old shriek.
                           # One-sided: never opens the filter for a SLOWED
                           # grain, or held's dark sustain would brighten.
                           # STILL SHRILL? raise this to 0.9, then drop
                           # rate_max to 1.7, then tnb_z4_height. tilt LAST -
                           # it is what stops the score repeating.

# ---- load + hot-reload the library ----
# Same mechanism as sonic-pi-buffer.rb; the long notes on why last_mtime and
# run_tag are locals, and why this loop's sched_ahead is 2.0, live there.
piece = "/home/mx/src/hala-mx/xenakis.rb"
set :xen_project_dir, File.dirname(piece)
last_mtime = nil
run_tag = (Time.now.to_f * 1000).to_i
set :xen_run_tag, run_tag

live_loop "reloader_#{run_tag}".to_sym do
  use_sched_ahead_time 2.0
  m = File.mtime(piece).to_f
  if m != last_mtime
    fresh_run = last_mtime.nil?
    last_mtime = m
    sample_free_all if fresh_run
    run_file piece
  end
  sleep 0.5
end
