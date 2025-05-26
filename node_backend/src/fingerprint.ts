import { Transform } from "stream";
import dsp from "dsp.js";

const SAMPLING_RATE = 22050;
const BPS = 2;
const MNLM = 5;
const MPPP = 3;
const NFFT = 512;
const STEP = NFFT / 2;
const DT = 1 / (SAMPLING_RATE / STEP);

const FFT = new dsp.FFT(NFFT, SAMPLING_RATE);

const HWIN = new Array(NFFT);
for (var i = 0; i < NFFT; i++) {
  HWIN[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (NFFT - 1)));
}

const MASK_DECAY_LOG = Math.log(0.995);
const IF_MIN = 0;
const IF_MAX = NFFT / 2;
const WINDOW_DF = 60;
const WINDOW_DT = 96;
const PRUNING_DT = 24;
const MASK_DF = 3;

const EWW = new Array(NFFT / 2);
for (let i = 0; i < NFFT / 2; i++) {
  EWW[i] = new Array(NFFT / 2);
  for (let j = 0; j < NFFT / 2; j++) {
    EWW[i][j] = -0.5 * Math.pow((j - i) / MASK_DF / Math.sqrt(i + 3), 2);
  }
}

interface Mark {
  t: number;
  i: number[];
  v: number[];
}

interface Options {
  readableObjectMode: boolean;
  highWaterMark: number;
  preprocess?: boolean;
  adaptiveThreshold?: boolean;
}

export class Codegen extends Transform {
  private originalSignal: Float32Array | null = null;
  private processedSignal: Float32Array | null = null;
  private buffer: Buffer;
  private bufferDelta: number;
  private stepIndex: number;
  private marks: Mark[];
  private threshold: any[];
  private adaptiveThreshold: boolean;
  private noiseFloor: number;
  private preprocess: boolean;

  constructor(options: Partial<Options> = {}) {
    super({
      readableObjectMode: true,
      highWaterMark: 16,
      ...options,
    });

    this.buffer = Buffer.alloc(0);
    this.bufferDelta = 0;
    this.stepIndex = 0;
    this.marks = [];
    this.threshold = [];
    this.adaptiveThreshold = options.adaptiveThreshold ?? false;
    this.preprocess = options.preprocess ?? false;
    this.noiseFloor = 0;
  }

  _write(chunk: Buffer, _: any, next: Function) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    while (this.buffer.length >= NFFT * BPS) {
      const tcodes: number[] = [];
      const hcodes: number[] = [];

      let signal = new Float32Array(NFFT);
      for (let i = 0; i < NFFT; i++) {
        signal[i] = this.buffer.readInt16LE(i * BPS) / 32768.0;
      }

      if (this.preprocess) {
        signal = this.preprocessAudio(signal);
      }

      // Apply Hanning window after preprocessing
      for (let i = 0; i < NFFT; i++) {
        signal[i] *= HWIN[i];
      }

      FFT.forward(signal);
      const spectrum = new Array(NFFT / 2);
      for (let i = 0; i < NFFT / 2; i++) {
        spectrum[i] = Math.log(
          1e-6 +
            Math.sqrt(FFT.real[i] * FFT.real[i] + FFT.imag[i] * FFT.imag[i])
        );
      }

      if (this.marks.length === 0) {
        this.threshold = spectrum.map((x) => x);
      }

      const mark: Mark = {
        t: this.stepIndex / STEP,
        i: new Array(MNLM).fill(Number.NEGATIVE_INFINITY),
        v: new Array(MNLM).fill(Number.NEGATIVE_INFINITY),
      };

      for (let i = IF_MIN; i < IF_MAX; i++) {
        if (spectrum[i] > this.threshold[i]) {
          for (let j = 0; j < MNLM; j++) {
            if (spectrum[i] > mark.v[j]) {
              mark.v.splice(j, 0, spectrum[i]);
              mark.i.splice(j, 0, i);
              mark.v.pop();
              mark.i.pop();
              break;
            }
          }
        }
      }

      this.marks.push(mark);

      const t0 = this.marks.length - 1 - PRUNING_DT;
      if (t0 >= 0) {
        for (let i = 0; i <= t0; i++) {
          for (let j = 0; j < this.marks[i].i.length; j++) {
            if (this.marks[i].i[j] === Number.NEGATIVE_INFINITY) continue;
            for (let k = i + 1; k < this.marks.length; k++) {
              for (let l = 0; l < this.marks[k].i.length; l++) {
                if (this.marks[k].i[l] === Number.NEGATIVE_INFINITY) continue;
                if (
                  Math.abs(this.marks[k].i[l] - this.marks[i].i[j]) <=
                    WINDOW_DF &&
                  this.marks[k].v[l] > this.marks[i].v[j]
                ) {
                  this.marks[i].v[j] = Number.NEGATIVE_INFINITY;
                  this.marks[i].i[j] = Number.NEGATIVE_INFINITY;
                  break;
                }
              }
              if (this.marks[i].i[j] === Number.NEGATIVE_INFINITY) break;
            }
          }
        }
      }

      if (t0 >= 0) {
        let m = this.marks[t0];
        for (let i = 0; i < m.i.length; i++) {
          if (m.i[i] === Number.NEGATIVE_INFINITY) continue;
          let nFingers = 0;
          for (let j = t0; j >= Math.max(0, t0 - WINDOW_DT); j--) {
            let m2 = this.marks[j];
            for (let k = 0; k < m2.i.length; k++) {
              if (
                m2.i[k] !== m.i[i] &&
                Math.abs(m2.i[k] - m.i[i]) < WINDOW_DF
              ) {
                tcodes.push(m.t);
                hcodes.push(
                  m2.i[k] + (NFFT / 2) * (m.i[i] + (NFFT / 2) * (t0 - j))
                );
                nFingers++;
                if (nFingers >= MPPP) break;
              }
            }
            if (nFingers >= MPPP) break;
          }
        }
        this.marks.splice(0, t0 + 1 - WINDOW_DT);
      }

      for (let j = 0; j < this.threshold.length; j++) {
        this.threshold[j] += MASK_DECAY_LOG;
      }

      if (tcodes.length > 0) {
        this.push({ tcodes, hcodes });
      }

      this.buffer = this.buffer.slice(STEP * BPS);
      this.stepIndex += STEP;
    }

