(function() {
    'use strict';

    const config = window.OasisSysmsgConfig || {};
    const urls = config.urls || {};

    function getUrl(key) {
        const value = urls[key];
        if (!value) {
            console.warn('OasisSysmsgConfig missing URL for ' + key);
        }
        return value || '';
    }

    const URL_UPDATE_SYSMSG = getUrl('updateSysmsg');
    const URL_ADD_SYSMSG = getUrl('addSysmsg');
    const URL_LOAD_EXTRA_SYSMSG = getUrl('loadExtraSysmsg');
    const URL_DELETE_SYSMSG = getUrl('deleteSysmsg');
    const URL_LOAD_SYSMSG = getUrl('loadSysmsg');

    let name_cnt = 1;

    function showToast(message, type = 'info', timeout = 2000) {
        const t = document.getElementById('sysmsg-toast');
        if (!t) return;
        t.textContent = message;
        t.className = `toast show ${type}`;
        setTimeout(() => { t.className = 'toast'; t.textContent = ''; }, timeout);
    }

    function setLoading(btn, loading) {
        if (!btn) return;
        btn.disabled = !!loading;
        if (loading) {
            btn.dataset.prevText = btn.textContent;
            btn.textContent = 'Loading...';
        } else if (btn.dataset.prevText) {
            btn.textContent = btn.dataset.prevText;
            delete btn.dataset.prevText;
        }
    }

    function autoResizeTextarea(el, maxRows = 20) {
        if (!el) return;
        const style = window.getComputedStyle(el);
        const lh = parseFloat(style.lineHeight) || 20;
        const border = parseInt(style.borderTopWidth) + parseInt(style.borderBottomWidth);
        const padding = parseInt(style.paddingTop) + parseInt(style.paddingBottom);
        el.style.height = 'auto';
        const content = el.scrollHeight;
        const maxH = lh * maxRows + border + padding;
        el.style.height = Math.min(content, maxH) + 'px';
        el.style.overflowY = content > maxH ? 'auto' : 'hidden';
    }

    function updateLastItemBorder() {
        const list = document.getElementById('system-message-list');
        if (!list) return;
        const visibleItems = Array.from(list.children).filter(el => el.style.display !== 'none');
        // reset all to have border
        Array.from(list.children).forEach(el => { el.style.borderBottom = '1px solid #bbbbbb'; });
        if (visibleItems.length > 0) {
            visibleItems[visibleItems.length - 1].style.borderBottom = 'none';
        }
    }

    // Delete confirm modal helpers
    function openDeleteConfirm(targetKey) {
        window._pendingDeleteKey = targetKey;
        const modal = document.getElementById('delete-confirm');
        if (!modal) return;
        modal.classList.add('show');
        modal.setAttribute('aria-hidden', 'false');
        const yesBtn = document.getElementById('confirm-yes');
        if (yesBtn) yesBtn.focus();
    }

    function closeDeleteConfirm() {
        const modal = document.getElementById('delete-confirm');
        if (!modal) return;
        modal.classList.remove('show');
        modal.setAttribute('aria-hidden', 'true');
        delete window._pendingDeleteKey;
    }

    function create_sysmsg_info(key, value) {

        let is_error = false;
        let is_update = false;

        // Create the container div
        const container = document.createElement('div');
        container.id = key;
        container.className = 'section';

        // Create the span element
        const span = document.createElement('label');
        span.className = 'field-row';
        span.textContent = '#' + name_cnt + ' TITLE:';

        // Create the input element
        const input = document.createElement('input');
        input.type = 'text';
        input.value = value.title;
        input.size = 15;
        input.className = 'input-text';

        // Create the buttons container
        const buttonsContainer = document.createElement('div');
        buttonsContainer.className = 'form-actions';

        // Create the Update button
        const updateButton = document.createElement('button');
        updateButton.type = 'button';
        updateButton.className = 'update-button'
        updateButton.textContent = 'Update';

        updateButton.addEventListener('click', function() {

            if (input.value.length === 0) {
                alert('Please input system message title');
                return;
            }

            if (textarea.value.length === 0) {
                alert('Please input system message data');
                return;
            }

            if (is_error || is_update) {
                return;
            }

            let update_sysmsg_data = textarea.value;
            update_sysmsg_data = update_sysmsg_data.replace(/"/g, '\\"');

            setLoading(updateButton, true);
            fetch(URL_UPDATE_SYSMSG, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: new URLSearchParams({ target: key, title: input.value, message: update_sysmsg_data }),
            })
            .then(response => response.json())
            .then(data => {

                if (data.error) {
                    is_error = true;
                    showToast('Update failed', 'error');
                    setLoading(updateButton, false);
                    return;
                }

                is_update = true;
                setLoading(updateButton, false);
                updateButton.textContent = 'Done';
                updateButton.classList.add('done');
            })
            .catch(error => {
                console.error('Error:', error);
                showToast('Network error', 'error');
                setLoading(updateButton, false);
                updateButton.textContent = 'Update';
                updateButton.classList.remove('done');
            });
        });

        // Create the textarea element
        const textarea = document.createElement('textarea');
        textarea.id = 'system-message-' + name_cnt;
        textarea.rows = 10;
        textarea.className = 'sysmsg-textarea';
        textarea.value = value.chat.replace(/\\"/g, '"').replace(/\\n/g, '\n');   
         
        textarea.addEventListener('input', function() {
            // After entering something, activate the update button.
            if (is_update) {
                is_update = false;
                updateButton.textContent = 'Update';
                updateButton.classList.remove('done');
            }
            autoResizeTextarea(textarea);
        });
        // initial autosize
        setTimeout(() => autoResizeTextarea(textarea), 0);
        name_cnt += 1;

        // Create the Delete button
        const deleteButton = document.createElement('button');
        deleteButton.type = 'button';
        deleteButton.className = 'delete-button';
        deleteButton.textContent = 'Delete';

        deleteButton.addEventListener('click', function() {
            openDeleteConfirm(key);
        });

        // Append the elements to the container
        container.appendChild(span);
        container.appendChild(input);
        container.appendChild(textarea);
        buttonsContainer.appendChild(updateButton);

        if (key !== "default") {
            buttonsContainer.appendChild(deleteButton);
        }

        container.appendChild(buttonsContainer);

        // Get the parent element by id and append the container to it
        const parentElement = document.getElementById('system-message-list');
        parentElement.appendChild(container);
        updateLastItemBorder();
    }

    document.getElementById('add-button').addEventListener('click', function() {
        
        const new_sysmsg_data = document.getElementById('new-sysmsg-data');
        const new_sysmsg_title = document.getElementById('new-sysmsg-title');

        //console.log(new_sysmsg_title.value);
        //console.log(new_sysmsg_data.value);

        if (new_sysmsg_title.value.length === 0) {
            alert('Please input system message title');
            return;
        }

        if (new_sysmsg_data.value.length === 0) {
            alert('Please input system message data');
            return;
        }


        let add_sysmsg_data =  new_sysmsg_data.value;
        add_sysmsg_data = add_sysmsg_data.replace(/"/g, '\\"');

        const addBtn = document.getElementById('add-button');
        setLoading(addBtn, true);
        fetch(URL_ADD_SYSMSG, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ title: new_sysmsg_title.value, message: add_sysmsg_data }),
        })
        .then(response => response.json())
        .then(data => {

            //console.log(data);

            if (data.error) {
                showToast('Add failed', 'error');
                setLoading(addBtn, false);
                return;
            }

            create_sysmsg_info(data.new_sysmsg_key, {title: new_sysmsg_title.value, chat: new_sysmsg_data.value});

            window.scrollTo({
                top: document.body.scrollHeight,
                behavior: 'smooth'
            });

            new_sysmsg_data.value = '';
            new_sysmsg_title.value = '';
            setLoading(addBtn, false);
        });
    });

    document.getElementById('extra-add-button').addEventListener('click', function() {
        
        const extra_sysmsg_data = document.getElementById('extra-sysmsg-data');
        const extra_sysmsg_title = document.getElementById('extra-sysmsg-title');

        //console.log(extra_sysmsg_title.value);
        //console.log(extra_sysmsg_data.value);

        if (extra_sysmsg_title.value.length === 0) {
            alert('Please input system message title');
            return;
        }

        if (extra_sysmsg_data.value.length === 0) {
            alert('Please input system message data');
            return;
        }


        let add_sysmsg_data =  extra_sysmsg_data.value;
        add_sysmsg_data = add_sysmsg_data.replace(/"/g, '\\"');

        const extraAddBtn = document.getElementById('extra-add-button');
        setLoading(extraAddBtn, true);
        fetch(URL_ADD_SYSMSG, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ title: extra_sysmsg_title.value, message: add_sysmsg_data }),
        })
        .then(response => response.json())
        .then(data => {

            //console.log(data);

            if (data.error) {
                showToast('Add failed', 'error');
                setLoading(extraAddBtn, false);
                return;
            }

            create_sysmsg_info(data.new_sysmsg_key, {title: extra_sysmsg_title.value, chat: extra_sysmsg_data.value});

            window.scrollTo({
                top: document.body.scrollHeight,
                behavior: 'smooth'
            });

            extra_sysmsg_data.value = '';
            extra_sysmsg_title.value = '';
            setLoading(extraAddBtn, false);
        });
    });

    document.getElementById('load-button').addEventListener('click', function() {

        const extra_sysmsg_url = document.getElementById('extra-sysmsg-url');
        const extra_sysmsg_container = document.getElementById('extra-sysmsg');
        const extra_sysmsg_textarea = document.getElementById('extra-sysmsg-data');
        //console.log(extra_sysmsg_url.value);

        if (extra_sysmsg_url.value.length === 0) {
            alert('Please input system message server url');
            return;
        }

        const loadBtn = document.getElementById('load-button');
        setLoading(loadBtn, true);
        fetch(URL_LOAD_EXTRA_SYSMSG, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ url: extra_sysmsg_url.value }),
        })
        .then(response => response.json())
        .then(data => {
            //console.log(data);
            extra_sysmsg_textarea.value = data.sysmsg;
            extra_sysmsg_container.style.display = "block";
            showToast('Loaded', 'success');
            setLoading(loadBtn, false);
        });
    });

    // Wire confirm modal buttons
    document.getElementById('confirm-no').addEventListener('click', function() {
        closeDeleteConfirm();
    });

    document.getElementById('confirm-yes').addEventListener('click', function() {
        const key = window._pendingDeleteKey;
        if (!key) { closeDeleteConfirm(); return; }
        fetch(URL_DELETE_SYSMSG, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ target: key }),
        })
        .then(response => response.json())
        .then(data => {
            if (data.error) {
                console.error("Error from server:", data.error);
                showToast('Delete failed', 'error');
                closeDeleteConfirm();
                return;
            }
            const parent = document.getElementById('system-message-list');
            const child = document.getElementById(key);
            if (parent && child) parent.removeChild(child);
            showToast('Deleted', 'success');
            updateLastItemBorder();
            closeDeleteConfirm();
        })
        .catch(error => {
            console.error('Error:', error);
            showToast('Network error', 'error');
            closeDeleteConfirm();
        });
    });

    

    document.addEventListener('DOMContentLoaded', function () {
        fetch(URL_LOAD_SYSMSG, {
            method: 'POST',
        })
        .then(response => response.json())
        .then(data => {
            if (data.error) {
                console.error("Error from server:", data.error);
                return;
            }

            create_sysmsg_info("default", data.default);

            Object.entries(data)
                .filter(([key]) => key.startsWith("custom_") && key.match(/^custom_(\d+)$/))
                .sort((a, b) => {
                    const numA = parseInt(a[0].match(/^custom_(\d+)$/)[1], 10);
                    const numB = parseInt(b[0].match(/^custom_(\d+)$/)[1], 10);
                    return numA - numB;
                })
                .forEach(([key, value]) => {
                    create_sysmsg_info(key, value);
                });
        })
        .catch(error => {
            console.error('Error:', error);
        });
    });

})();
