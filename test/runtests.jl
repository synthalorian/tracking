using Test

# Add src to path
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using Tracking

@testset "Phase 1: Audio Capture" begin
    
    @testset "RingBuffer" begin
        
        @testset "Basic operations" begin
            rb = RingBuffer{Float32}(10)
            
            @test capacity(rb) == 10
            @test length(rb) == 0
            @test isempty(rb)
            @test !Tracking.isfull(rb)
            @test available(rb) == 10
            
            push!(rb, 1.0f0)
            @test length(rb) == 1
            @test !isempty(rb)
            
            val = popfirst!(rb)
            @test val == 1.0f0
            @test isempty(rb)
        end
        
        @testset "Batch operations" begin
            rb = RingBuffer{Float32}(10)
            
            push!(rb, [1.0f0, 2.0f0, 3.0f0])
            @test length(rb) == 3
            
            vals = popfirst!(rb, 2)
            @test vals == [1.0f0, 2.0f0]
            @test length(rb) == 1
        end
        
        @testset "Overwrite mode" begin
            rb = RingBuffer{Float32}(3)
            
            Tracking.overwrite!(rb, 1.0f0)
            Tracking.overwrite!(rb, 2.0f0)
            Tracking.overwrite!(rb, 3.0f0)
            @test length(rb) == 3
            @test Tracking.isfull(rb)
            
            Tracking.overwrite!(rb, 4.0f0)
            @test length(rb) == 3  # Should still be full
            
            # Oldest should have been overwritten
            vals = popfirst!(rb, 3)
            @test vals == [2.0f0, 3.0f0, 4.0f0]
        end
        
        @testset "Wraparound" begin
            rb = RingBuffer{Float32}(4)
            
            push!(rb, [1.0f0, 2.0f0, 3.0f0])
            popfirst!(rb, 2)  # Remove first 2
            push!(rb, [4.0f0, 5.0f0, 6.0f0])  # This should wrap
            
            @test length(rb) == 4
            vals = popfirst!(rb, 4)
            @test vals == [3.0f0, 4.0f0, 5.0f0, 6.0f0]
        end
        
        @testset "Peek operations" begin
            rb = RingBuffer{Float32}(5)
            push!(rb, [1.0f0, 2.0f0, 3.0f0])
            
            @test Tracking.peek(rb) == 1.0f0
            @test length(rb) == 3  # Peek shouldn't remove
            
            vals = Tracking.peek(rb, 2)
            @test vals == [1.0f0, 2.0f0]
            @test length(rb) == 3
        end
        
        @testset "Empty! operation" begin
            rb = RingBuffer{Float32}(5)
            push!(rb, [1.0f0, 2.0f0, 3.0f0])
            @test length(rb) == 3
            
            empty!(rb)
            @test isempty(rb)
            @test length(rb) == 0
        end
        
        @testset "Thread safety" begin
            rb = RingBuffer{Float32}(10000)
            
            # Producer task
            producer = @async begin
                for i in 1:5000
                    push!(rb, Float32(i))
                end
            end
            
            # Consumer task
            consumer = @async begin
                count = 0
                while count < 5000
                    if !isempty(rb)
                        popfirst!(rb)
                        count += 1
                    else
                        yield()
                    end
                end
                return count
            end
            
            wait(producer)
            consumed = fetch(consumer)
            @test consumed == 5000
        end
        
        @testset "Error handling" begin
            rb = RingBuffer{Float32}(2)
            
            @test_throws ErrorException popfirst!(rb)
            @test_throws ErrorException Tracking.peek(rb)
            
            push!(rb, [1.0f0, 2.0f0])
            @test_throws ErrorException push!(rb, 3.0f0)
            @test_throws ErrorException popfirst!(rb, 3)
            @test_throws ErrorException Tracking.peek(rb, 3)
        end
        
        @testset "Show" begin
            rb = RingBuffer{Float32}(10)
            push!(rb, [1.0f0, 2.0f0])
            
            io = IOBuffer()
            show(io, rb)
            str = String(take!(io))
            @test occursin("RingBuffer{Float32}", str)
            @test occursin("capacity=10", str)
            @test occursin("count=2", str)
        end
    end
    
    @testset "AudioCapture (without hardware)" begin
        
        @testset "RingBuffer integration" begin
            rb = RingBuffer{Float32}(44100)  # 1 second at 44.1kHz
            
            # Test that we can create the ringbuffer with expected capacity
            @test capacity(rb) == 44100
            
            # Simulate pushing audio samples
            samples = rand(Float32, 1024)
            Tracking.overwrite!(rb, samples)
            @test length(rb) == 1024
            
            # Simulate reading back
            read_samples = popfirst!(rb, 1024)
            @test length(read_samples) == 1024
            @test all(read_samples .== samples)
        end
        
        @testset "Latency calculations" begin
            rb = RingBuffer{Float32}(44100)
            
            # Test latency in samples
            @test length(rb) == 0
            
            # Fill half the buffer
            Tracking.overwrite!(rb, rand(Float32, 22050))
            @test length(rb) == 22050
            
            # Latency should be the amount of data in the buffer
            # At 44.1kHz, 22050 samples = 500ms
            # We can't directly test AudioCapture without hardware,
            # but we can test the ringbuffer latency concept
            @test length(rb) / 44100.0 * 1000.0 ≈ 500.0 atol=1.0
        end
    end
    
end

