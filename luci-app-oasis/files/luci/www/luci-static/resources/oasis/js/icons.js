(function() {
    'use strict';

    const config = window.OasisIconsConfig || {};
    const resourcePath = config.resourcePath || '';
    const urls = config.urls || {};

    function getUrl(key) {
        const value = urls[key];
        if (!value) {
            console.warn('OasisIconsConfig missing URL for ' + key);
        }
        return value || '';
    }

    const URL_SELECT_ICON = getUrl('selectIcon');
    const URL_DELETE_ICON = getUrl('deleteIcon');
    const URL_UPLOAD_ICON = getUrl('uploadIcon');
    const URL_LOAD_ICON_INFO = getUrl('loadIconInfo');

    let is_select = false;
    let using_icon_key = "";
    let _pendingDeleteIconKey = null;

    const select_button = document.getElementById('select-button');
    const toastEl = document.getElementById('icons-toast');

    function showToast(message, type = 'info', timeout = 2000) {
        if (!toastEl) return;
        toastEl.style.display = 'block';
        toastEl.textContent = message;
        toastEl.className = `toast show ${type}`;
        setTimeout(() => { toastEl.className = 'toast'; toastEl.textContent = ''; toastEl.style.display = 'none'; }, timeout);
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

    function create_icon_info(key, icon_name, is_using) {
        const iconPath = `${resourcePath}/oasis/`;
        const container = document.getElementById('oasis-icon-container');

        const label = document.createElement('label');
        label.classList.add('icon-label');
        label.id = key;

        const input = document.createElement('input');
        input.type = 'radio';

        if (is_using) {
            input.checked = true;
            using_icon_key = key;
        }

        input.name = 'icon';
        input.value = key;
        input.addEventListener('click', function() {
            if (using_icon_key !== key) {
                is_select = false;
                select_button.classList.remove('done');
                select_button.textContent = 'Select';
            }
        });

        const img = document.createElement('img');
        let decodedIconPath = decodeURIComponent(iconPath + icon_name);
        //img.src = iconPath + icon_name;
        img.src = decodedIconPath;
        img.alt = icon_name;

        label.appendChild(input);
        label.appendChild(img);
        container.appendChild(label);
    }

    select_button.addEventListener('click', function() {

        if (is_select) {
            return;
        }

        const selected_icon = document.querySelector('input[name="icon"]:checked');
        if (!selected_icon) { showToast('Please select an icon', 'error'); return; }

        setLoading(select_button, true);
        fetch(URL_SELECT_ICON, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ using: selected_icon.value }),
        })
        .then(response => response.json())
        .then(data => {

            if (data.error) {
                console.error("Error from server:", data.error);
                showToast('Select failed', 'error');
                setLoading(select_button, false);
                return;
            }

            using_icon_key = selected_icon.value;
            select_button.textContent = 'Done';
            select_button.classList.add('done');
            showToast('Selected', 'success');
            setLoading(select_button, false);
        })
        .catch(error => {
            console.error('Error:', error);
            showToast('Network error', 'error');
            setLoading(select_button, false);
        });
    });

    document.getElementById('delete-button').addEventListener('click', function() {

        if (is_select) {
            return;
        }

        const selected_icon = document.querySelector('input[name="icon"]:checked');
        if (!selected_icon) { showToast('Please select an icon', 'error'); return; }
        _pendingDeleteIconKey = selected_icon.value;
        const modal = document.getElementById('icon-delete-confirm');
        modal.classList.add('show');
        modal.setAttribute('aria-hidden', 'false');
        modal.style.display = 'flex';
    });

    document.getElementById('icon-confirm-no').addEventListener('click', function() {
        const modal = document.getElementById('icon-delete-confirm');
        modal.classList.remove('show');
        modal.setAttribute('aria-hidden', 'true');
        modal.style.display = 'none';
        _pendingDeleteIconKey = null;
    });

    document.getElementById('icon-confirm-yes').addEventListener('click', function() {
        if (!_pendingDeleteIconKey) return;
        fetch(URL_DELETE_ICON, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({ key: _pendingDeleteIconKey }),
        })
        .then(response => response.json())
        .then(data => {
            const modal = document.getElementById('icon-delete-confirm');
            if (data.error) {
                console.error("Error from server:", data.error);
                showToast('Delete failed', 'error');
                modal.classList.remove('show');
                modal.setAttribute('aria-hidden', 'true');
                modal.style.display = 'none';
                _pendingDeleteIconKey = null;
                return;
            }
            const container = document.getElementById('oasis-icon-container');
            const label = document.getElementById(_pendingDeleteIconKey);
            if (container && label) container.removeChild(label);
            showToast('Deleted', 'success');
            modal.classList.remove('show');
            modal.setAttribute('aria-hidden', 'true');
            modal.style.display = 'none';
            _pendingDeleteIconKey = null;
        })
        .catch(error => {
            console.error('Error:', error);
            showToast('Network error', 'error');
            const modal = document.getElementById('icon-delete-confirm');
            modal.classList.remove('show');
            modal.setAttribute('aria-hidden', 'true');
            modal.style.display = 'none';
            _pendingDeleteIconKey = null;
        });
    });

    const dropArea = document.getElementById('dropArea');
    const fileInput = document.getElementById('imageInput');
    let selectedFile = null;

    dropArea.addEventListener('click', () => fileInput.click());

    dropArea.addEventListener('dragover', (event) => {
        event.preventDefault();
        dropArea.classList.add('highlight');
    });

    dropArea.addEventListener('dragleave', () => {
        dropArea.classList.remove('highlight');
    });

    dropArea.addEventListener('drop', (event) => {
        event.preventDefault();
        dropArea.classList.remove('highlight');

        const files = event.dataTransfer.files;
        if (files.length > 0) {
            handleFile(files[0]);
        }
    });

    fileInput.addEventListener('change', (event) => {
        const file = event.target.files[0];
        if (file) {
            handleFile(file);
        }
    });

    function handleFile(file) {

        if (!file.type.startsWith('image/')) {
            showToast('Please select an image file.', 'error');
            return;
        }

        selectedFile = file;
        const reader = new FileReader();
        reader.onload = function(e) {
            const container = document.getElementById('upload-image-container');
            const preview_container = document.getElementById('oasis-preview-container');
            const label = document.createElement('label');
            label.id = "icon-label";
            label.classList.add('icon-label');
            const img = document.createElement('img');
            img.src = e.target.result;
            label.appendChild(img);
            preview_container.appendChild(label);
            container.style.display = 'block';
        };
        reader.readAsDataURL(file);
    }

    document.getElementById('upload-button').addEventListener('click', function() {

        const reader = new FileReader();

        reader.onload = function(event) {

            const base64Data = event.target.result.split(",")[1];

            const uploadBtn = document.getElementById('upload-button');
            setLoading(uploadBtn, true);
            fetch(URL_UPLOAD_ICON, {
                method: "POST",
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: new URLSearchParams({ filename : selectedFile.name, image : base64Data }),
            })
            .then(response => response.json())
            .then(data => {

                if (data.error) {
                    console.error("Error from server:", data.error);
                    showToast('Upload failed', 'error');
                    setLoading(uploadBtn, false);
                    return;
                }

                /* Upload Success */
                create_icon_info(data.key, selectedFile.name, false);
                showToast('Uploaded', 'success');
                setLoading(uploadBtn, false);
            })
            .catch(error => {
                /* Upload Failure */
                showToast('Upload failed', 'error');
                const uploadBtn = document.getElementById('upload-button');
                setLoading(uploadBtn, false);
            });
        };

        reader.readAsDataURL(selectedFile);
        const container = document.getElementById('upload-image-container');
        const preview_container = document.getElementById('oasis-preview-container');
        const image_label = document.getElementById('icon-label');
        preview_container.removeChild(image_label);
        container.style.display = 'none';
    });

    document.getElementById('cancel-button').addEventListener('click', function() {
        const container = document.getElementById('upload-image-container');
        const preview_container = document.getElementById('oasis-preview-container');
        const image_label = document.getElementById('icon-label');
        preview_container.removeChild(image_label);
        container.style.display = 'none';
    });

    document.addEventListener('DOMContentLoaded', function () {
        fetch(URL_LOAD_ICON_INFO, {
            method: 'POST',
        })
        .then(response => response.json())
        .then(data => {

            if (data.error) {
                console.error("Error from server:", data.error);
                return;
            }

            Object.entries(data.list).forEach(([key, value]) => {
                let is_using = (data.ctrl.using == key) ? true : false;
                create_icon_info(key, value, is_using);
            });
        })
        .catch(error => {
            console.error('Error:', error);
        });
    });

})();
