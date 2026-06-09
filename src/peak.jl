using Printf

# ------------------------------------------------------------------------------
# Phase 5: Peak Detection Algorithm
# ------------------------------------------------------------------------------
#
# Advanced peak detection with sub-bin interpolation, SNR thresholding,
# minimum peak spacing, and temporal tracking across frames.
#
# Algorithm overview:
# 1. Find local maxima in magnitude spectrum
# 2. Apply SNR threshold (peak must exceed noise floor by margin)
# 3. Apply minimum peak distance (suppress duplicates from spectral leakage)
# 4. Refine peak location using parabolic interpolation for sub-bin accuracy
# 5. Optionally track peaks across time frames for stability
# ------------------------------------------------------------------------------

"""Represents a detected spectral peak with sub-bin precision.

Fields:
- frequency: Refined frequency in Hz (sub-bin accurate)
- magnitude: Peak magnitude (with amplitude correction applied)
- bin: Integer bin index of the peak
- bin_offset: Sub-bin offset from integer bin (-0.5 to +0.5)
- confidence: Detection confidence (0.0 to 1.0, based on SNR)
- snr_db: Signal-to-noise ratio in dB
- frame_id: Frame number when peak was detected (for tracking)
"""
struct Peak
    frequency::Float32
    magnitude::Float32
    bin::Int
    bin_offset::Float32
    confidence::Float32
    snr_db::Float32
    frame_id::Int
end

"""Default Peak constructor with frame_id=0."""
function Peak(frequency::Real, magnitude::Real, bin::Int, bin_offset::Real,
              confidence::Real, snr_db::Real)
    return Peak(Float32(frequency), Float32(magnitude), bin, Float32(bin_offset),
                Float32(confidence), Float32(snr_db), 0)
end

function Base.show(io::IO, p::Peak)
    print(io, "Peak(f=$(round(p.frequency, digits=2))Hz, ")
    print(io, "mag=$(round(p.magnitude, digits=4)), ")
    print(io, "bin=$(p.bin), offset=$(round(p.bin_offset, digits=3)), ")
    print(io, "SNR=$(round(p.snr_db, digits=1))dB, ")
    print(io, "conf=$(round(p.confidence, digits=2)))")
end

# ------------------------------------------------------------------------------
# Peak Detector Configuration
# ------------------------------------------------------------------------------

"""Configuration for the peak detection algorithm.

Fields:
- min_height: Minimum absolute magnitude for a peak (default: 0.0)
- snr_threshold: Minimum SNR in dB above noise floor (default: 10.0)
- min_peak_distance: Minimum distance between peaks in Hz (default: 50.0)
- min_freq: Minimum frequency to consider in Hz (default: 20.0)
- max_freq: Maximum frequency to consider in Hz (default: Nyquist)
- noise_floor_percentile: Percentile for noise floor estimation (default: 50.0, i.e. median)
- exclude_dc: Whether to exclude DC bin (default: true)
- max_peaks: Maximum number of peaks to return (default: 100)
- use_interpolation: Whether to use parabolic interpolation (default: true)
"""
mutable struct PeakDetector
    min_height::Float32
    snr_threshold::Float32
    min_peak_distance::Float32
    min_freq::Float32
    max_freq::Float32
    noise_floor_percentile::Float32
    exclude_dc::Bool
    max_peaks::Int
    use_interpolation::Bool
    frame_counter::Int
    prev_peaks::Vector{Peak}
    
    function PeakDetector(;
        min_height::Real=0.0,
        snr_threshold::Real=10.0,
        min_peak_distance::Real=50.0,
        min_freq::Real=20.0,
        max_freq::Real=22050.0,
        noise_floor_percentile::Real=50.0,
        exclude_dc::Bool=true,
        max_peaks::Int=100,
        use_interpolation::Bool=true
    )
        new(
            Float32(min_height),
            Float32(snr_threshold),
            Float32(min_peak_distance),
            Float32(min_freq),
            Float32(max_freq),
            Float32(noise_floor_percentile),
            exclude_dc,
            max_peaks,
            use_interpolation,
            0,
            Peak[]
        )
    end
end

function Base.show(io::IO, pd::PeakDetector)
    print(io, "PeakDetector(")
    print(io, "min_height=$(pd.min_height), ")
    print(io, "SNR=$(pd.snr_threshold)dB, ")
    print(io, "min_dist=$(pd.min_peak_distance)Hz, ")
    print(io, "freq=[$(pd.min_freq)-$(pd.max_freq)]Hz, ")
    print(io, "max_peaks=$(pd.max_peaks), ")
    print(io, "interp=$(pd.use_interpolation), ")
    print(io, "frames=$(pd.frame_counter))")
