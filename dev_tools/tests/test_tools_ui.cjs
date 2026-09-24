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
  constructor(tag = 'div', ownerDocument) {
    this.tagName = tag;
    this.children = [];
    this.style = {};
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.className = '';
    this.textContent = '';
    this.disabled = false;
    this.ownerDocument = ownerDocument;
    this.classList = {
      add: name => { this.className += ` ${name}`; },
      remove: name => { this.className = this.className.split(' ').filter(v => v !== name).join(' '); }
    };
  }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this._text = value; this.children = []; }
  set innerHTML(value) {
    assert.equal(value, '');
    if (this.ownerDocument && this.contains(this.ownerDocument.activeElement)) {
      this.ownerDocument.activeElement = this.ownerDocument.body;
    }
    this.children = [];
  }
  contains(node) { return this === node || this.children.some(child => child.contains(node)); }
  appendChild(child) { this.children.push(child); return child; }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
  async click() {
    if (!this.disabled) for (const fn of this.listeners.click || []) await fn();
  }
  focus() { this.ownerDocument.activeElement = this; }
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise(resolve => setImmediate(resolve));
};

function fixture(options = {}) {
  const env = {
    auto: options.auto === true, manual: true, selected: false,
    localTool: true, calls: [], modeError: false, corrupt: false, modeAvailable: true, loads: 0,
    ...options
  };
  const ids = new Map();
  const document = { body: new Element('body') };
  document.activeElement = document.body;
  const get = id => {
    if (!ids.has(id)) ids.set(id, new Element('div', document));
    return ids.get(id);
  };
  const snapshot = () => {
    const tools = {};
    for (const name of ['get_tool_list', 'set_tool_enabled', 'set_tool_disabled', 'weather']) {
      tools[name] = { '.type': 'tool', type: 'function', name,
        server: name === 'weather' ? 'fixture.weather' : 'oasis.tool.manager',
        conflict: name === 'weather' && env.conflict ? '1' : '0',
        enable: name === 'weather' ? ((env.auto ? env.selected : env.manual) ? '1' : '0') : (env.auto ? '1' : '0') };
    }
    return { status: env.corrupt ? 'NG' : 'OK', error: env.corrupt ? 'Invalid Auto state' : undefined,
      mode_available: env.modeAvailable, auto_mode: env.auto, local_tool: env.localTool, tools };
  };
  document.getElementById = get;
  document.createElement = tag => new Element(tag, document);
  const context = {
    window: { OasisToolsStrings: env.strings || {}, OasisToolsConfig: { csrfToken: 'fixture-token', urls: {
      enableTool: '/enable', disableTool: '/disable', setToolAuto: '/auto',
      refreshTools: '/refresh', loadTools: '/tools', loadManifest: '/manifest'
    } } },
    document,
    console: { warn() {}, error() {} }, URLSearchParams,
    setTimeout() {}, location: { reload() {} },
    fetch: async (url, init = {}) => {
      env.calls.push({ url, init });
      if (url === '/tools') {
        env.loads++;
        if (env.loadGate) await env.loadGate;
        if (env.loadError) throw new Error('Snapshot unavailable');
        return { ok: !env.loadHttpError, json: async () => env.badSnapshot ? {} : snapshot() };
      }
      assert.equal(init.method, 'POST');
      assert.equal(init.body.get('token'), 'fixture-token');
      if (env.postGate) await env.postGate;
      if (env.httpError) return { ok: false, json: async () => ({ status: 'OK' }) };
      if (url === '/auto') {
        if (env.modeError) return { ok: true, json: async () => ({ status: 'NG', error: 'Mode save failed' }) };
        env.auto = init.body.get('enable') === '1';
        if (env.loseModeResponse) throw new Error('Connection lost after commit');
      } else {
        assert.ok(['/enable', '/disable'].includes(url));
        assert.equal(env.auto, false, 'Manual mutation attempted while Auto was active');
        assert.equal(init.body.get('name'), 'weather');
        assert.equal(init.body.get('server'), 'fixture.weather');
        if (env.toolError) return { ok: true, json: async () => ({ status: 'NG', error: 'Tool save failed' }) };
        env.manual = url === '/enable';
        if (env.loseToolResponse) throw new Error('Connection lost after commit');
      }
      return { ok: true, json: async () => ({ status: 'OK' }) };
    }
  };
  vm.runInNewContext(source, context);
  env.root = get('oasis-tool-container');
  env.get = get;
  env.document = document;
  env.nodes = function walk(node = env.root) {
    return [node, ...node.children.flatMap(child => walk(child))];
  };
  env.button = text => env.nodes().find(node => node.tagName === 'button' && node.textContent === text);
  env.switch = name => env.nodes().find(node => node.attributes.role === 'switch' && node.attributes['aria-label'] === name);
  return env;
}

