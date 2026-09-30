// Browser regression for UCI sharing consent. Requires Playwright + Chromium.
// Run: node --test dev_tools/tests/test_chat_uci_consent.cjs
// Optional: OASIS_TEST_SCREENSHOTS_DIR to save desktop/mobile dialog screenshots.
// Uses repository templates/assets and mocked HTTP endpoints; no router or AI calls.
const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('../check_i18n.cjs');

const root = path.resolve(__dirname, '../..');
const luci = path.join(root, 'luci-app-oasis/files/luci');
const translations = parsePo(fs.readFileSync(path.join(root,
    'lang/luci-i18n-oasis-ja/po/ja/luci-app-oasis.po'), 'utf8'));
const htmlEscape = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');

function renderPage(japanese) {
    const translate = text => japanese ? translations.get(text)?.translation || text : text;
    return fs.readFileSync(path.join(luci, 'view/chat.htm'), 'utf8')
        .replace('<%+header%>', '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font-family:sans-serif;margin:16px}button,select,textarea{font:inherit}</style></head><body>')
        .replace('<%+footer%>', '</body></html>')
        .replace(/<% local [\s\S]*?%>/g, '')
        .replace(/<%=\s*translate_js\(("(?:\\.|[^"\\])*")\)\s*%>/g,
            (_, value) => JSON.stringify(translate(JSON.parse(value))))
        .replace(/<%:([\s\S]*?)%>/g, (_, value) => htmlEscape(translate(value)))
        .replace(/<%=\s*resource\s*%>/g, '/static')
        .replace(/<%=token%>/g, 'fixture-token')
        .replace(/<%=build_url\((.*?)\)%>/g, (_, args) => '/cgi-bin/luci/' + JSON.parse('[' + args + ']').join('/'));
}

let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { if (browser) await browser.close(); });

async function fixture(t, { mobile = false, japanese = false, fallback = false } = {}) {
    const context = await browser.newContext({
        viewport: mobile ? { width: 390, height: 844 } : { width: 1100, height: 850 },
        isMobile: mobile, hasTouch: mobile,
        userAgent: mobile ? 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36' : undefined
    });
    t.after(() => context.close());
    const page = await context.newPage();
    page.setDefaultTimeout(5000);
    const env = { page, uci: [], chats: [], errors: [], uciStatus: 200, uciData: ['network.lan.ipaddr=192.0.2.1'] };
    page.on('pageerror', error => env.errors.push(error.message));
    t.after(() => assert.deepEqual(env.errors, []));
    if (fallback) await page.addInitScript(() => { HTMLDialogElement.prototype.showModal = undefined; });
    await page.route('**/*', async route => {
        const request = route.request();
        const url = new URL(request.url());
        const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
        if (url.pathname === '/chat') return route.fulfill({ contentType: 'text/html', body: renderPage(japanese) });
        if (url.pathname.startsWith('/static/oasis/')) {
            const file = path.join(luci, 'www/luci-static/resources', url.pathname.slice('/static/'.length));
            return fs.existsSync(file) ? route.fulfill({ path: file }) : route.fulfill({ status: 404, body: '' });
        }
        if (url.pathname.endsWith('/base-info')) return json({
            chat: { item: [] }, icon: { ctrl: { using: 'default' }, list: { default: 'openwrt.png' } },
            sysmsg: [{ key: 'default', title: 'Default' }], configs: ['network', 'wireless'],
            service: [{ identifier: 'first', name: 'Provider A', model: 'Model A' },
                { identifier: 'second', name: 'Provider B', model: 'Model B' }]
        });
        if (url.pathname.endsWith('/confirm')) return json({ status: 'NG' });
        if (url.pathname.endsWith('/select-ai-service')) return json({ status: 'OK' });
        if (url.pathname.endsWith('/uci-show')) {
            env.uci.push(new URLSearchParams(request.postData()).get('target'));
            if (env.uciGate) await env.uciGate;
            return route.fulfill({ status: env.uciStatus, contentType: 'application/json', body: JSON.stringify(env.uciData) });
        }
        if (url.pathname === '/cgi-bin/oasis') {
            env.chats.push(request.postDataJSON());
            return json({ message: { content: 'Fixture reply ' + env.chats.length } });
        }
        return route.fulfill({ status: 404, body: '' });
    });
    env.ready = async () => page.waitForFunction(() => document.querySelector('#uci-config-list').options.length === 3);
    await page.goto('http://oasis.test/chat');
    await env.ready();
    env.select = async target => {
        if (mobile) {
            await page.locator('#open-bottom-sheet').click();
            await page.locator('#mb-uci-config-list').selectOption(target);
            // Close the sheet using its existing backdrop/outside-click handler.
            await page.locator('#ai-service-list').click();
        } else await page.locator('#uci-config-list').selectOption(target);
    };
    env.send = async text => {
        await page.locator('#message-input').fill(text);
        await page.locator(mobile ? '#smp-send-button' : '#send-button').click();
    };
    env.waitReply = async number => page.waitForFunction(n =>
        [...document.querySelectorAll('.message.received')].some(node =>
            node.textContent.includes('Fixture reply ' + n) && node.querySelector('[aria-busy="false"]')), number);
    env.dialog = page.locator('#uci-share-dialog');
    env.agree = () => page.locator('#uci-share-dialog button[value="agree"]').click();
    return env;
}

