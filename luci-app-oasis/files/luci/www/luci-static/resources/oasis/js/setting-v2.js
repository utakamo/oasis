(function() {
    'use strict';

    const STR = window.OasisSettingV2Strings || {};
    const CONFIG = window.OasisSettingV2Config || {};
    const URLS = CONFIG.urls || {};
    const LOAD_SETTINGS_URL = URLS.loadSettings || '';
    const UPDATE_SETTINGS_URL = URLS.updateSettings || '';
    const CSRF_TOKEN = CONFIG.csrfToken || '';
    const MAX_SERVICES = 32;
    const PROVIDERS = [
        'Ollama',
        'OpenAI',
        'Anthropic',
        'Gemini',
        'OpenRouter',
        'LM Studio'
    ];
    const ENDPOINT_TYPES = [
        { value: 'default', label: 'officialEndpoint', fallback: 'Official endpoint' },
        { value: 'custom', label: 'customEndpointType', fallback: 'Custom endpoint' }
    ];
    const OPENAI_API_MODES = [
        { value: 'responses', label: 'responsesApi', fallback: 'Responses API' },
        { value: 'chat_completions', label: 'chatCompletionsApi', fallback: 'Chat Completions API' }
    ];
    const ANTHROPIC_THINKING_MODES = [
        { value: 'disabled', label: 'thinkingDisabled', fallback: 'Disabled' },
        { value: 'enabled', label: 'thinkingEnabled', fallback: 'Enabled with manual budget' },
        { value: 'adaptive', label: 'thinkingAdaptive', fallback: 'Adaptive' }
    ];
    const API_KEY_ACTIONS = [
        { value: 'keep', label: 'apiKeyKeep', fallback: 'Keep current key' },
        { value: 'replace', label: 'apiKeyReplace', fallback: 'Replace with a new key' },
        { value: 'clear', label: 'apiKeyClear', fallback: 'Clear stored key' }
    ];
    const API_KEY_ACTIONS_WITH_PLACEHOLDER = [
        {
            value: '',
            label: 'selectApiKeyAction',
            fallback: 'Select an API key action',
            disabled: true
        }
    ].concat(API_KEY_ACTIONS);
    const ENDPOINT_FIELDS = {
        OpenAI: {
            type: 'openai_endpoint_type',
            custom: 'openai_custom_endpoint'
        },
        Anthropic: {
            type: 'anthropic_endpoint_type',
            custom: 'anthropic_custom_endpoint'
        },
        Gemini: {
            type: 'gemini_endpoint_type',
            custom: 'gemini_custom_endpoint'
        },
        OpenRouter: {
            type: 'openrouter_endpoint_type',
            custom: 'openrouter_custom_endpoint'
        }
    };

    const root = document.getElementById('oasis-setting-v2');
    const loading = document.getElementById('oasis-setting-v2-loading');
    const errorPanel = document.getElementById('oasis-setting-v2-error');
    const errorMessage = document.getElementById('oasis-setting-v2-error-message');
    const retryButton = document.getElementById('oasis-setting-v2-retry');
    const form = document.getElementById('oasis-setting-v2-form');
    const generalContainer = document.getElementById('oasis-setting-v2-general');
    const servicesContainer = document.getElementById('oasis-setting-v2-services');
    const servicesEmpty = document.getElementById('oasis-setting-v2-services-empty');
    const serviceCount = document.getElementById('oasis-setting-v2-service-count');
    const addServiceButton = document.getElementById('oasis-setting-v2-add-service');
    const resetButton = document.getElementById('oasis-setting-v2-reset');
    const saveButton = document.getElementById('oasis-setting-v2-save');
    const saveStatus = document.getElementById('oasis-setting-v2-save-status');
    const saveStatusMessage = document.getElementById('oasis-setting-v2-save-status-message');
    const reloadButton = document.getElementById('oasis-setting-v2-reload');

    let snapshot = null;
    let draft = null;
    let revision = '';
    let capabilities = {};
    let dirty = false;
    let saving = false;
    let clientKey = 0;

    function t(key, fallback) {
        return Object.prototype.hasOwnProperty.call(STR, key) ? STR[key] : fallback;
    }

    function isObject(value) {
        return value !== null && typeof value === 'object' && !Array.isArray(value);
    }

    function hasOwn(object, key) {
        return isObject(object) && Object.prototype.hasOwnProperty.call(object, key);
    }

    function deepClone(value) {
        return JSON.parse(JSON.stringify(value));
    }

    function requestJson(url, options, acceptErrorPayload) {
        return fetch(url, options).then(function(response) {
            return response.text().then(function(body) {
                let data = null;

                try {
                    data = body ? JSON.parse(body) : null;
                } catch (error) {
                    throw new Error('The settings API returned invalid JSON.');
                }

                if (!response.ok && !(acceptErrorPayload && isObject(data))) {
                    throw new Error('The settings API request failed with HTTP ' + response.status + '.');
                }

                return data;
            });
        });
    }

    function getSettings() {
        return requestJson(LOAD_SETTINGS_URL, {
            method: 'GET',
            credentials: 'same-origin',
            cache: 'no-store',
            headers: {
                Accept: 'application/json'
            }
        }, false);
    }

    function setSettings(expectedRevision, settings, services) {
        const body = new URLSearchParams();

        body.set('token', CSRF_TOKEN);
        body.set('payload', JSON.stringify({
            revision: expectedRevision,
            settings: settings,
            services: services
        }));

        return requestJson(UPDATE_SETTINGS_URL, {
            method: 'POST',
            credentials: 'same-origin',
            cache: 'no-store',
            headers: {
                Accept: 'application/json',
                'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'
            },
            body: body.toString()
        }, true);
    }

    function clearElement(element) {
        if (!element) {
            return;
        }

        while (element.firstChild) {
            element.removeChild(element.firstChild);
        }
    }

    function createElement(tagName, className, text) {
        const element = document.createElement(tagName);

        if (className) {
            element.className = className;
        }

        if (text !== undefined && text !== null) {
            element.textContent = String(text);
        }

        return element;
    }

    function stringValue(value, fallback) {
        if (typeof value === 'string' || typeof value === 'number') {
            return String(value);
        }

        return fallback === undefined ? '' : fallback;
    }

    function flagEnabled(value) {
        return value === true || value === 1 || value === '1';
    }

    function setDirty(value) {
        dirty = value === true;
        saveButton.disabled = !dirty || saving;
        resetButton.disabled = !dirty || saving;
    }

    function setSaving(value) {
        saving = value === true;
        root.setAttribute('aria-busy', saving ? 'true' : 'false');
        saveButton.disabled = saving || !dirty;
        resetButton.disabled = saving || !dirty;

        form.querySelectorAll('input, select, button').forEach(function(control) {
            if (control === reloadButton) {
                return;
            }

            if (saving) {
                control.dataset.oasisWasDisabled = control.disabled ? '1' : '0';
                control.disabled = true;
            } else if (hasOwn(control.dataset, 'oasisWasDisabled')) {
                control.disabled = control.dataset.oasisWasDisabled === '1';
                delete control.dataset.oasisWasDisabled;
            }
        });
    }

    function hideSaveStatus() {
        saveStatus.hidden = true;
        saveStatus.className = 'oasis-setting-v2__save-status';
        saveStatus.removeAttribute('role');
        reloadButton.hidden = true;
    }

    function showSaveStatus(type, message, showReload) {
        saveStatus.className = 'oasis-setting-v2__save-status oasis-setting-v2__save-status--' + type;
        saveStatus.setAttribute(
            'role',
            type === 'success' || type === 'progress' ? 'status' : 'alert'
        );
        saveStatusMessage.textContent = message;
        reloadButton.hidden = showReload !== true;
        saveStatus.hidden = false;

        if (type === 'error' || type === 'warning') {
            saveStatus.focus();
        }
    }

    function setInitialState(state) {
        const isLoading = state === 'loading';

        root.setAttribute('aria-busy', isLoading ? 'true' : 'false');
        loading.hidden = !isLoading;
        errorPanel.hidden = state !== 'error';
        form.hidden = state !== 'ready';

        if (state === 'error') {
            retryButton.focus();
        }
    }

    function fieldPath(scope, index, key) {
        return scope === 'services'
            ? 'services.' + index + '.' + key
            : 'settings.' + key;
    }

    function createHelp(text) {
        return createElement('p', 'oasis-setting-v2__help', text);
    }

    function createField(label, control, options) {
        const opts = options || {};
        const wrapper = createElement('div', 'oasis-setting-v2__field');
        const id = 'oasis-setting-v2-' + opts.path.replace(/[^A-Za-z0-9_-]/g, '-');
        const labelNode = createElement('label', '', label);
        const errorNode = createElement('p', 'oasis-setting-v2__field-error');
        const describedBy = [];

        control.id = id;
        control.dataset.fieldPath = opts.path;
        labelNode.htmlFor = id;

        if (opts.required) {
            control.required = true;
            control.setAttribute('aria-required', 'true');
            const requiredMark = createElement(
                'span',
                'oasis-setting-v2__required',
                ' *'
            );
            requiredMark.setAttribute('aria-hidden', 'true');
            labelNode.appendChild(requiredMark);
        }

        wrapper.appendChild(labelNode);
        wrapper.appendChild(control);

        if (opts.help) {
            const helpNode = createHelp(opts.help);
            helpNode.id = id + '-help';
            describedBy.push(helpNode.id);
            wrapper.appendChild(helpNode);
        }

        errorNode.id = id + '-error';
        errorNode.hidden = true;
        describedBy.push(errorNode.id);
        wrapper.appendChild(errorNode);
        control.setAttribute('aria-describedby', describedBy.join(' '));

        return wrapper;
    }

    function createTextInput(value, onChange, options) {
        const opts = options || {};
        const input = document.createElement('input');

        input.type = opts.type || 'text';
        input.className = 'cbi-input-text';
        input.value = stringValue(value);
        input.autocomplete = opts.autocomplete || 'off';

        if (opts.placeholder) {
            input.placeholder = opts.placeholder;
        }
        if (opts.readOnly) {
            input.readOnly = true;
        }
        if (opts.maxLength) {
            input.maxLength = opts.maxLength;
        }
        if (opts.inputMode) {
            input.inputMode = opts.inputMode;
        }

        input.addEventListener('input', function() {
            onChange(input.value);
            clearControlError(input);
            setDirty(true);
            hideSaveStatus();
        });

        return input;
    }

    function createSelect(value, items, onChange) {
        const select = document.createElement('select');
        let matched = false;
        select.className = 'cbi-input-select';

        items.forEach(function(item) {
            const option = document.createElement('option');
            const itemValue = typeof item === 'string' ? item : item.value;
            const label = typeof item === 'string'
                ? item
                : (hasOwn(item, 'text') ? item.text : t(item.label, item.fallback));

            option.value = itemValue;
            option.textContent = label;
            option.selected = itemValue === value;
            option.disabled = typeof item !== 'string' && item.disabled === true;
            matched = matched || option.selected;
            select.appendChild(option);
        });

        if (!matched && value !== '') {
            const currentOption = document.createElement('option');
            currentOption.value = value;
            currentOption.textContent = value;
            currentOption.selected = true;
            select.appendChild(currentOption);
        }

        select.addEventListener('change', function() {
            clearControlError(select);
            setDirty(true);
            hideSaveStatus();
            onChange(select.value);
        });

        return select;
    }

    function createCheckbox(value, onChange, disabled) {
        const input = document.createElement('input');

        input.type = 'checkbox';
        input.className = 'oasis-setting-v2__checkbox';
        input.checked = flagEnabled(value);
        input.disabled = disabled === true;
        input.addEventListener('change', function() {
            onChange(input.checked ? '1' : '0');
            clearControlError(input);
            setDirty(true);
            hideSaveStatus();
        });

        return input;
    }

    function createPanel(title, description) {
        const panel = document.createElement('fieldset');
        const legend = createElement('legend', '', title);

        panel.className = 'oasis-setting-v2__panel';
        panel.appendChild(legend);

        if (description) {
            panel.appendChild(createElement(
                'p',
                'oasis-setting-v2__panel-description',
                description
            ));
        }

        return panel;
    }

    function addGeneralField(panel, key, label, control, options) {
        const opts = options || {};
        opts.path = fieldPath('settings', 0, key);
        panel.appendChild(createField(label, control, opts));
    }

    function renderGeneralSettings() {
        const settings = draft.settings;
        const integration = createPanel(t('integration', 'Integration'));
        const storage = createPanel(t('storage', 'Storage'));
        const rollback = createPanel(
            t('rollback', 'Rollback'),
            capabilities.rollback === true
                ? ''
                : t(
                    'moduleUnavailable',
                    'The rollback module is unavailable. Its settings cannot be changed.'
                )
        );

        clearElement(generalContainer);

        if (capabilities.assist === true) {
            addGeneralField(
                integration,
                'assist_enable',
                t('aiAssist', 'AI-assisted configuration'),
                createCheckbox(settings.assist_enable, function(value) {
                    settings.assist_enable = value;
                })
            );
        }

        addGeneralField(
            integration,
            'rpc_enable',
            t('rpcAccess', 'RPC access'),
            createCheckbox(settings.rpc_enable, function(value) {
                settings.rpc_enable = value;
            })
        );

        addGeneralField(
            storage,
            'storage_path',
            t('storagePath', 'Storage path'),
            createTextInput(settings.storage_path, function(value) {
                settings.storage_path = value;
            }, { maxLength: 512 }),
            {
                required: true,
                help: t('storagePathHelp', 'Use an absolute directory path.')
            }
        );

        const chatOptions = [];
        for (let chatMax = 10; chatMax <= 100; chatMax += 10) {
            chatOptions.push(String(chatMax));
        }
        addGeneralField(
            storage,
            'chat_max',
            t('chatMax', 'Maximum turns per chat'),
            createSelect(stringValue(settings.chat_max, '30'), chatOptions, function(value) {
                settings.chat_max = value;
            }),
            { required: true }
        );

        addGeneralField(
            rollback,
            'rollback_enable',
            t('rollbackData', 'Store rollback data'),
            createCheckbox(settings.rollback_enable, function(value) {
                settings.rollback_enable = value;
            }, capabilities.rollback !== true)
        );

        const timeOptions = [];
        for (let seconds = 60; seconds <= 600; seconds += 60) {
            timeOptions.push({
                value: String(seconds),
                text: seconds + ' ' + t('seconds', 'seconds')
            });
        }
        addGeneralField(
            rollback,
            'rollback_time',
            t('monitorTime', 'Monitor time'),
            createSelect(stringValue(settings.rollback_time, '300'), timeOptions, function(value) {
                settings.rollback_time = value;
            }),
            { required: true }
        );
        if (capabilities.rollback !== true) {
            rollback.lastElementChild.querySelector('select').disabled = true;
        }

        generalContainer.appendChild(integration);
        generalContainer.appendChild(storage);
        generalContainer.appendChild(rollback);
    }

    function normalizeServiceForDisplay(service) {
        const normalized = isObject(service) ? deepClone(service) : {};

        normalized.identifier = stringValue(normalized.identifier);
        normalized._is_new = normalized.identifier === '';
        normalized.name = stringValue(normalized.name) || PROVIDERS[0];
        normalized.model = stringValue(normalized.model);
        normalized.function_calling = flagEnabled(normalized.function_calling) ? '1' : '0';
        normalized.show_thinking = flagEnabled(normalized.show_thinking) ? '1' : '0';
        normalized.api_key_set = flagEnabled(normalized.api_key_set);
        normalized.api_key_action = API_KEY_ACTIONS.some(function(item) {
            return item.value === normalized.api_key_action;
        }) ? normalized.api_key_action : 'keep';
        normalized.api_key = '';
        normalized._original_name = stringValue(
            normalized._original_name,
            normalized.name
        );
        normalized._client_key = ++clientKey;

        return normalized;
    }

    function newService() {
        return normalizeServiceForDisplay({
            identifier: '',
            name: 'Ollama',
            model: '',
            function_calling: '0',
            show_thinking: '0',
            api_key_set: false,
            api_key_action: 'replace',
            _original_name: '',
            ollama_endpoint: ''
        });
    }

    function addServiceField(fields, index, key, label, control, options) {
        const opts = options || {};
        opts.path = fieldPath('services', index, key);
        fields.appendChild(createField(label, control, opts));
    }

    function rerenderServices(focusIndex, focusKey) {
        renderServices();

        if (focusIndex !== undefined && focusKey) {
            const path = fieldPath('services', focusIndex, focusKey);
            const control = Array.prototype.find.call(
                form.querySelectorAll('[data-field-path]'),
                function(item) {
                    return item.dataset.fieldPath === path;
                }
            );

            if (control) {
                control.focus();
            }
        }
    }

    function changeProvider(index, provider) {
        const current = draft.services[index];
        const replacement = normalizeServiceForDisplay({
            identifier: current.identifier,
            name: provider,
            model: '',
            function_calling: current.function_calling,
            show_thinking: current.show_thinking,
            api_key_set: current.api_key_set,
            api_key_action: 'keep',
            _original_name: current._original_name
        });

        replacement._client_key = current._client_key;
        if (replacement.identifier === '') {
            replacement.api_key_action = 'replace';
        } else {
            replacement.api_key_action = current.api_key_set &&
                current._original_name !== provider
                ? ''
                : 'keep';
        }

        if (provider === 'Ollama') {
            replacement.ollama_endpoint = '';
        } else if (provider === 'OpenAI') {
            replacement.openai_endpoint_type = 'default';
            replacement.openai_custom_endpoint = '';
            replacement.openai_api_mode = 'chat_completions';
        } else if (provider === 'Anthropic') {
            replacement.anthropic_endpoint_type = 'default';
            replacement.anthropic_custom_endpoint = '';
            replacement.max_tokens = '1024';
            replacement.thinking = 'disabled';
            replacement.budget_tokens = '';
        } else if (provider === 'Gemini') {
            replacement.gemini_endpoint_type = 'default';
            replacement.gemini_custom_endpoint = '';
        } else if (provider === 'OpenRouter') {
            replacement.openrouter_endpoint_type = 'default';
            replacement.openrouter_custom_endpoint = '';
        } else if (provider === 'LM Studio') {
            replacement.lmstudio_endpoint = '';
        }

        draft.services[index] = replacement;
        rerenderServices(index, 'name');

        if (replacement.api_key_action === '') {
            showSaveStatus(
                'warning',
                t(
                    'providerKeyCleared',
                    'The provider changed. Choose whether to replace or clear the stored API key.'
                ),
                false
            );
        }
    }

    function addEndpointFields(fields, service, index) {
        const endpointConfig = ENDPOINT_FIELDS[service.name];

        if (service.name === 'Ollama') {
            addServiceField(
                fields,
                index,
                'ollama_endpoint',
                t('endpoint', 'Endpoint'),
                createTextInput(service.ollama_endpoint, function(value) {
                    service.ollama_endpoint = value;
                }, {
                    maxLength: 2048,
                    placeholder: 'http://192.0.2.1:11434/api/chat'
                }),
                { required: true }
            );
            return;
        }

        if (service.name === 'LM Studio') {
            addServiceField(
                fields,
                index,
                'lmstudio_endpoint',
                t('endpoint', 'Endpoint'),
                createTextInput(service.lmstudio_endpoint, function(value) {
                    service.lmstudio_endpoint = value;
                }, {
                    maxLength: 2048,
                    placeholder: 'http://192.0.2.1:1234/api/v1/chat'
                }),
                { required: true }
            );
            return;
        }

        if (!endpointConfig) {
            return;
        }

        const endpointType = service[endpointConfig.type] === 'custom'
            ? 'custom'
            : 'default';
        service[endpointConfig.type] = endpointType;

        addServiceField(
            fields,
            index,
            endpointConfig.type,
            t('endpointType', 'Endpoint type'),
            createSelect(endpointType, ENDPOINT_TYPES, function(value) {
                service[endpointConfig.type] = value;
                rerenderServices(index, endpointConfig.type);
            }),
            { required: true }
        );

        if (endpointType === 'custom') {
            addServiceField(
                fields,
                index,
                endpointConfig.custom,
                t('customEndpoint', 'Custom endpoint URL'),
                createTextInput(service[endpointConfig.custom], function(value) {
                    service[endpointConfig.custom] = value;
                }, {
                    maxLength: 2048,
                    placeholder: 'https://example.com/api'
                }),
                { required: true }
            );
        }
    }

    function addProviderFields(fields, service, index) {
        addEndpointFields(fields, service, index);

        if (service.name === 'OpenAI') {
            const mode = service.openai_api_mode === 'responses'
                ? 'responses'
                : 'chat_completions';
            service.openai_api_mode = mode;
            addServiceField(
                fields,
                index,
                'openai_api_mode',
                t('apiMode', 'API mode'),
                createSelect(mode, OPENAI_API_MODES, function(value) {
                    service.openai_api_mode = value;
                }),
                { required: true }
            );
        }

        if (service.name === 'Anthropic') {
            const thinking = ANTHROPIC_THINKING_MODES.some(function(item) {
                return item.value === service.thinking;
            }) ? service.thinking : 'disabled';
            service.thinking = thinking;

            addServiceField(
                fields,
                index,
                'max_tokens',
                t('maxTokens', 'Max Tokens'),
                createTextInput(stringValue(service.max_tokens, '1024'), function(value) {
                    service.max_tokens = value;
                }, {
                    maxLength: 12,
                    inputMode: 'numeric'
                }),
                {
                    required: true,
                    help: t('maxTokensHelp', 'Enter a positive integer.')
                }
            );
            addServiceField(
                fields,
                index,
                'thinking',
                t('thinkingMode', 'Thinking mode'),
                createSelect(thinking, ANTHROPIC_THINKING_MODES, function(value) {
                    service.thinking = value;
                    if (value !== 'enabled') {
                        service.budget_tokens = '';
                    }
                    rerenderServices(index, 'thinking');
                }),
                { required: true }
            );

            if (thinking === 'enabled') {
                addServiceField(
                    fields,
                    index,
                    'budget_tokens',
                    t('budgetTokens', 'Budget Tokens'),
                    createTextInput(service.budget_tokens, function(value) {
                        service.budget_tokens = value;
                    }, {
                        maxLength: 12,
                        inputMode: 'numeric'
                    }),
                    {
                        required: true,
                        help: t(
                            'budgetTokensHelp',
                            'Enter at least 1024 and less than Max Tokens.'
                        )
                    }
                );
            }
        }
    }

    function addApiKeyFields(fields, service, index) {
        if (service._is_new === true || service.identifier === '') {
            const setupSelect = createSelect(
                'replace',
                [ {
                    value: 'replace',
                    label: 'apiKeySetup',
                    fallback: 'API Key Setup'
                } ],
                function() {}
            );

            service.api_key_set = false;
            service.api_key_action = 'replace';
            setupSelect.disabled = true;
            addServiceField(
                fields,
                index,
                'api_key_action',
                t('apiKeyAction', 'API key action'),
                setupSelect
            );
            addServiceField(
                fields,
                index,
                'api_key',
                t('newApiKey', 'New API key'),
                createTextInput(service.api_key, function(value) {
                    service.api_key = value;
                }, {
                    type: 'password',
                    maxLength: 8192,
                    autocomplete: 'new-password'
                }),
                {
                    help: t(
                        'apiKeySecretHelp',
                        'The new key is sent only when you save and is never returned by the server.'
                    )
                }
            );
            return;
        }

        const status = service.api_key_set
            ? t('apiKeyStatusConfigured', 'A key is currently configured.')
            : t('apiKeyStatusEmpty', 'No key is currently configured.');
        const statusNode = createElement(
            'p',
            service.api_key_set
                ? 'oasis-setting-v2__secret-status oasis-setting-v2__secret-status--configured'
                : 'oasis-setting-v2__secret-status'
        );

        statusNode.appendChild(createElement(
            'strong',
            '',
            t('apiKey', 'API key') + ': '
        ));
        statusNode.appendChild(document.createTextNode(status));
        fields.appendChild(statusNode);
        addServiceField(
            fields,
            index,
            'api_key_action',
            t('apiKeyAction', 'API key action'),
            createSelect(
                service.api_key_action,
                API_KEY_ACTIONS_WITH_PLACEHOLDER,
                function(value) {
                    service.api_key_action = value;
                    if (value !== 'replace') {
                        service.api_key = '';
                    }
                    rerenderServices(index, 'api_key_action');
                }
            ),
            { required: true }
        );

        if (service.api_key_action === 'replace') {
            addServiceField(
                fields,
                index,
                'api_key',
                t('newApiKey', 'New API key'),
                createTextInput(service.api_key, function(value) {
                    service.api_key = value;
                }, {
                    type: 'password',
                    maxLength: 8192,
                    autocomplete: 'new-password'
                }),
                {
                    help: t(
                        'apiKeySecretHelp',
                        'The new key is sent only when you save and is never returned by the server.'
                    )
                }
            );
        }
    }

    function createServiceButton(className, label, disabled, handler) {
        const button = createElement('button', 'cbi-button ' + className, label);

        button.type = 'button';
        button.disabled = disabled;
        button.addEventListener('click', handler);
        return button;
    }

    function renderService(service, index) {
        const card = createElement('article', 'oasis-setting-v2__service-card');
        const heading = createElement('div', 'oasis-setting-v2__service-heading');
        const titleGroup = createElement('div', 'oasis-setting-v2__service-title');
        const title = createElement(
            'h4',
            '',
            '#' + (index + 1) + ' ' + stringValue(service.name, PROVIDERS[0])
        );
        const toolbar = createElement('div', 'oasis-setting-v2__service-toolbar');
        const fields = createElement('div', 'oasis-setting-v2__service-fields');

        card.dataset.clientKey = service._client_key;
        titleGroup.appendChild(title);

        if (index === 0) {
            card.classList.add('oasis-setting-v2__service-card--active');
            titleGroup.appendChild(createElement(
                'span',
                'oasis-setting-v2__badge',
                t('active', 'Active')
            ));
        }

        heading.appendChild(titleGroup);
        if (!service._is_new) {
            toolbar.appendChild(createServiceButton(
                'cbi-button-remove',
                t('removeService', 'Remove service'),
                false,
                function() {
                    if (!window.confirm(t(
                        'removeConfirm',
                        'Remove this AI service from the configuration?'
                    ))) {
                        return;
                    }

                    draft.services.splice(index, 1);
                    setDirty(true);
                    hideSaveStatus();
                    renderServices();
                    addServiceButton.focus();
                }
            ));
            heading.appendChild(toolbar);
        }
        card.appendChild(heading);

        addServiceField(
            fields,
            index,
            'name',
            t('provider', 'Provider'),
            createSelect(service.name, PROVIDERS, function(value) {
                changeProvider(index, value);
            }),
            { required: true }
        );

        addServiceField(
            fields,
            index,
            'model',
            t('model', 'Model'),
            createTextInput(service.model, function(value) {
                service.model = value;
            }, { maxLength: 256 }),
            { required: true }
        );

        addProviderFields(fields, service, index);
        addApiKeyFields(fields, service, index);

        addServiceField(
            fields,
            index,
            'function_calling',
            t('functionCalling', 'Function Calling'),
            createCheckbox(service.function_calling, function(value) {
                service.function_calling = value;
            }),
            {
                help: t(
                    'functionCallingHelp',
                    'Enable only when the selected provider and model support tool use.'
                )
            }
        );
        addServiceField(
            fields,
            index,
            'show_thinking',
            t('showThinking', 'Show thinking'),
            createCheckbox(service.show_thinking, function(value) {
                service.show_thinking = value;
            }),
            {
                help: t(
                    'showThinkingHelp',
                    'Controls display only; it does not enable model thinking.'
                )
            }
        );

        card.appendChild(fields);
        return card;
    }

    function renderServices() {
        clearElement(servicesContainer);
        addServiceButton.disabled = draft.services.length >= MAX_SERVICES;
        serviceCount.textContent = draft.services.length + ' ' + (
            draft.services.length === 1
                ? t('service', 'service')
                : t('services', 'services')
        );

        servicesEmpty.hidden = draft.services.length !== 0;
        draft.services.forEach(function(service, index) {
            servicesContainer.appendChild(renderService(service, index));
        });
    }

    function responseServices(services) {
        if (Array.isArray(services)) {
            return services;
        }

        // LuCI's Lua JSON encoder represents an empty Lua table as {}.  For
        // this API, services is always a list, so accept only the empty object
        // form as an empty service list for compatibility with that encoder.
        if (isObject(services) && Object.keys(services).length === 0) {
            return [];
        }

        return null;
    }

    function validResponse(response) {
        const services = isObject(response)
            ? responseServices(response.services)
            : null;

        return isObject(response) &&
            response.schema_version === 1 &&
            typeof response.revision === 'string' &&
            isObject(response.settings) &&
            isObject(response.capabilities) &&
            services !== null &&
            services.every(function(service) {
                return isObject(service) &&
                    typeof service.identifier === 'string' &&
                    typeof service.name === 'string' &&
                    typeof service.model === 'string' &&
                    typeof service.function_calling === 'string' &&
                    typeof service.show_thinking === 'string' &&
                    typeof service.api_key_set === 'boolean' &&
                    typeof service.active === 'boolean';
            });
    }

    function applySnapshot(response) {
        if (!validResponse(response)) {
            throw new Error('Invalid Oasis settings API response');
        }

        const services = responseServices(response.services);

        revision = response.revision;
        capabilities = deepClone(response.capabilities);
        snapshot = {
            settings: deepClone(response.settings),
            services: services.map(normalizeServiceForDisplay)
        };
        draft = deepClone(snapshot);

        renderGeneralSettings();
        renderServices();
        clearAllErrors();
        hideSaveStatus();
        setDirty(false);
    }

    function clearControlError(control) {
        const wrapper = control && control.closest('.oasis-setting-v2__field');
        const errorNode = wrapper && wrapper.querySelector('.oasis-setting-v2__field-error');

        if (!control || !errorNode) {
            return;
        }

        control.removeAttribute('aria-invalid');
        wrapper.classList.remove('oasis-setting-v2__field--error');
        errorNode.textContent = '';
        errorNode.hidden = true;
    }

    function clearAllErrors() {
        form.querySelectorAll('[data-field-path]').forEach(clearControlError);
    }

    function controlForPath(path) {
        return Array.prototype.find.call(
            form.querySelectorAll('[data-field-path]'),
            function(control) {
                return control.dataset.fieldPath === path;
            }
        ) || null;
    }

    function setFieldError(path, message) {
        const control = controlForPath(path);
        const wrapper = control && control.closest('.oasis-setting-v2__field');
        const errorNode = wrapper && wrapper.querySelector('.oasis-setting-v2__field-error');

        if (!control || !errorNode) {
            return false;
        }

        control.setAttribute('aria-invalid', 'true');
        wrapper.classList.add('oasis-setting-v2__field--error');
        errorNode.textContent = stringValue(message, t('validationFailed', 'Invalid value.'));
        errorNode.hidden = false;
        return true;
    }

    function trimmed(value) {
        return stringValue(value).trim();
    }

    function isPositiveInteger(value) {
        return /^[0-9]+$/.test(value) && Number(value) > 0;
    }

    function isHttpUrl(value) {
        const text = stringValue(value);
        const authorityMatch = text.match(/^https?:\/\/([^/?#]+)/i);
        const rawPortMatch = authorityMatch && authorityMatch[1].match(/:([0-9]+)$/);

        if (/[\s\\]/.test(text) ||
            !authorityMatch ||
            !/^[A-Za-z0-9_.:\[\]-]+$/.test(authorityMatch[1]) ||
            /@/.test(authorityMatch[1]) ||
            /:$/.test(authorityMatch[1]) ||
            (rawPortMatch &&
                (rawPortMatch[1].length > 5 ||
                    Number(rawPortMatch[1]) < 1 ||
                    Number(rawPortMatch[1]) > 65535))) {
            return false;
        }

        try {
            const parsed = new URL(text);
            const hostname = parsed.hostname;
            const bracketed = hostname.charAt(0) === '[';
            const unbracketed = bracketed
                ? hostname.slice(1, -1)
                : hostname;
            const port = parsed.port ? Number(parsed.port) : null;
            const validHostname = bracketed
                ? unbracketed.indexOf(':') !== -1
                : /[A-Za-z0-9]/.test(unbracketed) &&
                    !/^\./.test(unbracketed) &&
                    !/\.\./.test(unbracketed) &&
                    !/(^|\.)-/.test(unbracketed) &&
                    !/-(\.|$)/.test(unbracketed);

            if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') ||
                parsed.username ||
                parsed.password ||
                !validHostname) {
                return false;
            }

            return port === null || (port >= 1 && port <= 65535);
        } catch (error) {
            return false;
        }
    }

    function validateRequired(path, value, errors) {
        if (!trimmed(value)) {
            errors[path] = t('required', 'This field is required.');
            return false;
        }
        return true;
    }

    function validateEndpoint(path, value, errors) {
        if (!validateRequired(path, value, errors)) {
            return;
        }
        if (!isHttpUrl(trimmed(value))) {
            errors[path] = t('validUrlRequired', 'Enter a valid HTTP or HTTPS URL.');
        }
    }

    function validateDraft() {
        const errors = {};
        const settings = draft.settings;
        const identifiers = {};
        const storagePath = trimmed(settings.storage_path);

        if (!validateRequired('settings.storage_path', storagePath, errors)) {
            // Required error is sufficient.
        } else if (storagePath.charAt(0) !== '/') {
            errors['settings.storage_path'] = t(
                'absolutePathRequired',
                'Enter an absolute path beginning with a slash.'
            );
        } else if (storagePath.length > 512) {
            errors['settings.storage_path'] = t('valueTooLong', 'The value is too long.');
        } else if (/[\u0000-\u001f\u007f]/.test(storagePath)) {
            errors['settings.storage_path'] = t(
                'absolutePathRequired',
                'Enter a valid absolute path beginning with a slash.'
            );
        } else if (storagePath.split('/').indexOf('..') !== -1) {
            errors['settings.storage_path'] = t(
                'parentPathNotAllowed',
                'The storage path must not contain parent directory segments.'
            );
        }

        const chatMax = Number(settings.chat_max);
        if (!isPositiveInteger(stringValue(settings.chat_max))) {
            errors['settings.chat_max'] = t(
                'positiveIntegerRequired',
                'Enter a positive integer.'
            );
        } else if (chatMax < 10 || chatMax > 100 || chatMax % 10 !== 0) {
            errors['settings.chat_max'] = t(
                'chatMaxRange',
                'Select a value from 10 to 100 in steps of 10.'
            );
        }

        const rollbackTime = Number(settings.rollback_time);
        if (capabilities.rollback === true &&
            !isPositiveInteger(stringValue(settings.rollback_time))) {
            errors['settings.rollback_time'] = t(
                'positiveIntegerRequired',
                'Enter a positive integer.'
            );
        } else if (capabilities.rollback === true &&
            (rollbackTime < 60 || rollbackTime > 600 || rollbackTime % 60 !== 0)) {
            errors['settings.rollback_time'] = t(
                'monitorTimeRange',
                'Select a value from 60 to 600 seconds in steps of 60.'
            );
        }

        draft.services.forEach(function(service, index) {
            const prefix = 'services.' + index + '.';
            const identifier = trimmed(service.identifier);
            const model = trimmed(service.model);

            const unchangedUnsupportedProvider =
                PROVIDERS.indexOf(service.name) === -1 &&
                identifier.length > 0 &&
                service._original_name === service.name;

            if (PROVIDERS.indexOf(service.name) === -1 &&
                !unchangedUnsupportedProvider) {
                errors[prefix + 'name'] = t('required', 'This field is required.');
            }
            if (!model) {
                errors[prefix + 'model'] = t('required', 'This field is required.');
            } else if (model.length > 256) {
                errors[prefix + 'model'] = t('valueTooLong', 'The value is too long.');
            }

            if (identifier) {
                if (hasOwn(identifiers, identifier)) {
                    errors[prefix + 'identifier'] = t(
                        'duplicateIdentifier',
                        'Each service identifier must be unique.'
                    );
                    errors['services.' + identifiers[identifier] + '.identifier'] =
                        errors[prefix + 'identifier'];
                } else {
                    identifiers[identifier] = index;
                }
            }

            if (service.name === 'Ollama') {
                validateEndpoint(prefix + 'ollama_endpoint', service.ollama_endpoint, errors);
                if (trimmed(service.ollama_endpoint).length > 2048) {
                    errors[prefix + 'ollama_endpoint'] = t(
                        'valueTooLong',
                        'The value is too long.'
                    );
                }
            } else if (service.name === 'LM Studio') {
                validateEndpoint(prefix + 'lmstudio_endpoint', service.lmstudio_endpoint, errors);
                if (trimmed(service.lmstudio_endpoint).length > 2048) {
                    errors[prefix + 'lmstudio_endpoint'] = t(
                        'valueTooLong',
                        'The value is too long.'
                    );
                }
            } else if (hasOwn(ENDPOINT_FIELDS, service.name)) {
                const endpointConfig = ENDPOINT_FIELDS[service.name];
                if (service[endpointConfig.type] !== 'default' &&
                    service[endpointConfig.type] !== 'custom') {
                    errors[prefix + endpointConfig.type] = t(
                        'required',
                        'This field is required.'
                    );
                }
                if (service[endpointConfig.type] === 'custom') {
                    validateEndpoint(
                        prefix + endpointConfig.custom,
                        service[endpointConfig.custom],
                        errors
                    );
                    if (trimmed(service[endpointConfig.custom]).length > 2048) {
                        errors[prefix + endpointConfig.custom] = t(
                            'valueTooLong',
                            'The value is too long.'
                        );
                    }
                }
            }

            if (service.name === 'Anthropic') {
                const maxText = trimmed(service.max_tokens);
                const maxNumber = Number(maxText);
                if (!ANTHROPIC_THINKING_MODES.some(function(item) {
                    return item.value === service.thinking;
                })) {
                    errors[prefix + 'thinking'] = t(
                        'required',
                        'This field is required.'
                    );
                }
                if (!isPositiveInteger(maxText)) {
                    errors[prefix + 'max_tokens'] = t(
                        'positiveIntegerRequired',
                        'Enter a positive integer.'
                    );
                }
                if (service.thinking === 'enabled') {
                    const budgetText = trimmed(service.budget_tokens);
                    const budgetNumber = Number(budgetText);
                    if (!isPositiveInteger(budgetText) || budgetNumber < 1024) {
                        errors[prefix + 'budget_tokens'] = t(
                            'budgetMinimum',
                            'Budget Tokens must be at least 1024.'
                        );
                    } else if (isPositiveInteger(maxText) && budgetNumber >= maxNumber) {
                        errors[prefix + 'budget_tokens'] = t(
                            'budgetLessThanMax',
                            'Budget Tokens must be less than Max Tokens.'
                        );
                    }
                }
            }

            if (service.name === 'OpenAI' &&
                !OPENAI_API_MODES.some(function(item) {
                    return item.value === service.openai_api_mode;
                })) {
                errors[prefix + 'openai_api_mode'] = t(
                    'required',
                    'This field is required.'
                );
            }

            if (service.api_key_set &&
                service._original_name !== service.name &&
                service.api_key_action !== 'replace' &&
                service.api_key_action !== 'clear') {
                errors[prefix + 'api_key_action'] = t(
                    'providerKeyActionRequired',
                    'Choose Replace with a new key or Clear stored key after changing the provider.'
                );
            } else if (!API_KEY_ACTIONS.some(function(item) {
                return item.value === service.api_key_action;
            })) {
                errors[prefix + 'api_key_action'] = t(
                    'required',
                    'This field is required.'
                );
            }

            if (service.api_key_action === 'replace') {
                if (stringValue(service.api_key).length > 8192) {
                    errors[prefix + 'api_key'] = t('valueTooLong', 'The value is too long.');
                }
            }
        });

        return errors;
    }

    function normalizePayload() {
        const settings = deepClone(draft.settings);
        const services = draft.services.map(function(source) {
            const service = {};
            const commonKeys = [
                'identifier',
                'name',
                'model',
                'function_calling',
                'show_thinking',
                'api_key_action'
            ];

            commonKeys.forEach(function(key) {
                service[key] = stringValue(source[key]);
            });
            service.identifier = trimmed(service.identifier);
            service.name = trimmed(service.name);
            service.model = trimmed(service.model);

            if (source.api_key_action === 'replace') {
                service.api_key = source.api_key;
            }

            if (source.name === 'Ollama') {
                service.ollama_endpoint = trimmed(source.ollama_endpoint);
            } else if (source.name === 'LM Studio') {
                service.lmstudio_endpoint = trimmed(source.lmstudio_endpoint);
            } else if (hasOwn(ENDPOINT_FIELDS, source.name)) {
                const endpointConfig = ENDPOINT_FIELDS[source.name];
                service[endpointConfig.type] = source[endpointConfig.type] === 'custom'
                    ? 'custom'
                    : 'default';
                if (service[endpointConfig.type] === 'custom') {
                    service[endpointConfig.custom] = trimmed(source[endpointConfig.custom]);
                }
            }

            if (source.name === 'OpenAI') {
                service.openai_api_mode = source.openai_api_mode === 'responses'
                    ? 'responses'
                    : 'chat_completions';
            } else if (source.name === 'Anthropic') {
                service.max_tokens = trimmed(source.max_tokens);
                service.thinking = source.thinking;
                if (source.thinking === 'enabled') {
                    service.budget_tokens = trimmed(source.budget_tokens);
                }
            }

            return service;
        });

        settings.storage_path = trimmed(settings.storage_path);
        settings.chat_max = stringValue(settings.chat_max);
        settings.rpc_enable = flagEnabled(settings.rpc_enable) ? '1' : '0';
        if (capabilities.rollback === true) {
            settings.rollback_time = stringValue(settings.rollback_time);
            settings.rollback_enable = flagEnabled(settings.rollback_enable) ? '1' : '0';
        } else {
            delete settings.rollback_time;
            delete settings.rollback_enable;
        }
        if (capabilities.assist === true) {
            settings.assist_enable = flagEnabled(settings.assist_enable) ? '1' : '0';
        } else {
            delete settings.assist_enable;
        }

        return {
            settings: settings,
            services: services
        };
    }

    function showValidationErrors(errors) {
        let firstControl = null;
        let firstMessage = '';

        Object.keys(errors).forEach(function(path) {
            if (!firstMessage) {
                firstMessage = stringValue(errors[path]);
            }
            if (setFieldError(path, errors[path]) && !firstControl) {
                firstControl = controlForPath(path);
            }
        });
        showSaveStatus(
            'error',
            firstControl
                ? t('validationFailed', 'Correct the highlighted fields before saving.')
                : (firstMessage || t(
                    'validationFailed',
                    'Correct the highlighted fields before saving.'
                )),
            false
        );

        if (firstControl) {
            firstControl.focus();
        }
    }

    function parseServerFields(fields) {
        if (isObject(fields)) {
            return fields;
        }

        if (!Array.isArray(fields)) {
            return {};
        }

        const result = {};
        fields.forEach(function(field) {
            if (isObject(field) && typeof field.path === 'string') {
                result[field.path] = stringValue(field.message, t('validationFailed', 'Invalid value.'));
            }
        });
        return result;
    }

    function handleSetFailure(response) {
        const failure = isObject(response) && isObject(response.error)
            ? response.error
            : {};
        const code = stringValue(failure.code);
        const serverFields = parseServerFields(failure.fields);

        if (code === 'revision_conflict') {
            showSaveStatus(
                'error',
                stringValue(
                    failure.message,
                    t(
                        'conflict',
                        'The settings changed after this page was loaded. Load the latest settings before saving again.'
                    )
                ),
                true
            );
            return;
        }

        if (Object.keys(serverFields).length > 0) {
            showValidationErrors(serverFields);
            return;
        }

        showSaveStatus(
            'error',
            stringValue(
                failure.message,
                t('saveFailed', 'Failed to save settings. Check the fields and try again.')
            ),
            false
        );
    }

    function saveSettings(event) {
        event.preventDefault();

        if (saving || !dirty) {
            return;
        }

        clearAllErrors();
        hideSaveStatus();

        const errors = validateDraft();
        if (Object.keys(errors).length > 0) {
            showValidationErrors(errors);
            return;
        }

        const payload = normalizePayload();
        setSaving(true);
        showSaveStatus('progress', t('saving', 'Saving settings...'), false);

        setSettings(revision, payload.settings, payload.services)
            .then(function(response) {
                setSaving(false);
                if (!isObject(response) || response.ok !== true) {
                    handleSetFailure(response);
                    return;
                }

                applySnapshot(response);
                showSaveStatus(
                    'success',
                    t('saved', 'Settings saved successfully.'),
                    false
                );
            })
            .catch(function() {
                setSaving(false);
                console.error('Failed to save Oasis settings.');
                showSaveStatus(
                    'error',
                    t('saveFailed', 'Failed to save settings. Check the fields and try again.'),
                    false
                );
            });
    }

    function showLoadError(error) {
        console.error('Failed to load Oasis settings:', error);
        errorMessage.textContent = t(
            'loadFailed',
            'Failed to load settings. Check the settings API and try again.'
        );
        setInitialState('error');
    }

    function loadSettings() {
        setInitialState('loading');
        return getSettings()
            .then(function(response) {
                applySnapshot(response);
                setInitialState('ready');
            })
            .catch(showLoadError);
    }

    function resetSettings() {
        if (!snapshot || saving) {
            return;
        }

        draft = deepClone(snapshot);
        renderGeneralSettings();
        renderServices();
        clearAllErrors();
        hideSaveStatus();
        setDirty(false);
    }

    function reloadLatest() {
        if (saving) {
            return;
        }
        if (dirty && !window.confirm(t(
            'unsavedConfirm',
            'Discard unsaved changes and load the latest settings?'
        ))) {
            return;
        }

        setDirty(false);
        loadSettings();
    }

    function initialize() {
        if (!root || !loading || !errorPanel || !form ||
            !generalContainer || !servicesContainer || !servicesEmpty ||
            !serviceCount || !retryButton || !errorMessage ||
            !addServiceButton || !resetButton || !saveButton ||
            !saveStatus || !saveStatusMessage || !reloadButton) {
            return;
        }

        retryButton.addEventListener('click', function() {
            loadSettings();
        });
        reloadButton.addEventListener('click', reloadLatest);
        resetButton.addEventListener('click', resetSettings);
        addServiceButton.addEventListener('click', function() {
            if (draft.services.length >= MAX_SERVICES) {
                return;
            }

            draft.services.push(newService());
            setDirty(true);
            hideSaveStatus();
            renderServices();

            const index = draft.services.length - 1;
            const providerControl = controlForPath(fieldPath('services', index, 'name'));
            if (providerControl) {
                providerControl.focus();
            }
        });
        form.addEventListener('submit', saveSettings);
        window.addEventListener('beforeunload', function(event) {
            if (!dirty) {
                return;
            }
            event.preventDefault();
            event.returnValue = '';
        });

        if (!LOAD_SETTINGS_URL || !UPDATE_SETTINGS_URL || !CSRF_TOKEN) {
            showLoadError(new Error('The Oasis settings API configuration is unavailable.'));
            return;
        }

        loadSettings().catch(function() {
            // loadSettings() already rendered the error state.
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initialize, { once: true });
    } else {
        initialize();
    }
})();
