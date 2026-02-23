(function() {
  'use strict';

  const config = window.OasisToolMakerConfig || {};
  const urls = config.urls || {};

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
    if (typeof err === 'string' && err) return err;
    if (err && typeof err.message === 'string' && err.message) return err.message;
    return fallback || 'unknown error';
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
    if (toolType === 'ucode') {
      return {
        tool_desc: 'Get current temperature for a given location.',
        args: [
          { name: 'location', type: 'a_string', desc: 'City and country e.g. Bogotá, Colombia' }
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
      tool_desc: 'Get current temperature for a given location.',
      args: [
        { name: 'location', type: 'a_string', desc: 'City and country e.g. Bogotá, Colombia' }
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
      nameBtn.textContent = tool.name || 'unnamed';
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
      });

      const typeInput = document.createElement('input');
      typeInput.type = 'text';
      typeInput.value = arg.type || '';
      typeInput.addEventListener('input', () => {
        arg.type = typeInput.value.trim();
      });

      const descInput = document.createElement('input');
      descInput.type = 'text';
      descInput.value = arg.desc || '';
      descInput.addEventListener('input', () => {
        arg.desc = descInput.value;
      });

      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'tm-tool-del';
      delBtn.textContent = '×';
      delBtn.addEventListener('click', () => {
        tool.args.splice(idx, 1);
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
    switchTool(id);
  }

  function removeTool(id) {
    const idx = tools.findIndex(t => t.id === id);
    if (idx === -1) return;
    tools.splice(idx, 1);
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
    btnGenerate.disabled = true;

    return postForm(urls.render, { type: currentType, name: nameInput.value || '', tools: toolsPayload() })
      .then(data => {
        if (!data || data.status !== 'OK') {
          throw new Error((data && data.error) || 'Render failed');
        }
        outputEl.value = data.content || '';
        showToast('Generated', 'success');
        return data.content || '';
      })
      .catch(err => {
        const msg = getErrorMessage(err, 'Render failed');
        console.error('Render failed', err);

        if (rethrowOnError) {
          throw err;
        }

        setResult('Render failed: ' + msg);
        showToast('Render failed: ' + msg, 'error', 4000);
        return '';
      })
      .finally(() => { btnGenerate.disabled = false; });
  }

  function onValidate() {
    updateActiveTool();
    if (!requireToolDescriptions()) {
      showToast('Missing tool description', 'error', 3000);
      return;
    }
    btnValidate.disabled = true;
    setResult('');

    postForm(urls.validate, { type: currentType, name: nameInput.value || '', tools: toolsPayload() })
      .then(data => {
        if (!data) throw new Error('No response');
        if (data.status === 'OK') {
          setResult('Validation OK');
          showToast('Validation OK', 'success');
        } else {
          const errors = (data.errors || []).join(', ');
          setResult('Validation NG: ' + (errors || 'unknown error'));
          showToast('Validation NG', 'error', 3000);
        }
      })
      .catch(err => {
        console.error('Validate failed', err);
        showToast('Validate failed', 'error', 3000);
      })
      .finally(() => { btnValidate.disabled = false; });
  }

  function onSave() {
    const name = (nameInput && nameInput.value) ? nameInput.value : '';
    if (!name) {
      showToast('Missing tool name', 'error', 3000);
      return;
    }

    updateActiveTool();
    if (!tools.length) {
      showToast('Missing tool definition', 'error', 3000);
      return;
    }
    if (!requireToolDescriptions()) {
      showToast('Missing tool description', 'error', 3000);
      return;
    }

    btnSave.disabled = true;
    setResult('');

    generateOutput({ rethrowOnError: true })
      .then(content => {
        if (!content) throw new Error('No content');
        return postForm(urls.save, { type: currentType, name, tools: toolsPayload() });
      })
      .then(data => {
        if (!data || data.status !== 'OK') {
          throw new Error((data && data.error) || 'Save failed');
        }
        setResult('Saved: ' + data.path + ' (' + data.bytes + ' bytes)');
        showToast('Saved', 'success');
        if (urls.refreshTools) {
          fetch(urls.refreshTools, { method: 'POST' })
            .then(r => r.json())
            .then(res => {
              if (!res || res.status !== 'OK') {
                throw new Error('Refresh failed');
              }
            })
            .catch(err => {
              console.error('Refresh failed', err);
              showToast('Refresh failed', 'error', 3000);
            });
        }
      })
      .catch(err => {
        const msg = getErrorMessage(err, 'Save failed');
        console.error('Save failed', err);
        setResult('Save failed: ' + msg);
        showToast('Save failed: ' + msg, 'error', 4000);
      })
      .finally(() => { btnSave.disabled = false; });
  }

  if (typeSelect) {
    typeSelect.addEventListener('change', () => {
      currentType = typeSelect.value || currentType;
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
      renderArgRows(tool);
    });
  }
  if (toolNameInput) {
    toolNameInput.addEventListener('input', updateActiveTool);
  }
  if (toolDescInput) {
    toolDescInput.addEventListener('input', updateActiveTool);
  }
  if (bodyEl) {
    bodyEl.addEventListener('input', updateActiveTool);
  }
  if (btnGenerate) btnGenerate.addEventListener('click', generateOutput);
  if (btnValidate) btnValidate.addEventListener('click', onValidate);
  if (btnSave) btnSave.addEventListener('click', onSave);

  if (typeSelect && typeSelect.value) {
    currentType = typeSelect.value;
  }
  addTool('get_weather');
})();
