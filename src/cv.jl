# ------------------------------------------------------------------------------
# Phase 8: CV Output via Audio Interface DC Coupling
# ------------------------------------------------------------------------------
#
# Generates control voltage (CV) signals for modular synthesizers through
# DC-coupled audio interfaces. Converts detected frequencies, pitches, and
# envelopes into analog voltages using the 1V/octave standard.
#
# Features:
# - Multi-channel CV output via PortAudio
# - 1V/octave pitch CV generation
# - Gate/trigger output for note on/off
# - Velocity/expression CV
# - Smooth portamento/glide between notes
# - Configurable voltage scaling for different audio interfaces
# - Integration with HarmonicSeries and Peak detection pipeline
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Constants and Configuration
# ------------------------------------------------------------------------------

"""Standard voltage ranges for modular synthesizer CV.

Fields:
- bipolar_5v: ±5V range (Eurorack standard)
- bipolar_10v: ±10V range (some interfaces)
- unipolar_10v: 0 to +10V range
- unipolar_5v: 0 to +5V range
"""
struct VoltageRange
    min_v::Float32
    max_v::Float32
end

const BIPOLAR_5V = VoltageRange(-5.0f0, 5.0f0)
const BIPOLAR_10V = VoltageRange(-10.0f0, 10.0f0)
const UNIPOLAR_10V = VoltageRange(0.0f0, 10.0f0)
const UNIPOLAR_5V = VoltageRange(0.0f0, 5.0f0)

"""CV channel types.

- PitchCV: 1V/octave pitch control
- GateCV: Gate signal (high = note on, low = note off)
- TriggerCV: Short trigger pulse
- VelocityCV: Velocity/expression level
- ModulationCV: Generic modulation source
"""
abstract type CVChannelType end
struct PitchCV <: CVChannelType end
struct GateCV <: CVChannelType end
struct TriggerCV <: CVChannelType end
struct VelocityCV <: CVChannelType end
struct ModulationCV <: CVChannelType end

"""Configuration for a single CV output channel.

Fields:
- channel_type: Type of CV signal to generate
- voltage_range: Output voltage range
- scale: Additional scaling factor (default: 1.0)
- offset: Voltage offset (default: 0.0)
- portamento_time: Glide time in seconds (default: 0.0 = no glide)
- midi_reference: MIDI note that corresponds to 0V (default: 0 = C-1)
"""
mutable struct CVChannelConfig
    channel_type::CVChannelType
    voltage_range::VoltageRange
    scale::Float32
    offset::Float32
    portamento_time::Float32
    midi_reference::Int
    
    function CVChannelConfig(;
        channel_type::CVChannelType=PitchCV(),
        voltage_range::VoltageRange=BIPOLAR_5V,
        scale::Real=1.0f0,
        offset::Real=0.0f0,
        portamento_time::Real=0.0f0,
        midi_reference::Int=0
    )
        new(
            channel_type,
            voltage_range,
            Float32(scale),
            Float32(offset),
            Float32(portamento_time),
            midi_reference
        )
    end
end

function Base.show(io::IO, config::CVChannelConfig)
    type_name = string(typeof(config.channel_type))
    print(io, "CVChannelConfig(type=$type_name, ")
    print(io, "range=[$(config.voltage_range.min_v)V-$(config.voltage_range.max_v)V], ")
    print(io, "scale=$(config.scale), offset=$(config.offset)V, ")
    print(io, "portamento=$(config.portamento_time)s)")
end

