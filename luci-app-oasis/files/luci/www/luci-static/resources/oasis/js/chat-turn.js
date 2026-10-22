(function(global) {
    'use strict';

    const RENDER_INTERVAL_MS = 50;

    // Display-only state for one response. Never add tool notices to AI history.
    function create(options) {
        const container = options.container;
        let lastKind = '';
        let lastNode = null;
        let active = null;
        let timer = null;
        let finished = false;
        let hasContent = false;

        function element(className, text) {
            const node = document.createElement('div');
            node.className = className;
            if (text !== undefined) node.textContent = text;
            return node;
        }

        // Replace the initial typing placeholder once, not on every chunk.
        container.textContent = '';
        container.setAttribute('aria-busy', 'true');
        const pending = element('turn-pending', options.t('thinking', 'Thinking...'));
        container.appendChild(pending);

        function updated() {
            if (options.onUpdate) options.onUpdate();
        }

        function render() {
            if (!active || !active.dirty) return;
            if (active.kind === 'text') {
                try {
                    active.body.innerHTML = options.sanitizeHTML(options.convertMarkdownToHTML(active.text));
                } catch (_) {
                    // Incomplete Markdown must not discard already received output.
                    active.body.textContent = active.text;
                }
            } else {
                active.body.textContent = active.text;
            }
            active.dirty = false;
            updated();
        }

        function flush() {
            if (timer !== null) {
                clearTimeout(timer);
                timer = null;
            }
            render();
        }

        function append(kind, node) {
            flush();
            active = null;
            lastKind = kind;
            lastNode = node;
            container.insertBefore(node, pending);
            return node;
        }

        function appendContent(kind, content) {
            if (finished || typeof content !== 'string' || !content.length) return;
            if (!active || active.kind !== kind) {
                const node = element(kind === 'text' ? 'turn-text' : 'thinking-panel');
                append(kind, node);
                let body = node;
                if (kind === 'thinking') {
                    node.appendChild(element('thinking-label', options.t('thinkingLabel', 'Thinking')));
                    body = node.appendChild(element('thinking-body'));
                }
                active = { kind, body, text: '', dirty: false };
            }
            active.text += content;
            active.dirty = true;
            if (kind === 'text' && content.trim()) hasContent = true;
            if (timer === null) {
                timer = setTimeout(function() {
                    timer = null;
                    render();
                }, RENDER_INTERVAL_MS);
            }
        }

        function appendNotice(message, execution) {
            if (finished || typeof message !== 'string' || !message.trim()) return;
            const node = element(execution ? 'turn-execution' : 'error-notice');
            if (execution) node.innerHTML = options.sanitizeHTML(message);
            else node.textContent = message;
            append('notice', node);
            hasContent = true;
            updated();
        }

        function toolContainer() {
            // Called only for a newly accepted call, not for replayed results.
            if (lastKind !== 'tools') append('tools', element('turn-tools'));
            hasContent = true;
            return lastNode;
        }

        function finish() {
            if (finished) return;
            flush();
            if (!hasContent) {
                appendNotice(options.t('noResponse', 'No response from AI service. Please check settings.'), false);
            }
            finished = true;
            active = null;
            container.removeChild(pending);
            container.setAttribute('aria-busy', 'false');
            updated();
        }

        return {
            appendText: content => appendContent('text', content),
            appendThinking: content => appendContent('thinking', content),
            appendError: message => appendNotice(message, false),
            appendExecution: message => appendNotice(message, true),
            toolContainer, flush, finish
        };
    }

    // LuCI's Lua/ucode HTTP bridge can turn empty lists into {}. Normalize
    // collections only for display; leave the saved/exported document intact.
    function savedList(value) {
        return Array.isArray(value) ? value : [];
    }

    // Associate review data with the first assistant reply after its user
    // message. A failed turn without a reply gets its own assistant bubble,
    // before the next user message. Never modify the source document.
    function savedMessages(data) {
        const turns = new Map();
        if (data.format_version === 2) {
            savedList(data.turns).forEach(turn => turns.set(turn.user_message, turn));
        }
        const messages = [];
        let pending = null;
        function flush() {
            if (pending) messages.push({ role: 'assistant', content: '', savedTurn: pending });
            pending = null;
        }
        savedList(data.messages).forEach((message, index) => {
            if (message.role === 'user') {
                flush();
                messages.push({ role: message.role, content: message.content });
                const turn = turns.get(index + 1);
                if (turn && (savedList(turn.requests).length || turn.status !== 'completed')) pending = turn;
            } else if (message.role === 'assistant') {
                messages.push({ role: message.role, content: message.content, savedTurn: pending });
                pending = null;
            }
        });
        flush();
        return messages;
    }

    function renderSaved(options, message) {
        const turn = create(options);
        const activity = global.OasisChatTools.create({ ...options, getContainer: turn.toolContainer });
        const saved = message.savedTurn;
        const requests = savedList(saved.requests);
        let finalTextShown = false;
        requests.forEach((request, index) => {
            const calls = savedList(request.calls);
            // The final text-only response is also in messages. Prefer that
            // authoritative copy, but retain the checkpoint if final save failed.
            const finalText = index === requests.length - 1 && !calls.length && message.content;
            if (finalText) {
                turn.appendText(message.content);
                finalTextShown = true;
            } else {
                turn.appendText(request.assistant_text);
            }
            calls.forEach(activity.appendSaved);
            if (request.error) turn.appendError(request.error);
        });
        if (!finalTextShown) turn.appendText(message.content);
        if (saved.status === 'incomplete') {
            turn.appendError(options.t('savedResponseIncomplete', 'This response was not completed.'));
        } else if (saved.status === 'failed' && !requests.some(request => request.error)) {
            turn.appendError(options.t('savedResponseFailed', 'This response failed.'));
        }
        turn.finish();
    }

    global.OasisChatTurn = { create, savedMessages, renderSaved };
})(window);
