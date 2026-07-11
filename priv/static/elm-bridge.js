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
  let audioUnlockToastShown = false;
  const peers = new Map();
  const peerPromises = new Map();
  const defaultRtcConfig = { iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }] };
  let rtcConfig = window.PLAINWIRE_RTC_CONFIG || defaultRtcConfig;
  let rtcConfigRequest = null;
  let rtcConfigFetchedAt = 0;
  let vad = null;
  const debugEnabled = window.PLAINWIRE_DEBUG !== false && localStorage.getItem('plainwire_debug') !== 'false';
  const startedAt = performance.now();
  const redact = (value) => {
    if (!value || typeof value !== 'object') return value;
    const copy = Array.isArray(value) ? [] : {};
    Object.entries(value).forEach(([key, item]) => {
      if (/password|csrf|token|cookie|authorization|sdp|candidate/i.test(key)) {
        copy[key] = item == null ? item : `[redacted ${String(item).length} chars]`;
      } else if (key === 'body' && typeof item === 'string') {
        copy[key] = `[text ${item.length} chars]`;
      } else {
        copy[key] = item && typeof item === 'object' ? redact(item) : item;
      }
    });
    return copy;
  };
  const debug = (area, event, details = {}, level = 'log') => {
    if (!debugEnabled && level !== 'error' && level !== 'warn') return;
    const payload = { at: new Date().toISOString(), elapsed_ms: Math.round(performance.now() - startedAt), ...redact(details) };
    (console[level] || console.log)(`[Plainwire:${area}] ${event}`, payload);
  };
  window.PlainwireDebug = {
    enabled: debugEnabled,
    snapshot: () => ({
      websocket: ws ? ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'][ws.readyState] : 'NONE',
      room: room ? { ...room } : null,
      user_id: meId,
      local_tracks: localStream ? localStream.getTracks().map((t) => ({ kind: t.kind, enabled: t.enabled, muted: t.muted, readyState: t.readyState })) : [],
      peers: Array.from(peers, ([user_id, pc]) => ({ user_id, connection: pc.connectionState, ice: pc.iceConnectionState, signaling: pc.signalingState }))
    }),
    setEnabled: (enabled) => { localStorage.setItem('plainwire_debug', enabled ? 'true' : 'false'); location.reload(); }
  };
  debug('BOOT', 'bridge_initialized', { debug: debugEnabled, secure_context: window.isSecureContext, online: navigator.onLine });

  const loadRtcConfig = () => {
    if (window.PLAINWIRE_RTC_CONFIG) return Promise.resolve(rtcConfig);
    if (rtcConfigRequest && Date.now() - rtcConfigFetchedAt < 5 * 60 * 1000) return rtcConfigRequest;
    rtcConfigFetchedAt = Date.now();
    debug('RTC', 'config_fetch_started');
    rtcConfigRequest = fetch('/api/rtc-config', { headers: { accept: 'application/json' } })
      .then((res) => res.ok ? res.json() : null)
      .then((json) => {
        const config = json && json.ok && json.data;
        if (config && Array.isArray(config.iceServers)) rtcConfig = config;
        debug('RTC', 'config_loaded', { ice_server_count: rtcConfig.iceServers?.length || 0, source: config ? 'server' : 'fallback' });
        return rtcConfig;
      })
      .catch((error) => { debug('RTC', 'config_fetch_failed', { error: error.message }, 'warn'); return rtcConfig; });
    return rtcConfigRequest;
  };

  // ---- Presence / idle tracking ----
  let desiredStatus = 'online';       // user preference: online, away, busy, invisible
  let effectiveStatus = null;         // visible status sent to the server
  let idle = false;
  let idleTimer = null;
  const IDLE_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes

  const normalizeDesiredStatus = (status) => {
    if (status === 'away' || status === 'busy' || status === 'invisible') return status;
    return 'online';
  };

  const nextEffectiveStatus = () => {
    if (desiredStatus === 'invisible') return 'invisible';
    if (desiredStatus === 'busy') return 'busy';
    if (desiredStatus === 'away') return 'away';
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

  const applyUiPreferences = () => {
    const density = localStorage.getItem('plainwire_density') || 'comfortable';
    const reduceMotion = localStorage.getItem('plainwire_reduce_motion') === 'true';
    document.documentElement.dataset.density = density === 'compact' ? 'compact' : 'comfortable';
    document.documentElement.dataset.reduceMotion = reduceMotion ? 'true' : 'false';
  };
  applyUiPreferences();

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
    const requestStarted = performance.now();
    debug('API', 'request', { method, path, body });
    const headers = { accept: 'application/json', 'x-csrf-token': csrf };
    const options = { method, headers };
    if (body !== null && body !== undefined) {
      headers['content-type'] = 'application/json';
      options.body = JSON.stringify(body);
    }

    try {
      const res = await fetch('/api' + path, options);
      const json = await res.json().catch(() => ({ ok: false, error: 'bad_json' }));
      debug('API', 'response', { method, path, status: res.status, ok: !!json.ok, duration_ms: Math.round(performance.now() - requestStarted), error: json.error });
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
    } catch (error) {
      debug('API', 'request_failed', { method, path, duration_ms: Math.round(performance.now() - requestStarted), error: error.message }, 'error');
      send(app.ports.apiReceive, { path, method, ok: false, data: null, error: 'request_failed' });
      return null;
    }
  };

  const connectWs = () => {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
    const proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
    const url = proto + location.host + '/ws';
    debug('WS', 'connecting', { url, queued: wsQueue.length });
    ws = new WebSocket(url);
    ws.onopen = () => {
      const queued = wsQueue;
      wsQueue = [];
      debug('WS', 'connected', { queued: queued.length, room });
      queued.forEach((value) => sendWs(value));
      publishPresence(true);
      if (room && room.joined && localStream) {
        const join = room.kind === 'voice'
          ? { type: 'voice_join', channel_id: room.id }
          : { type: 'call_join', conversation_id: room.id };
        sendWs(join);
      }
    };
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        debug('WS', 'received', { message: msg });
        if (msg.session && msg.session.user && msg.session.user.id) meId = msg.session.user.id;
        handlePresenceEvent(msg);
        handleRtcEvent(msg);
        send(app.ports.wsReceive, msg);
      } catch (error) { debug('WS', 'invalid_message', { error: error.message, bytes: String(event.data).length }, 'error'); }
    };
    ws.onerror = () => debug('WS', 'transport_error', { ready_state: ws?.readyState }, 'error');
    ws.onclose = (event) => {
      debug('WS', 'closed', { code: event.code, reason: event.reason || '(none)', clean: event.wasClean, reconnect_ms: 800 }, 'warn');
      ws = null;
      setTimeout(connectWs, 800);
    };
  };

  const sendWs = (value) => {
    connectWs();
    if (ws && ws.readyState === WebSocket.OPEN) {
      debug('WS', 'sent', { message: value });
      ws.send(JSON.stringify(value));
    } else {
      wsQueue.push(value);
      debug('WS', 'queued', { type: value?.type, queue_length: wsQueue.length }, 'warn');
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
    if (localStream && localStream.getAudioTracks().some(t => t.readyState === 'live')) {
      debug('MEDIA', 'reusing_microphone', { tracks: localStream.getAudioTracks().length });
      return localStream;
    }
    if (localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      localStream = null;
    }
    try {
      debug('MEDIA', 'microphone_request', { constraints: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
      localStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false });
      localStream.getAudioTracks().forEach((track) => {
        track.enabled = !micMuted;
        debug('MEDIA', 'microphone_track', { label: track.label, enabled: track.enabled, settings: track.getSettings?.() });
        track.onended = () => debug('MEDIA', 'microphone_track_ended', { label: track.label }, 'warn');
        track.onmute = () => debug('MEDIA', 'microphone_track_muted', { label: track.label }, 'warn');
        track.onunmute = () => debug('MEDIA', 'microphone_track_unmuted', { label: track.label });
      });
      startVoiceDetection(localStream);
    } catch (e) {
      debug('MEDIA', 'microphone_failed', { name: e.name, error: e.message }, 'error');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone access is needed for calls.' });
      throw e;
    }
    return localStream;
  };

  const stopVoiceDetection = () => {
    if (!vad) return;
    cancelAnimationFrame(vad.frame);
    try { vad.source.disconnect(); vad.analyser.disconnect(); } catch (_) {}
    if (vad.speaking) reportVoiceActivity(false, vad.lastDb);
    vad = null;
    debug('VOICE', 'detector_stopped');
  };

  const reportVoiceActivity = (speaking, db) => {
    const details = { detected: speaking, level_db: Math.round(db), muted: micMuted, room_kind: room?.kind || null, room_id: room?.id || null };
    debug('VOICE', speaking ? 'voice_detected' : 'voice_stopped', details);
    if (room && ws?.readyState === WebSocket.OPEN) sendWs({ type: 'voice_activity', active: speaking, level_db: details.level_db });
  };

  const startVoiceDetection = (stream) => {
    stopVoiceDetection();
    const ctx = audioContext();
    if (!ctx) return debug('VOICE', 'detector_unavailable', { reason: 'AudioContext unsupported' }, 'warn');
    const analyser = ctx.createAnalyser();
    const source = ctx.createMediaStreamSource(stream);
    analyser.fftSize = 1024;
    analyser.smoothingTimeConstant = 0.75;
    source.connect(analyser);
    const samples = new Float32Array(analyser.fftSize);
    vad = { analyser, source, samples, frame: 0, speaking: false, above: 0, below: 0, noiseDb: -60, lastDb: -100 };
    debug('VOICE', 'detector_started', { attack_ms: 120, release_ms: 480, adaptive_threshold: true });
    const sample = () => {
      if (!vad || vad.analyser !== analyser) return;
      analyser.getFloatTimeDomainData(samples);
      let sum = 0;
      for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
      const rms = Math.sqrt(sum / samples.length);
      const db = rms > 0 ? 20 * Math.log10(rms) : -100;
      vad.lastDb = db;
      if (!vad.speaking && db < vad.noiseDb + 8) vad.noiseDb = vad.noiseDb * 0.98 + db * 0.02;
      const active = !micMuted && db > Math.max(-50, vad.noiseDb + 12);
      vad.above = active ? vad.above + 1 : 0;
      vad.below = active ? 0 : vad.below + 1;
      if (!vad.speaking && vad.above >= 8) { vad.speaking = true; reportVoiceActivity(true, db); }
      if (vad.speaking && vad.below >= 30) { vad.speaking = false; reportVoiceActivity(false, db); }
      vad.frame = requestAnimationFrame(sample);
    };
    vad.frame = requestAnimationFrame(sample);
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
      audio.play().then(() => { audioUnlockToastShown = false; }).catch(() => false);
    });
  };

  const playRemoteAudio = (audio) => {
    audio.play().then(() => { audioUnlockToastShown = false; }).catch(() => {
      if (!audioUnlockToastShown) {
        audioUnlockToastShown = true;
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Tap Enable audio to hear the call.' });
      }
    });
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
      if (pc._connectTimer) clearTimeout(pc._connectTimer);
      pc.close();
    }
    peers.delete(uid);
    debug('RTC', 'peer_closed', { peer_user_id: uid, remaining_peers: peers.size });
    document.getElementById('remote-audio-' + uid)?.remove();
    send(app.ports.bridgeReceive, { tag: 'rtc_peer_connected', user_id: uid, connected: false });
  };

  const leaveRtcRoom = () => {
    debug('RTC', 'room_leaving', { room, peers: peers.size });
    peers.forEach((_, uid) => closePeer(uid));
    stopVoiceDetection();
    room = null;
    if (localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      localStream = null;
    }
  };

  const cleanupRtcMedia = () => {
    peers.forEach((_, uid) => closePeer(uid));
    stopVoiceDetection();
    room = null;
    if (localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      localStream = null;
    }
  };

  const stopPendingCallMedia = () => {
    if (room) return;
    stopVoiceDetection();
    if (localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      localStream = null;
    }
  };

  const makeOffer = async (uid, pc, options = {}) => {
    if (!pc || pc.signalingState !== 'stable' || pc._makingOffer) return;
    pc._makingOffer = true;
    debug('RTC', 'offer_creating', { peer_user_id: uid, ice_restart: !!options.iceRestart, signaling: pc.signalingState });
    try {
      const offer = await pc.createOffer(options);
      await pc.setLocalDescription(offer);
      debug('RTC', 'offer_ready', { peer_user_id: uid });
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
    const pending = peerPromises.get(uid);
    if (pending) return pending;
    const creation = createPeer(uid, polite);
    peerPromises.set(uid, creation);
    try {
      return await creation;
    } finally {
      peerPromises.delete(uid);
    }
  };

  const createPeer = async (uid, polite) => {
    await loadRtcConfig();
    const stream = await ensureMedia();
    if (peers.has(uid)) return peers.get(uid);
    const pc = new RTCPeerConnection(rtcConfig);
    debug('RTC', 'peer_created', { peer_user_id: uid, polite, room, ice_server_count: rtcConfig.iceServers?.length || 0 });
    pc._polite = polite;
    pc._makingOffer = false;
    pc._pendingCandidates = [];
    pc._connectAttempts = 0;
    stream.getTracks().forEach((track) => pc.addTrack(track, stream));
    pc.onnegotiationneeded = () => {
      if (pc._polite) return;
      makeOffer(uid, pc).catch(() => closePeer(uid));
    };
    pc.onicecandidate = (ev) => {
      if (ev.candidate) {
        debug('RTC', 'ice_candidate', { peer_user_id: uid, protocol: ev.candidate.protocol, type: ev.candidate.type });
        sendSignal(uid, { kind: 'candidate', candidate: ev.candidate });
      } else debug('RTC', 'ice_gathering_complete', { peer_user_id: uid });
    };
    pc.ontrack = (ev) => {
      debug('RTC', 'remote_track', { peer_user_id: uid, kind: ev.track.kind, muted: ev.track.muted, ready_state: ev.track.readyState, streams: ev.streams?.length || 0 });
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
      debug('RTC', 'connection_state', { peer_user_id: uid, state: pc.connectionState });
      if (pc.connectionState === 'connected') {
        if (pc._connectTimer) clearTimeout(pc._connectTimer);
        reconnectAttempts = 0;
        send(app.ports.bridgeReceive, { tag: 'rtc_peer_connected', user_id: uid, connected: true });
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call audio connected' });
        playAllRemoteAudio();
        setTimeout(() => {
          if (pc.connectionState !== 'connected') return;
          const audio = document.getElementById('remote-audio-' + uid);
          const stream = audio && audio.srcObject;
          const hasLiveAudio = stream instanceof MediaStream && stream.getAudioTracks().some((track) => track.readyState === 'live');
          if (!hasLiveAudio) {
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Connected, but no audio track arrived—renegotiating…' });
            makeOffer(uid, pc).catch(() => {});
          }
        }, 4000);
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
      debug('RTC', 'ice_connection_state', { peer_user_id: uid, state: pc.iceConnectionState });
      if (pc.iceConnectionState === 'failed' && reconnectAttempts < 3) {
        reconnectAttempts++;
        restartPeerIce(uid, pc);
      }
    };
    pc.onicegatheringstatechange = () => debug('RTC', 'ice_gathering_state', { peer_user_id: uid, state: pc.iceGatheringState });
    pc.onsignalingstatechange = () => debug('RTC', 'signaling_state', { peer_user_id: uid, state: pc.signalingState });
    peers.set(uid, pc);
    const checkConnection = () => {
      pc._connectTimer = setTimeout(() => {
        if (pc.connectionState === 'connected' || pc.connectionState === 'closed') return;
        pc._connectAttempts++;
        if (pc._connectAttempts <= 2) {
          if (pc.signalingState === 'stable') {
            makeOffer(uid, pc, { iceRestart: true }).catch(() => {});
          } else if (typeof pc.restartIce === 'function') {
            pc.restartIce();
          }
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Still connecting audio—retrying…' });
          checkConnection();
        } else {
          const failedKind = room ? room.kind : 'call';
          closePeer(uid);
          send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: failedKind });
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Voice connection failed. Check TURN configuration or try rejoining.' });
        }
      }, 12000);
    };
    checkConnection();
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
    debug('RTC', 'signal_received', { peer_user_id: uid, kind: signal.kind, message_type: msg.type });
    if (!room && msg.type === 'call_signal' && msg.conversation_id) room = { kind: 'call', id: msg.conversation_id, joined: true };
    if (!room && msg.type === 'voice_signal' && msg.channel_id) room = { kind: 'voice', id: msg.channel_id, joined: true };
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
        debug('RTC', 'remote_offer_applied', { peer_user_id: uid });
        while (pc._pendingCandidates.length) {
          await pc.addIceCandidate(pc._pendingCandidates.shift()).catch(() => {});
        }
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        debug('RTC', 'answer_ready', { peer_user_id: uid });
        sendSignal(uid, { kind: 'answer', sdp: pc.localDescription });
      } else if (signal.kind === 'answer') {
        if (pc.signalingState === 'have-local-offer') {
          await pc.setRemoteDescription(signal.sdp);
          debug('RTC', 'remote_answer_applied', { peer_user_id: uid });
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
    } catch (e) { debug('RTC', 'signaling_failed', { peer_user_id: uid, kind: signal.kind, name: e.name, error: e.message, signaling: pc.signalingState }, 'error'); }
  };

  const joinRtcRoom = async (kind, id, users = []) => {
    room = { kind, id, joined: true };
    debug('RTC', 'room_joined', { kind, id, participant_count: users.length });
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
    if (/^(voice|call)_/.test(msg.type || '')) debug('RTC', 'server_event', { message: msg });
    if (['voice_state', 'call_state', 'voice_peer_joined', 'call_peer_joined', 'call_ringing', 'call_incoming'].includes(msg.type)) markActive();
    if (msg.type === 'voice_state') joinRtcRoom('voice', msg.channel_id, msg.users || []).catch(() => {});
    if (msg.type === 'call_state') joinRtcRoom('call', msg.conversation_id, msg.users || []).catch(() => {});
    if (msg.type === 'call_peer_left' || msg.type === 'voice_peer_left') closePeer(Number(msg.user_id));
    if (msg.type === 'voice_signal' || msg.type === 'call_signal') handleSignal(msg).catch(() => {});
    if (['call_declined', 'call_cancelled', 'call_missed', 'call_ended'].includes(msg.type)) leaveRtcRoom();
    if (msg.type === 'call_accepted') stopRingtones();
  };

  const setMuted = (muted) => {
    micMuted = !!muted;
    if (localStream) localStream.getAudioTracks().forEach((t) => { t.enabled = !micMuted; });
    debug('MEDIA', 'microphone_muted_changed', { muted: micMuted, tracks: localStream?.getAudioTracks().length || 0 });
  };

  const setDeafened = (value) => {
    deafened = !!value;
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((el) => { el.muted = deafened; });
    if (deafened) setMuted(true);
    debug('MEDIA', 'deafened_changed', { deafened });
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
    if (!/^image\/(jpeg|png|gif|webp|avif)$/i.test(file.type)) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Use a JPEG, PNG, GIF, WebP, or AVIF image.' });
      return;
    }
    if (file.size > 8 * 1024 * 1024) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Profile images and GIFs can be up to 8 MB.' });
      return;
    }
    const reader = new FileReader();
    reader.onload = () => send(app.ports.fileInput, { id, data: reader.result });
    reader.onerror = () => send(app.ports.bridgeReceive, { tag: 'toast', data: 'The browser could not read that image.' });
    reader.readAsDataURL(file);
  });
  recv(app.ports.requestNotifyPermission, () => {
    if ('Notification' in window && Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  });
  recv(app.ports.bridgeSend, ({ tag, data }) => {
    debug('ELM', 'command', { tag, data });
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
      case 'remove_friend':
        api({ method: 'POST', path: '/friends/remove', body: { user_id: data } }).then(() => {
          api({ method: 'GET', path: '/sync?since=0' });
        });
        break;
      case 'accept_message_request':
        api({ method: 'POST', path: '/conversation/' + data + '/request/accept', body: {} }).then(() => {
          api({ method: 'GET', path: '/sync?since=0' });
          location.hash = '#dm/' + data;
        });
        break;
      case 'deny_message_request':
        api({ method: 'POST', path: '/conversation/' + data + '/request/deny', body: {} }).then(() => {
          api({ method: 'GET', path: '/sync?since=0' });
          if (location.hash === '#dm/' + data) location.hash = '#dms';
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
            room = { kind: 'call', id: res.id, joined: false };
            ensureMedia()
              .then(() => {
                stopRingtones();
                outgoingTimer = setInterval(() => playTone({ freq: 520, dur: 140, type: 'triangle', vol: 0.12 }), 900);
                sendWs({ type: 'call_ring', conversation_id: res.id });
              })
              .catch(() => {
                room = null;
                stopRingtones();
                send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
                send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
              });
          }
        });
        break;
      case 'start_call':
        room = { kind: 'call', id: data, joined: false };
        ensureMedia()
          .then(() => {
            stopRingtones();
            outgoingTimer = setInterval(() => playTone({ freq: 520, dur: 140, type: 'triangle', vol: 0.12 }), 900);
            sendWs({ type: 'call_ring', conversation_id: data });
          })
          .catch(() => {
            room = null;
            stopRingtones();
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
          });
        break;
      case 'join_voice':
        leaveRtcRoom();
        room = { kind: 'voice', id: data, joined: false };
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
        room = { kind: 'call', id: data, joined: false };
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
        stopPendingCallMedia();
        break;
      case 'cancel_call':
        sendWs({ type: 'call_cancel', conversation_id: data });
        leaveRtcRoom();
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
      case 'ui_density':
        localStorage.setItem('plainwire_density', data === 'compact' ? 'compact' : 'comfortable');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: data === 'compact' ? 'Compact layout enabled' : 'Comfortable layout enabled' });
        break;
      case 'reduce_motion':
        localStorage.setItem('plainwire_reduce_motion', data ? 'true' : 'false');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: data ? 'Reduced motion enabled' : 'Standard motion enabled' });
        break;
      case 'request_notifications':
        if ('Notification' in window) {
          Notification.requestPermission().then((permission) => {
            send(app.ports.bridgeReceive, { tag: 'toast', data: permission === 'granted' ? 'Desktop notifications enabled' : 'Notifications were not enabled' });
          }).catch(() => {});
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
  window.addEventListener('online', () => debug('NETWORK', 'browser_online'));
  window.addEventListener('offline', () => debug('NETWORK', 'browser_offline', {}, 'warn'));
  window.addEventListener('unhandledrejection', (event) => debug('ERROR', 'unhandled_promise_rejection', { error: event.reason?.message || String(event.reason) }, 'error'));
  window.addEventListener('error', (event) => {
    if (event.target !== window) return;
    debug('ERROR', 'uncaught_exception', { error: event.message, file: event.filename, line: event.lineno, column: event.colno }, 'error');
  });
  document.addEventListener('error', (event) => {
    const target = event.target;
    if (!(target instanceof HTMLImageElement)) return;
    target.removeAttribute('src');
    target.removeAttribute('srcset');
    target.alt = '';
    target.classList.add('image-failed');
  }, true);
  window.addEventListener('pagehide', cleanupRtcMedia);
  window.addEventListener('beforeunload', cleanupRtcMedia);
  enableDrag();
  document.addEventListener('click', () => audioContext()?.resume?.(), { once: true });
})();