test('Manual mode hides manager cards and retains per-tool controls', async () => {
  const env = fixture(); await settle();
  assert.equal(env.button('Auto: OFF').attributes['aria-checked'], 'false');
  assert.equal(env.nodes().filter(node => node.className === 'cell').length, 1);
  assert.ok(!env.nodes().some(node => node.textContent === 'get_tool_list'));
  await env.button('Enabled').click(); await settle();
  assert.equal(env.manual, false);
  assert.ok(env.button('Disabled'));
  assert.equal(env.switch('fixture.weather / weather').attributes['aria-checked'], 'false');
});

test('Auto toggle uses POST and CSRF and shows AI-managed cards', async () => {
  const env = fixture(); await settle();
  await env.button('Auto: OFF').click(); await settle();
  assert.equal(env.auto, true);
  assert.equal(env.button('Auto: ON').attributes['aria-checked'], 'true');
  assert.equal(env.button('Disabled').disabled, true);
  assert.ok(env.nodes().some(node => node.className === 'tools-switch-note' && node.textContent === 'Managed by AI'));
  assert.ok(env.nodes().some(node => node.className === 'status-pill' && node.textContent === 'Disabled'));
  const count = env.calls.length;
  await env.button('Disabled').click(); await settle();
  assert.equal(env.calls.length, count);
  assert.equal(env.manual, true);
});

test('OFF ON preserves each selection and page load honors persisted Auto', async () => {
  const env = fixture({ auto: true, selected: true, manual: false }); await settle();
  assert.ok(env.button('Auto: ON'));
  await env.button('Auto: ON').click(); await settle();
  assert.ok(env.button('Disabled'));
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
  assert.equal(env.switch('fixture.weather / weather').disabled, true);
});

test('damaged Auto state leaves the OFF switch available', async () => {
  const env = fixture({ auto: true, corrupt: true }); await settle();
  assert.equal(env.button('Auto: ON').disabled, false);
  assert.equal(env.nodes().filter(node => node.className === 'cell').length, 0);
  assert.equal(env.get('tools-error-message').textContent, 'Invalid Auto state');
  env.corrupt = false;
  await env.button('Auto: ON').click(); await settle();
  assert.ok(env.button('Enabled'));
});

test('the existing local-tool master switch still hides tool controls', async () => {
  const env = fixture({ localTool: false }); await settle();
  assert.equal(env.get('tools-head').style.display, 'none');
  assert.equal(env.button('Auto: OFF'), undefined);
});

test('switches expose stable names, native keyboard activation, and current state', async () => {
  const env = fixture(); await settle();
  const toggle = env.switch('fixture.weather / weather');
  assert.equal(toggle.tagName, 'button');
  assert.equal(toggle.type, 'button');
  assert.equal(toggle.attributes['aria-checked'], 'true');
  assert.equal(toggle.children[0].attributes['aria-hidden'], 'true');
  assert.equal(toggle.listeners.keydown, undefined, 'Use native Enter/Space handling, not duplicate handlers');
  toggle.focus();
  await toggle.click();
  const updated = env.switch('fixture.weather / weather');
  assert.equal(updated.attributes['aria-checked'], 'false');
  assert.equal(updated.textContent, 'Disabled');
  assert.equal(env.document.activeElement, updated, 'Restore focus after rebuilding the controls');
  await updated.click();
  assert.equal(env.switch('fixture.weather / weather').attributes['aria-checked'], 'true');
});

