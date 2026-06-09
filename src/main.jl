include("Tracking.jl")
using .Tracking

# Main entry point - Phase 3: Real-time spectrum display demo
function main()
    println("Tracking - Real-time Audio Spectrum Analyzer")
    println("Phase 3: Real-time Spectrum Display (GLMakie)")
    println()
    
    # Create FFT engine
    nfft = 2048
    sr = 44100
    engine = FFTEngine(nfft, sr)
    println("Created: $engine")
    println()
    
    # Generate a synthetic test signal with multiple frequencies
    println("Generating test signal...")
    freq1 = 440.0   # A4
    freq2 = 880.0   # A5
    freq3 = 1760.0  # A6
    freq4 = 3520.0  # A7
    
    t = [i / sr for i in 0:(nfft - 1)]
    samples = Float32[
        0.5 * sin(2π * freq1 * ti) +
        0.3 * sin(2π * freq2 * ti) +
        0.2 * sin(2π * freq3 * ti) +
        0.1 * sin(2π * freq4 * ti)
        for ti in t
    ]
    
    # Create spectrum display
    println("Creating spectrum display...")
    config = DisplayConfig(
        freq_scale=LogScale(),
        mag_scale=DecibelMagnitude(),
        min_freq=20.0,
        max_freq=20000.0,
        db_range=80.0,
        peak_hold=true,
        refresh_rate=30.0,
        title="Tracking Spectrum Analyzer - Phase 3"
    )
    display = SpectrumDisplay(config, engine=engine)
    println("Created: $display")
    println()
    
    # Process the test signal
    process!(engine, samples)
    
    # Update display with the spectrum
    update!(display, engine)
    
    # Show the figure (non-blocking in GLMakie)
    display_figure(display)
    
    println("Displaying spectrum...")
    println("Frequencies: $(round(freq1)) Hz, $(round(freq2)) Hz, $(round(freq3)) Hz, $(round(freq4)) Hz")
    
    # Find and display peaks
    bin_idx, peak_freq, peak_mag = find_peak_bin(engine)
    println("Dominant peak: $(round(peak_freq, digits=1)) Hz (bin $bin_idx)")
    
    peaks = find_peaks(engine; min_height=5.0f0)
    println("Found $(length(peaks)) peaks above threshold")
    for (b, f, m) in peaks
        println("  $(round(f, digits=1)) Hz: magnitude $(round(m, digits=2))")
    end
    
    println()
    println("Phase 3 complete!")
    println("The spectrum window should be visible.")
    println("Close the window or press Ctrl+C to exit.")
    
    # Keep the window open
    try
        while true
            sleep(1.0)
        end
    catch e
        if isa(e, InterruptException)
            println("\nShutting down...")
        end
    end
end

main()