"""CV output configuration.

Fields:
- sample_rate: Output sample rate
- buffer_size: Output buffer size
- channels: Number of output channels
- channel_configs: Configuration for each channel
- voltage_scale: Interface scaling (volts per full-scale, default: 5.0)
- default_gate_voltage: Gate high voltage level
- trigger_duration: Trigger pulse duration in seconds
"""
mutable struct CVOutputConfig
    sample_rate::Int
    buffer_size::Int
    channels::Int
    channel_configs::Vector{CVChannelConfig}
    voltage_scale::Float32
    default_gate_voltage::Float32
    trigger_duration::Float32
    
    function CVOutputConfig(;
        sample_rate::Int=44100,
        buffer_size::Int=256,
        channels::Int=2,
        channel_configs::Union{Vector{CVChannelConfig}, Nothing}=nothing,
        voltage_scale::Real=5.0f0,
        default_gate_voltage::Real=5.0f0,
        trigger_duration::Real=0.01f0
    )
        if channel_configs === nothing
            # Default: channel 1 = pitch, channel 2 = gate
            channel_configs = [
                CVChannelConfig(channel_type=PitchCV()),
                CVChannelConfig(channel_type=GateCV())
            ]
        end
        
        new(
            sample_rate,
            buffer_size,
            channels,
            channel_configs,
            Float32(voltage_scale),
            Float32(default_gate_voltage),
            Float32(trigger_duration)
        )
    end
end

function Base.show(io::IO, config::CVOutputConfig)
    print(io, "CVOutputConfig(sr=$(config.sample_rate), ")
    print(io, "buf=$(config.buffer_size), ")
    print(io, "ch=$(config.channels), ")
    print(io, "vscale=$(config.voltage_scale)V, ")
    print(io, "gate=$(config.default_gate_voltage)V)")
end

# ------------------------------------------------------------------------------
# Voltage Conversion Functions
# ------------------------------------------------------------------------------

"""Convert MIDI note number to voltage using 1V/octave standard.

Parameters:
- midi_note: MIDI note number (0-127)
- config: CVChannelConfig with midi_reference and scale

Returns: Voltage in volts."""
function midi_to_voltage(midi_note::Real, config::CVChannelConfig)::Float32
    # 1V/octave: each semitone = 1/12 volt
    # Reference: midi_reference note = 0V
    volts = (Float32(midi_note) - config.midi_reference) / 12.0f0
    return volts * config.scale + config.offset
end

"""Convert frequency to voltage using 1V/octave standard.

Parameters:
- freq: Frequency in Hz
- config: CVChannelConfig with midi_reference and scale

Returns: Voltage in volts."""
function freq_to_voltage(freq::Real, config::CVChannelConfig)::Float32
    if freq <= 0
        return config.offset
    end
    midi = freq_to_midi(freq)
    return midi_to_voltage(midi, config)
end

"""Normalize voltage to audio interface full-scale range.

Converts volts to normalized sample values (-1.0 to 1.0 range).

Parameters:
- voltage: Voltage in volts
- voltage_scale: Full-scale voltage (e.g., 5.0 for ±5V interface)

Returns: Normalized sample value."""
function voltage_to_sample(voltage::Real, voltage_scale::Real)::Float32
    return clamp(Float32(voltage) / Float32(voltage_scale), -1.0f0, 1.0f0)
end

"""Convert normalized sample back to voltage.

Parameters:
- sample: Normalized sample value (-1.0 to 1.0)
- voltage_scale: Full-scale voltage

Returns: Voltage in volts."""
function sample_to_voltage(sample::Real, voltage_scale::Real)::Float32
    return Float32(sample) * Float32(voltage_scale)
end

"""Clamp voltage to a specific range.

Parameters:
- voltage: Input voltage
- range: VoltageRange to clamp to

Returns: Clamped voltage."""
function clamp_voltage(voltage::Real, range::VoltageRange)::Float32
    return clamp(Float32(voltage), range.min_v, range.max_v)
end

# ------------------------------------------------------------------------------
# CV Signal Generation
# ------------------------------------------------------------------------------

"""Represents a CV signal state for a single channel.

Tracks current voltage, target voltage, and portamento state."""
mutable struct CVSignalState
    current_voltage::Float32
    target_voltage::Float32
    gate_active::Bool
    trigger_active::Bool
    trigger_samples_remaining::Int
    portamento_rate::Float32