end

# ------------------------------------------------------------------------------
# Core Peak Detection
# ------------------------------------------------------------------------------

"""Estimate noise floor from magnitude spectrum using percentile.

Uses the specified percentile of the magnitude spectrum as the noise floor estimate.
This is robust against spurious peaks in the noise estimate itself."""
function _estimate_noise_floor(mag::Vector{Float32}, percentile::Float32=50.0f0)::Float32
    if isempty(mag)
        return 0.0f0
    end
    
    # Sort and pick the percentile point
    sorted = sort(mag)
    idx = max(1, min(length(sorted), ceil(Int, length(sorted) * percentile / 100.0f0)))
    return sorted[idx]
end

"""Refine peak location using parabolic interpolation.

Given a peak at bin i with neighbors at i-1 and i+1, fit a parabola and
find the vertex for sub-bin frequency estimation.

Returns (refined_frequency, refined_magnitude, bin_offset)."""
function _refine_peak_parabolic(freq_bins::Vector{Float32}, mag::Vector{Float32},
                                 bin_idx::Int)::Tuple{Float32, Float32, Float32}
    n = length(mag)
    
    # Ensure we have neighbors
    if bin_idx <= 1 || bin_idx >= n
        # Can't interpolate at edges
        return (freq_bins[bin_idx], mag[bin_idx], 0.0f0)
    end
    
    # Three-point parabolic interpolation
    # Points at x = -1, 0, 1 with values a, b, c
    a = mag[bin_idx - 1]
    b = mag[bin_idx]
    c = mag[bin_idx + 1]
    
    # Parabola: y = p*x^2 + q*x + r
    # At x=0: r = b
    # At x=-1: p - q + r = a  =>  p - q = a - b
    # At x=1:  p + q + r = c  =>  p + q = c - b
    # Solving:
    # 2p = (a - b) + (c - b) = a + c - 2b
    # 2q = (c - b) - (a - b) = c - a
    
    denom = 2.0f0 * b - a - c
    
    if abs(denom) < 1.0f-10
        # Flat top or numerical issue, no interpolation possible
        return (freq_bins[bin_idx], mag[bin_idx], 0.0f0)
    end
    
    # Vertex offset from center bin
    # Correct formula: offset = (c - a) / (2 * (2b - a - c))
    # When c > a, peak is to the right (positive offset)
    offset = (c - a) / (2.0f0 * denom)
    
    # Clamp offset to reasonable range (-0.5 to 0.5)
    offset = clamp(offset, -0.5f0, 0.5f0)
    
    # Refined magnitude at vertex
    # y_vertex = b + (a - c)^2 / (8 * (2b - a - c))
    # The vertex of a downward-opening parabola is above the center point
    refined_mag = b + (a - c)^2 / (8.0f0 * denom)
    
    # Ensure refined magnitude is positive
    refined_mag = max(refined_mag, 0.0f0)
    
    # Refined frequency
    df = freq_bins[2] - freq_bins[1]  # Frequency resolution
    refined_freq = freq_bins[bin_idx] + offset * df
    
    return (refined_freq, refined_mag, offset)
end

"""Calculate SNR in dB for a peak relative to noise floor.

SNR = 20 * log10(peak_magnitude / noise_floor)"""
function _calculate_snr(peak_mag::Float32, noise_floor::Float32)::Float32
    if noise_floor <= 0.0f0 || peak_mag <= 0.0f0
        return 0.0f0
    end
    return 20.0f0 * log10(peak_mag / noise_floor)
end

"""Calculate confidence score based on SNR.

Confidence maps SNR to [0, 1] using a sigmoid-like function.
Higher SNR = higher confidence."""
function _calculate_confidence(snr_db::Float32, snr_threshold::Float32)::Float32
    # Map SNR to confidence: below threshold -> low confidence
    # At threshold -> 0.5, well above -> approaches 1.0
    if snr_db <= 0.0f0
        return 0.0f0
    end
    
    # Use a smooth sigmoid-like mapping
    # confidence = 1 - exp(-snr_db / threshold)
    # At snr = threshold: confidence ≈ 0.63
    # At snr = 2*threshold: confidence ≈ 0.86
    conf = 1.0f0 - exp(-snr_db / max(snr_threshold, 1.0f0))
    return clamp(conf, 0.0f0, 1.0f0)
end

