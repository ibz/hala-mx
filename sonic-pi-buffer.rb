# ============================================
# XENAKIS / HALA MX - CONFIGURATION DESK
# The only place anything gets configured.
# xenakis.rb is a library and doesn't get touched.
# ============================================

set :xen_rig_outputs, 4    # 12 = Hala MX, 4 = UMC404HD in the studio
set :xen_focus, :inhale    # :inhale :exhale :m0 :m0_ceil :m0_floor :all
set :xen_master_amp, 1.0   # overall trim - the discrete outputs do NOT go through the limiter
set :xen_bleep, true       # studio reference: a beep at the cycle boundaries (OFF in the hall)
set :xen_seed, 0           # which rendition of the piece; changing it needs Stop + Run
                           # for an installation that never repeats
                           # identically: set :xen_seed, Time.now.to_i

# ---- load + hot-reload the library ----
piece = "/home/ibz/src/hala-mx/xenakis.rb"

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

live_loop :reloader do
  # Purely administrative loop: triggers no sound, so timing precision means
  # nothing here. Preloading the library (1536 files, with allocations
  # serialized on a single mutex) keeps the Ruby process busy for a few
  # seconds, and with the default tolerance Sonic Pi kills the reloader with
  # a TimingError right during that load. sched_ahead is thread-local, so
  # here we make it effectively infinite without affecting the piece.
  use_sched_ahead_time 60
  m = File.mtime(piece).to_f
  if m != last_mtime
    last_mtime = m
    run_file piece
  end
  sleep 0.5
end
