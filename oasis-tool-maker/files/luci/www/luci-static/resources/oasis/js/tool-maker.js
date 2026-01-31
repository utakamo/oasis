(function() {
  'use strict';

  const config = window.OasisToolMakerConfig || {};
  const urls = config.urls || {};

  const typeSelect = document.getElementById('tm-template');
  const nameInput = document.getElementById('tm-name');
  const bodyEl = document.getElementById('tm-body');
  const outputEl = document.getElementById('tm-output');
  const resultEl = document.getElementById('tm-result');
  const toastEl = document.getElementById('tool-maker-toast');

  const btnGenerate = document.getElementById('tm-generate');
  const btnValidate = document.getElementById('tm-validate');
  const btnSave = document.getElementById('tm-save');

  let currentType = (typeSelect && typeSelect.value) ? typeSelect.value : 'lua';

  function showToast(message, type, timeout) {
    if (!toastEl) return;
    toastEl.textContent = message;
    toastEl.className = 'tm-toast show ' + (type || 'info');
    setTimeout(() => { toastEl.className = 'tm-toast'; toastEl.textContent = ''; }, timeout || 2000);
  }

  function setResult(text) {
    if (resultEl) resultEl.textContent = text || '';
  }

  function postForm(url, data) {
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(data)
    }).then(r => r.json());
  }

  function generateOutput() {
    const body = bodyEl.value || '';
    setResult('');
    btnGenerate.disabled = true;

    return postForm(urls.render, { type: currentType, body })
      .then(data => {
        if (!data || data.status !== 'OK') {
          throw new Error((data && data.error) || 'Render failed');
        }
        outputEl.value = data.content || '';
        showToast('Generated', 'success');
        return data.content || '';
      })
      .catch(err => {
        console.error('Render failed', err);
        showToast('Render failed', 'error', 3000);
        return '';
      })
      .finally(() => { btnGenerate.disabled = false; });
  }

  function onValidate() {
    const body = bodyEl.value || '';
    btnValidate.disabled = true;
    setResult('');

    postForm(urls.validate, { type: currentType, body })
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

    btnSave.disabled = true;
    setResult('');

    const body = bodyEl.value || '';
    if (!body) {
      showToast('Missing tool body', 'error', 3000);
      return;
    }

    generateOutput()
      .then(content => {
        if (!content) throw new Error('No content');
        return postForm(urls.save, { type: currentType, name, body });
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
        console.error('Save failed', err);
        showToast('Save failed', 'error', 3000);
      })
      .finally(() => { btnSave.disabled = false; });
  }

  if (typeSelect) {
    typeSelect.addEventListener('change', () => {
      currentType = typeSelect.value || currentType;
    });
  }
  if (btnGenerate) btnGenerate.addEventListener('click', generateOutput);
  if (btnValidate) btnValidate.addEventListener('click', onValidate);
  if (btnSave) btnSave.addEventListener('click', onSave);

  if (typeSelect && typeSelect.value) {
    currentType = typeSelect.value;
  }
})();
