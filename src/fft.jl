using FFTW

# ------------------------------------------------------------------------------
# Window Functions
# ------------------------------------------------------------------------------

abstract type WindowFunction end

"""Rectangular (no) window."""
struct RectangularWindow <: WindowFunction end

"""Hann window: 0.5 * (1 - cos(2πn/(N-1))).
Good general-purpose window with low sidelobes."""
struct HannWindow <: WindowFunction end

"""Hamming window: 0.54 - 0.46 * cos(2πn/(N-1)).
Similar to Hann but with lower first sidelobe."""
struct HammingWindow <: WindowFunction end

"""Blackman window: 0.42 - 0.5 * cos(2πn/(N-1)) + 0.08 * cos(4πn/(N-1)).
Lower sidelobes at the cost of wider main lobe."""
struct BlackmanWindow <: WindowFunction end

"""Generate window coefficients for the given window type and length."""
function window_coefficients(::RectangularWindow, n::Int)::Vector{Float32}
    return ones(Float32, n)
end

function window_coefficients(::HannWindow, n::Int)::Vector{Float32}
    return Float32[0.5f0 * (1.0f0 - cos(2.0f0 * π * (i - 1) / (n - 1))) for i in 1:n]
end

function window_coefficients(::HammingWindow, n::Int)::Vector{Float32}
    return Float32[0.54f0 - 0.46f0 * cos(2.0f0 * π * (i - 1) / (n - 1)) for i in 1:n]
end

function window_coefficients(::BlackmanWindow, n::Int)::Vector{Float32}
    return Float32[
        0.42f0 - 0.5f0 * cos(2.0f0 * π * (i - 1) / (n - 1)) +
        0.08f0 * cos(4.0f0 * π * (i - 1) / (n - 1))
        for i in 1:n
    ]
end

"""Compute window power correction factor (to compensate for energy loss from windowing)."""
function window_power_correction(w::Vector{Float32})::Float32
    # Correction factor = 1 / sqrt(mean(w.^2))
    rms = sqrt(sum(x -> x^2, w) / length(w))
    return 1.0f0 / rms
end

"""Compute window amplitude correction factor (for peak amplitude measurements)."""
function window_amplitude_correction(w::Vector{Float32})::Float32
    return 1.0f0 / (sum(w) / length(w))
end

# ------------------------------------------------------------------------------
# FFT Engine
# ------------------------------------------------------------------------------

"""FFTEngine computes real-valued FFT with windowing.

Fields:
- nfft: FFT size (will be rounded up to next power of 2)
- sample_rate: Audio sample rate in Hz
- window: Precomputed window coefficients
- window_type: Type of window function used
- plan: FFTW plan for real FFT
- input_buffer: Real input buffer (nfft samples)
- output_buffer: Complex FFT output (nfft÷2+1 bins)
- magnitude_buffer: Magnitude spectrum cache
- phase_buffer: Phase spectrum cache
- freq_bins: Frequency values for each bin in Hz
- power_correction: Factor to correct power measurements for window loss
- amplitude_correction: Factor to correct amplitude measurements for window loss
- valid: Whether magnitude/phase buffers are up to date
"""
mutable struct FFTEngine
    nfft::Int
    sample_rate::Int
    window::Vector{Float32}
    window_type::WindowFunction
    plan::Any  # FFTW plan
    input_buffer::Vector{Float32}
    output_buffer::Vector{ComplexF32}
    magnitude_buffer::Vector{Float32}
    phase_buffer::Vector{Float32}
    freq_bins::Vector{Float32}
    power_correction::Float32
    amplitude_correction::Float32
    valid::Bool
end

"""Create a new FFTEngine.

Parameters:
- nfft: FFT size (will be rounded to next power of 2)
- sample_rate: Audio sample rate in Hz (default: 44100)
- window_type: Window function to apply (default: HannWindow)
"""
function FFTEngine(nfft::Int, sample_rate::Int=44100; window_type::WindowFunction=HannWindow())
    # Round up to next power of 2 for FFTW efficiency
    nfft = nextpow(2, nfft)
    
    window = window_coefficients(window_type, nfft)
    
    input_buffer = Vector{Float32}(undef, nfft)
    output_buffer = Vector{ComplexF32}(undef, nfft ÷ 2 + 1)
    
    # Create FFTW plan for real input
    plan = plan_rfft(input_buffer)
    
    magnitude_buffer = Vector{Float32}(undef, nfft ÷ 2 + 1)
    phase_buffer = Vector{Float32}(undef, nfft ÷ 2 + 1)
    
    # Frequency bins: 0, sr/nfft, 2*sr/nfft, ..., sr/2
    freq_bins = Float32[i * sample_rate / nfft for i in 0:(nfft ÷ 2)]
    
    power_correction = window_power_correction(window)
    amplitude_correction = window_amplitude_correction(window)
    
    return FFTEngine(
        nfft, sample_rate, window, window_type, plan,
        input_buffer, output_buffer, magnitude_buffer, phase_buffer,
        freq_bins, power_correction, amplitude_correction, false
    )
