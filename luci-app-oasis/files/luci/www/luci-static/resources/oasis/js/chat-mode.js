(function(global) {
    'use strict';
    const config = global.OasisChatConfig || {};
    const strings = global.OasisChatStrings || {};
    const t = (key, fallback) => strings[key] || fallback;
    let state = null;
    let saving = false;
    let busy = false;
    let revision = 0;
    let button, label, notice;

    function reason(value) {
        if (!value) return '';
        switch (value.reason_code || value.service_reason_code) {
        case 'agent_unavailable': return t('agentUnavailable', 'Install or repair oasis-mod-agent to use Agent mode.');
        case 'agent_incompatible': return t('agentIncompatible', 'Update oasis-mod-agent to use Agent mode.');
        case 'tool_incompatible': return t('toolIncompatible', 'Install a compatible oasis-mod-tool package.');
        case 'local_tools_disabled': return t('localToolsDisabled', 'Enable Local Tool support to use Agent mode.');
        case 'control_tools_unavailable': return t('controlToolsUnavailable', 'Refresh Agent tool registrations before enabling Agent mode.');
        case 'function_calling_disabled': return t('functionCallingDisabled', 'The selected AI service has Function Calling disabled.');
        case 'service_unsupported': return t('serviceUnsupported', 'The selected AI service does not support Agent tools.');
        default: return value.reason || '';
        }
    }

    function render() {
        if (!button) return;
        const enabled = state && state.enabled;
        button.setAttribute('aria-checked', String(!!enabled));
        button.setAttribute('aria-busy', String(saving));
        button.disabled = busy || saving || !state
            || !(enabled ? state.can_disable : state.can_enable);
        label.textContent = saving ? t('loading', 'Loading...')
            : !state ? t('modeUnknown', 'Mode status unavailable')
            : enabled ? t('agentOn', 'Agent: ON') : t('agentOff', 'Agent: OFF');
        notice.textContent = state ? reason(state) : t('modeLoadFailed', 'Could not load the conversation mode.');
        notice.hidden = !notice.textContent;
    }

    async function reload() {
        const current = ++revision;
        try {
            const response = await fetch(config.urls.getMode, {cache: 'no-store'});
            const value = await response.json();
            if (!response.ok || !value || value.status !== 'OK'
                || typeof value.enabled !== 'boolean' || typeof value.can_enable !== 'boolean'
                || typeof value.can_disable !== 'boolean' || typeof value.token !== 'string') {
                throw new Error('Invalid mode response');
            }
            if (current === revision) state = value;
        } catch (_) {
            if (current === revision) state = null;
        }
        render();
    }

    async function change() {
        if (!state || saving || busy || button.disabled) return;
        saving = true;
        ++revision;
        render();
        let error = '';
        try {
            const response = await fetch(config.urls.setMode, {
                method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: new URLSearchParams({mode: state.enabled ? 'normal' : 'agent',
                    generation: state.token, token: config.csrfToken || ''})
            });
            const result = await response.json();
            if (!response.ok || !result || result.status !== 'OK') {
                throw new Error((result && result.error) || t('modeSaveFailed', 'Could not change the conversation mode.'));
            }
        } catch (err) {
            error = err.message || t('modeSaveFailed', 'Could not change the conversation mode.');
        } finally {
            // A lost response may follow a successful commit. Always reload.
            await reload();
            saving = false;
            render();
            if (error) { notice.textContent = error; notice.hidden = false; }
        }
    }

    global.OasisChatMode = {
        isSaving: () => saving,
        reload,
        setBusy(value) {
            const wasBusy = busy;
            busy = !!value;
            render();
            if (wasBusy && !busy && button && !saving) reload();
        }
    };
    document.addEventListener('DOMContentLoaded', () => {
        button = document.getElementById('agent-mode-switch');
        label = document.getElementById('agent-mode-label');
        notice = document.getElementById('agent-mode-notice');
        if (!button || !label || !notice) return;
        button.addEventListener('click', change);
        render();
        reload();
    });
    global.addEventListener('focus', () => { if (button && !busy && !saving) reload(); });
})(window);
