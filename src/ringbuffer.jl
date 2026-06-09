mutable struct RingBuffer{T}
    buffer::Vector{T}
    capacity::Int
    head::Int  # write position
    tail::Int  # read position
    count::Int  # number of elements
    lock::ReentrantLock
    
    function RingBuffer{T}(capacity::Int) where T
        new(Vector{T}(undef, capacity), capacity, 1, 1, 0, ReentrantLock())
    end
end

function Base.push!(rb::RingBuffer{T}, item::T) where T
    lock(rb.lock) do
        if rb.count >= rb.capacity
            error("RingBuffer is full")
        end
        rb.buffer[rb.head] = item
        rb.head = mod1(rb.head + 1, rb.capacity)
        rb.count += 1
    end
    return rb
end

function Base.push!(rb::RingBuffer{T}, items::Vector{T}) where T
    lock(rb.lock) do
        n = length(items)
        if rb.count + n > rb.capacity
            error("RingBuffer overflow: trying to push $n items, only $(rb.capacity - rb.count) space available")
        end
        for item in items
            rb.buffer[rb.head] = item
            rb.head = mod1(rb.head + 1, rb.capacity)
            rb.count += 1
        end
    end
    return rb
end

function Base.popfirst!(rb::RingBuffer{T})::T where T
    lock(rb.lock) do
        if rb.count == 0
            error("RingBuffer is empty")
        end
        item = rb.buffer[rb.tail]
        rb.tail = mod1(rb.tail + 1, rb.capacity)
        rb.count -= 1
        return item
    end
end

function Base.popfirst!(rb::RingBuffer{T}, n::Int)::Vector{T} where T
    lock(rb.lock) do
        if rb.count < n
            error("RingBuffer underflow: trying to pop $n items, only $(rb.count) available")
        end
        items = Vector{T}(undef, n)
        for i in 1:n
            items[i] = rb.buffer[rb.tail]
            rb.tail = mod1(rb.tail + 1, rb.capacity)
            rb.count -= 1
        end
        return items
    end
end

function Base.isempty(rb::RingBuffer)::Bool
    lock(rb.lock) do
        return rb.count == 0
    end
end

function isfull(rb::RingBuffer)::Bool
    lock(rb.lock) do
        return rb.count >= rb.capacity
    end
end

function Base.length(rb::RingBuffer)::Int
    lock(rb.lock) do
        return rb.count
    end
end

function capacity(rb::RingBuffer)::Int
    return rb.capacity
end

function available(rb::RingBuffer)::Int
    lock(rb.lock) do
        return rb.capacity - rb.count
    end
end

function Base.empty!(rb::RingBuffer)
    lock(rb.lock) do
        rb.head = 1
        rb.tail = 1
        rb.count = 0
    end
    return rb
end

function peek(rb::RingBuffer{T}, n::Int)::Vector{T} where T
    lock(rb.lock) do
        if rb.count < n
            error("RingBuffer underflow: trying to peek $n items, only $(rb.count) available")
        end
        items = Vector{T}(undef, n)
        pos = rb.tail
        for i in 1:n
            items[i] = rb.buffer[pos]
            pos = mod1(pos + 1, rb.capacity)
        end
        return items
    end
end

function peek(rb::RingBuffer{T})::T where T
    lock(rb.lock) do
        if rb.count == 0
            error("RingBuffer is empty")
        end
        return rb.buffer[rb.tail]
    end
end

function overwrite!(rb::RingBuffer{T}, item::T) where T
    lock(rb.lock) do
        rb.buffer[rb.head] = item
        rb.head = mod1(rb.head + 1, rb.capacity)
        if rb.count >= rb.capacity
            rb.tail = mod1(rb.tail + 1, rb.capacity)
        else
            rb.count += 1
        end
    end
    return rb
end

function overwrite!(rb::RingBuffer{T}, items::Vector{T}) where T
    lock(rb.lock) do
        for item in items
            rb.buffer[rb.head] = item
            rb.head = mod1(rb.head + 1, rb.capacity)
            if rb.count >= rb.capacity
                rb.tail = mod1(rb.tail + 1, rb.capacity)
            else
                rb.count += 1
            end
        end
    end
    return rb
end

function Base.show(io::IO, rb::RingBuffer{T}) where T
    lock(rb.lock) do
        print(io, "RingBuffer{$T}(capacity=$(rb.capacity), count=$(rb.count), head=$(rb.head), tail=$(rb.tail))")
    end
end
