// Host-only i18n regression tests. Run: node dev_tools/tests/test_i18n.cjs
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { parsePo, inspectTemplate, scan, renderPot, audit } = require('../check_i18n.cjs');

const root = path.resolve(__dirname, '../..');
const catalog = parsePo(fs.readFileSync(path.join(root, 'lang/luci-i18n-oasis-ja/po/ja/luci-app-oasis.po'), 'utf8'));
const source = scan(root);
const pot = fs.readFileSync(path.join(root, 'lang/luci-i18n-oasis-ja/po/templates/luci-app-oasis.pot'), 'utf8');

function changed(key, fields) {
    const result = new Map(catalog);
    result.set(key, { ...result.get(key), ...fields });
    return result;
}

test('all current source strings, Japanese translations and generated POT agree', () => {
    assert.deepEqual(audit(source, catalog, pot), []);
    assert.ok(catalog.size > 300);
    assert.equal(catalog.size, source.messages.size);
    assert.equal(parsePo(pot).size, catalog.size);
});

test('missing Japanese translations are rejected', () => {
    const broken = new Map(catalog);
    broken.delete('Thinking');
    assert.ok(audit(source, broken, pot).includes('Missing Japanese translation: Thinking'));
});

test('empty, fuzzy and unchanged English translations are rejected', () => {
    for (const fields of [{ translation: '' }, { fuzzy: true }, { translation: 'Thinking' }]) {
        assert.ok(audit(source, changed('Thinking', fields), pot).some(error => error.includes('Thinking')));
    }
});

test('placeholder names and repetitions must match, while order may differ', () => {
    const key = 'Rebooting in {seconds}s ({percent}%)';
    assert.deepEqual(audit(source, changed(key, { translation: '{percent}%、あと{seconds}秒' }), pot), []);
    for (const value of ['{seconds}秒', '{seconds}秒 {percent}% {percent}', '{seconds}秒 {percentage}%']) {
        assert.ok(audit(source, changed(key, { translation: value }), pot).some(error => error.startsWith('Placeholder mismatch')));
    }
});

test('stale POT entries and source references are rejected', () => {
    assert.ok(audit(source, catalog, pot + '\n').some(error => error.startsWith('POT is out of date')));
    const withNewString = { ...source, messages: new Map(source.messages) };
    withNewString.messages.set('Fixture new label', new Set(['fixture.htm:1']));
    const errors = audit(withNewString, catalog, pot);
    assert.ok(errors.some(error => error.startsWith('POT is out of date')));
    assert.ok(errors.includes('Missing Japanese translation: Fixture new label'));
});

test('PO parser handles multiline entries and rejects duplicates or unsupported syntax', () => {
    const parsed = parsePo('msgid "Hello "\n"world"\nmsgstr "こんにちは"\n"世界"\n');
    assert.equal(parsed.get('Hello world').translation, 'こんにちは世界');
    assert.throws(() => parsePo('msgid "x"\nmsgstr "a"\nmsgid "x"\nmsgstr "b"\n'), /Duplicate/);
    assert.throws(() => parsePo('msgid "x"\n'), /Missing msgstr/);
    assert.throws(() => parsePo('msgctxt "new context"\n'), /Unsupported/);
    assert.equal(parsePo('#, fuzzy\nmsgid "x"\nmsgstr "a"\n').get('x').fuzzy, true);
    assert.equal(parsePo('#, fuzzy\n#, c-format\nmsgid "x"\nmsgstr "a"\n').get('x').fuzzy, true);
});

test('template audit finds missing literal and data-driven JS bridge keys', () => {
    const page = '<script>window.Strings = { present: <%= translate_js("Present") %> };</script>'
        + '<script src="/oasis/js/fixture.js"></script>';
    const result = inspectTemplate(page, 'fixture.htm', () =>
        "t('absent', 'Absent'); const options = [{ label: 'optionKey', fallback: 'Option' }];"
        + "const MANAGEMENT_LABELS = { name: ['managerKey', 'Manager'] };"
    );
    for (const key of ['absent', 'optionKey', 'managerKey']) {
        assert.ok(result.errors.some(error => error.includes('missing JS translation key ' + key)));
    }
});

test('translation keys keep literal quotes, not JavaScript escaping', () => {
    const good = inspectTemplate('<%= translate_js("User\'s \\\"config\\\"") %>', 'fixture.htm', () => '');
    assert.ok(good.messages.has('User\'s "config"'));
    assert.deepEqual(good.errors, []);
    const bad = inspectTemplate("<%:User\\'s config%>", 'fixture.htm', () => '');
    assert.ok(bad.errors.some(error => error.includes('escaped quote')));
});

test('direct UI English is detected, but comments and technical data are not treated as labels', () => {
    const page = '<script src="/oasis/js/fixture.js"></script>';
    const result = inspectTemplate(page, 'fixture.htm', () =>
        "// old.textContent = 'Disabled example';\nbutton.textContent = 'Apply';\nalert('Too big');\n"
        + "const name = 'get_tool_list'; label.textContent = name; button.textContent = '×';"
    );
    assert.equal(result.errors.length, 2);
    assert.ok(result.errors.some(error => error.endsWith('Apply')));
    assert.ok(result.errors.some(error => error.endsWith('Too big')));
});

