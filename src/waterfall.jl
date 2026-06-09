using GLMakie

# ------------------------------------------------------------------------------
# Waterfall / Spectrogram Display
# ------------------------------------------------------------------------------

"""Configuration for WaterfallDisplay.

Fields:
- time_history: Number of FFT frames to show vertically (time history)
- min_freq: Minimum frequency to display in Hz
- max_freq: Maximum frequency to display in Hz  
- db_range: Dynamic range in dB for color mapping
- db_ref: Reference level for dB calculation
- refresh_rate: Target display refresh rate in Hz
- colormap: Makie colormap for spectrogram (default :viridis)
- title: Plot title
"""
mutable struct WaterfallConfig
    time_history::Int
    min_freq::Float32
    max_freq::Float32
    db_range::Float32
    db_ref::Float32
    refresh_rate::Float32
    colormap::Symbol
    title::String
    
    function WaterfallConfig(;
        time_history::Int=100,
        min_freq::Real=20.0,
        max_freq::Real=22050.0,
        db_range::Real=80.0,
        db_ref::Real=1.0,
        refresh_rate::Real=30.0,
        colormap::Symbol=:viridis,
        title::String="Spectrogram"
    )
        new(time_history, Float32(min_freq), Float32(max_freq),
            Float32(db_range), Float32(db_ref), Float32(refresh_rate),
            colormap, title)
    end
end

"""Real-time waterfall/spectrogram display using GLMakie.

Shows a time-frequency heatmap where:
- X-axis: Frequency (Hz)
- Y-axis: Time (recent frames at top)
- Color: Magnitude (dB)

Fields:
- fig: GLMakie Figure
- ax: Axis for the heatmap
- heatmap_plot: The heatmap itself
- spectrogram_data: Observable 2D matrix (freq x time)
- freqs: Frequency bin values
- config: WaterfallConfig
- running: Whether the display loop is active
- task: The async update task
- frame_count: Counter for tracking update rate
- last_update: Timestamp of last update
"""
mutable struct WaterfallDisplay
    fig::Figure
    ax::Axis
    heatmap_plot::Any
    spectrogram_data::Observable{Matrix{Float32}}
    freqs::Vector{Float32}
    freq_mask::BitVector  # Mask for filtering magnitude spectrum to display range
    config::WaterfallConfig
    running::Bool
    task::Union{Task, Nothing}
    frame_count::Int
    last_update::Float64
end

"""Create a new WaterfallDisplay with the given configuration.

Parameters:
- config: WaterfallConfig
- engine: FFTEngine to configure frequency bins
"""
function WaterfallDisplay(config::WaterfallConfig, engine::FFTEngine)
    fig = Figure(size=(1000, 600))
    
    ax = Axis(
        fig[1, 1],
        title=config.title,
        xlabel="Frequency (Hz)",
        ylabel="Time",
        xminorticksvisible=true,
        xminorgridvisible=false
    )
    
    # Get frequency bins and filter to display range
    all_freqs = frequency_bins(engine)
    mask = all_freqs .>= config.min_freq .&& all_freqs .<= config.max_freq
    freqs = all_freqs[mask]
    n_freqs = length(freqs)
    
    # Initialize spectrogram data matrix (freq bins x time history)
    # Rows = frequency, Cols = time frames
    # Most recent time at the top (last column)
    init_data = fill(Float32(-config.db_range), n_freqs, config.time_history)
    
    spectrogram_data = Observable(init_data)
    
    # Create heatmap
    # X = frequency, Y = time index, color = magnitude
    heatmap_plot = heatmap!(ax, freqs, 1:config.time_history, spectrogram_data,
        colormap=config.colormap,
        colorrange=(-config.db_range, 0.0),
        lowclip=:black
    )
    
    # Set frequency limits
    xlims!(ax, config.min_freq, config.max_freq)
    
    # Style the axis
    ax.xgridstyle = :dash
    ax.ygridstyle = :dash
    
    # Hide y-axis ticks (time labels not meaningful in waterfall)
    ax.yticksvisible = false
    ax.ylabelvisible = false
    
    return WaterfallDisplay(
        fig, ax, heatmap_plot, spectrogram_data, freqs, mask,
        config, false, nothing, 0, time()
    )
end

"""Convert magnitude vector to dB for display.

Filters to display frequency range using stored mask and clamps to avoid -Inf.
"""
function _mags_to_spectrogram(mags::Vector{Float32}, display::WaterfallDisplay)::Vector{Float32}
    # Filter to display range using stored mask
    display_mags = mags[display.freq_mask]
    
    # Convert to dB
    db_vals = Float32[
        20.0f0 * log10(max(mag, 1.0f-10) / display.config.db_ref)
        for mag in display_mags
    ]
    
    return db_vals
