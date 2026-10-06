# ============================================
# XENAKIS / NICAPETRE - CONFIGURATION DESK
# The only place anything gets configured.
# xenakis.rb is a library and doesn't get touched.
# ============================================
#
# TWO LAYERS over eight monitors in two rings, in a room whose vertical axis is
# REAL - 4.2 m of ground floor and 3.6 m more above, under a stained-glass
# skylight (nicapetre.tsv). They move against each other:
#
#   the rain  a slow underwater waterfall, travelling a LEMNISCATE: round the
#             room while falling and rising twice. The file always plays
#             forward; what goes back up is the position, not the tape.
#   the rise  Hala MX's exhale shatter, its second half only, climbing bottom
#             to top. The water's counter-motion.
#
# THE REASONING FOR EVERY NUMBER HERE IS IN README 12, and it stays there: this
# file has a hard 16320-byte ceiling past which Run silently does nothing.

set :xen_venue, :nicapetre # :mx | :tnb | :nicapetre - MUST be stated. README 11f.
set :nica_engine, :layers  # :layers   = the piece: rain + rise (README 12)
                           # :tnb_zones = borrow TNB's mass + cube (scaffolding)
                           # :silent    = park, and say so once a block
set :xen_rig_outputs, 8    # TWO RINGS. Channel order reads DOWNWARD, like the
                           # water: the first half is the gallery rail, the
                           # second the ground. nicapetre.tsv is the authority.
                           #   8 = the venue   upper 1-4, ground 5-8
                           #   4 = the studio  upper 1-2, ground 3-4
                           #   2 = a pair      upper 1,   ground 2
                           # THE FOLD KEEPS THE VERTICAL AND SPENDS THE
                           # AZIMUTH - unlike MX, which compresses its whole
                           # drawing, and TNB, which sums its two quads. The
                           # piece IS a fall, so a fold that flattens the rings
                           # into one plane would leave you judging a waterfall
                           # that cannot descend. README 12b.
set :xen_density, 1.0
set :xen_master_amp, 1.0
set :xen_out_headroom, 0.75
set :xen_enhance, 0.4
set :xen_enhance_threshold, 0.2
set :xen_sched_ahead, 3.0
set :xen_bleep, false      # INERT here - this venue has no cycle to mark.
set :xen_seed, 0

set :nica_focus, :both     # :both | :rain | :rise - SOLO, read live.
                           # :rain = the Oktosi recording alone, travelling the
                           #         lemniscate - no grains at all
                           # :rise = the shatter climbing, no water
                           # The muted layer holds its clock, so soloing changes
                           # what you hear and never the cadence.

# ---- LAYER 1 - the rain ----------------------------------------------------
# A recording of a slow underwater waterfall, travelling a LEMNISCATE: round
# the room while falling and rising twice. The file always plays FORWARD; what
# goes back up is the position, not the tape.
set :nica_rain_file, "Braila_Oktosi.wav"   # in output_xenakis_installation/nicapetre/
set :nica_rain_gen, 62.0   # seconds per pass. The recording is 82.9 s and fades
                           # to -70 dB over its last ~18, so the tail is cut
                           # (below) and 62 s is what is left with body in it.
set :nica_rain_tail, 0.75  # fraction of the file used. 0.75 = 62 s of 82.9.
                           # Raise it and you re-admit the fade, which is a hole
                           # in a layer that is supposed to be continuous water.
set :nica_rain_fade, 4.0   # seconds of overlap between passes. sqrt taper, so
                           # two passes sum to constant POWER.
set :nica_lap, 97.0        # SECONDS PER FIGURE-OF-EIGHT, on its own clock -
                           # deliberately NOT a ratio of (gen - fade) = 58.
                           # It used to be a count of laps per pass, which
                           # locked the figure to the generation and put the
                           # SAME point of it in the fade window every single
                           # pass, forever. On four outputs that starved ch3.
