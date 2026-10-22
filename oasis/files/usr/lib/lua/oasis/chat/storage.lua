-- Shared by CLI, streaming WebUI, rpcd and imports. The process lock serializes
-- JSON replacement and UCI registration; closing the fd also releases it on exit.
local jsonc = require("luci.jsonc")
local history = require("oasis.chat.history")
local M = {}

function M.new_id()
    local file = assert(io.open("/dev/urandom", "rb"))
    local bytes = file:read(16)
    file:close()
    assert(bytes and #bytes == 16, "Cannot allocate a persistence ID.")
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function failure(message)
    return {status="ERROR", desc=tostring(message or "Chat storage failed.")}
end

local function cleanup_temporary(path)
    local directory, name=path:match("^(.*)/([^/]+)$")
    local prefix=name .. ".tmp."
    for item in require("nixio.fs").dir(directory) do
        if item:sub(1,#prefix)==prefix and item:sub(#prefix+1):match("^[a-f0-9]+$") then
            os.remove(directory .. "/" .. item)
        end
    end
end

function M.with_lock(fn)
    local nixio = require("nixio")
    local fs = require("nixio.fs")
    local directory = "/tmp/oasis-chat-storage"
    local stat, code = fs.lstat(directory)
    if not stat and code == 2 then fs.mkdir(directory,"0700"); stat=fs.lstat(directory) end
    if not stat or stat.type ~= "dir" or stat.uid ~= nixio.getuid()
        or stat.modestr ~= "rwx------" then return failure("Unsafe chat lock directory.") end
    local lock_path=directory .. "/lock"
    local lock_stat, lock_code=fs.lstat(lock_path)
    if lock_stat and (lock_stat.type ~= "reg" or lock_stat.uid ~= nixio.getuid()
        or lock_stat.nlink ~= 1 or lock_stat.modestr ~= "rw-------")
        or not lock_stat and lock_code ~= 2 then return failure("Unsafe chat lock file.") end
    local file, err = nixio.open(lock_path, "a", "0600")
    if not file then return failure(err) end
    local locked, lock_err = file:lock("tlock")
    if not locked then file:close(); return failure(lock_err or "Chat storage is busy; retry saving.") end
    local ok, result = pcall(fn)
    file:close()
    if not ok then return failure(result) end
    return result
end

function M.write_atomic(path, raw)
    local nixio = require("nixio")
    local temporary = path .. ".tmp." .. M.new_id()
    local file, err = nixio.open(temporary, nixio.open_flags("wronly","creat","excl"), "0600")
    if not file then return nil, err end
    local written, write_err = 0, nil
    while written < #raw do
        local count, err = file:write(raw:sub(written + 1))
        if not count or count == 0 then write_err=err or "Incomplete chat write."; break end
        written=written+count
    end
    local synced, sync_err
    if written == #raw then synced, sync_err = file:sync() end
    local closed, close_err = file:close()
    if written ~= #raw or not synced or not closed then
        os.remove(temporary)
        return nil, write_err or sync_err or close_err or "Incomplete chat write (possibly insufficient space)."
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary); return nil, rename_err end
    return true
end

local function context(id)
    if not history.identifier(id) then error("Invalid conversation ID.") end
    local common = require("oasis.common")
    local uci = require("luci.model.uci").cursor()
    local cfg = require("oasis.chat.datactrl").get_ai_service_cfg(nil, {with_storage=true})
    local section
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.chat, function(item)
        if item.id == id then section=item[".name"] end
    end)
    return uci, common, section, require("oasis.chat.misc").normalize_path(cfg.path) .. cfg.prefix .. id
end

local function encode(doc)
    local valid, err = history.validate(doc)
    if not valid then return nil, err end
    local raw = jsonc.stringify(doc, false)
    if type(raw) ~= "string" or #raw > history.MAX_BYTES then
        return nil, "Chat data exceeds the 4 MiB storage limit."
    end
    return raw
end