end

"""Push a new FFT frame into the waterfall display.

Shifts existing data down and puts new frame at the top.
"""
function push_frame!(display::WaterfallDisplay, mags::Vector{Float32})
    # Convert to dB spectrogram values
    db_vals = _mags_to_spectrogram(mags, display)
    
    # Get current data and shift
    current_data = display.spectrogram_data[]
    n_freqs = size(current_data, 1)
    n_time = size(current_data, 2)
    
    # Shift all columns down (older data -> lower indices)
    # Column n_time is newest, column 1 is oldest
    new_data = similar(current_data)
    new_data[:, 1:(n_time-1)] = current_data[:, 2:n_time]
    new_data[:, n_time] = db_vals
    
    display.spectrogram_data[] = new_data
    display.frame_count += 1
    
    return display
end

"""Update the waterfall display with new spectrum data from an FFTEngine.
"""
function update!(display::WaterfallDisplay, engine::FFTEngine)
    mags = magnitude_spectrum(engine; corrected=true)
    push_frame!(display, mags)
    return display
end

"""Start the real-time waterfall display loop.

Continuously reads from the audio ringbuffer, computes FFT,
and updates the spectrogram heatmap.

Parameters:
- display: WaterfallDisplay
- capture: AudioCapture (source of audio samples)
- engine: FFTEngine (FFT processor)
"""
function start!(display::WaterfallDisplay, capture::AudioCapture, engine::FFTEngine)
    if display.running
        return display
    end
    
    display.running = true
    
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
                    
                    # Update the waterfall
                    update!(display, engine)
                end
                
                sleep(refresh_interval)
            catch e
                if isa(e, InterruptException)
                    break
                end
                @warn "Waterfall display error: $e"
                sleep(0.1)
            end
        end
    end
    
    return display
end

"""Start the display in manual mode (user calls update! themselves).
"""
function start!(display::WaterfallDisplay)
    if display.running
        return display
    end
    
    display.running = true
    display_figure(display)
    
    return display
end

"""Stop the real-time display loop."""
function stop!(display::WaterfallDisplay)
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
function isrunning(display::WaterfallDisplay)::Bool
    return display.running
end

"""Display/show the figure window."""
function display_figure(display::WaterfallDisplay)
    Base.display(display.fig)
    return display
end

"""Get the current spectrogram data matrix."""
function spectrogram_data(display::WaterfallDisplay)::Matrix{Float32}
    return display.spectrogram_data[]
end

"""Get the frequency values."""
function frequency_data(display::WaterfallDisplay)::Vector{Float32}
    return display.freqs
end

"""Get the current frame count."""
function frame_count(display::WaterfallDisplay)::Int
    return display.frame_count
end

"""Reset/clear the spectrogram data."""
function reset!(display::WaterfallDisplay)
    n_freqs = length(display.freqs)
    n_time = display.config.time_history
    display.spectrogram_data[] = fill(Float32(-display.config.db_range), n_freqs, n_time)
    display.frame_count = 0
    return display
end

"""Set frequency axis limits."""
function set_freq_limits!(display::WaterfallDisplay, min_freq::Real, max_freq::Real)
    display.config.min_freq = Float32(min_freq)
    display.config.max_freq = Float32(max_freq)
    xlims!(display.ax, min_freq, max_freq)
    return display
end

"""Set display title."""
function set_title!(display::WaterfallDisplay, title::String)
    display.config.title = title
    display.ax.title = title
    return display
end

"""Take a screenshot of the current display."""
function screenshot(display::WaterfallDisplay)
    return display.fig.scene
end

function Base.show(io::IO, display::WaterfallDisplay)
    print(io, "WaterfallDisplay(")
    print(io, "time_history=$(display.config.time_history), ")
    print(io, "freq_bins=$(length(display.freqs)), ")
    print(io, "refresh=$(display.config.refresh_rate)Hz, ")
    print(io, "frames=$(display.frame_count), ")
    print(io, "running=$(display.running))")
end

# ------------------------------------------------------------------------------
# Convenience constructors
# ------------------------------------------------------------------------------

"""Create a waterfall display with default settings."""
function WaterfallDisplay(engine::FFTEngine; time_history::Int=100)
    config = WaterfallConfig(time_history=time_history)
    return WaterfallDisplay(config, engine)
end
