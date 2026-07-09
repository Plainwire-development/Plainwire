(() => {
  'use strict';

  const root = document.getElementById('app');
  if (!root || !window.Elm || !window.Elm.Main) return;

  const app = window.Elm.Main.init({ node: root, flags: null });
  let csrf = '';
  let ws = null;
  let wsQueue = [];
  let ringtoneTimer = null;
  let outgoingTimer = null;
  let audioCtx = null;

  const send = (port, value) => {
    if (port && typeof port.send === 'function') port.send(value);
  };

  const recv = (port, fn) => {
    if (port && typeof port.subscribe === 'function') port.subscribe(fn);
  };

  const audioContext = () => {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    audioCtx = audioCtx || new Ctx();
    return audioCtx;
  };

  const playTone = ({ freq = 660, dur = 120, type = 'sine', vol = 0.15 } = {}) => {
    const ctx = audioContext();
    if (!ctx) return;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = type;
    osc.frequency.value = freq;
    gain.gain.value = vol;
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + dur / 1000);
  };

  const stopRingtones = () => {
    if (ringtoneTimer) clearInterval(ringtoneTimer);
    if (outgoingTimer) clearInterval(outgoingTimer);
    ringtoneTimer = null;
    outgoingTimer = null;
  };

  const api = async ({ method = 'GET', path, body }) => {
    const headers = { accept: 'application/json', 'x-csrf-token': csrf };
    const options = { method, headers };
    if (body !== null && body !== undefined) {
      headers['content-type'] = 'application/json';
      options.body = JSON.stringify(body);
    }

    try {
      const res = await fetch('/api' + path, options);
      const json = await res.json().catch(() => ({ ok: false, error: 'bad_json' }));
      if (json.ok && json.data && json.data.csrf) csrf = json.data.csrf;
      send(app.ports.apiReceive, {
        path,
        ok: !!json.ok,
        data: json.data || null,
        error: json.error || (json.ok ? null : 'request_failed')
      });
      return json.ok ? json.data : null;
    } catch (_) {
      send(app.ports.apiReceive, { path, ok: false, data: null, error: 'request_failed' });
      return null;
    }
  };

  const connectWs = () => {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
    const proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
    ws = new WebSocket(proto + location.host + '/ws');
    ws.onopen = () => {
      const queued = wsQueue;
      wsQueue = [];
      queued.forEach((value) => sendWs(value));
    };
    ws.onmessage = (event) => {
      try {
        send(app.ports.wsReceive, JSON.parse(event.data));
      } catch (_) {}
    };
    ws.onclose = () => {
      ws = null;
      setTimeout(connectWs, 800);
    };
  };

  const sendWs = (value) => {
    connectWs();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(value));
    } else {
      wsQueue.push(value);
    }
  };

  const ask = (message, fallback = '') => {
    const value = window.prompt(message, fallback);
    return value == null ? '' : value.trim();
  };

  const askCsvInts = (message) =>
    ask(message)
      .split(',')
      .map((v) => Number(v.trim()))
      .filter((v) => Number.isInteger(v) && v > 0);

  recv(app.ports.apiSend, api);
  recv(app.ports.wsSend, (value) => {
    sendWs(value);
  });
  recv(app.ports.setHash, (hash) => {
    location.hash = hash;
  });
  recv(app.ports.setTitle, (title) => {
    document.title = title;
  });
  recv(app.ports.notify, ({ title = 'Plainwire Relay', body = '' } = {}) => {
    if ('Notification' in window && Notification.permission === 'granted') {
      new Notification(title, { body });
    }
  });
  recv(app.ports.copyText, (text) => {
    if (navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
  });
  recv(app.ports.localStorageGet, ({ key }) => {
    send(app.ports.bridgeReceive, { tag: 'local_storage', key, data: localStorage.getItem(key) });
  });
  recv(app.ports.localStorageSet, ({ key, value }) => {
    localStorage.setItem(key, value);
  });
  recv(app.ports.playTone, playTone);
  recv(app.ports.playNotification, (enabled) => {
    if (enabled) playTone({ freq: 880, dur: 80, type: 'triangle', vol: 0.1 });
  });
  recv(app.ports.playRingtone, (enabled) => {
    if (!enabled) return stopRingtones();
    stopRingtones();
    ringtoneTimer = setInterval(() => playTone({ freq: 740, dur: 180 }), 700);
  });
  recv(app.ports.playOutgoingRingtone, (enabled) => {
    if (!enabled) return stopRingtones();
    stopRingtones();
    outgoingTimer = setInterval(() => playTone({ freq: 520, dur: 140 }), 900);
  });
  recv(app.ports.scrollTo, (selector) => {
    document.querySelector(selector)?.scrollIntoView({ block: 'center' });
  });
  recv(app.ports.readFile, (id) => {
    const input = document.getElementById(id);
    const file = input && input.files && input.files[0];
    if (!file) return send(app.ports.fileInput, { id, data: null });
    const reader = new FileReader();
    reader.onload = () => send(app.ports.fileInput, { id, data: reader.result });
    reader.onerror = () => send(app.ports.fileInput, { id, data: null });
    reader.readAsDataURL(file);
  });
  recv(app.ports.requestNotifyPermission, () => {
    if ('Notification' in window && Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  });
  recv(app.ports.bridgeSend, ({ tag, data }) => {
    switch (tag) {
      case 'connect_ws':
        connectWs();
        break;
      case 'clear_subs':
        sendWs({ type: 'unsubscribe_all' });
        break;
      case 'silent_sync':
        api({ method: 'GET', path: '/sync?since=0' });
        break;
      case 'toast':
        send(app.ports.bridgeReceive, { tag: 'toast', data });
        break;
      case 'play_ringtone':
        stopRingtones();
        ringtoneTimer = setInterval(() => playTone({ freq: 740, dur: 180 }), 700);
        break;
      case 'friend_user':
        api({ method: 'POST', path: '/friends/request', body: { user_id: data } });
        break;
      case 'accept_friend':
        api({ method: 'POST', path: '/friends/accept', body: { user_id: data } });
        api({ method: 'GET', path: '/sync?since=0' });
        break;
      case 'dm_user':
        api({ method: 'POST', path: '/conversations', body: { user_ids: [data], name: '' } }).then((res) => {
          if (res && res.id) location.hash = '#dm/' + res.id;
        });
        break;
      case 'call_user':
        api({ method: 'POST', path: '/conversations', body: { user_ids: [data], name: '' } }).then((res) => {
          if (res && res.id) {
            sendWs({ type: 'call_ring', conversation_id: res.id });
          }
        });
        break;
      case 'join_voice':
        sendWs({ type: 'voice_join', channel_id: data });
        break;
      case 'accept_call':
        sendWs({ type: 'call_accept', conversation_id: data });
        sendWs({ type: 'call_join', conversation_id: data });
        stopRingtones();
        break;
      case 'decline_call':
        sendWs({ type: 'call_decline', conversation_id: data });
        sendWs({ type: 'call_cancel', conversation_id: data });
        stopRingtones();
        break;
      case 'end_call':
        sendWs({ type: 'call_leave' });
        sendWs({ type: 'voice_leave' });
        stopRingtones();
        break;
      case 'voice_mute':
        sendWs({ type: 'voice_state', patch: { muted: !!data } });
        sendWs({ type: 'call_state', patch: { muted: !!data } });
        break;
      case 'voice_deafen':
        sendWs({ type: 'voice_state', patch: { deafened: !!data } });
        sendWs({ type: 'call_state', patch: { deafened: !!data } });
        break;
      case 'reload':
        location.reload();
        break;
      case 'new_thread': {
        const forumId = data || Number(ask('Forum ID'));
        const title = ask('Thread title');
        const body = ask('Thread body');
        if (forumId && title) {
          api({ method: 'POST', path: '/threads', body: { forum_id: forumId, title, body } }).then((res) => {
            if (res && res.id) location.hash = '#thread/' + res.id;
          });
        }
        break;
      }
      case 'new_dm': {
        const userIds = askCsvInts('User IDs, comma separated');
        const name = ask('Conversation name', '');
        if (userIds.length) {
          api({ method: 'POST', path: '/conversations', body: { user_ids: userIds, name } }).then((res) => {
            if (res && res.id) location.hash = '#dm/' + res.id;
          });
        }
        break;
      }
      case 'search_users': {
        const query = ask('Search users and threads');
        if (query) location.hash = '#search/' + encodeURIComponent(query);
        break;
      }
      case 'create_invite':
        api({ method: 'POST', path: '/server/' + data + '/invites', body: { max_uses: 0 } }).then((res) => {
          if (res && res.url) {
            const url = location.origin + res.url;
            navigator.clipboard?.writeText(url).catch(() => {});
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Invite copied' });
          }
        });
        break;
      case 'create_channel': {
        const name = ask('Channel name');
        const kind = ask('Channel kind: text or voice', 'text') === 'voice' ? 'voice' : 'text';
        if (name) {
          api({ method: 'POST', path: '/server/' + data + '/channels', body: { name, kind } }).then((res) => {
            if (res && res.id) location.hash = (kind === 'voice' ? '#voice/' : '#channel/') + res.id;
          });
        }
        break;
      }
      case 'edit_server': {
        const name = ask('Server name', data.name || '');
        const description = ask('Server description', data.description || '');
        const icon_url = ask('Server icon URL', data.icon_url || '');
        if (data.id && name) {
          api({ method: 'POST', path: '/server/' + data.id, body: { name, description, icon_url } }).then(() => {
            api({ method: 'GET', path: '/server/' + data.id });
          });
        }
        break;
      }
      case 'edit_conversation': {
        const name = ask('Conversation name');
        if (name) api({ method: 'POST', path: '/conversation/' + data, body: { name } });
        break;
      }
      case 'add_people': {
        const userIds = askCsvInts('User IDs to add, comma separated');
        if (userIds.length) api({ method: 'POST', path: '/conversation/' + data + '/members', body: { user_ids: userIds } });
        break;
      }
      default:
        break;
    }
  });

  window.addEventListener('hashchange', () => send(app.ports.onHashChange, location.hash));
  document.addEventListener('click', () => audioContext()?.resume?.(), { once: true });
})();
