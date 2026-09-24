// Dependency-free DOM/stream fixtures, not browser layout tests.
// Run: node --test dev_tools/tests/test_chat_tools.cjs
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const jsDir = path.join(__dirname, '../../luci-app-oasis/files/luci/www/luci-static/resources/oasis/js');
const toolsSource = fs.readFileSync(path.join(jsDir, 'chat-tools.js'), 'utf8');
const turnSource = fs.readFileSync(path.join(jsDir, 'chat-turn.js'), 'utf8');
const utilsSource = fs.readFileSync(path.join(jsDir, 'chat-utils.js'), 'utf8');
const chatSource = fs.readFileSync(path.join(jsDir, 'chat.js'), 'utf8');
const sendStart = chatSource.indexOf('    async function send_message(');
const sendEnd = chatSource.indexOf('    function handleChatItemClick(');
assert.ok(sendStart > 0 && sendEnd > sendStart, 'shared send path not found');
const sendSource = chatSource.slice(sendStart, sendEnd);

class Element {
    constructor(tag = 'div') {
        this.tagName = tag;
        this.children = [];
        this.style = {};
        this.className = '';
        this.text = '';
        this.html = '';
        this.attributes = {};
    }
    set textContent(value) { this.text = String(value); this.html = ''; this.children = []; }
    get textContent() { return this.text + this.children.map(child => child.textContent).join(''); }
    set innerHTML(value) { this.html = value; this.text = ''; this.children = []; }
    get innerHTML() { return this.html; }
    setAttribute(name, value) { this.attributes[name] = value; }
    removeChild(child) {
        const index = this.children.indexOf(child);
        assert.ok(index >= 0);
        this.children.splice(index, 1);
        child.parentNode = null;
        return child;
    }
    appendChild(child) {
        if (child.parentNode) child.parentNode.removeChild(child);
        child.parentNode = this; this.children.push(child); return child;
    }
    insertBefore(child, next) {
        const index = this.children.indexOf(next);
        assert.ok(index >= 0);
        child.parentNode = this;
        this.children.splice(index, 0, child);
    }
    contains(child) { return this === child || this.children.some(node => node.contains(child)); }
}

function nodes(root) { return [root, ...root.children.flatMap(nodes)]; }
function byClass(root, name) { return nodes(root).filter(node => node.className.split(' ').includes(name)); }
function tool(name, id, output = { status: 'OK' }, args) {
    return { name, tool_call_id: id, output: JSON.stringify(output), arguments: args };
}
function event(...calls) { return { service: 'Fixture', tool_outputs: calls }; }

