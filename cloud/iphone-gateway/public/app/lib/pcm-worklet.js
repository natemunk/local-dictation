// AudioWorklet that downmixes the microphone and emits little-endian 16 kHz
// signed PCM. Frames are transferred to the page and are never persisted.

const TARGET_SAMPLE_RATE = 16_000;
const OUTPUT_SAMPLES = 640;

class LocalDictationPCMProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.nextSourceFrame = 0;
    this.totalSourceFrames = 0;
    this.previousSample = 0;
    this.output = new Int16Array(OUTPUT_SAMPLES);
    this.outputLength = 0;
    this.port.onmessage = (event) => {
      if (event.data?.type !== "flush") return;
      this.publish(true);
      this.port.postMessage({ type: "flushed" });
    };
  }

  downmix(channels, frame) {
    let sum = 0;
    for (const channel of channels) sum += channel[frame] ?? 0;
    return channels.length === 0 ? 0 : sum / channels.length;
  }

  append(value) {
    const clamped = Math.max(-1, Math.min(1, value));
    this.output[this.outputLength] = clamped < 0
      ? Math.round(clamped * 32_768)
      : Math.round(clamped * 32_767);
    this.outputLength += 1;
    if (this.outputLength === this.output.length) this.publish(false);
  }

  publish(partial) {
    if (this.outputLength === 0) return;
    const frame = partial ? this.output.slice(0, this.outputLength) : this.output;
    this.port.postMessage({ type: "pcm", buffer: frame.buffer }, [frame.buffer]);
    this.output = new Int16Array(OUTPUT_SAMPLES);
    this.outputLength = 0;
  }

  process(inputs) {
    const channels = inputs[0] ?? [];
    const frames = channels[0]?.length ?? 0;
    if (frames === 0) return true;

    const step = sampleRate / TARGET_SAMPLE_RATE;
    for (let frame = 0; frame < frames; frame += 1) {
      const absoluteFrame = this.totalSourceFrames + frame;
      const current = this.downmix(channels, frame);
      while (this.nextSourceFrame <= absoluteFrame) {
        const fraction = absoluteFrame === 0
          ? 1
          : this.nextSourceFrame - (absoluteFrame - 1);
        this.append(this.previousSample + ((current - this.previousSample) * fraction));
        this.nextSourceFrame += step;
      }
      this.previousSample = current;
    }
    this.totalSourceFrames += frames;
    return true;
  }
}

registerProcessor("local-dictation-pcm", LocalDictationPCMProcessor);
