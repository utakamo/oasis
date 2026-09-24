// Host-only translation audit. No router, network, or buildroot is required.
// Usage: node dev_tools/check_i18n.cjs [--write-pot]
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');
const CATALOG = 'lang/luci-i18n-oasis-ja/po/ja/luci-app-oasis.po';
const TEMPLATE = 'lang/luci-i18n-oasis-ja/po/templates/luci-app-oasis.pot';
const PACKAGES = ['luci-app-oasis', 'oasis-tool-maker'];
const UNCHANGED = new Set(['OK', 'Raw(JSON)', 'URL:', 'Function Calling',
    'Chat Completions API', 'Responses API', 'SSID', 'Auto: ON', 'Auto: OFF']);

// This project uses singular, context-free PO entries. Reject unsupported
// forms rather than silently overlooking them; msgfmt checks gettext syntax too.
function parsePo(source) {
    const entries = new Map();
    let entry, field, fuzzy = false;
    function finish() {
        if (!entry) return;
        if (entry.translation === undefined) throw new Error('Missing msgstr: ' + entry.id);
        if (entries.has(entry.id)) throw new Error('Duplicate msgid: ' + entry.id);
        entries.set(entry.id, entry);
    }
    for (const line of source.split('\n')) {
        if (line.startsWith('#,')) { fuzzy = fuzzy || /\bfuzzy\b/.test(line); continue; }
        if (!line.trim() || line.startsWith('#')) continue;
        const match = /^(msgid|msgstr) (".*")$/.exec(line);
        if (match) {
            const value = JSON.parse(match[2]);
            if (match[1] === 'msgid') {
                finish(); entry = { id: value, fuzzy }; fuzzy = false; field = 'id';
            } else {
                if (!entry) throw new Error('msgstr without msgid');
                field = 'translation'; entry[field] = value;
            }
        } else if (/^"/.test(line) && entry) {
            entry[field] += JSON.parse(line);
        } else {
            throw new Error('Unsupported PO syntax: ' + line);
        }
    }
    finish(); entries.delete('');
    return entries;
}

const normalize = text => text.trim().replace(/\s+/g, ' ');
const lineAt = (source, index) => source.slice(0, index).split('\n').length;