@testset "Phase 2: FFT Engine" begin
    
    @testset "Window functions" begin
        
        @testset "Rectangular window" begin
            w = Tracking.window_coefficients(RectangularWindow(), 8)
            @test length(w) == 8
            @test all(w .== 1.0f0)
        end
        
        @testset "Hann window" begin
            w = Tracking.window_coefficients(HannWindow(), 8)
            @test length(w) == 8
            @test w[1] ≈ 0.0f0 atol=1e-6
            @test w[end] ≈ 0.0f0 atol=1e-6
            @test w[4] ≈ 0.9504844f0 atol=1e-5  # For n=8, center falls between 4 and 5
            @test all(w .>= 0.0f0)
            @test all(w .<= 1.0f0)
        end
        
        @testset "Hamming window" begin
            w = Tracking.window_coefficients(HammingWindow(), 8)
            @test length(w) == 8
            @test w[1] ≈ 0.08f0 atol=1e-2  # Hamming doesn't go to 0
            @test w[end] ≈ 0.08f0 atol=1e-2
            @test all(w .>= 0.0f0)
            @test all(w .<= 1.0f0)
        end
        
        @testset "Blackman window" begin
            w = Tracking.window_coefficients(BlackmanWindow(), 64)
            @test length(w) == 64
            @test w[1] ≈ 0.0f0 atol=1e-6
            @test w[end] ≈ 0.0f0 atol=1e-6
            @test all(w .>= -1.0f-6)  # Allow tiny floating-point negatives at edges
            @test all(w .<= 1.0f0)
        end
        
        @testset "Window correction factors" begin
            rect = Tracking.window_coefficients(RectangularWindow(), 64)
            hann = Tracking.window_coefficients(HannWindow(), 64)
            
            rect_power = Tracking.window_power_correction(rect)
            hann_power = Tracking.window_power_correction(hann)
            
            # Rectangular window has no loss, correction ≈ 1
            @test rect_power ≈ 1.0f0 atol=1e-5
            # Hann window has ~1.63x power loss
            @test hann_power > 1.0f0
            
            rect_amp = Tracking.window_amplitude_correction(rect)
            hann_amp = Tracking.window_amplitude_correction(hann)
            
            @test rect_amp ≈ 1.0f0 atol=1e-5
            @test hann_amp > 1.0f0
        end
    end
    
    @testset "FFTEngine construction" begin
        
        @testset "Default parameters" begin
            engine = FFTEngine(512, 44100)
            @test fft_size(engine) == 512
            @test sample_rate(engine) == 44100
            @test num_bins(engine) == 257  # 512/2 + 1
            @test nyquist(engine) == 22050.0f0
            @test frequency_resolution(engine) ≈ 86.1328125f0 atol=1e-5
            @test window_type(engine) isa HannWindow
        end
        
        @testset "Power-of-2 rounding" begin
            engine = FFTEngine(500, 44100)  # Not a power of 2
            @test fft_size(engine) == 512   # Should round up to 512
        end
        
        @testset "Different window types" begin
            engine_rect = FFTEngine(256, 44100; window_type=RectangularWindow())
            @test window_type(engine_rect) isa RectangularWindow
            
            engine_hamm = FFTEngine(256, 44100; window_type=HammingWindow())
            @test window_type(engine_hamm) isa HammingWindow
            
            engine_black = FFTEngine(256, 44100; window_type=BlackmanWindow())
            @test window_type(engine_black) isa BlackmanWindow
        end
        
        @testset "Show" begin
            engine = FFTEngine(1024, 48000)
            io = IOBuffer()
            show(io, engine)
            str = String(take!(io))
            @test occursin("FFTEngine", str)
            @test occursin("nfft=1024", str)
            @test occursin("sr=48000Hz", str)
            @test occursin("window=HannWindow", str)
        end
    end
    
    @testset "FFT processing" begin
        
        @testset "DC signal" begin
            engine = FFTEngine(256, 44100; window_type=RectangularWindow())
            samples = ones(Float32, 256)  # DC = 1.0
            
            spectrum = process!(engine, samples)
            @test length(spectrum) == 129  # 256/2 + 1
            
            # DC bin should have significant energy
            mag = magnitude_spectrum(engine; corrected=false)
            @test mag[1] > 0.0f0
            
            # Phase at DC should be 0 or near 0
            phase = phase_spectrum(engine)
            @test abs(phase[1]) < 0.1f0
        end
        
        @testset "Sine wave detection" begin
            sr = 44100
            nfft = 1024
            freq = 1000.0  # 1 kHz sine wave
            engine = FFTEngine(nfft, sr; window_type=HannWindow())
            
            # Generate sine wave
            t = [i / sr for i in 0:(nfft - 1)]
            samples = Float32[sin(2π * freq * ti) for ti in t]
            
            spectrum = process!(engine, samples)
            mag = magnitude_spectrum(engine; corrected=false)
            
            # Find peak
            bin_idx, peak_freq, peak_mag = find_peak_bin(engine; exclude_dc=true)
            
            # Peak should be near 1 kHz
            @test peak_freq ≈ freq atol=50.0  # Within one bin width (~43 Hz)
            @test peak_mag > 0.0f0
            
            # Verify bin_to_hz and hz_to_bin
            expected_bin = hz_to_bin(engine, freq)
            @test expected_bin ≈ round(Int, freq * nfft / sr)
            @test bin_to_hz(engine, expected_bin) ≈ expected_bin * sr / nfft atol=1.0f0
        end
        
        @testset "Empty signal" begin
            engine = FFTEngine(256, 44100)
            samples = zeros(Float32, 256)
            
            process!(engine, samples)
            mag = magnitude_spectrum(engine; corrected=false)
            
            # All magnitudes should be near 0
            @test all(mag .< 1.0f0)
            
            # No peaks should be found
            peaks = find_peaks(engine; min_height=0.1f0)
            @test isempty(peaks)
        end
        
        @testset "Magnitude at specific frequencies" begin
            sr = 44100
            nfft = 512
            freq = 500.0
            engine = FFTEngine(nfft, sr)
            
            t = [i / sr for i in 0:(nfft - 1)]
            samples = Float32[sin(2π * freq * ti) for ti in t]
            
            process!(engine, samples)
            
            # Check magnitude at the expected frequency
            mag_at_freq = magnitude_at_hz(engine, freq)
            @test mag_at_freq > 0.0f0
            
            # Check magnitude at bin
            bin = hz_to_bin(engine, freq)
            mag_at_bin = magnitude_at_bin(engine, bin)
            @test mag_at_bin > 0.0f0
        end
    end
    
    @testset "Frequency bin utilities" begin
        engine = FFTEngine(1024, 44100)
        
        @testset "frequency_bins" begin
            bins = frequency_bins(engine)
            @test length(bins) == 513  # 1024/2 + 1
            @test bins[1] == 0.0f0      # DC
            @test bins[end] == 22050.0f0  # Nyquist
            @test bins[2] ≈ 44100.0f0 / 1024.0f0 atol=1e-5
        end
        
        @testset "bin_to_hz" begin
            @test bin_to_hz(engine, 0) == 0.0f0
            @test bin_to_hz(engine, 512) == 22050.0f0
            @test bin_to_hz(engine, 10) ≈ 10.0f0 * 44100.0f0 / 1024.0f0 atol=1e-3
        end
        
        @testset "hz_to_bin" begin
            @test hz_to_bin(engine, 0.0) == 0
            @test hz_to_bin(engine, 22050.0) == 512
            @test hz_to_bin(engine, 1000.0) == round(Int, 1000.0 * 1024 / 44100)
        end
        
        @testset "Error handling" begin
            @test_throws ErrorException bin_to_hz(engine, -1)
            @test_throws ErrorException bin_to_hz(engine, 513)
            @test_throws ErrorException hz_to_bin(engine, -1.0)
            @test_throws ErrorException hz_to_bin(engine, 30000.0)
        end
    end
    
    @testset "Peak detection" begin
        sr = 44100
        nfft = 1024
        
        @testset "Single sine wave" begin
            freq = 2000.0
            engine = FFTEngine(nfft, sr; window_type=HannWindow())
            
            t = [i / sr for i in 0:(nfft - 1)]
            samples = Float32[sin(2π * freq * ti) for ti in t]
            
            process!(engine, samples)
            
            bin_idx, peak_freq, peak_mag = find_peak_bin(engine)
            @test peak_freq ≈ freq atol=50.0
            @test peak_mag > 0.0f0
            @test bin_idx >= 0
            @test bin_idx <= nfft ÷ 2
        end
        
        @testset "Multiple peaks" begin
            freq1 = 500.0
            freq2 = 2000.0
            freq3 = 5000.0
            engine = FFTEngine(nfft, sr; window_type=HannWindow())
            
            t = [i / sr for i in 0:(nfft - 1)]
            samples = Float32[
                1.0f0 * sin(2π * freq1 * ti) +
                0.5f0 * sin(2π * freq2 * ti) +
                0.3f0 * sin(2π * freq3 * ti)
                for ti in t
            ]
            
            process!(engine, samples)
            
            peaks = find_peaks(engine; min_height=1.0f0)
            @test length(peaks) >= 2  # Should find at least the two strongest
            
            # Check that we found peaks near expected frequencies
            peak_freqs = [p[2] for p in peaks]
            @test any(f -> abs(f - freq1) < 100.0, peak_freqs) ||
                  any(f -> abs(f - freq2) < 100.0, peak_freqs)
        end
        
        @testset "find_peaks excludes DC" begin
            engine = FFTEngine(256, 44100; window_type=RectangularWindow())
            samples = ones(Float32, 256)
            process!(engine, samples)
            
            peaks = find_peaks(engine; exclude_dc=true)
            # DC should be excluded
            @test all(p -> p[2] > 0.0f0, peaks)
        end
    end
    
    @testset "Power spectrum" begin
        engine = FFTEngine(256, 44100; window_type=RectangularWindow())
        samples = ones(Float32, 256)
        
        process!(engine, samples)
        
        mag = magnitude_spectrum(engine; corrected=false)
        power = power_spectrum(engine; corrected=false)
        
        # Power should be magnitude squared / nfft^2
        expected_power = mag.^2 ./ 256^2
        @test all(isapprox.(power, expected_power, atol=1e-10))
    end
    
    @testset "RingBuffer integration" begin
        
        @testset "Process from RingBuffer" begin
            rb = RingBuffer{Float32}(1024)
            engine = FFTEngine(512, 44100)
            
            # Generate some test samples
            samples = rand(Float32, 1024)
            push!(rb, samples)
            
            # Should be able to process from RingBuffer
            spectrum = process!(engine, rb)
            @test length(spectrum) == 257  # 512/2 + 1
            
            mag = magnitude_spectrum(engine; corrected=false)
            @test length(mag) == 257
        end
        
        @testset "RingBuffer too small" begin
            rb = RingBuffer{Float32}(100)
            engine = FFTEngine(512, 44100)
            
            push!(rb, rand(Float32, 100))
            
            @test_throws ErrorException process!(engine, rb)
        end
    end
    
    @testset "Error handling" begin
        engine = FFTEngine(256, 44100)
        
        @testset "Wrong sample count" begin
            @test_throws ErrorException process!(engine, rand(Float32, 128))
            @test_throws ErrorException process!(engine, rand(Float32, 512))
        end
        
        @testset "magnitude_at_bin out of range" begin
            process!(engine, ones(Float32, 256))
            @test_throws ErrorException magnitude_at_bin(engine, -1)
            @test_throws ErrorException magnitude_at_bin(engine, 129)
        end
        
        @testset "magnitude_at_hz out of range" begin
            @test_throws ErrorException magnitude_at_hz(engine, -1.0)
            @test_throws ErrorException magnitude_at_hz(engine, 30000.0)
        end
    end
    
    @testset "Amplitude correction" begin
        sr = 44100
        nfft = 1024
        freq = 1000.0
        
        # Test with Hann window - corrected amplitude should be closer to true amplitude
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        
        t = [i / sr for i in 0:(nfft - 1)]
        amplitude = 2.0f0
        samples = Float32[amplitude * sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        mag_uncorrected = magnitude_spectrum(engine; corrected=false)
        mag_corrected = magnitude_spectrum(engine; corrected=true)
        
        # Corrected should be larger than uncorrected (Hann window attenuates)
        peak_bin_uncorrected, _, _ = find_peak_bin(engine; exclude_dc=true)
        # Need fresh process for fair comparison... actually find_peak_bin uses magnitude_spectrum
        # which sets valid=true. Let me reprocess.
        
        process!(engine, samples)
        mag_u = magnitude_spectrum(engine; corrected=false)
        
        process!(engine, samples)
        mag_c = magnitude_spectrum(engine; corrected=true)
        
        # The corrected peak should be larger
        peak_idx = argmax(mag_u[2:end]) + 1
        @test mag_c[peak_idx] > mag_u[peak_idx]
    end
    
end

@testset "Phase 3: Spectrum Display" begin
    
    @testset "DisplayConfig" begin
        
        @testset "Default construction" begin
            config = DisplayConfig()
            @test config.freq_scale isa LogScale
            @test config.mag_scale isa DecibelMagnitude
            @test config.min_freq == 20.0f0
            @test config.max_freq == 22050.0f0
            @test config.db_range == 80.0f0
            @test config.db_ref == 1.0f0
            @test config.peak_hold == true
            @test config.peak_decay == 20.0f0
            @test config.refresh_rate == 30.0f0
            @test config.title == "Spectrum Analyzer"
        end
        
        @testset "Custom construction" begin
            config = DisplayConfig(
                freq_scale=LinearScale(),
                mag_scale=LinearMagnitude(),
                min_freq=100.0,
                max_freq=10000.0,
                db_range=60.0,
                db_ref=0.5,
                peak_hold=false,
                peak_decay=10.0,
                refresh_rate=60.0,
                title="Custom Display"
            )
            @test config.freq_scale isa LinearScale
            @test config.mag_scale isa LinearMagnitude
            @test config.min_freq == 100.0f0
            @test config.max_freq == 10000.0f0
            @test config.db_range == 60.0f0
            @test config.db_ref == 0.5f0
            @test config.peak_hold == false
            @test config.peak_decay == 10.0f0
            @test config.refresh_rate == 60.0f0
            @test config.title == "Custom Display"
        end
    end
    
    @testset "Frequency and magnitude scales" begin
        @test LinearScale() isa FrequencyScale
        @test LogScale() isa FrequencyScale
        @test LinearMagnitude() isa MagnitudeScale
        @test DecibelMagnitude() isa MagnitudeScale
    end
    
    @testset "SpectrumDisplay construction" begin
        engine = FFTEngine(1024, 44100)
        
        @testset "Default constructor" begin
            display = SpectrumDisplay(engine=engine)
            @test display.config.freq_scale isa LogScale
            @test display.config.mag_scale isa DecibelMagnitude
            @test !display.running
            @test display.task === nothing
            @test display.config.title == "Spectrum Analyzer"
        end
        
        @testset "With custom config" begin
            config = DisplayConfig(
                freq_scale=LinearScale(),
                mag_scale=LinearMagnitude(),
                title="Test Display"
            )
            display = SpectrumDisplay(config, engine=engine)
            @test display.config.freq_scale isa LinearScale
            @test display.config.mag_scale isa LinearMagnitude
            @test display.config.title == "Test Display"
        end
        
        @testset "Convenience constructors" begin
            linear_display = LinearSpectrumDisplay(engine)
            @test linear_display.config.freq_scale isa LinearScale
            @test linear_display.config.mag_scale isa DecibelMagnitude
            
            log_display = LogSpectrumDisplay(engine)
            @test log_display.config.freq_scale isa LogScale
            @test log_display.config.mag_scale isa DecibelMagnitude
        end
    end
    
    @testset "Display scale conversion" begin
        config_linear = DisplayConfig(mag_scale=LinearMagnitude())
        config_db = DisplayConfig(mag_scale=DecibelMagnitude())
        
        # Linear magnitude should pass through unchanged
        @test Tracking._to_display_scale(1.0f0, config_linear) == 1.0f0
        @test Tracking._to_display_scale(0.5f0, config_linear) == 0.5f0
        
        # dB conversion: 1.0 -> 0 dB, 0.5 -> ~-6 dB, 0.1 -> -20 dB
        @test Tracking._to_display_scale(1.0f0, config_db) ≈ 0.0f0 atol=1e-5
        @test Tracking._to_display_scale(0.1f0, config_db) ≈ -20.0f0 atol=1e-5
        @test Tracking._to_display_scale(0.5f0, config_db) ≈ -6.0206f0 atol=1e-3
        
        # Very small values should be clamped to avoid -Inf
        @test Tracking._to_display_scale(0.0f0, config_db) < -100.0f0
        @test Tracking._to_display_scale(1.0f-12, config_db) < -100.0f0
    end
    
    @testset "update! with FFT engine" begin
        sr = 44100
        nfft = 512
        freq = 1000.0
        engine = FFTEngine(nfft, sr)
        
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        process!(engine, samples)
        
        config = DisplayConfig(
            freq_scale=LinearScale(),
            mag_scale=DecibelMagnitude(),
            min_freq=0.0,
            max_freq=22050.0
        )
        display = SpectrumDisplay(config, engine=engine)
        
        # Update the display
        update!(display, engine)
        
        # Check that observables were updated
        freqs = Tracking.frequency_data(display)
        mags = Tracking.magnitude_data(display)
        
        @test length(freqs) > 0
        @test length(mags) == length(freqs)
        @test all(freqs .>= config.min_freq)
        @test all(freqs .<= config.max_freq)
        
        # With a 1 kHz sine wave, there should be a peak near 1 kHz
        peak_mag = maximum(mags)
        @test peak_mag > -40.0f0  # Should be a strong peak
    end
    
    @testset "update! with explicit data" begin
        config = DisplayConfig(
            freq_scale=LinearScale(),
            mag_scale=LinearMagnitude(),
            min_freq=0.0,  # Include DC so all test data passes through
            max_freq=500.0
        )
        display = SpectrumDisplay(config)
        
        freqs = Float32[0.0, 100.0, 200.0, 300.0, 400.0]
        mags = Float32[0.0, 1.0, 2.0, 1.0, 0.0]
        
        update!(display, FFTEngine(8, 44100); freqs=freqs, mags=mags)
        
        @test Tracking.frequency_data(display) == freqs
        @test Tracking.magnitude_data(display) == mags
    end
    
    @testset "Peak hold" begin
        config = DisplayConfig(peak_hold=true)
        display = SpectrumDisplay(config)
        
        # Initially peaks should be -Inf
        peaks = Tracking.peak_data(display)
        @test all(peaks .== -Inf)
        
        # After reset, same thing
        reset_peaks!(display)
        peaks = Tracking.peak_data(display)
        @test all(peaks .== -Inf)
    end
    
    @testset "Display configuration methods" begin
        engine = FFTEngine(256, 44100)
        display = SpectrumDisplay(engine=engine)
        
        @testset "set_freq_limits!" begin
            set_freq_limits!(display, 100.0, 5000.0)
            @test display.config.min_freq == 100.0f0
            @test display.config.max_freq == 5000.0f0
        end
        
        @testset "set_mag_limits!" begin
            set_mag_limits!(display, -100.0, 10.0)
            # Just verify it doesn't error
            @test true
        end
        
        @testset "set_title!" begin
            set_title!(display, "New Title")
            @test display.config.title == "New Title"
            @test display.ax.title[] == "New Title"
        end
    end
    
    @testset "Show" begin
        engine = FFTEngine(512, 44100)
        display = SpectrumDisplay(engine=engine)
        
        io = IOBuffer()
        show(io, display)
        str = String(take!(io))
        @test occursin("SpectrumDisplay", str)
        @test occursin("LogScale", str)
        @test occursin("DecibelMagnitude", str)
        @test occursin("running=false", str)
    end
    
    @testset "Start/stop lifecycle" begin
        config = DisplayConfig(refresh_rate=60.0)
        display = SpectrumDisplay(config)
        
        @test !isrunning(display)
        
        # Start without capture (manual mode)
        start!(display)
        @test isrunning(display)
        
        stop!(display)
        @test !isrunning(display)
    end
    
    @testset "Integration with AudioCapture + FFTEngine" begin
        # Create a ringbuffer and populate it with test data
        rb = RingBuffer{Float32}(4096)
        sr = 44100
        nfft = 1024
        
        # Generate a multi-frequency test signal
        freq1 = 500.0
        freq2 = 2000.0
        t = [i / sr for i in 0:4095]
        samples = Float32[
            0.7 * sin(2π * freq1 * ti) + 0.3 * sin(2π * freq2 * ti)
            for ti in t
        ]
        overwrite!(rb, samples)
        
        engine = FFTEngine(nfft, sr)
        
        # Process from ringbuffer
        spectrum = process!(engine, rb)
        @test length(spectrum) == nfft ÷ 2 + 1
        
        # Create display and update
        config = DisplayConfig(
            min_freq=20.0,
            max_freq=10000.0,
            freq_scale=LogScale()
        )
        display = SpectrumDisplay(config, engine=engine)
        update!(display, engine)
        
        freqs = Tracking.frequency_data(display)
        mags = Tracking.magnitude_data(display)
        
        @test length(freqs) > 0
        @test length(mags) == length(freqs)
        
        # Verify frequency range filtering
        @test all(freqs .>= 20.0f0)
        @test all(freqs .<= 10000.0f0)
        
        # Should have peaks (signal was not zero)
        @test maximum(mags) > -80.0f0
    end
    
end

@testset "Phase 4: Waterfall / Spectrogram" begin
    
    @testset "WaterfallConfig" begin
        
        @testset "Default construction" begin
            config = WaterfallConfig()
            @test config.time_history == 100
            @test config.min_freq == 20.0f0
            @test config.max_freq == 22050.0f0
            @test config.db_range == 80.0f0
            @test config.db_ref == 1.0f0
            @test config.refresh_rate == 30.0f0
            @test config.colormap == :viridis
            @test config.title == "Spectrogram"
        end
        
        @testset "Custom construction" begin
            config = WaterfallConfig(
                time_history=50,
                min_freq=100.0,
                max_freq=10000.0,
                db_range=60.0,
                db_ref=0.5,
                refresh_rate=60.0,
                colormap=:plasma,
                title="Custom Waterfall"
            )
            @test config.time_history == 50
            @test config.min_freq == 100.0f0
            @test config.max_freq == 10000.0f0
            @test config.db_range == 60.0f0
            @test config.db_ref == 0.5f0
            @test config.refresh_rate == 60.0f0
            @test config.colormap == :plasma
            @test config.title == "Custom Waterfall"
        end
    end
    
    @testset "WaterfallDisplay construction" begin
        engine = FFTEngine(1024, 44100)
        
        @testset "With config" begin
            config = WaterfallConfig(time_history=50)
            display = WaterfallDisplay(config, engine)
            
            @test display.config.time_history == 50
            @test !display.running
            @test display.task === nothing
            @test display.frame_count == 0
            @test length(display.freqs) > 0
        end
        
        @testset "Convenience constructor" begin
            display = WaterfallDisplay(engine; time_history=75)
            @test display.config.time_history == 75
            @test length(display.freqs) > 0
        end
    end
    
    @testset "push_frame!" begin
        engine = FFTEngine(512, 44100)
        display = WaterfallDisplay(engine; time_history=10)
        
        # Get initial magnitude spectrum
        samples = rand(Float32, 512)
        process!(engine, samples)
        mags = magnitude_spectrum(engine; corrected=true)
        
        # Push frame
        push_frame!(display, mags)
        @test display.frame_count == 1
        
        # Push more frames
        for i in 1:5
            samples = rand(Float32, 512)
            process!(engine, samples)
            mags = magnitude_spectrum(engine; corrected=true)
            push_frame!(display, mags)
        end
        
        @test display.frame_count == 6
        
        # Check spectrogram data shape
        data = Tracking.spectrogram_data(display)
        @test size(data, 1) == length(display.freqs)
        @test size(data, 2) == 10  # time_history
    end
    
    @testset "update! with engine" begin
        sr = 44100
        nfft = 512
        freq = 1000.0
        engine = FFTEngine(nfft, sr)
        display = WaterfallDisplay(engine; time_history=20)
        
        # Generate sine wave and process
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        process!(engine, samples)
        
        # Update display
        update!(display, engine)
        @test display.frame_count == 1
        
        data = Tracking.spectrogram_data(display)
        @test size(data, 2) == 20
    end
    
    @testset "reset!" begin
        engine = FFTEngine(256, 44100)
        display = WaterfallDisplay(engine; time_history=10)
        
        # Push some frames
        for i in 1:5
            samples = rand(Float32, 256)
            process!(engine, samples)
            update!(display, engine)
        end
        
        @test display.frame_count == 5
        
        # Reset
        reset!(display)
        @test display.frame_count == 0
        
        data = Tracking.spectrogram_data(display)
        # All values should be at minimum (-db_range)
        @test all(data .== -display.config.db_range)
    end
    
    @testset "frequency_data" begin
        engine = FFTEngine(512, 44100)
        display = WaterfallDisplay(engine)
        
        freqs = Tracking.frequency_data(display)
        @test length(freqs) > 0
        @test freqs[1] >= display.config.min_freq
        @test freqs[end] <= display.config.max_freq
    end
    
    @testset "Display configuration methods" begin
        engine = FFTEngine(256, 44100)
        display = WaterfallDisplay(engine)
        
        @testset "set_freq_limits!" begin
            set_freq_limits!(display, 100.0, 5000.0)
            @test display.config.min_freq == 100.0f0
            @test display.config.max_freq == 5000.0f0
        end
        
        @testset "set_title!" begin
            set_title!(display, "New Title")
            @test display.config.title == "New Title"
            @test display.ax.title[] == "New Title"
        end
    end
    
    @testset "Show" begin
        engine = FFTEngine(512, 44100)
        display = WaterfallDisplay(engine)
        
        io = IOBuffer()
        show(io, display)
        str = String(take!(io))
        @test occursin("WaterfallDisplay", str)
        @test occursin("time_history=100", str)
        @test occursin("running=false", str)
    end
    
    @testset "Start/stop lifecycle" begin
        engine = FFTEngine(256, 44100)
        display = WaterfallDisplay(engine)
        
        @test !isrunning(display)
        
        # Start in manual mode
        start!(display)
        @test isrunning(display)
        
        stop!(display)
        @test !isrunning(display)
    end
    
    @testset "Integration: Spectrum + Waterfall" begin
        rb = RingBuffer{Float32}(4096)
        sr = 44100
        nfft = 1024
        
        # Generate test signal
        freq1 = 500.0
        freq2 = 2000.0
        t = [i / sr for i in 0:4095]
        samples = Float32[
            0.7 * sin(2π * freq1 * ti) + 0.3 * sin(2π * freq2 * ti)
            for ti in t
        ]
        overwrite!(rb, samples)
        
        engine = FFTEngine(nfft, sr)
        
        # Process from ringbuffer
        spectrum = process!(engine, rb)
        @test length(spectrum) == nfft ÷ 2 + 1
        
        # Create both displays with matching frequency ranges
        config = DisplayConfig(min_freq=20.0, max_freq=10000.0)
        spectrum_display = SpectrumDisplay(config, engine=engine)
        wf_config = WaterfallConfig(min_freq=20.0, max_freq=10000.0, time_history=50)
        waterfall_display = WaterfallDisplay(wf_config, engine)
        
        # Update both
        update!(spectrum_display, engine)
        update!(waterfall_display, engine)
        
        # Verify spectrum data
        freqs = Tracking.frequency_data(spectrum_display)
        mags = Tracking.magnitude_data(spectrum_display)
        @test length(freqs) > 0
        @test length(mags) == length(freqs)
        
        # Verify waterfall data
        wf_data = Tracking.spectrogram_data(waterfall_display)
        wf_freqs = Tracking.frequency_data(waterfall_display)
        @test size(wf_data, 1) == length(wf_freqs)
        @test size(wf_data, 2) == 50
        
        # Both should show the same frequency range
        @test length(wf_freqs) == length(freqs)
    end
    
    @testset "Live display loop (simulated)" begin
        # Simulate a live capture + display loop without actual hardware
        rb = RingBuffer{Float32}(4096)
        sr = 44100
        nfft = 512
        engine = FFTEngine(nfft, sr)
        
        # Create displays
        spectrum_display = SpectrumDisplay(engine=engine)
        waterfall_display = WaterfallDisplay(engine; time_history=20)
        
        # Simulate a few frames of live data
        freq = 1000.0
        for frame in 1:10
            # Generate frame of samples
            phase = frame * 0.1
            t = [i / sr for i in 0:(nfft - 1)]
            samples = Float32[sin(2π * freq * ti + phase) for ti in t]
            overwrite!(rb, samples)
            
            # Process and update
            process!(engine, rb)
            update!(spectrum_display, engine)
            update!(waterfall_display, engine)
        end
        
        # Verify displays were updated
        @test Tracking.frame_count(waterfall_display) == 10
        
        mags = Tracking.magnitude_data(spectrum_display)
        @test length(mags) > 0
        @test maximum(mags) > -80.0f0  # Should have a peak
    end
    
end

@testset "Phase 5: Peak Detection Algorithm" begin
    
    @testset "Peak struct" begin
        
        @testset "Construction" begin
            p = Peak(1000.0, 5.0, 23, 0.1, 0.95, 20.0)
            @test p.frequency == 1000.0f0
            @test p.magnitude == 5.0f0
            @test p.bin == 23
            @test p.bin_offset == 0.1f0
            @test p.confidence == 0.95f0
            @test p.snr_db == 20.0f0
            @test p.frame_id == 0
        end
        
        @testset "With frame_id" begin
            p = Peak(440.0, 1.0, 10, 0.0, 0.8, 15.0, 5)
            @test p.frame_id == 5
        end
        
        @testset "Show" begin
            p = Peak(1000.0, 5.0, 23, 0.1, 0.95, 20.0)
            io = IOBuffer()
            show(io, p)
            str = String(take!(io))
            @test occursin("Peak", str)
            @test occursin("1000.0", str)
            @test occursin("SNR=20.0", str)
        end
    end
    
    @testset "PeakDetector construction" begin
        
        @testset "Default parameters" begin
            pd = PeakDetector()
            @test pd.min_height == 0.0f0
            @test pd.snr_threshold == 10.0f0
            @test pd.min_peak_distance == 50.0f0
            @test pd.min_freq == 20.0f0
            @test pd.max_freq == 22050.0f0
            @test pd.noise_floor_percentile == 50.0f0
            @test pd.exclude_dc == true
            @test pd.max_peaks == 100
            @test pd.use_interpolation == true
            @test pd.frame_counter == 0
            @test isempty(pd.prev_peaks)
        end
        
        @testset "Custom parameters" begin
            pd = PeakDetector(
                min_height=0.5,
                snr_threshold=15.0,
                min_peak_distance=100.0,
                min_freq=100.0,
                max_freq=8000.0,
                noise_floor_percentile=75.0,
                exclude_dc=false,
                max_peaks=50,
                use_interpolation=false
            )
            @test pd.min_height == 0.5f0
            @test pd.snr_threshold == 15.0f0
            @test pd.min_peak_distance == 100.0f0
            @test pd.min_freq == 100.0f0
            @test pd.max_freq == 8000.0f0
            @test pd.noise_floor_percentile == 75.0f0
            @test pd.exclude_dc == false
            @test pd.max_peaks == 50
            @test pd.use_interpolation == false
        end
        
        @testset "Show" begin
            pd = PeakDetector()
            io = IOBuffer()
            show(io, pd)
            str = String(take!(io))
            @test occursin("PeakDetector", str)
            @test occursin("SNR=10.0", str)
            @test occursin("interp=true", str)
        end
    end
    
    @testset "Noise floor estimation" begin
        
        @testset "Median noise floor" begin
            mags = Float32[0.1, 0.2, 5.0, 0.15, 0.1, 0.2, 0.1]
            noise = Tracking._estimate_noise_floor(mags, 50.0f0)
            # Median should be around 0.15
            @test noise ≈ 0.15f0 atol=0.05f0
        end
        
        @testset "Empty spectrum" begin
            noise = Tracking._estimate_noise_floor(Float32[], 50.0f0)
            @test noise == 0.0f0
        end
        
        @testset "Percentile variation" begin
            mags = Float32[0.1, 0.2, 5.0, 10.0, 0.15, 0.1]
            
            # 50th percentile (median)
            noise_50 = Tracking._estimate_noise_floor(mags, 50.0f0)
            
            # 90th percentile should be higher
            noise_90 = Tracking._estimate_noise_floor(mags, 90.0f0)
            @test noise_90 >= noise_50
        end
    end
    
    @testset "Parabolic interpolation" begin
        
        @testset "Perfect parabola" begin
            freq_bins = Float32[0.0, 43.0, 86.0, 129.0, 172.0]
            # Perfect parabola with peak at bin 3 (index 3, 1-based)
            # Peak at x=0 (center), y=10
            mags = Float32[6.0, 8.0, 10.0, 8.0, 6.0]
            
            refined_freq, refined_mag, offset = Tracking._refine_peak_parabolic(freq_bins, mags, 3)
            
            # Should be very close to center
            @test abs(offset) < 0.01f0
            @test refined_mag ≈ 10.0f0 atol=0.01f0
            @test refined_freq ≈ 86.0f0 atol=1.0f0
        end
        
        @testset "Offset parabola" begin
            freq_bins = Float32[0.0, 43.0, 86.0, 129.0, 172.0]
            # Asymmetric: peak is slightly to the right of bin 3
            # a = mag[i-1] = 7, b = mag[i] = 10, c = mag[i+1] = 9
            # c > a means peak is to the right, so offset should be positive
            mags = Float32[6.0, 7.0, 10.0, 9.0, 7.0]
            
            refined_freq, refined_mag, offset = Tracking._refine_peak_parabolic(freq_bins, mags, 3)
            
            # When c > a, peak is to the right (higher frequency), offset is positive
            # offset = (c - a) / (2 * (2b - a - c)) = (9 - 7) / (2 * (20 - 7 - 9)) = 2 / 8 = 0.25
            @test offset > 0.0f0
            @test abs(offset) < 0.5f0
            @test refined_freq > freq_bins[3]  # Refined freq should be higher than center bin
        end
        
        @testset "Edge cases" begin
            freq_bins = Float32[0.0, 43.0, 86.0]
            mags = Float32[1.0, 2.0, 1.0]
            
            # First bin - can't interpolate
            f1, m1, o1 = Tracking._refine_peak_parabolic(freq_bins, mags, 1)
            @test o1 == 0.0f0
            
            # Last bin - can't interpolate
            f3, m3, o3 = Tracking._refine_peak_parabolic(freq_bins, mags, 3)
            @test o3 == 0.0f0
        end
    end
    
    @testset "SNR calculation" begin
        
        @testset "Basic SNR" begin
            snr = Tracking._calculate_snr(10.0f0, 1.0f0)
            @test snr ≈ 20.0f0 atol=0.1f0  # 20*log10(10) = 20 dB
        end
        
        @testset "Low SNR" begin
            snr = Tracking._calculate_snr(2.0f0, 1.0f0)
            @test snr ≈ 6.02f0 atol=0.1f0  # 20*log10(2) ≈ 6.02 dB
        end
        
        @testset "Zero noise" begin
            snr = Tracking._calculate_snr(1.0f0, 0.0f0)
            @test snr == 0.0f0
        end
    end
    
    @testset "Confidence calculation" begin
        
        @testset "High SNR" begin
            conf = Tracking._calculate_confidence(30.0f0, 10.0f0)
            @test conf > 0.9f0
            @test conf <= 1.0f0
        end
        
        @testset "At threshold" begin
            conf = Tracking._calculate_confidence(10.0f0, 10.0f0)
            @test conf > 0.5f0
            @test conf < 1.0f0
        end
        
        @testset "Below threshold" begin
            conf = Tracking._calculate_confidence(5.0f0, 10.0f0)
            @test conf < 0.5f0
            @test conf >= 0.0f0
        end
        
        @testset "Zero SNR" begin
            conf = Tracking._calculate_confidence(0.0f0, 10.0f0)
            @test conf == 0.0f0
        end
    end
    
    @testset "Peak detection - single sine wave" begin
        sr = 44100
        nfft = 4096
        freq = 1000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        detector = PeakDetector(snr_threshold=5.0, min_peak_distance=20.0)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) >= 1
        @test has_peaks(peaks)
        
        # Strongest peak should be near 1000 Hz (within 2 Hz with interpolation)
        strongest = peaks[1]
        @test strongest.frequency ≈ freq atol=2.0
        @test strongest.magnitude > 0.0f0
        @test strongest.confidence > 0.5f0
        @test strongest.snr_db > 5.0f0
        @test strongest.bin >= 0
        @test strongest.bin < nfft ÷ 2
    end
    
    @testset "Peak detection - multiple sine waves" begin
        sr = 44100
        nfft = 4096
        
        freq1 = 440.0   # A4
        freq2 = 880.0   # A5
        freq3 = 1760.0  # A6
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[
            1.0 * sin(2π * freq1 * ti) +
            0.5 * sin(2π * freq2 * ti) +
            0.3 * sin(2π * freq3 * ti)
            for ti in t
        ]
        
        process!(engine, samples)
        
        detector = PeakDetector(snr_threshold=3.0, min_peak_distance=100.0)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) >= 2
        @test num_peaks(peaks) >= 2
        
        # Should find peaks near expected frequencies
        peak_freqs = peak_frequencies(peaks)
        
        # Check for 440 Hz
        found_440 = any(f -> abs(f - freq1) < 10.0, peak_freqs)
        @test found_440
        
        # Check for 880 Hz
        found_880 = any(f -> abs(f - freq2) < 10.0, peak_freqs)
        @test found_880
    end
    
    @testset "Peak detection - SNR threshold" begin
        sr = 44100
        nfft = 2048
        freq = 1000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        # High SNR threshold should still find the strong peak
        detector_high = PeakDetector(snr_threshold=20.0)
        peaks_high = detect_peaks!(detector_high, engine)
        @test length(peaks_high) >= 1
        
        # Very high SNR threshold might filter out the peak
        detector_very_high = PeakDetector(snr_threshold=100.0)
        peaks_very_high = detect_peaks!(detector_very_high, engine)
        # Result depends on actual SNR, but test that it runs without error
        @test typeof(peaks_very_high) == Vector{Peak}
    end
    
    @testset "Peak detection - min peak distance" begin
        sr = 44100
        nfft = 4096
        
        # Two well-separated frequencies (at least 9 bins apart)
        # With nfft=4096, resolution is ~10.8 Hz
        freq1 = 1000.0
        freq2 = 1100.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[
            1.0 * sin(2π * freq1 * ti) +
            0.8 * sin(2π * freq2 * ti)
            for ti in t
        ]
        
        process!(engine, samples)
        
        # With large min distance, fewer peaks should be found (distance filtering works)
        detector_wide = PeakDetector(min_peak_distance=200.0, snr_threshold=10.0)
        peaks_wide = detect_peaks!(detector_wide, engine)
        
        # With small min distance, more peaks may be found
        detector_narrow = PeakDetector(min_peak_distance=10.0, snr_threshold=10.0)
        peaks_narrow = detect_peaks!(detector_narrow, engine)
        
        # The wide detector should find fewer or equal peaks than the narrow one
        @test length(peaks_wide) <= length(peaks_narrow)
        
        # With large distance, the strongest peak should suppress nearby peaks
        if !isempty(peaks_wide)
            @test peaks_wide[1].frequency ≈ freq1 atol=10.0
        end
        
        # With small distance, should be able to find both frequencies
        if length(peaks_narrow) >= 2
            peak_freqs = peak_frequencies(peaks_narrow)
            found_1000 = any(f -> abs(f - freq1) < 15.0, peak_freqs)
            found_1100 = any(f -> abs(f - freq2) < 15.0, peak_freqs)
            @test found_1000 || found_1100
        end
    end
    
    @testset "Peak detection - frequency range filtering" begin
        sr = 44100
        nfft = 2048
        
        freq_low = 200.0
        freq_high = 5000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[
            1.0 * sin(2π * freq_low * ti) +
            0.8 * sin(2π * freq_high * ti)
            for ti in t
        ]
        
        process!(engine, samples)
        
        # Filter to only high frequencies
        detector = PeakDetector(min_freq=1000.0, snr_threshold=3.0)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) >= 1
        # All peaks should be above 1000 Hz
        @test all(p -> p.frequency >= 1000.0f0, peaks)
    end
    
    @testset "Peak detection - max peaks limit" begin
        sr = 44100
        nfft = 2048
        
        # Multi-frequency signal
        freqs = [200.0, 400.0, 600.0, 800.0, 1000.0, 1200.0, 1400.0, 1600.0]
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[
            sum(sin(2π * f * ti) for f in freqs)
            for ti in t
        ]
        
        process!(engine, samples)
        
        detector = PeakDetector(max_peaks=3, snr_threshold=3.0, min_peak_distance=50.0)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) <= 3
    end
    
    @testset "Peak detection - no interpolation" begin
        sr = 44100
        nfft = 2048
        freq = 1000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        detector = PeakDetector(use_interpolation=false, snr_threshold=5.0)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) >= 1
        # Without interpolation, offset should be 0
        @test peaks[1].bin_offset == 0.0f0
    end
    
    @testset "Peak detection - empty signal" begin
        sr = 44100
        nfft = 512
        
        engine = FFTEngine(nfft, sr)
        samples = zeros(Float32, nfft)
        
        process!(engine, samples)
        
        detector = PeakDetector(snr_threshold=1.0)
        peaks = detect_peaks!(detector, engine)
        
        @test isempty(peaks)
        @test !has_peaks(peaks)
        @test num_peaks(peaks) == 0
    end
    
    @testset "find_peak convenience function" begin
        sr = 44100
        nfft = 4096
        freq = 1000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        detector = PeakDetector(snr_threshold=5.0)
        peak = find_peak(detector, engine)
        
        @test peak !== nothing
        @test peak isa Peak
        @test peak.frequency ≈ freq atol=2.0
    end
    
    @testset "detect_peaks convenience function" begin
        sr = 44100
        nfft = 2048
        freq = 1000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        peaks = detect_peaks(engine; snr_threshold=5.0, max_peaks=5)
        
        @test length(peaks) >= 1
        @test peaks isa Vector{Peak}
    end
    
    @testset "Peak helper functions" begin
        peaks = [
            Peak(440.0, 10.0, 20, 0.1, 0.95, 25.0),
            Peak(880.0, 8.0, 40, 0.05, 0.90, 22.0),
            Peak(1320.0, 5.0, 60, -0.1, 0.80, 18.0),
            Peak(1760.0, 3.0, 80, 0.0, 0.70, 15.0)
        ]
        
        @testset "peak_frequencies" begin
            freqs = peak_frequencies(peaks)
            @test freqs == Float32[440.0, 880.0, 1320.0, 1760.0]
        end
        
        @testset "peak_magnitudes" begin
            mags = peak_magnitudes(peaks)
            @test mags == Float32[10.0, 8.0, 5.0, 3.0]
        end
        
        @testset "peak_bins" begin
            bins = peak_bins(peaks)
            @test bins == [20, 40, 60, 80]
        end
        
        @testset "filter_by_confidence" begin
            high_conf = filter_by_confidence(peaks, 0.85)
            @test length(high_conf) == 2
            @test high_conf[1].frequency == 440.0f0
            @test high_conf[2].frequency == 880.0f0
        end
        
        @testset "filter_by_snr" begin
            high_snr = filter_by_snr(peaks, 20.0)
            @test length(high_snr) == 2
        end
        
        @testset "top_peaks" begin
            top2 = top_peaks(peaks, 2)
            @test length(top2) == 2
            @test top2[1].frequency == 440.0f0
            @test top2[2].frequency == 880.0f0
        end
        
        @testset "peaks_to_matrix" begin
            mat = peaks_to_matrix(peaks)
            @test size(mat) == (4, 6)
            @test mat[1, 1] == 440.0f0  # First peak frequency
            @test mat[1, 2] == 10.0f0   # First peak magnitude
        end
    end
    
    @testset "Temporal peak tracking" begin
        
        @testset "Basic tracking" begin
            detector = PeakDetector()
            
            # Frame 1: peaks at 440 and 880
            peaks1 = [
                Peak(440.0, 10.0, 20, 0.1, 0.95, 25.0, 1),
                Peak(880.0, 8.0, 40, 0.05, 0.90, 22.0, 1)
            ]
            
            tracked1 = track_peaks!(detector, peaks1; freq_tolerance=20.0)
            @test length(tracked1) == 2
            
            # Frame 2: same peaks with slight drift
            peaks2 = [
                Peak(441.0, 9.5, 20, 0.1, 0.94, 24.0, 2),
                Peak(879.0, 7.8, 40, 0.05, 0.89, 21.0, 2)
            ]
            
            tracked2 = track_peaks!(detector, peaks2; freq_tolerance=20.0)
            @test length(tracked2) == 2
        end
        
        @testset "Tracking with disappearance" begin
            detector = PeakDetector()
            
            # Frame 1: one peak
            peaks1 = [Peak(440.0, 10.0, 20, 0.1, 0.95, 25.0, 1)]
            tracked1 = track_peaks!(detector, peaks1)
            @test length(tracked1) == 1
            
            # Frame 2: peak is gone
            peaks2 = Peak[]
            tracked2 = track_peaks!(detector, peaks2)
            @test isempty(tracked2)
        end
        
        @testset "Reset detector" begin
            detector = PeakDetector()
            detector.frame_counter = 5
            detector.prev_peaks = [Peak(440.0, 10.0, 20, 0.1, 0.95, 25.0, 1)]
            
            reset!(detector)
            
            @test detector.frame_counter == 0
            @test isempty(detector.prev_peaks)
        end
    end
    
    @testset "Peak detection from raw vectors" begin
        # Create a simple magnitude spectrum with a clear peak
        freq_bins = Float32[0.0, 43.0, 86.0, 129.0, 172.0, 215.0]
        mags = Float32[0.1, 0.2, 5.0, 0.3, 0.1, 0.1]
        df = 43.0f0
        
        detector = PeakDetector(snr_threshold=1.0, exclude_dc=false)
        peaks = detect_peaks!(detector, mags, freq_bins, df)
        
        @test length(peaks) >= 1
        @test peaks[1].frequency ≈ 86.0f0 atol=5.0f0
    end
    
    @testset "Integration with FFTEngine" begin
        sr = 44100
        nfft = 2048
        
        # Complex signal
        freqs = [440.0, 880.0, 1320.0]
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[
            sum(sin(2π * f * ti) for f in freqs)
            for ti in t
        ]
        
        process!(engine, samples)
        
        # Use the new peak detection
        detector = PeakDetector(snr_threshold=3.0, min_peak_distance=100.0)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) >= 2
        
        # Verify peaks are sorted by magnitude
        for i in 2:length(peaks)
            @test peaks[i-1].magnitude >= peaks[i].magnitude
        end
        
        # Verify all peaks have valid properties
        for peak in peaks
            @test peak.frequency > 0.0f0
            @test peak.magnitude > 0.0f0
            @test peak.confidence > 0.0f0
            @test peak.snr_db > 0.0f0
        end
    end
    
    @testset "Sub-bin accuracy" begin
        sr = 44100
        nfft = 4096
        
        # Frequency that doesn't align exactly with a bin
        # With nfft=4096 and sr=44100, bin spacing is ~10.77 Hz
        # 1000 Hz is between bins 93 (1001.0 Hz) and 92 (990.2 Hz)
        freq = 1000.0
        
        engine = FFTEngine(nfft, sr; window_type=HannWindow())
        t = [i / sr for i in 0:(nfft - 1)]
        samples = Float32[sin(2π * freq * ti) for ti in t]
        
        process!(engine, samples)
        
        detector = PeakDetector(snr_threshold=3.0, use_interpolation=true)
        peaks = detect_peaks!(detector, engine)
        
        @test length(peaks) >= 1
        
        peak = peaks[1]
        
        # With interpolation, frequency should be very close to true frequency
        @test peak.frequency ≈ freq atol=2.0
        
        # Bin offset should be non-zero for off-bin frequencies
        @test abs(peak.bin_offset) < 0.5f0
    end
    
end