function fixture(options = {}) {
    const root = new Element();
    const assistant = root.appendChild(new Element());
    assistant.className = 'message received';
    const answer = assistant.appendChild(new Element());
    answer.className = 'message-text chat-bubble';
    const env = { root, assistant, answer, errors: [], actions: [], popups: [], sanitized: [], execution: [], downloads: [] };
    let timerId = 0;
    const timers = new Map();
    env.flushTimers = () => {
        const callbacks = [...timers.values()];
        timers.clear();
        callbacks.forEach(callback => callback());
    };
    env.pendingTimers = () => timers.size;
    const context = {
        window: { location: { origin: 'http://fixture.invalid' }, innerWidth: options.mobile ? 375 : 1200 },
        document: { querySelector: () => root, createElement: tag => new Element(tag) },
        console: { error: (...args) => env.errors.push(args.map(String).join(' ')) },
        TextDecoder, activeConversation: false, message_outputing: false, targetChatId: '',
        sysmsg_key: '', resourcePath: '/resources', icon_name: 'fixture.png',
        currentAssistantMessageDiv: assistant, isKeyboardOpen: false,
        t: (key, fallback) => (options.strings || {})[key] || fallback,
        convertMarkdownToHTML: value => value,
        keepLatestMessageVisible() {}, setChatScrollLock() {},
        clearInterval: timer => { env.clearedTimer = timer; },
        hideDownloadOverlayAndWait: async () => {}, formatChatError: err => typeof err === 'string' ? err : err.message,
        wifiHandleUiAction: action => env.actions.push(action),
        isNumeric: value => /^\d+$/.test(value),
        show_chat_popup: () => env.popups.push('chat'),
        show_notify_popup: () => env.popups.push('uci'),
        show_reboot_popup: () => env.popups.push('reboot'),
        show_shutdown_popup: () => env.popups.push('shutdown'),
        show_restart_service_popup: name => env.popups.push('restart:' + name),
        showToolExecutionNotice: msg => env.execution.push(msg),
        showDownloadOverlay: msg => env.downloads.push(msg),
        setTimeout: callback => { timers.set(++timerId, callback); return timerId; },
        clearTimeout: id => timers.delete(id),
        answer
    };
    vm.runInNewContext(utilsSource, context);
    context.extractJsonObjects = context.window.OasisChatUtils.extractJsonObjects;
    context.escapeHTML = context.window.OasisChatUtils.escapeHTML;
    // The renderer must route all user_only Markdown through the existing
    // sanitizer. This fixture spies on that boundary, not browser HTML parsing.
    context.sanitizeHTML = value => { env.sanitized.push(value); return context.escapeHTML(value); };
    vm.runInNewContext(toolsSource, context);
    vm.runInNewContext(turnSource, context);
    const create = () => context.window.OasisChatTools.create({
        container: answer,
        t: context.t, sanitizeHTML: context.sanitizeHTML, convertMarkdownToHTML: context.convertMarkdownToHTML
    });
    env.createTurn = () => context.window.OasisChatTurn.create({
        container: answer, t: context.t, sanitizeHTML: context.sanitizeHTML,
        convertMarkdownToHTML: context.convertMarkdownToHTML
    });
    env.activity = create();
    env.create = create;
    env.context = context;
    env.cards = () => byClass(root, 'tool-call');
    env.names = () => byClass(root, 'tool-call-name').map(node => node.textContent);
    env.statuses = () => byClass(root, 'tool-call-status').map(node => node.textContent);
    env.text = () => byClass(answer, 'turn-text').map(node => node.innerHTML).join('');
    env.displayed = () => nodes(answer).map(node => node.text + node.html).join('');
    env.send = async (events, opts = {}) => {
        let chunks = events.map(item => Buffer.from(JSON.stringify(item) + '\n'));
        if (opts.bytewise) chunks = chunks.flatMap(chunk => Array.from(chunk, byte => Buffer.from([byte])));
        if (opts.joined) chunks = [Buffer.concat(chunks)];
        context.fetch = async () => ({ ok: !opts.httpError, body: { getReader: () => ({ read: async () => {
            if (opts.flushEachChunk) env.flushTimers();
            if (opts.onRead) opts.onRead(env);
            if (chunks.length) return { value: chunks.shift(), done: false };
            if (opts.disconnect) throw new Error('fixture stream disconnected');
            return { done: true };
        } }) } });
        if (opts.eofFallback) {
            // Exercise the compatibility path with a complete object left in
            // the buffer, using the very same event handler as streaming.
            context.extractJsonObjects = text => ({ objects: [], remaining: text });
        }
        await vm.runInNewContext(sendSource + '\nsend_message(answer, "Check router")', context);
        env.flushTimers();
    };
    return env;
}

test('three Auto stages have individual ordered cards inside one assistant bubble', () => {
    const env = fixture();
    const calls = [tool('get_tool_list', 'list'),
        tool('set_tool_enabled', 'enable', { status: 'OK', changed: true }, JSON.stringify({ server: 'fixture.router', tool: 'router_status' })),
        tool('router_status', 'read', { value: 'up' })];
    calls.forEach(call => env.activity.consume(event(call)));
    assert.deepEqual(env.names(), ['get_tool_list', 'set_tool_enabled', 'router_status']);
    assert.equal(byClass(env.root, 'tool-activity').length, 1);
    assert.equal(byClass(env.root, 'tool-call-management').length, 2);
    assert.equal(env.root.children.length, 1);
    assert.equal(env.root.children[0], env.assistant);
    assert.equal(env.answer.children[0].className, 'tool-activity');
    assert.equal(byClass(env.root, 'tool-call-target')[0].textContent, '→ fixture.router / router_status');
    assert.deepEqual(env.statuses(), ['Succeeded', 'Succeeded', 'Result received']);
});

