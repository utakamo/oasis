-- Run from the repository root with Lua 5.1 and luci.jsonc on LUA_CPATH.
-- Real validation, event delivery, console and controller; mock router services.
package.path = './oasis/files/usr/lib/lua/?.lua;' .. package.path
local jsonc = require('luci.jsonc')
local settings, files, calls = {}, {}, 0
local common = {
    status = { error = 'ERROR' },
    db = { uci = { cfg = 'oasis', sect = { assist = 'assist', support = 'support' } } },
    ai = { format = { output = 'output', chat = 'chat', prompt = 'prompt' } },
    search_chat_id = function(id) return id == '123456' or id == 'imported-chat_1' end,
}
local cursor = { get_bool = function(_, _, _, name) return settings[name] == true end }
package.loaded['oasis.common'] = common
package.loaded['luci.model.uci'] = { cursor = function() return cursor end }
package.loaded['oasis.chat.misc'] = { check_file_exist = function(path) return files[path] end }
package.loaded['oasis.chat.debug'] = { log = function() end }
local output
package.loaded['oasis.chat.main'] = { output = function(request)
    calls = calls + 1
    assert(request.cmd == 'chat')
    return output(request)
end }
local console = require('oasis.console')
local web = require('oasis.chat.web')
local chat_error = require('oasis.chat.error')
local tests = 0
local function test(name, fn)
    settings, files, calls = {}, {}, 0
    fn()
    tests = tests + 1
    print('ok ' .. tests .. ' - ' .. name)