end

function CVSignalState()
    return CVSignalState(
        0.0f0,   # current_voltage
        0.0f0,   # target_voltage
        false,   # gate_active
        false,   # trigger_active
        0,       # trigger_samples_remaining
        0.0f0    # portamento_rate
    )
end

"""Update signal state with new target voltage.

Parameters:
- state: Current signal state
- target_voltage: New target voltage
- gate: Whether gate should be active
- config: Channel configuration for portamento
- sample_rate: Sample rate for portamento calculation

Returns: Updated state."""
function update_signal!(state::CVSignalState, target_voltage::Real, gate::Bool,
                        config::CVChannelConfig, sample_rate::Int)::CVSignalState
    state.target_voltage = Float32(target_voltage)
    state.gate_active = gate
    
    # Calculate portamento rate (volts per sample)
    if config.portamento_time > 0.0f0 && sample_rate > 0
        state.portamento_rate = abs(state.target_voltage - state.current_voltage) / 
                                (config.portamento_time * sample_rate)
    else
        state.portamento_rate = Inf32  # Instant change
    end
    
    return state
end

"""Generate one sample of CV signal.

Parameters:
- state: Current signal state
- config: Channel configuration

Returns: Normalized sample value for this sample."""
function generate_sample(state::CVSignalState, config::CVChannelConfig,
                         cv_config::CVOutputConfig)::Float32
    voltage = 0.0f0
    
    if config.channel_type isa PitchCV
        # Apply portamento
        if state.portamento_rate == Inf32
            state.current_voltage = state.target_voltage
        else
            diff = state.target_voltage - state.current_voltage
            if abs(diff) <= state.portamento_rate
                state.current_voltage = state.target_voltage
            else
                state.current_voltage += sign(diff) * state.portamento_rate
            end
        end
        voltage = state.current_voltage
        
    elseif config.channel_type isa GateCV
        voltage = state.gate_active ? cv_config.default_gate_voltage : 0.0f0
        
    elseif config.channel_type isa TriggerCV
        if state.trigger_active
            if state.trigger_samples_remaining > 0
                voltage = cv_config.default_gate_voltage
                state.trigger_samples_remaining -= 1
            else
                state.trigger_active = false
                voltage = 0.0f0
            end
        else
            voltage = 0.0f0
        end
        
    elseif config.channel_type isa VelocityCV
        # Velocity is a sustained level while gate is active
        if state.gate_active
            voltage = state.target_voltage
        else
            voltage = 0.0f0
        end
        
    elseif config.channel_type isa ModulationCV
        voltage = state.current_voltage
    end
    
    # Clamp to voltage range and convert to sample
    voltage = clamp_voltage(voltage, config.voltage_range)
    return voltage_to_sample(voltage, cv_config.voltage_scale)
end

"""Trigger a trigger pulse on the given state.

Parameters:
- state: Signal state to trigger
- cv_config: CV output configuration for trigger duration"""
function trigger!(state::CVSignalState, cv_config::CVOutputConfig)
    state.trigger_active = true
    state.trigger_samples_remaining = round(Int, cv_config.trigger_duration * cv_config.sample_rate)
    return state
end

# ------------------------------------------------------------------------------
# CV Output Engine
# ------------------------------------------------------------------------------

"""Main CV output engine.

Manages PortAudio output stream and generates real-time CV signals.

Fields:
- stream: PortAudio output stream
- config: CVOutputConfig
- signal_states: Current state for each channel
- running: Whether output is active
- task: Background output task
"""
mutable struct CVOutput
    stream::Union{PortAudioStream, Nothing}
    config::CVOutputConfig
    signal_states::Vector{CVSignalState}
    running::Bool
    task::Union{Task, Nothing}
    device::Union{PortAudio.PortAudioDevice, Nothing}
end