test('batched and repeated names keep per-call notices in arrival order', () => {
    const env = fixture();
    env.activity.consume(event(tool('read', 'one', { user_only: 'first' }), tool('read', 'two', { user_only: 'second' })));
    env.activity.consume(event(tool('read', 'three', { user_only: 'third' })));
    assert.deepEqual(env.names(), ['read', 'read', 'read']);
    assert.deepEqual(env.cards().map(card => byClass(card, 'oasis-user-only-body')[0].innerHTML), ['first', 'second', 'third']);
});

test('call IDs dedupe per service and per turn, but missing IDs do not collapse calls', () => {
    const env = fixture();
    const original = event(tool('read', 'one'));
    env.activity.consume(original);
    assert.equal(env.activity.consume(original).outputs.length, 0);
    env.activity.consume({ ...original, service: 'Other' });
    env.activity.consume(event(tool('read', ''), tool('read', ''), tool('read', undefined)));
    assert.equal(env.activity.count, 5);
    assert.equal(env.activity.consume(event(tool('different', 'one'))).invalid, true);
    assert.equal(env.activity.count, 5);
    env.create().consume(original);
    assert.equal(env.cards().length, 6);
});

test('only explicit results show success, and failures override success', () => {
    const env = fixture();
    env.activity.consume(event(
        tool('read', 'a', { status: 'OK' }), tool('read', 'b', { status: 'NG' }),
        tool('read', 'c', { result: 'text' }), tool('read', 'd', { status: 'UP' }),
        tool('read', 'e', { success: false }), tool('read', 'f', { success: true }),
        tool('read', 'g', { status: 'OK', error: 'failed' }),
        tool('set_tool_enabled', 'h', { status: 'OK', changed: false })
    ));
    assert.deepEqual(env.statuses(), ['Succeeded', 'Failed', 'Result received', 'Result received', 'Failed', 'Succeeded', 'Failed', 'No change']);
    assert.equal(byClass(env.root, 'tool-call-failed').length, 3);
});

test('malformed entries cannot discard their valid siblings or break later events', () => {
    const env = fixture();
    for (const invalid of [null, {}, { service: 'Fixture', tool_outputs: [] }, { service: 'Fixture', tool_outputs: 'bad' }]) {
        assert.equal(env.activity.consume(invalid).invalid, true);
    }
    assert.equal(env.cards().length, 0);
    const result = env.activity.consume(event(null, false, [], {}, tool('valid', 'ok')));
    assert.equal(result.invalid, true);
    assert.deepEqual(env.names(), ['valid']);
    env.activity.consume(event({ name: 'plain', output: 'non-JSON output' }, { name: 'null', output: 'null' }));
    assert.deepEqual(env.statuses(), ['Succeeded', 'Result received', 'Result received']);
});

test('names and targets use text, user_only is sanitized, raw arguments/results stay hidden', () => {
    const env = fixture();
    const attack = '<img src=x onerror=alert(1)>';
    const original = event(
        tool(attack, 'one', { user_only: attack, secret: 'OUTPUT_SECRET' }, { password: 'ARGUMENT_SECRET' }),
        tool('set_tool_enabled', 'two', { status: 'OK' }, { server: 'fixture', tool: attack, password: 'TARGET_SECRET' }),
        tool('read', 'three', { nested: { user_only: 'NESTED_SECRET' } })
    );
    const before = JSON.stringify(original);
    env.activity.consume(original);
    assert.equal(JSON.stringify(original), before);
    assert.equal(env.names()[0], attack);
    assert.equal(byClass(env.root, 'tool-call-name')[0].innerHTML, '');
    assert.equal(byClass(env.root, 'tool-call-target')[0].innerHTML, '');
    assert.deepEqual(env.sanitized, [attack]);
    assert.equal(byClass(env.root, 'oasis-user-only-body')[0].innerHTML, '&lt;img src=x onerror=alert(1)&gt;');
    assert.equal(byClass(env.root, 'oasis-user-only-body').length, 1);
    const displayed = nodes(env.root).map(node => node.textContent + node.innerHTML).join('');
    assert.doesNotMatch(displayed, /OUTPUT_SECRET|ARGUMENT_SECRET|TARGET_SECRET|NESTED_SECRET/);
});

