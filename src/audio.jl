using PortAudio

mutable struct AudioCapture
    stream::PortAudioStream
    ringbuffer::RingBuffer{Float32}
    sample_rate::Int
    channels::Int
    buffer_size::Int
    running::Bool
    task::Union{Task, Nothing}
end

function AudioCapture(
    ringbuffer::RingBuffer{Float32};
    sample_rate::Int=44100,
    channels::Int=1,
    buffer_size::Int=1024,
    device::Union{PortAudio.PortAudioDevice, Nothing}=nothing
)
    if device === nothing
        devices = PortAudio.devices()
        if isempty(devices)
            error("No audio devices found")
        end
        device = first(devices)
    end
    
    stream = PortAudioStream(device, buffer_size; samplerate=sample_rate, nchannels=channels)
    
    return AudioCapture(stream, ringbuffer, sample_rate, channels, buffer_size, false, nothing)
end

function start!(cap::AudioCapture)
    if cap.running
        return cap
    end
    
    cap.running = true
    
    cap.task = @async begin
        buffer = Vector{Float32}(undef, cap.buffer_size * cap.channels)
        
        while cap.running
            try
                read!(cap.stream, buffer)
                
                if cap.channels == 1
                    overwrite!(cap.ringbuffer, buffer)
                else
                    # Mix down to mono if stereo
                    mono = Vector{Float32}(undef, cap.buffer_size)
                    for i in 1:cap.buffer_size
                        sample = 0.0f0
                        for ch in 1:cap.channels
                            sample += buffer[(i-1)*cap.channels + ch]
                        end
                        mono[i] = sample / cap.channels
                    end
                    overwrite!(cap.ringbuffer, mono)
                end
            catch e
                if isa(e, InterruptException)
                    break
                end
                @warn "Audio capture error: $e"
                sleep(0.001)
            end
        end
    end
    
    return cap
end

function stop!(cap::AudioCapture)
    if !cap.running
        return cap
    end
    
    cap.running = false
    
    if cap.task !== nothing && !istaskdone(cap.task)
        wait(cap.task)
    end
    
    return cap
end

function Base.close(cap::AudioCapture)
    stop!(cap)
    close(cap.stream)
    return cap
end

function isrunning(cap::AudioCapture)::Bool
    return cap.running
end

function sample_rate(cap::AudioCapture)::Int
    return cap.sample_rate
end

function channels(cap::AudioCapture)::Int
    return cap.channels
end

function buffer_size(cap::AudioCapture)::Int
    return cap.buffer_size
end

function latency_samples(cap::AudioCapture)::Int
    return length(cap.ringbuffer)
end

function latency_ms(cap::AudioCapture)::Float64
    return latency_samples(cap) / cap.sample_rate * 1000.0
end
