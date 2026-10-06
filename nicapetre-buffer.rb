# ============================================
# XENAKIS / NICAPETRE - CONFIGURATION DESK
# The only place anything gets configured.
# xenakis.rb is a library and doesn't get touched.
# ============================================
#
# THE PIECE FOR THIS VENUE DOES NOT EXIST YET. The rig does: 8 outputs, two
# quads, on an interface established by ear at load-in. Everything below is
# either rig configuration, which is real, or SCAFFOLDING, which is labelled.
#
# Until nica_engine says otherwise this venue borrows TNB's two zones so the
# room can be patched, levelled and walked before a note of its own exists.
# That is a stand-in, not a decision - see README 12.

set :xen_venue, :nicapetre  # :mx | :tnb | :nicapetre - MUST be stated. README 11f.
set :nica_engine, :tnb_zones # :tnb_zones = borrow TNB's mass + cube (scaffolding)
                           # :silent     = park, and say so once a block
                           # A third value appears here when the piece does.
set :xen_rig_outputs, 8    # 8 = two quads. 4 = UMC: the zones FOLD and sum.
set :xen_density, 1.0
set :xen_master_amp, 1.0
set :xen_out_headroom, 0.75
set :xen_enhance, 0.4
set :xen_enhance_threshold, 0.2
set :xen_sched_ahead, 3.0
set :xen_bleep, false      # INERT here - this venue has no cycle to mark.
set :xen_seed, 0

set :tnb_focus, :all       # :all | :z1 | :z4 - SOLO, read live. README 11d.
                           # Applies to the borrowed zones while scaffolding.

# ---- the borrowed zones ----------------------------------------------------
# Identical keys to tnb-buffer.rb, read by the same engines. They are repeated
# rather than shared because the two venues must be tunable apart: the rooms
# are different sizes and the quads will not be rigged the same.
set :tnb_z1_block, 11.0
set :tnb_z1_density, 56.0
set :tnb_z1_floor, 0.70
set :tnb_z1_floor_shape, 16
set :tnb_z1_shape, 6
set :tnb_z1_xfade, 1.2
set :tnb_z1_fx_tail, 0.35
set :tnb_z1_amp, 1.0
set :tnb_z1_drift, 0.8
set :tnb_z1_lpf, 95
set :tnb_z1_rate, 0.9

set :tnb_z4_block, 13.0
set :tnb_z4_amp, 1.0
set :tnb_z4_pace, 1.0
set :tnb_z4_word, "Z X Z2 Y Z3 X2 Z Y3"
set :tnb_z4_seq, "held point burst rest line point burst"
set :tnb_z4_height, 0.5
set :tnb_z4_shear, 5
set :tnb_z4_tilt, 4.0
set :tnb_z4_tilt_every, 13
set :tnb_z4_rate_max, 2.0
set :tnb_z4_bright, 0.7

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
