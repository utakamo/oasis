(function(global) {
    'use strict';

    const MANAGEMENT_LABELS = {
        get_tool_list: ['toolList', 'List tools'],
        set_tool_enabled: ['toolEnable', 'Enable tool'],
        set_tool_disabled: ['toolDisable', 'Disable tool']
    };

    function objectValue(value) {
        if (typeof value === 'string') {
            try { value = JSON.parse(value); } catch (_) { return null; }
        }
        return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
    }

    // One instance per user turn. Display data is never added to AI messages
    // or persisted in chat history. Only explicitly user-facing output is shown.
    function create(options) {
        const t = options.t;
        const seen = new Map();
        let list = null;
        let container = null;
        let count = 0;

        function element(tag, className, text) {
            const node = document.createElement(tag);
            node.className = className;
            if (text !== undefined) node.textContent = text;
            return node;
        }

        function ensureList() {
            const next = options.getContainer ? options.getContainer() : options.container;
            if (list && container === next) return;
            container = next;
            const group = element('section', 'tool-activity');
            group.appendChild(element('div', 'tool-activity-title', t('toolActivity', 'Tool activity')));
            list = element('ol', 'tool-activity-list');
            list.start = count + 1;
            group.appendChild(list);
            container.appendChild(group);
        }

        function statusOf(output, management) {
            const status = output && typeof output.status === 'string' ? output.status.toUpperCase() : '';
            if (output && (output.success === false || output.error || status === 'NG' || status === 'ERROR' || status === 'FAILED')) {
                return ['failed', t('toolFailed', 'Failed')];
            }
            if (output && (output.success === true || status === 'OK' || status === 'SUCCESS')) {
                if (management && output.changed === false) return ['success', t('toolUnchanged', 'No change')];
                return ['success', t('toolSucceeded', 'Succeeded')];
            }
            return ['received', t('toolResultReceived', 'Result received')];
        }

        function appendCall(call, output) {
            const name = typeof call.name === 'string' && call.name.length ? call.name : t('unknownTool', 'Unknown tool');
            const management = Object.prototype.hasOwnProperty.call(MANAGEMENT_LABELS, name);
            const label = management ? MANAGEMENT_LABELS[name] : ['toolExecute', 'Tool execution'];
            const status = statusOf(output, management);
            const card = element('li', 'tool-call' + (management ? ' tool-call-management' : ''));
            const header = element('div', 'tool-call-header');
            header.appendChild(element('code', 'tool-call-name', name));
            header.appendChild(element('span', 'tool-call-kind', t(label[0], label[1])));
            header.appendChild(element('span', 'tool-call-status tool-call-' + status[0], status[1]));
            card.appendChild(header);

            if (management && name !== 'get_tool_list') {
                // Show only the target identity, never arbitrary tool arguments.
                const args = objectValue(call.arguments) || {};
                const target = typeof args.tool === 'string' ? args.tool : output && output.tool;
                const server = typeof args.server === 'string' ? args.server : output && output.server;
                if (typeof target === 'string' && target.length) {
                    const identity = typeof server === 'string' && server.length ? server + ' / ' + target : target;
                    card.appendChild(element('div', 'tool-call-target', '\u2192 ' + identity));
                }
            }

            if (output && typeof output.user_only === 'string' && output.user_only.trim()) {
                const notice = element('div', 'oasis-user-only tool-call-notice');
                notice.appendChild(element('div', 'oasis-user-only-title', t('userOnlyNotice', 'Additional message')));
                const body = element('div', 'oasis-user-only-body');
                body.innerHTML = options.sanitizeHTML(options.convertMarkdownToHTML(output.user_only.trim()));
                notice.appendChild(body);
                card.appendChild(notice);
            }

            ensureList();
            list.appendChild(card);
            count++;
        }

        function consume(event) {
            const result = { outputs: [], invalid: false };
            if (!event || typeof event.service !== 'string' || !event.service.trim()
                || !Array.isArray(event.tool_outputs) || !event.tool_outputs.length) {
                result.invalid = true;
                return result;
            }
            event.tool_outputs.forEach(call => {
                if (!call || typeof call !== 'object' || Array.isArray(call)
                    || !Object.prototype.hasOwnProperty.call(call, 'output')) {
                    result.invalid = true;
                    return;
                }
                // Providers without IDs (e.g. some Ollama responses) must not
                // lose legitimate repeated calls through name-based deduping.
                const id = typeof call.tool_call_id === 'string' ? call.tool_call_id : '';
                const key = id ? JSON.stringify([event.service, id]) : null;
                if (key && seen.has(key)) {
                    if (seen.get(key) !== call.name) result.invalid = true;
                    return;
                }
                const output = objectValue(call.output);
                appendCall(call, output);
                if (key) seen.set(key, call.name);
                if (output) result.outputs.push(output);
            });
            return result;
        }

        return { consume, get count() { return count; } };
    }

    global.OasisChatTools = { create };
})(window);
