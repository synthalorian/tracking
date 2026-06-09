module Tracking

using PortAudio
using FFTW
using GLMakie

# Phase 1: Audio capture (PortAudio + RingBuffer)
include("ringbuffer.jl")
include("audio.jl")

# Phase 2: FFT engine (FFTW) with windowing
include("fft.jl")

# Phase 3: Real-time spectrum display (GLMakie)
include("spectrum.jl")

# Phase 4: Waterfall / spectrogram view
include("waterfall.jl")

# Phase 5: Peak detection algorithm
include("peak.jl")

# Phase 1 exports
export RingBuffer, push!, popfirst!, isempty, isfull, length, capacity, available, empty!, peek, overwrite!
export AudioCapture, start!, stop!, isrunning, sample_rate, channels, buffer_size, latency_samples, latency_ms

# Phase 2 exports
export WindowFunction, RectangularWindow, HannWindow, HammingWindow, BlackmanWindow
export FFTEngine, process!, magnitude_spectrum, power_spectrum, phase_spectrum
export frequency_bins, bin_to_hz, hz_to_bin, frequency_resolution
export find_peak_bin, find_peaks, magnitude_at_bin, magnitude_at_hz
export fft_size, num_bins, nyquist, window_coefficients, window_type
export window_power_correction, window_amplitude_correction

# Phase 3 exports
export SpectrumDisplay, DisplayConfig
export FrequencyScale, LinearScale, LogScale
export MagnitudeScale, LinearMagnitude, DecibelMagnitude
export LinearSpectrumDisplay, LogSpectrumDisplay
export update!, display_figure, reset_peaks!
export set_freq_limits!, set_mag_limits!, set_title!
export frequency_data, magnitude_data, peak_data, screenshot

# Phase 4 exports
export WaterfallDisplay, WaterfallConfig
export push_frame!, reset!
export spectrogram_data, frame_count

# Phase 5 exports
export Peak, PeakDetector
export detect_peaks!, detect_peaks, find_peak
export track_peaks!, reset!
export peak_frequencies, peak_magnitudes, peak_bins
export filter_by_confidence, filter_by_snr, top_peaks
export num_peaks, has_peaks, peaks_to_matrix, print_peaks

end # module
