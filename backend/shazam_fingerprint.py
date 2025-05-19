import numpy as np
from scipy import signal
from typing import List, Tuple, Dict

# Constants matching SeekTune's implementation
DSP_RATIO = 4
FREQ_BIN_SIZE = 1024
MAX_FREQ = 5000.0  # 5kHz
HOP_SIZE = FREQ_BIN_SIZE // 32
TARGET_ZONE_SIZE = 5  # Number of points to look ahead for fingerprinting

class Peak:
    def __init__(self, time: float, freq: complex):
        self.time = time
        self.freq = freq

def low_pass_filter(cutoff_frequency: float, sample_rate: float, input_signal: np.ndarray) -> np.ndarray:
    """First-order low-pass filter that attenuates high frequencies."""
    rc = 1.0 / (2 * np.pi * cutoff_frequency)
    dt = 1.0 / sample_rate
    alpha = dt / (rc + dt)
    
    filtered_signal = np.zeros_like(input_signal)
    prev_output = 0.0
    
    for i, x in enumerate(input_signal):
        if i == 0:
            filtered_signal[i] = x * alpha
        else:
            filtered_signal[i] = alpha * x + (1 - alpha) * prev_output
        prev_output = filtered_signal[i]
    
    return filtered_signal

def downsample(input_signal: np.ndarray, original_sample_rate: int, target_sample_rate: int) -> np.ndarray:
    """Downsample the input audio."""
    if target_sample_rate <= 0 or original_sample_rate <= 0:
        raise ValueError("Sample rates must be positive")
    if target_sample_rate > original_sample_rate:
        raise ValueError("Target sample rate must be less than or equal to original sample rate")
    
    ratio = original_sample_rate // target_sample_rate
    if ratio <= 0:
        raise ValueError("Invalid ratio calculated from sample rates")
    
    # Use numpy's array operations for efficient downsampling
    resampled = np.array([np.mean(input_signal[i:i+ratio]) 
                         for i in range(0, len(input_signal), ratio)])
    return resampled

def create_spectrogram(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    """Create a spectrogram from audio samples using the Go implementation's approach."""
    # Apply low-pass filter
    filtered_samples = low_pass_filter(MAX_FREQ, sample_rate, samples)
    
    # Downsample
    downsampled_samples = downsample(filtered_samples, sample_rate, sample_rate // DSP_RATIO)
    
    # Calculate number of windows
    num_windows = len(downsampled_samples) // (FREQ_BIN_SIZE - HOP_SIZE)
    
    # Create Hamming window
    window = np.hamming(FREQ_BIN_SIZE)
    
    # Perform STFT
    spectrogram = []
    for i in range(num_windows):
        start = i * HOP_SIZE
        end = start + FREQ_BIN_SIZE
        if end > len(downsampled_samples):
            end = len(downsampled_samples)
        
        # Get the window of samples
        bin_samples = np.zeros(FREQ_BIN_SIZE)
        bin_samples[:end-start] = downsampled_samples[start:end]
        
        # Apply window
        windowed = bin_samples * window
        
        # Perform FFT
        spectrum = np.fft.fft(windowed)
        spectrogram.append(spectrum)
    
    return np.array(spectrogram)

def extract_peaks(spectrogram: np.ndarray, audio_duration: float) -> List[Peak]:
    """Extract peaks from the spectrogram using the Go implementation's approach."""
    if len(spectrogram) < 1:
        return []
    
    # Define frequency bands as in Go implementation
    bands = [(0, 10), (10, 20), (20, 40), (40, 80), (80, 160), (160, 512)]
    peaks = []
    bin_duration = audio_duration / len(spectrogram)
    
    for bin_idx, bin_data in enumerate(spectrogram):
        bin_band_maxies = []
        
        # Find maximum magnitude in each frequency band
        for band_min, band_max in bands:
            max_mag = 0.0
            max_freq = 0j
            max_freq_idx = band_min
            
            for idx, freq in enumerate(bin_data[band_min:band_max], start=band_min):
                magnitude = abs(freq)
                if magnitude > max_mag:
                    max_mag = magnitude
                    max_freq = freq
                    max_freq_idx = idx
            
            bin_band_maxies.append((max_mag, max_freq, max_freq_idx))
        
        # Calculate average magnitude
        max_mags = [x[0] for x in bin_band_maxies]
        avg = np.mean(max_mags)
        
        # Add peaks that exceed average magnitude
        for max_mag, max_freq, freq_idx in bin_band_maxies:
            if max_mag > avg:
                peak_time_in_bin = freq_idx * bin_duration / len(bin_data)
                peak_time = bin_idx * bin_duration + peak_time_in_bin
                peaks.append(Peak(peak_time, max_freq))
    
    return peaks

def generate_fingerprints(peaks: List[Peak], song_id: int) -> Dict[int, Tuple[int, int]]:
    """Generate fingerprints from peaks using the Go implementation's approach."""
    fingerprints = {}
    
    for i, anchor in enumerate(peaks):
        for j in range(i + 1, min(len(peaks), i + TARGET_ZONE_SIZE + 1)):
            target = peaks[j]
            
            # Create address (hash) as in Go implementation
            anchor_freq = int(abs(anchor.freq))
            target_freq = int(abs(target.freq))
            delta_ms = int((target.time - anchor.time) * 1000)
            
            # Combine components into 32-bit address
            address = (anchor_freq << 23) | (target_freq << 14) | delta_ms
            anchor_time_ms = int(anchor.time * 1000)
            
            fingerprints[address] = (anchor_time_ms, song_id)
    
    return fingerprints

def create_fingerprint_hash(anchor, target):
    """Create a unique hash from a pair of peaks."""
    # Convert complex frequency to real number (using magnitude)
    anchor_freq = int(np.abs(anchor.freq))
    target_freq = int(np.abs(target.freq))
    delta_time = int((target.time - anchor.time) * 1000)  # Convert to milliseconds
    
    # Combine into 32-bit hash (matching SeekTune's implementation)
    fingerprint_hash = (anchor_freq << 23) | (target_freq << 14) | (delta_time & 0x3FFF)
    return fingerprint_hash

def generate_fingerprints(peaks, song_id):
    """Generate fingerprints from peaks."""
    fingerprints = {}
    
    for i, anchor in enumerate(peaks):
        # Look ahead in target zone
        for j in range(i + 1, min(i + TARGET_ZONE_SIZE + 1, len(peaks))):
            target = peaks[j]
            
            hash_value = create_fingerprint_hash(anchor, target)
            anchor_time = int(anchor.time * 1000)  # Convert to milliseconds
            
            fingerprints[hash_value] = (anchor_time, song_id)
    
    return fingerprints
