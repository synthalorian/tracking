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
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 3: Real-time spectrum display (GLMakie)

**Goal:** Phase 3: Real-time spectrum display (GLMakie)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 4: Waterfall / spectrogram view

**Goal:** Phase 4: Waterfall / spectrogram view

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 5: Peak detection algorithm

**Goal:** Phase 5: Peak detection algorithm

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 6: Harmonic series tracking

**Goal:** Phase 6: Harmonic series tracking

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 7: MIDI export of detected notes

**Goal:** Phase 7: MIDI export of detected notes

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

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