set :nica_precess, 0.02    # how far the figure drifts round the ring, as a
                           # detuning of its exact 2:1 height-to-azimuth ratio.
                           #
                           # AT 0 THE FIGURE IS LOCKED TO THE SPEAKERS and four
                           # of the eight monitors never host an extreme at all
                           # - measured, ch1/3/6/8 get 6% of the energy against
                           # 19% for the others, and no level trim can fix it
                           # because it is geometry. A lemniscate has four
                           # extremes and the venue has eight monitors.
                           # At 0.02 an extreme moves one monitor every ~20 min,
                           # so within any one visit it is still the closed
                           # eight that was asked for, and across a day every
                           # monitor takes its turn.
                           # Set 0 for the exactly-locked figure.
set :nica_dipole, 0.12     # how far the recording's own L/R straddles the path
                           # VERTICALLY - left above, right below, in units of
                           # the full shaft. Its internal up/down becomes a
                           # small real height difference instead of being
                           # flattened to a point. 0 = mono-in-place.
set :nica_step, 0.2        # control interval. Each step moves 16 voices, so
                           # this is 80 messages/s; amp_slide covers the gaps.
set :nica_rain_amp, 1.0

# ---- LAYER 2 - the rise ----------------------------------------------------
# Hala MX's INHALE, climbing bottom to top against the water. In MX that phase
# descends - it enters pitched up at 1.4 and darkens to 0.95 while its filter
# closes from 8372 Hz to 1319. Flown upward it contradicts itself: the material
# gets heavier the higher it goes.
set :nica_rise_from, 0.5   # which part of the inhale, as fractions of its
set :nica_rise_to, 1.0     # phase. 0..1 is all of it; 0.5..1 the second half.
                           # At 0.5 the climb runs pitch 1.175 -> 0.95 and
                           # filter 3322 -> 1319 Hz: the inhale's ARRIVAL, with
                           # its bright 8 kHz entry left out. That is the half
                           # a room of this much stone can actually carry.
                           # The ramps are interpolated from MX's own constants,
                           # so retuning the breath carries through to here.
set :nica_rise_block, 47.0 # SECONDS PER CLIMB, which is also how long a grain
                           # takes to cross the shaft - a grain's height IS its
                           # position in the gesture, so this knob is the
                           # vertical SPEED. nicapetre.tsv puts 3.8 m between
                           # the rings, so 47 s is 8.1 cm/s against the 16.5
                           # cm/s that 23 s gave. It is also how often the
                           # climb restarts; there is only ever one in the air.
                           # Deliberately NOT a ratio of nica_rain_gen (62) or
                           # nica_lap (97) - both prime against it, so the
                           # three clocks do not line up inside 45 minutes.
                           # Share a clock and the room acquires a period you
                           # can hear.
set :nica_rise_density, 18.0 # grains/second. MX's own inhale_high cloud runs
                           # 24/s over twelve channels; this is 18 over eight,
                           # so per channel it is already denser than the
                           # source. It started at 9 as a guess against ~500 m3
                           # of marble and glass with almost no absorption -
                           # raised by ear.
                           # Per CLIMB that is 47 s x 18 = ~850 grains over the
                           # 3.8 m shaft, about 220 per metre. Note the climb's
                           # length multiplies this: slowing nica_rise_block
                           # already doubled the grains per metre without
                           # touching this number.
                           # 24 is the ceiling that still means "the inhale at
                           # its own density"; past that it is denser than
                           # anything Hala MX plays.
set :nica_rise_shape, 3    # Erlang order, as the exhale's own clouds use
set :nica_rise_spin, 0.25  # revolutions the climb turns through on its way up.
                           # 0 = straight up one side, 1 = a full helix.
set :nica_rise_jitter, 1.2 # azimuth scatter per grain, in quarter-turns, so the
                           # climb is a column rather than a line
set :nica_rise_amp, 1.0

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
