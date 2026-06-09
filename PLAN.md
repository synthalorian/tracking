# tracking — Implementation Plan

## Project Overview

Real-time audio spectrum analyzer with waterfall displays, peak detection, and export to MIDI/CV. Jack/PipeWire native.

**Language:** Julia  
**Constraint:** Do a lot of math  
**Stack:** FFTW, GLMakie, PortAudio, MIDI.jl

---

## Phase Breakdown

### Phase 1: Audio capture (PortAudio + RingBuffer)

**Goal:** Phase 1: Audio capture (PortAudio + RingBuffer)

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented thread-safe `RingBuffer{T}` with overwrite mode for real-time audio streaming
- Implemented `AudioCapture` struct wrapping PortAudio with async capture to ringbuffer
- Supports mono/stereo capture with automatic downmix
- 41 tests passing covering basic ops, batch ops, wraparound, thread safety, and error handling 

---

### Phase 2: FFT engine (FFTW) with windowing

**Goal:** Phase 2: FFT engine (FFTW) with windowing

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented `FFTEngine` with FFTW real FFT, Hann/Hamming/Blackman windowing
- Window power and amplitude correction factors
- Frequency bin utilities, peak detection helpers
- 20+ tests passing

---

### Phase 3: Real-time spectrum display (GLMakie)

**Goal:** Phase 3: Real-time spectrum display (GLMakie)

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented `SpectrumDisplay` with real-time GLMakie plotting
- Log/linear frequency scales, dB/linear magnitude scales
- Peak hold with decay, configurable display limits
- 15+ tests passing

---

### Phase 4: Waterfall / spectrogram view

**Goal:** Phase 4: Audio capture + FFT integration (live display loop)

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented `WaterfallDisplay` with real-time spectrogram heatmap using GLMakie
- Live display loop integrates AudioCapture → RingBuffer → FFTEngine → SpectrumDisplay + WaterfallDisplay
- Supports both demo mode (synthetic signal) and live microphone input
- Frame history buffer for time-frequency visualization
- Start/stop lifecycle for async update tasks 

---

### Phase 5: Peak detection algorithm

**Goal:** Phase 5: Peak detection algorithm

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented `Peak` struct with sub-bin frequency, magnitude, SNR, confidence
- `PeakDetector` with configurable SNR threshold, min peak distance, frequency range
- Parabolic interpolation for sub-bin frequency accuracy (~0.1-1 Hz precision)
- Noise floor estimation using percentile-based robust estimator
- Temporal peak tracking across frames for stability
- Convenience functions: `detect_peaks`, `find_peak`, `track_peaks!`, filtering helpers
- 20+ tests covering interpolation accuracy, SNR thresholding, peak spacing, tracking

---

### Phase 6: Harmonic series tracking

**Goal:** Phase 6: Harmonic series tracking

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented `Harmonic` and `HarmonicSeries` structs for representing detected harmonic families
- `HarmonicTracker` with configurable tolerance, min harmonics, missing harmonic handling
- Scoring algorithm prefers lower fundamentals that explain strong peaks (pitch perception model)
- Overlapping series filtering keeps best non-overlapping sets
- Temporal tracking with persistent series IDs across frames
- Note/pitch conversion: `freq_to_midi`, `midi_to_freq`, `freq_to_note`, `note_estimate`
- Integration with `PeakDetector` and `FFTEngine`
- 124 tests covering perfect harmonics, multiple series, missing harmonics, inharmonicity, temporal tracking

---

### Phase 7: MIDI export of detected notes

**Goal:** Phase 7: MIDI export of detected notes

**Deliverables:**
- [x] Core implementation
- [x] Tests
- [x] Documentation update

**Notes:**
- Implemented lightweight binary SMF (Standard MIDI File) writer from scratch (no external MIDI library dependency)
- `MIDINote` struct with pitch, velocity, start time, duration, channel
- `MIDIExporter` with configurable ticks-per-quarter, tempo, velocity mapping, note duration
- `series_to_note` converts `HarmonicSeries` to `MIDINote` with confidence-derived velocity
- `export_midi` writes Format 0/1 MIDI files with proper delta-time encoding
- `validate_midi` and `midi_info` for file verification
- Full integration with `HarmonicSeries`, `PeakDetector`, and `FFTEngine` pipeline
- 25+ tests covering note generation, file export, validation, and integration 

---

### Phase 8: CV output via audio interface DC coupling

**Goal:** Phase 8: CV output via audio interface DC coupling

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

## Architecture Notes

### Key Decisions

- 

### Data Flow

```
[Input] → [Parse] → [Transform] → [Output]
```

### Error Handling Strategy

- 

---

## Testing Strategy

- Unit tests for core functions
- Integration tests for full pipeline
- Benchmarks for performance-critical paths

---

## Open Questions

1. 
2. 

---

*Generated for opencode sprint. Implement phase by phase. DO NOT RESEARCH. Build directly.*
