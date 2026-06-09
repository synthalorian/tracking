module Tracking

using PortAudio
using FFTW

# Phase 1: Audio capture (PortAudio + RingBuffer)
include("ringbuffer.jl")
include("audio.jl")

# Phase 2: FFT engine (FFTW) with windowing
include("fft.jl")

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

end # module