for (const selected of [false, true]) {
  test('Auto tool switches are read-only and show the effective state: ' + selected, async () => {
    const env = fixture({ auto: true, selected, manual: !selected }); await settle();
    const toggle = env.switch('fixture.weather / weather');
    assert.equal(toggle.attributes['aria-checked'], String(selected));
    assert.equal(toggle.disabled, true);
    assert.equal(toggle.title, 'Managed by AI');
    const before = env.calls.length;
    await toggle.click();
    assert.equal(env.calls.length, before);
  });
}

test('conflicted tools and unavailable Auto mode cannot be changed', async () => {
  const env = fixture({ conflict: true, modeAvailable: false }); await settle();
  assert.equal(env.switch('Auto mode').disabled, true);
  assert.equal(env.switch('fixture.weather / weather').disabled, true);
  assert.equal(env.switch('fixture.weather / weather').title, 'Conflict: cannot change state');
  await env.switch('Auto mode').click();
  await env.switch('fixture.weather / weather').click();
  assert.equal(env.calls.length, 1);
});

for (const name of ['Auto mode', 'fixture.weather / weather']) {
  test('state saves lock all switches through POST and snapshot reload: ' + name, async () => {
    const env = fixture(); await settle();
    let releasePost, releaseLoad;
    env.postGate = new Promise(resolve => { releasePost = resolve; });
    env.loadGate = new Promise(resolve => { releaseLoad = resolve; });
    const toggle = env.switch(name);
    const previous = toggle.attributes['aria-checked'];
    const pending = toggle.click();
    await settle();
    assert.equal(toggle.textContent, 'Loading...');
    assert.equal(toggle.attributes['aria-busy'], 'true');
    assert.equal(toggle.attributes['aria-checked'], previous, 'Do not claim success before saving');
    for (const node of env.nodes().filter(node => node.attributes.role === 'switch')) {
      assert.equal(node.disabled, true);
      await node.click();
    }
    assert.equal(env.calls.filter(call => call.init.method === 'POST').length, 1);
    releasePost(); await settle();
    assert.equal(env.loads, 2);
    assert.equal(toggle.disabled, true, 'Keep the lock while reading the saved state');
    releaseLoad(); await pending;
    assert.equal(env.switch(name).attributes['aria-busy'], 'false');
    assert.equal(env.switch(name).attributes['aria-checked'], String(previous !== 'true'));
    assert.equal(env.switch('Auto mode').disabled, false);
    // Even a stale detached control must not issue another POST.
    await toggle.listeners.click[0]();
    assert.equal(env.calls.filter(call => call.init.method === 'POST').length, 1);
  });
}

test('saving does not steal focus if the user moved to another control', async () => {
  const env = fixture(); await settle();
  let release;
  env.postGate = new Promise(resolve => { release = resolve; });
  const toggle = env.switch('fixture.weather / weather');
  toggle.focus();
  const pending = toggle.click();
  env.get('tools-refresh').focus();
  release(); await pending;
  assert.equal(env.document.activeElement, env.get('tools-refresh'));
});

test('a rejected tool save restores the server state and reports an error', async () => {
  const env = fixture({ toolError: true }); await settle();
  await env.switch('fixture.weather / weather').click();
  assert.equal(env.manual, true);
  assert.equal(env.switch('fixture.weather / weather').attributes['aria-checked'], 'true');
  assert.equal(env.switch('fixture.weather / weather').disabled, false);
  assert.equal(env.get('tools-error-message').textContent, 'Tool save failed');
});

