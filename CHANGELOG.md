# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-10

### Added
- Phase 1: Real-time audio capture via PortAudio with thread-safe ring buffers.
- Phase 2: FFT engine using FFTW with configurable window functions (Hann, Hamming, Blackman, rectangular).
- Phase 3: Real-time spectrum display powered by GLMakie with configurable views.
- Phase 4: Waterfall / spectrogram time-frequency heatmap visualization.
- Phase 5: Peak detection algorithm with prominence and smoothing parameters.
- Phase 6: Harmonic series tracking to identify musical notes and fundamentals.
- Phase 7: MIDI export of detected notes with timing, velocity, and note names.
- Phase 8: CV (control voltage) output generation via audio interface DC coupling for modular synthesizers.
- Comprehensive test suite covering all 8 phases.
- Initial documentation in README.md and architecture notes in PLAN.md.

[1.0.0]: https://github.com/synth/tracking/releases/tag/v1.0.0
