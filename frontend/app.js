try { CONFIG; } catch(e) {
    window.CONFIG = {
        cognitoDomain: 'PLACEHOLDER',
        clientId: 'PLACEHOLDER',
        callbackUrl: window.location.origin + '/callback',
        agentEndpoint: 'PLACEHOLDER',
        region: 'us-east-1',
        userPoolId: '',
    };
}

let idToken = null;
let accessToken = null;
let userInfo = { name: 'User', initials: 'U', role: 'everyone', department: '' };
let allowedTools = [];
let auditEntries = [];
let chatInitialized = false;

const TOOL_BUTTONS = [
    { match: 'ToS-Lambda', label: 'What are the delivery conditions?', icon: 'doc', message: 'What are the delivery conditions?' },
    { match: 'Products-API-Gateway', label: 'What products do you have?', icon: 'search', message: 'What products do you have?' },
    { match: 'Sales-API-Gateway', label: 'Show me the sales data', icon: 'code', message: 'Show me the sales data' },
    { match: 'dynamodb-target', label: 'Show me customer reviews', icon: 'chat', message: 'Show me customer reviews' },
    { match: 'Inventory-MCP-Target', label: 'Check the inventory levels', icon: 'people', message: 'Check the inventory levels' },
];

const ICONS = {
    doc: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg>',
    code: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>',
    chat: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>',
    people: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>',
    ai: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.22.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>',
};

function getCookie(name) {
    var match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
    return match ? match[2] : null;
}

function decodeJwt(token) {
    try {
        var parts = token.split('.');
        if (parts.length !== 3) return {};
        var payload = parts[1].replace(/-/g, '+').replace(/_/g, '/');
        while (payload.length % 4) payload += '=';
        return JSON.parse(atob(payload));
    } catch (e) {
        return {};
    }
}

function parseUserInfo() {
    var token = idToken || getCookie('id_token') || sessionStorage.getItem('id_token');
    if (!token) return;
    idToken = token;
    var claims = decodeJwt(token);
    var name = claims['cognito:username'] || claims.email || claims.sub || 'User';
    var nameParts = name.replace(/\./g, ' ').split(' ');
    var initials = nameParts.map(function(p) { return p[0]; }).join('').toUpperCase().slice(0, 2);
    userInfo = {
        name: name,
        initials: initials || 'U',
        role: claims['custom:role'] || 'everyone',
        department: claims['custom:department'] || '',
    };
}

function showChat() {
    if (chatInitialized) return;
    chatInitialized = true;

    var chatScreen = document.getElementById('chat-screen');
    chatScreen.style.display = 'block';

    var roleLabel = userInfo.role.charAt(0).toUpperCase() + userInfo.role.slice(1);
    var region = CONFIG.region === 'us-east-1' ? 'US-East' : CONFIG.region;
    document.getElementById('user-info').textContent =
        'Signed in as ' + userInfo.name + ' (' + roleLabel + ', ' + region + ')';

    addMessage('Welcome! I can help you with products, sales data, inventory, customer reviews, and terms of service.', 'system');
    document.getElementById('message-input').focus();
}

function updateUserDisplay() {
    var roleLabel = userInfo.role.charAt(0).toUpperCase() + userInfo.role.slice(1);
    var region = CONFIG.region === 'us-east-1' ? 'US-East' : CONFIG.region;
    document.getElementById('user-info').textContent =
        'Signed in as ' + userInfo.name + ' (' + roleLabel + ', ' + region + ')';
}

function exchangeCodeForTokens(code) {
    fetch('https://' + CONFIG.cognitoDomain + '/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            grant_type: 'authorization_code',
            client_id: CONFIG.clientId,
            code: code,
            redirect_uri: CONFIG.callbackUrl,
        }),
    })
    .then(function(resp) { return resp.json(); })
    .then(function(data) {
        if (data.id_token) {
            idToken = data.id_token;
            accessToken = data.access_token;
            sessionStorage.setItem('id_token', idToken);
            sessionStorage.setItem('access_token', accessToken);
            document.cookie = 'id_token=' + idToken + '; path=/; secure; samesite=lax';
            document.cookie = 'access_token=' + accessToken + '; path=/; secure; samesite=lax';
            parseUserInfo();
            updateUserDisplay();
            window.history.replaceState({}, '', '/');
        }
    })
    .catch(function(err) {
        console.error('Token exchange error:', err);
    });
}

function init() {
    parseUserInfo();
    showChat();

    var params = new URLSearchParams(window.location.search);
    var code = params.get('code');
    if (code) {
        exchangeCodeForTokens(code);
    }
}

function switchTab(tab) {
    document.getElementById('tab-agent').classList.toggle('active', tab === 'agent');
    document.getElementById('tab-audit').classList.toggle('active', tab === 'audit');
    document.getElementById('panel-agent').style.display = tab === 'agent' ? 'flex' : 'none';
    document.getElementById('panel-audit').style.display = tab === 'audit' ? 'flex' : 'none';
}

