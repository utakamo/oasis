(function() {
    'use strict';

    const config = window.OasisRollbackConfig || {};
    const urls = config.urls || {};

    function getUrl(key) {
        const value = urls[key];
        if (!value) {
            console.warn('OasisRollbackConfig missing URL for ' + key);
        }
        return value || '';
    }

    const URL_LOAD_ROLLBACK_LIST = getUrl('loadRollbackList');
    const URL_ROLLBACK_TARGET = getUrl('rollbackTarget');

    const container = document.getElementById('rollbackContainer');
    const confirmModal = document.getElementById('rollback-confirm');
    const confirmOk = document.getElementById('confirmOk');
    const confirmCancel = document.getElementById('confirmCancel');
    const toastEl = document.getElementById('rollback-toast');

    function showToast(message, type = 'info', timeout = 2000) {
        if (!toastEl) return;
        toastEl.textContent = message;
        toastEl.className = `toast show ${type}`;
        setTimeout(() => { toastEl.className = 'toast'; toastEl.textContent = ''; }, timeout);
    }

    let currentRollbackId = null;
    let currentButton = null;

    function renderRollbackData(rollbackData) {
        container.innerHTML = '';

        const card = document.createElement('div');
        card.className = 'rollback-card';

        const reversedData = rollbackData.slice().reverse();

        reversedData.forEach((entry, index) => {
            const textBox = document.createElement('div');
            textBox.className = 'text-box';
            textBox.style.whiteSpace = 'pre-wrap';
            textBox.textContent = entry.text;

            const button = document.createElement('button');
            button.className = 'rollback-button load-button';
            button.dataset.id = entry.id;
            button.textContent = 'Rollback';

            card.appendChild(textBox);
            card.appendChild(button);
        });

        container.appendChild(card);
    }

    fetch(URL_LOAD_ROLLBACK_LIST, {
        method: 'POST',
    })
    .then(response => response.json())
    .then(data => {
        const rollbackData = data.map((entry, index) => {
            let cmds = [];

            Object.keys(entry).forEach(cmdType => {
                const cmdList = entry[cmdType];
                if (Array.isArray(cmdList) && cmdList.length > 0) {
                    cmdList.forEach(item => {
                        if (item && typeof item.param === 'string' && item.param.length > 0) {
                            cmds.push(`uci ${cmdType} ${item.param}`);
                        }
                    });
                }
            });

            return {
                id: index + 1,
                text: cmds.length ? cmds.join('\n') : 'No UCI commands found.'
            };
        });

        renderRollbackData(rollbackData);
    })
    .catch(error => {
        container.innerHTML = '<p>No Rollback Data</p>';
    });

    function showLoadingOverlay(message) {
        const overlay = document.getElementById('loadingOverlay');
        overlay.querySelector('div').textContent = message || 'Loading...';
        overlay.style.display = 'flex';
    }

    function hideLoadingOverlay() {
        document.getElementById('loadingOverlay').style.display = 'none';
    }

    container.addEventListener('click', function (e) {
        if (e.target.classList.contains('rollback-button')) {
            currentRollbackId = e.target.dataset.id;
            currentButton = e.target;

            document.querySelectorAll('.rollback-button').forEach(btn => {
                btn.classList.remove('selected');
            });
            currentButton.classList.add('selected');

            confirmModal.classList.add('show');
            confirmModal.setAttribute('aria-hidden', 'false');
        }
    });

    confirmOk.onclick = function () {
        confirmModal.classList.remove('show');
        confirmModal.setAttribute('aria-hidden', 'true');

        // Replace content immediately with final instruction
        const finalMsg = 'Rollback has been executed. You can access the UI again once the system has fully restarted.';
        container.innerHTML = '';
        showLoadingOverlay(finalMsg);

        // Fire-and-forget: rollback will likely drop connection; we don't wait UI feedback
        fetch(URL_ROLLBACK_TARGET, { 
            method: "POST",
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ index: currentRollbackId }),
        }).catch(error => {
            console.warn('Rollback may drop connection:', error);
        });
    };

    confirmCancel.onclick = function () {
        confirmModal.classList.remove('show');
        confirmModal.setAttribute('aria-hidden', 'true');
        if (currentButton) {
            currentButton.classList.remove('selected');
        }
    };

})();
