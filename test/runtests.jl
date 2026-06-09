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
