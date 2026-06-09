# ------------------------------------------------------------------------------
# Phase 6: Harmonic Series Tracking
# ------------------------------------------------------------------------------
#
# Identifies harmonic series (families of integer-multiple frequencies) from
# detected spectral peaks. Essential for pitch detection, note identification,
# and MIDI export.
#
# Algorithm overview:
# 1. Take detected peaks from Phase 5
# 2. For each strong peak, treat it as candidate fundamental f0
# 3. Check if 2*f0, 3*f0, ... exist among other peaks within tolerance
# 4. Score each candidate by number of harmonics, strengths, and regularity
# 5. Select best non-overlapping series
# 6. Track series across frames for temporal stability
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Data Structures
# ------------------------------------------------------------------------------

"""Represents a single harmonic within a series.

Fields:
- number: Harmonic number (1 = fundamental, 2 = 2nd harmonic, etc.)
- frequency: Detected frequency in Hz
- magnitude: Peak magnitude
- bin: FFT bin index
- deviation: Deviation from ideal harmonic frequency in Hz
- confidence: Individual harmonic confidence (0.0 to 1.0)
"""
struct Harmonic
    number::Int
    frequency::Float32
    magnitude::Float32
    bin::Int
    deviation::Float32
    confidence::Float32
end

"""Default Harmonic constructor."""
function Harmonic(number::Int, frequency::Real, magnitude::Real,
                  bin::Int, deviation::Real, confidence::Real)
    return Harmonic(number, Float32(frequency), Float32(magnitude),
                    bin, Float32(deviation), Float32(confidence))
end

function Base.show(io::IO, h::Harmonic)
    print(io, "H$(h.number)(f=$(round(h.frequency, digits=1))Hz, ")
    print(io, "mag=$(round(h.magnitude, digits=3)), ")
    print(io, "dev=$(round(h.deviation, digits=2))Hz, ")
    print(io, "conf=$(round(h.confidence, digits=2)))")
end

"""Represents a detected harmonic series (a set of harmonically-related peaks).

Fields:
- fundamental: Fundamental frequency in Hz (estimated f0)
- harmonics: Vector of detected Harmonic structs
- overall_confidence: Aggregate confidence score (0.0 to 1.0)
- inharmonicity: Measure of deviation from perfect harmonicity
- frame_id: Frame number when series was detected
- series_id: Persistent ID for tracking across frames
"""
struct HarmonicSeries
    fundamental::Float32
    harmonics::Vector{Harmonic}
    overall_confidence::Float32
    inharmonicity::Float32
    frame_id::Int
    series_id::Int
end

"""Default HarmonicSeries constructor with frame_id=0, series_id=0."""
function HarmonicSeries(fundamental::Real, harmonics::Vector{Harmonic},
                        overall_confidence::Real, inharmonicity::Real)
    return HarmonicSeries(Float32(fundamental), harmonics,
                          Float32(overall_confidence), Float32(inharmonicity), 0, 0)
end

function HarmonicSeries(fundamental::Real, harmonics::Vector{Harmonic},
                        overall_confidence::Real, inharmonicity::Real,
                        frame_id::Int)
    return HarmonicSeries(Float32(fundamental), harmonics,
                          Float32(overall_confidence), Float32(inharmonicity),
                          frame_id, 0)
end

function Base.show(io::IO, hs::HarmonicSeries)
    n = length(hs.harmonics)
    print(io, "HarmonicSeries(f0=$(round(hs.fundamental, digits=2))Hz, ")
    print(io, "harmonics=$n, ")
    print(io, "conf=$(round(hs.overall_confidence, digits=2)), ")
    print(io, "inharm=$(round(hs.inharmonicity, digits=4)), ")
    print(io, "frame=$(hs.frame_id), id=$(hs.series_id))")
end

