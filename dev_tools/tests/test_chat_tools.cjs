// Dependency-free DOM/stream fixtures, not browser layout tests.
// Run: node --test dev_tools/tests/test_chat_tools.cjs
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const jsDir = path.join(__dirname, '../../luci-app-oasis/files/luci/www/luci-static/resources/oasis/js');
const toolsSource = fs.readFileSync(path.join(jsDir, 'chat-tools.js'), 'utf8');
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
    }
    set textContent(value) { this.text = String(value); this.children = []; }
    get textContent() { return this.text + this.children.map(child => child.textContent).join(''); }
    set innerHTML(value) { this.html = value; this.children = []; }
    get innerHTML() { return this.html; }
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
    insertBefore(child, next) {
        const index = this.children.indexOf(next);
        assert.ok(index >= 0);
        child.parentNode = this;
        this.children.splice(index, 0, child);
    }
    contains(child) { return this.children.includes(child) || this.children.some(node => node.contains(child)); }
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
    const answer = assistant.appendChild(new Element());
    const env = { root, assistant, answer, errors: [], actions: [], popups: [], sanitized: [], execution: [], downloads: [] };
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
        setTimeout: callback => { callback(); return 0; },
        answer
    };
    vm.runInNewContext(utilsSource, context);
    context.extractJsonObjects = context.window.OasisChatUtils.extractJsonObjects;
    context.escapeHTML = context.window.OasisChatUtils.escapeHTML;
    // The renderer must route all user_only Markdown through the existing
    // sanitizer. This fixture spies on that boundary, not browser HTML parsing.
    context.sanitizeHTML = value => { env.sanitized.push(value); return context.escapeHTML(value); };
    vm.runInNewContext(toolsSource, context);
    const create = () => context.window.OasisChatTools.create({
        container: root, before: assistant, resourcePath: '/resources', iconName: 'fixture.png',
        t: context.t, sanitizeHTML: context.sanitizeHTML, convertMarkdownToHTML: context.convertMarkdownToHTML
    });
    env.activity = create();
    env.create = create;
    env.context = context;
    env.cards = () => byClass(root, 'tool-call');
    env.names = () => byClass(root, 'tool-call-name').map(node => node.textContent);
    env.statuses = () => byClass(root, 'tool-call-status').map(node => node.textContent);
    env.send = async (events, opts = {}) => {
        let chunks = events.map(item => Buffer.from(JSON.stringify(item) + '\n'));
        if (opts.bytewise) chunks = chunks.flatMap(chunk => Array.from(chunk, byte => Buffer.from([byte])));
        if (opts.joined) chunks = [Buffer.concat(chunks)];
        context.fetch = async () => ({ ok: true, body: { getReader: () => ({ read: async () => {
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
    };
    return env;
}

test('three Auto stages have individual ordered cards before the assistant', () => {
    const env = fixture();
    const calls = [tool('get_tool_list', 'list'),
        tool('set_tool_enabled', 'enable', { status: 'OK', changed: true }, JSON.stringify({ server: 'fixture.router', tool: 'router_status' })),
        tool('router_status', 'read', { value: 'up' })];
    calls.forEach(call => env.activity.consume(event(call)));
    assert.deepEqual(env.names(), ['get_tool_list', 'set_tool_enabled', 'router_status']);
    assert.equal(byClass(env.root, 'tool-activity').length, 1);
    assert.equal(byClass(env.root, 'tool-call-management').length, 2);
    assert.equal(env.root.children[0].className, 'message received tool-activity');
    assert.equal(env.root.children[1], env.assistant);
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
        assert.equal(env.answer.innerHTML, '確認できました。');
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
    assert.equal(env.answer.innerHTML, 'Ready.');
});

test('invalid batches display an error and preserve subsequent valid results and final text', async () => {
    const env = fixture();
    await env.send([event(null, tool('valid', 'one')), { service: 'Fixture', tool_outputs: null },
        event(tool('another', 'two')), { message: { content: 'Final answer' } }]);
    assert.deepEqual(env.errors, []);
    assert.deepEqual(env.names(), ['valid', 'another']);
    assert.match(env.answer.innerHTML, /Invalid tool response\./);
    assert.match(env.answer.innerHTML, /Final answer/);
});

test('failed followup and disconnected streams retain already received tool cards', async () => {
    for (const disconnect of [false, true]) {
        const env = fixture();
        env.answer._typingTimer = 42;
        const events = [event(tool('read', 'one'))];
        if (!disconnect) events.push({ error: { message: 'Fixture followup failed' } });
        await env.send(events, { disconnect });
        assert.equal(env.cards().length, 1);
        assert.match(env.answer.innerHTML, disconnect ? /network error/ : /Fixture followup failed/);
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
    assert.deepEqual(env.execution, ['Working']);
    assert.deepEqual(env.downloads, ['Downloading']);
    assert.deepEqual(env.popups, ['chat', 'uci', 'reboot']);
    assert.match(env.answer.innerHTML, /Thinking text/);
    assert.match(env.answer.innerHTML, /Fixture warning/);
    assert.match(env.answer.innerHTML, /Answer/);
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
    const rule = css.match(/\.message\.tool-activity\s+\.message-text\s+code\.tool-call-name\s*\{([^}]+)\}/);
    assert.ok(rule, 'Tool Activity must have a scoped tool-name color rule');
    assert.match(rule[1], /\bcolor:\s*#ffffff\s*;/);
});

test('package installs and loads the renderer before chat.js with matching cache versions', () => {
    const packageRoot = path.resolve(jsDir, '../../../../../../..');
    const makefile = fs.readFileSync(path.join(packageRoot, 'Makefile'), 'utf8');
    const template = fs.readFileSync(path.join(packageRoot, 'files/luci/view/chat.htm'), 'utf8');
    const version = makefile.match(/PKG_VERSION:=(\S+)/)[1] + '-r' + makefile.match(/PKG_RELEASE:=(\S+)/)[1];
    assert.match(makefile, /INSTALL_DATA.*\/js\/chat-tools\.js/);
    assert.ok(template.indexOf('/js/chat-tools.js') < template.indexOf('/js/chat.js'));
    for (const asset of ['js/chat-tools.js', 'js/chat.js', 'css/chat.css']) {
        assert.ok(template.includes(asset + '?v=' + version), asset);
    }
});
