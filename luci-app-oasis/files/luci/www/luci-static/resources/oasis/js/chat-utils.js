(function(global) {
    'use strict';

    function escapeHTML(str) {
        return String(str || '')
            .replace(/&/g, "&amp;")
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

    // Utility to extract complete JSON objects from a stream buffer
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

    global.OasisChatUtils = {
        escapeHTML,
        sanitizeHTML,
        convertMarkdownToHTML,
        extractJsonObjects
    };
})(window);