"""Configuration for harmonic series tracking.

Fields:
- max_harmonics: Maximum harmonic number to search for (default: 10)
- harmonic_tolerance: Frequency tolerance for matching harmonics as ratio of f0 (default: 0.03 = 3%)
- min_harmonics: Minimum number of harmonics required to form a series (default: 2)
- min_fundamental: Minimum fundamental frequency in Hz (default: 20.0)
- max_fundamental: Maximum fundamental frequency in Hz (default: 4000.0)
- min_confidence: Minimum confidence for a peak to be considered (default: 0.3)
- allow_missing_harmonics: Whether to allow gaps in the harmonic series (default: true)
- max_missing_harmonics: Maximum consecutive missing harmonics allowed (default: 2)
- track_persistence: Number of frames a series must persist (default: 1)
- freq_tolerance_hz: Absolute frequency tolerance in Hz (default: 5.0)
"""
mutable struct HarmonicTracker
    max_harmonics::Int
    harmonic_tolerance::Float32
    min_harmonics::Int
    min_fundamental::Float32
    max_fundamental::Float32
    min_confidence::Float32
    allow_missing_harmonics::Bool
    max_missing_harmonics::Int
    track_persistence::Int
    freq_tolerance_hz::Float32
    
    # Internal state
    frame_counter::Int
    next_series_id::Int
    tracked_series::Vector{HarmonicSeries}
    series_history::Dict{Int, Vector{HarmonicSeries}}
    
    function HarmonicTracker(;
        max_harmonics::Int=10,
        harmonic_tolerance::Real=0.03,
        min_harmonics::Int=2,
        min_fundamental::Real=20.0,
        max_fundamental::Real=4000.0,
        min_confidence::Real=0.3,
        allow_missing_harmonics::Bool=true,
        max_missing_harmonics::Int=2,
        track_persistence::Int=1,
        freq_tolerance_hz::Real=5.0
    )
        new(
            max_harmonics,
            Float32(harmonic_tolerance),
            min_harmonics,
            Float32(min_fundamental),
            Float32(max_fundamental),
            Float32(min_confidence),
            allow_missing_harmonics,
            max_missing_harmonics,
            track_persistence,
            Float32(freq_tolerance_hz),
            0,
            1,
            HarmonicSeries[],
            Dict{Int, Vector{HarmonicSeries}}()
        )
    end
end

function Base.show(io::IO, ht::HarmonicTracker)
    print(io, "HarmonicTracker(")
    print(io, "max_harm=$(ht.max_harmonics), ")
    print(io, "tol=$(ht.harmonic_tolerance), ")
    print(io, "min_harm=$(ht.min_harmonics), ")
    print(io, "f0=[$(ht.min_fundamental)-$(ht.max_fundamental)]Hz, ")
    print(io, "min_conf=$(ht.min_confidence), ")
    print(io, "persist=$(ht.track_persistence), ")
    print(io, "frames=$(ht.frame_counter), ")
    print(io, "tracked=$(length(ht.tracked_series)))")
end

# ------------------------------------------------------------------------------
# Core Harmonic Finding Algorithm
# ------------------------------------------------------------------------------

"""Calculate the tolerance in Hz for a given harmonic number and fundamental.

Uses the larger of:
- Relative tolerance: harmonic_tolerance * fundamental * harmonic_number
- Absolute tolerance: freq_tolerance_hz"""
function _harmonic_tolerance_hz(fundamental::Float32, harmonic_num::Int,
                                 tracker::HarmonicTracker)::Float32
    rel_tol = tracker.harmonic_tolerance * fundamental * harmonic_num
    return max(rel_tol, tracker.freq_tolerance_hz)
end

"""Find the best matching peak for an expected harmonic frequency.

Returns (peak_index, matched_peak) or (0, nothing) if no match found."""
function _find_harmonic_match(expected_freq::Float32, peaks::Vector{Peak},
                               used_peaks::Set{Int}, tracker::HarmonicTracker)::Tuple{Int, Union{Peak, Nothing}}
    best_idx = 0
    best_error = Inf32
    
    for (idx, peak) in enumerate(peaks)
        # Skip already-used peaks
        if idx in used_peaks
            continue
        end
        
        # Skip low-confidence peaks
        if peak.confidence < tracker.min_confidence
            continue
        end
        
        error = abs(peak.frequency - expected_freq)
        
        if error < best_error
            best_error = error
            best_idx = idx
        end
    end
    
    if best_idx == 0
        return (0, nothing)
    end
    
    return (best_idx, peaks[best_idx])
end