for (const mobile of [false, true]) {
    test(`consent precedes all UCI/chat traffic; cancel, repeat and plain send (${mobile ? 'mobile/ja' : 'desktop/en'})`, async t => {
        const env = await fixture(t, { mobile, japanese: mobile });
        const { page } = env;
        await env.select('network');
        await env.send('Inspect this configuration');
        await env.dialog.waitFor({ state: 'visible' });
        assert.equal(await page.locator('#uci-share-title').textContent(),
            mobile ? 'UCI設定をAIと共有しますか？' : 'Share UCI configuration with AI?');
        assert.deepEqual(env.uci, []);
        assert.deepEqual(env.chats, []);
        assert.equal(await page.locator('#message-input').inputValue(), 'Inspect this configuration');
        assert.equal(await page.locator('.message').count(), 0);
        assert.equal(await page.locator('#sysmsg-select').isDisabled(), false);
        assert.equal(await page.evaluate(() => document.activeElement.value), 'cancel');
        if (process.env.OASIS_TEST_SCREENSHOTS_DIR) {
            fs.mkdirSync(process.env.OASIS_TEST_SCREENSHOTS_DIR, { recursive: true });
            await page.screenshot({ path: path.join(process.env.OASIS_TEST_SCREENSHOTS_DIR,
                mobile ? 'uci-consent-mobile-ja.png' : 'uci-consent-desktop-en.png') });
        }
        await page.locator('#uci-share-dialog button[value="cancel"]').click();
        await env.dialog.waitFor({ state: 'hidden' });
        assert.equal(await page.locator('#uci-config-list').inputValue(), 'network');
        assert.equal(await page.locator('#message-input').inputValue(), 'Inspect this configuration');
        assert.deepEqual(env.uci, []);
        assert.deepEqual(env.chats, []);

        await page.locator('#message-input').press('Enter');
        await env.dialog.waitFor({ state: 'visible' });
        await page.keyboard.press('Escape');
        await env.dialog.waitFor({ state: 'hidden' });
        assert.deepEqual(env.uci, []);
        await env.send('Inspect this configuration');
        await env.agree();
        await env.waitReply(1);
        assert.deepEqual(env.uci, ['network']);
        assert.match(env.chats[0].message, /network\.lan\.ipaddr=192\.0\.2\.1/);
        for (const id of ['uci-config-list', 'mb-uci-config-list']) assert.equal(await page.locator('#' + id).inputValue(), '---');

        await page.locator(mobile ? '#smp-new-mini' : '#new-button').click();
        await env.select('wireless');
        await env.send('Inspect another configuration');
        await env.waitReply(2);
        assert.deepEqual(env.uci, ['network', 'wireless']);
        assert.equal(await env.dialog.isVisible(), false);
        await env.send('A plain message');
        await env.waitReply(3);
        assert.equal(env.chats[2].message, 'A plain message');
        assert.equal(env.uci.length, 2);
    });
}