    next();
  }

  private preprocessAudio(signal: Float32Array): Float32Array {
    if (this.adaptiveThreshold) {
      this.noiseFloor = this.calculateNoiseFloor(signal);
    }
    const maxAmp = Math.max(...Array.from(signal).map(Math.abs));
    if (maxAmp === 0) return signal;
    const normalized = signal.map((s) => s / maxAmp);

    const windowSize = 32;
    const processed = new Float32Array(normalized.length);

    for (let i = 0; i < normalized.length; i++) {
      const start = Math.max(0, i - windowSize);
      const end = Math.min(normalized.length, i + windowSize);
      const window = normalized.slice(start, end);
      const localNoiseFloor = this.calculateLocalNoise(window);
      const noiseGate = Math.max(this.noiseFloor || 0.1, localNoiseFloor * 2.0); // Stronger noise gate
      const signalStrength = Math.abs(normalized[i]);

      if (signalStrength < noiseGate) {
        processed[i] = 0;
      } else {
        const reduction = Math.min((signalStrength - noiseGate) / noiseGate, 1);
        processed[i] = normalized[i] * reduction;
      }
    }

    return this.applyMedianFilter(processed, 3);
  }

  private calculateLocalNoise(window: Float32Array): number {
    const amplitudes = Array.from(window).map(Math.abs);
    const sorted = amplitudes.sort((a, b) => a - b);
    const quarterIdx = Math.floor(sorted.length / 4);
    return sorted[quarterIdx] * 1.5; // Slightly higher threshold for better noise discrimination
  }

  private applyMedianFilter(
    signal: Float32Array,
    windowSize: number
  ): Float32Array {
    const result = new Float32Array(signal.length);
    const halfWindow = Math.floor(windowSize / 2);

    for (let i = 0; i < signal.length; i++) {
      const start = Math.max(0, i - halfWindow);
      const end = Math.min(signal.length, i + halfWindow + 1);
      const window = Array.from(signal.slice(start, end));
      window.sort((a, b) => a - b);
      result[i] = window[Math.floor(window.length / 2)];
    }

    return result;
  }

  private calculateNoiseFloor(signal: Float32Array): number {
    // Sort amplitudes and take the median of the lower quarter
    const amplitudes = Array.from(signal)
      .map(Math.abs)
      .sort((a, b) => a - b);
    const quarterIdx = Math.floor(amplitudes.length / 4);
    const lowerQuarter = amplitudes.slice(0, quarterIdx);
    return (lowerQuarter.reduce((a, b) => a + b, 0) / lowerQuarter.length) * 2;
  }
}