"""Build a harmonic series from a candidate fundamental peak.

Searches for harmonics 2, 3, ... up to max_harmonics that match the expected
frequencies within tolerance."""
function _build_series_from_fundamental(fundamental_peak::Peak, peaks::Vector{Peak},
                                         tracker::HarmonicTracker,
                                         frame_id::Int)::Union{HarmonicSeries, Nothing}
    f0 = fundamental_peak.frequency
    
    # Check fundamental is in valid range
    if f0 < tracker.min_fundamental || f0 > tracker.max_fundamental
        return nothing
    end
    
    harmonics = Harmonic[]
    used_peaks = Set{Int}()
    
    # Add the fundamental as harmonic #1
    h1 = Harmonic(1, f0, fundamental_peak.magnitude, fundamental_peak.bin,
                  0.0f0, fundamental_peak.confidence)
    push!(harmonics, h1)
    
    # Find the fundamental peak index to mark as used
    for (idx, p) in enumerate(peaks)
        if p.frequency == fundamental_peak.frequency && p.bin == fundamental_peak.bin
            push!(used_peaks, idx)
            break
        end
    end
    
    consecutive_missing = 0
    
    for h_num in 2:tracker.max_harmonics
        expected_freq = f0 * h_num
        
        # Stop if expected frequency exceeds max detectable or configured max
        if expected_freq > 20000.0f0 || expected_freq > tracker.max_fundamental * tracker.max_harmonics
            break
        end
        
        tol = _harmonic_tolerance_hz(f0, h_num, tracker)
        
        # Find best match
        matched_idx, matched_peak = _find_harmonic_match(expected_freq, peaks, used_peaks, tracker)
        
        if matched_peak !== nothing && abs(matched_peak.frequency - expected_freq) <= tol
            # Found a match
            deviation = matched_peak.frequency - expected_freq
            h = Harmonic(h_num, matched_peak.frequency, matched_peak.magnitude,
                        matched_peak.bin, deviation, matched_peak.confidence)
            push!(harmonics, h)
            push!(used_peaks, matched_idx)
            consecutive_missing = 0
        else
            # Missing harmonic
            consecutive_missing += 1
            
            if !tracker.allow_missing_harmonics || consecutive_missing > tracker.max_missing_harmonics
                break
            end
        end
    end
    
    # Check if we have enough harmonics
    if length(harmonics) < tracker.min_harmonics
        return nothing
    end
    
    # Calculate overall confidence
    # Weighted average of harmonic confidences, with more weight on lower harmonics
    total_weight = 0.0f0
    weighted_conf = 0.0f0
    for h in harmonics
        weight = 1.0f0 / h.number  # Lower harmonics are more important
        weighted_conf += weight * h.confidence
        total_weight += weight
    end
    overall_conf = total_weight > 0 ? weighted_conf / total_weight : 0.0f0
    
    # Calculate inharmonicity
    # Average absolute deviation normalized by fundamental
    total_dev = 0.0f0
    for h in harmonics
        if h.number > 1
            total_dev += abs(h.deviation)
        end
    end
    n_harm = max(1, length(harmonics) - 1)
    inharm = total_dev / (n_harm * f0)
    
    return HarmonicSeries(f0, harmonics, overall_conf, inharm, frame_id)
end

"""Score a harmonic series for ranking.

Higher score = better series. Based on:
- Total magnitude of all harmonics (strong signal is better)
- Number of harmonics (more is better, with diminishing returns)
- Overall confidence
- Low inharmonicity
- Prefer lower fundamentals (pitch perception favors the root)"""
function _score_series(series::HarmonicSeries)::Float32
    n = length(series.harmonics)
    
    # Primary score: total magnitude of all harmonics
    # This strongly favors series that explain strong peaks
    total_mag = sum(h.magnitude for h in series.harmonics)
    
    # Count bonus (diminishing returns for many harmonics)
    count_bonus = sqrt(Float32(n))
    
    # Confidence factor
    conf_factor = series.overall_confidence
    
    # Inharmonicity penalty (lower is better, so invert)
    inharm_factor = 1.0f0 / (1.0f0 + 10.0f0 * series.inharmonicity)
    
    # Slight preference for lower fundamentals (common in pitch perception)
    # This helps when a higher partial could be mistaken for the fundamental
    f0_penalty = sqrt(1000.0f0 / max(series.fundamental, 50.0f0))
    
    return total_mag * count_bonus * conf_factor * inharm_factor * f0_penalty
end