test('a lost tool save response uses the committed state, not the previous state', async () => {
  const env = fixture({ loseToolResponse: true }); await settle();
  await env.switch('fixture.weather / weather').click();
  assert.equal(env.manual, false);
  assert.equal(env.switch('fixture.weather / weather').attributes['aria-checked'], 'false');
  assert.equal(env.switch('fixture.weather / weather').disabled, false);
  assert.equal(env.get('tools-error-message').textContent, 'Connection lost after commit');
});

for (const name of ['Auto mode', 'fixture.weather / weather']) {
  test('an HTTP error is not treated as a successful save: ' + name, async () => {
    const env = fixture({ httpError: true }); await settle();
    const previous = env.switch(name).attributes['aria-checked'];
    await env.switch(name).click();
    assert.equal(env.switch(name).attributes['aria-checked'], previous);
    assert.equal(env.switch(name).disabled, false);
    assert.equal(env.get('tools-error-message').textContent, 'Failed to update tool state');
  });
}

for (const failure of ['loadError', 'loadHttpError', 'badSnapshot']) {
  test('unavailable saved state locks switches instead of guessing: ' + failure, async () => {
    const env = fixture(); await settle();
    env[failure] = true;
    await env.switch('Auto mode').click();
    assert.equal(env.auto, true, 'The server saved the mode, but its snapshot was not received');
    for (const toggle of env.nodes().filter(node => node.attributes.role === 'switch')) {
      assert.equal(toggle.disabled, true);
      assert.equal(toggle.attributes['aria-busy'], 'false');
      await toggle.click();
    }
    assert.equal(env.calls.filter(call => call.init.method === 'POST').length, 1);
    assert.equal(env.get('tools-error-message').textContent, 'Failed to update tool state');
  });
}

test('switch status and AI management notes use existing localized strings', async () => {
  const strings = { autoMode: '自動モード', autoOn: '自動: ON', autoOff: '自動: OFF',
    enabled: '有効', disabled: '無効', autoManaged: 'AIが管理' };
  const env = fixture({ strings }); await settle();
  assert.equal(env.switch('自動モード').textContent, '自動: OFF');
  assert.equal(env.switch('fixture.weather / weather').textContent, '有効');
  await env.switch('自動モード').click();
  assert.equal(env.switch('fixture.weather / weather').textContent, '無効');
  assert.ok(env.nodes().some(node => node.className === 'tools-switch-note' && node.textContent === 'AIが管理'));
});

test('switch styling and packaged assets retain colors, focus, and cache versions', () => {
  const pkg = path.join(__dirname, '../../luci-app-oasis');
  const css = fs.readFileSync(path.join(pkg, 'files/luci/www/luci-static/resources/oasis/css/tools.css'), 'utf8');
  assert.match(css, /\.tools-switch-auto\[aria-checked="true"\] \.tools-switch-track\s*\{[^}]*#db2777/);
  assert.match(css, /\.tools-switch\[aria-checked="true"\] \.tools-switch-track\s*\{[^}]*#198754/);
  assert.match(css, /\.tools-switch-track\s*\{[^}]*background: #6b7280/);
  assert.match(css, /\.tools-switch:focus-visible\s*\{[^}]*outline:/);
  assert.match(css, /prefers-reduced-motion: reduce/);
  const makefile = fs.readFileSync(path.join(pkg, 'Makefile'), 'utf8');
  const version = makefile.match(/PKG_VERSION:=(\S+)/)[1] + '-r' + makefile.match(/PKG_RELEASE:=(\S+)/)[1];
  const template = fs.readFileSync(path.join(pkg, 'files/luci/view/tools.htm'), 'utf8');
  for (const asset of ['js/tools.js', 'css/tools.css']) {
    assert.ok(template.includes(asset + '?v=' + version));
    assert.ok(makefile.includes('/oasis/' + asset));
  }
});