test('generated POT is deterministic and excludes disabled HTML', () => {
    const page = inspectTemplate('<!-- <%:Disabled%> -->\n<%:Active%>\n<%:Active%>', 'fixture.htm', () => '');
    assert.equal(page.messages.size, 1);
    assert.deepEqual([...page.messages.get('Active')], ['fixture.htm:2', 'fixture.htm:3']);
    assert.equal(renderPot(page.messages), renderPot(page.messages));
});

// Exercise the real Lua wrapper, stubbing only LuCI translation lookup and
// jsonc's standard JSON serialization. No native modules or router are needed.
function luaString(value) {
    return '"' + Array.from(Buffer.from(value), byte => '\\' + String(byte).padStart(3, '0')).join('') + '"';
}

function serializeTranslations(entries) {
    const lookup = entries.map(([key, value]) => '[' + luaString(key) + ']=' + luaString(value)).join(',\n');
    const serialized = entries.map(([, value]) => '[' + luaString(value) + ']=' + luaString(JSON.stringify(value))).join(',\n');
    const keys = entries.map(([key]) => luaString(key)).join(',\n');
    const script = `local lookup = {${lookup}}
local serialized = {${serialized}}
package.loaded['luci.i18n'] = { translate = function(key) return assert(lookup[key]) end }
package.loaded['luci.jsonc'] = { stringify = function(value) return assert(serialized[value]) end }
local helper = dofile(${luaString(path.join(root, 'luci-app-oasis/files/luci/oasis/i18n.lua'))})
for _, key in ipairs({${keys}}) do io.write(helper.translate_js(key), '\\n') end
`;
    const result = spawnSync(process.env.OASIS_TEST_LUA || 'lua5.1', ['-'], { input: script, encoding: 'utf8', timeout: 10000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trimEnd().split('\n');
}

test('Lua serializer preserves Unicode, quotes, backslashes and newlines without ending a script', () => {
    const value = '日本語 "quoted" and \'apostrophe\' \\ path\n</script><script>alert(1)</script>&\u2028\u2029';
    const [encoded] = serializeTranslations([['Fixture', value]]);
    assert.equal(JSON.parse(encoded), value);
    assert.doesNotMatch(encoded, /[<>&\u2028\u2029]/);
    assert.doesNotThrow(() => new vm.Script('const label = ' + encoded + ';'));
});

test('all six rendered WebUI dictionaries parse as JavaScript and contain exact Japanese values', () => {
    const entries = [...catalog].map(([key, entry]) => [key, entry.translation]);
    const encoded = serializeTranslations(entries);
    const literals = new Map(entries.map(([key], index) => [key, encoded[index]]));
    for (const name of ['chat', 'tools', 'sysmsg', 'icons', 'rollback-list', 'setting-v2']) {
        const template = fs.readFileSync(path.join(root, 'luci-app-oasis/files/luci/view', name + '.htm'), 'utf8');
        const context = { window: {} };
        const expected = [];
        for (const block of template.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
            assert.doesNotMatch(block[1], /<%:/, name + ': HTML translation tag in JS');
            const rendered = block[1].replace(/(\w+):\s*<%=\s*translate_js\(("(?:\\.|[^"\\])*")\)\s*%>/g,
                (_, key, message) => {
                    const id = JSON.parse(message);
                    assert.ok(literals.has(id), id);
                    expected.push([key, catalog.get(id).translation]);
                    return key + ': ' + literals.get(id);
                }).replace(/<%=[\s\S]*?%>/g, 'fixture');
            vm.runInNewContext(rendered, context);
        }
        const dictionaries = Object.entries(context.window).filter(([key]) => key.endsWith('Strings')).map(([, value]) => value);
        assert.equal(dictionaries.length, 1, name);
        for (const [key, value] of expected) assert.equal(dictionaries[0][key], value, name + ':' + key);
    }
});

test('helper is packaged with the templates, and fixed bridge keys remain available', () => {
    const makefile = fs.readFileSync(path.join(root, 'luci-app-oasis/Makefile'), 'utf8');
    assert.match(makefile, /INSTALL_DATA.*\/oasis\/i18n\.lua/);
    const chat = fs.readFileSync(path.join(root, 'luci-app-oasis/files/luci/view/chat.htm'), 'utf8');
    for (const key of ['applyButton', 'cancelButton', 'reloadCountdown', 'rollingBack', 'noAiService', 'importTooLarge']) {
        assert.ok(chat.includes(key + ': <%= translate_js('), key);
    }
    const sysmsg = fs.readFileSync(path.join(root, 'luci-app-oasis/files/luci/view/sysmsg.htm'), 'utf8');
    assert.ok(sysmsg.includes('titleLabel: <%= translate_js("TITLE:") %>'));
});