"""Filter out overlapping series, keeping the best-scoring ones.

Two series overlap if they share any harmonics (within tolerance)."""
function _filter_overlapping_series(series_list::Vector{HarmonicSeries},
                                     tracker::HarmonicTracker)::Vector{HarmonicSeries}
    if isempty(series_list)
        return series_list
    end
    
    # Sort by score (best first)
    scored = [(s, _score_series(s)) for s in series_list]
    sort!(scored, by=x -> x[2], rev=true)
    
    kept = HarmonicSeries[]
    used_freqs = Set{Float32}()
    
    for (series, score) in scored
        # Check if any harmonic frequency is already used
        overlap = false
        for h in series.harmonics
            for used_f in used_freqs
                if abs(h.frequency - used_f) <= tracker.freq_tolerance_hz
                    overlap = true
                    break
                end
            end
            if overlap
                break
            end
        end
        
        if !overlap
            push!(kept, series)
            for h in series.harmonics
                push!(used_freqs, h.frequency)
            end
        end
    end
    
    return kept
end

# ------------------------------------------------------------------------------
# Main Detection API
# ------------------------------------------------------------------------------

"""Find harmonic series in a set of detected peaks.

This is the main entry point for harmonic analysis. It:
1. Takes detected peaks from Phase 5
2. For each strong peak, tries to build a harmonic series
3. Scores and filters overlapping series
4. Returns non-overlapping harmonic series sorted by score

Parameters:
- tracker: HarmonicTracker configuration
- peaks: Vector of Peak structs from detect_peaks!
- frame_id: Optional frame identifier (uses tracker's counter if not provided)

Returns: Vector of HarmonicSeries, sorted by quality (best first)."""
function find_harmonic_series!(tracker::HarmonicTracker, peaks::Vector{Peak};
                                frame_id::Union{Int, Nothing}=nothing)::Vector{HarmonicSeries}
    # Increment frame counter
    tracker.frame_counter += 1
    current_frame = frame_id !== nothing ? frame_id : tracker.frame_counter
    
    # Filter peaks by confidence
    valid_peaks = filter(p -> p.confidence >= tracker.min_confidence, peaks)
    
    if isempty(valid_peaks)
        return HarmonicSeries[]
    end
    
    # Sort peaks by magnitude (strongest first) - better fundamentals first
    sorted_peaks = sort(valid_peaks, by=p -> p.magnitude, rev=true)
    
    # Try each peak as a candidate fundamental
    candidates = HarmonicSeries[]
    
    for peak in sorted_peaks
        series = _build_series_from_fundamental(peak, valid_peaks, tracker, current_frame)
        
        if series !== nothing
            push!(candidates, series)
        end
    end
    
    # Filter overlapping series (keep best)
    series_list = _filter_overlapping_series(candidates, tracker)
    
    # Assign series IDs for tracking
    for series in series_list
        # Try to match with existing tracked series
        matched = false
        for tracked in tracker.tracked_series
            if abs(series.fundamental - tracked.fundamental) <= tracker.freq_tolerance_hz * 2
                # Match found - inherit ID
                series = HarmonicSeries(series.fundamental, series.harmonics,
                                       series.overall_confidence, series.inharmonicity,
                                       series.frame_id, tracked.series_id)
                matched = true
                break
            end
        end
        
        if !matched
            # New series - assign new ID
            series = HarmonicSeries(series.fundamental, series.harmonics,
                                   series.overall_confidence, series.inharmonicity,
                                   series.frame_id, tracker.next_series_id)
            tracker.next_series_id += 1
        end
    end
    
    # Store in history
    tracker.series_history[current_frame] = series_list
    
    return series_list
end

"""Find harmonic series from peaks without a tracker (stateless).

Convenience function that creates a temporary tracker."""
function find_harmonic_series(peaks::Vector{Peak};
                               max_harmonics::Int=10,
                               harmonic_tolerance::Real=0.03,
                               min_harmonics::Int=2,
                               min_fundamental::Real=20.0,
                               max_fundamental::Real=4000.0,
                               min_confidence::Real=0.3)::Vector{HarmonicSeries}
    tracker = HarmonicTracker(
        max_harmonics=max_harmonics,
        harmonic_tolerance=harmonic_tolerance,
        min_harmonics=min_harmonics,
        min_fundamental=min_fundamental,
        max_fundamental=max_fundamental,
        min_confidence=min_confidence
    )
    return find_harmonic_series!(tracker, peaks)