"""Create a CVOutput without opening a stream (for testing/sequencing).

Use this when you want to generate CV samples manually without hardware."""
function CVOutput(config::CVOutputConfig=CVOutputConfig())
    states = [CVSignalState() for _ in 1:config.channels]
    return CVOutput(nothing, config, states, false, nothing, nothing)
end

"""Create a CVOutput with a PortAudio output stream.

Parameters:
- config: CVOutputConfig
- device: PortAudio device (uses default if not specified)

Returns: CVOutput with open stream."""
function CVOutput(config::CVOutputConfig, device::PortAudio.PortAudioDevice)
    # Open output stream
    stream = PortAudioStream(device, 0, config.buffer_size; 
                            samplerate=config.sample_rate, 
                            nchannels=config.channels)
    
    states = [CVSignalState() for _ in 1:config.channels]
    return CVOutput(stream, config, states, false, nothing, device)
end

"""Create a CVOutput with default device."""
function CVOutput(config::CVOutputConfig=CVOutputConfig(); 
                  device::Union{PortAudio.PortAudioDevice, Nothing}=nothing)
    if device === nothing
        devices = PortAudio.devices()
        if isempty(devices)
            error("No audio devices found")
        end
        device = first(devices)
    end
    
    return CVOutput(config, device)
end

function Base.show(io::IO, cv::CVOutput)
    print(io, "CVOutput(")
    print(io, "ch=$(cv.config.channels), ")
    print(io, "sr=$(cv.config.sample_rate), ")
    print(io, "running=$(cv.running), ")
    print(io, "stream=$(cv.stream !== nothing ? "open" : "closed"))")
end

"""Close the CV output stream."""
function Base.close(cv::CVOutput)
    stop!(cv)
    if cv.stream !== nothing
        close(cv.stream)
        cv.stream = nothing
    end
    return cv
end

# ------------------------------------------------------------------------------
# Real-time Output
# ------------------------------------------------------------------------------

"""Start CV output.

Begins generating CV signals and writing to the audio interface.
If no stream is open, this starts in "software" mode (no hardware output)."""
function start!(cv::CVOutput)
    if cv.running
        return cv
    end
    
    cv.running = true
    
    if cv.stream !== nothing
        cv.task = @async begin
            buffer = Matrix{Float32}(undef, cv.config.buffer_size, cv.config.channels)
            
            while cv.running
                try
                    # Generate CV samples for each channel
                    for ch in 1:cv.config.channels
                        config = cv.config.channel_configs[ch]
                        state = cv.signal_states[ch]
                        
                        for i in 1:cv.config.buffer_size
                            buffer[i, ch] = generate_sample(state, config, cv.config)
                        end
                    end
                    
                    # Write to audio interface
                    write(cv.stream, buffer)
                    
                catch e
                    if isa(e, InterruptException)
                        break
                    end
                    @warn "CV output error: $e"
                    sleep(0.001)
                end
            end
        end
    end
    
    return cv
end

"""Stop CV output."""
function stop!(cv::CVOutput)
    if !cv.running
        return cv
    end
    
    cv.running = false
    
    if cv.task !== nothing && !istaskdone(cv.task)
        wait(cv.task)
    end
    
    # Reset all states to zero
    for state in cv.signal_states
        state.current_voltage = 0.0f0
        state.target_voltage = 0.0f0
        state.gate_active = false
        state.trigger_active = false
        state.trigger_samples_remaining = 0
    end
    
    return cv
end

function isrunning(cv::CVOutput)::Bool
    return cv.running
end

"""Get the sample rate."""
function sample_rate(cv::CVOutput)::Int
    return cv.config.sample_rate
end

"""Get the number of channels."""
function channels(cv::CVOutput)::Int
    return cv.config.channels
end

# ------------------------------------------------------------------------------
# CV Control API
# ------------------------------------------------------------------------------

