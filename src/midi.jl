# ------------------------------------------------------------------------------
# Phase 7: MIDI Export of Detected Notes
# ------------------------------------------------------------------------------
#
# Exports detected harmonic series as Standard MIDI Files (SMF).
# Converts fundamental frequencies to MIDI note numbers with velocity
# mapped from detection confidence.
#
# Features:
# - Binary SMF format 0/1 writer (no external MIDI library required)
# - Note velocity from harmonic series confidence/magnitude
# - Configurable tempo, ticks per quarter note, and note duration
# - Batch export of multiple series with temporal spacing
# - Integration with HarmonicSeries and note estimation pipeline
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Data Structures
# ------------------------------------------------------------------------------

"""Represents a single MIDI note event.

Fields:
- pitch: MIDI note number (0-127, 69 = A4 = 440 Hz)
- velocity: Note velocity (0-127, default 100)
- start_time: Start time in MIDI ticks
- duration: Note duration in MIDI ticks
- channel: MIDI channel (0-15, default 0)
"""
struct MIDINote
    pitch::UInt8
    velocity::UInt8
    start_time::UInt32
    duration::UInt32
    channel::UInt8
end

"""Default MIDINote constructor with channel=0."""
function MIDINote(pitch::Int, velocity::Int, start_time::Int, duration::Int)
    return MIDINote(
        UInt8(clamp(pitch, 0, 127)),
        UInt8(clamp(velocity, 0, 127)),
        UInt32(max(0, start_time)),
        UInt32(max(0, duration)),
        UInt8(0)
    )
end

function Base.show(io::IO, note::MIDINote)
    print(io, "MIDINote(pitch=$(note.pitch), vel=$(note.velocity), ")
    print(io, "start=$(note.start_time), dur=$(note.duration), ch=$(note.channel))")
end

"""Configuration for MIDI export.

Fields:
- ticks_per_quarter: Ticks per quarter note (default: 480)
- tempo: Tempo in microseconds per quarter note (default: 500000 = 120 BPM)
- default_velocity: Default note velocity when not derived from confidence (default: 100)
- note_duration: Default note duration in ticks (default: 480 = 1 quarter note)
- min_velocity: Minimum velocity from confidence mapping (default: 40)
- max_velocity: Maximum velocity from confidence mapping (default: 127)
- time_spacing: Time spacing between notes in ticks when exporting multiple series (default: 480)
- format: MIDI file format (0 or 1, default: 0)
"""
mutable struct MIDIExporter
    ticks_per_quarter::Int
    tempo::Int
    default_velocity::Int
    note_duration::Int
    min_velocity::Int
    max_velocity::Int
    time_spacing::Int
    format::Int

    function MIDIExporter(;
        ticks_per_quarter::Int=480,
        tempo::Int=500000,
        default_velocity::Int=100,
        note_duration::Int=480,
        min_velocity::Int=40,
        max_velocity::Int=127,
        time_spacing::Int=480,
        format::Int=0
    )
        new(
            ticks_per_quarter,
            tempo,
            clamp(default_velocity, 0, 127),
            note_duration,
            clamp(min_velocity, 0, 127),
            clamp(max_velocity, 0, 127),
            time_spacing,
            format
        )
    end
end

function Base.show(io::IO, exporter::MIDIExporter)
    bpm = round(60000000.0 / exporter.tempo, digits=1)
    print(io, "MIDIExporter(tpq=$(exporter.ticks_per_quarter), ")
    print(io, "tempo=$(bpm)BPM, vel=[$(exporter.min_velocity)-$(exporter.max_velocity)], ")
    print(io, "dur=$(exporter.note_duration), spacing=$(exporter.time_spacing))")
end

# ------------------------------------------------------------------------------
# Note Generation from Harmonic Series
# ------------------------------------------------------------------------------

"""Convert a HarmonicSeries to a MIDINote.

Maps the fundamental frequency to a MIDI note number using freq_to_midi,
and derives velocity from the series confidence and fundamental magnitude.

Parameters:
- series: HarmonicSeries to convert
- exporter: MIDIExporter configuration
- start_time: Note start time in ticks
- duration: Note duration in ticks (uses exporter default if not provided)

Returns: MIDINote or nothing if frequency is out of MIDI range."""
function series_to_note(series::HarmonicSeries, exporter::MIDIExporter;
                         start_time::Int=0,
                         duration::Union{Int, Nothing}=nothing)::Union{MIDINote, Nothing}
    midi_float = freq_to_midi(series.fundamental)

    # Check if frequency maps to valid MIDI range
    if midi_float <= 0.0f0 || midi_float >= 127.0f0
        return nothing
    end

    pitch = round(Int, midi_float)
    pitch = clamp(pitch, 0, 127)

    # Map confidence to velocity
    conf = clamp(series.overall_confidence, 0.0f0, 1.0f0)
    velocity_range = exporter.max_velocity - exporter.min_velocity
    velocity = exporter.min_velocity + round(Int, conf * velocity_range)
    velocity = clamp(velocity, 0, 127)

    dur = duration !== nothing ? duration : exporter.note_duration

    return MIDINote(pitch, velocity, start_time, dur)
