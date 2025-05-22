declare module 'dsp.js' {
    export class FFT {
        constructor(bufferSize: number, sampleRate: number);
        forward(buffer: Float32Array): void;
        real: number[];
        imag: number[];
    }
    
    export default {
        FFT
    };
}
