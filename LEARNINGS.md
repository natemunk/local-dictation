# Local Dictation engineering learnings

These notes capture narrow implementation observations from the
Overwhisper-derived audio path and current Local Dictation work. They are not
latency, accuracy, compatibility, or release benchmarks.

## Keep microphone capture independent of the output device

The seed implementation used `AVAudioEngine` only for microphone input, but
its render loop was still clocked through the default output device. A setup
with a USB microphone and Bluetooth output could therefore lose capture when
the output route changed.

Local Dictation's current `AudioRecorder.makeInputUnit` uses
`kAudioUnitSubType_HALOutput` in input-only mode: input bus 1 is enabled,
output bus 0 is disabled, and the unit is bound to the selected input device.
No speaker device needs to enter the capture graph.

## “System default” has API-specific device semantics

An earlier `AVAudioEngine` fix stopped reapplying the system-default device:
the engine had already selected it, and forcing the same ID could break format
negotiation with `kAudioUnitErr_FormatNotSupported` (-10868).

That rule must not be copied blindly to AUHAL. A new HAL output unit can default
to the default **output** device, so the input-only implementation resolves the
current default input device and always sets
`kAudioOutputUnitProperty_CurrentDevice` explicitly. The lesson is to follow
the owning API's semantics rather than treating “default device” as universal.

## Multi-channel input needs an explicit layout and a deliberate channel map

`AVAudioFormat` convenience initialization cannot infer a layout for every
device above stereo. The current capture path constructs the stream description
and attaches a discrete channel layout for multi-channel hardware.

The converter currently maps channel 0 to mono because that was the microphone
channel on the exercised Scarlett setup. That observation is hardware-specific;
new interfaces need channel-level validation rather than an assumption that
their first channel is always the desired input.

## Hardware startup observations are not product guarantees

One exercised USB interface delivered its first input buffer roughly 570 ms
after start. That explains why very short recordings can contain little or no
audio, but it is a single-device observation, not a supported latency target.
Keep first-buffer timing visible in diagnostics and validate representative
hardware before changing tap/hold behavior or advertising responsiveness.

## Never append revisable transcript text to finalized text

Streaming partials can be replaced by a later update. `TranscriptBuffer`
therefore stores `finalized` and `volatile` separately, replaces both ranges
for each update, and clears the volatile range on final commit. UI or cleanup
code that concatenates successive volatile values will duplicate words.

## Keep evidence layers separate

Source inspection, source-audit scripts, unit tests, synthetic benchmark
fixtures, recorded-corpus results, ad-hoc app installation, and real-use
cutover are different gates. Report each one explicitly; none substitutes for
the next.
