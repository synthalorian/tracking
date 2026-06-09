using GLMakie

# ------------------------------------------------------------------------------
# Spectrum Display Configuration
# ------------------------------------------------------------------------------

"""Display scale for frequency axis."""
abstract type FrequencyScale end

"""Linear frequency scale (0 Hz to Nyquist)."""
struct LinearScale <: FrequencyScale end

"""Logarithmic frequency scale (20 Hz to Nyquist)."""
struct LogScale <: FrequencyScale end

"""Display scale for magnitude axis."""
abstract type MagnitudeScale end

"""Linear magnitude scale (raw FFT magnitude)."""
struct LinearMagnitude <: MagnitudeScale end

"""Decibel magnitude scale (20*log10(magnitude))."""
struct DecibelMagnitude <: MagnitudeScale end

"""Configuration for SpectrumDisplay.

Fields:
- freq_scale: Frequency axis scale (LinearScale or LogScale)
- mag_scale: Magnitude axis scale (LinearMagnitude or DecibelMagnitude)
- min_freq: Minimum frequency to display in Hz (for log scale, default 20 Hz)
- max_freq: Maximum frequency to display in Hz (default Nyquist)
- db_range: Dynamic range in dB for decibel display (default 80 dB)
- db_ref: Reference level for dB calculation (default 1.0)
- peak_hold: Whether to show peak hold line (default true)
- peak_decay: Peak decay rate in dB per second (default 20.0)
- refresh_rate: Target display refresh rate in Hz (default 30)
- title: Plot title
"""
mutable struct DisplayConfig
    freq_scale::FrequencyScale
    mag_scale::MagnitudeScale
    min_freq::Float32
    max_freq::Float32
    db_range::Float32
    db_ref::Float32
    peak_hold::Bool
    peak_decay::Float32
    refresh_rate::Float32
    title::String
    
    function DisplayConfig(;
        freq_scale::FrequencyScale=LogScale(),
        mag_scale::MagnitudeScale=DecibelMagnitude(),
        min_freq::Real=20.0,
        max_freq::Real=22050.0,
        db_range::Real=80.0,
        db_ref::Real=1.0,
        peak_hold::Bool=true,
        peak_decay::Real=20.0,
        refresh_rate::Real=30.0,
        title::String="Spectrum Analyzer"
    )
        new(freq_scale, mag_scale, Float32(min_freq), Float32(max_freq),
            Float32(db_range), Float32(db_ref), peak_hold, Float32(peak_decay),
            Float32(refresh_rate), title)
    end
end

# ------------------------------------------------------------------------------
# Spectrum Display
# ------------------------------------------------------------------------------

"""Real-time spectrum display using GLMakie.

Connects to an AudioCapture + FFTEngine pipeline and displays
a continuously updating frequency spectrum.

Fields:
- fig: GLMakie Figure
- ax: Axis for the spectrum plot
- freq_obs: Observable frequency values
- mag_obs: Observable magnitude values  
- peak_obs: Observable peak hold values
- spectrum_line: The main spectrum line plot
- peak_line: The peak hold line plot
- config: DisplayConfig
- running: Whether the display loop is active
- task: The async update task
- peak_buffer: Buffer for peak hold tracking
"""
mutable struct SpectrumDisplay
    fig::Figure
    ax::Axis
    freq_obs::Observable{Vector{Float32}}
    mag_obs::Observable{Vector{Float32}}
    peak_obs::Observable{Vector{Float32}}
    spectrum_line::Any
    peak_line::Any
    config::DisplayConfig
    running::Bool
    task::Union{Task, Nothing}
    peak_buffer::Vector{Float32}
    last_peak_update::Float64
end

