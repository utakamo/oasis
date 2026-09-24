(function() {
  'use strict';

  const config = window.OasisToolsConfig || {};
  const urls = config.urls || {};
  const STR = window.OasisToolsStrings || {};
  const t = (key, fallback) => (Object.prototype.hasOwnProperty.call(STR, key) ? STR[key] : fallback);

  function getUrl(key) {
    const value = urls[key];
    if (!value) {
      console.warn('OasisToolsConfig missing URL for ' + key);
    }
    return value || '';
  }

  const API_ENABLE = getUrl('enableTool');
  const API_DISABLE = getUrl('disableTool');
  const API_AUTO = getUrl('setToolAuto');
  const URL_REFRESH_TOOLS = getUrl('refreshTools');
  const URL_LOAD_TOOLS = getUrl('loadTools');
  const URL_LOAD_MANIFEST = getUrl('loadManifest');
  const TOOL_SEARCH_SERVER = 'oasis.tool.manager';
  const TOOL_SEARCH_TOOL_ORDER = {
    get_tool_list: 0,
    set_tool_enabled: 1,
    set_tool_disabled: 2
  };

  const container = document.getElementById('oasis-tool-container');
  const toastEl = document.getElementById('tools-toast');
  const headBar = document.getElementById('tools-head');
  const refreshBtn = document.getElementById('tools-refresh');
  const errorModal = document.getElementById('tools-error-modal');
  const errorMsgEl = document.getElementById('tools-error-message');
  const errorOkBtn = document.getElementById('tools-error-ok');
  const confirmModal = document.getElementById('tools-confirm-modal');
  const confirmMessageEl = document.getElementById('tools-confirm-message');
  const confirmListEl = document.getElementById('tools-confirm-list');
  const confirmApplyBtn = document.getElementById('tools-confirm-apply');
  const confirmCancelBtn = document.getElementById('tools-confirm-cancel');
  let pendingManifests = [];
  let autoMode = false;
  let changingState = false;
  let stateKnown = false;
  let pendingSwitchKey = null;
  let switches = [];
  let loadGeneration = 0;

  function showToast(message, type = 'info', timeout = 2000) {
    if (!toastEl) return;
    toastEl.textContent = message;
    toastEl.className = `toast show ${type}`;
    setTimeout(() => { toastEl.className = 'toast'; toastEl.textContent = ''; }, timeout);
  }

  function showErrorModal(message) {
    if (errorMsgEl) errorMsgEl.textContent = message || t('errorDefault', 'An error occurred.');
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

  function closeConfirmModal() {
    if (!confirmModal) return;
    confirmModal.classList.remove('show');
    confirmModal.setAttribute('aria-hidden', 'true');
  }

  function renderConfirmList(manifests) {
    if (!confirmListEl) return;
    confirmListEl.innerHTML = '';

    (manifests || []).forEach(manifest => {
      const item = document.createElement('div');
      item.className = 'tools-confirm-item';

      const path = document.createElement('div');
      path.className = 'tools-confirm-path';
      path.textContent = `${t('confirmPathLabel', 'Manifest Path')}: ${manifest.path || ''}`;
      item.appendChild(path);

      const meta = document.createElement('div');
      meta.className = 'tools-confirm-meta';
      meta.textContent = [
        `${t('confirmSourceTypeLabel', 'Source Type')}: ${manifest.source_type || '-'}`,
        `${t('confirmSourcePathLabel', 'Source Path')}: ${manifest.source_path || t('confirmNoSourcePath', 'None')}`,
        `${t('confirmToolCountLabel', 'Tool Count')}: ${manifest.tool_count || 0}`
      ].join('  |  ');
      item.appendChild(meta);

      const servers = document.createElement('div');
      servers.className = 'tools-confirm-servers';
      servers.textContent = `${t('confirmServersLabel', 'Servers')}: ${(manifest.servers || []).join(', ') || '-'}`;
      item.appendChild(servers);

      const tools = document.createElement('div');
      tools.className = 'tools-confirm-tools';
      tools.textContent = `${t('confirmToolsLabel', 'Tools')}: ${(manifest.tools || []).join(', ') || '-'}`;
      item.appendChild(tools);

      confirmListEl.appendChild(item);
    });
  }

  function openConfirmModal(manifests) {
    pendingManifests = Array.isArray(manifests) ? manifests : [];
    if (confirmMessageEl) {
      confirmMessageEl.textContent = t(
        'confirmRequiredMessage',
        'The following AI tool manifests are not yet applied. Applying them will register their tools in Oasis.'
      );
    }
    renderConfirmList(pendingManifests);
    if (confirmApplyBtn) {
      confirmApplyBtn.disabled = false;
      confirmApplyBtn.textContent = t('confirmApplyButton', 'Apply');
    }
    if (confirmCancelBtn) {
      confirmCancelBtn.disabled = false;
      confirmCancelBtn.textContent = t('confirmCancelButton', 'Cancel');
    }
    if (confirmModal) {
      confirmModal.classList.add('show');
      confirmModal.setAttribute('aria-hidden', 'false');
    }
  }

  function postRefresh(confirm) {
    const body = new URLSearchParams();
    if (confirm) {
      body.set('confirm', '1');
    }

    return fetch(URL_REFRESH_TOOLS, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
      body: body.toString()
    }).then(r => r.json());
  }

  function bindRefreshButton() {
    if (!refreshBtn || refreshBtn.dataset.bound === '1') return;
    refreshBtn.addEventListener('click', () => {
      refreshBtn.disabled = true;
      refreshBtn.textContent = t('running', 'Running...');
      postRefresh(false)
        .then(res => {
          if (res && res.status === 'CONFIRM_REQUIRED') {
            refreshBtn.disabled = false;
            refreshBtn.textContent = t('refreshLabel', 'Refresh');
            openConfirmModal(res.manifests || []);
            return;
          }
          if (!res || res.status !== 'OK') {
            throw new Error((res && res.error) || t('refreshFailed', 'Failed to refresh services'));
          }
          location.reload();
        })
        .catch(err => {
          console.error('refresh-tools failed:', err);
          showToast((err && err.message) || t('refreshFailed', 'Failed to refresh services'), 'error', 3000);
          refreshBtn.disabled = false;
          refreshBtn.textContent = t('refreshLabel', 'Refresh');
        });
    });
    refreshBtn.dataset.bound = '1';
  }

  if (confirmCancelBtn) {
    confirmCancelBtn.addEventListener('click', () => {
      closeConfirmModal();
      if (refreshBtn) {
        refreshBtn.disabled = false;
        refreshBtn.textContent = t('refreshLabel', 'Refresh');
      }
    });
  }

  if (confirmApplyBtn) {
    confirmApplyBtn.addEventListener('click', () => {
      confirmApplyBtn.disabled = true;
      confirmCancelBtn.disabled = true;
      confirmApplyBtn.textContent = t('running', 'Running...');

      postRefresh(true)
        .then(res => {
          if (!res || res.status !== 'OK') {
            throw new Error((res && res.error) || t('refreshFailed', 'Failed to refresh services'));
          }
          closeConfirmModal();
          location.reload();
        })
        .catch(err => {
          console.error('refresh-tools confirm failed:', err);
          showToast((err && err.message) || t('refreshFailed', 'Failed to refresh services'), 'error', 3000);
          confirmApplyBtn.disabled = false;
          confirmCancelBtn.disabled = false;
          confirmApplyBtn.textContent = t('confirmApplyButton', 'Apply');
        });
    });
  }

  function createServerBlock(serverName, tools, options) {
    const opts = options || {};
    const serverKey = opts.serverKey || serverName;
    const block = document.createElement('div');
    block.className = 'server-block';
    if (opts.blockClassName) {
      block.classList.add(opts.blockClassName);
    }

    const headerWrap = document.createElement('div');
    headerWrap.className = 'server-header';
    if (opts.headerClassName) {
      headerWrap.classList.add(opts.headerClassName);
    }
    const header = document.createElement('h3');
    header.textContent = serverName;
    headerWrap.appendChild(header);
    if (opts.badgeLabel) {
      const badge = document.createElement('span');
      badge.className = 'server-badge';
      if (opts.badgeClassName) {
        badge.classList.add(opts.badgeClassName);
      }
      badge.textContent = opts.badgeLabel;
      headerWrap.appendChild(badge);
    }
    block.appendChild(headerWrap);

    if (opts.description) {
      const description = document.createElement('p');
      description.className = 'server-description';
      if (opts.descriptionClassName) {
        description.classList.add(opts.descriptionClassName);
      }
      description.textContent = opts.description;
      block.appendChild(description);
    }

    const actions = document.createElement('div');
    actions.className = 'server-actions';
    const manifestButton = document.createElement('button');
    manifestButton.type = 'button';
    manifestButton.className = 'manifest-button';
    manifestButton.textContent = t('manifestButton', 'Manifest');
    actions.appendChild(manifestButton);
    block.appendChild(actions);

    const manifestPanel = document.createElement('div');
    manifestPanel.className = 'manifest-panel';
    manifestPanel.hidden = true;
    block.appendChild(manifestPanel);

    const list = document.createElement('div');
    list.className = 'list';
    if (opts.listClassName) {
      list.classList.add(opts.listClassName);
    }

    tools.forEach(tool => {
      list.appendChild(createCard(tool, { cardClassName: opts.cardClassName }));
    });

    block.appendChild(list);

    let manifestLoaded = false;
    let manifestLoading = false;

    function renderManifestMessage(message, className) {
      manifestPanel.innerHTML = '';
      const text = document.createElement('p');
      text.className = className;
      text.textContent = message;
      manifestPanel.appendChild(text);
    }

    function renderManifestPanel(manifests) {
      manifestPanel.innerHTML = '';

      if (!Array.isArray(manifests) || manifests.length === 0) {
        renderManifestMessage(t('manifestNotFound', 'Manifest not found.'), 'manifest-empty');
        return;
      }

      manifests.forEach(manifest => {
        const entry = document.createElement('div');
        entry.className = 'manifest-entry';

        const path = document.createElement('div');
        path.className = 'manifest-path';
        path.textContent = manifest.path || '';
        entry.appendChild(path);

        const meta = document.createElement('div');
        meta.className = 'manifest-meta';
        const sourceType = manifest.source_type || manifest.script_type || '-';
        const sourcePath = manifest.source_path || manifest.script_path || '-';
        meta.textContent = [
          `${t('manifestSourceType', 'Source Type')}: ${sourceType}`,
          `${t('manifestSourcePath', 'Source Path')}: ${sourcePath}`
        ].join('  |  ');
        entry.appendChild(meta);

        const pre = document.createElement('pre');
        pre.className = 'manifest-content';
        pre.textContent = manifest.content || '';
        entry.appendChild(pre);

        manifestPanel.appendChild(entry);
      });
    }

    manifestButton.addEventListener('click', () => {
      if (!manifestPanel.hidden) {
        manifestPanel.hidden = true;
        manifestButton.textContent = t('manifestButton', 'Manifest');
        return;
      }

      manifestPanel.hidden = false;
      manifestButton.textContent = t('hideManifestButton', 'Hide Manifest');

      if (manifestLoaded || manifestLoading) {
        return;
      }

      manifestLoading = true;
      renderManifestMessage(t('loadingManifest', 'Loading manifest...'), 'manifest-loading');

      const query = new URLSearchParams({ server: serverKey });
      fetch(`${URL_LOAD_MANIFEST}?${query.toString()}`)
        .then(response => response.json())
        .then(data => {
          if (!data || data.status !== 'OK') {
            throw new Error((data && data.error) || t('manifestLoadFailed', 'Failed to load manifest.'));
          }
          renderManifestPanel(data.manifests);
          manifestLoaded = true;
        })
        .catch(err => {
          console.error('tool-manifest failed:', err);
          renderManifestMessage(
            err && err.message ? err.message : t('manifestLoadFailed', 'Failed to load manifest.'),
            'manifest-error'
          );
        })
        .finally(() => {
          manifestLoading = false;
        });
    });

    return block;
  }

  function compareText(a, b) {
    return String(a || '').localeCompare(String(b || ''));
  }

  function isToolSearchTool(tool) {
    return tool &&
      tool.server === TOOL_SEARCH_SERVER &&
      Object.prototype.hasOwnProperty.call(TOOL_SEARCH_TOOL_ORDER, tool.name || '');
  }

  function sortToolsForDisplay(tools, isSpecialGroup) {
    const list = Array.isArray(tools) ? tools.slice() : [];
    list.sort((a, b) => {
      if (isSpecialGroup) {
        const aOrder = TOOL_SEARCH_TOOL_ORDER[a.name] ?? Number.MAX_SAFE_INTEGER;
        const bOrder = TOOL_SEARCH_TOOL_ORDER[b.name] ?? Number.MAX_SAFE_INTEGER;
        if (aOrder !== bOrder) return aOrder - bOrder;
      }

      const byName = compareText(a.name, b.name);
      if (byName !== 0) return byName;

      const byScript = compareText(a.script, b.script);
      if (byScript !== 0) return byScript;

      return compareText(a.server, b.server);
    });
    return list;
  }

  function syncSwitches() {
    switches.forEach(control => {
      const busy = changingState && control.key === pendingSwitchKey;
      control.button.disabled = !control.available || changingState || !stateKnown;
      control.button.setAttribute('aria-busy', String(busy));
      control.state.textContent = busy ? t('loading', 'Loading...') : control.label;
    });
  }

  function createStateSwitch(key, name, checked, label, available, isAuto) {
    // A native button provides both Space and Enter activation. Keep its
    // accessible name stable while aria-checked conveys the current state.
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'tools-switch' + (isAuto ? ' tools-switch-auto' : '');
    button.setAttribute('role', 'switch');
    button.setAttribute('aria-label', name);
    button.setAttribute('aria-checked', String(checked));
    const track = document.createElement('span');
    track.className = 'tools-switch-track';
    track.setAttribute('aria-hidden', 'true');
    const thumb = document.createElement('span');
    thumb.className = 'tools-switch-thumb';
    track.appendChild(thumb);
    const state = document.createElement('span');
    state.className = 'tools-switch-state';
    button.appendChild(track);
    button.appendChild(state);
    const control = { key, button, state, label, available };
    switches.push(control);
    syncSwitches();
    return control;
  }

  async function saveSwitch(control, url, values) {
    if (changingState || !stateKnown || !control.available || !switches.includes(control)) return;
    const hadFocus = document.activeElement === control.button;
    let failed = false;
    changingState = true;
    pendingSwitchKey = control.key;
    syncSwitches();
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ ...values, token: config.csrfToken || '' })
      });
      const data = await response.json();
      if (!response.ok || !data || data.status !== 'OK') {
        throw new Error((data && data.error) || t('updateFailed', 'Failed to update tool state'));
      }
    } catch (err) {
      failed = true;
      showErrorModal(err.message || t('updateFailed', 'Failed to update tool state'));
    } finally {
      // A lost POST response may still mean that the change was saved. Never
      // guess the state or allow another write until the snapshot is reloaded.
      await loadTools();
      changingState = false;
      pendingSwitchKey = null;
      syncSwitches();
      if (hadFocus && !failed && stateKnown
          && (document.activeElement === control.button || document.activeElement === document.body)) {
        const replacement = switches.find(item => item.key === control.key);
        if (replacement && !replacement.button.disabled) replacement.button.focus();
      }
    }
  }

  function createCard(tool, options) {
    const opts = options || {};
    const cell = document.createElement('div');
    cell.className = 'cell';
    if (opts.cardClassName) {
      cell.classList.add(opts.cardClassName);
    }

    const title = document.createElement('div');
    title.className = 'cell-title';
    const titleText = document.createElement('span');
    titleText.textContent = tool.name || t('unknownTool', 'Unknown');
    const status = document.createElement('span');
    status.className = 'status-pill' + ((tool.enable === '1') ? ' enabled' : '');
    status.textContent = (tool.enable === '1') ? t('enabled', 'Enabled') : t('disabled', 'Disabled');
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
      conflict.textContent = t('conflict', 'conflict');
      title.appendChild(conflict);
    }
    // enable/disable status at the end
    title.appendChild(status);

    const desc = document.createElement('div');
    desc.className = 'cell-description';
    desc.textContent = tool.description || t('noDescription', 'No description.');

    const footer = document.createElement('div');
    footer.className = 'cell-footer';

    const isEnabled = tool.enable === '1';
    const control = createStateSwitch(
      JSON.stringify([tool.server || '', tool.name || '']),
      (tool.server ? tool.server + ' / ' : '') + (tool.name || t('unknownTool', 'Unknown')),
      isEnabled, isEnabled ? t('enabled', 'Enabled') : t('disabled', 'Disabled'),
      !isConflict && !autoMode, false
    );
    if (isConflict || autoMode) {
      control.button.title = isConflict ? t('conflictTitle', 'Conflict: cannot change state') : t('autoManaged', 'Managed by AI');
    }
    if (autoMode) {
      const managed = document.createElement('span');
      managed.className = 'tools-switch-note';
      managed.textContent = t('autoManaged', 'Managed by AI');
      footer.appendChild(managed);
    }
    control.button.addEventListener('click', () => {
      if (!tool.name) { showToast(t('missingName', 'Missing tool name'), 'error'); return; }
      return saveSwitch(control, isEnabled ? API_DISABLE : API_ENABLE,
        { name: tool.name, server: tool.server || '' });
    });

    footer.appendChild(control.button);
    cell.appendChild(title);
    cell.appendChild(desc);
    cell.appendChild(footer);

    return cell;
  }

  function createAutoSwitch(available) {
    const block = document.createElement('div');
    block.className = 'server-block auto-mode-block';
    const control = createStateSwitch('auto', t('autoMode', 'Auto mode'), autoMode,
      autoMode ? t('autoOn', 'Auto: ON') : t('autoOff', 'Auto: OFF'), available, true);
    const description = document.createElement('p');
    description.className = 'server-description';
    description.textContent = autoMode
      ? t('autoDescription', 'AI selects tools independently of your manual settings. Auto selections are shared by all users until reboot. Turning Auto off and on preserves them during the same boot. The mode itself is saved across reboots.')
      : t('manualDescription', 'Manual mode uses your saved tool settings. In Auto mode, AI can enable tools even if they are disabled here. After reboot, Auto starts with only tool discovery and management enabled.');
    block.appendChild(control.button);
    block.appendChild(description);
    control.button.addEventListener('click', () =>
      saveSwitch(control, API_AUTO, { enable: autoMode ? '0' : '1' }));
    return block;
  }

  function loadTools() {
    const generation = ++loadGeneration;
    return fetch(URL_LOAD_TOOLS, { cache: 'no-store' })
      .then(response => {
        if (!response.ok) throw new Error(t('updateFailed', 'Failed to update tool state'));
        return response.json();
      })
      .then(data => {
        if (generation !== loadGeneration) return;
        if (!data || typeof data !== 'object' || Array.isArray(data)
            || (data.local_tool !== false && (typeof data.auto_mode !== 'boolean'
              || typeof data.mode_available !== 'boolean'
              || (data.status !== 'OK' && data.status !== 'NG')))) {
          throw new Error(t('updateFailed', 'Failed to update tool state'));
        }
        stateKnown = true;
        switches = [];
        if (data && data.local_tool === false) {
          if (headBar) headBar.style.display = 'none';
          if (container) {
            container.innerHTML = '';
            const p = document.createElement('p');
            p.textContent = t('installExtensionHint', "Please install the extension module 'oasis-mod-tool' to enable local tools.");
            container.appendChild(p);
          }
          return;
        }
        // local_tool is enabled: show static Refresh button and bind handler
        if (headBar) headBar.style.display = '';
        bindRefreshButton();
        if (container) {
          container.innerHTML = '';
        }
        autoMode = data.auto_mode === true;
        if (container) container.appendChild(createAutoSwitch(data.mode_available === true));
        if (data.status === 'NG') {
          showErrorModal(data.error || t('updateFailed', 'Failed to update tool state'));
          return;
        }
        const tools = data.tools || {};
        const serverMap = {};

        Object.values(tools).forEach(tool => {
          if (tool[".type"] === "tool" && tool.type === "function") {
            if (isToolSearchTool(tool)) {
              return;
            }
            const server = tool.server || t('unknownServer', 'Unknown Server');
            if (!serverMap[server]) serverMap[server] = [];
            serverMap[server].push(tool);
          }
        });

        Object.keys(serverMap)
          .sort(compareText)
          .forEach(server => {
            if (!container) return;
            const block = createServerBlock(server, sortToolsForDisplay(serverMap[server], false), {
              serverKey: server
            });
            container.appendChild(block);
          });
      })
      .catch(err => {
        if (generation !== loadGeneration) return;
        stateKnown = false;
        syncSwitches();
        console.error('Failed to load server info:', err);
        showErrorModal(t('updateFailed', 'Failed to update tool state'));
      });
  }

  loadTools();
})();
