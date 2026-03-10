# Dr.Kynox UI ses teması (Sonic Pi)
use_bpm 96

define :ui_tap do
  use_synth :pluck
  play :e6, release: 0.06, amp: 0.6
end

define :ui_success do
  use_synth :pretty_bell
  play :e5, release: 0.08, amp: 0.45
  sleep 0.08
  play :a5, release: 0.12, amp: 0.5
end

define :ui_error do
  use_synth :fm
  play :c4, release: 0.12, amp: 0.45
  sleep 0.06
  play :a3, release: 0.14, amp: 0.5
end

define :ambient_bed do
  with_fx :reverb, room: 0.85, mix: 0.35 do
    use_synth :hollow
    play chord(:e3, :minor9), sustain: 3, release: 1.2, amp: 0.2
  end
end

# Example preview loop (comment out while exporting one-shots)
live_loop :preview, delay: 0.3 do
  ambient_bed
  sleep 4
end