"""Create a new SpectrumDisplay with the given configuration.

Parameters:
- config: DisplayConfig (default: logarithmic frequency, dB magnitude)
- engine: Optional FFTEngine to pre-configure frequency bins
"""
function SpectrumDisplay(config::DisplayConfig=DisplayConfig(); engine::Union{FFTEngine, Nothing}=nothing)
    fig = Figure(size=(1000, 600))
    
    ax = Axis(
        fig[1, 1],
        title=config.title,
        xlabel="Frequency (Hz)",
        ylabel=config.mag_scale isa DecibelMagnitude ? "Magnitude (dB)" : "Magnitude",
        xscale=config.freq_scale isa LogScale ? log10 : identity,
        xminorticksvisible=true,
        xminorgridvisible=true,
        yminorgridvisible=true
    )
    
    # Set frequency limits
    xlims!(ax, config.min_freq, config.max_freq)
    
    # Set magnitude limits based on scale
    if config.mag_scale isa DecibelMagnitude
        ylims!(ax, -config.db_range, 0.0)
    else
        ylims!(ax, 0.0, 10.0)
    end
    
    # Initialize with empty data
    if engine !== nothing
        freqs = frequency_bins(engine)
        # Filter to display range
        mask = freqs .>= config.min_freq .&& freqs .<= config.max_freq
        freq_data = freqs[mask]
        n = length(freq_data)
    else
        freq_data = Float32[]
        n = 0
    end
    
    mag_data = zeros(Float32, n)
    peak_data = fill(Float32(-Inf), n)
    
    freq_obs = Observable(freq_data)
    mag_obs = Observable(mag_data)
    peak_obs = Observable(peak_data)
    
    # Create plots
    spectrum_line = lines!(ax, freq_obs, mag_obs, color=:cyan, linewidth=1.5)
    
    peak_line = nothing
    if config.peak_hold
        peak_line = lines!(ax, freq_obs, peak_obs, color=:yellow, linewidth=1.0, linestyle=:dot)
    end
    
    # Add grid styling
    ax.xgridstyle = :dash
    ax.ygridstyle = :dash
    
    return SpectrumDisplay(
        fig, ax, freq_obs, mag_obs, peak_obs,
        spectrum_line, peak_line, config, false, nothing,
        copy(peak_data), time()
    )
end

"""Convert magnitude to display units based on config."""
function _to_display_scale(mag::Float32, config::DisplayConfig)::Float32
    if config.mag_scale isa DecibelMagnitude
        # Avoid log(0) by clamping to a small positive value
        clamped = max(mag, 1.0f-10)
        return 20.0f0 * log10(clamped / config.db_ref)
    else
        return mag
    end
end

"""Convert magnitude vector to display units."""
function _to_display_scale(mags::Vector{Float32}, config::DisplayConfig)::Vector{Float32}
    return [_to_display_scale(m, config) for m in mags]
end

"""Update peak hold buffer with decay.

Peaks decay over time at config.peak_decay dB/second.
"""
function _update_peaks!(display::SpectrumDisplay, current_mags::Vector{Float32})
    config = display.config
    now = time()
    dt = Float32(now - display.last_peak_update)
    display.last_peak_update = now
    
    if config.mag_scale isa DecibelMagnitude
        # Decay in dB domain
        decay_amount = config.peak_decay * dt
        @inbounds for i in eachindex(display.peak_buffer)
            # Decay old peaks
            display.peak_buffer[i] -= decay_amount
            # Update with new peak if higher
            if current_mags[i] > display.peak_buffer[i]
                display.peak_buffer[i] = current_mags[i]
            end
        end
    else
        # Decay in linear domain (simpler: just let peaks fall)
        @inbounds for i in eachindex(display.peak_buffer)
            display.peak_buffer[i] *= exp(-5.0f0 * dt)
            if current_mags[i] > display.peak_buffer[i]
                display.peak_buffer[i] = current_mags[i]
            end
        end
    end
    
    display.peak_obs[] = copy(display.peak_buffer)
    return display
end

"""Update the display with new spectrum data.

Parameters:
- display: SpectrumDisplay to update
- engine: FFTEngine with computed FFT (must have called process! first)
- freqs: Optional frequency values (uses engine.freq_bins if not provided)
- mags: Optional magnitude values (uses magnitude_spectrum if not provided)
"""
function update!(display::SpectrumDisplay, engine::FFTEngine;
    freqs::Union{Vector{Float32}, Nothing}=nothing,
    mags::Union{Vector{Float32}, Nothing}=nothing
)
    # Get frequency bins
    if freqs === nothing
        freqs = frequency_bins(engine)
    end
    
    # Get magnitudes
    if mags === nothing
        mags = magnitude_spectrum(engine; corrected=true)
    end
    
    config = display.config
    
    # Filter to display range
    mask = freqs .>= config.min_freq .&& freqs .<= config.max_freq
    display_freqs = freqs[mask]
    display_mags = mags[mask]
    
    # Convert to display scale
    display_mags_db = _to_display_scale(display_mags, config)
    
    # Update observables (triggers Makie redraw)
    display.freq_obs[] = display_freqs
    display.mag_obs[] = display_mags_db
    
    # Update peak hold
    if config.peak_hold
        _update_peaks!(display, display_mags_db)
    end
    
    return display
end