end

"""Convert multiple HarmonicSeries to a vector of MIDINote.

Spaces notes according to exporter.time_spacing.

Parameters:
- series_list: Vector of HarmonicSeries
- exporter: MIDIExporter configuration
- start_offset: Initial time offset in ticks

Returns: Vector of MIDINote."""
function series_to_notes(series_list::Vector{HarmonicSeries}, exporter::MIDIExporter;
                          start_offset::Int=0)::Vector{MIDINote}
    notes = MIDINote[]
    current_time = start_offset

    for series in series_list
        note = series_to_note(series, exporter; start_time=current_time)
        if note !== nothing
            push!(notes, note)
            current_time += exporter.time_spacing
        end
    end

    return notes
end

"""Create MIDINote from frequency directly.

Convenience function for exporting peaks or raw frequencies without
harmonic series context.

Parameters:
- freq: Frequency in Hz
- exporter: MIDIExporter configuration
- start_time: Note start time in ticks
- duration: Note duration in ticks
- velocity: Note velocity (0-127, default uses exporter default)

Returns: MIDINote or nothing if out of range."""
function freq_to_note(freq::Real, exporter::MIDIExporter;
                       start_time::Int=0,
                       duration::Union{Int, Nothing}=nothing,
                       velocity::Union{Int, Nothing}=nothing)::Union{MIDINote, Nothing}
    midi_float = freq_to_midi(freq)

    if midi_float <= 0.0f0 || midi_float >= 127.0f0
        return nothing
    end

    pitch = round(Int, midi_float)
    pitch = clamp(pitch, 0, 127)

    vel = velocity !== nothing ? velocity : exporter.default_velocity
    vel = clamp(vel, 0, 127)

    dur = duration !== nothing ? duration : exporter.note_duration

    return MIDINote(pitch, vel, start_time, dur)
end

# ------------------------------------------------------------------------------
# Binary MIDI File Writer
# ------------------------------------------------------------------------------

"""Encode an integer as a variable-length quantity (VLQ) for MIDI.

MIDI uses VLQ for delta times and meta event lengths."""
function _encode_vlq(value::UInt32)::Vector{UInt8}
    if value == 0
        return UInt8[0x00]
    end

    bytes = UInt8[]
    v = value

    while v > 0
        push!(bytes, UInt8(v & 0x7F))
        v >>= 7
    end

    # Reverse and set continuation bits
    reverse!(bytes)

    for i in 1:(length(bytes) - 1)
        bytes[i] |= 0x80
    end

    return bytes
end

"""Write a big-endian UInt16 to an IO stream."""
function _write_uint16(io::IO, value::UInt16)
    write(io, UInt8((value >> 8) & 0xFF))
    write(io, UInt8(value & 0xFF))
end

"""Write a big-endian UInt32 to an IO stream."""
function _write_uint32(io::IO, value::UInt32)
    write(io, UInt8((value >> 24) & 0xFF))
    write(io, UInt8((value >> 16) & 0xFF))
    write(io, UInt8((value >> 8) & 0xFF))
    write(io, UInt8(value & 0xFF))
end

"""Write a MIDI header chunk.

Format 0: Single track
Format 1: Multiple tracks"""
function _write_header(io::IO, format::Int, ntracks::Int, ticks_per_quarter::Int)
    write(io, b"MThd")
    _write_uint32(io, UInt32(6))  # Header length
    _write_uint16(io, UInt16(format))
    _write_uint16(io, UInt16(ntracks))
    _write_uint16(io, UInt16(ticks_per_quarter))
end

"""Write a tempo meta event."""
function _write_tempo_event(track_data::Vector{UInt8}, tempo::Int)
    append!(track_data, _encode_vlq(UInt32(0)))  # Delta time
    push!(track_data, 0xFF)  # Meta event
    push!(track_data, 0x51)  # Tempo
    push!(track_data, 0x03)  # Length
    push!(track_data, UInt8((tempo >> 16) & 0xFF))
    push!(track_data, UInt8((tempo >> 8) & 0xFF))
    push!(track_data, UInt8(tempo & 0xFF))
end

"""Write a track name meta event."""
function _write_track_name(track_data::Vector{UInt8}, name::String)
    name_bytes = Vector{UInt8}(name)
    append!(track_data, _encode_vlq(UInt32(0)))  # Delta time
    push!(track_data, 0xFF)  # Meta event
    push!(track_data, 0x03)  # Track name
    append!(track_data, _encode_vlq(UInt32(length(name_bytes))))
    append!(track_data, name_bytes)