end

# ------------------------------------------------------------------------------
# Core FFT Operations
# ------------------------------------------------------------------------------

"""Compute FFT of real-valued samples with windowing.

Copies samples into internal buffer, applies window, computes FFT.
Returns complex spectrum (nfft÷2+1 bins for real input).
"""
function process!(engine::FFTEngine, samples::Vector{Float32})::Vector{ComplexF32}
    n = length(samples)
    if n != engine.nfft
        error("FFTEngine: expected $(engine.nfft) samples, got $n")
    end
    
    # Copy and window the input
    @inbounds for i in 1:n
        engine.input_buffer[i] = samples[i] * engine.window[i]
    end
    
    # Execute FFT
    engine.output_buffer .= engine.plan * engine.input_buffer
    engine.valid = false
    
    return engine.output_buffer
end

"""Compute FFT from a RingBuffer, reading the most recent nfft samples.

If fewer samples are available, throws an error."""
function process!(engine::FFTEngine, rb::RingBuffer{Float32})::Vector{ComplexF32}
    if length(rb) < engine.nfft
        error("FFTEngine: RingBuffer has $(length(rb)) samples, need $(engine.nfft)")
    end
    
    # Read the most recent nfft samples
    # We need to peek the last nfft samples in order
    # peek(rb, n) returns oldest n samples, but we want newest
    # So we read all available and take the last nfft
    available_samples = min(length(rb), engine.nfft * 2)  # Read enough to have nfft recent
    all_samples = peek(rb, min(length(rb), available_samples))
    samples = all_samples[max(1, end - engine.nfft + 1):end]
    
    return process!(engine, samples)
end

"""Get the magnitude spectrum (amplitude per frequency bin).

Computes |X[k]| for each FFT bin. Optionally applies amplitude correction
for window compensation.
"""
function magnitude_spectrum(engine::FFTEngine; corrected::Bool=true)::Vector{Float32}
    if !engine.valid
        @inbounds for i in eachindex(engine.output_buffer)
            re = real(engine.output_buffer[i])
            im = imag(engine.output_buffer[i])
            engine.magnitude_buffer[i] = sqrt(re * re + im * im)
        end
        engine.valid = true
    end
    
    if corrected
        return engine.magnitude_buffer .* engine.amplitude_correction
    else
        return copy(engine.magnitude_buffer)
    end
end

"""Get the power spectrum (power per frequency bin).

Power = |X[k]|² / N². Optionally applies power correction.
"""
function power_spectrum(engine::FFTEngine; corrected::Bool=true)::Vector{Float32}
    mag = magnitude_spectrum(engine; corrected=false)
    n = engine.nfft
    power = mag.^2 ./ n^2
    
    if corrected
        return power .* (engine.power_correction^2)
    else
        return power
    end
end

"""Get the phase spectrum in radians.

Computes atan(imag(X[k]), real(X[k])) for each bin.
"""
function phase_spectrum(engine::FFTEngine)::Vector{Float32}
    @inbounds for i in eachindex(engine.output_buffer)
        engine.phase_buffer[i] = atan(imag(engine.output_buffer[i]), real(engine.output_buffer[i]))
    end
    return copy(engine.phase_buffer)
end

"""Get the frequency values (in Hz) for each FFT bin."""
function frequency_bins(engine::FFTEngine)::Vector{Float32}
    return copy(engine.freq_bins)
end

"""Convert bin index to frequency in Hz.

Bins are 0-indexed: bin 0 = DC, bin nfft÷2 = Nyquist.
"""
function bin_to_hz(engine::FFTEngine, bin::Int)::Float32
    if bin < 0 || bin > engine.nfft ÷ 2
        error("FFTEngine: bin $bin out of range [0, $(engine.nfft ÷ 2)]")
    end
    return engine.freq_bins[bin + 1]  # +1 for 1-based indexing
end