function inspectTemplate(source, filename, readScript) {
    // Ignore disabled HTML while preserving source line numbers.
    source = source.replace(/<!--[\s\S]*?-->/g, text => text.replace(/[^\n]/g, ' '));
    const messages = new Map(), bridges = new Set(), errors = [];
    function add(message, index) {
        const key = normalize(message);
        if (/\\['"]/.test(key)) errors.push(filename + ': escaped quote in translation key: ' + key);
        if (!messages.has(key)) messages.set(key, new Set());
        messages.get(key).add(filename + ':' + lineAt(source, index));
    }
    for (const match of source.matchAll(/<%:([\s\S]*?)%>/g)) add(match[1], match.index);
    for (const match of source.matchAll(/<%=\s*translate_js\(("(?:\\.|[^"\\])*")\)\s*%>/g)) {
        add(JSON.parse(match[1]), match.index);
    }
    for (const match of source.matchAll(/\b(\w+):\s*(?:['"]<%:|<%=\s*translate_js\()/g)) {
        bridges.add(match[1]);
    }
    const scripts = [...source.matchAll(/\/oasis\/js\/([\w-]+\.js)/g)].map(match => match[1]);
    for (const name of scripts) {
        const js = readScript(name).replace(/^\s*\/\/.*$/gm, '');
        const required = new Set([...js.matchAll(/\bt\(\s*['"](\w+)['"]\s*,/g)].map(match => match[1]));
        // The settings select options and tool-card labels use data-driven keys.
        for (const match of js.matchAll(/\blabel:\s*['"](\w+)['"]\s*,\s*fallback:/g)) required.add(match[1]);
        const management = js.match(/const MANAGEMENT_LABELS = \{([\s\S]*?)\};/);
        if (management) {
            for (const match of management[1].matchAll(/:\s*\[\s*['"](\w+)['"]/g)) required.add(match[1]);
        }
        for (const key of required) {
            if (!bridges.has(key)) errors.push(filename + ': missing JS translation key ' + key + ' (' + name + ')');
        }
        // Catch the common direct-label regressions, not technical identifiers,
        // provider responses, or dynamically supplied user data.
        for (const match of js.matchAll(/(?:\.(?:textContent|placeholder)\s*=\s*|\b(?:alert|confirm)\(\s*)(['"])([A-Za-z][^'"\n]*)\1/g)) {
            errors.push(name + ': untranslated UI literal: ' + match[2]);
        }
    }
    return { messages, errors };
}

function scan(root = ROOT) {
    const messages = new Map(), errors = [];
    for (const pkg of PACKAGES) {
        const directory = pkg + '/files/luci/view';
        for (const name of fs.readdirSync(path.join(root, directory)).filter(name => name.endsWith('.htm')).sort()) {
            const filename = directory + '/' + name;
            const page = inspectTemplate(fs.readFileSync(path.join(root, filename), 'utf8'), filename,
                js => fs.readFileSync(path.join(root, pkg, 'files/luci/www/luci-static/resources/oasis/js', js), 'utf8'));
            errors.push(...page.errors);
            for (const [key, refs] of page.messages) {
                if (!messages.has(key)) messages.set(key, new Set());
                for (const ref of refs) messages.get(key).add(ref);
            }
        }
    }
    return { messages, errors };
}

function renderPot(messages) {
    const header = '# Generated by node dev_tools/check_i18n.cjs --write-pot.\n'
        + 'msgid ""\nmsgstr ""\n'
        + '"Project-Id-Version: luci-app-oasis\\n"\n'
        + '"MIME-Version: 1.0\\n"\n'
        + '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        + '"Content-Transfer-Encoding: 8bit\\n"\n';
    return header + [...messages.keys()].sort().map(key => '\n'
        + [...messages.get(key)].sort().map(ref => '#: ' + ref).join('\n')
        + '\nmsgid ' + JSON.stringify(key) + '\nmsgstr ""\n').join('');
}

function audit(scanResult, catalog, potSource) {
    const errors = [...scanResult.errors];
    if (renderPot(scanResult.messages) !== potSource) errors.push('POT is out of date; run node dev_tools/check_i18n.cjs --write-pot');
    for (const key of scanResult.messages.keys()) {
        if (!catalog.has(key)) errors.push('Missing Japanese translation: ' + key);
    }
    const placeholders = value => JSON.stringify((value.match(/\{[A-Za-z_]\w*\}/g) || []).sort());
    for (const [key, entry] of catalog) {
        if (!entry.translation.trim() || entry.fuzzy) errors.push('Empty or fuzzy translation: ' + key);
        if (key === entry.translation && !UNCHANGED.has(key)) errors.push('Untranslated English: ' + key);
        if (placeholders(key) !== placeholders(entry.translation)) errors.push('Placeholder mismatch: ' + key);
        if (!scanResult.messages.has(key)) errors.push('Unused PO entry: ' + key);
    }
    return errors;
}

function main(args) {
    if (args.length && (args.length !== 1 || args[0] !== '--write-pot')) {
        throw new Error('Usage: node dev_tools/check_i18n.cjs [--write-pot]');
    }
    const result = scan();
    if (args[0] === '--write-pot') {
        // Generated catalog metadata only. Never overwrite Japanese translations.
        fs.writeFileSync(path.join(ROOT, TEMPLATE), renderPot(result.messages));
        console.log('Updated ' + TEMPLATE + ' (' + result.messages.size + ' messages)');
        return;
    }
    const catalog = parsePo(fs.readFileSync(path.join(ROOT, CATALOG), 'utf8'));
    const errors = audit(result, catalog, fs.readFileSync(path.join(ROOT, TEMPLATE), 'utf8'));
    const checked = spawnSync('msgfmt', ['--check', '-o', '/dev/null', path.join(ROOT, CATALOG)], { encoding: 'utf8', timeout: 10000 });
    if (checked.error) errors.push('msgfmt is required (install GNU gettext): ' + checked.error.message);
    else if (checked.status !== 0) errors.push(checked.stderr || 'msgfmt failed');
    if (errors.length) throw new Error(errors.join('\n'));
    console.log('i18n OK: ' + result.messages.size + ' source messages, ' + catalog.size
        + ' Japanese translations; POT, JS bridges, and placeholders match.');
}

module.exports = { parsePo, inspectTemplate, scan, renderPot, audit };
if (require.main === module) {
    try { main(process.argv.slice(2)); }
    catch (error) { console.error(error.message); process.exitCode = 1; }
}
