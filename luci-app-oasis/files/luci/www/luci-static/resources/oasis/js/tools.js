(function() {
  'use strict';

  const config = window.OasisToolsConfig || {};
  const urls = config.urls || {};

  function getUrl(key) {
    const value = urls[key];
    if (!value) {
      console.warn('OasisToolsConfig missing URL for ' + key);
    }
    return value || '';
  }

  const API_ENABLE = getUrl('enableTool');
  const API_DISABLE = getUrl('disableTool');
  const URL_REFRESH_TOOLS = getUrl('refreshTools');
  const URL_LOAD_TOOLS = getUrl('loadTools');

  const container = document.getElementById('oasis-tool-container');
  const toastEl = document.getElementById('tools-toast');
  const headBar = document.getElementById('tools-head');
  const refreshBtn = document.getElementById('tools-refresh');
  const errorModal = document.getElementById('tools-error-modal');
  const errorMsgEl = document.getElementById('tools-error-message');
  const errorOkBtn = document.getElementById('tools-error-ok');

  function showToast(message, type = 'info', timeout = 2000) {
    if (!toastEl) return;
    toastEl.textContent = message;
    toastEl.className = `toast show ${type}`;
    setTimeout(() => { toastEl.className = 'toast'; toastEl.textContent = ''; }, timeout);
  }

  function showErrorModal(message) {
    if (errorMsgEl) errorMsgEl.textContent = message || 'An error occurred.';
    if (errorModal) {
      errorModal.classList.add('show');
      errorModal.setAttribute('aria-hidden', 'false');
    }
  }
  if (errorOkBtn) {
    errorOkBtn.addEventListener('click', function() {
      errorModal.classList.remove('show');
      errorModal.setAttribute('aria-hidden', 'true');
    });
  }

  function bindRefreshButton() {
    if (!refreshBtn || refreshBtn.dataset.bound === '1') return;
    refreshBtn.addEventListener('click', () => {
      refreshBtn.disabled = true;
      refreshBtn.textContent = 'Running...';
      fetch(URL_REFRESH_TOOLS, { method: 'POST' })
        .then(r => r.json())
        .then(res => {
          if (!res || res.status !== 'OK') throw new Error('Failed to refresh services');
          location.reload();
        })
        .catch(err => {
          console.error('refresh-tools failed:', err);
          showToast('Failed to refresh services', 'error', 3000);
          refreshBtn.disabled = false;
          refreshBtn.textContent = 'Refresh';
        });
    });
    refreshBtn.dataset.bound = '1';
  }

  function createServerBlock(serverName, tools) {
    const block = document.createElement('div');
    block.className = 'server-block';

    const headerWrap = document.createElement('div');
    headerWrap.className = 'server-header';
    const header = document.createElement('h3');
    header.textContent = serverName;
    headerWrap.appendChild(header);
    block.appendChild(headerWrap);

    const list = document.createElement('div');
    list.className = 'list';

    tools.forEach(tool => {
      list.appendChild(createCard(tool));
    });

    block.appendChild(list);
    return block;
  }

  function createCard(tool) {
    const cell = document.createElement('div');
    cell.className = 'cell';

    const title = document.createElement('div');
    title.className = 'cell-title';
    const titleText = document.createElement('span');
    titleText.textContent = tool.name || 'Unknown';
    const status = document.createElement('span');
    status.className = 'status-pill' + ((tool.enable === '1') ? ' enabled' : '');
    status.textContent = (tool.enable === '1') ? 'Enabled' : 'Disabled';
    title.appendChild(titleText);
    // script badge (lua -> blue, ucode -> purple)
    if (tool.script === 'lua' || tool.script === 'ucode') {
      const script = document.createElement('span');
      script.className = 'pill-script ' + (tool.script === 'lua' ? 'script-lua' : 'script-ucode');
      script.textContent = (tool.script === 'ucode') ? 'ucode' : tool.script;
      title.appendChild(script);
    }
    // Show conflict badge when conflict === '1'
    const isConflict = (tool.conflict === '1');
    if (isConflict) {
      const conflict = document.createElement('span');
      conflict.className = 'pill-conflict';
      conflict.textContent = 'conflict';
      title.appendChild(conflict);
    }
    // enable/disable status at the end
    title.appendChild(status);

    const desc = document.createElement('div');
    desc.className = 'cell-description';
    desc.textContent = tool.description || 'No description.';

    const footer = document.createElement('div');
    footer.className = 'cell-footer';

    const btn = document.createElement('button');
    let isEnabled = tool.enable === '1';
    btn.className = isEnabled ? 'delete-button' : 'load-button';
    btn.textContent = isEnabled ? 'Disable' : 'Enable';
    if (isConflict) {
      btn.disabled = true;
      btn.title = 'Conflict: cannot change state';
    }

    btn.addEventListener('click', () => {
      if (isConflict) return;
      if (!tool.name) { showToast('Missing tool name', 'error'); return; }
      const enabling = !isEnabled; // current button action
      const url = enabling ? API_ENABLE : API_DISABLE;
      const prevText = btn.textContent;
      btn.disabled = true;
      btn.textContent = 'Loading...';
      fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ name: tool.name, server: tool.server || '' })
      })
      .then(r => r.json())
      .then(data => {
        if (!data || data.status !== 'OK') throw new Error((data && data.error) || 'Unexpected response');
        // apply UI only on success
        isEnabled = enabling;
        btn.textContent = isEnabled ? 'Disable' : 'Enable';
        btn.className = isEnabled ? 'delete-button' : 'load-button';
        status.textContent = isEnabled ? 'Enabled' : 'Disabled';
        status.className = 'status-pill' + (isEnabled ? ' enabled' : '');
      })
      .catch(err => {
        console.error('toggle failed:', err);
        showErrorModal(err && err.message ? err.message : 'Failed to update tool state');
        btn.textContent = prevText;
      })
      .finally(() => { btn.disabled = false; });
    });

    footer.appendChild(btn);
    cell.appendChild(title);
    cell.appendChild(desc);
    cell.appendChild(footer);

    return cell;
  }

  function loadTools() {
    fetch(URL_LOAD_TOOLS)
      .then(response => response.json())
      .then(data => {
        if (data && data.local_tool === false) {
          if (headBar) headBar.style.display = 'none';
          if (container) {
            container.innerHTML = '';
            const p = document.createElement('p');
            p.textContent = "Please install the extension module 'oasis-mod-tool' to enable local tools.";
            container.appendChild(p);
          }
          return;
        }
        // local_tool is enabled: show static Refresh button and bind handler
        if (headBar) headBar.style.display = '';
        bindRefreshButton();
        const tools = data.tools || {};
        const serverMap = {};

        Object.values(tools).forEach(tool => {
          if (tool[".type"] === "tool" && tool.type === "function") {
            const server = tool.server || 'Unknown Server';
            if (!serverMap[server]) serverMap[server] = [];
            serverMap[server].push(tool);
          }
        });

        Object.entries(serverMap).forEach(([server, serverTools]) => {
          const block = createServerBlock(server, serverTools);
          container.appendChild(block);
        });
      })
      .catch(err => {
        console.error('Failed to load server info:', err);
      });
  }

  loadTools();
})();