"""Convert frequency in Hz to nearest bin index."""
function hz_to_bin(engine::FFTEngine, hz::Real)::Int
    if hz < 0 || hz > engine.sample_rate / 2
        error("FFTEngine: frequency $hz Hz out of range [0, $(engine.sample_rate/2)]")
    end
    return round(Int, hz * engine.nfft / engine.sample_rate)
end

"""Get frequency resolution (bin spacing) in Hz."""
function frequency_resolution(engine::FFTEngine)::Float32
    return engine.sample_rate / engine.nfft
end

# ------------------------------------------------------------------------------
# Peak Detection Helpers
# ------------------------------------------------------------------------------

"""Find the bin with maximum magnitude in the spectrum.

Returns (bin_index, frequency_hz, magnitude).
Excludes DC bin (bin 0) by default."""
function find_peak_bin(engine::FFTEngine; exclude_dc::Bool=true)::Tuple{Int, Float32, Float32}
    mag = magnitude_spectrum(engine; corrected=false)
    
    start_bin = exclude_dc ? 2 : 1  # 1-based indexing
    max_idx = start_bin
    max_mag = mag[start_bin]
    
    @inbounds for i in (start_bin + 1):length(mag)
        if mag[i] > max_mag
            max_mag = mag[i]
            max_idx = i
        end
    end
    
    bin_idx = max_idx - 1  # Convert to 0-based
    freq = engine.freq_bins[max_idx]
    
    return (bin_idx, freq, max_mag)
end

"""Find all local maxima (peaks) in the magnitude spectrum.

Returns vector of (bin_index, frequency_hz, magnitude) tuples.
A peak is a bin that is greater than both neighbors.

Parameters:
- min_height: minimum magnitude to be considered a peak
- exclude_dc: if true, skip DC bin
"""
function find_peaks(engine::FFTEngine; min_height::Float32=0.0f0, exclude_dc::Bool=true)::Vector{Tuple{Int, Float32, Float32}}
    mag = magnitude_spectrum(engine; corrected=false)
    
    start_bin = exclude_dc ? 3 : 2  # Need neighbor on both sides, 1-based
    end_bin = length(mag) - 1
    
    peaks = Vector{Tuple{Int, Float32, Float32}}()
    
    @inbounds for i in start_bin:end_bin
        if mag[i] > min_height && mag[i] > mag[i - 1] && mag[i] > mag[i + 1]
            bin_idx = i - 1  # Convert to 0-based
            freq = engine.freq_bins[i]
            push!(peaks, (bin_idx, freq, mag[i]))
        end
    end
    
    return peaks
end

"""Get the magnitude at a specific frequency bin."""
function magnitude_at_bin(engine::FFTEngine, bin::Int)::Float32
    if bin < 0 || bin > engine.nfft ÷ 2
        error("FFTEngine: bin $bin out of range [0, $(engine.nfft ÷ 2)]")
    end
    mag = magnitude_spectrum(engine; corrected=false)
    return mag[bin + 1]
end

"""Get the magnitude at a specific frequency in Hz."""
function magnitude_at_hz(engine::FFTEngine, hz::Real)::Float32
    bin = hz_to_bin(engine, hz)
    return magnitude_at_bin(engine, bin)
end

# ------------------------------------------------------------------------------
# Utility Functions
# ------------------------------------------------------------------------------

"""Get the FFT size."""
function fft_size(engine::FFTEngine)::Int
    return engine.nfft
end

"""Get the sample rate."""
function sample_rate(engine::FFTEngine)::Int
    return engine.sample_rate
end

"""Get the number of frequency bins (nfft÷2 + 1)."""
function num_bins(engine::FFTEngine)::Int
    return engine.nfft ÷ 2 + 1
end

"""Get the Nyquist frequency (sample_rate / 2)."""
function nyquist(engine::FFTEngine)::Float32
    return engine.sample_rate / 2.0f0
end

"""Get the window coefficients."""
function window_coefficients(engine::FFTEngine)::Vector{Float32}
    return copy(engine.window)
end

"""Get the window type."""
function window_type(engine::FFTEngine)::WindowFunction
    return engine.window_type
end

function Base.show(io::IO, engine::FFTEngine)
    print(io, "FFTEngine(nfft=$(engine.nfft), sr=$(engine.sample_rate)Hz, ")
    print(io, "window=$(typeof(engine.window_type)), ")
    print(io, "resolution=$(round(frequency_resolution(engine), digits=2))Hz, ")
    print(io, "bins=$(num_bins(engine)))")
end