test('disable targets fall back to result identity and labels are translatable', () => {
    const env = fixture({ strings: { toolActivity: 'ツール実行', toolDisable: '無効化', toolSucceeded: '成功' } });
    env.activity.consume(event(tool('set_tool_disabled', 'disable', { status: 'OK', server: 'fixture', tool: 'read' })));
    assert.equal(byClass(env.root, 'tool-activity-title')[0].textContent, 'ツール実行');
    assert.equal(byClass(env.root, 'tool-call-kind')[0].textContent, '無効化');
    assert.deepEqual(env.statuses(), ['成功']);
    assert.equal(byClass(env.root, 'tool-call-target')[0].textContent, '→ fixture / read');
});

for (const opts of [{}, { bytewise: true }, { joined: true }, { mobile: true, bytewise: true }]) {
    test('shared send path keeps every stage and Unicode notice: ' + JSON.stringify(opts), async () => {
        const env = fixture(opts);
        const read = event(tool('router_status', 'read', { user_only: 'ルーターの状態を取得しました', ui_action: { type: 'fixture' } }));
        await env.send([
            event(tool('get_tool_list', 'list')), event(tool('set_tool_enabled', 'enable')),
            read, read, { message: { content: '確認できました。' } }
        ], opts);
        assert.deepEqual(env.errors, []);
        assert.deepEqual(env.names(), ['get_tool_list', 'set_tool_enabled', 'router_status']);
        assert.equal(byClass(env.root, 'oasis-user-only-body')[0].innerHTML, 'ルーターの状態を取得しました');
        assert.equal(env.actions.length, 1);
        assert.equal(env.text(), '確認できました。');
    });
}

test('EOF fallback shares notices, shutdown/restart actions, and UI-action deduping', async () => {
    const env = fixture();
    const call = tool('restart', 'same', { user_only: 'Confirm this action', ui_action: { type: 'fixture' }, prepare_service_restart: 'fixture-service' });
    await env.send([{ ...event(call, call), shutdown: true, message: { content: 'Ready.' } }], { eofFallback: true });
    assert.deepEqual(env.errors, []);
    assert.equal(env.cards().length, 1);
    assert.equal(byClass(env.root, 'oasis-user-only-body')[0].innerHTML, 'Confirm this action');
    assert.deepEqual(env.popups, ['shutdown', 'restart:fixture-service']);
    assert.equal(env.actions.length, 1);
    assert.equal(env.text(), 'Ready.');
});

test('invalid batches display an error and preserve subsequent valid results and final text', async () => {
    const env = fixture();
    await env.send([event(null, tool('valid', 'one')), { service: 'Fixture', tool_outputs: null },
        event(tool('another', 'two')), { message: { content: 'Final answer' } }]);
    assert.deepEqual(env.errors, []);
    assert.deepEqual(env.names(), ['valid', 'another']);
    assert.match(env.displayed(), /Invalid tool response\./);
    assert.match(env.text(), /Final answer/);
});

test('failed followup and disconnected streams retain already received tool cards', async () => {
    for (const disconnect of [false, true]) {
        const env = fixture();
        env.answer._typingTimer = 42;
        const events = [event(tool('read', 'one'))];
        if (!disconnect) events.push({ error: { message: 'Fixture followup failed' } });
        await env.send(events, { disconnect });
        assert.equal(env.cards().length, 1);
        assert.match(env.displayed(), disconnect ? /network error/ : /Fixture followup failed/);
        assert.equal(env.errors.length, disconnect ? 1 : 0);
        assert.equal(env.clearedTimer, 42);
        assert.equal(env.answer._typingTimer, undefined);
    }
});

test('plain chat, thinking, warnings and existing confirmation events remain supported', async () => {
    const env = fixture();
    await env.send([{ type: 'thinking', content: 'Thinking text' }, { warning: 'Fixture warning' },
        { type: 'execution', message: '' }, { type: 'download', message: '' },
        { type: 'execution', message: 'Working' }, { type: 'download', message: 'Downloading' },
        { message: { content: 'Answer' } }, { id: '123', reboot: true, uci_notify: true }]);
    assert.deepEqual(env.errors, []);
    assert.equal(env.cards().length, 0);
    assert.deepEqual(byClass(env.answer, 'turn-execution').map(node => node.innerHTML), ['Working']);
    assert.deepEqual(env.downloads, ['Downloading']);
    assert.deepEqual(env.popups, ['chat', 'uci', 'reboot']);
    assert.match(env.displayed(), /Thinking text/);
    assert.match(env.displayed(), /Fixture warning/);
    assert.match(env.text(), /Answer/);
});

