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
  let pendingManualManifests = [];

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

      confirmListEl.appendChild(item);
    });
  }

  function openConfirmModal(manifests) {
    pendingManualManifests = Array.isArray(manifests) ? manifests : [];
    if (confirmMessageEl) {
      confirmMessageEl.textContent = t(
        'confirmRequiredMessage',
        'The following manual manifests are not yet applied. Applying them will register their tools in Oasis.'
      );
    }
    renderConfirmList(pendingManualManifests);
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

    const btn = document.createElement('button');
    let isEnabled = tool.enable === '1';
    btn.className = isEnabled ? 'delete-button' : 'load-button';
    btn.textContent = isEnabled ? t('disableButton', 'Disable') : t('enableButton', 'Enable');
    if (isConflict) {
      btn.disabled = true;
      btn.title = t('conflictTitle', 'Conflict: cannot change state');
    }

    btn.addEventListener('click', () => {
      if (isConflict) return;
      if (!tool.name) { showToast(t('missingName', 'Missing tool name'), 'error'); return; }
      const enabling = !isEnabled; // current button action
      const url = enabling ? API_ENABLE : API_DISABLE;
      const prevText = btn.textContent;
      btn.disabled = true;
      btn.textContent = t('loading', 'Loading...');
      fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ name: tool.name, server: tool.server || '' })
      })
      .then(r => r.json())
      .then(data => {
        if (!data || data.status !== 'OK') throw new Error((data && data.error) || t('updateFailed', 'Failed to update tool state'));
        // apply UI only on success
        isEnabled = enabling;
        btn.textContent = isEnabled ? t('disableButton', 'Disable') : t('enableButton', 'Enable');
        btn.className = isEnabled ? 'delete-button' : 'load-button';
        status.textContent = isEnabled ? t('enabled', 'Enabled') : t('disabled', 'Disabled');
        status.className = 'status-pill' + (isEnabled ? ' enabled' : '');
      })
      .catch(err => {
        console.error('toggle failed:', err);
        showErrorModal(err && err.message ? err.message : t('updateFailed', 'Failed to update tool state'));
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
        const tools = data.tools || {};
        const serverMap = {};
        const toolSearchTools = [];

        Object.values(tools).forEach(tool => {
          if (tool[".type"] === "tool" && tool.type === "function") {
            if (isToolSearchTool(tool)) {
              toolSearchTools.push(tool);
              return;
            }
            const server = tool.server || t('unknownServer', 'Unknown Server');
            if (!serverMap[server]) serverMap[server] = [];
            serverMap[server].push(tool);
          }
        });

        if (toolSearchTools.length > 0 && container) {
          const block = createServerBlock(
            t('toolSearchCategory', 'Tool Search (oasis.tool.manager)'),
            sortToolsForDisplay(toolSearchTools, true),
            {
              serverKey: TOOL_SEARCH_SERVER,
              blockClassName: 'tool-search-block',
              headerClassName: 'tool-search-header',
              descriptionClassName: 'tool-search-description',
              listClassName: 'tool-search-list',
              cardClassName: 'tool-search-card',
              description: t(
                'toolSearchDescription',
                'Browse available tools and enable or disable them.'
              )
            }
          );
          container.appendChild(block);
        }

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
        console.error('Failed to load server info:', err);
      });
  }

  loadTools();
})();