end

"""Find harmonic series directly from an FFTEngine.

Detects peaks first, then finds harmonic series."""
function find_harmonic_series!(tracker::HarmonicTracker, detector::PeakDetector,
                                engine::FFTEngine)::Vector{HarmonicSeries}
    peaks = detect_peaks!(detector, engine)
    return find_harmonic_series!(tracker, peaks)
end

# ------------------------------------------------------------------------------
# Temporal Tracking
# ------------------------------------------------------------------------------

"""Track harmonic series across frames by matching fundamentals.

Matches current series to previously tracked series within frequency tolerance.
Only returns series that have persisted for at least track_persistence frames.

Parameters:
- tracker: HarmonicTracker with tracked_series populated
- current_series: Series detected in current frame
- freq_tolerance: Maximum frequency difference for match in Hz

Returns: Vector of tracked series that meet persistence requirements."""
function track_harmonics!(tracker::HarmonicTracker,
                           current_series::Vector{HarmonicSeries};
                           freq_tolerance::Union{Real, Nothing}=nothing)::Vector{HarmonicSeries}
    tol = freq_tolerance !== nothing ? Float32(freq_tolerance) : tracker.freq_tolerance_hz * 2
    
    # Match current series to tracked series
    matched_ids = Set{Int}()
    new_tracked = HarmonicSeries[]
    
    for series in current_series
        matched = false
        
        for tracked in tracker.tracked_series
            if tracked.series_id in matched_ids
                continue
            end
            
            if abs(series.fundamental - tracked.fundamental) < tol
                # Match found - update tracked series
                push!(matched_ids, tracked.series_id)
                
                # Use the new detection but keep the series ID
                updated = HarmonicSeries(series.fundamental, series.harmonics,
                                        series.overall_confidence, series.inharmonicity,
                                        series.frame_id, tracked.series_id)
                push!(new_tracked, updated)
                matched = true
                break
            end
        end
        
        if !matched
            # New series - assign a new ID
            new_id = tracker.next_series_id
            tracker.next_series_id += 1
            new_series = HarmonicSeries(series.fundamental, series.harmonics,
                                       series.overall_confidence, series.inharmonicity,
                                       series.frame_id, new_id)
            push!(new_tracked, new_series)
        end
    end
    
    # Update tracked series
    tracker.tracked_series = new_tracked
    
    # Filter by persistence if needed
    if tracker.track_persistence > 1
        # Count occurrences in recent history
        persistent = HarmonicSeries[]
        
        for series in new_tracked
            count = 0
            for frame in max(1, tracker.frame_counter - tracker.track_persistence + 1):tracker.frame_counter
                if haskey(tracker.series_history, frame)
                    for hist_series in tracker.series_history[frame]
                        if hist_series.series_id == series.series_id
                            count += 1
                            break
                        end
                    end
                end
            end
            
            if count >= tracker.track_persistence
                push!(persistent, series)
            end
        end
        
        return persistent
    end
    
    return new_tracked
end

"""Reset the harmonic tracker's state."""
function reset!(tracker::HarmonicTracker)
    tracker.frame_counter = 0
    tracker.next_series_id = 1
    tracker.tracked_series = HarmonicSeries[]
    tracker.series_history = Dict{Int, Vector{HarmonicSeries}}()
    return tracker
end

# ------------------------------------------------------------------------------
# Convenience Functions
# ------------------------------------------------------------------------------

"""Get the number of harmonics in a series."""
function harmonic_count(series::HarmonicSeries)::Int
    return length(series.harmonics)
end

"""Get the frequencies of all harmonics in a series."""
function harmonic_frequencies(series::HarmonicSeries)::Vector{Float32}
    return [h.frequency for h in series.harmonics]
end

"""Get the magnitudes of all harmonics in a series."""
function harmonic_magnitudes(series::HarmonicSeries)::Vector{Float32}
    return [h.magnitude for h in series.harmonics]
end

"""Get the harmonic numbers (1 = fundamental, 2 = 2nd, etc.)."""
function harmonic_numbers(series::HarmonicSeries)::Vector{Int}
    return [h.number for h in series.harmonics]
end

"""Get the fundamental frequency (f0) of a series."""
function fundamental_frequency(series::HarmonicSeries)::Float32
    return series.fundamental
end