function renderQuickActions() {
    var container = document.getElementById('quick-actions');
    container.innerHTML = '';
    TOOL_BUTTONS.forEach(function(btn) {
        var hasAccess = allowedTools.some(function(t) { return t.indexOf(btn.match) === 0; });
        if (!hasAccess) return;
        var el = document.createElement('button');
        el.className = 'quick-action-btn';
        el.innerHTML = ICONS[btn.icon] + ' ' + btn.label;
        el.onclick = function() {
            document.getElementById('message-input').value = btn.message;
            sendMessage();
        };
        container.appendChild(el);
    });
}

function renderMarkdown(text) {
    var html = text
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
        .replace(/^[\s]*[-*•]\s+(.+)$/gm, '<li>$1</li>')
        .replace(/\n{2,}/g, '</p><p>')
        .replace(/\n/g, '<br>');
    if (html.indexOf('<li>') >= 0) {
        html = html.replace(/(<li>[\s\S]*?<\/li>)/g, '<ul>$1</ul>');
    }
    html = '<p>' + html + '</p>';
    html = html.replace(/<p><\/p>/g, '');
    return html;
}

function escapeHtml(text) {
    var div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function addMessage(text, type) {
    var container = document.getElementById('chat-container');
    var msg = document.createElement('div');
    msg.className = 'message ' + type;

    if (type === 'user') {
        msg.innerHTML =
            '<div class="avatar user-avatar">' + userInfo.initials + '</div>' +
            '<div class="bubble">' + escapeHtml(text) + '</div>';
    } else if (type === 'agent') {
        msg.innerHTML =
            '<div class="avatar agent-avatar">' + ICONS.ai + '</div>' +
            '<div class="bubble">' + renderMarkdown(text) + '</div>';
    } else {
        msg.innerHTML = '<div class="bubble">' + escapeHtml(text) + '</div>';
    }

    container.appendChild(msg);
    container.scrollTop = container.scrollHeight;
    return msg;
}

function showTyping() {
    var container = document.getElementById('chat-container');
    var indicator = document.createElement('div');
    indicator.className = 'typing-indicator';
    indicator.id = 'typing';
    indicator.innerHTML =
        '<div class="avatar agent-avatar">' + ICONS.ai + '</div>' +
        '<div class="typing-dots"><span></span><span></span><span></span></div>';
    container.appendChild(indicator);
    container.scrollTop = container.scrollHeight;
}

function hideTyping() {
    var el = document.getElementById('typing');
    if (el) el.remove();
}

function addAuditEntries(entries) {
    if (!entries || !entries.length) return;
    auditEntries = auditEntries.concat(entries);
    document.getElementById('audit-count').textContent = auditEntries.length;

    var tbody = document.getElementById('audit-body');
    var empty = document.getElementById('audit-empty');
    if (empty) empty.style.display = 'none';

    entries.forEach(function(entry) {
        var tr = document.createElement('tr');
        var ts = new Date(entry.timestamp).toLocaleTimeString();
        var cls = entry.decision.toLowerCase();
        tr.innerHTML =
            '<td>' + ts + '</td>' +
            '<td>' + escapeHtml(entry.tool) + '</td>' +
            '<td><span class="decision-badge ' + cls + '">' + entry.decision + '</span></td>';
        tbody.appendChild(tr);
    });
}

function logout() {
    sessionStorage.clear();
    document.cookie = 'id_token=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT';
    document.cookie = 'access_token=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT';
    idToken = null;
    accessToken = null;
    window.location.href = 'https://' + CONFIG.cognitoDomain + '/logout' +
        '?client_id=' + CONFIG.clientId +
        '&logout_uri=' + encodeURIComponent(window.location.origin);
}

function sendMessage() {
    var input = document.getElementById('message-input');
    var text = input.value.trim();
    if (!text) return;

    input.value = '';
    addMessage(text, 'user');
    document.getElementById('send-btn').disabled = true;
    showTyping();

    fetch(CONFIG.agentEndpoint, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + (accessToken || idToken),
        },
        body: JSON.stringify({
            message: text,
            user_sub: userInfo.name,
            user_role: userInfo.role,
        }),
    })
    .then(function(resp) {
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        return resp.json();
    })
    .then(function(data) {
        hideTyping();
        var body = data;
        if (typeof body.body === 'string') {
            try { body = JSON.parse(body.body); } catch(e) {}
        }

        addMessage(body.response || 'No response received.', 'agent');

        if (body.allowed_tools) {
            allowedTools = body.allowed_tools;
            renderQuickActions();
        }

        if (body.audit_log) {
            addAuditEntries(body.audit_log);
        }
    })
    .catch(function(err) {
        hideTyping();
        console.error('Send error:', err);
        addMessage('Connection error: ' + err.message, 'system');
    })
    .finally(function() {
        document.getElementById('send-btn').disabled = false;
        input.focus();
    });
}

window.addEventListener('DOMContentLoaded', init);
