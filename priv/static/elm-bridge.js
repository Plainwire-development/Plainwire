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
  let meId = null;
  let localStream = null;
  let room = null;
  let speakerOn = true;
  let micMuted = false;
  let deafened = false;
  let remoteAudioUnlockInstalled = false;
  const peers = new Map();
  const rtcConfig = window.PLAINWIRE_RTC_CONFIG || { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };

  // ---- Presence / idle tracking ----
  let desiredStatus = 'online';       // user preference: online, busy, invisible
  let effectiveStatus = null;         // visible status sent to the server
  let idle = false;
  let idleTimer = null;
  const IDLE_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes

  const normalizeDesiredStatus = (status) => {
    if (status === 'busy' || status === 'invisible') return status;
    return 'online';
  };

  const nextEffectiveStatus = () => {
    if (desiredStatus === 'invisible') return 'invisible';
    if (desiredStatus === 'busy') return 'busy';
    return idle ? 'away' : 'online';
  };

  const publishPresence = (force = false) => {
    const status = nextEffectiveStatus();
    if (!force && status === effectiveStatus) return;
    effectiveStatus = status;
    if (ws && ws.readyState === WebSocket.OPEN) {
      sendWs({ type: 'presence_update', status });
    }
  };

  const setDesiredStatus = (status) => {
    desiredStatus = normalizeDesiredStatus(status);
    if (desiredStatus !== 'online') idle = false;
    publishPresence(true);
  };

  const resetIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer);
    if (desiredStatus === 'online') {
      if (idle) {
        idle = false;
        publishPresence();
      }
      idleTimer = setTimeout(() => {
        idle = true;
        publishPresence();
      }, IDLE_TIMEOUT_MS);
    }
  };

  const activityEvents = ['mousemove', 'keydown', 'mousedown', 'touchstart', 'scroll', 'wheel'];
  const activityHandler = () => { resetIdleTimer(); };
  const visibilityHandler = () => {
    if (document.hidden && desiredStatus === 'online') {
      idle = true;
      publishPresence();
    } else {
      resetIdleTimer();
    }
  };
  const startActivityTracking = () => {
    activityEvents.forEach((ev) => document.addEventListener(ev, activityHandler, { passive: true }));
    document.addEventListener('visibilitychange', visibilityHandler);
    resetIdleTimer();
  };
  const stopActivityTracking = () => {
    activityEvents.forEach((ev) => document.removeEventListener(ev, activityHandler));
    document.removeEventListener('visibilitychange', visibilityHandler);
    if (idleTimer) clearTimeout(idleTimer);
  };

  // Mark activity for calls/messages too
  const markActive = () => { resetIdleTimer(); };

  startActivityTracking();

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
      if (json.ok && json.data && json.data.user && json.data.user.id) meId = json.data.user.id;
      send(app.ports.apiReceive, {
        path,
        method,
        ok: !!json.ok,
        data: json.data || null,
        error: json.error || (json.ok ? null : 'request_failed')
      });
      return json.ok ? json.data : null;
    } catch (_) {
      send(app.ports.apiReceive, { path, method, ok: false, data: null, error: 'request_failed' });
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
      publishPresence(true);
    };
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.session && msg.session.user && msg.session.user.id) meId = msg.session.user.id;
        handlePresenceEvent(msg);
        handleRtcEvent(msg);
        send(app.ports.wsReceive, msg);
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

  const ensureMedia = async () => {
    if (localStream && localStream.getAudioTracks().some(t => t.readyState === 'live')) return localStream;
    if (localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      localStream = null;
    }
    try {
      localStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false });
      localStream.getAudioTracks().forEach((t) => { t.enabled = !micMuted; });
    } catch (e) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone access is needed for calls.' });
      throw e;
    }
    return localStream;
  };

  const signalType = () => room && room.kind === 'voice' ? 'voice_signal' : 'call_signal';

  const sendSignal = (to, signal) => {
    if (!room) return;
    sendWs({ type: signalType(), to_user_id: to, signal });
  };

  const remoteAudio = (uid) => {
    let el = document.getElementById('remote-audio-' + uid);
    if (!el) {
      el = document.createElement('audio');
      el.id = 'remote-audio-' + uid;
      el.autoplay = true;
      el.playsInline = true;
      el.controls = false;
      el.volume = 1;
      el.style.position = 'fixed';
      el.style.left = '-9999px';
      el.style.top = '0';
      el.style.width = '1px';
      el.style.height = '1px';
      el.style.opacity = '0';
      el.style.pointerEvents = 'none';
      document.body.appendChild(el);
    }
    return el;
  };

  const playAllRemoteAudio = () => {
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((audio) => {
      audio.play().catch(() => false);
    });
  };

  const playRemoteAudio = (audio) => {
    audio.play().catch(() => false);
    if (!remoteAudioUnlockInstalled) {
      remoteAudioUnlockInstalled = true;
      ['click', 'touchend', 'keydown'].forEach((ev) => {
        document.addEventListener(ev, playAllRemoteAudio, { passive: true });
      });
    }
  };

  const applySpeaker = async () => {
    const sink = speakerOn ? 'default' : 'communications';
    await Promise.all(Array.from(document.querySelectorAll('audio[id^="remote-audio-"]')).map((el) => {
      if (typeof el.setSinkId !== 'function') return Promise.resolve(false);
      return el.setSinkId(sink).catch(() => false);
    }));
  };

  const closePeer = (uid) => {
    const pc = peers.get(uid);
    if (pc) {
      if (pc._restartTimer) clearTimeout(pc._restartTimer);
      pc.close();
    }
    peers.delete(uid);
    document.getElementById('remote-audio-' + uid)?.remove();
    send(app.ports.bridgeReceive, { tag: 'rtc_peer_connected', user_id: uid, connected: false });
  };

  const leaveRtcRoom = () => {
    peers.forEach((_, uid) => closePeer(uid));
    room = null;
    if (localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      localStream = null;
    }
  };

  const cleanupRtcMedia = () => {
    peers.forEach((_, uid) => closePeer(uid));
    room = null;
  };

  const makeOffer = async (uid, pc, options = {}) => {
    if (!pc || pc.signalingState !== 'stable' || pc._makingOffer) return;
    pc._makingOffer = true;
    try {
      const offer = await pc.createOffer(options);
      await pc.setLocalDescription(offer);
      sendSignal(uid, { kind: 'offer', sdp: pc.localDescription });
    } finally {
      pc._makingOffer = false;
    }
  };

  const restartPeerIce = (uid, pc) => {
    if (!pc || pc.signalingState === 'closed') return;
    if (pc._restartTimer) clearTimeout(pc._restartTimer);
    pc._restartTimer = setTimeout(() => {
      makeOffer(uid, pc, { iceRestart: true }).catch(() => closePeer(uid));
    }, 600);
  };

  const ensurePeer = async (uid, polite = false) => {
    if (!uid || uid === meId) return null;
    const existing = peers.get(uid);
    if (existing) return existing;
    const stream = await ensureMedia();
    const pc = new RTCPeerConnection(rtcConfig);
    pc._polite = polite;
    pc._makingOffer = false;
    pc._pendingCandidates = [];
    stream.getTracks().forEach((track) => pc.addTrack(track, stream));
    pc.onnegotiationneeded = () => {
      makeOffer(uid, pc).catch(() => closePeer(uid));
    };
    pc.onicecandidate = (ev) => {
      if (ev.candidate) sendSignal(uid, { kind: 'candidate', candidate: ev.candidate });
    };
    pc.ontrack = (ev) => {
      const audio = remoteAudio(uid);
      if (ev.streams && ev.streams[0]) {
        audio.srcObject = ev.streams[0];
      } else {
        const stream = audio.srcObject instanceof MediaStream ? audio.srcObject : new MediaStream();
        stream.addTrack(ev.track);
        audio.srcObject = stream;
      }
      audio.muted = deafened;
      playRemoteAudio(audio);
      applySpeaker();
    };
    let reconnectAttempts = 0;
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'connected') {
        reconnectAttempts = 0;
        send(app.ports.bridgeReceive, { tag: 'rtc_peer_connected', user_id: uid, connected: true });
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call audio connected' });
      }
      if (pc.connectionState === 'disconnected' && reconnectAttempts < 3) {
        reconnectAttempts++;
        setTimeout(() => { if (pc.connectionState === 'disconnected') restartPeerIce(uid, pc); }, 2000);
      }
      if (pc.connectionState === 'failed') {
        if (reconnectAttempts < 2) {
          reconnectAttempts++;
          restartPeerIce(uid, pc);
        } else {
          closePeer(uid);
        }
      }
    };
    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'failed' && reconnectAttempts < 3) {
        reconnectAttempts++;
        restartPeerIce(uid, pc);
      }
    };
    peers.set(uid, pc);
    return pc;
  };

  const callPeer = async (uid) => {
    const pc = await ensurePeer(uid, false);
    if (!pc) return;
    await makeOffer(uid, pc);
  };

  const handleSignal = async (msg) => {
    const uid = Number(msg.from_user_id || msg.user_id || 0);
    const signal = msg.signal || {};
    if (!room && msg.type === 'call_signal' && msg.conversation_id) room = { kind: 'call', id: msg.conversation_id };
    if (!room && msg.type === 'voice_signal' && msg.channel_id) room = { kind: 'voice', id: msg.channel_id };
    if (!uid || uid === meId || !room) return;
    const pc = await ensurePeer(uid, true);
    if (!pc) return;
    try {
      if (signal.kind === 'offer') {
        const offerCollision = pc._makingOffer || pc.signalingState !== 'stable';
        if (offerCollision) {
          if (!pc._polite) return; // impolite peer ignores late offers
          await pc.setLocalDescription({ type: 'rollback' });
        }
        pc._makingOffer = false;
        await pc.setRemoteDescription(signal.sdp);
        while (pc._pendingCandidates.length) {
          await pc.addIceCandidate(pc._pendingCandidates.shift()).catch(() => {});
        }
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        sendSignal(uid, { kind: 'answer', sdp: pc.localDescription });
      } else if (signal.kind === 'answer') {
        if (pc.signalingState === 'have-local-offer') {
          await pc.setRemoteDescription(signal.sdp);
          while (pc._pendingCandidates.length) {
            await pc.addIceCandidate(pc._pendingCandidates.shift()).catch(() => {});
          }
        }
      } else if (signal.kind === 'candidate' && signal.candidate) {
        if (pc.remoteDescription) {
          await pc.addIceCandidate(signal.candidate).catch(() => {});
        } else {
          pc._pendingCandidates.push(signal.candidate);
        }
      }
    } catch (e) { /* ignore signaling errors */ }
  };

  const joinRtcRoom = async (kind, id, users = []) => {
    room = { kind, id };
    await ensureMedia();
    const ids = users.map((u) => Number(u.user_id || u.userId || u.profile?.id || 0)).filter((uid) => uid && uid !== meId);
    ids.forEach((uid) => {
      const shouldOffer = meId > uid;
      ensurePeer(uid, !shouldOffer).then(() => {
        if (shouldOffer) callPeer(uid);
      }).catch(() => {});
    });
  };

  const handlePresenceEvent = (msg) => {
    if (msg.type === 'presence_state' && msg.statuses) {
      send(app.ports.bridgeReceive, { tag: 'presence_state', data: msg.statuses });
    } else if (msg.type === 'presence_online' && msg.status) {
      send(app.ports.bridgeReceive, { tag: 'presence_online', data: { user_id: msg.user_id, status: msg.status } });
    } else if (msg.type === 'presence_offline') {
      send(app.ports.bridgeReceive, { tag: 'presence_offline', data: msg.user_id });
    } else if (msg.type === 'presence_status' && msg.status) {
      send(app.ports.bridgeReceive, { tag: 'presence_status', data: { user_id: msg.user_id, status: msg.status } });
    }
  };

  const handleRtcEvent = (msg) => {
    if (['voice_state', 'call_state', 'voice_peer_joined', 'call_peer_joined', 'call_ringing', 'call_incoming'].includes(msg.type)) markActive();
    if (msg.type === 'voice_state') joinRtcRoom('voice', msg.channel_id, msg.users || []).catch(() => {});
    if (msg.type === 'call_state') joinRtcRoom('call', msg.conversation_id, msg.users || []).catch(() => {});
    if (msg.type === 'call_peer_left' || msg.type === 'voice_peer_left') closePeer(Number(msg.user_id));
    if (msg.type === 'voice_signal' || msg.type === 'call_signal') handleSignal(msg).catch(() => {});
    if (['call_declined', 'call_cancelled', 'call_missed'].includes(msg.type)) leaveRtcRoom();
  };

  const setMuted = (muted) => {
    micMuted = !!muted;
    if (localStream) localStream.getAudioTracks().forEach((t) => { t.enabled = !micMuted; });
  };

  const setDeafened = (value) => {
    deafened = !!value;
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((el) => { el.muted = deafened; });
    if (deafened) setMuted(true);
  };

  const enableDrag = () => {
    let drag = null;
    document.addEventListener('pointerdown', (ev) => {
      const card = ev.target.closest?.('.call-popup.active-call');
      if (!card || ev.target.closest('button')) return;
      const rect = card.getBoundingClientRect();
      drag = { card, dx: ev.clientX - rect.left, dy: ev.clientY - rect.top };
      card.setPointerCapture?.(ev.pointerId);
    });
    document.addEventListener('pointermove', (ev) => {
      if (!drag) return;
      drag.card.style.position = 'fixed';
      drag.card.style.left = Math.max(8, ev.clientX - drag.dx) + 'px';
      drag.card.style.top = Math.max(8, ev.clientY - drag.dy) + 'px';
      drag.card.style.right = 'auto';
      drag.card.style.bottom = 'auto';
    });
    document.addEventListener('pointerup', () => { drag = null; });
  };

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
  recv(app.ports.notify, ({ title = 'Plainwire', body = '' } = {}) => {
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
        api({ method: 'POST', path: '/friends/request', body: { user_id: data } }).then(() => {
          api({ method: 'GET', path: '/sync?since=0' });
        });
        break;
      case 'accept_friend':
        api({ method: 'POST', path: '/friends/accept', body: { user_id: data } }).then(() => {
          api({ method: 'GET', path: '/sync?since=0' });
        });
        break;
      case 'dm_user':
        api({ method: 'POST', path: '/conversations', body: { user_ids: [data], name: '' } }).then((res) => {
          if (res && res.id) location.hash = '#dm/' + res.id;
        });
        break;
      case 'call_user':
        api({ method: 'POST', path: '/conversations', body: { user_ids: [data], name: '' } }).then((res) => {
          if (res && res.id) {
            ensureMedia()
              .then(() => {
                stopRingtones();
                outgoingTimer = setInterval(() => playTone({ freq: 520, dur: 140, type: 'triangle', vol: 0.12 }), 900);
                sendWs({ type: 'call_ring', conversation_id: res.id });
              })
              .catch(() => {
                stopRingtones();
                send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
                send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
              });
          }
        });
        break;
      case 'start_call':
        ensureMedia()
          .then(() => {
            stopRingtones();
            outgoingTimer = setInterval(() => playTone({ freq: 520, dur: 140, type: 'triangle', vol: 0.12 }), 900);
            sendWs({ type: 'call_ring', conversation_id: data });
          })
          .catch(() => {
            stopRingtones();
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
          });
        break;
      case 'join_voice':
        leaveRtcRoom();
        room = { kind: 'voice', id: data };
        ensureMedia()
          .then(() => sendWs({ type: 'voice_join', channel_id: data }))
          .catch(() => {
            room = null;
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'voice' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for voice.' });
          });
        break;
      case 'accept_call':
        leaveRtcRoom();
        room = { kind: 'call', id: data };
        ensureMedia()
          .then(() => {
            sendWs({ type: 'call_accept', conversation_id: data });
            stopRingtones();
          })
          .catch(() => {
            room = null;
            stopRingtones();
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
          });
        break;
      case 'decline_call':
        sendWs({ type: 'call_decline', conversation_id: data });
        stopRingtones();
        break;
      case 'cancel_call':
        sendWs({ type: 'call_cancel', conversation_id: data });
        stopRingtones();
        break;
      case 'end_call':
        sendWs({ type: 'call_leave' });
        sendWs({ type: 'voice_leave' });
        leaveRtcRoom();
        stopRingtones();
        break;
      case 'voice_mute':
        setMuted(!!data);
        sendWs({ type: 'voice_state', patch: { muted: !!data } });
        sendWs({ type: 'call_state', patch: { muted: !!data } });
        break;
      case 'voice_deafen':
        setDeafened(!!data);
        sendWs({ type: 'voice_state', patch: { deafened: !!data, muted: !!data ? true : micMuted } });
        sendWs({ type: 'call_state', patch: { deafened: !!data, muted: !!data ? true : micMuted } });
        break;
      case 'unlock_audio':
        audioContext()?.resume?.();
        playAllRemoteAudio();
        break;
      case 'toggle_speaker':
        speakerOn = !speakerOn;
        applySpeaker().then(() => {
          send(app.ports.bridgeReceive, { tag: 'toast', data: speakerOn ? 'Speaker output on' : 'Speaker output off' });
        });
        break;
      case 'reload':
        location.reload();
        break;
      case 'new_thread': {
        const forumId = data || Number(ask('Thread category ID'));
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
        const query = ask('Search people and threads');
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
        if (name) api({ method: 'POST', path: '/conversation/' + data, body: { name } }).then(() => api({ method: 'GET', path: '/sync?since=0' }));
        break;
      }
      case 'add_people': {
        const userIds = askCsvInts('User IDs to add, comma separated');
        if (userIds.length) api({ method: 'POST', path: '/conversation/' + data + '/members', body: { user_ids: userIds } }).then(() => api({ method: 'GET', path: '/sync?since=0' }));
        break;
      }
      case 'set_theme':
        if (data === 'system') {
          document.documentElement.removeAttribute('data-theme');
        } else {
          document.documentElement.setAttribute('data-theme', data);
        }
        break;
      case 'presence_update':
        setDesiredStatus(String(data));
        break;
      default:
        break;
    }
  });

  window.addEventListener('hashchange', () => send(app.ports.onHashChange, location.hash));
  window.addEventListener('pagehide', cleanupRtcMedia);
  window.addEventListener('beforeunload', cleanupRtcMedia);
  enableDrag();
  document.addEventListener('click', () => audioContext()?.resume?.(), { once: true });
})();