"""Get the fundamental magnitude (strength of f0)."""
function fundamental_magnitude(series::HarmonicSeries)::Float32
    if isempty(series.harmonics)
        return 0.0f0
    end
    return series.harmonics[1].magnitude
end

"""Calculate the average deviation from ideal harmonic frequencies."""
function average_deviation(series::HarmonicSeries)::Float32
    if length(series.harmonics) <= 1
        return 0.0f0
    end
    
    total_dev = sum(abs(h.deviation) for h in series.harmonics if h.number > 1)
    n = max(1, length(series.harmonics) - 1)
    return total_dev / n
end

"""Get the overall confidence of a harmonic series."""
function overall_confidence(series::HarmonicSeries)::Float32
    return series.overall_confidence
end

"""Get the inharmonicity measure (0.0 = perfectly harmonic)."""
function inharmonicity(series::HarmonicSeries)::Float32
    return series.inharmonicity
end

"""Check if a series has at least N harmonics."""
function has_min_harmonics(series::HarmonicSeries, n::Int)::Bool
    return length(series.harmonics) >= n
end

"""Get the number of detected series."""
function num_series(series_list::Vector{HarmonicSeries})::Int
    return length(series_list)
end

"""Check if any harmonic series were detected."""
function has_series(series_list::Vector{HarmonicSeries})::Bool
    return !isempty(series_list)
end

"""Get the strongest series (highest overall confidence)."""
function strongest_series(series_list::Vector{HarmonicSeries})::Union{HarmonicSeries, Nothing}
    if isempty(series_list)
        return nothing
    end
    
    return argmax(s -> s.overall_confidence, series_list)
end

"""Filter series by minimum number of harmonics."""
function filter_by_harmonic_count(series_list::Vector{HarmonicSeries}, min_count::Int)::Vector{HarmonicSeries}
    return filter(s -> length(s.harmonics) >= min_count, series_list)
end

"""Filter series by maximum inharmonicity."""
function filter_by_inharmonicity(series_list::Vector{HarmonicSeries}, max_inharm::Real)::Vector{HarmonicSeries}
    return filter(s -> s.inharmonicity <= max_inharm, series_list)
end

"""Filter series by minimum confidence."""
function filter_by_confidence(series_list::Vector{HarmonicSeries}, min_conf::Real)::Vector{HarmonicSeries}
    return filter(s -> s.overall_confidence >= min_conf, series_list)
end

"""Filter series to a fundamental frequency range."""
function filter_by_fundamental(series_list::Vector{HarmonicSeries},
                                min_f0::Real, max_f0::Real)::Vector{HarmonicSeries}
    return filter(s -> s.fundamental >= min_f0 && s.fundamental <= max_f0, series_list)
end

"""Get the series with the most harmonics."""
function richest_series(series_list::Vector{HarmonicSeries})::Union{HarmonicSeries, Nothing}
    if isempty(series_list)
        return nothing
    end
    
    return argmax(s -> length(s.harmonics), series_list)
end

# ------------------------------------------------------------------------------
# Note / Pitch Conversion
# ------------------------------------------------------------------------------

"""Convert frequency to MIDI note number.

A4 (440 Hz) = MIDI note 69."""
function freq_to_midi(freq::Real)::Float32
    if freq <= 0
        return 0.0f0
    end
    return 69.0f0 + 12.0f0 * log2(Float32(freq) / 440.0f0)
end

"""Convert MIDI note number to frequency."""
function midi_to_freq(midi_note::Real)::Float32
    return 440.0f0 * 2.0f0 ^ ((Float32(midi_note) - 69.0f0) / 12.0f0)
end

"""Convert frequency to note name (e.g., "A4", "C#5").

Returns (note_name, cents_deviation) where cents_deviation is how far
from the equal-tempered note the frequency is."""
function freq_to_note(freq::Real)::Tuple{String, Float32}
    if freq <= 0
        return ("N/A", 0.0f0)
    end
    
    midi = freq_to_midi(freq)
    midi_rounded = round(Int, midi)
    cents = (midi - midi_rounded) * 100.0f0
    
    note_names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    octave = div(midi_rounded, 12) - 1
    note_idx = mod(midi_rounded, 12) + 1
    
    note_name = note_names[note_idx] * string(octave)
    
    return (note_name, cents)
end