"""Find local maxima in magnitude spectrum.

Returns vector of integer bin indices (1-based) where local maxima occur."""
function _find_local_maxima(mag::Vector{Float32}; exclude_dc::Bool=true)::Vector{Int}
    n = length(mag)
    peaks = Int[]
    
    start_idx = exclude_dc ? 3 : 2  # Need neighbors on both sides
    end_idx = n - 1
    
    @inbounds for i in start_idx:end_idx
        if mag[i] > mag[i - 1] && mag[i] > mag[i + 1]
            push!(peaks, i)
        end
    end
    
    return peaks
end

"""Sort peaks by magnitude in descending order."""
function _sort_peaks_by_magnitude(peaks::Vector{Peak})::Vector{Peak}
    return sort(peaks, by=p -> p.magnitude, rev=true)
end

"""Filter peaks by minimum distance in Hz.

After sorting by magnitude (strongest first), keep only peaks that are
at least min_distance Hz away from any already-kept peak."""
function _filter_by_distance(peaks::Vector{Peak}, min_distance::Float32)::Vector{Peak}
    if isempty(peaks) || min_distance <= 0.0f0
        return peaks
    end
    
    sorted = _sort_peaks_by_magnitude(peaks)
    kept = Peak[]
    
    for peak in sorted
        # Check if this peak is far enough from all kept peaks
        too_close = false
        for kept_peak in kept
            if abs(peak.frequency - kept_peak.frequency) < min_distance
                too_close = true
                break
            end
        end
        
        if !too_close
            push!(kept, peak)
        end
    end
    
    return kept
end

"""Filter peaks to frequency range."""
function _filter_by_frequency(peaks::Vector{Peak}, min_freq::Float32, max_freq::Float32)::Vector{Peak}
    return filter(p -> p.frequency >= min_freq && p.frequency <= max_freq, peaks)
end

# ------------------------------------------------------------------------------
# Main Detection API
# ------------------------------------------------------------------------------

"""Detect peaks in the magnitude spectrum from an FFTEngine.

This is the main entry point for peak detection. It:
1. Finds local maxima in the magnitude spectrum
2. Estimates noise floor
3. Applies SNR threshold
4. Refines peak locations using parabolic interpolation
5. Filters by frequency range and minimum peak distance
6. Sorts by magnitude and limits to max_peaks

Parameters:
- detector: PeakDetector configuration
- engine: FFTEngine with computed FFT (must have called process! first)
- mags: Optional pre-computed magnitude spectrum (uses magnitude_spectrum if not provided)

Returns: Vector of Peak structs, sorted by magnitude (strongest first)."""
function detect_peaks!(detector::PeakDetector, engine::FFTEngine;
                       mags::Union{Vector{Float32}, Nothing}=nothing)::Vector{Peak}
    # Increment frame counter
    detector.frame_counter += 1
    frame_id = detector.frame_counter
    
    # Get magnitude spectrum
    if mags === nothing
        mags = magnitude_spectrum(engine; corrected=true)
    end
    
    freq_bins = engine.freq_bins
    df = frequency_resolution(engine)
    
    # Estimate noise floor
    noise_floor = _estimate_noise_floor(mags, detector.noise_floor_percentile)
    
    # Find local maxima
    local_maxima = _find_local_maxima(mags; exclude_dc=detector.exclude_dc)
    
    peaks = Peak[]
    
    @inbounds for bin_idx in local_maxima
        peak_mag = mags[bin_idx]
        
        # Check absolute height threshold
        if peak_mag < detector.min_height
            continue
        end
        
        # Calculate SNR
        snr_db = _calculate_snr(peak_mag, noise_floor)
        
        # Check SNR threshold
        if snr_db < detector.snr_threshold
            continue
        end
        
        # Refine peak location
        if detector.use_interpolation && bin_idx > 1 && bin_idx < length(mags)
            refined_freq, refined_mag, offset = _refine_peak_parabolic(freq_bins, mags, bin_idx)
            
            # Re-calculate SNR with refined magnitude
            snr_db = _calculate_snr(refined_mag, noise_floor)
            
            confidence = _calculate_confidence(snr_db, detector.snr_threshold)
            
            push!(peaks, Peak(refined_freq, refined_mag, bin_idx - 1, offset,
                            confidence, snr_db, frame_id))
        else
            # No interpolation, use integer bin
            freq = freq_bins[bin_idx]
            confidence = _calculate_confidence(snr_db, detector.snr_threshold)
            
            push!(peaks, Peak(freq, peak_mag, bin_idx - 1, 0.0f0,
                            confidence, snr_db, frame_id))
        end
    end
    
    # Filter by frequency range
    peaks = _filter_by_frequency(peaks, detector.min_freq, detector.max_freq)
    
    # Filter by minimum peak distance
    peaks = _filter_by_distance(peaks, detector.min_peak_distance)
    
    # Sort by magnitude (strongest first) and limit
    peaks = _sort_peaks_by_magnitude(peaks)
    
    if length(peaks) > detector.max_peaks
        peaks = peaks[1:detector.max_peaks]
    end
    
    # Store for temporal tracking
    detector.prev_peaks = peaks
    
    return peaks
