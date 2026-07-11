#!/usr/bin/env lua

local M = {}

local DEFAULT_MAX_BYTES = 4 * 1024 * 1024

local function is_blank(value)
    return tostring(value or ""):match("^%s*$") ~= nil
end

local function fail(state, message)
    state.buffer = ""
    state.parts = {}
    state.part_bytes = 0
    state.failed = true
    state.error = message
    return message
end

local function check_frame_size(state, frame)
    if #frame <= state.max_bytes then
        return nil
    end

    return fail(state, string.format(
        "AI response record exceeded the %d-byte buffer limit.",
        state.max_bytes
    ))
end

function M.new(streaming, max_bytes)
    return {
        buffer = "",
        parts = {},
        part_bytes = 0,
        streaming = streaming ~= false,
        max_bytes = tonumber(max_bytes) or DEFAULT_MAX_BYTES,
        failed = false,
        error = nil,
    }
end

function M.reset(state, streaming, max_bytes)
    state.buffer = ""
    state.parts = {}
    state.part_bytes = 0
    state.streaming = streaming ~= false
    state.max_bytes = tonumber(max_bytes) or state.max_bytes or DEFAULT_MAX_BYTES
    state.failed = false
    state.error = nil
end

function M.push(state, chunk)
    if state.failed then
        return {}, state.error
    end

    chunk = tostring(chunk or "")

    if not state.streaming then
        local next_size = state.part_bytes + #chunk
        if next_size > state.max_bytes then
            return {}, fail(state, string.format(
                "AI response exceeded the %d-byte buffer limit.",
                state.max_bytes
            ))
        end

        state.parts[#state.parts + 1] = chunk
        state.part_bytes = next_size
        return {}, nil
    end

    state.buffer = state.buffer .. chunk

    local frames = {}
    local start = 1

    while true do
        local newline = state.buffer:find("\n", start, true)
        if not newline then
            break
        end

        local frame = state.buffer:sub(start, newline - 1):gsub("\r$", "")
        start = newline + 1

        if not is_blank(frame) then
            local size_error = check_frame_size(state, frame)
            if size_error then
                return frames, size_error
            end
            frames[#frames + 1] = frame
        end
    end

    state.buffer = state.buffer:sub(start)
    if #state.buffer > state.max_bytes then
        return frames, fail(state, string.format(
            "Incomplete AI response record exceeded the %d-byte buffer limit.",
            state.max_bytes
        ))
    end

    return frames, nil
end

function M.finish(state)
    if state.failed then
        return {}, state.error
    end

    if state.streaming then
        local frame = state.buffer
        state.buffer = ""
        frame = frame:gsub("\r$", "")

        if is_blank(frame) then
            return {}, nil
        end

        local size_error = check_frame_size(state, frame)
        if size_error then
            return {}, size_error
        end

        return { frame }, nil
    end

    local frame = table.concat(state.parts)
    state.parts = {}
    state.part_bytes = 0

    if is_blank(frame) then
        return {}, nil
    end

    return { frame }, nil
end

function M.pending_bytes(state)
    if state.streaming then
        return #(state.buffer or "")
    end
    return tonumber(state.part_bytes) or 0
end

return M
