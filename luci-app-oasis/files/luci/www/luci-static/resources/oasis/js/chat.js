(function() {
    'use strict';

    const config = window.OasisChatConfig || {};
    if (!config.resourcePath) {
        console.warn('OasisChatConfig.resourcePath is missing');
    }
    const urls = config.urls || {};
    const resourcePath = config.resourcePath || '';
    function getUrl(key) {
        const value = urls[key];
        if (!value) {
            console.warn('OasisChatConfig missing URL for ' + key);
        }
        return value || '';
    }

    const URL_CONFIRM = getUrl('confirm');
    const URL_FINALIZE = getUrl('finalize');
    const URL_ROLLBACK = getUrl('rollback');
    const URL_BASE_INFO = getUrl('baseInfo');
    const URL_DELETE_CHAT = getUrl('deleteChat');
    const URL_RENAME_CHAT = getUrl('renameChat');
    const URL_LOAD_CHAT = getUrl('loadChat');
    const URL_APPLY_UCI_CMD = getUrl('applyUciCmd');
    const URL_SYSTEM_REBOOT = getUrl('systemReboot');
    const URL_RESTART_SERVICE = getUrl('restartService');
    const URL_UCI_SHOW = getUrl('uciShow');
    const URL_IMPORT_CHAT = getUrl('importChat');
    const URL_SELECT_AI_SERVICE = getUrl('selectAiService');
    const STR = window.OasisChatStrings || {};
    const t = (key, fallback) => (Object.prototype.hasOwnProperty.call(STR, key) ? STR[key] : fallback);
    function formatString(template, replacements) {
        let result = template || '';
        if (!replacements) return result;
        Object.keys(replacements).forEach(key => {
            result = result.replace(new RegExp(`\\{${key}\\}`, 'g'), replacements[key]);
        });
        return result;
    }

    
    let activeConversation = false;
    let targetChatItemId = null;
    let chatList = null;
    let icon_name = null;
    let sysmsg_list = null;
    let sysmsg_key = "";
    let targetChatId = "";
    let message_outputing = false;
    let ai_service_list = [];
    let scrollLockEnabled = false;
    let isKeyboardOpen = false;
    let currentAssistantMessageDiv = null;
    let cachedInputHeight = null;
    let mobileLayoutTimer = null;
    let mobileLayoutForce = false;
    let mobileLayoutRemeasure = false;
    const MAX_CHAT_IMPORT_BYTES = 512 * 1024; // 512KB cap to avoid huge uploads on routers

    function isValidChatImportFile(file) {
        if (!file) return false;
        const name = (file.name || '').toLowerCase();
        const extOk = name.endsWith('.json');
        const typeOk = !file.type || file.type === 'application/json' || file.type === 'text/json';
        if (!extOk || !typeOk) {
            alert(t('unexpectedFormat', 'Unexpected data format'));
            return false;
        }
        if (file.size > MAX_CHAT_IMPORT_BYTES) {
            alert('Chat data file is too large (max 512KB).');
            return false;
        }
        return true;
    }

    // Overlay helpers
    function showDownloadOverlay(text) {
        const ov = document.getElementById('download-overlay');
        const tx = document.getElementById('download-overlay-text');
        if (tx && typeof text === 'string') tx.textContent = text;
        if (ov) {
            ov.classList.add('show');
            ov.setAttribute('aria-hidden', 'false');
        }
    }
    function hideDownloadOverlay() {
        const ov = document.getElementById('download-overlay');
        if (ov) {
            ov.classList.remove('show');
            ov.setAttribute('aria-hidden', 'true');
        }
    }

    function hideDownloadOverlayAndWait() {
        hideDownloadOverlay();
        return new Promise((resolve) => {
            requestAnimationFrame(() => {
                requestAnimationFrame(resolve);
            });
        });
    }

    // Reboot progress (5s) and completion animation
    function startRebootProgress(totalMs = 5000) {
        const applyingPopup = document.getElementById('applying-popup');
        const title = document.getElementById('applying-popup-title');
        const progressBar = document.getElementById('progressBar');
        const info = document.getElementById('progressInfo');
        const announce = document.getElementById('reboot_announce');
        if (!applyingPopup || !title || !progressBar) return;

        title.textContent = t('rebooting', 'Rebooting...');
        applyingPopup.style.display = 'block';
        centerElementInChat(applyingPopup);
        progressBar.style.width = '0%';
        if (announce) { announce.style.display = 'none'; announce.classList.remove('reboot-animate'); }

        const startTs = Date.now();
        const tick = () => {
            const elapsed = Date.now() - startTs;
            const pct = Math.min(100, Math.round((elapsed / totalMs) * 100));
            progressBar.style.width = pct + '%';
            if (info) {
                const remainMs = Math.max(0, totalMs - elapsed);
                const remainSec = Math.ceil(remainMs / 1000);
                info.textContent = formatString(t('rebootCountdown', 'Rebooting in {seconds}s ({percent}%)'), {
                    seconds: remainSec,
                    percent: pct
                });
            }
            if (elapsed >= totalMs) {
                if (announce) { announce.style.display = 'block'; announce.classList.add('reboot-animate'); }
            } else {
                requestAnimationFrame(tick);
            }
        };
        requestAnimationFrame(tick);
    }

    function startServiceRestartProgress(totalMs = 10000) {
        const applyingPopup = document.getElementById('applying-popup');
        const title = document.getElementById('applying-popup-title');
        const progressBar = document.getElementById('progressBar');
        const info = document.getElementById('progressInfo');
        if (!applyingPopup || !title || !progressBar) return;

        title.textContent = t('restartService', 'Restarting service...');
        applyingPopup.style.display = 'block';
        centerElementInChat(applyingPopup);
        progressBar.style.width = '0%';
        if (info) info.textContent = '';

        const startTs = Date.now();
        const tick = () => {
            const elapsed = Date.now() - startTs;
            const pct = Math.min(100, Math.round((elapsed / totalMs) * 100));
            progressBar.style.width = pct + '%';
            if (info) {
                const remainMs = Math.max(0, totalMs - elapsed);
                const remainSec = Math.ceil(remainMs / 1000);
                info.textContent = formatString(t('restartCountdown', 'Please wait {seconds}s ({percent}%)'), {
                    seconds: remainSec,
                    percent: pct
                });
            }
            if (elapsed >= totalMs) {
                if (info) info.textContent = '';
                applyingPopup.style.display = 'none';
            } else {
                requestAnimationFrame(tick);
            }
        };
        requestAnimationFrame(tick);
    }

    // Tool execution notice (use existing look & feel as Tool used)
    function showToolExecutionNotice(message) {
        const iconPath = `${resourcePath}/oasis/${icon_name}`;
        const msgDiv = document.createElement('div');
        msgDiv.className = 'message received';
        const iconDiv = document.createElement('div');
        iconDiv.className = 'icon';
        iconDiv.style.backgroundImage = `url(${iconPath})`;
        const textDiv = document.createElement('div');
        textDiv.className = 'message-text chat-bubble';
        const safe = typeof message === 'string' && message.length ? message : t('executingTool', 'Executing tool...');
        textDiv.innerHTML = sanitizeHTML(safe);
        msgDiv.appendChild(iconDiv);
        msgDiv.appendChild(textDiv);
        const chatRoot = document.querySelector('.chat-messages');
        if (chatRoot) {
            if (currentAssistantMessageDiv && chatRoot.contains(currentAssistantMessageDiv)) {
                chatRoot.insertBefore(msgDiv, currentAssistantMessageDiv);
            } else {
                chatRoot.appendChild(msgDiv);
            }
        }
        keepLatestMessageVisible(false);
    }

    // Center popups within the right column (.chat-container)
    function centerElementInChat(element) {
        const chatContainer = document.querySelector('.chat-container');
        if (!element || !chatContainer) return;
        const rect = chatContainer.getBoundingClientRect();
        const centerX = rect.left + (rect.width / 2);
        const centerY = rect.top + (rect.height / 2);
        element.style.position = 'fixed';
        element.style.left = `${centerX}px`;
        element.style.top = `${centerY}px`;
        element.style.transform = 'translate(-50%, -50%)';
    }

    function recenterVisiblePopups() {
        const applying = document.getElementById('applying-popup');
        if (applying && getComputedStyle(applying).display !== 'none') {
            centerElementInChat(applying);
        }
        const confirm = document.getElementById('confirm-popup');
        if (confirm && getComputedStyle(confirm).display !== 'none') {
            centerElementInChat(confirm);
        }
    }

    // Ensure an element is fully visible inside a scroll container
    function ensureElementFullyVisible(container, target, extraPadding = 24) {
        if (!container || !target) return;
        const cRect = container.getBoundingClientRect();
        const tRect = target.getBoundingClientRect();
        const overshootBottom = tRect.bottom - (cRect.bottom - extraPadding);
        const overshootTop = (cRect.top + extraPadding) - tRect.top;
        if (overshootBottom > 0) {
            container.scrollTop += overshootBottom;
        } else if (overshootTop > 0) {
            container.scrollTop -= overshootTop;
        }
    }

    // Keep the latest chat message visible (handles mobile soft keyboard animations)
    // If force=false, only scroll when user is near bottom (stickToBottom=true)
    function keepLatestMessageVisible(force = false) {
        const chatMessages = document.querySelector('.chat-messages');
        if (!chatMessages) return;
        if (!force && !window.__oasisStickToBottom) return;
        const lastReceived = chatMessages.querySelector('.message.received:last-of-type');
        const target = lastReceived || chatMessages.querySelector('.message:last-child');
        const doScroll = () => ensureElementFullyVisible(chatMessages, target, 24);
        doScroll();
        if (force) {
            // Retry to absorb viewport/IME animation timing
            setTimeout(doScroll, 100);
            setTimeout(doScroll, 250);
        }
    }

    // Align conversation start to the top of the chat viewport
    function anchorChatToTop() {
        const chatMessages = document.querySelector('.chat-messages');
        if (!chatMessages) return;
        chatMessages.scrollTop = 0;
    }

    // Ensure the first chat message is visually below the AI service select
    function ensureFirstMessageBelowAISelect() {
        const chatMessages = document.querySelector('.chat-messages');
        const aiSelect = document.getElementById('ai-service-list');
        if (!chatMessages || !aiSelect) return;
        const firstMsg = chatMessages.querySelector('.message');
        if (!firstMsg) return;
        const firstRect = firstMsg.getBoundingClientRect();
        const aiRect = aiSelect.getBoundingClientRect();
        const vp = window.visualViewport;
        const viewportTop = vp ? vp.offsetTop : 0;
        // desired top is at least AI select bottom plus margin, and within visual viewport
        const desiredTop = Math.max(aiRect.bottom + 8, viewportTop + 8);
        const delta = desiredTop - firstRect.top;
        if (delta > 0) {
            // Move content down into view
            chatMessages.scrollTop = Math.max(0, chatMessages.scrollTop - delta);
        }
    }

    function alignFirstConversationUnderAI() {
        // Run a few times to stabilize after keyboard layout is applied
        const doAlign = () => {
            anchorChatToTop();
            ensureFirstMessageBelowAISelect();
        };
        doAlign();
        setTimeout(doAlign, 50);
        setTimeout(doAlign, 150);
        setTimeout(doAlign, 300);
        setTimeout(doAlign, 450);
    }

    function setChatScrollLock(enabled) {
        // Always keep scrolling enabled. Only perform unlock cleanup if needed.
        const cm = document.querySelector('.chat-messages');
        if (!cm) return;
        if (scrollLockEnabled) {
            // If previously locked, remove handlers and restore overflow
            cm.style.overflowY = cm.dataset && cm.dataset.prevOverflowY !== undefined ? cm.dataset.prevOverflowY : '';
            if (cm._wheelHandler) { cm.removeEventListener('wheel', cm._wheelHandler); delete cm._wheelHandler; }
            if (cm._touchHandler) { cm.removeEventListener('touchmove', cm._touchHandler); delete cm._touchHandler; }
        }
        scrollLockEnabled = false;
    }

    function updateScrollLockState() {
        // No-op: scrolling is always enabled now
        setChatScrollLock(false);
    }

    window.addEventListener('resize', recenterVisiblePopups);
    // Show compact New Chat icon on small viewports (desktop included)
    function updateCompactNewButtonForViewport() {
        const smpNewBtn = document.getElementById('smp-new-button');
        const smpNewMini = document.getElementById('smp-new-mini');
        if (!smpNewMini) return;
        const isSmall = window.innerWidth <= 768;
        if (isSmall) {
            smpNewMini.style.display = 'block';
            if (smpNewBtn) smpNewBtn.style.display = 'none';
            if (!smpNewMini.dataset.bound) {
                smpNewMini.addEventListener('click', async function() {
                    await new_chat_action();
                });
                smpNewMini.dataset.bound = '1';
            }
        } else {
            smpNewMini.style.display = 'none';
            if (smpNewBtn) smpNewBtn.style.display = '';
        }
    }
    window.addEventListener('resize', updateCompactNewButtonForViewport);

    // Hide transient overlays/menus when viewport changes to avoid lingering UI
    window.addEventListener('resize', function () {
        const dropdown = document.getElementById('oasis-dropdown');
        if (dropdown) dropdown.style.display = 'none';
        // legacy smartphone dropdown was removed
    });

    function loadPaperPlane() {
        const style = document.createElement('style');
        style.textContent = `
            @font-face {
                font-family: 'Material Icons';
                font-style: normal;
                font-weight: 400;
                src: url('${resourcePath}/oasis/fonts/flUhRq6tzZclQEJ-Vdg-IuiaDsNc.woff2') format('woff2');
            }
            .material-icons {
                font-family: 'Material Icons';
                font-weight: normal;
                font-style: normal;
                font-size: 24px;
                line-height: 1;
                letter-spacing: normal;
                text-transform: none;
                display: inline-block;
                white-space: nowrap;
                word-wrap: normal;
                direction: ltr;
                -webkit-font-feature-settings: 'liga';
                -webkit-font-smoothing: antialiased;
            }
        `;
        document.head.appendChild(style);
    }

    /* legacy smartphone hamburger removed */

    function convertMarkdownToHTML(input) {
        let html = '';
        let isCodeBlock = false;
        let currentLanguage = '';
        const lines = input.split('\n');

        const paragraph = [];
        const flushParagraph = () => {
            if (!paragraph.length) return;
            html += '<p>' + paragraph.join(' ') + '</p>';
            paragraph.length = 0;
        };

        // Markdown table utilities
        const splitCells = (line) => {
            const body = line.trim().replace(/^\|/, '').replace(/\|$/, '');
            return body.split('|').map(c => c.trim());
        };
        const parseAligns = (sepLine) => {
            // supports: :--- (left), :---: (center), ---: (right), --- (left)
            const parts = splitCells(sepLine);
            if (!parts.length) return null;
            const aligns = [];
            for (const p of parts) {
                const s = p.replace(/\s+/g, '');
                if (!/^:?-{3,}:?$/.test(s)) return null;
                if (s.startsWith(':') && s.endsWith(':')) aligns.push('center');
                else if (s.endsWith(':')) aligns.push('right');
                else aligns.push('left');
            }
            return aligns;
        };
        const isTableHeaderStart = (i) => {
            if (i + 1 >= lines.length) return null;
            const head = lines[i].trim();
            const sep = lines[i + 1].trim();
            if (!head.includes('|')) return null;
            const aligns = parseAligns(sep);
            if (!aligns) return null;
            const heads = splitCells(head);
            if (heads.length < 2) return null;
            return { heads, aligns };
        };
        const formatInline = (s) => {
            s = s.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
            s = s.replace(/\*(.+?)\*/g, '<i>$1</i>');
            s = s.replace(/`([^`]+)`/g, '<code class="inline-code">$1<\/code>');
            s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1<\/a>');
            s = s.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1<\/a>');
            return s;
        };

        for (let i = 0; i < lines.length; i++) {
            const rawLine = lines[i];
            const trimmedLine = rawLine.trim();

            // fenced code block
            if (trimmedLine.startsWith('```')) {
                flushParagraph();
                if (!isCodeBlock) {
                    currentLanguage = trimmedLine.slice(3).trim();
                    const languageClass = currentLanguage ? ` language-${escapeHTML(currentLanguage)}` : '';
                    html += `<pre class="console-command-color${languageClass}">`;
                    isCodeBlock = true;
                } else {
                    html += '</pre>';
                    isCodeBlock = false;
                }
                continue;
            }

            if (isCodeBlock) {
                html += escapeHTML(rawLine) + '\n';
                continue;
            }

            // table detection
            const tbl = isTableHeaderStart(i);
            if (tbl) {
                flushParagraph();
                const { heads, aligns } = tbl;
                const colCount = Math.max(heads.length, aligns.length);
                html += '<div class="md-table-wrap"><table class="md-table"><thead><tr>';
                for (let c = 0; c < colCount; c++) {
                    const cell = heads[c] || '';
                    const align = aligns[c] || 'left';
                    html += `<th align="${align}">` + formatInline(cell) + '</th>';
                }
                html += '</tr></thead><tbody>';
                i += 2; // skip header + separator

                // body rows
                while (i < lines.length) {
                    const rowLine = lines[i];
                    if (!rowLine.trim().includes('|')) break;
                    const cells = splitCells(rowLine);
                    // stop if this looks like a new section (e.g., heading) with no real table cells
                    if (cells.length === 1 && cells[0] === '') break;

                    html += '<tr>';
                    for (let c = 0; c < colCount; c++) {
                        const cell = cells[c] || '';
                        const align = aligns[c] || 'left';
                        html += `<td align="${align}">` + formatInline(cell) + '</td>';
                    }
                    html += '</tr>';
                    i++;
                }
                html += '</tbody></table></div>';
                i--; // compensate for for-loop increment
                continue;
            }

            const headingMatch = trimmedLine.match(/^(#{1,6})\s+(.*)$/);
            if (headingMatch) {
                flushParagraph();
                const level = headingMatch[1].length;
                const content = formatInline(headingMatch[2]);
                html += `<h${level}>${content}</h${level}>`;
                continue;
            }

            const blockquoteMatch = trimmedLine.match(/^>\s+(.*)$/);
            if (blockquoteMatch) {
                flushParagraph();
                const content = formatInline(blockquoteMatch[1]);
                html += `<blockquote>${content}</blockquote>`;
                continue;
            }

            if (trimmedLine === '') {
                flushParagraph();
                continue;
            }

            paragraph.push(formatInline(trimmedLine));
        }

        flushParagraph();
        if (isCodeBlock) {
            html += '</pre>';
        }

        return html;
    }

    function escapeHTML(str) {
        return str.replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
                .replace(/'/g, "&#039;");
    }

    // Basic sanitizer with strict allowlist for tags/attributes and safe URLs only
    function sanitizeHTML(dirtyHtml) {
        const tmp = document.createElement('div');
        tmp.innerHTML = dirtyHtml || '';

        const allowedTags = new Set([
            'b','strong','i','em','code','pre','p','br','ul','ol','li','table','thead','tbody','tr','th','td',
            'div','span','h1','h2','h3','h4','h5','h6','blockquote','a'
        ]);
        const allowedAttrs = {
            a: new Set(['href','target','rel']),
            code: new Set(['class']),
            pre: new Set(['class']),
            div: new Set(['class']),
            span: new Set(['class']),
            th: new Set(['align']),
            td: new Set(['align'])
        };

        const walker = document.createTreeWalker(tmp, NodeFilter.SHOW_ELEMENT, null, false);
        const toRemove = [];
        while (walker.nextNode()) {
            const el = walker.currentNode;
            const tag = el.tagName ? el.tagName.toLowerCase() : '';
            if (!allowedTags.has(tag)) { toRemove.push(el); continue; }

            const attrs = Array.from(el.attributes || []);
            for (const attr of attrs) {
                const name = attr.name.toLowerCase();
                const value = attr.value || '';
                const allowForTag = allowedAttrs[tag];
                const isAllowedAttr = allowForTag && allowForTag.has(name);
                if (!isAllowedAttr) { el.removeAttribute(attr.name); continue; }

                if ((name === 'href' || name === 'src') && !/^https?:\/\//i.test(value)) {
                    el.removeAttribute(attr.name);
                    continue;
                }
                if (name === 'target') {
                    if (value !== '_blank' && value !== '_self') {
                        el.setAttribute('target', '_blank');
                    }
                    el.setAttribute('rel', 'noopener');
                }
            }
        }
        toRemove.forEach(n => { if (n && n.parentNode) n.parentNode.removeChild(n); });
        return tmp.innerHTML;
    }

    function closeRenamePopup() {
        const popup = document.getElementById('rename-popup');
        const overlay = document.getElementById('rename-popup-overlay');
        const rename_box = document.getElementById('rename-line-box');
        rename_box.value = '';
        popup.style.display = 'none';
        overlay.style.display = 'none';
    }

    // Inline handlers in chat.htm expect these globals
    window.closeRenamePopup = closeRenamePopup;

    function closeExportPopup() {
        const popup = document.getElementById('export-popup');
        const overlay = document.getElementById('export-popup-overlay');
        popup.style.display = 'none';
        overlay.style.display = 'none';
    }

    window.closeExportPopup = closeExportPopup;

    function check_temporary_setting() {

        fetch(URL_CONFIRM, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded'
            }
        })
        .then(response => response.json())
        .then(data => {

            if (data.error) {
                console.error("Error from server:", data.error);
                return;
            }

            if (data.status === "OK") {
                //console.log(data.uci_list);
                const preElement = document.getElementById("confirm-popup-pre");
                const popup = document.getElementById("confirm-popup");
                const finalizeButton = document.getElementById("finalize");
                const rollbackButton = document.getElementById("rollback");
                popup.style.display = 'block';
                centerElementInChat(popup);

                const uci_list = JSON.parse(data.uci_list);

                Object.keys(uci_list).forEach(key => {
                    const items = uci_list[key];

                    if (Array.isArray(items) && items.length > 0) {
                        //console.log(`Processing items under '${key}':`);
                        items.forEach(item => {
                            if (item.class && item.param) {
                                //const { option, config, value, section } = item.class;
                                const param = item.param;
                                //const output = `Key: ${key}, Config: ${config}, Section: ${section}, Option: ${option}, Value: ${value}, Param: ${param}`;
                                preElement.textContent += `uci ${key} ${param}\n`;
                            }
                        });
                    }
                });

                finalizeButton.addEventListener("click", function (event) {
                    //console.log("finalize click");

                    fetch(URL_FINALIZE, {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/x-www-form-urlencoded'
                        }
                    })
                    .then(response => response.json())
                    .then(data => {

                        if (data.error) {
                            console.error("Error from server:", data.error);
                            return;
                        }
                    })
                    .catch(error => {
                        console.error('Error:', error);
                    });

                    popup.style.display = "none";
                });

                rollbackButton.addEventListener("click", function (event) {
                    //console.log("rollback click");

                    fetch(URL_ROLLBACK, {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/x-www-form-urlencoded'
                        }
                    })
                    .then(response => response.json())
                    .then(data => {

                        if (data.error) {
                            console.error("Error from server:", data.error);
                            return;
                        }
                    })
                    .catch(error => {
                        console.error('Error:', error);
                    });

                    popup.style.display = "none";

                    const applying_popup = document.getElementById('applying-popup');
                    const title = document.getElementById('applying-popup-title');
                    const progressBar = document.getElementById('progressBar');

                    title.textContent = "Rollback..."
                    applying_popup.style.display = 'block';
                    centerElementInChat(applying_popup);
                    progressBar.style.width = '0';

                    setTimeout(() => {
                        progressBar.style.width = '100%';
                    }, 100);

                    setTimeout(() => {
                        reboot_announce.style.display = 'block';
                    }, 10100);
                });
            }
        })
        .catch(error => {
            console.error('Error:', error);
        });
    }

    // Global: Create chat list items and attach events (callable from anywhere)
    function addChatListEntry(id, title) {
        const chatMessagesContainer = document.querySelector('.chat-messages');
        const chatListContainer = document.getElementById("chat-list");
            // legacy smartphone dropdown was removed
        const dropdown = document.getElementById("oasis-dropdown");

        const li = document.createElement("li");

        li.setAttribute("data-id", id);

        const span = document.createElement("span");
        span.textContent = title;
        li.appendChild(span);

                const menuContainer = document.createElement("div");
                menuContainer.classList.add("oasis-hamburger-menu");
                const menuButton = document.createElement("button");
                menuButton.classList.add("oasis-menu-btn");
                menuButton.textContent = "⋮";
                menuButton.addEventListener("click", function (event) {
                    targetChatItemId = event.target.closest("li").getAttribute("data-id");
                    event.stopPropagation();
                    const rect = this.getBoundingClientRect();
                    // Two-column (desktop) layout: place dialog's top-left at the right side of kebab
                    dropdown.style.position = 'absolute';
                    dropdown.style.transform = 'none';
                    dropdown.style.top = `${rect.top + window.scrollY}px`;
                    dropdown.style.left = `${rect.right + window.scrollX}px`;
                    dropdown.style.display = "block";
                });
        menuContainer.appendChild(menuButton);
        li.appendChild(menuContainer);
        chatListContainer.appendChild(li);
        // Sync mobile bottom sheet list whenever a new item is added on desktop
        try {
            if (typeof updateMobileBottomSheetFromDesktop === 'function') {
                updateMobileBottomSheetFromDesktop();
                const mbList = document.getElementById('mb-chat-list');
                if (mbList && mbList.lastElementChild) {
                    mbList.lastElementChild.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
                }
                const sheetContent = document.querySelector('#mobile-bottom-sheet .sheet-content');
                const sheet = document.getElementById('mobile-bottom-sheet');
                if (sheet && sheet.classList.contains('show') && sheetContent) {
                    sheetContent.scrollTop = sheetContent.scrollHeight;
                }
            }
        } catch (_) {}

        li.addEventListener('click', function (event) {
                    const systemMessage = document.getElementById("oasis-system");
                    if (systemMessage !== null) {
                        chatMessagesContainer.removeChild(systemMessage);
                    }
                    targetChatItemId = event.target.closest("li").getAttribute("data-id");
                    if (event.target.closest(".oasis-menu-btn") || event.target.closest(".oasis-dropdown")) {
                        return;
                    }
                    handleChatItemClick(targetChatItemId);
        });
    }

    document.addEventListener('DOMContentLoaded', function () {

        loadPaperPlane();
        const chatMessagesContainer = document.querySelector('.chat-messages');
        const chatListContainer = document.getElementById("chat-list");
        // legacy smartphone dropdown was removed
        const dropdown = document.getElementById("oasis-dropdown");

        // Scroll-to-bottom button click -> smooth scroll to latest
        const scrollBtn = document.getElementById('scroll-bottom-btn');
        if (scrollBtn) {
            scrollBtn.addEventListener('click', () => {
                const cm = document.querySelector('.chat-messages');
                if (cm) cm.scrollTo({ top: cm.scrollHeight, behavior: 'smooth' });
            });
        }

        // Mobile keyboard handling: fixed input bar with simple padding adjustment
        function applyMobileLayout(forceBottom = false, remeasure = false) {
            const chatMessages = document.querySelector('.chat-messages');
            const chatInput = document.querySelector('.chat-input');
            if (!chatMessages || !chatInput) return;
            const isSmallViewport = window.innerWidth <= 768;

            if (!isSmallViewport) {
                cachedInputHeight = null;
                chatInput.style.position = '';
                chatInput.style.left = '';
                chatInput.style.right = '';
                chatInput.style.bottom = '';
                chatInput.style.zIndex = '';
                chatMessages.style.paddingBottom = '';
                isKeyboardOpen = false;
                return;
            }

            let kb = 0;
            if (window.visualViewport) {
                const vv = window.visualViewport;
                kb = Math.max(0, window.innerHeight - (vv.height + vv.offsetTop));
            }
            isKeyboardOpen = kb > 0;

            chatInput.style.position = 'fixed';
            chatInput.style.left = '0';
            chatInput.style.right = '0';
            chatInput.style.bottom = kb + 'px';
            chatInput.style.zIndex = '1200';

            if (cachedInputHeight === null || remeasure) {
                cachedInputHeight = chatInput.offsetHeight || 0;
            }
            const paddingBottom = cachedInputHeight + kb + 16;
            chatMessages.style.paddingBottom = paddingBottom + 'px';

            if (forceBottom && window.__oasisStickToBottom) {
                keepLatestMessageVisible(true);
            }
        }

        function scheduleMobileLayout(forceBottom = false, remeasure = false) {
            mobileLayoutForce = mobileLayoutForce || forceBottom;
            mobileLayoutRemeasure = mobileLayoutRemeasure || remeasure;
            if (mobileLayoutTimer) return;
            mobileLayoutTimer = setTimeout(() => {
                mobileLayoutTimer = null;
                applyMobileLayout(mobileLayoutForce, mobileLayoutRemeasure);
                mobileLayoutForce = false;
                mobileLayoutRemeasure = false;
            }, 50);
        }

        function setChatInputDisabled(disabled) {
            const ci = document.querySelector('.chat-input');
            if (!ci) return;
            if (disabled) ci.classList.add('input-disabled');
            else ci.classList.remove('input-disabled');
        }

        // Track whether user intends to stick to bottom
        function updateStickToBottomFlag() {
            const cm = document.querySelector('.chat-messages');
            if (!cm) return;
            const threshold = 40; // px
            window.__oasisStickToBottom = (cm.scrollHeight - cm.scrollTop - cm.clientHeight) < threshold;
            // Show/hide scroll-to-bottom button
            const btn = document.getElementById('scroll-bottom-btn');
            if (btn) {
                const hasMessages = !!cm.querySelector('.message');
                if (!window.__oasisStickToBottom && hasMessages) {
                    btn.classList.add('show');
                } else {
                    btn.classList.remove('show');
                }
            }
        }
        const cmInit = document.querySelector('.chat-messages');
        if (cmInit) {
            cmInit.addEventListener('scroll', updateStickToBottomFlag, { passive: true });
            // initial flag
            updateStickToBottomFlag();
        }
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', () => scheduleMobileLayout(true, false));
            window.visualViewport.addEventListener('scroll', () => scheduleMobileLayout(true, false));
        }
        window.addEventListener('resize', () => scheduleMobileLayout(false, false));
        window.addEventListener('orientationchange', () => scheduleMobileLayout(true, true));
        scheduleMobileLayout(false, true);

        check_temporary_setting();

        // Helper: populate mobile bottom sheet controls from desktop controls
        function updateMobileBottomSheetFromDesktop() {
            const inlineSys = document.getElementById('inline-sysmsg-select');
            const mbUci = document.getElementById('mb-uci-config-list');
            const mbList = document.getElementById('mb-chat-list');
            const desktopSys = document.getElementById('sysmsg-select');
            const desktopUci = document.getElementById('uci-config-list');
            const desktopList = document.getElementById('chat-list');

            const syncSelect = (target, source, mirrorDisabled = false, onChange) => {
                if (!target || !source) return;
                const srcHtml = source.innerHTML;
                if (target.dataset._lastOptions !== srcHtml) {
                    target.innerHTML = srcHtml;
                    target.dataset._lastOptions = srcHtml;
                }
                target.value = source.value;
                if (mirrorDisabled) target.disabled = source.disabled;
                if (!target.dataset.bound) {
                    target.addEventListener('change', (e) => {
                        if (typeof onChange === 'function') onChange(e);
                    });
                    target.dataset.bound = '1';
                }
            };

            // Populate inline System Message (above textarea)
            syncSelect(inlineSys, desktopSys, true, (e) => {
                desktopSys.value = e.target.value;
                desktopSys.dispatchEvent(new Event('change'));
            });

            // Populate mobile sheet System Message (kept for mobile flow)
            // mb-sysmsg-select was removed

            syncSelect(mbUci, desktopUci, false, (e) => {
                desktopUci.value = e.target.value;
                desktopUci.dispatchEvent(new Event('change'));
            });

            if (mbList && desktopList) {
                const srcHtml = desktopList.innerHTML;
                if (mbList.dataset._lastHtml !== srcHtml) {
                    mbList.innerHTML = srcHtml;
                    mbList.dataset._lastHtml = srcHtml;
                    mbList.querySelectorAll('li').forEach(li => {
                        // Open chat when tapping the row (but not the kebab)
                        li.addEventListener('click', (ev) => {
                            if ((ev.target && (ev.target.closest && ev.target.closest('.oasis-hamburger-menu'))) ||
                                (ev.target && (ev.target.closest && ev.target.closest('.oasis-menu-btn')))) {
                                return; // handled by kebab
                            }
                            const id = ev.currentTarget.getAttribute('data-id');
                            if (id) {
                                handleChatItemClick(id);
                                const sheet = document.getElementById('mobile-bottom-sheet');
                                if (sheet) {
                                    sheet.classList.remove('show');
                                    setTimeout(() => sheet.style.display = 'none', 250);
                                    setChatInputDisabled(false);
                                }
                            }
                        });
                        // Kebab menu in bottom sheet: open oasis-dropdown
                        const menuBtn = li.querySelector('.oasis-menu-btn');
                        if (menuBtn) {
                            menuBtn.addEventListener('click', function (event) {
                                event.stopPropagation();
                                const dropdown = document.getElementById('oasis-dropdown');
                                targetChatItemId = this.closest('li').getAttribute('data-id');
                                dropdown.style.display = 'block';
                                dropdown.style.position = 'fixed';
                                centerElementInChat(dropdown);
                            });
                        }
                    });
                }
            }
        }
        // Expose for global callers (e.g., import handlers defined outside this scope)
        window.updateMobileBottomSheetFromDesktop = updateMobileBottomSheetFromDesktop;
        // Initialize compact New Chat icon state based on viewport
        updateCompactNewButtonForViewport();
        // Initialize mobile bottom sheet bindings if present
(function initMobileBottomSheet() {
            const fab = document.getElementById('open-bottom-sheet');
            const sheet = document.getElementById('mobile-bottom-sheet');
            if (!fab || !sheet) return;
            // Keep FAB inline within chat input buttons; only move sheet to body to avoid clipping
            if (sheet.parentNode !== document.body) document.body.appendChild(sheet);

            // No dynamic repositioning needed since FAB is inline in chat-buttons

            const closeSheet = () => {
                sheet.classList.remove('show');
                sheet.setAttribute('aria-hidden', 'true');
                setTimeout(() => sheet.style.display = 'none', 250);
                sheet.style.transform = '';
                setChatInputDisabled(false);
            };

            fab.addEventListener('click', () => {
                // Ensure content is up-to-date every time before showing
                updateMobileBottomSheetFromDesktop();
                sheet.style.display = 'block';
                sheet.setAttribute('aria-hidden', 'false');
                requestAnimationFrame(() => {
                    sheet.classList.add('show');
                    const focusTarget = sheet;
                    if (focusTarget && focusTarget.focus) focusTarget.focus();
                });
                setChatInputDisabled(true);
            });
            // close button removed
            // First population
            updateMobileBottomSheetFromDesktop();

            // Drag-to-close (pull down) for mobile sheet
            const handle = sheet.querySelector('.sheet-handle') || sheet;
            let dragStartY = 0;
            let dragCurrentY = 0;
            let dragging = false;
            const threshold = 80;
            let rafId = null;

            const onDragStart = (y) => {
                dragging = true;
                dragStartY = y;
                dragCurrentY = y;
                sheet.style.transition = 'none';
            };
            const onDragMove = (y) => {
                if (!dragging) return;
                dragCurrentY = y;
                if (rafId) cancelAnimationFrame(rafId);
                rafId = requestAnimationFrame(() => {
                    const delta = Math.max(0, dragCurrentY - dragStartY);
                    sheet.style.transform = `translateY(${delta}px)`;
                });
            };
            const onDragEnd = () => {
                if (!dragging) return;
                const delta = dragCurrentY - dragStartY;
                sheet.style.transition = 'transform 120ms ease-out';
                if (rafId) { cancelAnimationFrame(rafId); rafId = null; }
                if (delta > threshold) {
                    closeSheet();
                } else {
                    sheet.style.transform = '';
                }
                dragging = false;
            };

            handle.addEventListener('touchstart', (e) => {
                if (e.touches && e.touches[0]) onDragStart(e.touches[0].clientY);
            }, { passive: true });
            handle.addEventListener('touchmove', (e) => {
                if (e.touches && e.touches[0]) onDragMove(e.touches[0].clientY);
            }, { passive: true });
            handle.addEventListener('touchend', onDragEnd);
            handle.addEventListener('mousedown', (e) => onDragStart(e.clientY));
            window.addEventListener('mousemove', (e) => onDragMove(e.clientY));
            window.addEventListener('mouseup', onDragEnd);

            // No need to track scroll/resize for FAB inline placement
            // Hide bottom sheet and FAB on desktop viewport
            function updateBottomSheetVisibilityForViewport() {
                const isSmall = window.innerWidth <= 768;
                if (!isSmall) {
                    // Hide sheet if visible
                    closeSheet();
                    // Hide FAB
                    fab.style.display = 'none';
                    setChatInputDisabled(false);
                } else {
                    // Show FAB on small viewport
                    fab.style.display = '';
                }
            }
            window.addEventListener('resize', updateBottomSheetVisibilityForViewport);
            // Initial state
            updateBottomSheetVisibilityForViewport();
            // Remove textarea-height tracking to avoid following input height
        })();
        
        // Close bottom sheet when clicking outside, but keep it open if user interacts with dialogs/menus
        document.addEventListener('click', function (ev) {
            const sheet = document.getElementById('mobile-bottom-sheet');
            const fab = document.getElementById('open-bottom-sheet');
            const dropdown = document.getElementById('oasis-dropdown');
            const renamePopup = document.getElementById('rename-popup');
            const renameOverlay = document.getElementById('rename-popup-overlay');
            const exportPopup = document.getElementById('export-popup');
            const exportOverlay = document.getElementById('export-popup-overlay');
            const confirmPopup = document.getElementById('confirm-popup');
            const applyingPopup = document.getElementById('applying-popup');
            if (!sheet || getComputedStyle(sheet).display === 'none') return;
            // If click is inside the sheet, FAB, dropdown, or any foreground dialog/overlay, do not close the sheet
            if (
                sheet.contains(ev.target) ||
                (fab && fab.contains(ev.target)) ||
                (dropdown && dropdown.style.display === 'block' && dropdown.contains(ev.target)) ||
                (renamePopup && renamePopup.contains(ev.target)) ||
                (renameOverlay && renameOverlay.contains(ev.target)) ||
                (exportPopup && exportPopup.contains(ev.target)) ||
                (exportOverlay && exportOverlay.contains(ev.target)) ||
                (confirmPopup && confirmPopup.contains(ev.target)) ||
                (applyingPopup && applyingPopup.contains(ev.target))
            ) return;
            sheet.classList.remove('show');
            sheet.setAttribute('aria-hidden', 'true');
            setTimeout(() => sheet.style.display = 'none', 250);
            setChatInputDisabled(false);
        });

        // Input: Enter to send / Shift+Enter for newline + auto-resize up to 5 lines + disable SEND when empty
        function initMessageInputAutoResizeAndEnterSend() {
            const messageInputEl = document.getElementById('message-input');
            const sendBtn = document.getElementById('send-button');
            // Determine line-height dynamically (fallback when 'normal')
            const computed = window.getComputedStyle(messageInputEl);
            const parsedLine = parseFloat(computed.lineHeight);
            const lineHeightPx = isNaN(parsedLine) ? 20 : parsedLine;
            const maxLines = 5;

            function autoResizeTextarea() {
                messageInputEl.style.height = 'auto';
                const cs = window.getComputedStyle(messageInputEl);
                const border = parseInt(cs.borderTopWidth) + parseInt(cs.borderBottomWidth);
                const padding = parseInt(cs.paddingTop) + parseInt(cs.paddingBottom);
                const contentHeight = messageInputEl.scrollHeight;
                const maxHeight = (lineHeightPx * maxLines) + padding + border;
                const newHeight = Math.min(contentHeight, maxHeight);
                messageInputEl.style.height = newHeight + 'px';
                messageInputEl.style.overflowY = (contentHeight > maxHeight) ? 'auto' : 'hidden';
                applyMobileLayout(false);
            }

            function toggleSendDisabled() {
                const text = messageInputEl.value.trim();
                sendBtn.disabled = text.length === 0;
            }

            messageInputEl.placeholder = t('inputPlaceholder', 'Your Message (Enter to send, Shift+Enter for newline)');
        messageInputEl.addEventListener('input', function() {
            autoResizeTextarea();
            toggleSendDisabled();
            scheduleMobileLayout(false, true);
            if (isKeyboardOpen && window.__oasisStickToBottom) keepLatestMessageVisible();
        });
            messageInputEl.addEventListener('keydown', function(event) {
                if (event.key === 'Enter' && !event.shiftKey) {
                    event.preventDefault();
                    sendBtn.click();
                }
            });

            autoResizeTextarea();
            toggleSendDisabled();
            // Initial adjust for mobile keyboard when focusing the input
        messageInputEl.addEventListener('focus', () => {
                scheduleMobileLayout(true, true);
                setTimeout(() => { if (window.__oasisStickToBottom) keepLatestMessageVisible(true); }, 50);
                setTimeout(() => { if (window.__oasisStickToBottom) keepLatestMessageVisible(true); }, 200);
        });
        }

        // Run initialization (safe after DOMContentLoaded)
        initMessageInputAutoResizeAndEnterSend();

        // addChatListEntry is defined globally above

        fetch(URL_BASE_INFO, {
            method: 'POST'
        })
        .then(response => response.json())
        .then(data => {
            if (data.error) {
                console.error("Error from server:", data.error);
                return;
            }

            const chatItems = Array.isArray(data.chat.item) ? data.chat.item
                : (typeof data.chat.item === 'object' && data.chat.item !== null && !('id' in data.chat.item)) ? []
                : (data.chat.item ? [data.chat.item] : []);

            // Initialize chatList and sync internal state
            chatList = { item: [] };

            chatItems.forEach(chat => {
                chatList.item.push({ id: chat.id, title: chat.title });
                addChatListEntry(chat.id, chat.title);
            });

            // After desktop controls are filled, sync to mobile bottom sheet
            updateMobileBottomSheetFromDesktop();

            let using_icon = data.icon.ctrl.using;
            icon_name = data.icon.list[using_icon];

            // Populate System Message <select>
            sysmsg_list = data.sysmsg;
            const sysmsgSelect = document.getElementById('sysmsg-select');
            if (sysmsgSelect) {
                sysmsgSelect.innerHTML = '';
            const sortedSysmsgList = sysmsg_list
                .map(item => {
                        if (!item.key || typeof item.key !== 'string') return null;
                        if (item.key === 'default') {
                            return { key: item.key, title: item.title || 'Default', number: -1 };
                        }
                    const match = item.key.match(/^custom_(\d+)$/);
                    if (!match) return null;
                        return { key: item.key, title: item.title || 'No Title', number: parseInt(match[1], 10) };
                    })
                    .filter(Boolean)
                .sort((a, b) => a.number - b.number);

            sortedSysmsgList.forEach(item => {
                    const opt = document.createElement('option');
                    opt.value = item.key;
                    opt.textContent = item.title;
                    sysmsgSelect.appendChild(opt);
                });

                // Set default selection and update global key
                if (sortedSysmsgList.length > 0) {
                    const defaultEntry = sortedSysmsgList.find(x => x.key === 'default') || sortedSysmsgList[0];
                    sysmsgSelect.value = defaultEntry.key;
                    sysmsg_key = defaultEntry.key;
                }

                sysmsgSelect.addEventListener('change', function (e) {
                    sysmsg_key = e.target.value;
                });
                // Enable only for a new chat (no targetChatId yet)
                sysmsgSelect.disabled = (targetChatId && targetChatId.length > 0);
                // Sync to mobile bottom sheet now that System Message is ready
                updateMobileBottomSheetFromDesktop();
            }

            ai_service_list = Array.isArray(data.service) ? data.service : [];
            const aiServiceSelect = document.getElementById("ai-service-list");
            aiServiceSelect.innerHTML = '';  // clear existing options

            let validServiceFound = false;

            ai_service_list.forEach((service, index) => {
                if (service && service.name && service.model) {
                    const option = document.createElement("option");
                    option.value = index;
                    option.textContent = `${service.name} - ${service.model}`;
                    aiServiceSelect.appendChild(option);
                    validServiceFound = true;
                }
            });

            if (!validServiceFound) {
                const option = document.createElement("option");
                option.value = 0;
                option.textContent = "No AI Service";
                aiServiceSelect.appendChild(option);
            }

            const uciConfigSelect = document.getElementById("uci-config-list");
            uciConfigSelect.innerHTML = '';
            const defaultOption = document.createElement("option");
            defaultOption.value = "---";
            defaultOption.textContent = "---";
            uciConfigSelect.appendChild(defaultOption);

            data.configs.forEach(config => {
                const option = document.createElement("option");
                option.value = config;
                option.textContent = config;
                uciConfigSelect.appendChild(option);
            });
            // Sync to mobile bottom sheet now that UCI list is ready
            updateMobileBottomSheetFromDesktop();

            // Smartphone selects mirror (System Message & UCI)
            // smp-sysmsg-select removed

            // smp-uci-config-list removed

        })
        .catch(error => {
            console.error('Error:', error);
        });

        function isMobile() {
            return (
                /iPhone|iPad|iPod|Android/i.test(navigator.userAgent) || 
                (navigator.maxTouchPoints > 0 && window.innerWidth <= 500)
            );
        }

        if (isMobile()) {
            document.getElementById("message-input").addEventListener("keydown", function(event) {
                // On mobile, also use Enter to send / Shift+Enter for newline
                if (event.key === 'Enter' && !event.shiftKey) {
                    event.preventDefault();
                    document.getElementById("send-button").click();
                }
            });

            document.getElementById("message-input").addEventListener("focus", function() {
                setTimeout(() => {
                    this.scrollIntoView({ behavior: "smooth", block: "center" });
                }, 300);
            });

        // Mirror lock state of System Message select on mobile (legacy removed)

        // Replace New Chat button in hamburger with compact icon under send icon (vertical stack)
        const smpNewBtn = document.getElementById('smp-new-button');
        const smpNewMini = document.getElementById('smp-new-mini');
        if (smpNewBtn && smpNewMini) {
            smpNewBtn.style.display = 'none';
            smpNewMini.style.display = 'block';
            smpNewMini.addEventListener('click', async function() {
                await new_chat_action();
            });
        }

        // Setup mobile bottom sheet
        const fab = document.getElementById('open-bottom-sheet');
        const sheet = document.getElementById('mobile-bottom-sheet');
        if (fab && sheet) {
            fab.classList.add('show');
            fab.addEventListener('click', () => {
                sheet.style.display = 'block';
                requestAnimationFrame(() => sheet.classList.add('show'));
            });
            // Mirror selects into bottom sheet (System Message select removed on mobile)
            const mbUci = document.getElementById('mb-uci-config-list');
            const desktopUci = document.getElementById('uci-config-list');
            if (mbUci && desktopUci) {
                mbUci.innerHTML = desktopUci.innerHTML;
                mbUci.value = desktopUci.value;
                mbUci.addEventListener('change', (e) => {
                    desktopUci.value = e.target.value;
                    desktopUci.dispatchEvent(new Event('change'));
                });
            }
        }
        }

        document.addEventListener("click", function (e) {
            dropdown.style.display = 'none';
        });

        document.addEventListener("click", function (event) {
            const target = event.target;

            if (target.classList.contains("oasis-menu-item")) {
                const action = target.getAttribute("data-action");

                if (action === "delete") {
                    handleDeleteAction(target);
                } else if (action === "rename") {
                    handleRenameAction(target, targetChatItemId);
                } else if (action === "export") {
                    handleExportAction(target, targetChatItemId);
                }
            }
        });

        function handleDeleteAction(button) {

            //console.log("Deleting chat with ID:", targetChatItemId);

            if (activeConversation) {
                return;
            }

            fetch(URL_DELETE_CHAT, {
                method: "POST",
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: new URLSearchParams({ params: targetChatItemId }),
            })
            .then((response) => response.json())
            .then((data) => {
                if (data.status === "OK") {
                    const deletedId = targetChatItemId;
                    const desktopItem = document.querySelector(`#chat-list li[data-id='${deletedId}']`);
                    const mbItem = document.querySelector(`#mb-chat-list li[data-id='${deletedId}']`);

                    let removed = false;
                    if (desktopItem) { desktopItem.remove(); removed = true; }
                    if (mbItem) { mbItem.remove(); removed = true; }

                    if (removed) {
                        const chatMessagesContainer = document.querySelector('.chat-messages');
                        if (chatMessagesContainer) {
                            const messages = chatMessagesContainer.querySelectorAll('.message.sent, .message.received');
                            messages.forEach(message => message.remove());
                        }
                        // Remove from in-memory chatList
                        if (chatList && Array.isArray(chatList.item)) {
                            chatList.item = chatList.item.filter(entry => String(entry.id) !== String(deletedId));
                        }
                        targetChatId = ""; // clear target id
                        // Hide dropdown if visible
                        const dropdownEl = document.getElementById('oasis-dropdown');
                        if (dropdownEl) dropdownEl.style.display = 'none';
                        // If deletion was triggered from the bottom sheet, keep the sheet open
                        const sheet = document.getElementById('mobile-bottom-sheet');
                        if (sheet && sheet.classList.contains('show')) {
                            // no-op: do not close the sheet
                        }
                        // Refresh mobile sheet list from desktop
                        if (typeof updateMobileBottomSheetFromDesktop === 'function') {
                            updateMobileBottomSheetFromDesktop();
                        }
                    } else {
                        console.error("Could not find the list item with ID:", deletedId);
                    }
                } else {
                    console.error("Error deleting chat:", data.error);
                    alert(t('deleteFailed', 'Failed to delete chat. Please try again.'));
                }
            })
            .catch((error) => {
                console.error("Request failed:", error);
                alert(t('deleteFailed', 'Failed to delete chat. Please try again.'));
            });
        }

        function handleRenameAction(button) {

            //console.log("Renaming chat with ID:", targetChatItemId);
            //const newName = prompt("Enter new name for the chat:", "");

            const renameLineBox = document.getElementById('rename-line-box');
            const popup = document.getElementById('rename-popup');
            const overlay = document.getElementById('rename-popup-overlay');
            popup.style.display = 'block';
            overlay.style.display = 'block';

            const rename = document.getElementById("rename");

        let title = "";
        if (chatList && Array.isArray(chatList.item)) {
            chatList.item.forEach(chat => {
                if (chat.id === targetChatItemId) {
                    title = chat.title;
                }
            });
        }

            renameLineBox.setAttribute('placeholder', title || t('renamePlaceholder', 'Enter new title'));
            renameLineBox.setAttribute('autocomplete', 'off');

            rename.addEventListener('click', function() {

                const rename_box = document.getElementById('rename-line-box');
                let new_title = rename_box.value;

                if (new_title.length === 0) {
                    return;
                }

                fetch(URL_RENAME_CHAT, {
                    method: "POST",
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: new URLSearchParams({ id: targetChatItemId, title: new_title })
                })
                .then((response) => response.json())
                .then((data) => {
                    if (data.error) {
                        console.error("Error renaming chat:", data.error);
                        return;
                    }
                })
                .catch((error) => {
                    console.error("Request failed:", error);
                    //alert("Failed to rename chat. Please try again.");
                });

                const desktopItem = document.querySelector(`#chat-list li[data-id='${targetChatItemId}']`);
                const mbItem = document.querySelector(`#mb-chat-list li[data-id='${targetChatItemId}']`);

                const desktopSpan = desktopItem ? desktopItem.querySelector('span') : null;
                const mbSpan = mbItem ? mbItem.querySelector('span') : null;

                if (desktopSpan) desktopSpan.textContent = new_title;
                if (mbSpan) mbSpan.textContent = new_title;
                rename_box.value = "";

                if (chatList && Array.isArray(chatList.item)) {
                chatList.item.forEach(chat => {
                    if (chat.id === targetChatItemId) {
                        chat.title = new_title;
                    }
                });
                }

                closeRenamePopup();
        const overlay = document.getElementById('modal-overlay');
        if (overlay) overlay.style.display = 'none';
                // Refresh mobile list mirror after rename
                if (typeof updateMobileBottomSheetFromDesktop === 'function') {
                    updateMobileBottomSheetFromDesktop();
                }
            }, { once: true })
        }

        function handleExportAction(button, id) {
            const popup = document.getElementById('export-popup');
            const overlay = document.getElementById('export-popup-overlay');
            popup.style.display = 'block';
            overlay.style.display = 'block';

            //console.log("id = " + id);

            // 重複リスナ防止のためボタンをクローンして差し替える
            const jsonBtn = document.getElementById("json-export");
            const textBtn = document.getElementById("text-export");

            const jsonClone = jsonBtn.cloneNode(true);
            jsonBtn.parentNode.replaceChild(jsonClone, jsonBtn);
            jsonClone.addEventListener('click', function() {
                jsonClone.disabled = true;

                fetch(URL_LOAD_CHAT, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: new URLSearchParams({ params: id })
                })
                .then(response => response.json())
                .then(data => {

                    if (data.error) {
                        console.error("Error from server:", data.error);
                        return;
                    }

                    const rawData = JSON.stringify(data, null, 2);

                    const blob = new Blob([rawData], { type: "application/json" });
                    const url = URL.createObjectURL(blob);

                    const a = document.createElement("a");
                    a.href = url;
                    a.download = `chat_data_${id}.json`;
                    document.body.appendChild(a);
                    a.click();
                    document.body.removeChild(a);
                    URL.revokeObjectURL(url);
                })
                .catch(error => {
                    console.error('Error:', error);
                })
                .finally(() => {
                    jsonClone.disabled = false;
                });

                closeExportPopup();
            });

            const textClone = textBtn.cloneNode(true);
            textBtn.parentNode.replaceChild(textClone, textBtn);
            textClone.addEventListener('click', function() {

                let chat_data = "";
                textClone.disabled = true;

                fetch(URL_LOAD_CHAT, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: new URLSearchParams({ params: id })
                })
                .then(response => response.json())
                .then(data => {

                    if (data.error) {
                        console.error("Error from server:", data.error);
                        return;
                    }

                    data.messages.forEach(message => {
                        if (message.role === 'user') {
                            chat_data += ">>> You\n";
                        } else if (message.role === 'assistant') {
                            chat_data += ">>> AI\n";
                        }

                        if ((message.role === 'user') || (message.role === 'assistant')) {
                            chat_data += message.content + "\n\n";
                        }
                    });

                    const blob = new Blob([chat_data], { type: "text/plain" });
                    const url = URL.createObjectURL(blob);

                    const a = document.createElement("a");
                    a.href = url;
                    a.download = `chat_data_${id}.txt`;
                    document.body.appendChild(a);
                    a.click();
                    document.body.removeChild(a);
                    URL.revokeObjectURL(url);

                    //console.log("Text file downloaded successfully.");
                })
                .catch(error => {
                    console.error('Error:', error);
                })
                .finally(() => {
                    textClone.disabled = false;
                });

                closeExportPopup();
            });

            // Duplicate handler removed
        }
    });