"""Get the estimated musical note for a harmonic series.

Returns (note_name, cents_deviation, midi_note)."""
function note_estimate(series::HarmonicSeries)::Tuple{String, Float32, Float32}
    midi = freq_to_midi(series.fundamental)
    note_name, cents = freq_to_note(series.fundamental)
    return (note_name, cents, midi)
end

# ------------------------------------------------------------------------------
# Display / Utility
# ------------------------------------------------------------------------------

"""Print a summary of detected harmonic series."""
function print_series(series_list::Vector{HarmonicSeries}; max_display::Int=5)
    n = length(series_list)
    println("Detected $n harmonic series:")
    println()
    
    display_count = min(n, max_display)
    
    for i in 1:display_count
        series = series_list[i]
        note_name, cents, midi = note_estimate(series)
        
        println("  Series $i (ID=$(series.series_id)):")
        println("    Fundamental: $(round(series.fundamental, digits=2)) Hz ",
                "(Note: $note_name, MIDI=$(round(midi, digits=2)), ",
                "deviation=$(round(cents, digits=1)) cents)")
        println("    Confidence: $(round(series.overall_confidence, digits=3)), ",
                "Inharmonicity: $(round(series.inharmonicity, digits=5))")
        println("    Harmonics: $(length(series.harmonics))")
        
        for h in series.harmonics
            println("      H$(h.number): $(round(h.frequency, digits=2)) Hz ",
                    "(mag=$(round(h.magnitude, digits=3)), ",
                    "dev=$(round(h.deviation, digits=2)) Hz)")
        end
        println()
    end
    
    if n > max_display
        println("  ... and $(n - max_display) more series")
    end
end

"""Convert harmonic series to a matrix for easy inspection.
Columns: fundamental, n_harmonics, overall_confidence, inharmonicity"""
function series_to_matrix(series_list::Vector{HarmonicSeries})::Matrix{Float32}
    n = length(series_list)
    mat = Matrix{Float32}(undef, n, 4)
    
    @inbounds for i in 1:n
        s = series_list[i]
        mat[i, 1] = s.fundamental
        mat[i, 2] = Float32(length(s.harmonics))
        mat[i, 3] = s.overall_confidence
        mat[i, 4] = s.inharmonicity
    end
    
    return mat
end

# ------------------------------------------------------------------------------
# Integration with PeakDetector
# ------------------------------------------------------------------------------

"""One-shot harmonic series detection from an FFTEngine.

Detects peaks, then finds harmonic series. Returns the detected series.

Parameters:
- engine: FFTEngine with computed FFT
- peak_kwargs: Keyword arguments passed to PeakDetector
- harmonic_kwargs: Keyword arguments passed to HarmonicTracker

Returns: Vector of HarmonicSeries."""
function detect_harmonics(engine::FFTEngine;
                           peak_kwargs::Dict=Dict{Symbol, Any}(),
                           harmonic_kwargs::Dict=Dict{Symbol, Any}())::Vector{HarmonicSeries}
    # Create detector with user overrides
    detector = PeakDetector()
    for (k, v) in peak_kwargs
        if k == :min_height
            detector.min_height = Float32(v)
        elseif k == :snr_threshold
            detector.snr_threshold = Float32(v)
        elseif k == :min_peak_distance
            detector.min_peak_distance = Float32(v)
        elseif k == :min_freq
            detector.min_freq = Float32(v)
        elseif k == :max_freq
            detector.max_freq = Float32(v)
        elseif k == :max_peaks
            detector.max_peaks = v
        elseif k == :use_interpolation
            detector.use_interpolation = v
        end
    end
    
    # Detect peaks
    peaks = detect_peaks!(detector, engine)
    
    # Find harmonic series
    tracker = HarmonicTracker()
    for (k, v) in harmonic_kwargs
        if k == :max_harmonics
            tracker.max_harmonics = v
        elseif k == :harmonic_tolerance
            tracker.harmonic_tolerance = Float32(v)
        elseif k == :min_harmonics
            tracker.min_harmonics = v
        elseif k == :min_fundamental
            tracker.min_fundamental = Float32(v)
        elseif k == :max_fundamental
            tracker.max_fundamental = Float32(v)
        elseif k == :min_confidence
            tracker.min_confidence = Float32(v)
        end
    end
    
    return find_harmonic_series!(tracker, peaks)
end