test('Tool Activity uses white code text for both management and normal tool names', () => {
    const env = fixture();
    const names = ['get_tool_list', 'set_tool_enabled', 'set_tool_disabled', 'wifi_scan'];
    env.activity.consume(event(...names.map((name, index) => tool(name, 'color-' + index))));
    assert.deepEqual(env.names(), names);
    for (const node of byClass(env.root, 'tool-call-name')) {
        assert.equal(node.tagName, 'code');
    }
    const css = fs.readFileSync(path.join(jsDir, '../css/chat.css'), 'utf8');
    const rule = css.match(/\.message\s+\.message-text\s+\.tool-activity\s+code\.tool-call-name\s*\{([^}]+)\}/);
    assert.ok(rule, 'Tool Activity must have a scoped tool-name color rule');
    assert.match(rule[1], /\bcolor:\s*#ffffff\s*;/);
});

test('package installs and loads the renderer before chat.js with matching cache versions', () => {
    const packageRoot = path.resolve(jsDir, '../../../../../../..');
    const makefile = fs.readFileSync(path.join(packageRoot, 'Makefile'), 'utf8');
    const template = fs.readFileSync(path.join(packageRoot, 'files/luci/view/chat.htm'), 'utf8');
    const version = makefile.match(/PKG_VERSION:=(\S+)/)[1] + '-r' + makefile.match(/PKG_RELEASE:=(\S+)/)[1];
    assert.match(makefile, /INSTALL_DATA.*\/js\/chat-tools\.js/);
    assert.match(makefile, /INSTALL_DATA.*\/js\/chat-turn\.js/);
    assert.ok(template.indexOf('/js/chat-tools.js') < template.indexOf('/js/chat.js'));
    assert.ok(template.indexOf('/js/chat-turn.js') < template.indexOf('/js/chat.js'));
    for (const asset of ['js/chat-tools.js', 'js/chat-turn.js', 'js/chat.js', 'css/chat.css']) {
        assert.ok(template.includes(asset + '?v=' + version), asset);
    }
});

for (const options of [{}, { mobile: true }, { bytewise: true }, { joined: true }]) {
    test('interleaved text and tools stay in receive order in one bubble: ' + JSON.stringify(options), async () => {
        const env = fixture(options);
        let firstText, firstCard, firstNotice;
        await env.send([
            { message: { content: 'Checking. ' } },
            event(tool('get_tool_list', 'list')),
            event(tool('set_tool_enabled', 'enable', { status: 'OK', user_only: 'Ready to inspect' })),
            { message: { content: 'Reading ' } },
            { message: { content: 'Wi-Fi. ' } },
            event(tool('get_wifi_config', 'wifi', { user_only: 'Wi-Fi notice', ui_action: { type: 'fixture' } })),
            { message: { content: 'Result: ' } },
            { message: { content: '**available**' } }
        ], { ...options, flushEachChunk: true, onRead() {
            firstText ||= byClass(env.answer, 'turn-text')[0];
            firstCard ||= env.cards()[0];
            firstNotice ||= byClass(env.answer, 'oasis-user-only-body')[0];
        } });
        assert.deepEqual(env.answer.children.map(node => node.className),
            ['turn-text', 'turn-tools', 'turn-text', 'turn-tools', 'turn-text']);
        assert.deepEqual(byClass(env.answer, 'turn-text').map(node => node.innerHTML),
            ['Checking. ', 'Reading Wi-Fi. ', 'Result: **available**']);
        assert.deepEqual(env.names(), ['get_tool_list', 'set_tool_enabled', 'get_wifi_config']);
        assert.equal(env.root.children.length, 1);
        assert.equal(byClass(env.root, 'message').length, 1);
        assert.equal(byClass(env.answer, 'tool-activity').length, 2);
        assert.equal(byClass(env.answer, 'tool-activity-list')[1].start, 3);
        assert.equal(byClass(env.answer, 'turn-text')[0], firstText);
        assert.equal(env.cards()[0], firstCard);
        assert.equal(byClass(env.answer, 'oasis-user-only-body')[0], firstNotice);
        assert.deepEqual(byClass(env.answer, 'oasis-user-only-body').map(node => node.innerHTML),
            ['Ready to inspect', 'Wi-Fi notice']);
        assert.equal(env.actions.length, 1);
        assert.equal(env.answer.attributes['aria-busy'], 'false');
        assert.equal(env.pendingTimers(), 0);
    });
}