// removed: showTitlePopup (unused)

    async function send_chat_data(systemMessage, messageInput, messageText) {

        const messageContainer = document.createElement('div');
        messageContainer.className = 'message sent';

        const messageTextContainer = document.createElement('div');
        messageTextContainer.className = 'message-text';
        //messageTextContainer.textContent = messageText;
        messageTextContainer.innerHTML = sanitizeHTML(convertMarkdownToHTML(messageText));

        messageContainer.appendChild(messageTextContainer);

        const chatMessagesRoot = document.querySelector('.chat-messages');
        const hasExisting = !!chatMessagesRoot.querySelector('.message');
        chatMessagesRoot.appendChild(messageContainer);

        if (systemMessage !== null) {
            document.querySelector('.chat-messages').removeChild(systemMessage);
        }
    
        messageInput.value = '';
        messageInput.focus();

        const chatMessages = document.querySelector('.chat-messages');
        chatMessages.scrollTop = chatMessages.scrollHeight;

        const receivedMessageContainer = document.createElement('div');
        receivedMessageContainer.className = 'message received';

        const iconPath = `${resourcePath}/oasis/${icon_name}`;
        const receivedIconContainer = document.createElement('div');
        receivedIconContainer.className = 'icon';
        receivedIconContainer.style.backgroundImage = `url(${iconPath})`;

        const receivedMessageTextContainer = document.createElement('div');
        receivedMessageTextContainer.className = 'message-text chat-bubble';

        const typingDots = document.createElement("span");
        typingDots.classList.add("typing-dots");

        for (let i = 0; i < 3; i++) {
            const dot = document.createElement("span");
            typingDots.appendChild(dot);
        }

        const typingText = document.createElement("span");
        typingText.classList.add("typing-text");
        typingText.textContent = t('thinking', 'Thinking...');

        receivedMessageTextContainer.appendChild(typingDots);
        receivedMessageTextContainer.appendChild(typingText);

        // Typing indicator only (fixed "Thinking...")
    
        receivedMessageContainer.appendChild(receivedIconContainer);
        receivedMessageContainer.appendChild(receivedMessageTextContainer);

        chatMessagesRoot.appendChild(receivedMessageContainer);
        currentAssistantMessageDiv = receivedMessageContainer;
        // If this is the very first conversation while IME is open, anchor start to top
        const vp = window.visualViewport;
        const keyboardShown = vp ? (window.innerHeight - vp.height - vp.offsetTop) > 0 : false;
        if (!hasExisting && keyboardShown) {
            // Position the first pair at the top of the viewport
            const firstMessage = chatMessagesRoot.querySelector('.message');
            if (firstMessage && firstMessage.scrollIntoView) {
                try { firstMessage.scrollIntoView({ block: 'start' }); } catch (_) {}
            }
            chatMessages.scrollTop = 0;
            ensureFirstMessageBelowAISelect();
        } else {
            chatMessages.scrollTop = chatMessages.scrollHeight;
        }

        let uci_info = await retrieve_uci_show_result(messageTextContainer);
        messageText += uci_info;
        //console.log(messageText);
        send_message(receivedMessageTextContainer, messageText);
    }

        document.getElementById('smp-send-button').addEventListener('click', function(event) {
        event.preventDefault();
        document.getElementById("send-button").click();
    });

        // Send button
    document.getElementById('send-button').addEventListener('click', async function() {

        const systemMessage = document.getElementById("oasis-system");
        const messageInput = document.getElementById('message-input');
        const messageText = messageInput.value.trim();

        if (!messageText) {
            return;
        }

        if (message_outputing) {
            return;
        }

        message_outputing = true;

        // For new chats, do not show popup; use System Message selected in left column

        // Lock System Message selection once the very first message of a new chat is sent
        if (!targetChatId || targetChatId.length === 0) {
            const sysmsgSelect = document.getElementById('sysmsg-select');
            const inlineSys = document.getElementById('inline-sysmsg-select');
            const mbSys = document.getElementById('mb-sysmsg-select');
            if (sysmsgSelect) sysmsgSelect.disabled = true;
            if (inlineSys) inlineSys.disabled = true;
            if (mbSys) mbSys.disabled = true;
        }

        send_chat_data(systemMessage, messageInput, messageText);
        // Ensure the newly appended messages are visible even when IME is open
        keepLatestMessageVisible();
    });

    function show_chat_popup(jsonResponse) {
        message_outputing = false;
        targetChatId = jsonResponse.id;
        //console.log("targetChatId = " + targetChatId);
        // removed: showTitlePopup(jsonResponse.title);

        const itemCount = (chatList !== null) ? chatList.item.length : 0;
        
        if (itemCount === 0) {
            chatList = { item:[] };  
        }

        chatList.item.push({id: jsonResponse.id, title: jsonResponse.title})
        
        // New Chat List Item (refactored)
        addChatListEntry(jsonResponse.id, jsonResponse.title);
    }

    function save_apply_proc(jsonResponse, type) {
        const chatMessagesContainer = document.querySelector('.chat-messages');
        const popup = document.getElementById('applying-popup');
        const title = document.getElementById('applying-popup-title');
        const progressBar = document.getElementById('progressBar');
        //const closePopupButton = document.getElementById('close-applying-popup');

        let uci_list_json = JSON.stringify(jsonResponse.uci_list);

        fetch(URL_APPLY_UCI_CMD, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded'
            },
            body: new URLSearchParams({uci_list : uci_list_json, id : targetChatId, type : type})
        })
        .then(response => {
            if (!response.ok) {
                throw new Error('HTTP ' + response.status);
            }
            return response.text();
        })
        .then(_ => { /* ignore body */ })
        .catch(error => {
            console.error('Error:', error);
        });

        // Note: Input init already executed on page load

        const systemMessage = document.getElementById("oasis-system");
        if (systemMessage !== null) {
            chatMessagesContainer.removeChild(systemMessage);
        }

        title.textContent = t('applySettings', 'Applying the settings...');
        popup.style.display = 'block';
        centerElementInChat(popup);
        progressBar.style.width = '0%';

        const progressInfo = document.getElementById('progressInfo');
        const totalMs = 10000; // reload after 10 seconds
        const startTs = Date.now();

        const tick = () => {
            const elapsed = Date.now() - startTs;
            const pct = Math.min(100, Math.round((elapsed / totalMs) * 100));
            progressBar.style.width = pct + '%';
            if (progressInfo) {
                const remainMs = Math.max(0, totalMs - elapsed);
                const remainSec = Math.ceil(remainMs / 1000);
                progressInfo.textContent = `Reloading in ${remainSec}s (${pct}%)`;
            }
            if (elapsed >= totalMs) {
            window.location.reload();
            } else {
                requestAnimationFrame(tick);
            }
        };
        requestAnimationFrame(tick);

        // Copy button: copy contents of confirm-popup-pre (works after element creation)
        // No copy button needed on Applying

        // Applying dialog cannot be closed by clicking background

        /*
        closePopupButton.addEventListener('click', () => {
            //popup.style.display = 'none';
            window.location.reload();
        });
        */
    }

    function show_notify_popup(jsonResponse) {
        const chatMessagesContainer = document.querySelector('.chat-messages');
        const systemMessage = document.createElement("div");

        systemMessage.classList.add("message", "oasis-system");
        systemMessage.id = "oasis-system";

        const messageTextDiv = document.createElement("div");
        messageTextDiv.className = "message-text";

        const textNode = document.createTextNode("OpenWrt UCI Commands");
        messageTextDiv.appendChild(textNode);

        const preElement = document.createElement("pre");
        preElement.className = "console-command-color";
        preElement.id = "uci-popup-pre";

        Object.keys(jsonResponse.uci_list).forEach(key => {
            const items = jsonResponse.uci_list[key];

            if (Array.isArray(items) && items.length > 0) {
                //console.log(`Processing items under '${key}':`);
                items.forEach(item => {
                    if (item.class && item.param) {
                        //const { option, config, value, section } = item.class;
                        const param = item.param;
                        //const output = `Key: ${key}, Config: ${config}, Section: ${section}, Option: ${option}, Value: ${value}, Param: ${param}`;
                        preElement.textContent += `uci ${key} ${param}\n`;
                    }
                });
            }
        });

        //preElement.textContent = `uci set network.lan.ipaddr=192.168.1.1\nuci set network.lan.proto=static`;
        messageTextDiv.appendChild(preElement);

        const popupButtonsDiv = document.createElement("div");
        popupButtonsDiv.className = "uci-popup-buttons";

        const popupDiv = document.createElement("div");
        popupDiv.className = "uci-popup";

        // TODO: Ask button will be added later
        // const askButton = document.createElement("button");
        // askButton.id = "ask";
        // askButton.textContent = "Ask";
        // popupDiv.appendChild(askButton);

        const applyButton = document.createElement("button");
        applyButton.id = "apply";
        applyButton.textContent = "Apply";
        applyButton.addEventListener('click', function (event) {
            save_apply_proc(jsonResponse, "commit");
        });

        popupDiv.appendChild(applyButton);
        

        const cancelButton = document.createElement("button");
        cancelButton.id = "uci-cancel";
        cancelButton.textContent = "Cancel";
        cancelButton.addEventListener('click', function (event) {
            const systemMessage = document.getElementById("oasis-system");
            // overlay removed
            if (systemMessage) chatMessagesContainer.removeChild(systemMessage);
        });

        popupDiv.appendChild(cancelButton);

        popupButtonsDiv.appendChild(popupDiv);
        messageTextDiv.appendChild(popupButtonsDiv);
        systemMessage.appendChild(messageTextDiv);
        chatMessagesContainer.appendChild(systemMessage);
        // Show overlay when opening confirm (overlay removed)
        // overlay removed
    }

    function show_reboot_popup() {
        const chatMessagesContainer = document.querySelector('.chat-messages');
        const systemMessage = document.createElement("div");

        systemMessage.classList.add("message", "oasis-system");
        systemMessage.id = "oasis-reboot";

        const messageTextDiv = document.createElement("div");
        messageTextDiv.className = "message-text";

        const titleDiv = document.createElement("div");
        titleDiv.textContent = t('rebootPrompt', 'System reboot is required. Reboot now?');
        messageTextDiv.appendChild(titleDiv);

        const popupButtonsDiv = document.createElement("div");
        popupButtonsDiv.className = "uci-popup-buttons";

        const popupDiv = document.createElement("div");
        popupDiv.className = "uci-popup";

        const rebootButton = document.createElement("button");
        rebootButton.id = "apply";
        rebootButton.textContent = t('rebootButton', 'Reboot');
        rebootButton.addEventListener('click', async function () {
            rebootButton.disabled = true;
            cancelButton.disabled = true;
            try {
                const res = await fetch(URL_SYSTEM_REBOOT, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
                });
                if (!res.ok) throw new Error('HTTP ' + res.status);
                let data = null;
                try { data = await res.json(); } catch (_) {}
                if (!data || data.status !== 'OK') {
                    console.error('system-reboot NG:', data);
                } else {
                    // Close confirm bubble
                    const el = document.getElementById("oasis-reboot");
                    if (el && el.parentNode) el.parentNode.removeChild(el);
                    // Show 7s progress and completion animation
                    startRebootProgress(7000);
                }
            } catch (e) {
                console.error('system-reboot failed:', e);
            } finally {
                rebootButton.disabled = false;
                cancelButton.disabled = false;
            }
        });

        const cancelButton = document.createElement("button");
        cancelButton.id = "uci-cancel";
        cancelButton.textContent = t('cancelButton', 'Cancel');
        cancelButton.addEventListener('click', async function () {
            try {
                await fetch(URL_SYSTEM_REBOOT, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'cancel=1'
                });
            } catch (_) {}
            const el = document.getElementById("oasis-reboot");
            if (el && el.parentNode) el.parentNode.removeChild(el);
        });

        popupDiv.appendChild(rebootButton);
        popupDiv.appendChild(cancelButton);

        popupButtonsDiv.appendChild(popupDiv);
        messageTextDiv.appendChild(popupButtonsDiv);
        systemMessage.appendChild(messageTextDiv);
        chatMessagesContainer.appendChild(systemMessage);

        if (typeof keepLatestMessageVisible === 'function') {
            keepLatestMessageVisible(true);
        }
    }

    function show_restart_service_popup(serviceName) {
        const chatMessagesContainer = document.querySelector('.chat-messages');
        if (!chatMessagesContainer) return;

        if (document.getElementById("oasis-restart-service")) return;

        const systemMessage = document.createElement("div");
        systemMessage.classList.add("message", "oasis-system");
        systemMessage.id = "oasis-restart-service";

        const messageTextDiv = document.createElement("div");
        messageTextDiv.className = "message-text";

        const titleDiv = document.createElement("div");
        const restartPrompt = (serviceName && serviceName.length)
            ? formatString(t('restartServiceNamedPrompt', 'Service "{name}" needs restart. Restart now?'), { name: serviceName })
            : t('restartServicePrompt', 'Service restart is required. Restart now?');
        titleDiv.textContent = restartPrompt;
        messageTextDiv.appendChild(titleDiv);

        const popupButtonsDiv = document.createElement("div");
        popupButtonsDiv.className = "uci-popup-buttons";

        const popupDiv = document.createElement("div");
        popupDiv.className = "uci-popup";

        const restartBtn = document.createElement("button");
        restartBtn.textContent = t('restartButton', 'Restart');
        restartBtn.className = "btn-restart";

        const cancelBtn = document.createElement("button");
        cancelBtn.id = "uci-cancel";
        cancelBtn.textContent = t('cancelButton', 'Cancel');

        restartBtn.addEventListener("click", async () => {
            restartBtn.disabled = true;
            cancelBtn.disabled = true;
            try {
                const res = await fetch(URL_RESTART_SERVICE, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
                });
                if (!res.ok) throw new Error('HTTP ' + res.status);
                let data = null;
                try { data = await res.json(); } catch (_) {}
                if (!data || data.status !== 'OK') {
                    console.error('restart-service NG:', data);
                } else {
                    const el = document.getElementById("oasis-restart-service");
                    if (el && el.parentNode) el.parentNode.removeChild(el);
                    startServiceRestartProgress(10000);
                }
            } catch (e) {
                console.error('restart-service failed:', e);
            } finally {
                restartBtn.disabled = false;
                cancelBtn.disabled = false;
            }
        });

        cancelBtn.addEventListener("click", async () => {
            try {
                await fetch(URL_RESTART_SERVICE, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'cancel=1'
                });
            } catch (_) {}
            const el = document.getElementById("oasis-restart-service");
            if (el && el.parentNode) el.parentNode.removeChild(el);
        });

        popupDiv.appendChild(restartBtn);
        popupDiv.appendChild(cancelBtn);
        popupButtonsDiv.appendChild(popupDiv);
        messageTextDiv.appendChild(popupButtonsDiv);
        systemMessage.appendChild(messageTextDiv);
        chatMessagesContainer.appendChild(systemMessage);

        if (typeof keepLatestMessageVisible === 'function') {
            keepLatestMessageVisible(true);
        }
    }


    // TODO: Temporary Fix
    // This function will be removed later.
    function isNumeric(str) {
        return /^\d+$/.test(str);
    }

    async function retrieve_uci_show_result(messageTextContainer) {

        const selectElement = document.getElementById("uci-config-list");
        let target_uci_config = selectElement.value;
        //console.log(target_uci_config);

        if (target_uci_config === '---') {
            return '';
        }

        let uci_info = '';

        try {
            const response = await fetch(URL_UCI_SHOW, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded'
                },
                body: new URLSearchParams({ target: target_uci_config })
            });

            const data = await response.json();

            const uciTitle = formatString(t('uciInfoTitle', "### [User's {config} config]"), { config: target_uci_config });
            uci_info = '\n\n' + uciTitle + '\n';
            uci_info += '```\n';

            for (let i = 0; i < data.length; i++) {
                uci_info += data[i] + '\n';
            }

            uci_info += '```\n';
            messageTextContainer.innerHTML += sanitizeHTML(convertMarkdownToHTML(uci_info));

        } catch (error) {
            console.error('Error:', error);
            return '';
        }

        selectElement.value = '---';
        return uci_info;
    }


    async function send_message(receivedMessageTextContainer, messageText) {
        activeConversation = true;
        const baseUrl = window.location.origin || `${window.location.protocol}//${window.location.host}`;
        let fullMessage = '';
        let is_notify = false;
        let toolNoticesHtml = '';
        let errorNoticesHtml = '';
        let toolNoticeShown = false;
        let toolNoticeMessageDiv = null;
        let rebootRequired = false;
        let pendingServiceRestart = '';

        // Utility to extract complete JSON objects from the buffer
        function extractJsonObjects(text) {
            const objects = [];
            let startIndex = -1;
            let depth = 0;
            let inString = false;
            let escapeNext = false;

            for (let i = 0; i < text.length; i++) {
                const ch = text[i];

                if (inString) {
                    if (escapeNext) {
                        escapeNext = false;
                    } else if (ch === '\\') {
                        escapeNext = true;
                    } else if (ch === '"') {
                        inString = false;
                    }
                    continue;
                }

                if (ch === '"') {
                    inString = true;
                    continue;
                }

                if (ch === '{') {
                    if (depth === 0) startIndex = i;
                    depth++;
                } else if (ch === '}') {
                    depth--;
                    if (depth === 0 && startIndex !== -1) {
                        objects.push(text.slice(startIndex, i + 1));
                        startIndex = -1;
                    }
                }
            }

            let remaining = '';
            if (depth > 0 && startIndex !== -1) {
                remaining = text.slice(startIndex);
            } else if (startIndex === -1) {
                remaining = '';
            }

            return { objects, remaining };
        }

        try {
            const response = await fetch(`${baseUrl}/cgi-bin/oasis`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    cmd: 'chat',
                    id: targetChatId,
                    message: messageText,
                    sysmsg_key: sysmsg_key,
                })
            });

            if (!response.ok) {
                console.error('HTTP Error:', response.status, response.statusText);
                receivedMessageTextContainer.innerHTML = sanitizeHTML(convertMarkdownToHTML(t('networkError', 'A network error occurred. Please try again later.')));
                return;
            }

            const chatMessages = document.querySelector('.chat-messages');
            const isSmallViewport = window.innerWidth <= 768;
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let buffer = '';

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                buffer += decoder.decode(value, { stream: true });

                // Safely extract using brace depth even if NDJSON/SSE prefixes are mixed
                const { objects, remaining } = extractJsonObjects(buffer);
                buffer = remaining;

                for (const jsonText of objects) {
                    let evt = null;
                    try {
                        evt = JSON.parse(jsonText);
                    } catch (e) {
                        continue;
                    }
                    //console.log('[AI evt]', evt);

                    if (evt && evt.reboot === true) { rebootRequired = true }

                    // Custom stream events: execution/download
                    if (evt && typeof evt.type === 'string') {
                        if (evt.type === 'execution') {
                            if (evt.message) showToolExecutionNotice(evt.message);
                            else showToolExecutionNotice(t('executingTool', 'Executing tool...'));
                            continue;
                        }
                        if (evt.type === 'download') {
                            showDownloadOverlay(evt.message || t('downloading', 'Downloading...'));
                            continue;
                        }
                    }

                    // Restart service popup trigger (streaming) -> defer to final phase
                    if (evt && typeof evt.prepare_service_restart === 'string' && evt.prepare_service_restart.trim().length > 0) {
                        // console.log('[oasis] detected prepare_service_restart (stream top-level):', evt.prepare_service_restart);
                        pendingServiceRestart = evt.prepare_service_restart.trim();
                    }

                    // Tool execution notice
                    // Expected JSON: {"tool_outputs":[{"tool_call_id":"...","output":"...","name":"..."}], "service":"..."}
                    if (evt && Array.isArray(evt.tool_outputs)) {
                        const hasService = (typeof evt.service === 'string' && evt.service.length > 0);
                        const hasOutputs = (evt.tool_outputs.length > 0);
                        const allValid = hasOutputs && evt.tool_outputs.every(o => ('output' in o));

                        const names = hasOutputs
                            ? Array.from(new Set(
                                evt.tool_outputs
                                    .map(o => (typeof o.name === 'string' && o.name.length > 0) ? o.name : null)
                                    .filter(Boolean)
                            ))
                            : [];
                        const toolNamesLabel = names.length ? names.join(', ') : '(unknown)';

                        if (hasService && allValid) {
                            toolNoticesHtml += `<div class="tool-notice">${escapeHTML(t('toolUsed', 'Tool used:'))} <span class="tool-name">${escapeHTML(toolNamesLabel)}</span></div>`;
                            if (!toolNoticeShown) {
                                // Insert Tool Used bubble before current typing bubble
                                const iconPath = `${resourcePath}/oasis/${icon_name}`;
                                const msgDiv = document.createElement('div');
                                msgDiv.className = 'message received';
                                const iconDiv = document.createElement('div');
                                iconDiv.className = 'icon';
                                iconDiv.style.backgroundImage = `url(${iconPath})`;
                                const textDiv = document.createElement('div');
                                textDiv.className = 'message-text chat-bubble';
                                textDiv.innerHTML = toolNoticesHtml;
                                msgDiv.appendChild(iconDiv);
                                msgDiv.appendChild(textDiv);
                                const chatRoot = document.querySelector('.chat-messages');
                                const parentMsg = receivedMessageTextContainer && receivedMessageTextContainer.parentNode;
                                if (chatRoot) {
                                    if (parentMsg && chatRoot.contains(parentMsg)) {
                                        chatRoot.insertBefore(msgDiv, parentMsg);
                                    } else {
                                        chatRoot.appendChild(msgDiv);
                                    }
                                }
                                toolNoticeShown = true;
                                toolNoticeMessageDiv = msgDiv;
                                const cm = document.querySelector('.chat-messages');
                                if (cm) cm.scrollTop = cm.scrollHeight;
                                if (isKeyboardOpen) {
                                    keepLatestMessageVisible(true);
                                    setChatScrollLock(true);
                                } else {
                                    keepLatestMessageVisible(true);
                                }
                            }

                            // Show user_only message(s) right after the Tool Used bubble
                            try {
                                const outputs = Array.isArray(evt.tool_outputs) ? evt.tool_outputs : [];
                                outputs.forEach(o => {
                                    if (!o || typeof o.output !== 'string') return;
                                    try {
                                        const parsed = JSON.parse(o.output);
                                        // Detect prepare_service_restart inside tool output JSON
                                        if (parsed && typeof parsed.prepare_service_restart === 'string') {
                                            const svc = parsed.prepare_service_restart.trim();
                                            if (svc) {
                                                // console.log('[oasis] detected prepare_service_restart in tool_outputs (stream):', svc);
                                                pendingServiceRestart = svc;
                                            }
                                        }
                                        const userOnly = (parsed && typeof parsed.user_only === 'string') ? parsed.user_only.trim() : '';
                                        if (!userOnly) return;

                                        const iconPath2 = `${resourcePath}/oasis/${icon_name}`;
                                        const msgDiv2 = document.createElement('div');
                                        msgDiv2.className = 'message received oasis-user-only';
                                        const iconDiv2 = document.createElement('div');
                                        iconDiv2.className = 'icon';
                                        iconDiv2.style.backgroundImage = `url(${iconPath2})`;
                                        const textDiv2 = document.createElement('div');
                                        textDiv2.className = 'message-text';
                                        const titleEl = document.createElement('div');
                                        titleEl.className = 'oasis-user-only-title';
                                        titleEl.textContent = 'user only message';
                                        const bodyEl = document.createElement('div');
                                        bodyEl.className = 'oasis-user-only-body';
                                        bodyEl.innerHTML = sanitizeHTML(convertMarkdownToHTML(userOnly));
                                        textDiv2.appendChild(titleEl);
                                        textDiv2.appendChild(bodyEl);
                                        msgDiv2.appendChild(iconDiv2);
                                        msgDiv2.appendChild(textDiv2);

                                        const chatRoot2 = document.querySelector('.chat-messages');
                                        const parentMsg2 = receivedMessageTextContainer && receivedMessageTextContainer.parentNode;
                                        if (chatRoot2) {
                                            if (toolNoticeMessageDiv && chatRoot2.contains(toolNoticeMessageDiv)) {
                                                if (toolNoticeMessageDiv.nextSibling) {
                                                    chatRoot2.insertBefore(msgDiv2, toolNoticeMessageDiv.nextSibling);
                                                } else {
                                                    chatRoot2.appendChild(msgDiv2);
                                                }
                                            } else if (parentMsg2 && chatRoot2.contains(parentMsg2)) {
                                                chatRoot2.insertBefore(msgDiv2, parentMsg2);
                                            } else {
                                                chatRoot2.appendChild(msgDiv2);
                                            }
                                        }
                                        const cm2 = document.querySelector('.chat-messages');
                                        if (cm2) cm2.scrollTop = cm2.scrollHeight;
                                        if (isKeyboardOpen) {
                                            keepLatestMessageVisible(true);
                                            setChatScrollLock(true);
                                        } else {
                                            keepLatestMessageVisible(true);
                                        }
                                    } catch (_) {}
                                });
                            } catch (_) {}
                        } else {
                            const missing = [];
                            if (!hasService) missing.push('service');
                            if (!hasOutputs) missing.push('tool_outputs');
                            else if (!allValid) missing.push('tool_outputs[*].output');
                            errorNoticesHtml += `<div class="error-notice">Invalid tool response: missing ${escapeHTML(missing.join(', '))}</div>`;
                        }

                        // Progressive rendering on desktop: keep typing until content arrives
                        if (!isSmallViewport && fullMessage.length > 0) {
                            receivedMessageTextContainer.innerHTML = errorNoticesHtml + sanitizeHTML(convertMarkdownToHTML(fullMessage));
                            if (receivedMessageTextContainer._typingTimer) {
                                clearInterval(receivedMessageTextContainer._typingTimer);
                                delete receivedMessageTextContainer._typingTimer;
                            }
                            if (isKeyboardOpen) {
                                keepLatestMessageVisible(true);
                                setChatScrollLock(true);
                            } else {
                                keepLatestMessageVisible(false);
                            }
                        }
                    }

                    // Assistant message (streaming)
                    if (evt.message && typeof evt.message.content === 'string') {
                        // On assistant response, hide download overlay if visible
                        await hideDownloadOverlayAndWait();
                        fullMessage += evt.message.content;
                        if (!isSmallViewport) {
                            receivedMessageTextContainer.innerHTML = errorNoticesHtml + sanitizeHTML(convertMarkdownToHTML(fullMessage));
                            if (receivedMessageTextContainer._typingTimer) {
                                clearInterval(receivedMessageTextContainer._typingTimer);
                                delete receivedMessageTextContainer._typingTimer;
                            }
                            if (isKeyboardOpen) {
                                keepLatestMessageVisible(true);
                                setChatScrollLock(true);
                            } else {
                                keepLatestMessageVisible(false);
                            }
                        }
                    }

                    if (evt.id && isNumeric(evt.id)) {
                        show_chat_popup(evt);
                    }

                    if (evt.uci_notify && !is_notify) {
                        show_notify_popup(evt);
                        chatMessages.scrollTop = chatMessages.scrollHeight;
                        is_notify = true;
                    }
                }
            }

            // For single-response (one JSON), try parsing the remaining buffer
            const trimmed = (buffer || '').trim();
            if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
                try {
                    const evt = JSON.parse(trimmed);
                    //console.log('[AI single evt]', evt);

                    if (evt && evt.reboot === true) { rebootRequired = true }

                    // Tool execution notice (single JSON)
                    if (evt && Array.isArray(evt.tool_outputs)) {
                        const hasService = (typeof evt.service === 'string' && evt.service.length > 0);
                        const hasOutputs = (evt.tool_outputs.length > 0);
                        const allValid = hasOutputs && evt.tool_outputs.every(o => ('output' in o));

                        const names = hasOutputs
                            ? Array.from(new Set(
                                evt.tool_outputs
                                    .map(o => (typeof o.name === 'string' && o.name.length > 0) ? o.name : null)
                                    .filter(Boolean)
                            ))
                            : [];
                        const toolNamesLabel = names.length ? names.join(', ') : '(unknown)';

                        if (hasService && allValid) {
                            toolNoticesHtml += `<div class=\"tool-notice\">Tool used: <span class=\"tool-name\">${escapeHTML(toolNamesLabel)}</span></div>`;
                            if (!toolNoticeShown) {
                                const iconPath = `${resourcePath}/oasis/${icon_name}`;
                                const msgDiv = document.createElement('div');
                                msgDiv.className = 'message received';
                                const iconDiv = document.createElement('div');
                                iconDiv.className = 'icon';
                                iconDiv.style.backgroundImage = `url(${iconPath})`;
                                const textDiv = document.createElement('div');
                                textDiv.className = 'message-text chat-bubble';
                                textDiv.innerHTML = toolNoticesHtml;
                                msgDiv.appendChild(iconDiv);
                                msgDiv.appendChild(textDiv);
                                const chatRoot = document.querySelector('.chat-messages');
                                if (chatRoot) chatRoot.appendChild(msgDiv);
                                toolNoticeShown = true;
                                toolNoticeMessageDiv = msgDiv;
                                const cm = document.querySelector('.chat-messages');
                                if (cm) cm.scrollTop = cm.scrollHeight;
                                if (isKeyboardOpen) {
                                    keepLatestMessageVisible(true);
                                    setChatScrollLock(true);
                                } else {
                                    keepLatestMessageVisible(true);
                                }
                            }

                            // Show user_only message(s) right after the Tool Used bubble
                            try {
                                const outputs = Array.isArray(evt.tool_outputs) ? evt.tool_outputs : [];
                                outputs.forEach(o => {
                                    if (!o || typeof o.output !== 'string') return;
                                    try {
                                        const parsed = JSON.parse(o.output);
                                        // Detect prepare_service_restart inside tool output JSON (single JSON path)
                                        if (parsed && typeof parsed.prepare_service_restart === 'string') {
                                            const svc = parsed.prepare_service_restart.trim();
                                            if (svc) {
                                                // console.log('[oasis] detected prepare_service_restart in tool_outputs (single):', svc);
                                                pendingServiceRestart = svc;
                                            }
                                        }
                                        const userOnly = (parsed && typeof parsed.user_only === 'string') ? parsed.user_only.trim() : '';
                                        if (!userOnly) return;
                                        // ... existing code ...
                                    } catch (_) {}
                                });
                            } catch (_) {}
                        } else {
                            const missing = [];
                            if (!hasService) missing.push('service');
                            if (!hasOutputs) missing.push('tool_outputs');
                            else if (!allValid) missing.push('tool_outputs[*].output');
                            errorNoticesHtml += `<div class="error-notice">${escapeHTML(formatString(t('invalidToolResponse', 'Invalid tool response: missing {fields}'), { fields: missing.join(', ') }))}</div>`;
                        }
                    }

                    if (evt && typeof evt.type === 'string') {
                        if (evt.type === 'execution') {
                            if (evt.message) showToolExecutionNotice(evt.message);
                        } else if (evt.type === 'download') {
                            showDownloadOverlay(evt.message || t('downloading', 'Downloading...'));
                        }
                    }

                    // Restart service popup trigger (single JSON) -> defer to final phase
                    if (evt && typeof evt.prepare_service_restart === 'string' && evt.prepare_service_restart.trim().length > 0) {
                        // console.log('[oasis] detected prepare_service_restart (single top-level):', evt.prepare_service_restart);
                        pendingServiceRestart = evt.prepare_service_restart.trim();
                    }

                    if (evt.message && typeof evt.message.content === 'string') {
                        await hideDownloadOverlayAndWait();
                        fullMessage += evt.message.content;
                    }
                    if (evt.id && isNumeric(evt.id)) {
                        show_chat_popup(evt);
                    }
                    if (evt.uci_notify && !is_notify) {
                        show_notify_popup(evt);
                    }
                } catch (_) {
                    // Ignore: the final fragment may be incomplete
                }
            }

            // Final output
            const __hasToolNotice = !!(toolNoticesHtml && toolNoticesHtml.length > 0);
            const __hasErrorNotice = !!(errorNoticesHtml && errorNoticesHtml.length > 0);
            const __finalText = (fullMessage || '').trim();
            //console.log('[AI final text]', __finalText);
            if (!__hasToolNotice && !__hasErrorNotice && __finalText.length === 0) {
                receivedMessageTextContainer.innerHTML = sanitizeHTML(convertMarkdownToHTML(t('noResponse', 'No response from AI service. Please check settings.')));
            } else {
                // Render only errors + assistant content. Tool notice is shown in a separate bubble.
                receivedMessageTextContainer.innerHTML = errorNoticesHtml + sanitizeHTML(convertMarkdownToHTML(__finalText));
            }

            // Prompt reboot if required by tool results
            if (rebootRequired === true) {
                setTimeout(async () => {
                    show_reboot_popup();
                }, 0);
            }
            // Show restart-service popup at the same timing as reboot popup (final phase)
            if (pendingServiceRestart && pendingServiceRestart.length > 0) {
                // console.log('[oasis] pendingServiceRestart(final):', pendingServiceRestart);
                setTimeout(() => { show_restart_service_popup(pendingServiceRestart); }, 0);
            }
            if (receivedMessageTextContainer._typingTimer) {
                clearInterval(receivedMessageTextContainer._typingTimer);
                delete receivedMessageTextContainer._typingTimer;
            }
            if (isSmallViewport) {
                keepLatestMessageVisible(true);
            } else {
                if (isKeyboardOpen) {
                    keepLatestMessageVisible(true);
                } else {
                    keepLatestMessageVisible(false);
                }
            }
        } catch (error) {
            console.error('Request failed', error);
            receivedMessageTextContainer.innerHTML = sanitizeHTML(convertMarkdownToHTML(t('networkErrorDetailed', 'A network error occurred. Please check your network connection and AI service settings.')));
        } finally {
            message_outputing = false;
            activeConversation = false;
            setChatScrollLock(false);
            currentAssistantMessageDiv = null;
        }
    }

    function handleChatItemClick(chatId) {

        //console.log("chat id = " + chatId);

        if (activeConversation) {
            return;
        }

        const chatMessagesContainer = document.querySelector('.chat-messages');

        if (chatMessagesContainer) {
            const messages = chatMessagesContainer.querySelectorAll('.message.sent, .message.received');
            messages.forEach(message => message.remove());
        }

        fetch(URL_LOAD_CHAT, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded'
            },
            body: new URLSearchParams({ params: chatId })
        })
        .then(response => response.json())
        .then(data => {

            if (data.error) {
                console.error("Error from server:", data.error);
                return;
            }

            if (data.messages && Array.isArray(data.messages)) {
                data.messages.forEach(message => {
                    const messageDiv = document.createElement('div');
                    const messageTextDiv = document.createElement('div');

                    if (message.role === 'user') {
                        messageDiv.className = 'message sent';
                    } else if (message.role === 'assistant') {
                        messageDiv.className = 'message received';

                        const iconPath = `${resourcePath}/oasis/${icon_name}`;
                        const iconDiv = document.createElement('div');
                        iconDiv.className = 'icon';
                        iconDiv.style.backgroundImage = `url(${iconPath})`;

                        messageDiv.appendChild(iconDiv);
                    }

                    if (message.role === 'user' || message.role === 'assistant') {
                        messageTextDiv.className = 'message-text';
                        message.content = sanitizeHTML(convertMarkdownToHTML(message.content));
                        messageTextDiv.innerHTML = message.content;
                        //messageTextDiv.textContent = message.content;

                        messageDiv.appendChild(messageTextDiv);

                        chatMessagesContainer.appendChild(messageDiv);
                    }
                });
                // Scroll to the latest message after history is rendered
                keepLatestMessageVisible(true);
            } 
            
            //else {
            //    console.error("Unexpected data format:", data);
            //}
        })
        .catch(error => {
            console.error('Error:', error);
        });
        targetChatId = chatId;
        // Lock System Message selection once a chat is active
        const sysmsgSelect = document.getElementById('sysmsg-select');
        const inlineSys = document.getElementById('inline-sysmsg-select');
        if (sysmsgSelect) sysmsgSelect.disabled = true;
        if (inlineSys) inlineSys.disabled = true;
    }

    async function new_chat_action() {
        if (activeConversation || message_outputing) {
            return;
        }

        targetChatId = "";
        // Re-enable System Message selection only for new chat
        const sysmsgSelect = document.getElementById('sysmsg-select');
        const inlineSys = document.getElementById('inline-sysmsg-select');
        if (sysmsgSelect) sysmsgSelect.disabled = false;
        if (inlineSys) inlineSys.disabled = false;
        // Sync mirrors (inline/mobile) with desktop state
        if (typeof updateMobileBottomSheetFromDesktop === 'function') {
            updateMobileBottomSheetFromDesktop();
        }

        const chatMessagesContainer = document.querySelector('.chat-messages');

        if (chatMessagesContainer) {
            const systemMessage = document.getElementById("oasis-system");
            if (systemMessage !== null) {
                chatMessagesContainer.removeChild(systemMessage);
            }
            const messages = chatMessagesContainer.querySelectorAll('.message.sent, .message.received');
            messages.forEach(message => message.remove());
        }
    }

    (function(){
        const smpNewButton = document.getElementById('smp-new-button');
        if (smpNewButton) {
            smpNewButton.addEventListener('click', async function() {
                await new_chat_action();
            });
        }
    })();

    document.getElementById('new-button').addEventListener('click', async function() {
        await new_chat_action();
    });

    document.getElementById('import-chat-data').addEventListener('change', function(event) {
        const file = event.target.files[0];
        if (file) {
            if (!isValidChatImportFile(file)) {
                event.target.value = '';
                return;
            }
            const importBtn = document.getElementById('import-button');
            const prevText = importBtn ? importBtn.textContent : '';
            if (importBtn) { importBtn.disabled = true; importBtn.textContent = t('downloading', 'Downloading...'); }
            const reader = new FileReader();
            reader.onload = function(e) {

                const base64Data = e.target.result.split(",")[1];
 
                fetch(URL_IMPORT_CHAT, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: new URLSearchParams({ chat_data: base64Data })
                })
                .then(response => response.json())
                .then(data => {

                    if (data.error) {
                        alert(t('unexpectedFormat', 'Unexpected data format'));
                        return;
                    }

                    // Reflect the added chat in the list (common function)
                    const importedTitle = (data.title && String(data.title).length) ? data.title : '--';
                    addChatListEntry(data.id, importedTitle);

                    const itemCount = (chatList !== null) ? chatList.item.length : 0;
                    if (itemCount === 0) {
                        chatList = { item:[] };  
                    }
                    chatList.item.push({id: data.id, title: importedTitle});
                    // Refresh mobile bottom sheet list after import
                    if (typeof window.updateMobileBottomSheetFromDesktop === 'function') {
                        window.updateMobileBottomSheetFromDesktop();
                        const mbList = document.getElementById('mb-chat-list');
                        if (mbList && mbList.lastElementChild) {
                            mbList.lastElementChild.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
                        }
                        const sheetContent = document.querySelector('#mobile-bottom-sheet .sheet-content');
                        const sheet = document.getElementById('mobile-bottom-sheet');
                        if (sheet && sheet.classList.contains('show') && sheetContent) {
                            sheetContent.scrollTop = sheetContent.scrollHeight;
                        }
                    }
                })
                .catch(error => {
                    console.error('Error:', error);
                })
                .finally(() => {
                    if (importBtn) { importBtn.disabled = false; importBtn.textContent = prevText; }
                });
            };
            reader.readAsDataURL(file);
        }
    });


    const smpImportInput = document.getElementById('smp-import-chat-data');
    if (smpImportInput) smpImportInput.addEventListener('change', function(event) {
        const file = event.target.files[0];
        if (file) {
            if (!isValidChatImportFile(file)) {
                event.target.value = '';
                return;
            }
            const importBtn = document.getElementById('smp-import-button');
            const prevText = importBtn ? importBtn.textContent : '';
            if (importBtn) { importBtn.disabled = true; importBtn.textContent = t('downloading', 'Downloading...'); }
            const reader = new FileReader();
            reader.onload = function(e) {

                const base64Data = e.target.result.split(",")[1];
 
                fetch(URL_IMPORT_CHAT, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: new URLSearchParams({ chat_data: base64Data })
                })
                .then(response => response.json())
                .then(data => {

                    if (data.error) {
                        alert(t('unexpectedFormat', 'Unexpected data format'));
                        return;
                    }

                    // Reflect the added chat in the list (common function)
                    const importedTitle = (data.title && String(data.title).length) ? data.title : '--';
                    addChatListEntry(data.id, importedTitle);

                    const itemCount = (chatList !== null) ? chatList.item.length : 0;
                    if (itemCount === 0) {
                        chatList = { item:[] };  
                    }
                    chatList.item.push({id: data.id, title: importedTitle});
                    // Refresh mobile bottom sheet list after import (from sheet)
                    if (typeof window.updateMobileBottomSheetFromDesktop === 'function') {
                        window.updateMobileBottomSheetFromDesktop();
                        const mbList = document.getElementById('mb-chat-list');
                        if (mbList && mbList.lastElementChild) {
                            mbList.lastElementChild.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
                        }
                        const sheetContent = document.querySelector('#mobile-bottom-sheet .sheet-content');
                        const sheet = document.getElementById('mobile-bottom-sheet');
                        if (sheet && sheet.classList.contains('show') && sheetContent) {
                            sheetContent.scrollTop = sheetContent.scrollHeight;
                        }
                    }
                })
                .catch(error => {
                    console.error('Error:', error);
                })
                .finally(() => {
                    if (importBtn) { importBtn.disabled = false; importBtn.textContent = prevText; }
                });
            };
            reader.readAsDataURL(file);
        }
    });

    document.getElementById("ai-service-list").addEventListener("change", function(event) {
      const selected_service_index = parseInt(event.target.value, 10);
      const current_service = ai_service_list[selected_service_index];

      if (current_service) {

        fetch(URL_SELECT_AI_SERVICE, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded'
            },
            body: new URLSearchParams(
            {
                identifier: current_service.identifier,
                name: current_service.name,
                model: current_service.model
            }),
        })
        .then(response => {
          if (!response.ok) throw new Error('Transmission failure');
          return response.json();
        })
        .then(data => {
        })
        .catch(error => {
          console.error('Error:', error);
        });
      }
    });

})();
