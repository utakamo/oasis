// Dependency-free DOM/HTTP fixtures for Tools page behavior (not a browser
// rendering test). Run: node --test dev_tools/tests/test_tools_ui.cjs
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
  '../../luci-app-oasis/files/luci/www/luci-static/resources/oasis/js/tools.js'), 'utf8');

class Element {
  constructor(tag = 'div') {
    this.tagName = tag;
    this.children = [];
    this.style = {};
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.className = '';
    this.textContent = '';
    this.disabled = false;
    this.classList = {
      add: name => { this.className += ` ${name}`; },
      remove: name => { this.className = this.className.split(' ').filter(v => v !== name).join(' '); }
    };
  }
  set innerHTML(value) { assert.equal(value, ''); this.children = []; }
  appendChild(child) { this.children.push(child); return child; }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
  async click() {
    if (!this.disabled) for (const fn of this.listeners.click || []) await fn();
  }
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise(resolve => setImmediate(resolve));
};

function fixture(options = {}) {
  const env = {
    auto: options.auto === true, manual: true, selected: false,
    localTool: true, calls: [], modeError: false, corrupt: false,
    ...options
  };
  const ids = new Map();
  const get = id => {
    if (!ids.has(id)) ids.set(id, new Element());
    return ids.get(id);
  };
  const snapshot = () => {
    const tools = {};
    for (const name of ['get_tool_list', 'set_tool_enabled', 'set_tool_disabled', 'weather']) {
      tools[name] = { '.type': 'tool', type: 'function', name,
        server: name === 'weather' ? 'fixture.weather' : 'oasis.tool.manager',
        enable: name === 'weather' ? ((env.auto ? env.selected : env.manual) ? '1' : '0') : (env.auto ? '1' : '0') };
    }
    return { status: env.corrupt ? 'NG' : 'OK', error: env.corrupt ? 'Invalid Auto state' : undefined,
      mode_available: true, auto_mode: env.auto, local_tool: env.localTool, tools };
  };
  const context = {
    window: { OasisToolsConfig: { csrfToken: 'fixture-token', urls: {
      enableTool: '/enable', disableTool: '/disable', setToolAuto: '/auto',
      refreshTools: '/refresh', loadTools: '/tools', loadManifest: '/manifest'
    } } },
    document: { getElementById: get, createElement: tag => new Element(tag) },
    console: { warn() {}, error() {} }, URLSearchParams,
    setTimeout() {}, location: { reload() {} },
    fetch: async (url, init = {}) => {
      env.calls.push({ url, init });
      if (url === '/tools') return { ok: true, json: async () => snapshot() };
      assert.equal(init.method, 'POST');
      assert.equal(init.body.get('token'), 'fixture-token');
      if (url === '/auto') {
        if (env.modeError) return { ok: true, json: async () => ({ status: 'NG', error: 'Mode save failed' }) };
        env.auto = init.body.get('enable') === '1';
        if (env.loseModeResponse) throw new Error('Connection lost after commit');
      } else {
        assert.ok(['/enable', '/disable'].includes(url));
        assert.equal(env.auto, false, 'Manual mutation attempted while Auto was active');
        assert.equal(init.body.get('name'), 'weather');
        assert.equal(init.body.get('server'), 'fixture.weather');
        env.manual = url === '/enable';
      }
      return { ok: true, json: async () => ({ status: 'OK' }) };
    }
  };
  vm.runInNewContext(source, context);
  env.root = get('oasis-tool-container');
  env.get = get;
  env.nodes = function walk(node = env.root) {
    return [node, ...node.children.flatMap(child => walk(child))];
  };
  env.button = text => env.nodes().find(node => node.tagName === 'button' && node.textContent === text);
  return env;
}

test('Manual mode hides manager cards and retains per-tool controls', async () => {
  const env = fixture(); await settle();
  assert.equal(env.button('Auto: OFF').attributes['aria-pressed'], 'false');
  assert.equal(env.nodes().filter(node => node.className === 'cell').length, 1);
  assert.ok(!env.nodes().some(node => node.textContent === 'get_tool_list'));
  await env.button('Disable').click(); await settle();
  assert.equal(env.manual, false);
  assert.ok(env.button('Enable'));
});

test('Auto toggle uses POST and CSRF and shows AI-managed cards', async () => {
  const env = fixture(); await settle();
  await env.button('Auto: OFF').click(); await settle();
  assert.equal(env.auto, true);
  assert.equal(env.button('Auto: ON').attributes['aria-pressed'], 'true');
  assert.equal(env.button('Managed by AI').disabled, true);
  assert.ok(env.nodes().some(node => node.className === 'status-pill' && node.textContent === 'Disabled'));
  const count = env.calls.length;
  await env.button('Managed by AI').click(); await settle();
  assert.equal(env.calls.length, count);
  assert.equal(env.manual, true);
});

test('OFF ON preserves each selection and page load honors persisted Auto', async () => {
  const env = fixture({ auto: true, selected: true, manual: false }); await settle();
  assert.ok(env.button('Auto: ON'));
  await env.button('Auto: ON').click(); await settle();
  assert.ok(env.button('Enable'));
  await env.button('Auto: OFF').click(); await settle();
  assert.equal(env.selected, true);
  assert.equal(env.manual, false);
  assert.ok(env.nodes().some(node => node.className === 'status-pill enabled'));
});

test('failed mode save restores authoritative UI and reports the failure', async () => {
  const env = fixture({ modeError: true }); await settle();
  await env.button('Auto: OFF').click(); await settle();
  assert.equal(env.auto, false);
  assert.equal(env.button('Auto: OFF').disabled, false);
  assert.equal(env.get('tools-error-message').textContent, 'Mode save failed');
});

test('a lost POST response reloads the committed mode instead of guessing', async () => {
  const env = fixture({ loseModeResponse: true }); await settle();
  await env.button('Auto: OFF').click(); await settle();
  assert.equal(env.auto, true);
  assert.ok(env.button('Auto: ON'));
  assert.equal(env.button('Managed by AI').disabled, true);
});

test('damaged Auto state leaves the OFF switch available', async () => {
  const env = fixture({ auto: true, corrupt: true }); await settle();
  assert.equal(env.button('Auto: ON').disabled, false);
  assert.equal(env.nodes().filter(node => node.className === 'cell').length, 0);
  assert.equal(env.get('tools-error-message').textContent, 'Invalid Auto state');
  env.corrupt = false;
  await env.button('Auto: ON').click(); await settle();
  assert.ok(env.button('Disable'));
});

test('the existing local-tool master switch still hides tool controls', async () => {
  const env = fixture({ localTool: false }); await settle();
  assert.equal(env.get('tools-head').style.display, 'none');
  assert.equal(env.button('Auto: OFF'), undefined);
});
