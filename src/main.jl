include("Tracking.jl")
using .Tracking

# Main entry point - Phase 2 FFT engine demo
function main()
    println("Tracking - Real-time Audio Spectrum Analyzer")
    println("Phase 2: FFT Engine with Windowing")
    println()
    
    # Create an FFT engine
    engine = FFTEngine(1024, 44100)
    println("Created: $engine")
    
    # Generate a test signal with multiple frequencies
    sr = 44100
    freq1 = 440.0   # A4
    freq2 = 880.0   # A5
    freq3 = 1760.0  # A6
    
    t = [i / sr for i in 0:1023]
    samples = Float32[
        0.5 * sin(2π * freq1 * ti) +
        0.3 * sin(2π * freq2 * ti) +
        0.2 * sin(2π * freq3 * ti)
        for ti in t
    ]
    
    # Process through FFT engine
    process!(engine, samples)
    
    # Find peaks
    bin_idx, peak_freq, peak_mag = find_peak_bin(engine)
    println("Dominant peak: $(round(peak_freq, digits=1)) Hz (bin $bin_idx, magnitude $(round(peak_mag, digits=2)))")
    
    peaks = find_peaks(engine; min_height=5.0f0)
    println("Found $(length(peaks)) peaks above threshold")
    for (b, f, m) in peaks
        println("  $(round(f, digits=1)) Hz: magnitude $(round(m, digits=2))")
    end
    
    println()
    println("Phase 2 complete!")
end

main()