"""Set pitch CV for a channel.

Parameters:
- cv: CVOutput
- frequency: Target frequency in Hz
- channel: Output channel (1-based)
- gate: Whether to activate gate"""
function set_pitch!(cv::CVOutput, frequency::Real; 
                    channel::Int=1, gate::Bool=true)
    if channel < 1 || channel > cv.config.channels
        error("Channel $channel out of range (1-$(cv.config.channels))")
    end
    
    config = cv.config.channel_configs[channel]
    state = cv.signal_states[channel]
    
    voltage = freq_to_voltage(frequency, config)
    update_signal!(state, voltage, gate, config, cv.config.sample_rate)
    
    return cv
end

"""Set pitch CV from MIDI note.

Parameters:
- cv: CVOutput
- midi_note: MIDI note number
- channel: Output channel (1-based)
- gate: Whether to activate gate"""
function set_midi_pitch!(cv::CVOutput, midi_note::Real;
                          channel::Int=1, gate::Bool=true)
    if channel < 1 || channel > cv.config.channels
        error("Channel $channel out of range (1-$(cv.config.channels))")
    end
    
    config = cv.config.channel_configs[channel]
    state = cv.signal_states[channel]
    
    voltage = midi_to_voltage(midi_note, config)
    update_signal!(state, voltage, gate, config, cv.config.sample_rate)
    
    return cv
end

"""Set gate state for a channel.

Parameters:
- cv: CVOutput
- active: Whether gate is active (high)
- channel: Output channel"""
function set_gate!(cv::CVOutput, active::Bool; channel::Int=2)
    if channel < 1 || channel > cv.config.channels
        error("Channel $channel out of range (1-$(cv.config.channels))")
    end
    
    state = cv.signal_states[channel]
    state.gate_active = active
    
    return cv
end

"""Trigger a pulse on a trigger channel.

Parameters:
- cv: CVOutput
- channel: Trigger channel"""
function trigger!(cv::CVOutput; channel::Int=2)
    if channel < 1 || channel > cv.config.channels
        error("Channel $channel out of range (1-$(cv.config.channels))")
    end
    
    trigger!(cv.signal_states[channel], cv.config)
    
    return cv
end

"""Set velocity/expression level.

Parameters:
- cv: CVOutput
- velocity: Velocity level (typically 0-1, mapped to voltage)
- channel: Velocity channel"""
function set_velocity!(cv::CVOutput, velocity::Real; channel::Int=3)
    if channel < 1 || channel > cv.config.channels
        error("Channel $channel out of range (1-$(cv.config.channels))")
    end
    
    config = cv.config.channel_configs[channel]
    state = cv.signal_states[channel]
    
    # Map 0-1 velocity to voltage range
    range = config.voltage_range
    voltage = Float32(velocity) * (range.max_v - range.min_v) + range.min_v
    update_signal!(state, voltage, state.gate_active, config, cv.config.sample_rate)
    
    return cv
end

"""Output a HarmonicSeries as CV.

Sets pitch from fundamental frequency and optionally gate/velocity.

Parameters:
- cv: CVOutput
- series: HarmonicSeries to output
- pitch_channel: Channel for pitch CV
- gate_channel: Channel for gate CV (optional)
- velocity_channel: Channel for velocity CV (optional)"""
function output_series!(cv::CVOutput, series::HarmonicSeries;
                        pitch_channel::Int=1,
                        gate_channel::Union{Int, Nothing}=nothing,
                        velocity_channel::Union{Int, Nothing}=nothing)
    # Set pitch
    set_pitch!(cv, series.fundamental; channel=pitch_channel, gate=true)
    
    # Set gate if channel specified
    if gate_channel !== nothing
        set_gate!(cv, true; channel=gate_channel)
    end
    
    # Set velocity if channel specified
    if velocity_channel !== nothing
        set_velocity!(cv, series.overall_confidence; channel=velocity_channel)
    end
    
    return cv
end