test('replays between text chunks neither split the text nor reopen tool actions', async () => {
    const env = fixture();
    const original = event(tool('read', 'same', { user_only: 'Notice', ui_action: { type: 'fixture' } }));
    await env.send([original, { message: { content: 'One ' } }, original,
        { message: { content: 'answer.' } }, event(tool('read', 'new')),
        { message: { content: 'Second.' } }, original]);
    assert.deepEqual(env.answer.children.map(node => node.className),
        ['turn-tools', 'turn-text', 'turn-tools', 'turn-text']);
    assert.deepEqual(byClass(env.answer, 'turn-text').map(node => node.innerHTML), ['One answer.', 'Second.']);
    assert.equal(env.cards().length, 2);
    assert.equal(env.actions.length, 1);
});

for (const mobile of [false, true]) {
    test('text is visible before EOF on ' + (mobile ? 'mobile' : 'desktop'), async () => {
        const env = fixture({ mobile });
        const observed = [];
        await env.send([{ message: { content: 'First ' } }, { message: { content: 'second' } }], {
            flushEachChunk: true,
            onRead() { observed.push(env.text()); }
        });
        assert.ok(observed.includes('First '));
        assert.equal(env.text(), 'First second');
        assert.equal(byClass(env.answer, 'turn-text').length, 1);
    });
}

test('text renders are batched and boundaries seal earlier DOM nodes', () => {
    const env = fixture();
    const turn = env.createTurn();
    turn.appendText('a');
    turn.appendText('b');
    turn.appendText('c');
    assert.equal(env.pendingTimers(), 1);
    assert.deepEqual(env.sanitized, []);
    env.flushTimers();
    assert.deepEqual(env.sanitized, ['abc']);
    const first = env.answer.children[0];
    const tools = env.context.window.OasisChatTools.create({
        getContainer: turn.toolContainer, t: env.context.t,
        sanitizeHTML: env.context.sanitizeHTML, convertMarkdownToHTML: value => value
    });
    tools.consume(event(tool('read', 'one', { user_only: 'important' })));
    const card = env.cards()[0];
    turn.appendText('tail');
    turn.finish();
    turn.finish();
    env.flushTimers();
    assert.equal(env.answer.children[0], first);
    assert.equal(first.innerHTML, 'abc');
    assert.equal(env.cards()[0], card);
    assert.deepEqual(env.sanitized, ['abc', 'important', 'tail']);
    assert.equal(env.pendingTimers(), 0);
    assert.equal(byClass(env.answer, 'turn-pending').length, 0);
});

test('thinking, execution notices and warnings keep their positions without extra bubbles', async () => {
    const env = fixture();
    await env.send([{ message: { content: 'Start' } },
        { type: 'thinking', content: '<fixture thinking>' },
        { type: 'execution', message: 'Working' }, event(tool('read', 'one')),
        { warning: { message: 'Warning' } }, { message: { content: 'End' } }]);
    assert.deepEqual(env.answer.children.map(node => node.className),
        ['turn-text', 'thinking-panel', 'turn-execution', 'turn-tools', 'error-notice', 'turn-text']);
    assert.equal(byClass(env.answer, 'thinking-body')[0].textContent, '<fixture thinking>');
    assert.equal(byClass(env.answer, 'thinking-body')[0].innerHTML, '');
    assert.equal(env.root.children.length, 1);
});

test('disconnect preserves partial text, tool notices and safe inline errors', async () => {
    const env = fixture();
    await env.send([{ message: { content: 'Before' } },
        event(tool('read', 'one', { user_only: 'Keep this notice' })),
        { message: { content: 'Partial answer' } }], { disconnect: true });
    assert.deepEqual(env.answer.children.map(node => node.className),
        ['turn-text', 'turn-tools', 'turn-text', 'error-notice']);
    assert.equal(env.text(), 'BeforePartial answer');
    assert.match(env.displayed(), /Keep this notice.*Partial answer.*network error/);
    assert.equal(env.answer.attributes['aria-busy'], 'false');
    assert.equal(env.context.activeConversation, false);
    assert.equal(env.pendingTimers(), 0);
});

