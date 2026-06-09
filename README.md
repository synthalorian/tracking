# tracking

> Real-time audio spectrum analyzer with waterfall displays, peak detection, and export to MIDI/CV. Jack/PipeWire native.

**Language:** Julia  
**Constraint:** Do a lot of math  
**Stack:** FFTW, GLMakie, PortAudio, MIDI.jl

---

## Features

- Real-time FFT spectrum analysis
- Waterfall display (time vs frequency heatmap)
- Peak detection and harmonic tracking
- Export detected peaks to MIDI
- CV (control voltage) output for modular synths
- Jack and PipeWire native backends
- Oscilloscope and spectrogram views

---

## Development Plan

1. Phase 1: Audio capture (PortAudio + RingBuffer)
2. Phase 2: FFT engine (FFTW) with windowing
3. Phase 3: Real-time spectrum display (GLMakie)
4. Phase 4: Waterfall / spectrogram view
5. Phase 5: Peak detection algorithm
6. Phase 6: Harmonic series tracking
7. Phase 7: MIDI export of detected notes
8. Phase 8: CV output via audio interface DC coupling

---

## Getting Started

### Prerequisites

- Julia toolchain

### Build

```bash
# See PLAN.md for detailed build instructions per phase
cd tracking
```

### Run

```bash
# See PLAN.md for run instructions
```

---

## Architecture

See `PLAN.md` for detailed architecture decisions and implementation notes.

---

## License

MIT