"""Output a Peak as CV.

Sets pitch from peak frequency.

Parameters:
- cv: CVOutput
- peak: Peak to output
- pitch_channel: Channel for pitch CV
- gate_channel: Channel for gate CV (optional)"""
function output_peak!(cv::CVOutput, peak::Peak;
                       pitch_channel::Int=1,
                       gate_channel::Union{Int, Nothing}=nothing)
    set_pitch!(cv, peak.frequency; channel=pitch_channel, gate=true)
    
    if gate_channel !== nothing
        set_gate!(cv, true; channel=gate_channel)
    end
    
    return cv
end

"""Release all gates (note off).

Parameters:
- cv: CVOutput
- gate_channels: Which channels to release (default: all)"""
function release_gates!(cv::CVOutput; gate_channels::Union{Vector{Int}, Nothing}=nothing)
    channels_to_release = gate_channels !== nothing ? gate_channels : 1:cv.config.channels
    
    for ch in channels_to_release
        if ch >= 1 && ch <= cv.config.channels
            cv.signal_states[ch].gate_active = false
        end
    end
    
    return cv
end

"""Reset all CV outputs to zero."""
function reset!(cv::CVOutput)
    for state in cv.signal_states
        state.current_voltage = 0.0f0
        state.target_voltage = 0.0f0
        state.gate_active = false
        state.trigger_active = false
        state.trigger_samples_remaining = 0
    end
    
    return cv
end

# ------------------------------------------------------------------------------
# Software-mode Sample Generation (no hardware)
# ------------------------------------------------------------------------------

"""Generate a buffer of CV samples without hardware output.

Useful for testing, recording CV to files, or driving other software.

Parameters:
- cv: CVOutput
- num_samples: Number of samples to generate

Returns: Matrix of samples (samples × channels)."""
function generate_samples(cv::CVOutput, num_samples::Int)::Matrix{Float32}
    buffer = Matrix{Float32}(undef, num_samples, cv.config.channels)
    
    for ch in 1:cv.config.channels
        config = cv.config.channel_configs[ch]
        state = cv.signal_states[ch]
        
        for i in 1:num_samples
            buffer[i, ch] = generate_sample(state, config, cv.config)
        end
    end
    
    return buffer
end

"""Generate CV samples for a specific frequency over time.

Parameters:
- cv: CVOutput
- frequency: Frequency in Hz
- duration_seconds: Duration in seconds
- channel: Output channel

Returns: Vector of samples."""
function generate_pitch_cv(cv::CVOutput, frequency::Real, duration_seconds::Real;
                            channel::Int=1)::Vector{Float32}
    num_samples = round(Int, duration_seconds * cv.config.sample_rate)
    
    # Set the pitch
    set_pitch!(cv, frequency; channel=channel, gate=true)
    
    # Generate samples
    buffer = generate_samples(cv, num_samples)
    
    return buffer[:, channel]
end

"""Generate a gate signal.

Parameters:
- cv: CVOutput
- active: Whether gate is active
- duration_seconds: Duration in seconds
- channel: Gate channel

Returns: Vector of samples."""
function generate_gate_cv(cv::CVOutput, active::Bool, duration_seconds::Real;
                           channel::Int=2)::Vector{Float32}
    num_samples = round(Int, duration_seconds * cv.config.sample_rate)
    
    set_gate!(cv, active; channel=channel)
    
    buffer = generate_samples(cv, num_samples)
    
    return buffer[:, channel]
end

"""Generate a trigger pulse.

Parameters:
- cv: CVOutput
- channel: Trigger channel
- duration_seconds: Total duration in seconds

Returns: Vector of samples."""
function generate_trigger_cv(cv::CVOutput, duration_seconds::Real;
                              channel::Int=2)::Vector{Float32}
    num_samples = round(Int, duration_seconds * cv.config.sample_rate)
    
    trigger!(cv; channel=channel)
    
    buffer = generate_samples(cv, num_samples)
    
    return buffer[:, channel]
