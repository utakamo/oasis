(function() {
  'use strict';

  const config = window.OasisToolMakerConfig || {};
  const urls = config.urls || {};
  const strings = config.strings || {};

  function t(key, fallback) {
    const value = strings[key];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
    return fallback;
  }

  function formatText(template, params) {
    let out = String(template || '');
    const table = params || {};

    Object.keys(table).forEach(key => {
      const value = (table[key] === null || table[key] === undefined) ? '' : String(table[key]);
      out = out.split('{' + key + '}').join(value);
    });

    return out;
  }

  const typeSelect = document.getElementById('tm-template');
  const nameInput = document.getElementById('tm-name');
  const toolNameInput = document.getElementById('tm-tool-name');
  const toolDescInput = document.getElementById('tm-tool-desc');
  const toolListEl = document.getElementById('tm-tool-list');
  const addToolBtn = document.getElementById('tm-add-tool');
  const argRowsEl = document.getElementById('tm-arg-rows');
  const addArgBtn = document.getElementById('tm-add-arg');
  const bodyEl = document.getElementById('tm-body');
  const outputEl = document.getElementById('tm-output');
  const resultEl = document.getElementById('tm-result');
  const toastEl = document.getElementById('tool-maker-toast');

  const btnGenerate = document.getElementById('tm-generate');
  const btnValidate = document.getElementById('tm-validate');
  const btnSave = document.getElementById('tm-save');

  let currentType = (typeSelect && typeSelect.value) ? typeSelect.value : 'lua';
  let activeToolId = null;
  const tools = [];
  let hasFreshOutput = false;
  let isValidateBusy = false;
  const backendErrorMap = {
    'invalid tools': t('backendInvalidTools', 'invalid tools'),
    'failed to render': t('backendFailedToRender', 'failed to render'),
    'invalid body': t('backendInvalidBody', 'invalid body'),
    'empty tools': t('backendEmptyTools', 'empty tools'),
    'missing tool description': t('backendMissingToolDescription', 'missing tool description'),
    'missing tool name': t('backendMissingToolName', 'missing tool name'),
    'missing call body': t('backendMissingCallBody', 'missing call body'),
    'invalid args': t('backendInvalidArgs', 'invalid args'),
    'args and args_desc mismatch': t('backendArgsDescMismatch', 'args and args_desc mismatch'),
    'invalid arg': t('backendInvalidArg', 'invalid arg'),
    'invalid template type': t('backendInvalidTemplateType', 'invalid template type'),
    'template not found': t('backendTemplateNotFound', 'template not found'),
    'lua loader not available': t('backendLuaLoaderNotAvailable', 'lua loader not available'),
    'ucode syntax error': t('backendUcodeSyntaxError', 'ucode syntax error'),
    'failed to write temp file': t('backendFailedToWriteTempFile', 'failed to write temp file'),
    'invalid tool type': t('backendInvalidToolType', 'invalid tool type'),
    'missing name': t('backendMissingName', 'missing name'),
    'invalid name': t('backendInvalidName', 'invalid name'),
    'empty content': t('backendEmptyContent', 'empty content'),
    'already exists': t('backendAlreadyExists', 'already exists'),
    'failed to write file': t('backendFailedToWriteFile', 'failed to write file'),
    'failed to chmod': t('backendFailedToChmod', 'failed to chmod'),
    'failed to set executable permission': t('backendFailedToSetExecutablePermission', 'failed to set executable permission'),
    'marker begin not found': t('backendMarkerBeginNotFound', 'marker begin not found'),
    'marker begin line not found': t('backendMarkerBeginLineNotFound', 'marker begin line not found'),
    'marker end not found': t('backendMarkerEndNotFound', 'marker end not found'),
    'marker end line not found': t('backendMarkerEndLineNotFound', 'marker end line not found')
  };

  function syncValidateButtonState() {
    if (!btnValidate) return;
    btnValidate.disabled = !hasFreshOutput || isValidateBusy;
  }

  function markOutputStale() {
    hasFreshOutput = false;
    syncValidateButtonState();
  }

  function markOutputFresh() {
    hasFreshOutput = true;
    syncValidateButtonState();
  }

  function setValidateBusy(busy) {
    isValidateBusy = !!busy;
    syncValidateButtonState();
  }

  function localizeBackendError(message) {
    if (typeof message !== 'string' || !message) {
      return message;
    }
    return backendErrorMap[message] || message;
  }

  function showToast(message, type, timeout) {
    if (!toastEl) return;
    toastEl.textContent = message;
    toastEl.className = 'tm-toast show ' + (type || 'info');
    setTimeout(() => { toastEl.className = 'tm-toast'; toastEl.textContent = ''; }, timeout || 2000);
  }

  function setResult(text) {
    if (resultEl) resultEl.textContent = text || '';
  }

  function getErrorMessage(err, fallback) {
    if (typeof err === 'string' && err) return localizeBackendError(err);
    if (err && typeof err.message === 'string' && err.message) return localizeBackendError(err.message);
    return localizeBackendError(fallback || t('unknownError', 'unknown error'));
  }

  function postForm(url, data) {
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(data)
    }).then(r => r.json());
  }

  function escapeToolName(name) {
    return String(name || '').replace(/[^\w._@:+=-]/g, '');
  }

  function escapeArgName(name) {
    return String(name || '').replace(/[^\w_]/g, '');
  }

  function defaultToolDef(toolType) {
    const toolDesc = t('defaultToolDescription', 'Get current temperature for a given location.');
    const argDesc = t('defaultArgDescription', 'City and country e.g. Bogotá, Colombia');

    if (toolType === 'ucode') {
      return {
        tool_desc: toolDesc,
        args: [
          { name: 'location', type: 'a_string', desc: argDesc }
        ],
        call_body: [
          'return {',
          '  location: request.args.location,',
          '  temperature: "25°C",',
          '  condition: "Sunny"',
          '};'
        ].join('\n')
      };
    }

    return {
      tool_desc: toolDesc,
      args: [
        { name: 'location', type: 'a_string', desc: argDesc }
      ],
      call_body: [
        'local res = server.response({ location = args.location, temperature = "25°C", condition = "Sunny" })',
        'return res'
      ].join('\n')
    };
  }

  function renderToolList() {
    if (!toolListEl) return;
    toolListEl.innerHTML = '';
    tools.forEach(tool => {
      const row = document.createElement('div');
      row.className = 'tm-tool-row' + (tool.id === activeToolId ? ' active' : '');

      const nameBtn = document.createElement('button');
      nameBtn.type = 'button';
      nameBtn.className = 'tm-tool-name';
      nameBtn.textContent = tool.name || t('unnamedLabel', 'unnamed');
      nameBtn.addEventListener('click', () => {
        switchTool(tool.id);
      });

      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'tm-tool-del';
      delBtn.textContent = '×';
      delBtn.addEventListener('click', () => {
        removeTool(tool.id);
      });

      row.appendChild(nameBtn);
      row.appendChild(delBtn);
      toolListEl.appendChild(row);
    });
  }

  function renderArgRows(tool) {
    if (!argRowsEl || !tool) return;
    argRowsEl.innerHTML = '';
    tool.args.forEach((arg, idx) => {
      const row = document.createElement('div');
      row.className = 'tm-arg-row';

      const nameInput = document.createElement('input');
      nameInput.type = 'text';
      nameInput.value = arg.name || '';
      nameInput.addEventListener('input', () => {
        arg.name = escapeArgName(nameInput.value);
        markOutputStale();
      });

      const typeInput = document.createElement('input');
      typeInput.type = 'text';
      typeInput.value = arg.type || '';
      typeInput.addEventListener('input', () => {
        arg.type = typeInput.value.trim();
        markOutputStale();
      });

      const descInput = document.createElement('input');
      descInput.type = 'text';
      descInput.value = arg.desc || '';
      descInput.addEventListener('input', () => {
        arg.desc = descInput.value;
        markOutputStale();
      });

      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'tm-tool-del';
      delBtn.textContent = '×';
      delBtn.addEventListener('click', () => {
        tool.args.splice(idx, 1);
        markOutputStale();
        renderArgRows(tool);
      });

      row.appendChild(nameInput);
      row.appendChild(typeInput);
      row.appendChild(descInput);
      row.appendChild(delBtn);
      argRowsEl.appendChild(row);
    });
  }

  function switchTool(id) {
    const tool = tools.find(t => t.id === id);
    if (!tool) return;
    activeToolId = id;
    if (toolNameInput) toolNameInput.value = tool.name;
    if (toolDescInput) toolDescInput.value = tool.tool_desc || '';
    if (bodyEl) bodyEl.value = tool.call_body || '';
    renderArgRows(tool);
    renderToolList();
  }

  function addTool(name) {
    const toolName = escapeToolName(name || 'get_weather');
    const id = 'tool_' + Date.now() + '_' + Math.floor(Math.random() * 1000);
    const def = defaultToolDef(currentType);
    const tool = {
      id,
      name: toolName,
      tool_desc: def.tool_desc,
      args: def.args,
      call_body: def.call_body
    };
    tools.push(tool);
    markOutputStale();
    switchTool(id);
  }

  function removeTool(id) {
    const idx = tools.findIndex(t => t.id === id);
    if (idx === -1) return;
    tools.splice(idx, 1);
    markOutputStale();
    if (activeToolId === id) {
      activeToolId = tools.length ? tools[0].id : null;
      if (activeToolId) {
        switchTool(activeToolId);
      } else {
        if (toolNameInput) toolNameInput.value = '';
        if (toolDescInput) toolDescInput.value = '';
        if (bodyEl) bodyEl.value = '';
        if (argRowsEl) argRowsEl.innerHTML = '';
      }
    }
    renderToolList();
  }

  function updateActiveTool() {
    const tool = tools.find(t => t.id === activeToolId);
    if (!tool) return;
    tool.name = escapeToolName(toolNameInput ? toolNameInput.value : tool.name);
    tool.tool_desc = toolDescInput ? toolDescInput.value : tool.tool_desc;
    tool.call_body = bodyEl ? bodyEl.value : tool.call_body;
    renderToolList();
  }

  function toolsPayload() {
    return JSON.stringify(tools.map(t => ({
      name: t.name,
      tool_desc: t.tool_desc,
      args: (t.args || []).map(a => ({ name: a.name, type: a.type })),
      args_desc: (t.args || []).map(a => a.desc || ''),
      call_body: t.call_body || ''
    })));
  }

  function requireToolDescriptions() {
    for (const tool of tools) {
      if (!tool.tool_desc || tool.tool_desc.trim() === '') {
        return false;
      }
    }
    return true;
  }

  function generateOutput(opts) {
    const options = opts || {};
    const rethrowOnError = !!options.rethrowOnError;

    updateActiveTool();
    setResult('');
    markOutputStale();
    btnGenerate.disabled = true;

    return postForm(urls.render, { type: currentType, name: nameInput.value || '', tools: toolsPayload() })
      .then(data => {
        if (!data || data.status !== 'OK') {
          throw new Error((data && data.error) || t('renderFailed', 'Render failed'));
        }
        outputEl.value = data.content || '';
        markOutputFresh();
        showToast(t('generated', 'Generated'), 'success');
        return data.content || '';
      })
      .catch(err => {
        const msg = getErrorMessage(err, t('renderFailed', 'Render failed'));
        const failMsg = formatText(t('renderFailedWithReason', 'Render failed: {error}'), { error: msg });
        console.error(t('renderFailed', 'Render failed'), err);

        if (rethrowOnError) {
          throw new Error(msg);
        }

        setResult(failMsg);
        showToast(failMsg, 'error', 4000);
        return '';
      })
      .finally(() => { btnGenerate.disabled = false; });
  }

  function onValidate() {
    updateActiveTool();
    if (!requireToolDescriptions()) {
      showToast(t('missingToolDescription', 'Missing tool description'), 'error', 3000);
      return;
    }
    setValidateBusy(true);
    setResult('');

    postForm(urls.validate, { type: currentType, name: nameInput.value || '', tools: toolsPayload() })
      .then(data => {
        if (!data) throw new Error(t('noResponse', 'No response'));
        if (data.status === 'OK') {
          const okText = t('validationOk', 'Validation OK');
          setResult(okText);
          showToast(okText, 'success');
        } else {
          const errors = (data.errors || []).map(localizeBackendError).join(', ');
          const text = formatText(
            t('validationNgWithReason', 'Validation NG: {error}'),
            { error: errors || t('unknownError', 'unknown error') }
          );
          setResult(text);
          showToast(t('validationNg', 'Validation NG'), 'error', 3000);
        }
      })
      .catch(err => {
        console.error(t('validateFailed', 'Validate failed'), err);
        showToast(t('validateFailed', 'Validate failed'), 'error', 3000);
      })
      .finally(() => { setValidateBusy(false); });
  }

  function onSave() {
    const name = (nameInput && nameInput.value) ? nameInput.value : '';
    if (!name) {
      showToast(t('missingToolName', 'Missing tool name'), 'error', 3000);
      return;
    }

    updateActiveTool();
    if (!tools.length) {
      showToast(t('missingToolDefinition', 'Missing tool definition'), 'error', 3000);
      return;
    }
    if (!requireToolDescriptions()) {
      showToast(t('missingToolDescription', 'Missing tool description'), 'error', 3000);
      return;
    }

    btnSave.disabled = true;
    setResult('');

    generateOutput({ rethrowOnError: true })
      .then(content => {
        if (!content) throw new Error(t('noContent', 'No content'));
        return postForm(urls.save, { type: currentType, name, tools: toolsPayload() });
      })
      .then(data => {
        if (!data || data.status !== 'OK') {
          throw new Error((data && data.error) || t('saveFailed', 'Save failed'));
        }
        const savedText = formatText(
          t('savedSummary', 'Saved: {path} ({bytes} bytes)'),
          { path: data.path || '', bytes: data.bytes || 0 }
        );
        setResult(savedText);
        showToast(t('saved', 'Saved'), 'success');
        if (urls.refreshTools) {
          fetch(urls.refreshTools, { method: 'POST' })
            .then(r => r.json())
            .then(res => {
              if (!res || res.status !== 'OK') {
                throw new Error(t('refreshFailed', 'Refresh failed'));
              }
            })
            .catch(err => {
              console.error(t('refreshFailed', 'Refresh failed'), err);
              showToast(t('refreshFailed', 'Refresh failed'), 'error', 3000);
            });
        }
      })
      .catch(err => {
        const msg = getErrorMessage(err, t('saveFailed', 'Save failed'));
        const failText = formatText(t('saveFailedWithReason', 'Save failed: {error}'), { error: msg });
        console.error(t('saveFailed', 'Save failed'), err);
        setResult(failText);
        showToast(failText, 'error', 4000);
      })
      .finally(() => { btnSave.disabled = false; });
  }

  if (typeSelect) {
    typeSelect.addEventListener('change', () => {
      currentType = typeSelect.value || currentType;
      markOutputStale();
    });
  }
  if (nameInput) {
    nameInput.addEventListener('input', () => {
      markOutputStale();
    });
  }
  if (addToolBtn) {
    addToolBtn.addEventListener('click', () => addTool('get_weather'));
  }
  if (addArgBtn) {
    addArgBtn.addEventListener('click', () => {
      const tool = tools.find(t => t.id === activeToolId);
      if (!tool) return;
      tool.args.push({ name: '', type: 'a_string', desc: '' });
      markOutputStale();
      renderArgRows(tool);
    });
  }
  if (toolNameInput) {
    toolNameInput.addEventListener('input', () => {
      markOutputStale();
      updateActiveTool();
    });
  }
  if (toolDescInput) {
    toolDescInput.addEventListener('input', () => {
      markOutputStale();
      updateActiveTool();
    });
  }
  if (bodyEl) {
    bodyEl.addEventListener('input', () => {
      markOutputStale();
      updateActiveTool();
    });
  }
  if (btnGenerate) btnGenerate.addEventListener('click', generateOutput);
  if (btnValidate) btnValidate.addEventListener('click', onValidate);
  if (btnSave) btnSave.addEventListener('click', onSave);

  if (typeSelect && typeSelect.value) {
    currentType = typeSelect.value;
  }
  markOutputStale();
  addTool('get_weather');
})();