end

"""Write a note ON event."""
function _write_note_on(track_data::Vector{UInt8}, delta_time::UInt32,
                         channel::UInt8, pitch::UInt8, velocity::UInt8)
    append!(track_data, _encode_vlq(delta_time))
    push!(track_data, UInt8(0x90 | (channel & 0x0F)))
    push!(track_data, pitch)
    push!(track_data, velocity)
end

"""Write a note OFF event."""
function _write_note_off(track_data::Vector{UInt8}, delta_time::UInt32,
                          channel::UInt8, pitch::UInt8, velocity::UInt8)
    append!(track_data, _encode_vlq(delta_time))
    push!(track_data, UInt8(0x80 | (channel & 0x0F)))
    push!(track_data, pitch)
    push!(track_data, velocity)
end

"""Write end-of-track meta event."""
function _write_end_of_track(track_data::Vector{UInt8})
    append!(track_data, _encode_vlq(UInt32(0)))  # Delta time
    push!(track_data, 0xFF)  # Meta event
    push!(track_data, 0x2F)  # End of track
    push!(track_data, 0x00)  # Length
end

"""Write a track chunk from note data."""
function _write_track(io::IO, track_data::Vector{UInt8})
    write(io, b"MTrk")
    _write_uint32(io, UInt32(length(track_data)))
    write(io, track_data)
end

"""Build track data from a vector of MIDINote.

Creates NOTE_ON and NOTE_OFF events for each note, sorted by start time."""
function _build_track_data(notes::Vector{MIDINote}, exporter::MIDIExporter;
                            track_name::String="Detected Notes")::Vector{UInt8}
    track_data = UInt8[]

    # Track name
    _write_track_name(track_data, track_name)

    # Tempo
    _write_tempo_event(track_data, exporter.tempo)

    # Sort notes by start time
    sorted_notes = sort(notes, by=n -> n.start_time)

    # Build NOTE_ON / NOTE_OFF events
    events = Tuple{UInt32, Symbol, MIDINote}[]

    for note in sorted_notes
        push!(events, (note.start_time, :on, note))
        push!(events, (note.start_time + note.duration, :off, note))
    end

    # Sort by time, then OFF before ON at same time
    sort!(events, by=e -> (e[1], e[2] == :off ? 0 : 1))

    # Write events with delta times
    last_time = UInt32(0)

    for (time, event_type, note) in events
        delta_time = time - last_time
        last_time = time

        if event_type == :on
            _write_note_on(track_data, delta_time, note.channel, note.pitch, note.velocity)
        else
            _write_note_off(track_data, delta_time, note.channel, note.pitch, UInt8(0))
        end
    end

    # End of track
    _write_end_of_track(track_data)

    return track_data
end

# ------------------------------------------------------------------------------
# Main Export API
# ------------------------------------------------------------------------------

"""Export MIDINote vector to a MIDI file.

Parameters:
- notes: Vector of MIDINote to export
- filepath: Output file path
- exporter: MIDIExporter configuration
- track_name: Optional track name

Returns: filepath on success."""
function export_midi(notes::Vector{MIDINote}, filepath::String,
                      exporter::MIDIExporter=MIDIExporter();
                      track_name::String="Detected Notes")::String
    track_data = _build_track_data(notes, exporter; track_name=track_name)

    open(filepath, "w") do io
        _write_header(io, exporter.format, 1, exporter.ticks_per_quarter)
        _write_track(io, track_data)
    end

    return filepath
end

"""Export HarmonicSeries vector to a MIDI file.

Converts each series to a note and writes to file.

Parameters:
- series_list: Vector of HarmonicSeries
- filepath: Output file path
- exporter: MIDIExporter configuration

Returns: filepath on success."""
function export_midi(series_list::Vector{HarmonicSeries}, filepath::String;
                      exporter::MIDIExporter=MIDIExporter())::String
    notes = series_to_notes(series_list, exporter)
    return export_midi(notes, filepath, exporter;
                        track_name="Detected Harmonics")
end

"""Export a single HarmonicSeries to a MIDI file.

Parameters:
- series: HarmonicSeries to export
- filepath: Output file path
- exporter: MIDIExporter configuration

Returns: filepath on success."""
function export_midi(series::HarmonicSeries, filepath::String;
                      exporter::MIDIExporter=MIDIExporter())::String
    note = series_to_note(series, exporter)
    if note === nothing
        error("Cannot export series: fundamental frequency out of MIDI range")
    end
    return export_midi([note], filepath, exporter;
                        track_name="Single Note")
end

