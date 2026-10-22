// Browser fixtures use repository assets and mocked HTTP. No device or AI calls.
// NODE_PATH=<playwright modules> node --test dev_tools/tests/test_chat_history.cjs
const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('../check_i18n.cjs');
const root = path.resolve(__dirname, '../..');
const luci = path.join(root, 'luci-app-oasis/files/luci');
const translations = parsePo(fs.readFileSync(path.join(root, 'lang/luci-i18n-oasis-ja/po/ja/luci-app-oasis.po'), 'utf8'));
const escape = value => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
function pageHtml() {
    const translate = text => translations.get(text)?.translation || text;
    return fs.readFileSync(path.join(luci, 'view/chat.htm'), 'utf8')
        .replace('<%+header%>', '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font-family:sans-serif;margin:16px}button,select,textarea{font:inherit}</style></head><body>')
        .replace('<%+footer%>', '</body></html>')
        .replace(/<% local [\s\S]*?%>/g, '')
        .replace(/<%=\s*translate_js\(("(?:\\.|[^"\\])*")\)\s*%>/g, (_, value) => JSON.stringify(translate(JSON.parse(value))))
        .replace(/<%:([\s\S]*?)%>/g, (_, value) => escape(translate(value)))
        .replace(/<%=\s*resource\s*%>/g, '/static')
        .replace(/<%=token%>/g, 'fixture-token')
        .replace(/<%=build_url\((.*?)\)%>/g, (_, args) => '/cgi-bin/luci/' + JSON.parse('[' + args + ']').join('/'));
}
function documentFixture() {
    return {
        format_version: 2, revision: 8, last_operation_id: 'save-final',
        messages: [{role: 'user', content: 'ルーターの状態を確認してください。'},
            {role: 'assistant', content: '確認が完了しました。接続は正常です。'}],
        turns: [{id: 'turn-1', user_message: 1, status: 'completed', requests: [{
            id: 'request-1', provider: 'OpenAI', model: 'fixture-model', status: 'completed',
            assistant_text: '状態を確認します。',
            tools: {state: 'provided', definitions_json: '[{"name":"inspect","description":"Router status","parameters":{"type":"object","properties":{}}}]'},
            calls: [{id: 'saved-call-1', provider_id: 'call-1', name: 'inspect', arguments_json: '{}', status: 'completed',
                result: {status: 'success', original_json: '{"status":"OK","user_only":"確認時の補足です。<img src=x onerror=window.historyExecuted=true>","ui_action":{"type":"wifi_config","operation":"update"},"reboot":true,"shutdown":true,"prepare_service_restart":"network"}',
                    ai_json: '{"status":"OK"}'}}]
        }, {id: 'request-2', provider: 'OpenAI', model: 'fixture-model', status: 'completed',
            assistant_text: '確認が完了しました。接続は正常です。', tools: {state: 'none'}, calls: []}]}]
    };
}

function interruptedFixture() {
    return {
        format_version: 2,
        messages: [{role: 'system', content: 'fixture'}, {role: 'user', content: '中断された確認'},
            {role: 'user', content: '次の質問'}, {role: 'assistant', content: '次の回答'}],
        turns: [{id: 'interrupted', user_message: 2, status: 'failed', requests: [{
            id: 'failed-request', provider: 'OpenAI', model: 'fixture', status: 'failed',
            assistant_text: '順番に確認します。', error: '保存された処理エラー', tools: {state: 'none'},
            calls: [
                {id: 'done', name: 'inspect', arguments_json: '{}', status: 'completed', result: {status: 'success', original_json: '{"status":"OK"}'}},
                {id: 'error', name: 'inspect', arguments_json: '{}', status: 'failed', result: {status: 'error', error: 'fixture error'}},
                {id: 'running', name: 'inspect', arguments_json: '{}', status: 'running'},
                {id: 'pending', name: 'inspect', arguments_json: '{}', status: 'pending'}
            ]
        }]}]
    };
}

// LuCI's Lua/ucode HTTP bridge serializes empty lists as objects, even when
// storage and ubus return arrays. Exercise the actual WebUI response shape.
function luciResponse(doc) {
    return JSON.parse(JSON.stringify(doc, (_, value) => Array.isArray(value) && !value.length ? {} : value));
}
let browser;
before(async () => { browser = await chromium.launch({headless: true}); });
after(async () => { if (browser) await browser.close(); });

async function downloadText(download) {
    const chunks = [];
    for await (const chunk of await download.createReadStream()) chunks.push(chunk);
    return Buffer.concat(chunks).toString('utf8');
}

for (const mobile of [false, true]) {
    test('history is inert and JSON/text exports survive imports: ' + (mobile ? 'mobile' : 'desktop'), async t => {
        const context = await browser.newContext({viewport: mobile ? {width: 390, height: 844} : {width: 1200, height: 900}, isMobile: mobile, hasTouch: mobile});
        t.after(() => context.close());
        const page = await context.newPage();
        const errors = [], sends = [], imports = [], unexpected = [];
        let failedChatId;
        page.on('pageerror', error => errors.push(error.message));
        const documents = {
            '123456': luciResponse(documentFixture()), '123460': luciResponse(interruptedFixture()),
            '123461': {format_version: 2, messages: [{role: 'user', content: 'ツールのない会話'},
                {role: 'assistant', content: '保存された通常の回答'}], turns: {}},
            '123462': {format_version: 2, messages: [{role: 'user', content: 'リクエスト前に中断した会話'}],
                turns: [{user_message: 1, status: 'incomplete', requests: {}}]}
        };
        await page.route('**/*', async route => {
            const request = route.request(), url = new URL(request.url());
            const json = value => route.fulfill({contentType: 'application/json', body: JSON.stringify(value)});
            if (url.pathname === '/chat') return route.fulfill({contentType: 'text/html', body: pageHtml()});
            if (url.pathname.startsWith('/static/oasis/')) {
                const file = path.join(luci, 'www/luci-static/resources', url.pathname.slice('/static/'.length));
                return fs.existsSync(file) ? route.fulfill({path: file}) : route.fulfill({status: 404, body: ''});
            }
            if (url.pathname.endsWith('/base-info')) return json({
                chat: {item: [{id: '123456', title: 'ルーターの状態'}, {id: '123460', title: '中断された確認'},
                    {id: '123461', title: 'ツールのない会話'}, {id: '123462', title: 'リクエスト前の中断'}]},
                icon: {ctrl: {using: 'default'}, list: {default: 'openwrt.png'}},
                sysmsg: [{key: 'default', title: 'Default'}], configs: ['network'],
                service: [{identifier: 'first', name: 'OpenAI', model: 'fixture-model'}, {identifier: 'second', name: 'Ollama', model: 'another-model'}]
            });
            if (url.pathname.endsWith('/confirm')) return json({status: 'NG'});
            if (url.pathname.endsWith('/load-chat-data')) return json(documents[new URLSearchParams(request.postData()).get('params')]);
            if (url.pathname.endsWith('/import-chat-data')) {
                const raw = Buffer.from(new URLSearchParams(request.postData()).get('chat_data'), 'base64').toString('utf8');
                const doc = JSON.parse(raw); imports.push(doc);
                const id = String(123456 + imports.length); documents[id] = doc;
                return json({id, title: 'インポートした会話'});
            }
            if (url.pathname.endsWith('/select-ai-service')) return json({status: 'OK'});
            if (url.pathname === '/cgi-bin/oasis') {
                sends.push(request.postDataJSON());
                if (failedChatId) return json({error: {chat_id: failedChatId, message: 'fixture failure', can_continue: false}});
                return json({message: {content: '切り替え後の回答'}});
            }
            unexpected.push(url.pathname);
            return route.fulfill({status: 404, body: ''});
        });
        await page.goto('http://oasis.test/chat');
        await page.waitForFunction(() => document.querySelector('#chat-list li'));
        const openSheet = async () => {
            if (mobile) {
                if (await page.locator('#mobile-bottom-sheet').evaluate(node => node.classList.contains('show'))) {
                    await page.locator('#ai-service-list').click();
                }
                // The existing sheet has a delayed close; allow that timer to
                // finish even if it is already transitioning off screen.
                await page.waitForTimeout(300);
                await page.locator('#open-bottom-sheet').click();
            }
        };
        const select = async id => {
            await openSheet();
            await page.locator((mobile ? '#mb-chat-list' : '#chat-list') + ' li[data-id="' + id + '"] > span').click();
            if (mobile) await page.waitForTimeout(350); // Finish closing the sheet before screenshots.
        };
        await select('123456');
        await page.locator('.message.received .tool-activity').waitFor();
        assert.equal(await page.locator('.message.sent').count(), 1);
        assert.equal(await page.locator('.message.received').count(), 1);
        assert.equal(await page.locator('.message.sent .tool-activity, .oasis-tool-history').count(), 0);
        assert.deepEqual(await page.locator('.tool-call-name').allTextContents(), ['inspect']);
        assert.deepEqual(await page.locator('.tool-call-status').allTextContents(), ['成功']);
        assert.deepEqual(await page.locator('.message.received .turn-text').allTextContents(), ['状態を確認します。', '確認が完了しました。接続は正常です。']);
        assert.match(await page.locator('.tool-call-notice').innerText(), /確認時の補足/);
        assert.equal(await page.evaluate(() => window.historyExecuted === true), false);
        assert.equal(await page.locator('.tool-call-notice img, .chat-messages .oasis-system').count(), 0);
        assert.equal(await page.locator('#wifi-config-modal, #confirm-popup, #applying-popup').filter({visible: true}).count(), 0);
        assert.equal(sends.length, 0);
        assert.equal(await page.locator('.turn-pending').count(), 0);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false);
        if (process.env.OASIS_TEST_SCREENSHOTS_DIR) {
            fs.mkdirSync(process.env.OASIS_TEST_SCREENSHOTS_DIR, {recursive: true});
            await page.screenshot({animations: 'disabled', path: path.join(process.env.OASIS_TEST_SCREENSHOTS_DIR, 'history-' + (mobile ? 'mobile' : 'desktop') + '.png')});
        }
        const exportChat = async (id, format) => {
            await openSheet();
            await page.locator((mobile ? '#mb-chat-list' : '#chat-list') + ' li[data-id="' + id + '"] .oasis-menu-btn').click();
            await page.locator('[data-action="export"]').click();
            const download = page.waitForEvent('download');
            await page.locator('#' + format + '-export').click();
            return downloadText(await download);
        };
        const exported = await exportChat('123456', 'json');
        assert.deepEqual(JSON.parse(exported), documents['123456']);
        const text = await exportChat('123456', 'text');
        assert.match(text, />>> You\nルーター/);
        assert.match(text, />>> AI\n確認が完了/);
        assert.doesNotMatch(text, /user_only|ui_action|definitions_json/);
        await page.locator('#import-chat-data').setInputFiles({name: 'history.json', mimeType: 'application/json', buffer: Buffer.from(exported)});
        await page.waitForFunction(() => document.querySelector('#chat-list li[data-id="123457"]'));
        assert.deepEqual(imports[0], documents['123456']);
        await select('123457');
        await page.locator('.message.received .tool-activity').waitFor();
        assert.equal(sends.length, 0);
        await page.locator('#ai-service-list').selectOption('1');
        await page.locator('#message-input').fill('別のモデルで続きをお願いします。');
        await page.locator(mobile ? '#smp-send-button' : '#send-button').click();
        await page.waitForFunction(() => document.querySelector('.chat-messages').textContent.includes('切り替え後の回答'));
        assert.equal(sends[0].id, '123457');
        assert.doesNotMatch(JSON.stringify(sends[0]), /definitions_json|user_only|PRIVATE/);
        failedChatId = '123457';
        await page.locator('#message-input').fill('保存済みの会話で失敗した場合');
        await page.locator(mobile ? '#smp-send-button' : '#send-button').click();
        await page.waitForFunction(() => document.querySelector('.chat-messages').textContent.includes('fixture failure'));
        assert.equal(await page.locator('#chat-list li[data-id="123457"]').count(), 1);
        failedChatId = undefined;
        const legacy = {messages: [{role: 'user', content: 'legacy user'}, {role: 'assistant', content: 'legacy answer'}]};
        await page.locator('#import-chat-data').setInputFiles({name: 'legacy.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(legacy))});
        await page.waitForFunction(() => document.querySelector('#chat-list li[data-id="123458"]'));
        await select('123458');
        await page.waitForFunction(() => document.querySelector('.chat-messages').textContent.includes('legacy answer'));
        assert.equal(await page.locator('.oasis-tool-history').count(), 0);
        assert.equal(await page.locator('.tool-activity').count(), 0);
        assert.deepEqual(JSON.parse(await exportChat('123458', 'json')), legacy);
        if (mobile) await page.waitForTimeout(300);
        await page.locator(mobile ? '#smp-new-mini' : '#new-button').click();
        failedChatId = '123459';
        await page.locator('#message-input').fill('最終回答のない新規会話');
        await page.locator(mobile ? '#smp-send-button' : '#send-button').click();
        await page.waitForFunction(() => document.querySelector('#chat-list li[data-id="123459"]'));
        assert.equal(await page.locator('#chat-list li[data-id="123459"]').count(), 1);
        await page.waitForFunction(() => document.querySelector('.chat-messages').textContent.includes('fixture failure'));
        await select('123460');
        await page.locator('.tool-call').nth(3).waitFor();
        assert.deepEqual(await page.locator('.tool-call-status').allTextContents(), ['成功', '失敗', '結果未確認', '未実行']);
        assert.equal(await page.locator('.message.received').count(), 2);
        assert.equal(await page.locator('.message.received').first().locator('.tool-call').count(), 4);
        assert.equal(await page.locator('.message.received').last().locator('.tool-call').count(), 0);
        assert.equal(await page.locator('.message.received').last().innerText(), '次の回答');
        assert.match(await page.locator('.message.received').first().innerText(), /保存された処理エラー/);
        assert.equal(await page.locator('.turn-pending').count(), 0);
        if (process.env.OASIS_TEST_SCREENSHOTS_DIR) {
            await page.screenshot({animations: 'disabled', path: path.join(process.env.OASIS_TEST_SCREENSHOTS_DIR, 'history-interrupted-' + (mobile ? 'mobile' : 'desktop') + '.png')});
        }
        await select('123461');
        await page.waitForFunction(() => document.querySelector('.chat-messages').textContent.includes('保存された通常の回答'));
        assert.equal(await page.locator('.message.received').count(), 1);
        assert.equal(await page.locator('.tool-activity').count(), 0);
        await select('123462');
        await page.locator('.message.received .error-notice').waitFor();
        assert.equal(await page.locator('.message.received').count(), 1);
        assert.equal(await page.locator('.tool-activity').count(), 0);
        assert.deepEqual(unexpected, []);
        assert.deepEqual(errors, []);
    });
}