test('empty, whitespace-only and HTTP-error turns do not leave a blank response', async () => {
    for (const events of [[], [{ message: { content: ' \n\t' } }]]) {
        const env = fixture();
        await env.send(events);
        assert.match(env.displayed(), /No response from AI service/);
        assert.equal(env.pendingTimers(), 0);
    }
    const env = fixture();
    await env.send([], { httpError: true });
    assert.match(env.displayed(), /network error/);
    assert.equal(env.answer.attributes['aria-busy'], 'false');
});

test('tool-only responses retain Additional message without an empty extra bubble', async () => {
    const env = fixture();
    await env.send([event(tool('update_wifi_config', 'one', {
        user_only: 'Please confirm the configuration', ui_action: { type: 'wifi_config', operation: 'update' }
    }))]);
    assert.deepEqual(env.answer.children.map(node => node.className), ['turn-tools']);
    assert.match(env.displayed(), /Please confirm the configuration/);
    assert.equal(env.actions.length, 1);
    assert.equal(env.root.children.length, 1);
});

test('Markdown failures fall back to safe text and missing assets release the send lock', async () => {
    const env = fixture();
    env.context.convertMarkdownToHTML = () => { throw new Error('fixture formatter'); };
    const turn = env.createTurn();
    turn.appendText('<img src=x onerror=fixture()>');
    turn.finish();
    const text = byClass(env.answer, 'turn-text')[0];
    assert.equal(text.textContent, '<img src=x onerror=fixture()>');
    assert.equal(text.innerHTML, '');
    env.context.window.OasisChatTurn = undefined;
    await env.send([]);
    assert.match(env.displayed(), /network error/);
    assert.equal(env.context.activeConversation, false);
});

function scrollFixture() {
    const frames = [];
    const container = { scrollHeight: 1000, clientHeight: 400, scrollTop: 0, querySelector: () => ({}) };
    const context = {
        window: { __oasisStickToBottom: true },
        document: { querySelector: () => container, getElementById: () => null },
        requestAnimationFrame: callback => { frames.push(callback); return frames.length; }
    };
    const start = chatSource.indexOf('    let chatScrollFrame = null;');
    const end = chatSource.indexOf('    // Align conversation start', start);
    const trackStart = chatSource.indexOf('        function updateStickToBottomFlag()');
    const trackEnd = chatSource.indexOf('        const cmInit', trackStart);
    assert.ok(start > 0 && end > start && trackStart > 0 && trackEnd > trackStart);
    vm.runInNewContext(chatSource.slice(start, end) + chatSource.slice(trackStart, trackEnd), context);
    return { container, context, frames, tick() { frames.splice(0).forEach(callback => callback()); } };
}

test('long responses follow only the tail and coalesce scroll requests', () => {
    const env = scrollFixture();
    env.context.keepLatestMessageVisible();
    env.context.keepLatestMessageVisible();
    assert.equal(env.frames.length, 1);
    env.tick();
    assert.equal(env.container.scrollTop, 600);
    env.context.keepLatestMessageVisible();
    env.tick();
    assert.equal(env.container.scrollTop, 600);
    env.container.scrollHeight = 1200;
    env.context.updateStickToBottomFlag();
    assert.equal(env.context.window.__oasisStickToBottom, true, 'growth is not a manual scroll');
    env.context.keepLatestMessageVisible();
    env.tick();
    assert.equal(env.container.scrollTop, 800);
});

test('reading earlier content cancels even queued or forced follow requests', () => {
    const env = scrollFixture();
    env.context.keepLatestMessageVisible();
    env.tick();
    env.context.keepLatestMessageVisible();
    env.container.scrollTop = 200;
    env.context.updateStickToBottomFlag();
    env.tick();
    assert.equal(env.context.window.__oasisStickToBottom, false);
    assert.equal(env.container.scrollTop, 200);
    env.context.keepLatestMessageVisible(true);
    assert.equal(env.frames.length, 0);
    env.context.window.__oasisStickToBottom = true; // Explicit "latest" button.
    env.context.keepLatestMessageVisible();
    env.tick();
    assert.equal(env.container.scrollTop, 600);
});
