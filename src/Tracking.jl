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

# Phase 6: Harmonic series tracking
include("harmonic.jl")

# Phase 7: MIDI export of detected notes
include("midi.jl")

# Phase 8: CV output via audio interface DC coupling
include("cv.jl")

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

# Phase 6 exports
export Harmonic, HarmonicSeries, HarmonicTracker
export find_harmonic_series!, find_harmonic_series
export track_harmonics!, reset!
export harmonic_count, harmonic_frequencies, harmonic_magnitudes
export harmonic_numbers, fundamental_frequency, fundamental_magnitude
export average_deviation, overall_confidence, inharmonicity
export has_min_harmonics, num_series, has_series
export strongest_series, richest_series
export filter_by_harmonic_count, filter_by_inharmonicity
export filter_by_confidence, filter_by_fundamental
export freq_to_midi, midi_to_freq, freq_to_note, note_estimate
export print_series, series_to_matrix, detect_harmonics

# Phase 7 exports
export MIDINote, MIDIExporter
export series_to_note, series_to_notes, freq_to_note
export export_midi, export_frequencies
export note_names, tempo_to_bpm, set_bpm!
export note_count, pitch_range, notes_to_matrix
export print_notes, validate_midi, midi_info

# Phase 8 exports
export CVOutput, CVOutputConfig, CVChannelConfig, CVSignalState
export CVChannelType, PitchCV, GateCV, TriggerCV, VelocityCV, ModulationCV
export VoltageRange, BIPOLAR_5V, BIPOLAR_10V, UNIPOLAR_10V, UNIPOLAR_5V
export start!, stop!, isrunning, reset!
export set_pitch!, set_midi_pitch!, set_gate!, set_velocity!
export output_series!, output_peak!, output_series_list!
export release_gates!, trigger!
export generate_samples, generate_pitch_cv, generate_gate_cv, generate_trigger_cv
export generate_ramp
export midi_to_voltage, freq_to_voltage, voltage_to_sample, sample_to_voltage
export voltage_to_midi, voltage_to_freq, clamp_voltage
export current_voltage, current_voltages, gate_active
export series_to_cv, peak_to_cv
export eurorack_config, test_cv_config
export print_cv_state

end # module