end

# ------------------------------------------------------------------------------
# Convenience Functions
# ------------------------------------------------------------------------------

"""Get current voltage for a channel.

Parameters:
- cv: CVOutput
- channel: Channel number

Returns: Current voltage in volts."""
function current_voltage(cv::CVOutput, channel::Int=1)::Float32
    if channel < 1 || channel > cv.config.channels
        error("Channel $channel out of range")
    end
    
    state = cv.signal_states[channel]
    config = cv.config.channel_configs[channel]
    
    # Calculate current voltage based on channel type
    if config.channel_type isa PitchCV
        return state.current_voltage
    elseif config.channel_type isa GateCV
        return state.gate_active ? cv.config.default_gate_voltage : 0.0f0
    elseif config.channel_type isa VelocityCV
        return state.gate_active ? state.target_voltage : 0.0f0
    else
        return state.current_voltage
    end
end

"""Get all current voltages.

Returns: Vector of voltages for all channels."""
function current_voltages(cv::CVOutput)::Vector{Float32}
    return [current_voltage(cv, ch) for ch in 1:cv.config.channels]
end

"""Check if gate is active on a channel."""
function gate_active(cv::CVOutput, channel::Int=2)::Bool
    if channel < 1 || channel > cv.config.channels
        return false
    end
    return cv.signal_states[channel].gate_active
end

"""Convert voltage to MIDI note (inverse of midi_to_voltage).

Parameters:
- voltage: Voltage in volts
- config: CVChannelConfig with midi_reference

Returns: MIDI note number."""
function voltage_to_midi(voltage::Real, config::CVChannelConfig)::Float32
    normalized = (Float32(voltage) - config.offset) / config.scale
    return normalized * 12.0f0 + config.midi_reference
end

"""Convert voltage to frequency (inverse of freq_to_voltage).

Parameters:
- voltage: Voltage in volts
- config: CVChannelConfig

Returns: Frequency in Hz."""
function voltage_to_freq(voltage::Real, config::CVChannelConfig)::Float32
    midi = voltage_to_midi(voltage, config)
    return midi_to_freq(midi)
end

"""Print current CV state summary."""
function print_cv_state(cv::CVOutput)
    println("CV Output State:")
    println()
    
    for ch in 1:cv.config.channels
        config = cv.config.channel_configs[ch]
        state = cv.signal_states[ch]
        
        type_name = string(typeof(config.channel_type))
        println("  Channel $ch ($type_name):")
        println("    Current: $(round(state.current_voltage, digits=3))V")
        println("    Target:  $(round(state.target_voltage, digits=3))V")
        println("    Gate:    $(state.gate_active)")
        println()
    end
end

# ------------------------------------------------------------------------------
# Integration with Harmonic Tracking Pipeline
# ------------------------------------------------------------------------------

"""Convert a HarmonicSeries to a CV configuration with pitch + gate.

Parameters:
- series: HarmonicSeries to convert
- cv_config: CVOutputConfig
- pitch_channel: Channel for pitch
- gate_channel: Channel for gate

Returns: (pitch_voltage, gate_state) tuple."""
function series_to_cv(series::HarmonicSeries, cv_config::CVOutputConfig;
                       pitch_channel::Int=1)::Tuple{Float32, Bool}
    if pitch_channel < 1 || pitch_channel > length(cv_config.channel_configs)
        return (0.0f0, false)
    end
    
    config = cv_config.channel_configs[pitch_channel]
    voltage = freq_to_voltage(series.fundamental, config)
    
    return (voltage, true)
end

"""Convert a Peak to a CV configuration.

Parameters:
- peak: Peak to convert
- cv_config: CVOutputConfig
- channel: Output channel

Returns: Voltage value."""
function peak_to_cv(peak::Peak, cv_config::CVOutputConfig;
                     channel::Int=1)::Float32
    if channel < 1 || channel > length(cv_config.channel_configs)
        return 0.0f0
    end
    
    config = cv_config.channel_configs[channel]
    return freq_to_voltage(peak.frequency, config)