end
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function request(fields, length)
    local raw = type(fields) == 'string' and fields or jsonc.stringify(fields)
    return web.parse_request(raw, length or (#raw + 32))
end
local function invalid(fields, expected, length)
    local value, err, status = request(fields, length)
    equal(value, nil); equal(status, expected); equal(err.can_continue, false)
    equal(calls, 0)
end
local function collect()
    local events = {}
    return events, function(chunk)
        assert(chunk:sub(-1) == '\n')
        assert(not chunk:sub(1, -2):find('\n', 1, true))
        events[#events + 1] = assert(jsonc.parse(chunk))
    end
end
local input = { cmd = 'chat', id = '', message = 'hello', sysmsg_key = '' }

test('request contract and current imported chat identifiers', function()
    for _, id in ipairs({'', '123456', 'imported-chat_1'}) do
        local value = assert(request({id=id, message='日本語 & + % { } "'}))
        equal(value.cmd, 'chat'); equal(value.sysmsg_key, ''); equal(value.id, id)
    end
    invalid({id='', message='hello', cmd='setup'}, 400)
    invalid({id='../etc/config/oasis', message='hello'}, 400)
    invalid({id='missing', message='hello'}, 404)
    invalid({id=123456, message='hello'}, 400)
    invalid({id='', message=' \t\n'}, 400)
    invalid('{"id":"","message":"bad\\u0000message"}', 400)
    invalid('{"id":"","message":"bad\0message"}', 400)
    assert(request('{"id":"","message":"literal \\\\u0000"}'))
    invalid({id='', message={}, sysmsg_key='default'}, 400)
    invalid({id='', message='ok', sysmsg_key='../bad'}, 400)
    invalid({id='', message='ok', sysmsg_key=42}, 400)
end)

test('malformed JSON and request bounds fail before processing', function()
    invalid('[]', 400); invalid('{', 400)
    invalid('{"id":"","message":"ok"} {}', 400)
    invalid('{"id":"","message":"ok","extra":' .. string.rep('[', 9) .. '0' .. string.rep(']', 9) .. '}', 400)
    invalid({id='', message=string.rep('a', web.MAX_MESSAGE_BYTES + 1)}, 413)
    invalid(string.rep(' ', web.MAX_PAYLOAD_BYTES + 1), 413)
    invalid({id='', message='ok'}, 413, web.MAX_HTTP_BODY_BYTES + 1)
    for _, length in ipairs({'', 'abc', 0, -1, 1.5}) do
        invalid({id='', message='ok'}, 400, length)
    end
    assert(request({id='', message=string.rep('a', web.MAX_MESSAGE_BYTES)}))
end)

test('sink nesting, nil return values and exception restoration', function()
    local events, flushes = {}, 0
    local count = select('#', console.with_output_sink(function(s) events[#events+1]=s end,
        function() flushes=flushes+1 end, function()
            console.printf('%s', 'outer')
            local inner = {}
            console.with_output_sink(function(s) inner[#inner+1]=s end, nil, function()
                console.write('inner'); console.flush()
            end)
            equal(table.concat(inner), 'inner')
            equal(pcall(console.with_output_sink, function() error('write failed') end, nil,
                function() console.write('bad') end), false)
            console.print('restored')
            return nil, 'middle', nil
        end))
    equal(count, 3); equal(flushes, 1); equal(table.concat(events), 'outerrestored\n')
    local file = assert(io.tmpfile())
    local previous = io.output()
    io.output(file)
    console.write('CLI fallback'); console.flush()
    file:seek('set'); equal(file:read('*a'), 'CLI fallback')
    io.output(previous); file:close()
end)

test('coroutine output does not escape into the main request sink', function()
    local outer, inner = {}, {}
    console.with_output_sink(function(s) outer[#outer+1]=s end, nil, function()
        local co = coroutine.create(function()
            console.with_output_sink(function(s) inner[#inner+1]=s end, nil,
                function() console.write('child') end)
        end)
        assert(coroutine.resume(co)); console.write('parent')
    end)
    equal(table.concat(outer), 'parent'); equal(table.concat(inner), 'child')
end)

test('events arrive before completion; final text is not duplicated', function()
    local events, emit = collect()
    local sequence = {
        {type='thinking', content='reasoning'}, {message={content='first'}},
        {type='execution', message='running'}, {type='download', message='loading'},
        {tool_outputs={{user_only='visible', ui_action={type='wifi_config'}, reboot=true}}},
        {message={content='second'}},
    }
    output = function()
        for i, value in ipairs(sequence) do
            console.write(jsonc.stringify(value, false)); console.flush()
            equal(#events, i)
        end
        return jsonc.stringify({id='123456', title='result', warning={message='title failed'}}), 'firstsecond'
    end
    assert(web.process(input, emit)); equal(calls, 1); equal(#events, 7)
    equal(events[5].tool_outputs[1].user_only, 'visible')
    equal(events[7].warning.message, 'title failed')
end)

test('optional retired UCI notification precedes metadata', function()
    settings.enable = true
    files['/usr/lib/lua/oasis/chat/filter.lua'] = true
    package.loaded['oasis.chat.filter'] = {
        uci_cmd_filter = function(message) equal(message, 'reply'); return {'uci show network'} end,
        check_uci_list_exist = function() return true end,
    }
    output = function() return '{"id":"123456"}', 'reply' end
    local events, emit = collect()
    assert(web.process(input, emit)); equal(#events, 2)
    equal(events[1].uci_notify, true); equal(events[2].id, '123456')
    package.loaded['oasis.chat.filter'].uci_cmd_filter = function() error('filter failure') end
    events, emit = collect()
    assert(web.process(input, emit)); equal(#events, 1)
end)

test('structured failures preserve continuation and saved chat ID', function()
    local err = chat_error.build(nil, {message='storage failed', can_continue=false})
    err.chat_id = '123456'
    output = function() return nil, nil, err end
    local events, emit = collect()
    equal(web.process(input, emit), false); equal(#events, 1)
    equal(events[1].error.chat_id, '123456'); equal(events[1].error.can_continue, false)
    output = function() error('private internal detail') end
    events, emit = collect()
    equal(web.process(input, emit), false); equal(#events, 1)
    equal(events[1].error.message, 'Chat processing failed.')
end)

test('disconnect does not retry requests or writes and restores outer sink', function()
    for _, throws in ipairs({false, true}) do
        local writes, restored = 0, false
        output = function() console.write('{"message":{"content":"first"}}') end
        console.with_output_sink(function() restored=true end, nil, function()
            equal(web.process(input, function()
                writes = writes + 1
                if throws then error('closed') end
                return false
            end), false)
            console.write('outer')
        end)
        equal(writes, 1); equal(restored, true)
    end
    equal(calls, 2)
end)

test('old optional tool package is rejected before AI or tool execution', function()
    settings.local_tool = true
    files['/usr/lib/lua/oasis/local/tool/client.lua'] = true
    package.loaded['oasis.local.tool.client'] = {}
    output = function() error('must not execute') end
    local events, emit = collect()
    equal(web.process(input, emit), false); equal(calls, 0)
    assert(events[1].error.message:find('Update oasis%-mod%-tool'))
end)

-- Load the actual optional client and exercise the notification closure it uses.
test('tool notifications use the same sink and retain CLI text', function()
    for _, name in ipairs({'luci.sys', 'nixio.fs', 'oasis.local.tool.package.manager',
        'oasis.local.tool.state', 'oasis.uci_transaction'}) do package.loaded[name] = {} end
    local client = dofile('oasis-mod-tool/files/usr/lib/lua/oasis/local/tool/client.lua')
    equal(client.OUTPUT_SINK_VERSION, 1)
    local notify
    for index=1,100 do
        local name, value = debug.getupvalue(client.exec_server_tool, index)
        if not name then break end
        if name == 'handle_option_message' then notify = value end
    end
    assert(notify)
    local events, emit = collect()
    console.with_output_sink(function(s) emit(s .. '\n') end, nil, function()
        notify('running', 'execution', common.ai.format.output)
        notify('loading', 'download', common.ai.format.output)
    end)
    equal(events[1].type, 'execution'); equal(events[2].type, 'download')
    local text = ''
    console.with_output_sink(function(s) text=text..s end, nil,
        function() notify('CLI tool', 'execution', common.ai.format.chat) end)
    equal(text, 'CLI tool\n\n')
end)

test('controller registers a gated POST route and streams via the HTTP bridge', function()
    for _, name in ipairs({'luci.util', 'oasis.chat.apply', 'oasis.chat.transfer',
        'oasis.chat.datactrl', 'nixio', 'oasis.ubus.util', 'oasis.tool_edge.account',
        'oasis.mode', 'oasis.mode_lock'}) do package.loaded[name] = {} end
    local headers, chunks, status, media = {}, {}, nil, 'application/x-www-form-urlencoded'
    local payload = '{"id":"","message":"hello"}'
    package.loaded['luci.http'] = {
        getenv = function(key) return key == 'CONTENT_TYPE' and media or tostring(#payload+32) end,
        formvalue = function(name) equal(name, 'payload'); return payload end,
        header = function(k,v) headers[k]=v end,
        status = function(code) status=code end,
        prepare_content = function(value) headers['Content-Type']=value end,
        write = function(value) chunks[#chunks+1]=value end,
    }
    dofile('oasis/files/luci/controller/module.lua')
    local controller = package.loaded['luci.controller.oasis.module']
    local routes = {}
    controller.entry = function(path, target) local item={target=target}; routes[path[#path]]=item; return item end
    for _, name in ipairs({'call', 'post', 'template', 'alias', 'firstchild'}) do
        local kind = name
        controller[name] = function(value) return {kind=kind, value=value} end
    end
    controller.index(); equal(next(routes), nil)
    settings.webui = true; controller.index()
    equal(routes['chat-stream'].target.kind, 'post')
    equal(routes['chat'].target.kind, 'template')
    local streamed = {}
    _G.L = {http={write=function(_, value) streamed[#streamed+1]=value; return true end}}
    output = function()
        console.write('{"message":{"content":"partial"}}')
        equal(#streamed, 1); equal(#chunks, 0)
        return '{"id":"123456"}', 'partial'
    end
    controller.chat_stream()
    equal(#streamed, 2); equal(headers['Cache-Control'], 'no-store')
    equal(headers['Content-Type'], 'application/x-ndjson; charset=utf-8')
    _G.L = nil
    media = 'application/json'; controller.chat_stream(); equal(status, 415)
    media = 'application/x-www-form-urlencoded'; payload = '{}'
    controller.chat_stream(); equal(status, 400); equal(calls, 1)
end)

print('Passed ' .. tests .. ' WebUI regression tests.')
