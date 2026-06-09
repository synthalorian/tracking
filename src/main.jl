include("Tracking.jl")
using .Tracking

"""
    main(; demo::Bool=true)

Main entry point for Phase 4: Live Audio Spectrum Analyzer

Demonstrates the complete pipeline:
- Audio capture (PortAudio + RingBuffer)
- FFT processing (FFTW with windowing)
- Real-time spectrum display (GLMakie)
- Waterfall / spectrogram view (GLMakie)

Parameters:
- demo: If true (default), uses a synthetic test signal instead of microphone.
        Set to false to use live audio input.
"""
function main(; demo::Bool=true)
    println("=" ^ 60)
    println("Tracking - Real-time Audio Spectrum Analyzer")
    println("Phase 4: Audio capture + FFT integration (live display loop)")
    println("=" ^ 60)
    println()
    
    # Configuration
    nfft = 2048
    sr = 44100
    buffer_size = 1024
    ringbuffer_capacity = sr * 2  # 2 seconds of audio
    
    # Create FFT engine
    engine = FFTEngine(nfft, sr; window_type=HannWindow())
    println("FFT Engine: $engine")
    println()
    
    if demo
        println("DEMO MODE: Using synthetic test signal")
        println("Set demo=false for live microphone input")
        println()
        
        # Create ringbuffer and populate with test signal
        rb = RingBuffer{Float32}(ringbuffer_capacity)
        
        # Generate a multi-frequency test signal
        freq1 = 440.0   # A4
        freq2 = 880.0   # A5
        freq3 = 1760.0  # A6
        freq4 = 3520.0  # A7
        
        println("Test signal frequencies:")
        println("  $(round(freq1)) Hz (A4)")
        println("  $(round(freq2)) Hz (A5)")
        println("  $(round(freq3)) Hz (A6)")
        println("  $(round(freq4)) Hz (A7)")
        println()
        
        # Generate continuous test signal
        t = [i / sr for i in 0:(ringbuffer_capacity - 1)]
        samples = Float32[
            0.5 * sin(2π * freq1 * ti) +
            0.3 * sin(2π * freq2 * ti) +
            0.2 * sin(2π * freq3 * ti) +
            0.1 * sin(2π * freq4 * ti)
            for ti in t
        ]
        overwrite!(rb, samples)
        
        # Create a mock AudioCapture that points to our ringbuffer
        # We'll manually feed samples into the ringbuffer to simulate live input
        println("Simulating live audio stream...")
        println()
        
        # Create displays
        spectrum_config = DisplayConfig(
            freq_scale=LogScale(),
            mag_scale=DecibelMagnitude(),
            min_freq=20.0,
            max_freq=20000.0,
            db_range=80.0,
            peak_hold=true,
            peak_decay=20.0,
            refresh_rate=30.0,
            title="Tracking Spectrum Analyzer - Phase 4"
        )
        
        spectrum_display = SpectrumDisplay(spectrum_config, engine=engine)
        println("Spectrum display ready")
        
        waterfall_display = WaterfallDisplay(engine, time_history=100)
        println("Waterfall display ready")
        println()
        
        # Start displays in manual mode (we'll feed them data)
        start!(spectrum_display)
        start!(waterfall_display)
        
        # Simulate live update loop
        println("Running live display loop...")
        println("Close the windows or press Ctrl+C to stop")
        println()
        
        frame = 0
        phase = 0.0
        
        try
            while true
                # Simulate changing signal by shifting phase
                phase += 0.01
                frame += 1
                
                # Generate new samples with slight modulation
                t_frame = [i / sr for i in 0:(buffer_size - 1)]
                modulated_samples = Float32[
                    0.5 * sin(2π * freq1 * ti + phase) +
                    0.3 * sin(2π * freq2 * ti + phase * 1.5) +
                    0.2 * sin(2π * freq3 * ti + phase * 2.0) +
                    0.1 * sin(2π * freq4 * ti + phase * 2.5)
                    for ti in t_frame
                ]
                
                # Push to ringbuffer (simulating live capture)
                overwrite!(rb, modulated_samples)
                
                # Process FFT from ringbuffer
                if length(rb) >= nfft
                    process!(engine, rb)
                    
                    # Update both displays
                    update!(spectrum_display, engine)
                    update!(waterfall_display, engine)
                end
                
                # Target ~30 fps
                sleep(1.0 / 30.0)
            end
        catch e
            if isa(e, InterruptException)
                println("\nShutting down...")
            else
                rethrow(e)
            end
        end
        
        # Stop displays
        stop!(spectrum_display)
        stop!(waterfall_display)
        
    else
        # LIVE MODE: Use actual microphone input
        println("LIVE MODE: Capturing from microphone")
        println()
        
        # Create ringbuffer for audio
        rb = RingBuffer{Float32}(ringbuffer_capacity)
        
        # Create audio capture
        println("Initializing audio capture...")
        capture = AudioCapture(rb; sample_rate=sr, channels=1, buffer_size=buffer_size)
        println("Audio device: $(capture.stream.source)")
        println()
        
        # Create displays
        spectrum_config = DisplayConfig(
            freq_scale=LogScale(),
            mag_scale=DecibelMagnitude(),
            min_freq=20.0,
            max_freq=20000.0,
            db_range=80.0,
            peak_hold=true,
            peak_decay=20.0,
            refresh_rate=30.0,
            title="Tracking Spectrum Analyzer - Live"
        )
        
        spectrum_display = SpectrumDisplay(spectrum_config, engine=engine)
        println("Spectrum display ready")
        
        waterfall_display = WaterfallDisplay(engine, time_history=100)
        println("Waterfall display ready")
        println()
        
        # Start audio capture
        println("Starting audio capture...")
        start!(capture)
        println("Capture running: $(isrunning(capture))")
        println()
        
        # Start display loops
        println("Starting display loops...")
        start!(spectrum_display, capture, engine)
        start!(waterfall_display, capture, engine)
        println()
        
        println("Running! Speak, play music, or make noise.")
        println("Close the windows or press Ctrl+C to stop")
        println()
        
        # Keep running until interrupted
        try
            while isrunning(spectrum_display) || isrunning(waterfall_display)
                sleep(1.0)
            end
        catch e
            if isa(e, InterruptException)
                println("\nShutting down...")
            else
                rethrow(e)
            end
        end
        
        # Cleanup
        println("Stopping audio capture...")
        stop!(capture)
        close(capture)
        
        println("Stopping displays...")
        stop!(spectrum_display)
        stop!(waterfall_display)
    end
    
    println()
    println("Phase 4 complete!")
    println("Live display loop terminated successfully.")
end

# Run with demo mode by default
# Use `main(demo=false)` for live microphone input
main(demo=true)