end

"""Batch convert multiple harmonic series to CV output.

Parameters:
- cv: CVOutput
- series_list: Vector of HarmonicSeries
- max_series: Maximum number of series to output (for multi-channel setups)"""
function output_series_list!(cv::CVOutput, series_list::Vector{HarmonicSeries};
                              max_series::Int=1)
    for (i, series) in enumerate(series_list)
        if i > max_series
            break
        end
        
        ch = min(i, cv.config.channels)
        output_series!(cv, series; pitch_channel=ch)
    end
    
    return cv
end

"""Create a standard Eurorack CV setup.

Standard 2-channel setup: pitch + gate
Standard 3-channel setup: pitch + gate + velocity

Parameters:
- channels: Number of channels (2 or 3)
- sample_rate: Sample rate
- voltage_scale: Interface voltage scale

Returns: CVOutputConfig"""
function eurorack_config(channels::Int=2; 
                         sample_rate::Int=44100,
                         voltage_scale::Real=5.0f0)::CVOutputConfig
    configs = CVChannelConfig[]
    
    # Channel 1: Pitch (1V/octave, bipolar ±5V)
    push!(configs, CVChannelConfig(
        channel_type=PitchCV(),
        voltage_range=BIPOLAR_5V,
        midi_reference=0
    ))
    
    if channels >= 2
        # Channel 2: Gate (unipolar 0-5V)
        push!(configs, CVChannelConfig(
            channel_type=GateCV(),
            voltage_range=UNIPOLAR_5V
        ))
    end
    
    if channels >= 3
        # Channel 3: Velocity (unipolar 0-5V)
        push!(configs, CVChannelConfig(
            channel_type=VelocityCV(),
            voltage_range=UNIPOLAR_5V
        ))
    end
    
    # Fill remaining channels with modulation
    for _ in 4:channels
        push!(configs, CVChannelConfig(
            channel_type=ModulationCV(),
            voltage_range=BIPOLAR_5V
        ))
    end
    
    return CVOutputConfig(
        sample_rate=sample_rate,
        channels=channels,
        channel_configs=configs,
        voltage_scale=voltage_scale
    )
end

"""Create an audio interface test configuration.

Generates a simple ascending voltage sweep for testing DC coupling.

Parameters:
- sample_rate: Sample rate
- voltage_scale: Interface full-scale voltage

Returns: CVOutputConfig suitable for testing"""
function test_cv_config(sample_rate::Int=44100;
                        voltage_scale::Real=5.0f0)::CVOutputConfig
    return CVOutputConfig(
        sample_rate=sample_rate,
        channels=1,
        channel_configs=[
            CVChannelConfig(
                channel_type=ModulationCV(),
                voltage_range=VoltageRange(-Float32(voltage_scale), Float32(voltage_scale))
            )
        ],
        voltage_scale=voltage_scale
    )
end

"""Generate a voltage ramp for testing DC coupling.

Parameters:
- cv: CVOutput
- start_voltage: Starting voltage
- end_voltage: Ending voltage
- duration_seconds: Duration of ramp
- channel: Output channel

Returns: Vector of samples."""
function generate_ramp(cv::CVOutput, start_voltage::Real, end_voltage::Real,
                        duration_seconds::Real; channel::Int=1)::Vector{Float32}
    num_samples = round(Int, duration_seconds * cv.config.sample_rate)
    samples = Vector{Float32}(undef, num_samples)
    
    for i in 1:num_samples
        t = (i - 1) / max(num_samples - 1, 1)
        voltage = Float32(start_voltage) + t * (Float32(end_voltage) - Float32(start_voltage))
        samples[i] = voltage_to_sample(voltage, cv.config.voltage_scale)
    end
    
    return samples
end