local function equivalent(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k,v in pairs(a) do
        if k ~= "revision" and k ~= "last_operation_id" and not equivalent(v,b[k]) then return false end
    end
    for k in pairs(b) do
        if k ~= "revision" and k ~= "last_operation_id" and a[k] == nil then return false end
    end
    return true
end

-- A complete snapshot with an expected revision is used for checkpoints.
-- A lost acknowledgement can retry the same operation, never an AI/tool call.
function M.save(id, doc, operation_id, create)
    if not history.identifier(operation_id) then return failure("Invalid save operation ID.") end
    local raw, invalid = encode(doc)
    if not raw then return failure(invalid) end
    return M.with_lock(function()
        local uci, common, section, path = context(id)
        cleanup_temporary(path)
        if section then
            local existing_raw, read_err = require("oasis.chat.misc").read_file(path)
            if not existing_raw then return failure(read_err) end
            local existing, decode_err = history.decode(existing_raw)
            if not existing then return failure(decode_err) end
            if existing.last_operation_id == operation_id then
                if not equivalent(existing, doc) then return failure("Save operation ID was reused with different data.") end
                return {status="OK", id=id, revision=existing.revision, duplicate=true}
            end
            if create then return failure("Conversation ID already exists.") end
            if (existing.revision or 0) ~= (doc.revision or 0) then
                return failure("Conversation changed concurrently; reload it before continuing.")
            end
        elseif not create then
            return failure("Conversation was not found.")
        end
        local updated = history.copy(doc)
        updated.revision = (doc.revision or 0) + 1
        updated.last_operation_id = operation_id
        local encoded, encode_err = encode(updated)
        if not encoded then return failure(encode_err) end
        local written, write_err = M.write_atomic(path, encoded)
        if not written then return failure(write_err) end
        if not section then
            local new_section
            local ok, registered = pcall(function()
                new_section = uci:add(common.db.uci.cfg, common.db.uci.sect.chat)
                return new_section and uci:set(common.db.uci.cfg, new_section, "id", id)
                    and uci:set(common.db.uci.cfg, new_section, "title", "--")
                    and uci:commit(common.db.uci.cfg)
            end)
            if not ok or not registered then
                if new_section then pcall(function() uci:delete(common.db.uci.cfg,new_section); uci:commit(common.db.uci.cfg) end) end
                os.remove(path)
                return failure("Failed to register conversation.")
            end
        end
        return {status="OK", id=id, revision=updated.revision}
    end)
end

function M.create(doc, id, operation_id)
    id = id or require("oasis.common").generate_chat_id()
    return M.save(id, doc, operation_id or M.new_id(), true)
end

function M.import(raw)
    local doc, err = history.decode(raw)
    if not doc then return failure(err) end
    -- Imported revision/operation tokens belong to the exporting conversation.
    doc = history.upgrade(doc)
    doc.revision, doc.last_operation_id = 0, nil
    return M.create(doc)
end

function M.legacy_append(id, messages, operation_id)
    -- Read/compare/write uses the same revision barrier as structured appends.
    local _, common, section, path = context(id)
    if not section then return {status=common.status.not_found} end
    local raw, read_err = require("oasis.chat.misc").read_file(path)
    if not raw then return failure(read_err) end
    local doc, decode_err = history.decode(raw)
    if not doc then return failure(decode_err) end
    if operation_id and doc.last_operation_id == operation_id then
        for index, message in ipairs(messages) do
            if not equivalent(doc.messages[#doc.messages-#messages+index],message) then
                return failure("Save operation ID was reused with different data.")
            end
        end
        return {status="OK",id=id,revision=doc.revision,duplicate=true}
    end
    doc = history.upgrade(doc)
    for _, message in ipairs(messages) do doc.messages[#doc.messages+1] = message end
    return M.save(id, doc, operation_id or M.new_id(), false)
end

function M.delete(id)
    return M.with_lock(function()
        local uci, common, section, path = context(id)
        if not section then return {status=common.status.not_found} end
        cleanup_temporary(path)
        local removed, err = os.remove(path)
        if not removed then return failure(err) end
        if not uci:delete(common.db.uci.cfg, section) or not uci:commit(common.db.uci.cfg) then
            return failure("Failed to unregister conversation.")
        end
        return {status="OK"}
    end)
end

return M