end

"""Detect peaks from a raw magnitude vector and frequency bins.

Use this when you have magnitude data outside of an FFTEngine context.

Parameters:
- detector: PeakDetector configuration
- mags: Magnitude spectrum vector
- freq_bins: Frequency values for each bin in Hz
- df: Frequency resolution (bin spacing) in Hz

Returns: Vector of Peak structs."""
function detect_peaks!(detector::PeakDetector, mags::Vector{Float32},
                       freq_bins::Vector{Float32}, df::Float32)::Vector{Peak}
    detector.frame_counter += 1
    frame_id = detector.frame_counter
    
    # Estimate noise floor
    noise_floor = _estimate_noise_floor(mags, detector.noise_floor_percentile)
    
    # Find local maxima
    local_maxima = _find_local_maxima(mags; exclude_dc=detector.exclude_dc)
    
    peaks = Peak[]
    
    @inbounds for bin_idx in local_maxima
        peak_mag = mags[bin_idx]
        
        # Check absolute height threshold
        if peak_mag < detector.min_height
            continue
        end
        
        # Calculate SNR
        snr_db = _calculate_snr(peak_mag, noise_floor)
        
        # Check SNR threshold
        if snr_db < detector.snr_threshold
            continue
        end
        
        # Refine peak location
        if detector.use_interpolation && bin_idx > 1 && bin_idx < length(mags)
            refined_freq, refined_mag, offset = _refine_peak_parabolic(freq_bins, mags, bin_idx)
            
            # Re-calculate SNR with refined magnitude
            snr_db = _calculate_snr(refined_mag, noise_floor)
            
            confidence = _calculate_confidence(snr_db, detector.snr_threshold)
            
            push!(peaks, Peak(refined_freq, refined_mag, bin_idx - 1, offset,
                            confidence, snr_db, frame_id))
        else
            # No interpolation, use integer bin
            freq = freq_bins[bin_idx]
            confidence = _calculate_confidence(snr_db, detector.snr_threshold)
            
            push!(peaks, Peak(freq, peak_mag, bin_idx - 1, 0.0f0,
                            confidence, snr_db, frame_id))
        end
    end
    
    # Filter by frequency range
    peaks = _filter_by_frequency(peaks, detector.min_freq, detector.max_freq)
    
    # Filter by minimum peak distance
    peaks = _filter_by_distance(peaks, detector.min_peak_distance)
    
    # Sort by magnitude (strongest first) and limit
    peaks = _sort_peaks_by_magnitude(peaks)
    
    if length(peaks) > detector.max_peaks
        peaks = peaks[1:detector.max_peaks]
    end
    
    # Store for temporal tracking
    detector.prev_peaks = peaks
    
    return peaks
end

# ------------------------------------------------------------------------------
# Temporal Peak Tracking
# ------------------------------------------------------------------------------

"""Track peaks across frames by matching frequencies.

Matches current peaks to previous peaks within a frequency tolerance.
Useful for stabilizing peak detection in real-time applications where
the same physical frequency source persists across multiple frames.

Parameters:
- detector: PeakDetector with prev_peaks populated
- current_peaks: Peaks detected in the current frame
- freq_tolerance: Maximum frequency difference for match in Hz (default: 20.0)
- min_frames_persisted: Minimum number of frames a peak must persist (default: 1)

Returns: Vector of tracked peaks that have persisted for min_frames_persisted."""
function track_peaks!(detector::PeakDetector, current_peaks::Vector{Peak};
                      freq_tolerance::Real=20.0,
                      min_frames_persisted::Int=1)::Vector{Peak}
    prev = detector.prev_peaks
    tol = Float32(freq_tolerance)
    
    if isempty(prev) || min_frames_persisted <= 1
        # First frame or no persistence requirement
        detector.prev_peaks = current_peaks
        return current_peaks
    end
    
    tracked = Peak[]
    
    for curr in current_peaks
        # Find best matching previous peak
        matched = false
        for prev_peak in prev
            if abs(curr.frequency - prev_peak.frequency) < tol
                matched = true
                break
            end
        end
        
        if matched
            push!(tracked, curr)
        end
    end
    
    detector.prev_peaks = current_peaks
    return tracked