test('consent resets on service change, reload and back/forward page restoration', async t => {
    const env = await fixture(t);
    await env.select('network');
    await env.send('First');
    await env.agree();
    await env.waitReply(1);
    await env.page.locator('#ai-service-list').selectOption('1');
    await env.select('network');
    await env.send('Different service');
    await env.dialog.waitFor({ state: 'visible' });
    assert.equal(env.uci.length, 1);
    await env.agree();
    await env.waitReply(2);
    await env.page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })));
    await env.select('network');
    await env.send('Restored page');
    await env.dialog.waitFor({ state: 'visible' });
    assert.equal(env.uci.length, 2);
    await env.agree();
    await env.waitReply(3);
    await env.page.reload();
    await env.ready();
    await env.select('network');
    await env.send('Reloaded page');
    await env.dialog.waitFor({ state: 'visible' });
    assert.equal(env.uci.length, 3);
});

test('plain messages work before any UCI sharing agreement', async t => {
    const env = await fixture(t);
    await env.send('A plain first message');
    await env.waitReply(1);
    assert.deepEqual(env.uci, []);
    assert.equal(env.chats[0].message, 'A plain first message');
    assert.equal(await env.dialog.isVisible(), false);
});

for (const status of [200, 500]) {
test(`failed retrieval preserves input and never sends a plain fallback message (HTTP ${status})`, async t => {
    const env = await fixture(t);
    env.uciStatus = status;
    env.uciData = { error: 'Not Found' };
    const alerts = [];
    env.page.on('dialog', async dialog => { alerts.push(dialog.message()); await dialog.accept(); });
    await env.select('network');
    await env.send('Keep my input');
    await env.agree();
    await env.page.waitForFunction(() => !document.querySelector('#message-input').readOnly);
    assert.equal(env.chats.length, 0);
    assert.equal(await env.page.locator('#message-input').inputValue(), 'Keep my input');
    assert.equal(await env.page.locator('#uci-config-list').inputValue(), 'network');
    assert.equal(await env.page.locator('.message').count(), 0);
    assert.equal(alerts.length, 1);
    env.uciStatus = 200;
    env.uciData = ['network.lan.ipaddr=192.0.2.1'];
    await env.send('Keep my input');
    await env.waitReply(1);
});
}

test('pending retrieval cannot duplicate send or send to a changed service', async t => {
    const env = await fixture(t);
    let release;
    env.uciGate = new Promise(resolve => { release = resolve; });
    t.after(() => release());
    await env.select('network');
    await env.send('One message');
    await env.agree();
    await env.page.waitForFunction(() => document.querySelector('#message-input').readOnly);
    await env.page.locator('#send-button').click();
    assert.equal(env.uci.length, 1);
    await env.page.locator('#ai-service-list').selectOption('1');
    release();
    await env.page.waitForFunction(() => !document.querySelector('#message-input').readOnly);
    assert.equal(env.chats.length, 0);
    assert.equal(await env.page.locator('#message-input').inputValue(), 'One message');
    await env.send('One message');
    await env.dialog.waitFor({ state: 'visible' });
    await env.agree();
    await env.waitReply(1);
});

test('browsers without native dialog support still require explicit consent', async t => {
    const env = await fixture(t, { fallback: true });
    let agree = false;
    env.page.on('dialog', async dialog => { if (agree) await dialog.accept(); else await dialog.dismiss(); });
    await env.select('network');
    await env.send('Fallback');
    assert.deepEqual(env.uci, []);
    assert.deepEqual(env.chats, []);
    agree = true;
    await env.send('Fallback');
    await env.waitReply(1);
    assert.equal(env.uci.length, 1);
});
