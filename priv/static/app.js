(() => {
  'use strict';

  const $ = (q, r = document) => r.querySelector(q);
  const $$ = (q, r = document) => [...r.querySelectorAll(q)];
  const app = $('#app');

  const S = {
    me: null,
    csrf: '',
    forums: [],
    servers: [],
    convs: [],
    friends: [],
    notifs: [],
    route: '',
    active: { kind: 'home' },
    drafts: JSON.parse(localStorage.pw_drafts || '{}'),
    msg: [],
    ws: null,
    subs: new Set(),
    lastSync: 0,
    serverCache: {},
    embedCache: {},
    voice: {
      mode: null,
      id: null,
      stream: null,
      peers: new Map(),
      users: new Map(),
      muted: false,
      deafened: false
    },
    callUI: {
      incoming: null,
      outgoing: null
    }
  };

  const TAB = {
    id: crypto.randomUUID(),
    bc: typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel('pw-relay') : null,
    isLeader: false,
    pingTimer: null
  };

  const esc = (s) =>
    String(s ?? '').replace(/[&<>"']/g, (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
    );

  const ago = (t) => {
    if (!t) return 'never';
    let s = Math.max(1, Math.floor((Date.now() - t) / 1000));
    if (s < 60) return s + 's';
    let m = Math.floor(s / 60);
    if (m < 60) return m + 'm';
    let h = Math.floor(m / 60);
    if (h < 24) return h + 'h';
    return Math.floor(h / 24) + 'd';
  };

  const fmt = (t) =>
    new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

  const saveDrafts = () => {
    localStorage.pw_drafts = JSON.stringify(S.drafts);
  };

  async function api(method, path, body) {
    const opt = { method, headers: { accept: 'application/json' } };
    if (body !== undefined) {
      opt.headers['content-type'] = 'application/json';
      opt.headers['x-csrf-token'] = S.csrf;
      opt.body = JSON.stringify(body);
    }
    const r = await fetch('/api' + path, opt);
    const j = await r.json().catch(() => ({ ok: false, error: 'bad_json' }));
    if (!j.ok) throw Object.assign(new Error(j.error || 'request_failed'), { status: r.status });
    return j.data;
  }

  function go(h) {
    location.hash = h;
  }

  function imgSrc(src) {
    if (!src) return '';
    if (src.startsWith('/api/media/') || src.startsWith('data:')) return esc(src);
    return esc(src);
  }

  function avatar(u, cls = '') {
    const src = u && u.avatar_url;
    if (src) return `<img class="avatar ${cls}" src="${imgSrc(src)}" alt="" loading="lazy">`;
    const n = (u?.display_name || u?.username || '?').slice(0, 1).toUpperCase();
    return `<div class="avatar ${cls}">${esc(n)}</div>`;
  }

  function iconServer(s) {
    if (s?.icon_url) return `<img class="server-icon" src="${imgSrc(s.icon_url)}" alt="" loading="lazy">`;
    return `<div class="server-icon">${esc((s?.name || '?').slice(0, 1).toUpperCase())}</div>`;
  }

  function toast(t) {
    const n = document.createElement('div');
    n.className = 'toast';
    n.textContent = t;
    document.body.appendChild(n);
    setTimeout(() => n.remove(), 2600);
  }

  function statusDot(u) {
    const online = u?.status === 'online' || (u?.last_seen && Date.now() - u.last_seen < 120000);
    return `<span class="status-dot ${online ? '' : 'offline'}"></span>`;
  }

  function membersPanel(members) {
    if (!members?.length) return '';
    const groups = { owner: [], admin: [], member: [] };
    for (const m of members) {
      const role = m.role || 'member';
      (groups[role] || groups.member).push(m);
    }
    const renderGroup = (title, list) => {
      if (!list.length) return '';
      return `<div class="member-group"><div class="member-group-title">${esc(title)} — ${list.length}</div>${list
        .map(
          (m) =>
            `<a class="row" data-go="#profile/${m.user.id}">${statusDot(m.user)}${avatar(m.user)}<div class="grow"><b>${esc(m.user.display_name)}</b><small class="muted">${esc(m.user.status || m.role)}</small></div></a>`
        )
        .join('')}</div>`;
    };
    return `<aside class="right members-panel"><h3>Members</h3><div class="list">${renderGroup('Owner', groups.owner)}${renderGroup('Admins', groups.admin)}${renderGroup('Members', groups.member)}</div><div id="voiceBox" class="voice"></div></aside>`;
  }

  function shell(main, side = '', right = '') {
    return `<div class="layout"><nav class="rail"><div class="mark" title="Plainwire"></div><button class="rail-btn ${S.active.kind === 'home' ? 'active' : ''}" data-go="#">⌂</button><button class="rail-btn ${S.active.kind === 'forum' ? 'active' : ''}" data-go="#forums">F</button><button class="rail-btn ${S.active.kind === 'dm' ? 'active' : ''}" data-go="#dms">D</button><button class="rail-btn ${S.active.kind === 'friends' ? 'active' : ''}" data-go="#friends">+</button><div class="rail-spacer"></div>${S.servers
      .slice(0, 8)
      .map(
        (s) =>
          `<button class="rail-btn ${S.active.serverId === s.id ? 'active' : ''}" data-go="#server/${s.id}" title="${esc(s.name)}">${iconServer(s)}</button>`
      )
      .join('')}<button class="rail-btn" data-go="#settings" title="Settings">⚙</button></nav>${side || sideDefault()}<main class="main">${main}</main>${right || rightDefault()}</div>`;
  }

  function sideDefault() {
    const unread = S.notifs.filter((n) => !n.seen).length;
    return `<aside class="side"><div class="side-head"><h1>Plainwire</h1><small>Relay v1.1</small><div class="nav-actions"><button class="btn secondary" data-go="#new-server">New server</button><button class="btn secondary" data-action="joinInvite">Join invite</button></div></div><div class="search"><input id="globalSearch" placeholder="Search users and threads"></div><div class="list"><a class="row" data-go="#notifications"><span class="badge" ${unread ? '' : 'data-zero="1"'}>${unread || ''}</span><div class="grow"><b>Notifications</b><small class="muted">live updates</small></div></a><a class="row" data-go="#friends"><span class="server-icon">+</span><div class="grow"><b>Friends</b><small class="muted">requests and contacts</small></div></a>${S.servers
      .map(
        (s) =>
          `<a class="row ${S.active.serverId === s.id ? 'active' : ''}" data-go="#server/${s.id}">${iconServer(s)}<div class="grow"><b>${esc(s.name)}</b><small class="muted">${esc(s.role)} · ${s.member_count} members</small></div></a>`
      )
      .join('')}<div class="row"><div class="grow"><b>Direct Messages</b><small class="muted">private and group chats</small></div><button class="btn secondary" data-action="newDM">New</button></div>${S.convs
      .map(
        (c) =>
          `<a class="row" data-go="#dm/${c.id}"><span class="badge" ${c.unread ? '' : 'data-zero="1"'}>${c.unread || ''}</span><div class="grow"><b>${esc(convName(c))}</b><small class="muted">${esc(c.last_body || 'No messages yet')}</small></div></a>`
      )
      .join('')}</div><div class="user-panel">${avatar(S.me)}<div class="grow"><b>${esc(S.me?.display_name || '')}</b><small>${esc(S.me?.status || 'online')}</small></div><div class="user-panel-actions"><button title="Settings" data-go="#settings">⚙</button></div></div></aside>`;
  }

  function rightDefault() {
    return `<aside class="right"><h3 style="padding:12px 18px;margin:0;font-size:12px;text-transform:uppercase;color:var(--muted)">Profile</h3><div class="pad">${avatar(S.me, 'big')}<h3>${esc(S.me?.display_name || '')}</h3><p class="muted">@${esc(S.me?.username || '')}</p><p>${esc(S.me?.bio || 'No bio set.')}</p><span class="pill">${esc(S.me?.status || 'online')}</span></div><div id="voiceBox" class="voice"></div></aside>`;
  }

  function convName(c) {
    return c.name || `Group DM ${c.id}`;
  }

  function wire() {
    $$('[data-go]').forEach((e) => {
      e.onclick = (ev) => {
        ev.preventDefault();
        go(e.dataset.go);
      };
    });
    $$('[data-action="joinInvite"]').forEach((e) => (e.onclick = joinInvite));
    $$('[data-action="newDM"]').forEach((e) => (e.onclick = newDMModal));
    const gs = $('#globalSearch');
    if (gs) {
      gs.onkeydown = (e) => {
        if (e.key === 'Enter' && gs.value.trim()) go('#search/' + encodeURIComponent(gs.value.trim()));
      };
    }
    renderVoiceBox();
  }

  /* ---- Tab / WebSocket coordination ---- */

  function electLeader() {
    const leader = localStorage.getItem('pw_ws_leader');
    const ts = +(localStorage.getItem('pw_ws_leader_ts') || 0);
    const stale = Date.now() - ts > 4000;
    if (!leader || stale) {
      localStorage.setItem('pw_ws_leader', TAB.id);
      localStorage.setItem('pw_ws_leader_ts', String(Date.now()));
    }
    TAB.isLeader = localStorage.getItem('pw_ws_leader') === TAB.id;
  }

  function touchLeader() {
    if (TAB.isLeader) localStorage.setItem('pw_ws_leader_ts', String(Date.now()));
  }

  function broadcast(type, payload) {
    TAB.bc?.postMessage({ type, payload, from: TAB.id });
  }

  if (TAB.bc) {
    TAB.bc.onmessage = (e) => {
      const { type, payload, from } = e.data || {};
      if (from === TAB.id) return;
      if (type === 'ws_event') handleEvent(payload, true);
      if (type === 'sync') silentSync(false);
      if (type === 'leader_ping') {
        if (TAB.isLeader) broadcast('leader_pong', { id: TAB.id });
      }
      if (type === 'leader_pong') {
        if (!TAB.isLeader && payload?.id) {
          localStorage.setItem('pw_ws_leader', payload.id);
          localStorage.setItem('pw_ws_leader_ts', String(Date.now()));
        }
      }
    };
  }

  document.addEventListener('visibilitychange', () => {
    electLeader();
    if (document.visibilityState === 'visible') {
      if (TAB.isLeader) connectWS();
      else {
        broadcast('leader_ping', {});
        silentSync(true);
      }
    }
  });

  window.addEventListener('storage', (e) => {
    if (e.key === 'pw_ws_leader' && e.newValue !== TAB.id && S.ws) {
      try {
        S.ws.close();
      } catch {}
      S.ws = null;
    }
  });

  setInterval(() => {
    electLeader();
    if (TAB.isLeader) {
      touchLeader();
      sendWS({ type: 'ping' });
    }
  }, 2000);

  /* ---- Boot & sync ---- */

  async function boot() {
    try {
      electLeader();
      const d = await api('GET', '/me');
      S.me = d.user;
      S.csrf = d.csrf;
      S.lastSync = d.server_time || Date.now();
      if (TAB.isLeader) connectWS();
      await silentSync(true);
      render();
      setInterval(() => {
        if (document.visibilityState === 'visible') silentSync(false);
      }, 4000);
    } catch {
      renderAuth();
    }
  }

  function renderAuth() {
    app.innerHTML = `<div class="layout"><div></div><main class="main"><div class="content"><div class="card pad" style="max-width:520px;margin:8vh auto"><h1>Plainwire Relay</h1><p class="muted">Independent forum, chat, server, and voice relay.</p><div class="tabs"><button class="btn" id="loginTab">Login</button><button class="btn secondary" id="regTab">Register</button></div><div id="authForm"></div></div></div></main></div>`;
    let mode = 'login';
    const draw = () => {
      $('#authForm').innerHTML = `<div class="field"><label>Username</label><input id="u" autocomplete="username"></div>${mode === 'register' ? '<div class="field"><label>Display name</label><input id="d"></div>' : ''}<div class="field"><label>Password</label><input id="p" type="password" autocomplete="current-password"></div><button class="btn" id="authBtn">${mode === 'login' ? 'Login' : 'Create account'}</button>`;
      $('#authBtn').onclick = async () => {
        try {
          const path = mode === 'login' ? '/login' : '/register';
          const data = await api('POST', path, {
            username: $('#u').value,
            display_name: $('#d')?.value || $('#u').value,
            password: $('#p').value
          });
          S.me = data.user;
          S.csrf = data.csrf;
          electLeader();
          if (TAB.isLeader) connectWS();
          await silentSync(true);
          render();
        } catch (e) {
          toast(e.message);
        }
      };
    };
    $('#loginTab').onclick = () => {
      mode = 'login';
      draw();
    };
    $('#regTab').onclick = () => {
      mode = 'register';
      draw();
    };
    draw();
  }

  async function silentSync(force) {
    try {
      const d = await api('GET', '/sync?since=' + S.lastSync);
      S.lastSync = d.now;
      S.notifs = d.notifications || [];
      S.convs = d.conversations || [];
      S.servers = d.servers || [];
      S.friends = d.friends || [];
      if (force || !S.me) {
        const me = await api('GET', '/me');
        S.me = me.user;
        S.csrf = me.csrf;
      }
      updateShellBits();
      await updateActiveMessages();
    } catch (e) {
      if (e.status === 401) renderAuth();
    }
  }

  function updateShellBits() {
    const unread = S.notifs.filter((n) => !n.seen).length;
    document.title = unread ? `(${unread}) Plainwire Relay` : 'Plainwire Relay';
  }

  function connectWS() {
    if (!TAB.isLeader) return;
    if (S.ws && S.ws.readyState <= 1) return;
    if (S.ws) {
      try {
        S.ws.close();
      } catch {}
    }
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(proto + '://' + location.host + '/ws');
    S.ws = ws;
    ws.onopen = () => resub();
    ws.onmessage = (e) => {
      const ev = JSON.parse(e.data);
      if (ev.type === 'pong') return;
      handleEvent(ev);
      broadcast('ws_event', ev);
    };
    ws.onclose = () => {
      S.ws = null;
      if (TAB.isLeader && document.visibilityState === 'visible') {
        setTimeout(connectWS, 1800);
      }
    };
  }

  function sendWS(o) {
    if (S.ws && S.ws.readyState === 1) S.ws.send(JSON.stringify(o));
  }

  function subscribe(k) {
    S.subs.add(k);
    sendWS({ type: 'subscribe', key: k });
  }

  function clearSubs() {
    S.subs.clear();
    sendWS({ type: 'unsubscribe_all' });
  }

  function resub() {
    for (const k of S.subs) sendWS({ type: 'subscribe', key: k });
  }

  async function handleEvent(ev, fromBc = false) {
    if (ev.type === 'notification') {
      await silentSync(false);
      if (!fromBc) toast('New notification');
      return;
    }
    if (ev.type === 'message_created') {
      const active =
        (S.active.kind === 'channel' && ev.scope === 'channel' && ev.scope_id === S.active.id) ||
        (S.active.kind === 'dm' && ev.scope === 'direct' && ev.scope_id === S.active.id);
      if (active) appendMessage(ev.message);
      else silentSync(false);
      return;
    }
    if (ev.type === 'thread_reply' && S.active.kind === 'thread' && ev.thread_id === S.active.id) {
      appendReply(ev.reply);
      return;
    }
    if (ev.type?.startsWith('voice')) return voiceEvent(ev);
    if (ev.type?.startsWith('call')) return callEvent(ev);
    if (ev.type === 'server_updated' || ev.type === 'member_joined') silentSync(false);
  }

  /* ---- Routing ---- */

  function render() {
    const h = location.hash.slice(1) || 'home';
    S.route = h;
    clearSubs();
    if (h === 'home') return renderHome();
    if (h === 'forums') return renderForums();
    if (h.startsWith('forum/')) return renderForum(+h.split('/')[1]);
    if (h.startsWith('thread/')) return renderThread(+h.split('/')[1]);
    if (h === 'dms') return renderDMs();
    if (h.startsWith('dm/')) return renderDM(+h.split('/')[1]);
    if (h === 'friends') return renderFriends();
    if (h.startsWith('profile/')) return renderProfile(+h.split('/')[1]);
    if (h === 'settings') return renderSettings();
    if (h === 'new-server') return renderNewServer();
    if (h.startsWith('server/')) return renderServer(+h.split('/')[1]);
    if (h.startsWith('channel/')) return renderChannel(+h.split('/')[1]);
    if (h.startsWith('voice/')) return renderVoiceChannel(+h.split('/')[1]);
    if (h.startsWith('invite/')) return renderInvitePage(h.split('/')[1]);
    if (h === 'notifications') return renderNotifications();
    if (h.startsWith('search/')) return renderSearch(decodeURIComponent(h.slice(7)));
    renderHome();
  }

  function renderHome() {
    S.active = { kind: 'home' };
    app.innerHTML = shell(
      `<div class="topbar"><h2>Home</h2></div><div class="content"><div class="grid"><div class="card pad"><h2>Relay</h2><p>A persistent chat/forum workspace with servers, groups, direct messages, invites, profiles, and peer-to-peer voice signaling.</p></div><div class="card pad"><h2>Unread</h2><p class="muted">${S.notifs.filter((n) => !n.seen).length} notifications · ${S.convs.reduce((a, c) => a + (c.unread || 0), 0)} direct unread</p></div><div class="card pad"><h2>Security</h2><p class="muted">External images are proxied through the relay. Message bodies are encrypted at rest when PLAINWIRE_ENC_KEY is configured.</p></div></div></div>`
    );
    wire();
  }

  async function renderForums() {
    S.active = { kind: 'forum' };
    S.forums = await api('GET', '/forums');
    app.innerHTML = shell(
      `<div class="topbar"><h2>Forums</h2><button class="btn" id="newThread">New thread</button></div><div class="content"><div class="grid">${S.forums
        .map(
          (f) =>
            `<div class="card pad" data-go="#forum/${f.id}"><h2>${esc(f.name)}</h2><p class="muted">${esc(f.description)}</p><span class="pill">${f.thread_count} threads</span> <span class="pill">${f.reply_count} replies</span></div>`
        )
        .join('')}</div></div>`
    );
    wire();
    $('#newThread').onclick = newThreadModal;
  }

  async function renderForum(id) {
    S.active = { kind: 'forum', id };
    subscribe('forum:' + id);
    const threads = await api('GET', '/threads?forum_id=' + id);
    app.innerHTML = shell(
      `<div class="topbar"><h2>Forum</h2><button class="btn" id="newThread">New thread</button></div><div class="content"><div class="card">${threads
        .map(
          (t) =>
            `<a class="row" data-go="#thread/${t.id}"><div class="grow"><b>${esc(t.title)}</b>${t.pinned ? ' <span class="pill pin">pinned</span>' : ''}${t.reply_count > 5 ? ' <span class="pill hot">hot</span>' : ''}<small class="muted">${esc(t.display_name)} · ${t.reply_count} replies · ${t.views} views · ${ago(t.updated_at)} ago</small></div></a>`
        )
        .join('') || '<div class="empty">No threads yet.</div>'}</div></div>`
    );
    wire();
    $('#newThread').onclick = () => newThreadModal(id);
  }

  function newThreadModal(fid) {
    modal(
      `<h2>New thread</h2><div class="field"><label>Forum</label><select id="forumPick">${S.forums
        .map((f) => `<option value="${f.id}" ${f.id === fid ? 'selected' : ''}>${esc(f.name)}</option>`)
        .join('')}</select></div><div class="field"><label>Title</label><input id="tTitle"></div><div class="field"><label>Body</label><textarea id="tBody" rows="8"></textarea></div><button class="btn" id="createThread">Create</button>`
    );
    $('#createThread').onclick = async () => {
      const r = await api('POST', '/threads', {
        forum_id: +$('#forumPick').value,
        title: $('#tTitle').value,
        body: $('#tBody').value
      });
      closeModal();
      go('#thread/' + r.id);
    };
  }

  async function renderThread(id) {
    S.active = { kind: 'thread', id };
    subscribe('thread:' + id);
    const d = await api('GET', '/thread/' + id);
    const t = d.thread;
    app.innerHTML = shell(
      `<div class="topbar"><h2>${esc(t.forum_name)}</h2></div><div class="content" id="threadContent"><div class="post card"><h1 class="thread-title">${esc(t.title)}</h1><div class="post-meta">${avatar(t)}<b data-go="#profile/${t.user_id}">${esc(t.display_name)}</b><span class="muted">${fmt(t.created_at)}</span></div><div class="msg-body">${formatBody(t.body)}</div></div><div id="replies">${d.replies.map(replyHtml).join('')}</div></div>${composer('thread:' + id, 'Reply to thread')}`
    );
    wire();
    wireComposer('thread:' + id);
    loadEmbedsForContainer($('#threadContent'));
  }

  function replyHtml(r) {
    return `<div class="post card" data-reply="${r.id}"><div class="post-meta">${avatar(r)}<b data-go="#profile/${r.user_id}">${esc(r.display_name)}</b><span class="muted">${fmt(r.created_at)}</span></div><div class="msg-body">${formatBody(r.body)}</div></div>`;
  }

  function appendReply(r) {
    const box = $('#replies');
    if (!box) return;
    box.insertAdjacentHTML('beforeend', replyHtml(r));
    wire();
    box.lastElementChild.scrollIntoView({ block: 'nearest' });
  }

  async function renderDMs() {
    S.active = { kind: 'dm' };
    app.innerHTML = shell(
      `<div class="topbar"><h2>Direct Messages</h2><button class="btn" data-action="newDM">New group</button></div><div class="content"><div class="card">${S.convs
        .map(
          (c) =>
            `<a class="row" data-go="#dm/${c.id}"><span class="badge" ${c.unread ? '' : 'data-zero="1"'}>${c.unread || ''}</span><div class="grow"><b>${esc(convName(c))}</b><small class="muted">${esc(c.last_body || 'No messages yet')}</small></div></a>`
        )
        .join('') || '<div class="empty">No conversations yet.</div>'}</div></div>`
    );
    wire();
  }

  async function renderDM(id) {
    S.active = { kind: 'dm', id };
    subscribe('direct:' + id);
    const info = await api('GET', '/conversation/' + id);
    const side = `<aside class="side"><div class="side-head"><h1>${esc(info.conversation.name || 'Conversation')}</h1><div class="nav-actions"><button class="btn secondary" id="addPeople">Add</button><button class="btn" id="callBtn" title="Start voice call">📞 Call</button></div></div><div class="list">${info.members
      .map(
        (m) =>
          `<a class="row" data-go="#profile/${m.user.id}">${avatar(m.user)}<div class="grow"><b>${esc(m.user.display_name)}</b><small class="muted">@${esc(m.user.username)}</small></div></a>`
      )
      .join('')}</div></aside>`;
    app.innerHTML = shell(
      `<div class="topbar"><h2>${esc(info.conversation.name || 'Direct Message')}</h2><button class="btn secondary" id="editConv">Edit</button></div><div class="messages" id="messages"></div>${composer('direct:' + id, 'Message conversation')}`,
      side
    );
    wire();
    $('#addPeople').onclick = () => addPeopleModal(id);
    $('#editConv').onclick = () => editConversationModal(info.conversation);
    $('#callBtn').onclick = () => startCall(id, info);
    await loadMessages('direct', id);
    wireComposer('direct:' + id);
  }

  async function getServerData(id) {
    if (S.serverCache[id]) return S.serverCache[id];
    const d = await api('GET', '/server/' + id);
    S.serverCache[id] = d;
    return d;
  }

  async function renderServer(id) {
    S.active = { kind: 'server', serverId: id };
    subscribe('server:' + id);
    const d = await getServerData(id);
    const s = d.server;
    const side = `<aside class="side"><div class="side-head">${iconServer(s)}<h1>${esc(s.name)}</h1><small>${esc(s.description)}</small><div class="nav-actions"><button class="btn secondary" id="inviteBtn">Invite</button><button class="btn secondary" id="newChannel">Channel</button><button class="btn secondary" id="editServer">Edit</button></div></div><div class="list">${d.channels
      .map(
        (c) =>
          `<a class="row" data-go="${c.kind === 'voice' ? '#voice/' + c.id : '#channel/' + c.id}"><span class="server-icon">${c.kind === 'voice' ? '♪' : '#'}</span><div class="grow"><b>${esc(c.name)}</b><small class="muted">${esc(c.kind)}</small></div></a>`
      )
      .join('')}</div></aside>`;
    const right = membersPanel(d.members);
    app.innerHTML = shell(
      `<div class="topbar"><h2>${esc(s.name)}</h2></div><div class="content"><div class="card pad"><h2>Welcome</h2><p class="muted">${esc(s.description)}</p><p>Select a text channel or voice channel from the sidebar.</p></div></div>`,
      side,
      right
    );
    wire();
    $('#inviteBtn').onclick = () => inviteModal(id);
    $('#newChannel').onclick = () => channelModal(id);
    $('#editServer').onclick = () => editServerModal(s);
  }

  async function renderChannel(id) {
    S.active = { kind: 'channel', id };
    subscribe('channel:' + id);
    const d = await findServerForChannel(id);
    S.active.serverId = d.server.id;
    const ch = d.channels.find((c) => c.id === id);
    const side = `<aside class="side"><div class="side-head"><h1>${esc(d.server.name)}</h1><button class="btn secondary" data-go="#server/${d.server.id}">Back</button></div><div class="list">${d.channels
      .map(
        (c) =>
          `<a class="row ${c.id === id ? 'active' : ''}" data-go="${c.kind === 'voice' ? '#voice/' + c.id : '#channel/' + c.id}"><span class="server-icon">${c.kind === 'voice' ? '♪' : '#'}</span><div class="grow"><b>${esc(c.name)}</b></div></a>`
      )
      .join('')}</div></aside>`;
    const right = membersPanel(d.members);
    app.innerHTML = shell(
      `<div class="topbar"><h2># ${esc(ch?.name || 'channel')}</h2><button class="btn secondary" id="inviteBtn">Invite</button></div><div class="messages" id="messages"></div>${composer('channel:' + id, 'Message #' + (ch?.name || ''))}`,
      side,
      right
    );
    wire();
    $('#inviteBtn').onclick = () => inviteModal(d.server.id);
    await loadMessages('channel', id);
    wireComposer('channel:' + id);
  }

  async function renderVoiceChannel(id) {
    const d = await findServerForChannel(id);
    S.active = { kind: 'voice', id, serverId: d.server.id };
    const ch = d.channels.find((c) => c.id === id);
    const side = `<aside class="side"><div class="side-head"><h1>${esc(d.server.name)}</h1><button class="btn secondary" data-go="#server/${d.server.id}">Back</button></div><div class="list">${d.channels
      .map(
        (c) =>
          `<a class="row ${c.id === id ? 'active' : ''}" data-go="${c.kind === 'voice' ? '#voice/' + c.id : '#channel/' + c.id}"><span class="server-icon">${c.kind === 'voice' ? '♪' : '#'}</span><div class="grow"><b>${esc(c.name)}</b></div></a>`
      )
      .join('')}</div></aside>`;
    const right = membersPanel(d.members);
    app.innerHTML = shell(
      `<div class="topbar"><h2>♪ ${esc(ch?.name || 'voice')}</h2><button class="btn" id="joinV">Join voice</button></div><div class="content"><div class="card pad"><h2>Voice channel</h2><p class="muted">Peer-to-peer audio uses WebRTC signaling through the Erlang WebSocket hub.</p></div></div>`,
      side,
      right
    );
    wire();
    $('#joinV').onclick = () => joinVoice(id);
  }

  async function findServerForChannel(cid) {
    for (const s of S.servers) {
      try {
        const d = await getServerData(s.id);
        if (d.channels.some((c) => c.id === cid)) return d;
      } catch {}
    }
    throw Error('channel not found');
  }

  async function renderInvitePage(code) {
    S.active = { kind: 'invite' };
    try {
      const preview = await api('GET', '/invites/' + encodeURIComponent(code));
      const srv = preview.server;
      app.innerHTML = shell(
        `<div class="content"><div class="card pad invite-card">${iconServer({ name: srv.name, icon_url: srv.icon_url })}<h1>${esc(srv.name)}</h1><p class="muted">${esc(srv.description)}</p><p class="muted">${srv.member_count} members</p>${preview.valid ? `<button class="btn" id="joinInviteBtn">Accept invite</button>` : '<p class="muted">This invite is no longer valid.</p>'}<button class="btn secondary" data-go="#">Back home</button></div></div>`
      );
      wire();
      if (preview.valid) {
        $('#joinInviteBtn').onclick = async () => {
          const r = await api('POST', '/invites/' + encodeURIComponent(code) + '/join', {});
          delete S.serverCache[r.server_id];
          await silentSync(true);
          go('#server/' + r.server_id);
        };
      }
    } catch (e) {
      app.innerHTML = shell(`<div class="content"><div class="card pad invite-card"><h2>Invalid invite</h2><p class="muted">${esc(e.message)}</p><button class="btn secondary" data-go="#">Back home</button></div></div>`);
      wire();
    }
  }

  async function renderFriends() {
    S.active = { kind: 'friends' };
    app.innerHTML = shell(
      `<div class="topbar"><h2>Friends</h2><button class="btn" id="findUser">Find user</button></div><div class="content"><div class="card">${S.friends
        .map(
          (f) =>
            `<div class="row"><div data-go="#profile/${f.user.id}">${avatar(f.user)}</div><div class="grow"><b>${esc(f.user.display_name)}</b><small class="muted">@${esc(f.user.username)} · ${esc(f.status)}${f.incoming ? ' · incoming' : ''}</small></div>${f.incoming ? `<button class="btn" data-accept="${f.user.id}">Accept</button>` : ''}<button class="btn secondary" data-call="${f.user.id}">📞</button><button class="btn secondary" data-dm="${f.user.id}">DM</button></div>`
        )
        .join('') || '<div class="empty">No friends yet.</div>'}</div></div>`
    );
    wire();
    $('#findUser').onclick = searchUsersModal;
    $$('[data-accept]').forEach((b) => {
      b.onclick = async () => {
        await api('POST', '/friends/accept', { user_id: +b.dataset.accept });
        await silentSync(true);
        renderFriends();
      };
    });
    $$('[data-dm]').forEach((b) => {
      b.onclick = async () => {
        const r = await api('POST', '/conversations', { user_ids: [+b.dataset.dm], name: '' });
        go('#dm/' + r.id);
      };
    });
    $$('[data-call]').forEach((b) => {
      b.onclick = async () => {
        const r = await api('POST', '/conversations', { user_ids: [+b.dataset.call], name: '' });
        startCall(r.id);
      };
    });
  }

  async function renderProfile(id) {
    const p = await api('GET', '/profile/' + id);
    const u = p.user;
    app.innerHTML = shell(
      `<div class="topbar"><h2>Profile</h2></div><div class="content"><div class="card profile"><div class="banner" style="${u.banner_url ? `background-image:url('${imgSrc(u.banner_url)}');background-size:cover` : ''}"></div><div class="profile-body">${avatar(u, 'big')}<div><h1>${esc(u.display_name)}</h1><p class="muted">@${esc(u.username)} · seen ${ago(u.last_seen)} ago</p><p>${esc(u.bio || 'No bio set.')}</p><p><span class="pill">${esc(u.status || '')}</span> <span class="pill">${esc(p.relationship.status || 'none')}</span></p>        <div style="display:flex;gap:10px;margin-top:12px;flex-wrap:wrap"><button class="btn" id="addFriend">Friend</button><button class="btn secondary" id="callUser">Call</button><button class="btn secondary" id="dmUser">Message</button></div></div></div></div></div>`
    );
    wire();
    $('#addFriend').onclick = async () => {
      await api('POST', '/friends/request', { user_id: id });
      toast('Request sent');
    };
    $('#callUser').onclick = async () => {
      const r = await api('POST', '/conversations', { user_ids: [id], name: '' });
      startCall(r.id);
    };
    $('#dmUser').onclick = async () => {
      const r = await api('POST', '/conversations', { user_ids: [id], name: '' });
      go('#dm/' + r.id);
    };
  }

  async function renderSettings() {
    const u = S.me;
    app.innerHTML = shell(
      `<div class="topbar"><h2>Settings</h2><button class="btn danger" id="logout">Logout</button></div><div class="content"><div class="card pad"><h2>Profile</h2><div class="field"><label>Display name</label><input id="display" value="${esc(u.display_name)}"></div><div class="field"><label>Status</label><input id="status" value="${esc(u.status || '')}" placeholder="online, away, busy"></div><div class="field"><label>Bio</label><textarea id="bio" rows="5">${esc(u.bio || '')}</textarea></div><div class="field"><label>Avatar URL (proxied through relay)</label><input id="avatar" value="${esc(u.avatar_url || '')}"><input type="file" id="avatarFile" accept="image/*"></div><div class="field"><label>Banner URL (proxied through relay)</label><input id="banner" value="${esc(u.banner_url || '')}"><input type="file" id="bannerFile" accept="image/*"></div><button class="btn" id="saveProfile">Save</button></div></div>`
    );
    wire();
    $('#logout').onclick = async () => {
      await api('POST', '/logout', {});
      location.reload();
    };
    $('#avatarFile').onchange = (e) => readImage(e.target.files[0], $('#avatar'));
    $('#bannerFile').onchange = (e) => readImage(e.target.files[0], $('#banner'));
    $('#saveProfile').onclick = async () => {
      await api('POST', '/profile', {
        display_name: $('#display').value,
        status: $('#status').value,
        bio: $('#bio').value,
        avatar_url: $('#avatar').value,
        banner_url: $('#banner').value
      });
      await silentSync(true);
      renderSettings();
    };
  }

  function readImage(file, input) {
    if (!file || file.size > 260000) return toast('Image too large; use under 260 KB');
    const r = new FileReader();
    r.onload = () => (input.value = r.result);
    r.readAsDataURL(file);
  }

  async function renderNewServer() {
    S.active = { kind: 'server' };
    app.innerHTML = shell(
      `<div class="topbar"><h2>Create server</h2></div><div class="content"><div class="card pad"><div class="field"><label>Name</label><input id="sName"></div><div class="field"><label>Description</label><textarea id="sDesc"></textarea></div><button class="btn" id="createServer">Create</button></div></div>`
    );
    wire();
    $('#createServer').onclick = async () => {
      const r = await api('POST', '/servers', { name: $('#sName').value, description: $('#sDesc').value });
      await silentSync(true);
      go('#server/' + r.id);
    };
  }

  async function renderNotifications() {
    S.active = { kind: 'home' };
    app.innerHTML = shell(
      `<div class="topbar"><h2>Notifications</h2><button class="btn secondary" id="seen">Mark seen</button></div><div class="content"><div class="card">${S.notifs
        .map(
          (n) =>
            `<a class="row notif ${n.seen ? '' : 'unseen'}" data-go="${esc(n.url)}"><div class="grow"><b>${esc(n.kind)}</b><small>${esc(n.body)}</small></div><span class="muted">${ago(n.created_at)} ago</span></a>`
        )
        .join('') || '<div class="empty">No notifications.</div>'}</div></div>`
    );
    wire();
    $('#seen').onclick = async () => {
      await api('POST', '/notifications/seen', {});
      await silentSync(true);
      renderNotifications();
    };
  }

  async function renderSearch(q) {
    const users = await api('GET', '/users?q=' + encodeURIComponent(q));
    const threads = await api('GET', '/threads?q=' + encodeURIComponent(q));
    app.innerHTML = shell(
      `<div class="topbar"><h2>Search: ${esc(q)}</h2></div><div class="content"><h3>Users</h3><div class="card">${users
        .map(
          (u) =>
            `<a class="row" data-go="#profile/${u.id}">${avatar(u)}<div><b>${esc(u.display_name)}</b><small class="muted">@${esc(u.username)}</small></div></a>`
        )
        .join('') || '<div class="empty">No users.</div>'}</div><h3>Threads</h3><div class="card">${threads
        .map(
          (t) =>
            `<a class="row" data-go="#thread/${t.id}"><div><b>${esc(t.title)}</b><small class="muted">${esc(t.forum_name)}</small></div></a>`
        )
        .join('') || '<div class="empty">No threads.</div>'}</div></div>`
    );
    wire();
  }

  /* ---- Messages & embeds ---- */

  async function loadMessages(scope, id, after) {
    const q = `/messages?scope=${scope}&scope_id=${id}` + (after ? '&after=' + after : '');
    const msgs = await api('GET', q);
    if (!after) {
      S.msg = msgs.reverse();
      renderMessages();
    } else {
      msgs.forEach(appendMessage);
    }
  }

  async function updateActiveMessages() {
    const a = S.active;
    if (!$('#messages')) return;
    const last = S.msg[S.msg.length - 1]?.id;
    if (a.kind === 'channel' && last) await loadMessages('channel', a.id, last);
    if (a.kind === 'dm' && last) await loadMessages('direct', a.id, last);
  }

  function renderMessages() {
    const box = $('#messages');
    if (!box) return;
    box.innerHTML =
      S.msg.map((m, i) => msgHtml(m, S.msg[i - 1])).join('') || '<div class="empty">No messages yet.</div>';
    box.scrollTop = box.scrollHeight;
    wire();
    loadEmbedsForContainer(box);
  }

  const URL_RE = /https?:\/\/[^\s<>"']+/g;

  function formatBody(body) {
    const safe = esc(body);
    return safe.replace(URL_RE, (url) => `<a href="${url}" target="_blank" rel="noopener noreferrer nofollow">${url}</a>`);
  }

  function extractUrls(body) {
    return [...new Set((body || '').match(URL_RE) || [])].slice(0, 2);
  }

  async function fetchEmbed(url) {
    if (S.embedCache[url]) return S.embedCache[url];
    try {
      const meta = await api('GET', '/embed?url=' + encodeURIComponent(url));
      S.embedCache[url] = meta;
      return meta;
    } catch {
      return null;
    }
  }

  function embedHtml(meta) {
    if (!meta?.title && !meta?.description) return '';
    const img = meta.image ? `<img src="${imgSrc(meta.image)}" alt="" loading="lazy">` : '';
    return `<a class="embed" href="${esc(meta.url)}" target="_blank" rel="noopener noreferrer">${img}<div class="embed-body"><div class="embed-site">${esc(meta.site_name || '')}</div><div class="embed-title">${esc(meta.title || meta.url)}</div><div class="embed-desc">${esc(meta.description || '')}</div></div></a>`;
  }

  async function loadEmbedsForContainer(container) {
    if (!container) return;
    const nodes = container.querySelectorAll('.msg-body, .post .msg-body');
    for (const node of nodes) {
      if (node.dataset.embedsLoaded) continue;
      node.dataset.embedsLoaded = '1';
      const urls = extractUrls(node.textContent);
      for (const url of urls) {
        const meta = await fetchEmbed(url);
        if (meta) node.insertAdjacentHTML('beforeend', embedHtml(meta));
      }
    }
  }

  function msgHtml(m, prev) {
    const same = prev && prev.user_id === m.user_id && m.created_at - prev.created_at < 300000;
    return `<div class="msg ${same ? 'compact' : ''}" data-mid="${m.id}">${avatar(m)}<div>${same ? '' : `<div class="msg-head"><span class="msg-name" data-go="#profile/${m.user_id}">${esc(m.display_name)}</span><span class="msg-time">${fmt(m.created_at)}</span></div>`}<div class="msg-body">${formatBody(m.body)}</div></div></div>`;
  }

  function appendMessage(m) {
    if (S.msg.some((x) => x.id === m.id)) return;
    const box = $('#messages');
    if (!box) return;
    const near = box.scrollHeight - box.scrollTop - box.clientHeight < 160;
    if (box.querySelector('.empty')) box.innerHTML = '';
    const prev = S.msg[S.msg.length - 1];
    S.msg.push(m);
    box.insertAdjacentHTML('beforeend', msgHtml(m, prev));
    wire();
    const lastBody = box.lastElementChild?.querySelector('.msg-body');
    if (lastBody) {
      lastBody.dataset.embedsLoaded = '';
      loadEmbedsForContainer(box.lastElementChild);
    }
    if (near) box.scrollTop = box.scrollHeight;
  }

  function composer(key, ph) {
    return `<div class="composer"><textarea id="compose" placeholder="${esc(ph)}">${esc(S.drafts[key] || '')}</textarea><button class="btn" id="sendBtn">Send</button></div>`;
  }

  function wireComposer(key) {
    const ta = $('#compose');
    const btn = $('#sendBtn');
    if (!ta || !btn) return;
    ta.oninput = () => {
      S.drafts[key] = ta.value;
      saveDrafts();
    };
    ta.onkeydown = (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        btn.click();
      }
    };
    btn.onclick = async () => {
      const body = ta.value.trim();
      if (!body) return;
      ta.value = '';
      S.drafts[key] = '';
      saveDrafts();
      try {
        if (key.startsWith('channel:'))
          appendMessage(await api('POST', '/channels/' + key.split(':')[1] + '/messages', { body }));
        else if (key.startsWith('direct:'))
          appendMessage(await api('POST', '/conversation/' + key.split(':')[1] + '/messages', { body }));
        else appendReply(await api('POST', '/thread/' + key.split(':')[1] + '/replies', { body }));
      } catch (e) {
        toast(e.message);
      }
    };
  }

  /* ---- Modals ---- */

  function modal(body) {
    closeModal();
    const d = document.createElement('div');
    d.className = 'modal';
    d.innerHTML = `<div class="modal-card"><div class="modal-head"><b>Plainwire</b><button class="btn ghost" id="xModal">Close</button></div><div class="pad">${body}</div></div>`;
    document.body.appendChild(d);
    $('#xModal').onclick = closeModal;
    d.onclick = (e) => {
      if (e.target === d) closeModal();
    };
  }

  function closeModal() {
    $('.modal')?.remove();
  }

  function searchUsersModal() {
    modal(`<h2>Find user</h2><input id="userQ" placeholder="username or display name"><div id="userResults"></div>`);
    $('#userQ').oninput = async (e) => {
      const q = e.target.value.trim();
      if (q.length < 2) return;
      const users = await api('GET', '/users?q=' + encodeURIComponent(q));
      $('#userResults').innerHTML = users
        .map(
          (u) =>
            `<div class="row"><div data-go="#profile/${u.id}">${avatar(u)}</div><div class="grow"><b>${esc(u.display_name)}</b><small class="muted">@${esc(u.username)}</small></div><button class="btn secondary" data-friend="${u.id}">Add</button></div>`
        )
        .join('');
      wire();
      $$('[data-friend]').forEach((b) => {
        b.onclick = async () => {
          await api('POST', '/friends/request', { user_id: +b.dataset.friend });
          toast('Request sent');
        };
      });
    };
  }

  function newDMModal() {
    modal(
      `<h2>New direct/group message</h2><p class="muted">Enter usernames separated by commas.</p><input id="dmUsers"><div class="field"><label>Group name optional</label><input id="dmName"></div><button class="btn" id="makeDM">Create</button>`
    );
    $('#makeDM').onclick = async () => {
      const names = $('#dmUsers').value.split(',').map((x) => x.trim()).filter(Boolean);
      const ids = [];
      for (const n of names) {
        const u = await api('GET', '/users?q=' + encodeURIComponent(n));
        if (u[0]) ids.push(u[0].id);
      }
      const r = await api('POST', '/conversations', { name: $('#dmName').value, user_ids: ids });
      closeModal();
      await silentSync(true);
      go('#dm/' + r.id);
    };
  }

  function addPeopleModal(id) {
    modal(`<h2>Add people</h2><p class="muted">Usernames separated by commas.</p><input id="addUsers"><button class="btn" id="addBtn">Add</button>`);
    $('#addBtn').onclick = async () => {
      const ids = [];
      for (const n of $('#addUsers').value.split(',').map((x) => x.trim()).filter(Boolean)) {
        const u = await api('GET', '/users?q=' + encodeURIComponent(n));
        if (u[0]) ids.push(u[0].id);
      }
      await api('POST', '/conversation/' + id + '/members', { user_ids: ids });
      closeModal();
      renderDM(id);
    };
  }

  function editConversationModal(c) {
    modal(
      `<h2>Edit conversation</h2><input id="cName" value="${esc(c.name || '')}"><div class="field"><label>Avatar URL</label><input id="cAvatar" value="${esc(c.avatar_url || '')}"></div><button class="btn" id="saveC">Save</button>`
    );
    $('#saveC').onclick = async () => {
      await api('POST', '/conversation/' + c.id, { name: $('#cName').value, avatar_url: $('#cAvatar').value });
      closeModal();
      renderDM(c.id);
    };
  }

  function editServerModal(s) {
    modal(
      `<h2>Edit server</h2><div class="field"><label>Name</label><input id="sEditName" value="${esc(s.name)}"></div><div class="field"><label>Description</label><textarea id="sEditDesc">${esc(s.description)}</textarea></div><div class="field"><label>Icon URL</label><input id="sEditIcon" value="${esc(s.icon_url || '')}"></div><button class="btn" id="saveServer">Save</button>`
    );
    $('#saveServer').onclick = async () => {
      await api('POST', '/server/' + s.id, {
        name: $('#sEditName').value,
        description: $('#sEditDesc').value,
        icon_url: $('#sEditIcon').value
      });
      delete S.serverCache[s.id];
      closeModal();
      renderServer(s.id);
    };
  }

  function inviteModal(sid) {
    modal(
      `<h2>Create server invite</h2><p class="muted">Share this link like Discord. 0 uses means unlimited.</p><div class="field"><label>Max uses (0 = unlimited)</label><input id="maxUses" type="number" value="0" min="0"></div><button class="btn" id="makeInvite">Create invite</button><div id="inviteOut"></div>`
    );
    $('#makeInvite').onclick = async () => {
      const r = await api('POST', '/server/' + sid + '/invites', { max_uses: +$('#maxUses').value || 0 });
      const url = location.origin + location.pathname + r.url;
      $('#inviteOut').innerHTML = `<div class="field" style="margin-top:16px"><label>Invite link</label><input value="${esc(url)}" readonly id="inviteLink"></div><button class="btn secondary" id="copyInvite">Copy link</button>`;
      $('#copyInvite').onclick = () => {
        navigator.clipboard?.writeText(url);
        toast('Invite copied');
      };
      navigator.clipboard?.writeText(url);
      toast('Invite copied');
    };
  }

  function channelModal(sid) {
    modal(
      `<h2>New channel</h2><div class="field"><label>Name</label><input id="chName" placeholder="name"></div><div class="field"><label>Kind</label><select id="chKind"><option value="text">Text</option><option value="voice">Voice</option></select></div><button class="btn" id="makeCh">Create</button>`
    );
    $('#makeCh').onclick = async () => {
      await api('POST', '/server/' + sid + '/channels', { name: $('#chName').value, kind: $('#chKind').value });
      delete S.serverCache[sid];
      closeModal();
      renderServer(sid);
    };
  }

  async function joinInvite() {
    const code = prompt('Paste invite code or full invite link');
    if (!code) return;
    const m = code.match(/invite\/([^/?#]+)/);
    go('#invite/' + (m ? m[1] : code.trim()));
  }

  /* ---- Voice / calls ---- */

  function ensureCallLayer() {
    let layer = $('#callLayer');
    if (!layer) {
      layer = document.createElement('div');
      layer.id = 'callLayer';
      layer.className = 'call-layer';
      document.body.appendChild(layer);
    }
    return layer;
  }

  function renderCallPopups() {
    const layer = ensureCallLayer();
    const parts = [];
    if (S.callUI.incoming) {
      const c = S.callUI.incoming;
      const p = c.profile || {};
      parts.push(`<div class="call-popup incoming" id="callIncoming"><div class="call-popup-head"><div class="call-avatar-wrap">${avatar(p, 'big')}<span class="call-ring"></span><span class="call-ring delay"></span></div><div><p class="call-popup-title">${esc(p.display_name || 'Someone')}</p><p class="call-popup-sub">Incoming voice call</p><div class="call-wave"><span></span><span></span><span></span><span></span><span></span></div></div></div><div class="call-popup-actions"><button class="btn call-decline" id="declineCall">Decline</button><button class="btn call-accept" id="acceptCall">Accept</button></div></div>`);
    }
    if (S.callUI.outgoing) {
      const o = S.callUI.outgoing;
      const label = o.label || 'Ringing…';
      parts.push(`<div class="call-popup outgoing" id="callOutgoing"><div class="call-popup-head"><div class="call-avatar-wrap">${avatar(S.me, 'big')}<span class="call-ring"></span><span class="call-ring delay"></span></div><div><p class="call-popup-title">${esc(label)}</p><p class="call-popup-sub">Waiting for answer</p><div class="call-wave"><span></span><span></span><span></span><span></span><span></span></div></div></div><div class="call-popup-actions"><button class="btn call-decline" id="cancelCall">Cancel</button></div></div>`);
    }
    layer.innerHTML = parts.join('');
    $('#acceptCall')?.addEventListener('click', () => acceptIncomingCall());
    $('#declineCall')?.addEventListener('click', () => declineIncomingCall());
    $('#cancelCall')?.addEventListener('click', () => cancelOutgoingCall());
  }

  function clearIncomingCall() {
    S.callUI.incoming = null;
    renderCallPopups();
  }

  function clearOutgoingCall() {
    S.callUI.outgoing = null;
    renderCallPopups();
  }

  function showIncomingCall(ev) {
    if (S.callUI.outgoing) return;
    S.callUI.incoming = {
      conversation_id: ev.conversation_id,
      from_user_id: ev.from_user_id,
      profile: ev.profile || {}
    };
    renderCallPopups();
    if (document.visibilityState === 'hidden' && 'Notification' in window && Notification.permission === 'granted') {
      try {
        new Notification('Incoming call', { body: (ev.profile?.display_name || 'Someone') + ' is calling', tag: 'pw-call-' + ev.conversation_id });
      } catch {}
    }
  }

  async function startCall(cid, info) {
    if (S.callUI.outgoing || S.callUI.incoming) {
      toast('Already in a call');
      return;
    }
    let label = 'Calling…';
    if (info?.members) {
      const others = info.members.filter((m) => m.user.id !== S.me?.id);
      if (others.length === 1) label = 'Calling ' + (others[0].user.display_name || 'contact');
      else if (others.length > 1) label = 'Calling group (' + others.length + ')';
    } else if (cid) {
      try {
        const d = await api('GET', '/conversation/' + cid);
        const others = d.members.filter((m) => m.user.id !== S.me?.id);
        if (others.length === 1) label = 'Calling ' + (others[0].user.display_name || 'contact');
      } catch {}
    }
    S.callUI.outgoing = { conversation_id: cid, label };
    renderCallPopups();
    sendWS({ type: 'call_ring', conversation_id: cid });
    go('#dm/' + cid);
  }

  async function acceptIncomingCall() {
    const c = S.callUI.incoming;
    if (!c) return;
    clearIncomingCall();
    try {
      await leaveVoice();
      S.voice.stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      S.voice.mode = 'call';
      S.voice.id = c.conversation_id;
      sendWS({ type: 'call_accept', conversation_id: c.conversation_id });
      renderVoiceBox();
      go('#dm/' + c.conversation_id);
    } catch {
      toast('Microphone unavailable');
      sendWS({ type: 'call_decline', conversation_id: c.conversation_id });
    }
  }

  function declineIncomingCall() {
    const c = S.callUI.incoming;
    if (!c) return;
    sendWS({ type: 'call_decline', conversation_id: c.conversation_id });
    clearIncomingCall();
  }

  function cancelOutgoingCall() {
    const o = S.callUI.outgoing;
    if (!o) return;
    sendWS({ type: 'call_cancel', conversation_id: o.conversation_id });
    clearOutgoingCall();
  }

  async function connectToCall(conversationId, silent) {
    if (S.voice.mode === 'call' && S.voice.id === conversationId && S.voice.stream) return;
    try {
      if (!S.voice.stream) {
        S.voice.stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      }
      S.voice.mode = 'call';
      S.voice.id = conversationId;
      renderVoiceBox();
      if (!silent) toast('Call connected');
    } catch {
      toast('Microphone unavailable');
    }
  }

  async function joinVoice(channelId) {
    await leaveVoice();
    try {
      S.voice.stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      S.voice.mode = 'voice';
      S.voice.id = channelId;
      sendWS({ type: 'voice_join', channel_id: channelId });
      renderVoiceBox();
    } catch {
      toast('Microphone unavailable');
    }
  }

  async function joinCall(cid) {
    await startCall(cid);
  }

  async function leaveVoice() {
    if (S.voice.mode === 'voice') sendWS({ type: 'voice_leave' });
    if (S.voice.mode === 'call') sendWS({ type: 'call_leave' });
    if (S.callUI.outgoing) cancelOutgoingCall();
    clearIncomingCall();
    for (const id of [...S.voice.peers.keys()]) closePeer(id);
    S.voice.stream?.getTracks().forEach((t) => t.stop());
    S.voice = { mode: null, id: null, stream: null, peers: new Map(), users: new Map(), muted: false, deafened: false };
    renderVoiceBox();
  }

  async function ensurePeer(uid, offer) {
    if (!S.voice.stream && S.voice.mode === 'call' && S.voice.id) {
      await connectToCall(S.voice.id, true);
    }
    if (S.voice.peers.has(uid)) return S.voice.peers.get(uid);
    const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
    S.voice.stream?.getTracks().forEach((t) => pc.addTrack(t, S.voice.stream));
    pc.onicecandidate = (e) => {
      if (e.candidate) signal(uid, { kind: 'ice', candidate: e.candidate });
    };
    pc.ontrack = (e) => {
      let a = $('#audio_' + uid);
      if (!a) {
        a = document.createElement('audio');
        a.id = 'audio_' + uid;
        a.autoplay = true;
        document.body.appendChild(a);
      }
      a.srcObject = e.streams[0];
      a.muted = S.voice.deafened;
    };
    S.voice.peers.set(uid, pc);
    if (offer) {
      const o = await pc.createOffer();
      await pc.setLocalDescription(o);
      signal(uid, { kind: 'offer', sdp: o });
    }
    return pc;
  }

  function signal(to, sig) {
    if (S.voice.mode === 'voice') sendWS({ type: 'voice_signal', to_user_id: to, signal: sig });
    else sendWS({ type: 'call_signal', to_user_id: to, signal: sig });
  }

  async function handleSignal(from, sig) {
    const pc = await ensurePeer(from, false);
    if (sig.kind === 'offer') {
      await pc.setRemoteDescription(sig.sdp);
      const a = await pc.createAnswer();
      await pc.setLocalDescription(a);
      signal(from, { kind: 'answer', sdp: a });
    } else if (sig.kind === 'answer') {
      await pc.setRemoteDescription(sig.sdp);
    } else if (sig.kind === 'ice') {
      try {
        await pc.addIceCandidate(sig.candidate);
      } catch {}
    }
  }

  function closePeer(id) {
    S.voice.peers.get(id)?.close();
    S.voice.peers.delete(id);
    $('#audio_' + id)?.remove();
  }

  function voiceEvent(e) {
    if (e.type === 'voice_state') {
      S.voice.users = new Map((e.users || []).map((u) => [u.user_id, u]));
      renderVoiceBox();
    }
    if (e.type === 'voice_peer_joined') {
      S.voice.users.set(e.user_id, { user_id: e.user_id, profile: e.profile });
      renderVoiceBox();
      ensurePeer(e.user_id, true);
    }
    if (e.type === 'voice_peer_left') {
      S.voice.users.delete(e.user_id);
      closePeer(e.user_id);
      renderVoiceBox();
    }
    if (e.type === 'voice_signal') handleSignal(e.from_user_id, e.signal);
  }

  function callEvent(e) {
    if (e.type === 'call_incoming') {
      showIncomingCall(e);
      return;
    }
    if (e.type === 'call_ringing') {
      S.callUI.outgoing = { conversation_id: e.conversation_id, label: S.callUI.outgoing?.label || 'Ringing…' };
      renderCallPopups();
      return;
    }
    if (e.type === 'call_accepted') {
      const wasOutgoing = !!S.callUI.outgoing;
      clearOutgoingCall();
      clearIncomingCall();
      connectToCall(e.conversation_id, !wasOutgoing);
    }
    if (e.type === 'call_declined') {
      if (S.callUI.outgoing) toast('Call declined');
    }
    if (e.type === 'call_cancelled' || e.type === 'call_missed' || e.type === 'call_ended') {
      clearOutgoingCall();
      clearIncomingCall();
      if (e.type === 'call_missed' && e.reason === 'timeout') toast('No answer');
      if (e.type === 'call_cancelled' && e.reason === 'all_declined') toast('Call declined');
    }
    if (e.type === 'call_state') {
      clearOutgoingCall();
      clearIncomingCall();
      S.voice.users = new Map((e.users || []).map((u) => [u.user_id, u]));
      if (!S.voice.stream) connectToCall(e.conversation_id, true);
      else {
        S.voice.mode = 'call';
        S.voice.id = e.conversation_id;
        renderVoiceBox();
      }
    }
    if (e.type === 'call_peer_joined') {
      clearOutgoingCall();
      clearIncomingCall();
      S.voice.mode = 'call';
      S.voice.id = e.conversation_id;
      S.voice.users.set(e.user_id, { user_id: e.user_id, profile: e.profile });
      renderVoiceBox();
      if (S.voice.stream) ensurePeer(e.user_id, true);
    }
    if (e.type === 'call_peer_left') {
      S.voice.users.delete(e.user_id);
      closePeer(e.user_id);
      renderVoiceBox();
      if (S.voice.users.size === 0 && S.voice.mode === 'call') toast('Call ended');
    }
    if (e.type === 'call_signal') handleSignal(e.from_user_id, e.signal);
  }

  function renderVoiceBox() {
    const box = $('#voiceBox');
    if (!box) return;
    const inCall = S.voice.mode === 'call';
    box.innerHTML = S.voice.mode
      ? `<b>${inCall ? 'In call' : 'Voice'} connected</b>${inCall ? '<br><span class="call-indicator">● Live</span>' : ''}<br><small>${S.voice.id}</small>${[...S.voice.users.values()]
          .map(
            (u) =>
              `<div class="voice-user">${avatar(u.profile || {})}<span>${esc(u.profile?.display_name || 'User ' + u.user_id)}</span>${u.muted ? ' 🔇' : ''}${u.deafened ? ' 🧏' : ''}</div>`
          )
          .join('')}<div style="margin-top:10px;display:flex;flex-wrap:wrap;gap:8px"><button class="btn secondary" id="muteBtn">${S.voice.muted ? 'Unmute' : 'Mute'}</button><button class="btn secondary" id="deafenBtn">${S.voice.deafened ? 'Undeafen' : 'Deafen'}</button><button class="btn danger" id="leaveV">Leave</button></div>`
      : `<b>Voice</b><br><small>Join a voice channel or start a DM call.</small>`;
    $('#muteBtn')?.addEventListener('click', () => {
      S.voice.muted = !S.voice.muted;
      S.voice.stream?.getAudioTracks().forEach((t) => (t.enabled = !S.voice.muted));
      sendWS({
        type: S.voice.mode === 'call' ? 'call_state' : 'voice_state',
        patch: { muted: S.voice.muted, deafened: S.voice.deafened }
      });
      renderVoiceBox();
    });
    $('#deafenBtn')?.addEventListener('click', () => {
      S.voice.deafened = !S.voice.deafened;
      $$('audio[id^="audio_"]').forEach((a) => (a.muted = S.voice.deafened));
      sendWS({
        type: S.voice.mode === 'call' ? 'call_state' : 'voice_state',
        patch: { muted: S.voice.muted, deafened: S.voice.deafened }
      });
      renderVoiceBox();
    });
    $('#leaveV')?.addEventListener('click', leaveVoice);
  }

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (S.callUI.incoming) declineIncomingCall();
      else if (S.callUI.outgoing) cancelOutgoingCall();
      else if (S.voice.mode) leaveVoice();
    }
  });

  if ('Notification' in window && Notification.permission === 'default') {
    try {
      Notification.requestPermission();
    } catch {}
  }

  window.addEventListener('hashchange', render);
  window.addEventListener('beforeunload', () => {
    if (TAB.isLeader) {
      localStorage.removeItem('pw_ws_leader');
      localStorage.removeItem('pw_ws_leader_ts');
    }
  });

  boot();
})();