"""Export frequencies directly to a MIDI file.

Convenience function for exporting raw frequencies.

Parameters:
- frequencies: Vector of frequencies in Hz
- filepath: Output file path
- exporter: MIDIExporter configuration

Returns: filepath on success."""
function export_frequencies(frequencies::Vector{<:Real}, filepath::String;
                             exporter::MIDIExporter=MIDIExporter())::String
    notes = MIDINote[]
    current_time = 0

    for freq in frequencies
        note = freq_to_note(freq, exporter; start_time=current_time)
        if note !== nothing
            push!(notes, note)
            current_time += exporter.time_spacing
        end
    end

    return export_midi(notes, filepath, exporter;
                        track_name="Frequency Export")
end

# ------------------------------------------------------------------------------
# Convenience Functions
# ------------------------------------------------------------------------------

"""Get the pitch names of exported notes.

Returns a vector of note names like ["A4", "C#5", ...]."""
function note_names(notes::Vector{MIDINote})::Vector{String}
    names = String[]
    for note in notes
        freq = midi_to_freq(note.pitch)
        name, _ = freq_to_note(freq)
        push!(names, name)
    end
    return names
end

"""Get the BPM from tempo."""
function tempo_to_bpm(exporter::MIDIExporter)::Float64
    return 60000000.0 / exporter.tempo
end

"""Set tempo from BPM."""
function set_bpm!(exporter::MIDIExporter, bpm::Real)
    exporter.tempo = round(Int, 60000000.0 / bpm)
    return exporter
end

"""Count notes in export."""
function note_count(notes::Vector{MIDINote})::Int
    return length(notes)
end

"""Get pitch range of notes."""
function pitch_range(notes::Vector{MIDINote})::Tuple{Int, Int}
    if isempty(notes)
        return (0, 0)
    end
    pitches = [Int(n.pitch) for n in notes]
    return (minimum(pitches), maximum(pitches))
end

"""Convert notes to a matrix for easy inspection.
Columns: pitch, velocity, start_time, duration"""
function notes_to_matrix(notes::Vector{MIDINote})::Matrix{Int}
    n = length(notes)
    mat = Matrix{Int}(undef, n, 4)
    @inbounds for i in 1:n
        note = notes[i]
        mat[i, 1] = Int(note.pitch)
        mat[i, 2] = Int(note.velocity)
        mat[i, 3] = Int(note.start_time)
        mat[i, 4] = Int(note.duration)
    end
    return mat
end

"""Print a summary of MIDI notes."""
function print_notes(notes::Vector{MIDINote}; max_display::Int=10)
    n = length(notes)
    println("MIDI Notes ($n total):")
    println()
    println("  #    Pitch  Note   Vel   Start    Dur")
    println("  " * "-"^45)

    display_count = min(n, max_display)
    @inbounds for i in 1:display_count
        note = notes[i]
        freq = midi_to_freq(note.pitch)
        name, cents = freq_to_note(freq)
        println(@sprintf("  %-3d  %-3d    %-4s   %-3d   %-6d   %-6d",
                        i, note.pitch, name, note.velocity,
                        note.start_time, note.duration))
    end

    if n > max_display
        println("  ... and $(n - max_display) more")
    end

    println()
end

"""Validate that a MIDI file was written correctly by checking the header.

Returns true if the file has a valid MIDI header."""
function validate_midi(filepath::String)::Bool
    if !isfile(filepath)
        return false
    end

    open(filepath, "r") do io
        header = read(io, 4)
        if header != b"MThd"
            return false
        end

        # Read header length (big-endian)
        len_bytes = read(io, 4)
        len = UInt32(len_bytes[1]) << 24 | UInt32(len_bytes[2]) << 16 |
              UInt32(len_bytes[3]) << 8 | UInt32(len_bytes[4])
        if len != 6
            return false
        end

        return true
    end
end

"""Read MIDI file header information.

Returns (format, ntracks, ticks_per_quarter) or nothing if invalid."""
function midi_info(filepath::String)::Union{Tuple{Int, Int, Int}, Nothing}
    if !isfile(filepath)
        return nothing
    end

    open(filepath, "r") do io
        header = read(io, 4)
        if header != b"MThd"
            return nothing
        end

        len_bytes = read(io, 4)
        len = UInt32(len_bytes[1]) << 24 | UInt32(len_bytes[2]) << 16 |
              UInt32(len_bytes[3]) << 8 | UInt32(len_bytes[4])
        if len != 6
            return nothing
        end

        fmt_bytes = read(io, 2)
        fmt = Int(UInt16(fmt_bytes[1]) << 8 | UInt16(fmt_bytes[2]))

        ntracks_bytes = read(io, 2)
        ntracks = Int(UInt16(ntracks_bytes[1]) << 8 | UInt16(ntracks_bytes[2]))

        tpq_bytes = read(io, 2)
        tpq = Int(UInt16(tpq_bytes[1]) << 8 | UInt16(tpq_bytes[2]))

        return (fmt, ntracks, tpq)
    end
end