end

"""Reset the peak detector's frame counter and history."""
function reset!(detector::PeakDetector)
    detector.frame_counter = 0
    detector.prev_peaks = Peak[]
    return detector
end

# ------------------------------------------------------------------------------
# Convenience Functions
# ------------------------------------------------------------------------------

"""Get the frequencies of detected peaks."""
function peak_frequencies(peaks::Vector{Peak})::Vector{Float32}
    return [p.frequency for p in peaks]
end

"""Get the magnitudes of detected peaks."""
function peak_magnitudes(peaks::Vector{Peak})::Vector{Float32}
    return [p.magnitude for p in peaks]
end

"""Get the bin indices of detected peaks."""
function peak_bins(peaks::Vector{Peak})::Vector{Int}
    return [p.bin for p in peaks]
end

"""Filter peaks by minimum confidence score."""
function filter_by_confidence(peaks::Vector{Peak}, min_confidence::Real)::Vector{Peak}
    return filter(p -> p.confidence >= min_confidence, peaks)
end

"""Filter peaks by minimum SNR."""
function filter_by_snr(peaks::Vector{Peak}, min_snr_db::Real)::Vector{Peak}
    return filter(p -> p.snr_db >= min_snr_db, peaks)
end

"""Get the strongest N peaks."""
function top_peaks(peaks::Vector{Peak}, n::Int)::Vector{Peak}
    if n >= length(peaks)
        return peaks
    end
    return peaks[1:n]
end

"""Get peak count."""
function num_peaks(peaks::Vector{Peak})::Int
    return length(peaks)
end

"""Check if any peaks were detected."""
function has_peaks(peaks::Vector{Peak})::Bool
    return !isempty(peaks)
end

"""Convert peaks to a matrix for easy inspection.
Columns: frequency, magnitude, bin, bin_offset, confidence, snr_db"""
function peaks_to_matrix(peaks::Vector{Peak})::Matrix{Float32}
    n = length(peaks)
    mat = Matrix{Float32}(undef, n, 6)
    @inbounds for i in 1:n
        p = peaks[i]
        mat[i, 1] = p.frequency
        mat[i, 2] = p.magnitude
        mat[i, 3] = Float32(p.bin)
        mat[i, 4] = p.bin_offset
        mat[i, 5] = p.confidence
        mat[i, 6] = p.snr_db
    end
    return mat
end

"""Print a summary table of detected peaks."""
function print_peaks(peaks::Vector{Peak}; max_display::Int=10)
    n = length(peaks)
    println("Detected $n peak(s):")
    println()
    println("  #    Frequency(Hz)  Magnitude    Bin    Offset   SNR(dB)  Confidence")
    println("  " * "-"^72)
    
    display_count = min(n, max_display)
    @inbounds for i in 1:display_count
        p = peaks[i]
        println(@sprintf("  %-3d  %-13.2f  %-11.4f  %-5d  %-7.3f  %-7.1f  %.3f",
                        i, p.frequency, p.magnitude, p.bin, p.bin_offset, p.snr_db, p.confidence))
    end
    
    if n > max_display
        println("  ... and $(n - max_display) more")
    end
    
    println()
end

# ------------------------------------------------------------------------------
# Integration with Existing FFT Engine Functions
# ------------------------------------------------------------------------------

"""Enhanced find_peak_bin using parabolic interpolation.

Returns (Peak, frequency, magnitude) where Peak contains refined information.
This replaces the simple find_peak_bin with sub-bin accuracy."""
function find_peak(detector::PeakDetector, engine::FFTEngine)::Union{Peak, Nothing}
    peaks = detect_peaks!(detector, engine)
    
    if isempty(peaks)
        return nothing
    end
    
    return peaks[1]  # Strongest peak
end

"""Enhanced find_peaks using the full PeakDetector algorithm.

This is a drop-in replacement for the basic find_peaks in fft.jl,
providing sub-bin interpolation, SNR thresholding, and peak spacing."""
function detect_peaks(engine::FFTEngine;
                      min_height::Real=0.0,
                      snr_threshold::Real=10.0,
                      min_peak_distance::Real=50.0,
                      max_peaks::Int=100)::Vector{Peak}
    detector = PeakDetector(
        min_height=min_height,
        snr_threshold=snr_threshold,
        min_peak_distance=min_peak_distance,
        max_peaks=max_peaks
    )
    return detect_peaks!(detector, engine)
end