"""Start the real-time display loop.

The display loop continuously reads from the audio ringbuffer,
computes FFT, and updates the plot.

Parameters:
- display: SpectrumDisplay
- capture: AudioCapture (source of audio samples)
- engine: FFTEngine (FFT processor)
"""
function start!(display::SpectrumDisplay, capture::AudioCapture, engine::FFTEngine)
    if display.running
        return display
    end
    
    display.running = true
    
    # Pre-configure frequency bins if not already set
    if isempty(display.freq_obs[])
        freqs = frequency_bins(engine)
        config = display.config
        mask = freqs .>= config.min_freq .&& freqs .<= config.max_freq
        display.freq_obs[] = freqs[mask]
        n = length(freqs[mask])
        display.mag_obs[] = zeros(Float32, n)
        if config.peak_hold
            display.peak_obs[] = fill(Float32(-Inf), n)
            display.peak_buffer = fill(Float32(-Inf), n)
        end
    end
    
    # Show the figure window
    display_figure(display)
    
    refresh_interval = 1.0 / display.config.refresh_rate
    
    display.task = @async begin
        while display.running
            try
                # Check if we have enough samples
                if length(capture.ringbuffer) >= engine.nfft
                    # Read latest samples from ringbuffer
                    spectrum = process!(engine, capture.ringbuffer)
                    
                    # Update the display
                    update!(display, engine)
                end
                
                sleep(refresh_interval)
            catch e
                if isa(e, InterruptException)
                    break
                end
                @warn "Spectrum display error: $e"
                sleep(0.1)
            end
        end
    end
    
    return display
end

"""Start the display with a manual update loop.

Use this when you want to control the update yourself.
Call update!() in your own loop.

Parameters:
- display: SpectrumDisplay
"""
function start!(display::SpectrumDisplay)
    if display.running
        return display
    end
    
    display.running = true
    display_figure(display)
    
    return display
end

"""Stop the real-time display loop."""
function stop!(display::SpectrumDisplay)
    if !display.running
        return display
    end
    
    display.running = false
    
    if display.task !== nothing && !istaskdone(display.task)
        wait(display.task)
    end
    
    return display
end

"""Check if the display loop is running."""
function isrunning(display::SpectrumDisplay)::Bool
    return display.running
end

"""Display/show the figure window."""
function display_figure(display::SpectrumDisplay)
    Base.display(display.fig)
    return display
end

"""Get the current frequency data."""
function frequency_data(display::SpectrumDisplay)::Vector{Float32}
    return display.freq_obs[]
end

"""Get the current magnitude data."""
function magnitude_data(display::SpectrumDisplay)::Vector{Float32}
    return display.mag_obs[]
end

"""Get the current peak hold data."""
function peak_data(display::SpectrumDisplay)::Vector{Float32}
    return display.peak_obs[]
end

"""Reset peak hold values."""
function reset_peaks!(display::SpectrumDisplay)
    fill!(display.peak_buffer, Float32(-Inf))
    display.peak_obs[] = copy(display.peak_buffer)
    display.last_peak_update = time()
    return display
end

"""Set frequency axis limits."""
function set_freq_limits!(display::SpectrumDisplay, min_freq::Real, max_freq::Real)
    display.config.min_freq = Float32(min_freq)
    display.config.max_freq = Float32(max_freq)
    xlims!(display.ax, min_freq, max_freq)
    return display
end

"""Set magnitude axis limits (for dB scale: min_db is typically negative)."""
function set_mag_limits!(display::SpectrumDisplay, min_mag::Real, max_mag::Real)
    ylims!(display.ax, min_mag, max_mag)
    return display
end

"""Set display title."""
function set_title!(display::SpectrumDisplay, title::String)
    display.config.title = title
    display.ax.title = title
    return display
end

"""Take a single screenshot of the current display.

Returns the Makie `Scene` which can be saved with FileIO.save().
"""
function screenshot(display::SpectrumDisplay)
    return display.fig.scene
end

function Base.show(io::IO, display::SpectrumDisplay)
    print(io, "SpectrumDisplay(")
    print(io, "freq_scale=$(typeof(display.config.freq_scale).name.name), ")
    print(io, "mag_scale=$(typeof(display.config.mag_scale).name.name), ")
    print(io, "refresh=$(display.config.refresh_rate)Hz, ")
    print(io, "running=$(display.running))")
end

# ------------------------------------------------------------------------------
# Convenience constructors
# ------------------------------------------------------------------------------

"""Create a standard spectrum display with default settings.

Parameters:
- engine: Optional FFTEngine for frequency bin configuration
"""
function SpectrumDisplay(engine::FFTEngine)
    return SpectrumDisplay(DisplayConfig(), engine=engine)
end

"""Create a spectrum display with linear frequency scale."""
function LinearSpectrumDisplay(engine::Union{FFTEngine, Nothing}=nothing)
    config = DisplayConfig(freq_scale=LinearScale(), mag_scale=DecibelMagnitude())
    return SpectrumDisplay(config, engine=engine)
end

"""Create a spectrum display with logarithmic frequency scale (default)."""
function LogSpectrumDisplay(engine::Union{FFTEngine, Nothing}=nothing)
    config = DisplayConfig(freq_scale=LogScale(), mag_scale=DecibelMagnitude())
    return SpectrumDisplay(config, engine=engine)
end
