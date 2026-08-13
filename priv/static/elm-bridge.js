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
  let localMicrophoneLease = null;
  let microphoneRequest = null;
  let microphoneEpoch = 0;
  let room = null;
  let roomEpoch = 0;
  const RTC_RESUME_KEY = 'plainwire_rtc_room';
  const RTC_RESUME_MAX_AGE_MS = 60000;
  let resumeAttempted = false;
  let resumeInFlight = false;
  let speakerOn = true;
  let micMuted = false;
  let deafened = false;
  let selectedInputId = localStorage.getItem('plainwire_audio_input') || '';
  let selectedOutputId = localStorage.getItem('plainwire_audio_output') || '';
  const normalizeProcessingMode = (value) => ['noise', 'studio', 'krisp'].includes(value) ? value : 'noise';
  let voiceProcessingMode = normalizeProcessingMode(localStorage.getItem('plainwire_voice_processing') || 'noise');
  let voiceProcessingConfig = {
    krisp_available: false,
    sdk_url: '/assets/krisp/krispsdk.mjs',
    model_8_url: '/assets/krisp/models/model_8.kef',
    model_nc_url: '/assets/krisp/models/model_nc_mq.kef'
  };
  let voiceProcessingConfigRequest = null;
  let krispModuleRequest = null;
  let micMonitoring = false;
  let remoteAudioUnlockInstalled = false;
  let audioUnlockToastShown = false;
  const peers = new Map();
  let screenStream = null;
  let screenSenders = new Map(); // uid -> RTCRtpSender for video
  const displayMediaSupported = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia);
  const peerPromises = new Map();
  const signalQueues = new Map();
  const defaultRtcConfig = { iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }] };
  const RTC_CONNECT_CHECK_MS = 8000;
  const RTC_MAX_RECOVERY_ATTEMPTS = 4;
  let rtcConfig = window.PLAINWIRE_RTC_CONFIG || defaultRtcConfig;
  let rtcConfigRequest = null;
  let rtcConfigFetchedAt = 0;
  const presenceWatch = new Set();
  let messageScrollSnapshot = null;
  let messageListElement = null;
  let messagesPinnedToBottom = true;
  let presenceWatchTimer = null;
  let vad = null;
  let micTest = null;
  let wsPingTimer = null;
  let syncInFlight = null;
  let syncQueued = false;
  const screenSharers = new Set();
  // very noisy. off unless somebody actually asks for it.
  const debugEnabled = window.PLAINWIRE_DEBUG === true || localStorage.getItem('plainwire_debug') === 'true';
  const startedAt = performance.now();
  const readRtcIntent = () => {
    try {
      const value = JSON.parse(sessionStorage.getItem(RTC_RESUME_KEY) || 'null');
      const validKind = value?.kind === 'call' || value?.kind === 'voice';
      const id = Number(value?.id || 0);
      const fresh = Number.isFinite(value?.at) && Date.now() - value.at <= RTC_RESUME_MAX_AGE_MS;
      if (!validKind || !Number.isInteger(id) || id <= 0 || !fresh) {
        sessionStorage.removeItem(RTC_RESUME_KEY);
        return null;
      }
      return { kind: value.kind, id, muted: value.muted === true, deafened: value.deafened === true, at: value.at };
    } catch (_) {
      try { sessionStorage.removeItem(RTC_RESUME_KEY); } catch (_) {}
      return null;
    }
  };
  let resumeIntent = readRtcIntent();
  const clearRtcIntent = () => {
    resumeIntent = null;
    try { sessionStorage.removeItem(RTC_RESUME_KEY); } catch (_) {}
  };
  const persistRtcIntent = () => {
    if (!room?.joined) return;
    resumeIntent = { kind: room.kind, id: room.id, muted: micMuted, deafened, at: Date.now() };
    try { sessionStorage.setItem(RTC_RESUME_KEY, JSON.stringify(resumeIntent)); } catch (_) {}
  };
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
      peers: Array.from(peers, ([user_id, pc]) => ({
        user_id, connection: pc.connectionState, ice: pc.iceConnectionState,
        signaling: pc.signalingState, offerer: pc._offerer,
        recovery_attempts: pc._reconnectAttempts || 0,
        failed: pc._failureReported === true
      }))
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

  const krispAssetPath = (value, fallback) =>
    typeof value === 'string' && value.startsWith('/assets/krisp/') ? value : fallback;

  const loadVoiceProcessingConfig = () => {
    if (voiceProcessingConfigRequest) return voiceProcessingConfigRequest;
    voiceProcessingConfigRequest = fetch('/api/voice-processing-config', { headers: { accept: 'application/json' } })
      .then((res) => res.ok ? res.json() : null)
      .then((json) => {
        const config = json && json.ok && json.data;
        if (config) {
          voiceProcessingConfig = {
            krisp_available: config.krisp_available === true,
            sdk_url: krispAssetPath(config.sdk_url, voiceProcessingConfig.sdk_url),
            model_8_url: krispAssetPath(config.model_8_url, voiceProcessingConfig.model_8_url),
            model_nc_url: krispAssetPath(config.model_nc_url, voiceProcessingConfig.model_nc_url)
          };
        }
        if (voiceProcessingMode === 'krisp' && !voiceProcessingConfig.krisp_available) {
          voiceProcessingMode = 'noise';
          localStorage.setItem('plainwire_voice_processing', voiceProcessingMode);
        }
        debug('MEDIA', 'voice_processing_config_loaded', { krisp_available: voiceProcessingConfig.krisp_available });
        return voiceProcessingConfig;
      })
      .catch((error) => {
        debug('MEDIA', 'voice_processing_config_failed', { error: error.message }, 'warn');
        return voiceProcessingConfig;
      });
    return voiceProcessingConfigRequest;
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
  let lastActivityHandledAt = 0;
  const activityHandler = () => {
    const now = Date.now();
    // one poke a second is plenty for a ten minute idle timer.
    if (now - lastActivityHandledAt < 1000) return;
    lastActivityHandledAt = now;
    resetIdleTimer();
  };
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
  send(app.ports.bridgeReceive, {
    tag: 'sound_preference',
    data: localStorage.getItem('plainwire_sound_enabled') !== 'false'
  });

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

  let historyObserver = null;
  let historySentinel = null;
  let historyRoot = null;
  const mediaTime = (seconds) => {
    if (!Number.isFinite(seconds) || seconds < 0) return '–:––';
    const whole = Math.floor(seconds);
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
  };

  const mountMediaPlayers = () => {
    document.querySelectorAll('.pw-media-player:not([data-player-ready])').forEach((player) => {
      const media = player.querySelector('audio, video');
      const playButtons = Array.from(player.querySelectorAll('[data-media-action="play"]'));
      const mute = player.querySelector('[data-media-action="mute"]');
      const fullscreen = player.querySelector('[data-media-action="fullscreen"]');
      const seek = player.querySelector('.pw-media-seek');
      const volume = player.querySelector('.pw-media-volume');
      const elapsed = player.querySelector('.pw-media-time');
      const duration = player.querySelector('.pw-media-duration');
      if (!media || !playButtons.length || !seek) return;

      player.dataset.playerReady = 'true';
      let scrubbing = false;
      let resumeAfterScrub = false;
      const savedVolume = Number(localStorage.getItem('plainwire_media_volume'));
      media.volume = Number.isFinite(savedVolume) ? Math.max(0, Math.min(1, savedVolume)) : 0.85;
      seek.value = '0';
      if (volume) volume.value = String(media.volume);

      const update = () => {
        const total = media.duration;
        if (!scrubbing) seek.value = Number.isFinite(total) && total > 0 ? String(Math.round(media.currentTime * 1000 / total)) : '0';
        if (elapsed) elapsed.textContent = mediaTime(media.currentTime);
        if (duration) duration.textContent = mediaTime(total);
        const label = media.paused ? 'Play' : 'Pause';
        playButtons.forEach((button) => {
          button.textContent = label;
          button.setAttribute('aria-label', `${label} media`);
        });
        if (mute) mute.textContent = media.muted || media.volume === 0 ? 'Muted' : 'Sound';
        player.classList.toggle('playing', !media.paused);
        player.classList.toggle('muted', media.muted || media.volume === 0);
      };

      const togglePlayback = () => {
        if (!media.paused) return media.pause();
        document.querySelectorAll('.pw-media-player audio, .pw-media-player video').forEach((other) => {
          if (other !== media) other.pause();
        });
        media.play().catch(() => send(app.ports.bridgeReceive, { tag: 'toast', data: 'Playback was blocked. Tap Play again.' }));
      };
      playButtons.forEach((button) => button.addEventListener('click', togglePlayback));
      if (media instanceof HTMLVideoElement) media.addEventListener('dblclick', () => fullscreen?.click());

      const beginScrub = () => {
        scrubbing = true;
        resumeAfterScrub = !media.paused;
        if (resumeAfterScrub) media.pause();
      };
      const applyScrub = () => {
        if (Number.isFinite(media.duration) && media.duration > 0) {
          media.currentTime = Number(seek.value) * media.duration / 1000;
          if (elapsed) elapsed.textContent = mediaTime(media.currentTime);
        }
      };
      const finishScrub = () => {
        if (!scrubbing) return;
        applyScrub();
        scrubbing = false;
        if (resumeAfterScrub) media.play().catch(() => {});
        resumeAfterScrub = false;
        update();
      };
      seek.addEventListener('pointerdown', (event) => {
        seek.setPointerCapture?.(event.pointerId);
        beginScrub();
      });
      seek.addEventListener('input', applyScrub);
      seek.addEventListener('change', finishScrub);
      seek.addEventListener('pointerup', finishScrub);
      seek.addEventListener('pointercancel', finishScrub);
      seek.addEventListener('lostpointercapture', finishScrub);

      volume?.addEventListener('input', () => {
        const next = Math.max(0, Math.min(1, Number(volume.value)));
        media.volume = next;
        media.muted = false;
        localStorage.setItem('plainwire_media_volume', String(next));
        update();
      });
      mute?.addEventListener('click', () => { media.muted = !media.muted; update(); });
      fullscreen?.addEventListener('click', () => {
        const target = player.querySelector('.pw-video-frame') || media;
        if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
        else target.requestFullscreen?.().catch(() => media.webkitEnterFullscreen?.());
      });

      ['loadedmetadata', 'durationchange', 'timeupdate', 'play', 'pause', 'volumechange', 'ended'].forEach((event) => media.addEventListener(event, update));
      media.addEventListener('error', () => player.classList.add('media-error'));
      update();
    });
  };

  const trackMessageScroll = () => {
    const list = document.getElementById('messages');
    if (!list || list === messageListElement) return list;
    messageListElement = list;
    messagesPinnedToBottom = true;
    list.addEventListener('scroll', () => {
      messagesPinnedToBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 120;
    }, { passive: true });
    return list;
  };

  const observeMessageHistory = () => {
    const list = trackMessageScroll();
    const sentinel = document.getElementById('message-history-sentinel');
    if (!list || !sentinel || typeof IntersectionObserver === 'undefined') return;
    if (historySentinel === sentinel && historyRoot === list) return;
    if (historyObserver) historyObserver.disconnect();
    historySentinel = sentinel;
    historyRoot = list;
    historyObserver = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        send(app.ports.bridgeReceive, { tag: 'load_more_messages' });
      }
    }, { root: list, rootMargin: '320px 0px 0px', threshold: 0 });
    historyObserver.observe(sentinel);
  };

  let callTimerId = null;
  const updateCallTimers = () => {
    const timers = Array.from(document.querySelectorAll('.pw-live-call-timer[data-call-start]'));
    if (!timers.length) {
      if (callTimerId) clearInterval(callTimerId);
      callTimerId = null;
      return;
    }
    timers.forEach((timer) => {
      const started = Number(timer.dataset.callStart || 0);
      const seconds = Math.max(0, Math.floor((Date.now() - started) / 1000));
      timer.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
    });
    if (!callTimerId) callTimerId = setInterval(updateCallTimers, 1000);
  };

  let messageDomFrame = 0;
  const messageDomObserver = new MutationObserver((records) => {
    const relevantSelector = '#messages, #message-history-sentinel, .pw-media-player, .pw-live-call-timer';
    const relevant = records.some((record) => [...record.addedNodes, ...record.removedNodes].some((node) =>
      node.nodeType === Node.ELEMENT_NODE && (node.matches?.(relevantSelector) || node.querySelector?.(relevantSelector))
    ));
    if (!relevant) return;
    if (messageDomFrame) return;
    messageDomFrame = requestAnimationFrame(() => {
      messageDomFrame = 0;
      trackMessageScroll();
      observeMessageHistory();
      mountMediaPlayers();
      updateCallTimers();
    });
  });
  messageDomObserver.observe(root, { childList: true, subtree: true });
  trackMessageScroll();
  observeMessageHistory();
  mountMediaPlayers();
  updateCallTimers();

  const audioContext = () => {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    audioCtx = audioCtx || new Ctx();
    return audioCtx;
  };

  const soundNodes = new Set();
  const playTone = ({ freq = 660, endFreq = freq, dur = 120, delay = 0, type = 'sine', vol = 0.1 } = {}) => {
    const ctx = audioContext();
    if (!ctx || ctx.state === 'closed') return null;
    const start = ctx.currentTime + Math.max(0, delay) / 1000;
    const stop = start + Math.max(40, dur) / 1000;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, start);
    osc.frequency.exponentialRampToValueAtTime(Math.max(40, endFreq), stop);
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, vol), start + 0.018);
    gain.gain.exponentialRampToValueAtTime(0.0001, stop);
    osc.connect(gain);
    gain.connect(ctx.destination);
    soundNodes.add(osc);
    osc.onended = () => {
      soundNodes.delete(osc);
      try { osc.disconnect(); gain.disconnect(); } catch (_) {}
    };
    osc.start(start);
    osc.stop(stop + 0.01);
    return osc;
  };

  const playSound = (name) => {
    if (name === 'notification') {
      playTone({ freq: 659.25, endFreq: 698.46, dur: 105, vol: 0.055 });
      playTone({ freq: 880, endFreq: 932.33, dur: 145, delay: 92, vol: 0.045 });
    } else if (name === 'incoming') {
      playTone({ freq: 523.25, endFreq: 554.37, dur: 230, vol: 0.05 });
      playTone({ freq: 659.25, endFreq: 698.46, dur: 260, delay: 190, vol: 0.045 });
      playTone({ freq: 783.99, endFreq: 830.61, dur: 330, delay: 390, vol: 0.04 });
    } else if (name === 'outgoing') {
      playTone({ freq: 440, endFreq: 466.16, dur: 180, vol: 0.035 });
      playTone({ freq: 554.37, endFreq: 587.33, dur: 220, delay: 175, vol: 0.03 });
    }
  };

  const stopRingtones = () => {
    if (ringtoneTimer) clearInterval(ringtoneTimer);
    if (outgoingTimer) clearInterval(outgoingTimer);
    ringtoneTimer = null;
    outgoingTimer = null;
  };

  const startRingtone = (kind) => {
    stopRingtones();
    if (kind === 'incoming') {
      playSound('incoming');
      ringtoneTimer = setInterval(() => playSound('incoming'), 2600);
    } else {
      playSound('outgoing');
      outgoingTimer = setInterval(() => playSound('outgoing'), 3000);
    }
  };

  const performApi = async ({ method = 'GET', path, body }) => {
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
      if (json.ok && json.data) updatePresenceWatch(json.data);
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

  // fold sync bursts into one request, plus one encore if needed.
  const api = (request) => {
    const isFullSync = (request.method || 'GET') === 'GET' && request.path === '/sync?since=0';
    if (!isFullSync) return performApi(request);
    if (syncInFlight) {
      syncQueued = true;
      return syncInFlight;
    }
    syncInFlight = performApi(request).finally(() => {
      syncInFlight = null;
      if (syncQueued) {
        syncQueued = false;
        queueMicrotask(() => api(request));
      }
    });
    return syncInFlight;
  };

  const activeComposer = () => {
    const composers = Array.from(document.querySelectorAll('#compose'));
    return composers.reverse().find((element) => element.offsetParent !== null) || null;
  };

  const appendToComposer = (text) => {
    const composer = activeComposer();
    if (!composer) return;
    composer.value += composer.value && !composer.value.endsWith('\n') ? '\n' + text : text;
    composer.dispatchEvent(new Event('input', { bubbles: true }));
    composer.focus();
  };

  const uploadOne = (file) => new Promise((resolve, reject) => {
    if (!file || file.size <= 0) return reject(new Error('empty_file'));
    if (file.size > 250 * 1024 * 1024) return reject(new Error('file_too_large'));
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/uploads');
    xhr.responseType = 'json';
    xhr.setRequestHeader('x-csrf-token', csrf);
    xhr.setRequestHeader('x-file-name', encodeURIComponent(file.name || 'pasted-image'));
    xhr.setRequestHeader('content-type', file.type || 'application/octet-stream');
    let lastProgressAt = 0;
    let lastProgress = -1;
    xhr.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      const now = performance.now();
      const progress = Math.round(event.loaded * 100 / event.total);
      if (progress < 100 && progress - lastProgress < 5 && now - lastProgressAt < 250) return;
      lastProgressAt = now;
      lastProgress = progress;
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Uploading ${file.name || 'image'}… ${progress}%` });
    };
    xhr.onload = () => {
      const json = xhr.response;
      if (xhr.status >= 200 && xhr.status < 300 && json?.ok && json.data) resolve(json.data);
      else reject(new Error(json?.error || 'upload_failed'));
    };
    xhr.onerror = () => reject(new Error('network_error'));
    xhr.onabort = () => reject(new Error('upload_cancelled'));
    xhr.send(file);
  });

  const uploadFiles = async (files) => {
    for (const file of Array.from(files || []).slice(0, 10)) {
      try {
        const uploaded = await uploadOne(file);
        const safeName = String(uploaded.name || 'file').replace(/[\]()[\r\n]/g, '_');
        const markup = String(uploaded.content_type || '').startsWith('image/')
          ? `![${safeName}](${uploaded.url})` : `[${safeName}](${uploaded.url})`;
        appendToComposer(markup);
        send(app.ports.bridgeReceive, { tag: 'toast', data: `${safeName} ready to send` });
      } catch (error) {
        const messages = { file_too_large: 'Files can be up to 250 MB.', upload_quota_exceeded: 'Upload limit reached: 1 GB every 3 hours.', network_error: 'Upload connection interrupted.' };
        send(app.ports.bridgeReceive, { tag: 'toast', data: messages[error.message] || 'File upload failed. Please try again.' });
      }
    }
  };

  const attachmentInput = document.createElement('input');
  attachmentInput.type = 'file';
  attachmentInput.multiple = true;
  attachmentInput.hidden = true;
  attachmentInput.addEventListener('change', () => { uploadFiles(attachmentInput.files); attachmentInput.value = ''; });
  document.body.appendChild(attachmentInput);
  document.addEventListener('paste', (event) => {
    if (document.activeElement !== activeComposer()) return;
    const files = Array.from(event.clipboardData?.files || []);
    if (files.length) { event.preventDefault(); uploadFiles(files); }
  });
  document.addEventListener('dragover', (event) => { if (activeComposer()) event.preventDefault(); });
  document.addEventListener('drop', (event) => {
    if (!activeComposer()) return;
    const files = Array.from(event.dataTransfer?.files || []);
    if (files.length) { event.preventDefault(); uploadFiles(files); }
  });

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
      send(app.ports.bridgeReceive, { tag: 'ws_status', data: true });
      queued.forEach((value) => sendWs(value));
      publishPresence(true);
      if (room && room.joined && localStream) {
        const join = room.kind === 'voice'
          ? { type: 'voice_join', channel_id: room.id }
          : { type: 'call_join', conversation_id: room.id };
        sendWs(join);
      }
      if (wsPingTimer) clearInterval(wsPingTimer);
      wsPingTimer = setInterval(() => { if (ws && ws.readyState === WebSocket.OPEN) sendWs({ type: 'ping' }); }, 60000);
    };
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        debug('WS', 'received', { message: msg });
        if (msg.session && msg.session.user && msg.session.user.id) meId = msg.session.user.id;
        if (msg.type === 'hello') maybeResumeRtcRoom();
        handlePresenceEvent(msg);
        handleRtcEvent(msg);
        send(app.ports.wsReceive, msg);
      } catch (error) { debug('WS', 'invalid_message', { error: error.message, bytes: String(event.data).length }, 'error'); }
    };
    ws.onerror = () => debug('WS', 'transport_error', { ready_state: ws?.readyState }, 'error');
    ws.onclose = (event) => {
      debug('WS', 'closed', { code: event.code, reason: event.reason || '(none)', clean: event.wasClean, reconnect_ms: 800 }, 'warn');
      if (wsPingTimer) { clearInterval(wsPingTimer); wsPingTimer = null; }
      send(app.ports.bridgeReceive, { tag: 'ws_status', data: false });
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

  const updatePresenceWatch = (data) => {
    const before = presenceWatch.size;
    const visit = (value, depth = 0) => {
      if (!value || typeof value !== 'object' || depth > 6 || presenceWatch.size >= 2000) return;
      if (Number.isInteger(value.id) && value.id > 0 && (typeof value.username === 'string' || typeof value.display_name === 'string')) {
        // include self too; other tabs may have changed its status.
        presenceWatch.add(value.id);
      }
      if (Array.isArray(value)) value.forEach((item) => visit(item, depth + 1));
      else Object.values(value).forEach((item) => visit(item, depth + 1));
    };
    visit(data);
    if (presenceWatch.size === before) return;
    if (presenceWatchTimer) clearTimeout(presenceWatchTimer);
    presenceWatchTimer = setTimeout(() => {
      presenceWatchTimer = null;
      sendWs({ type: 'presence_watch', user_ids: Array.from(presenceWatch) });
      debug('PRESENCE', 'watch_updated', { users: presenceWatch.size });
    }, 100);
  };

  const microphoneConstraints = (mode = voiceProcessingMode) => {
    const processing = mode === 'studio'
      ? { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: { ideal: 2 }, sampleRate: { ideal: 48000 } }
      : mode === 'krisp'
        ? { echoCancellation: true, noiseSuppression: false, autoGainControl: false, channelCount: { ideal: 1 } }
        : { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: { ideal: 1 } };
    return { ...processing, ...(selectedInputId ? { deviceId: { exact: selectedInputId } } : {}) };
  };

  const stopStream = (stream) => stream?.getTracks?.().forEach((track) => track.stop());
  const openRawMicrophone = (mode = voiceProcessingMode) =>
    navigator.mediaDevices.getUserMedia({ audio: microphoneConstraints(mode), video: false });

  const nativeMicrophoneLease = (stream, mode) => {
    let released = false;
    return {
      stream,
      rawStream: stream,
      mode,
      release: async () => {
        if (released) return;
        released = true;
        stopStream(stream);
      }
    };
  };

  const loadKrispModule = async () => {
    await loadVoiceProcessingConfig();
    if (!voiceProcessingConfig.krisp_available) throw new Error('Krisp SDK assets are not installed');
    if (!krispModuleRequest) {
      krispModuleRequest = import(voiceProcessingConfig.sdk_url).catch((error) => {
        krispModuleRequest = null;
        throw error;
      });
    }
    const module = await krispModuleRequest;
    const KrispSDK = module.default || module.KrispSDK;
    if (typeof KrispSDK !== 'function') throw new Error('Krisp SDK module is invalid');
    if (typeof KrispSDK.isSupported === 'function' && !KrispSDK.isSupported()) {
      throw new Error('Krisp is not supported by this browser');
    }
    return KrispSDK;
  };

  const krispMicrophoneLease = async () => {
    const KrispSDK = await loadKrispModule();
    const rawStream = await openRawMicrophone('krisp');
    const ctx = audioContext();
    let sdk = null;
    let source = null;
    let destination = null;
    let filterNode = null;
    let overflowTimer = null;
    try {
      if (!ctx) throw new Error('AudioContext unavailable');
      await ctx.resume?.();
      sdk = new KrispSDK({
        params: {
          debugLogs: false,
          logProcessStats: false,
          useSharedArrayBuffer: false,
          bufferOverflowMS: 200,
          bufferDropMS: 400,
          models: {
            model8: voiceProcessingConfig.model_8_url,
            modelNC: voiceProcessingConfig.model_nc_url
          }
        },
        callbacks: {
          errorCallback: (error) => debug('MEDIA', 'krisp_sdk_error', { error: error?.message || String(error) }, 'error')
        }
      });
      await Promise.resolve(sdk.init());
      let filterReady = false;
      const enableFilter = () => {
        filterReady = true;
        try { filterNode?.enable(); } catch (_) {}
        debug('MEDIA', 'krisp_filter_ready');
      };
      filterNode = await sdk.createNoiseFilter(ctx, enableFilter);
      filterNode.addEventListener?.('ready', enableFilter, { once: true });
      if (filterReady) filterNode.enable();
      source = ctx.createMediaStreamSource(rawStream);
      destination = ctx.createMediaStreamDestination();
      source.connect(filterNode);
      filterNode.connect(destination);
      filterNode.addEventListener?.('error', (event) => {
        const details = event?.data || {};
        debug('MEDIA', 'krisp_filter_error', { code: details.errorCode, error: details.errorMessage }, 'error');
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Krisp had a processing error; audio is passing through.' });
        try { filterNode.disable(); } catch (_) {}
      });
      filterNode.addEventListener?.('buffer_overflow', (event) => {
        if (overflowTimer) clearTimeout(overflowTimer);
        const count = Math.max(1, Number(event?.data?.overflowCount || 1));
        try { filterNode.disable(); } catch (_) {}
        if (count < 4) {
          overflowTimer = setTimeout(() => {
            try { filterNode?.enable(); } catch (_) {}
          }, Math.min(80000, 10000 * (2 ** count)));
        }
        debug('MEDIA', 'krisp_buffer_overflow', { count }, 'warn');
      });
      const stream = destination.stream;
      let released = false;
      return {
        stream,
        rawStream,
        mode: 'krisp',
        release: async () => {
          if (released) return;
          released = true;
          if (overflowTimer) clearTimeout(overflowTimer);
          stopStream(stream);
          stopStream(rawStream);
          try { source?.disconnect(); } catch (_) {}
          try { filterNode?.disconnect(); } catch (_) {}
          try { destination?.disconnect(); } catch (_) {}
          try { await filterNode?.dispose?.(); } catch (_) {}
          try { sdk?.dispose?.(); } catch (_) {}
        }
      };
    } catch (error) {
      if (overflowTimer) clearTimeout(overflowTimer);
      stopStream(rawStream);
      try { source?.disconnect(); } catch (_) {}
      try { filterNode?.disconnect(); } catch (_) {}
      try { destination?.disconnect(); } catch (_) {}
      try { await filterNode?.dispose?.(); } catch (_) {}
      try { sdk?.dispose?.(); } catch (_) {}
      throw error;
    }
  };

  const prepareMicrophone = async () => {
    const mode = voiceProcessingMode;
    debug('MEDIA', 'microphone_request', { selected_input: selectedInputId || 'default', processing_mode: mode });
    if (mode === 'krisp') return krispMicrophoneLease();
    return nativeMicrophoneLease(await openRawMicrophone(mode), mode);
  };

  const observeMicrophoneTracks = (stream) => {
    stream.getAudioTracks().forEach((track) => {
      track.enabled = !micMuted;
      debug('MEDIA', 'microphone_track', { label: track.label, enabled: track.enabled, settings: track.getSettings?.(), processing_mode: voiceProcessingMode });
      track.onended = () => debug('MEDIA', 'microphone_track_ended', { label: track.label }, 'warn');
      track.onmute = () => debug('MEDIA', 'microphone_track_muted', { label: track.label }, 'warn');
      track.onunmute = () => debug('MEDIA', 'microphone_track_unmuted', { label: track.label });
    });
  };

  const releaseCurrentMicrophone = () => {
    microphoneEpoch++;
    const lease = localMicrophoneLease;
    const stream = localStream;
    if (micTest?.stream === stream) stopMicTest();
    localMicrophoneLease = null;
    localStream = null;
    stopVoiceDetection();
    if (lease) lease.release().catch(() => {});
    else stopStream(stream);
  };

  const ensureMedia = async () => {
    if (localStream && localMicrophoneLease?.mode === voiceProcessingMode && localStream.getAudioTracks().some((track) => track.readyState === 'live')) {
      debug('MEDIA', 'reusing_microphone', { tracks: localStream.getAudioTracks().length, processing_mode: voiceProcessingMode });
      return localStream;
    }
    if (microphoneRequest) {
      try { await microphoneRequest; } catch (_) {}
      return ensureMedia();
    }
    microphoneRequest = (async () => {
      releaseCurrentMicrophone();
      const requestEpoch = microphoneEpoch;
      try {
        const lease = await prepareMicrophone();
        if (requestEpoch !== microphoneEpoch) {
          await lease.release();
          throw new Error('microphone_request_cancelled');
        }
        localMicrophoneLease = lease;
        localStream = lease.stream;
        observeMicrophoneTracks(localStream);
        startVoiceDetection(localStream);
        return localStream;
      } catch (error) {
        debug('MEDIA', 'microphone_failed', { name: error.name, error: error.message, processing_mode: voiceProcessingMode }, error.message === 'microphone_request_cancelled' ? 'warn' : 'error');
        if (error.message !== 'microphone_request_cancelled') {
          send(app.ports.bridgeReceive, { tag: 'toast', data: voiceProcessingMode === 'krisp' ? 'Krisp could not start. Choose another microphone mode.' : 'Microphone access is needed for calls.' });
        }
        throw error;
      }
    })().finally(() => { microphoneRequest = null; });
    return microphoneRequest;
  };

  const publishAudioDevices = async () => {
    if (!navigator.mediaDevices?.enumerateDevices) return;
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const normalize = (device, index) => ({
        id: device.deviceId,
        label: device.label || `${device.kind === 'audioinput' ? 'Microphone' : 'Speaker'} ${index + 1}`
      });
      const inputs = devices.filter((device) => device.kind === 'audioinput').map(normalize);
      const outputs = devices.filter((device) => device.kind === 'audiooutput').map(normalize);
      send(app.ports.bridgeReceive, { tag: 'audio_devices', data: {
        inputs,
        outputs,
        selected_input: selectedInputId,
        selected_output: selectedOutputId,
        output_selection_supported: typeof HTMLMediaElement.prototype.setSinkId === 'function',
        processing_mode: voiceProcessingMode,
        krisp_available: voiceProcessingConfig.krisp_available,
        mic_monitoring: micMonitoring
      }});
    } catch (error) {
      debug('MEDIA', 'device_enumeration_failed', { error: error.message }, 'warn');
    }
  };

  const rebuildLocalMicrophone = async () => {
    if (!localStream) return false;
    const changeEpoch = ++microphoneEpoch;
    const previousLease = localMicrophoneLease;
    const previousStream = localStream;
    const replacementLease = await prepareMicrophone();
    if (changeEpoch !== microphoneEpoch) {
      await replacementLease.release();
      throw new Error('microphone_request_cancelled');
    }
    const track = replacementLease.stream.getAudioTracks()[0];
    if (!track) {
      await replacementLease.release();
      throw new Error('No microphone track');
    }
    track.enabled = !micMuted;
    try {
      await Promise.all(Array.from(peers.values()).map((pc) => pc._audioSender ? pc._audioSender.replaceTrack(track) : Promise.resolve()));
    } catch (error) {
      await replacementLease.release();
      throw error;
    }
    localMicrophoneLease = replacementLease;
    localStream = replacementLease.stream;
    observeMicrophoneTracks(localStream);
    startVoiceDetection(localStream);
    if (previousLease) previousLease.release().catch(() => {});
    else stopStream(previousStream);
    return true;
  };

  const replaceMicrophone = async (deviceId) => {
    const previousId = selectedInputId;
    selectedInputId = String(deviceId || '');
    localStorage.setItem('plainwire_audio_input', selectedInputId);
    try {
      const changed = await rebuildLocalMicrophone();
      if (changed) send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone changed' });
    } catch (error) {
      selectedInputId = previousId;
      localStorage.setItem('plainwire_audio_input', selectedInputId);
      debug('MEDIA', 'microphone_change_failed', { error: error.message }, 'error');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not switch microphones.' });
    }
    await publishAudioDevices();
  };

  const replaceVoiceProcessing = async (requestedMode) => {
    const nextMode = normalizeProcessingMode(requestedMode);
    await loadVoiceProcessingConfig();
    if (nextMode === 'krisp' && !voiceProcessingConfig.krisp_available) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Install the licensed Krisp browser SDK and models on the server first.' });
      return publishAudioDevices();
    }
    const previousMode = voiceProcessingMode;
    if (nextMode === previousMode) return publishAudioDevices();
    voiceProcessingMode = nextMode;
    localStorage.setItem('plainwire_voice_processing', voiceProcessingMode);
    try {
      const changed = await rebuildLocalMicrophone();
      if (changed) send(app.ports.bridgeReceive, { tag: 'toast', data: nextMode === 'studio' ? 'Studio microphone enabled' : nextMode === 'krisp' ? 'Krisp noise cancellation enabled' : 'Noise cancellation enabled' });
    } catch (error) {
      voiceProcessingMode = previousMode;
      localStorage.setItem('plainwire_voice_processing', voiceProcessingMode);
      debug('MEDIA', 'voice_processing_change_failed', { requested_mode: nextMode, error: error.message }, 'error');
      send(app.ports.bridgeReceive, { tag: 'toast', data: nextMode === 'krisp' ? 'Krisp could not start in this browser.' : 'Could not change microphone processing.' });
    }
    await publishAudioDevices();
  };

  const stopMicTest = () => {
    if (!micTest) return;
    const current = micTest;
    micTest = null;
    micMonitoring = false;
    clearTimeout(current.frame);
    try { current.source.disconnect(); current.analyser.disconnect(); } catch (_) {}
    current.monitor.pause();
    current.monitor.srcObject = null;
    current.monitor.remove();
    if (current.lease) current.lease.release().catch(() => {});
    send(app.ports.bridgeReceive, { tag: 'mic_test_level', data: 0 });
    publishAudioDevices().catch(() => {});
  };

  const setMicMonitor = async (enabled) => {
    if (!micTest) {
      micMonitoring = false;
      return publishAudioDevices();
    }
    micMonitoring = !!enabled;
    micTest.monitoring = micMonitoring;
    if (!micMonitoring) {
      micTest.monitor.pause();
      return publishAudioDevices();
    }
    try {
      await audioContext()?.resume?.();
      if (selectedOutputId && typeof micTest.monitor.setSinkId === 'function') await micTest.monitor.setSinkId(selectedOutputId);
      await micTest.monitor.play();
    } catch (error) {
      micMonitoring = false;
      micTest.monitoring = false;
      debug('MEDIA', 'microphone_monitor_failed', { error: error.message }, 'warn');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'The browser blocked microphone playback. Try again after clicking the page.' });
    }
    await publishAudioDevices();
  };

  const startMicTest = async () => {
    stopMicTest();
    let testLease = null;
    try {
      const reuse = !micMuted && localStream?.getAudioTracks().some((track) => track.readyState === 'live');
      testLease = reuse ? null : await prepareMicrophone();
      const stream = reuse ? localStream : testLease.stream;
      const ctx = audioContext();
      if (!ctx) throw new Error('AudioContext unavailable');
      await ctx.resume?.();
      const analyser = ctx.createAnalyser();
      const source = ctx.createMediaStreamSource(stream);
      const monitor = document.createElement('audio');
      monitor.id = 'pw-mic-monitor';
      monitor.autoplay = false;
      monitor.controls = false;
      monitor.playsInline = true;
      monitor.volume = 0.72;
      monitor.srcObject = stream;
      monitor.hidden = true;
      document.body.appendChild(monitor);
      analyser.fftSize = 512;
      analyser.smoothingTimeConstant = 0.7;
      source.connect(analyser);
      const samples = new Float32Array(analyser.fftSize);
      micTest = { stream, lease: testLease, analyser, source, monitor, monitoring: false, samples, frame: 0, lastSent: 0, lastLevel: -1 };
      testLease = null;
      micMonitoring = false;
      const sample = () => {
        if (!micTest || micTest.analyser !== analyser) return;
        analyser.getFloatTimeDomainData(samples);
        let sum = 0;
        for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
        const rms = Math.sqrt(sum / samples.length);
        const level = Math.max(0, Math.min(100, Math.round((20 * Math.log10(Math.max(rms, 0.00001)) + 60) * 2)));
        const now = performance.now();
        if (Math.abs(level - micTest.lastLevel) >= 2 || now - micTest.lastSent > 250) {
          micTest.lastSent = now;
          micTest.lastLevel = level;
          send(app.ports.bridgeReceive, { tag: 'mic_test_level', data: level });
        }
        micTest.frame = setTimeout(sample, 80);
      };
      micTest.frame = setTimeout(sample, 0);
      await publishAudioDevices();
    } catch (error) {
      if (testLease) testLease.release().catch(() => {});
      stopMicTest();
      debug('MEDIA', 'microphone_test_failed', { error: error.message }, 'error');
      send(app.ports.bridgeReceive, { tag: 'mic_test_failed', data: voiceProcessingMode === 'krisp' ? 'Krisp microphone test could not start.' : 'Microphone test could not start.' });
    }
  };

  const stopVoiceDetection = () => {
    if (!vad) return;
    clearTimeout(vad.frame);
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
    analyser.fftSize = 512;
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
      if (!vad.speaking && vad.above >= 3) { vad.speaking = true; reportVoiceActivity(true, db); }
      if (vad.speaking && vad.below >= 12) { vad.speaking = false; reportVoiceActivity(false, db); }
      vad.frame = setTimeout(sample, 40);
    };
    vad.frame = setTimeout(sample, 0);
  };

  // ---- Floating window system (draggable stage video + preview) ----
  const floatWindows = new Map(); // id -> { wrapper, video, title }
  let floatZIndex = 900;
  const floatPositions = {}; // id -> { x, y }

  const makeFloatWindow = (id, titleText, accentColor, opts = {}) => {
    const wrapper = document.createElement('div');
    wrapper.id = 'pw-float-' + id;
    wrapper.className = 'pw-float';
    wrapper.style.cssText = 'position:fixed;z-index:' + (floatZIndex++) + ';display:none;width:min(560px,calc(100vw - 24px));max-width:calc(100vw - 16px);max-height:calc(100dvh - 24px);transition:box-shadow .15s';
    const saved = floatPositions[id];
    if (saved) { wrapper.style.left = saved.x + 'px'; wrapper.style.top = saved.y + 'px'; }
    else if (opts.right != null && opts.bottom != null) {
      wrapper.style.right = opts.right + 'px';
      wrapper.style.bottom = opts.bottom + 'px';
    }

    const bar = document.createElement('div');
    bar.className = 'pw-float-bar';
    bar.style.cssText = 'display:flex;align-items:center;gap:6px;padding:4px 8px;background:' + accentColor + ';border-radius:8px 8px 0 0;cursor:grab;user-select:none;min-width:180px';

    const title = document.createElement('span');
    title.style.cssText = 'flex:1;color:#fff;font-size:11px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
    title.textContent = titleText;

    const btnFs = document.createElement('button');
    btnFs.className = 'pw-float-btn pw-float-fs';
    btnFs.title = 'Fullscreen';
    btnFs.textContent = '⛶';
    btnFs.style.cssText = 'background:rgba(255,255,255,.2);border:none;color:#fff;width:22px;height:22px;border-radius:4px;cursor:pointer;font-size:13px;line-height:1;display:flex;align-items:center;justify-content:center;transition:background .1s';
    btnFs.addEventListener('mouseenter', () => { btnFs.style.background = 'rgba(255,255,255,.35)'; });
    btnFs.addEventListener('mouseleave', () => { btnFs.style.background = 'rgba(255,255,255,.2)'; });
    btnFs.addEventListener('click', (e) => {
      e.stopPropagation();
      const vid = wrapper.querySelector('video');
      if (vid) {
        if (vid.requestFullscreen) vid.requestFullscreen().catch(() => {});
        else if (vid.webkitRequestFullscreen) vid.webkitRequestFullscreen();
      }
    });

    const btnClose = document.createElement('button');
    btnClose.className = 'pw-float-btn pw-float-close';
    btnClose.title = 'Close';
    btnClose.textContent = '✕';
    btnClose.style.cssText = 'background:rgba(255,255,255,.2);border:none;color:#fff;width:22px;height:22px;border-radius:4px;cursor:pointer;font-size:13px;line-height:1;display:flex;align-items:center;justify-content:center;transition:background .1s';
    btnClose.addEventListener('mouseenter', () => { btnClose.style.background = 'rgba(255,255,255,.35)'; });
    btnClose.addEventListener('mouseleave', () => { btnClose.style.background = 'rgba(255,255,255,.2)'; });
    if (opts.onClose) btnClose.addEventListener('click', (e) => { e.stopPropagation(); opts.onClose(); });

    bar.appendChild(title);
    bar.appendChild(btnFs);
    bar.appendChild(btnClose);

    const video = document.createElement('video');
    video.autoplay = true;
    video.playsInline = true;
    video.muted = true;
    video.controls = false;
    video.style.cssText = 'display:block;width:100%;height:auto;max-height:70vh;border-radius:0 0 8px 8px;background:#000;object-fit:contain';

    wrapper.appendChild(bar);
    wrapper.appendChild(video);
    document.body.appendChild(wrapper);

    // keep this local. the old global listeners bred like rabbits.
    let dragging = false, dragPointer = null, dragOffX = 0, dragOffY = 0;
    const onMove = (clientX, clientY) => {
      if (!dragging) return;
      let nx = clientX - dragOffX, ny = clientY - dragOffY;
      nx = Math.max(0, Math.min(window.innerWidth - 80, nx));
      ny = Math.max(0, Math.min(window.innerHeight - 40, ny));
      wrapper.style.left = nx + 'px';
      wrapper.style.top = ny + 'px';
      wrapper.style.right = 'auto';
      wrapper.style.bottom = 'auto';
      floatPositions[id] = { x: nx, y: ny };
    };
    bar.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || e.target.closest('.pw-float-btn')) return;
      dragging = true;
      dragPointer = e.pointerId;
      const rect = wrapper.getBoundingClientRect();
      dragOffX = e.clientX - rect.left;
      dragOffY = e.clientY - rect.top;
      bar.style.cursor = 'grabbing';
      bar.setPointerCapture?.(e.pointerId);
      e.preventDefault();
    });
    bar.addEventListener('pointermove', (e) => {
      if (dragging && e.pointerId === dragPointer) onMove(e.clientX, e.clientY);
    });
    const finishDrag = (e) => {
      if (!dragging || e.pointerId !== dragPointer) return;
      dragging = false;
      dragPointer = null;
      bar.style.cursor = 'grab';
    };
    bar.addEventListener('pointerup', finishDrag);
    bar.addEventListener('pointercancel', finishDrag);
    bar.addEventListener('lostpointercapture', finishDrag);

    // Resize handle (bottom-right corner)
    let resizing = false, resizePointer = null, startW = 0, startX = 0;
    const resizeGrip = document.createElement('div');
    resizeGrip.style.cssText = 'position:absolute;bottom:0;right:0;width:16px;height:16px;cursor:nwse-resize;opacity:.4;z-index:1';
    resizeGrip.innerHTML = '<svg width="12" height="12" viewBox="0 0 12 12" style="position:absolute;bottom:2px;right:2px"><path d="M11 1L1 11M11 5L5 11M11 9L9 11" stroke="#fff" stroke-width="1.5" fill="none"/></svg>';
    wrapper.appendChild(resizeGrip);
    wrapper.style.overflow = 'visible';
    resizeGrip.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      resizing = true;
      resizePointer = e.pointerId;
      startW = wrapper.offsetWidth;
      startX = e.clientX;
      resizeGrip.setPointerCapture?.(e.pointerId);
      e.preventDefault();
      e.stopPropagation();
    });
    resizeGrip.addEventListener('pointermove', (e) => {
      if (!resizing || e.pointerId !== resizePointer) return;
      const nw = Math.max(160, Math.min(window.innerWidth - 40, startW + (e.clientX - startX)));
      const ratio = video.videoHeight / video.videoWidth || 0.56;
      wrapper.style.width = nw + 'px';
      video.style.height = Math.round(nw * ratio) + 'px';
    });
    const finishResize = (e) => {
      if (!resizing || e.pointerId !== resizePointer) return;
      resizing = false;
      resizePointer = null;
    };
    resizeGrip.addEventListener('pointerup', finishResize);
    resizeGrip.addEventListener('pointercancel', finishResize);
    resizeGrip.addEventListener('lostpointercapture', finishResize);

    floatWindows.set(id, { wrapper, video, title, bar });
    return { wrapper, video, bar, title };
  };

  const ensureFloatWindow = (id, titleText, accentColor, opts) => {
    if (floatWindows.has(id)) return floatWindows.get(id);
    return makeFloatWindow(id, titleText, accentColor, opts);
  };

  // ---- Stage video for screenshare viewers ----
  const showStageVideo = (uid, stream) => {
    const { wrapper, video } = ensureFloatWindow('stage-' + uid, 'Screen Share', 'var(--accent,#5865f2)', {
      right: 16, bottom: 80,
      onClose: () => { wrapper.style.display = 'none'; video.srcObject = null; }
    });
    if (stream) {
      video.srcObject = stream;
      video.play().catch(() => {});
    }
    wrapper.style.display = '';
  };

  const hideStageVideo = (uid) => {
    const w = floatWindows.get('stage-' + uid);
    if (w) { w.wrapper.style.display = 'none'; w.video.srcObject = null; }
  };

  const removeStageVideo = (uid) => {
    const w = floatWindows.get('stage-' + uid);
    if (w) {
      if (w.video.srcObject) { w.video.srcObject.getTracks().forEach((t) => t.stop()); w.video.srcObject = null; }
      w.wrapper.remove();
      floatWindows.delete('stage-' + uid);
    }
    screenSharers.delete(uid);
  };

  // ---- Local screen share preview ----
  const showLocalScreenPreview = (stream) => {
    const { wrapper, video } = ensureFloatWindow('local-preview', 'Your Screen Share', 'var(--ok,#23a55a)', {
      right: 16, bottom: 80,
      onClose: () => { stopScreenShare(); }
    });
    video.srcObject = stream;
    video.play().catch(() => {});
    wrapper.style.display = '';
  };

  const removeLocalScreenPreview = () => {
    const w = floatWindows.get('local-preview');
    if (w) {
      if (w.video.srcObject) { w.video.srcObject.getTracks().forEach((t) => t.stop()); w.video.srcObject = null; }
      w.wrapper.remove();
      floatWindows.delete('local-preview');
    }
  };

  // ---- Screen sharing ----
  const screenShareEncoderTiers = [
    { maxBitrate: 2500000, maxFramerate: 30, scaleResolutionDownBy: 1 },
    { maxBitrate: 1500000, maxFramerate: 24, scaleResolutionDownBy: 1.5 },
    { maxBitrate: 750000, maxFramerate: 15, scaleResolutionDownBy: 2 },
  ];

  const applyEncoderTier = (sender, participantCount) => {
    if (!sender || !sender.track) return;
    const tierIndex = Math.min(participantCount - 2, screenShareEncoderTiers.length - 1);
    const tier = screenShareEncoderTiers[Math.max(0, tierIndex)];
    sender.getParameters().then((params) => {
      params.encodings = params.encodings || [{}];
      params.encodings[0].maxBitrate = tier.maxBitrate;
      params.encodings[0].maxFramerate = tier.maxFramerate;
      params.encodings[0].scaleResolutionDownBy = tier.scaleResolutionDownBy;
      sender.setParameters(params).catch(() => {});
    }).catch(() => {});
  };

  const startScreenShare = async () => {
    if (!displayMediaSupported) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen sharing is not supported on this browser. Use Chrome, Edge, Firefox, or Safari on desktop.' });
      return;
    }
    if (!room) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Join a voice channel first.' });
      return;
    }
    try {
      screenStream = await navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: { ideal: 30, max: 30 } },
        audio: true
      });
    } catch (e) {
      debug('MEDIA', 'display_media_failed', { name: e.name, error: e.message }, 'warn');
      // Safari may not support audio in getDisplayMedia; retry without
      if (e.name !== 'AbortError') {
        try {
          screenStream = await navigator.mediaDevices.getDisplayMedia({
            video: { frameRate: { ideal: 30, max: 30 } }
          });
        } catch (e2) {
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen sharing was cancelled or is not available.' });
          return;
        }
      } else {
        return;
      }
    }
    const videoTrack = screenStream.getVideoTracks()[0];
    if (videoTrack) {
      videoTrack.contentHint = 'detail';
      videoTrack.onended = () => stopScreenShare();
    }
    // Set screen flag on server
    sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen: true } });
    // Replace video track on all peer senders
    peers.forEach((pc, peerUid) => {
      if (pc._videoSender) {
        pc._videoSender.replaceTrack(videoTrack).catch(() => {});
        applyEncoderTier(pc._videoSender, peers.size + 1);
        screenSenders.set(peerUid, pc._videoSender);
      }
    });
    send(app.ports.bridgeReceive, { tag: 'screen_share_started', user_id: meId });
    send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen sharing started' });
    showLocalScreenPreview(screenStream);
    debug('MEDIA', 'screen_share_started', { tracks: screenStream.getTracks().length });
  };

  const stopScreenShare = () => {
    if (!screenStream) return;
    screenStream.getTracks().forEach((t) => t.stop());
    screenStream = null;
    // Restore camera video on all peer senders
    const cameraTrack = localStream && localStream.getVideoTracks()[0];
    peers.forEach((pc, peerUid) => {
      if (pc._videoSender) {
        pc._videoSender.replaceTrack(cameraTrack || null).catch(() => {});
      }
    });
    screenSenders.clear();
    removeLocalScreenPreview();
    // Clear screen flag on server
    if (room && ws?.readyState === WebSocket.OPEN) {
      sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen: false } });
    }
    send(app.ports.bridgeReceive, { tag: 'screen_share_stopped', user_id: meId });
    send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen sharing stopped' });
    debug('MEDIA', 'screen_share_stopped');
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
    audioContext()?.resume?.();
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((audio) => {
      audio.play().then(() => { audioUnlockToastShown = false; }).catch(() => false);
    });
  };

  const playRemoteAudio = (audio) => {
    audio.play().then(() => { audioUnlockToastShown = false; }).catch(() => {
      audioContext()?.resume?.();
      audio.play().catch(() => {
        if (!audioUnlockToastShown) {
          audioUnlockToastShown = true;
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Tap Enable audio to hear the call.' });
        }
      });
    });
    if (!remoteAudioUnlockInstalled) {
      remoteAudioUnlockInstalled = true;
      ['click', 'touchend', 'keydown', 'pointerdown'].forEach((ev) => {
        document.addEventListener(ev, () => {
          audioContext()?.resume?.();
          playAllRemoteAudio();
        }, { passive: true });
      });
    }
  };

  const applySpeaker = async () => {
    const sink = selectedOutputId || (speakerOn ? 'default' : 'communications');
    const outputs = Array.from(document.querySelectorAll('audio[id^="remote-audio-"]'));
    if (micTest?.monitor) outputs.push(micTest.monitor);
    await Promise.all(outputs.map((el) => {
      if (typeof el.setSinkId !== 'function') return Promise.resolve(false);
      return el.setSinkId(sink).catch(() => false);
    }));
  };

  const reportPeerConnection = (uid, pc, connected) => {
    const kind = pc?._roomKind || room?.kind;
    const id = Number(pc?._roomId || room?.id || 0);
    if (!kind || !id) return;
    send(app.ports.bridgeReceive, {
      tag: 'rtc_peer_connected', room_kind: kind, room_id: id,
      user_id: Number(uid), connected: !!connected
    });
  };

  const reportPeerFailure = (uid, pc, failed, reason = '') => {
    const kind = pc?._roomKind || room?.kind;
    const id = Number(pc?._roomId || room?.id || 0);
    if (!kind || !id || pc?._reportedFailure === !!failed) return;
    if (pc) pc._reportedFailure = !!failed;
    send(app.ports.bridgeReceive, {
      tag: 'rtc_peer_failed', room_kind: kind, room_id: id,
      user_id: Number(uid), failed: !!failed, reason
    });
  };

  const rtcHasTurn = () => (rtcConfig.iceServers || []).some((server) => {
    const urls = Array.isArray(server.urls) ? server.urls : [server.urls];
    return urls.some((url) => typeof url === 'string' && /^turns?:/i.test(url));
  });

  const markPeerFailed = (uid, pc, reason = 'connection_timeout') => {
    if (!pc || pc.signalingState === 'closed' || pc._failureReported) return;
    pc._failureReported = true;
    reportPeerConnection(uid, pc, false);
    reportPeerFailure(uid, pc, true, reason);
    debug('RTC', 'peer_connection_failed', {
      peer_user_id: uid, reason, connection: pc.connectionState,
      signaling: pc.signalingState, ice: pc.iceConnectionState,
      turn_configured: rtcHasTurn()
    }, 'warn');
    send(app.ports.bridgeReceive, {
      tag: 'toast',
      data: rtcHasTurn()
        ? 'Audio could not connect. Use Retry audio.'
        : 'Audio could not connect on this network. Configure TURN or use Retry audio.'
    });
  };

  const closePeer = (uid) => {
    const pc = peers.get(uid);
    if (pc) {
      if (pc._restartTimer) clearTimeout(pc._restartTimer);
      if (pc._connectTimer) clearTimeout(pc._connectTimer);
      if (pc._disconnectTimer) clearTimeout(pc._disconnectTimer);
      pc.close();
    }
    peers.delete(uid);
    debug('RTC', 'peer_closed', { peer_user_id: uid, remaining_peers: peers.size });
    removeStageVideo(uid);
    document.getElementById('remote-audio-' + uid)?.remove();
    reportPeerConnection(uid, pc, false);
  };

  const cleanupAllFloatWindows = () => {
    floatWindows.forEach((w, id) => {
      if (w.video.srcObject) { w.video.srcObject.getTracks().forEach((t) => t.stop()); w.video.srcObject = null; }
      w.wrapper.remove();
    });
    floatWindows.clear();
  };

  const rtcEventRoom = (msg) => {
    if (!msg) return null;
    if (msg.channel_id) return { kind: 'voice', id: Number(msg.channel_id) };
    if (msg.conversation_id) return { kind: 'call', id: Number(msg.conversation_id) };
    return null;
  };

  const roomMatches = (kind, id) => !!room && room.kind === kind && room.id === Number(id);
  const eventMatchesRoom = (msg) => {
    const eventRoom = rtcEventRoom(msg);
    return !!eventRoom && roomMatches(eventRoom.kind, eventRoom.id);
  };

  const leaveRtcRoom = ({ notifyServer = false, preserveResume = false } = {}) => {
    const previous = room ? { ...room } : null;
    debug('RTC', 'room_leaving', { room: previous, peers: peers.size, notify_server: notifyServer, preserve_resume: preserveResume });
    if (preserveResume) persistRtcIntent();
    else clearRtcIntent();
    if (notifyServer && previous) {
      if (previous.kind === 'voice') sendWs({ type: 'voice_leave' });
      else sendWs({ type: previous.joined ? 'call_leave' : 'call_cancel', conversation_id: previous.id });
    }
    roomEpoch++;
    peers.forEach((_, uid) => closePeer(uid));
    peerPromises.clear();
    signalQueues.clear();
    if (screenStream) {
      screenStream.getTracks().forEach((t) => t.stop());
      screenStream = null;
    }
    screenSenders.clear();
    cleanupAllFloatWindows();
    screenSharers.clear();
    room = null;
    resumeInFlight = false;
    releaseCurrentMicrophone();
  };

  const switchRtcRoom = (kind, id) => {
    const numericId = Number(id);
    if (roomMatches(kind, numericId)) return room.epoch;
    leaveRtcRoom({ notifyServer: true });
    const epoch = ++roomEpoch;
    room = { kind, id: numericId, joined: false, epoch };
    debug('RTC', 'room_selected', { room });
    return epoch;
  };

  const maybeResumeRtcRoom = () => {
    if (resumeAttempted || resumeInFlight || room || !resumeIntent || !meId) return;
    const intent = readRtcIntent();
    resumeAttempted = true;
    if (!intent) return clearRtcIntent();
    resumeIntent = intent;
    resumeInFlight = true;
    micMuted = intent.muted;
    deafened = intent.deafened;
    const epoch = ++roomEpoch;
    room = { kind: intent.kind, id: intent.id, joined: false, epoch };
    send(app.ports.bridgeReceive, {
      tag: 'rtc_resuming', room_kind: intent.kind, room_id: intent.id,
      muted: micMuted, deafened
    });
    debug('RTC', 'room_resume_started', { room });
    ensureMedia()
      .then(() => {
        if (!room || room.epoch !== epoch) return;
        const join = intent.kind === 'voice'
          ? { type: 'voice_join', channel_id: intent.id }
          : { type: 'call_join', conversation_id: intent.id };
        sendWs(join);
      })
      .catch((error) => {
        if (room?.epoch === epoch) leaveRtcRoom();
        debug('RTC', 'room_resume_failed', { error: error.message, intent }, 'warn');
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not rejoin the call. Check microphone permission.' });
      });
  };

  const cleanupRtcMedia = () => leaveRtcRoom({ preserveResume: true });

  const stopPendingCallMedia = () => {
    if (room) return;
    releaseCurrentMicrophone();
  };

  const makeOffer = async (uid, pc, options = {}) => {
    // one offerer per pair. two is how glare happens.
    if (!pc || !pc._offerer || !room || pc._roomEpoch !== room.epoch || pc.signalingState !== 'stable' || pc._makingOffer) return;
    pc._makingOffer = true;
    debug('RTC', 'offer_creating', { peer_user_id: uid, ice_restart: !!options.iceRestart, signaling: pc.signalingState });
    try {
      const offer = await pc.createOffer(options);
      if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed') return;
      await pc.setLocalDescription(offer);
      pc._offerSentAt = Date.now();
      debug('RTC', 'offer_ready', { peer_user_id: uid });
      sendSignal(uid, { kind: 'offer', sdp: pc.localDescription });
    } finally {
      pc._makingOffer = false;
    }
  };

  const restartPeerIce = (uid, pc, reason = 'network') => {
    if (!pc || pc.signalingState === 'closed' || pc.connectionState === 'connected') return;
    if (pc._restartTimer || Date.now() - (pc._lastRecoveryAt || 0) < 4500) return;
    if ((pc._reconnectAttempts || 0) >= RTC_MAX_RECOVERY_ATTEMPTS) {
      markPeerFailed(uid, pc, reason);
      return;
    }
    pc._reconnectAttempts = (pc._reconnectAttempts || 0) + 1;
    pc._lastRecoveryAt = Date.now();
    pc._failureReported = false;
    reportPeerFailure(uid, pc, false);
    reportPeerConnection(uid, pc, false);
    debug('RTC', 'peer_recovery_scheduled', {
      peer_user_id: uid, reason, attempt: pc._reconnectAttempts,
      offerer: pc._offerer, signaling: pc.signalingState
    });
    pc._restartTimer = setTimeout(async () => {
      pc._restartTimer = null;
      if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed' || pc.connectionState === 'connected') return;
      try {
        if (!pc._offerer) {
          // answerer asks; offerer restarts.
          sendSignal(uid, { kind: 'renegotiate' });
          return;
        }
        if (pc.signalingState === 'have-local-offer' && Date.now() - (pc._offerSentAt || 0) >= 4500) {
          // probably lost an offer/answer. send the pending one again.
          pc._offerSentAt = Date.now();
          sendSignal(uid, { kind: 'offer', sdp: pc.localDescription });
          return;
        }
        if (pc.signalingState === 'stable') {
          try { pc.restartIce?.(); } catch (_) {}
          await makeOffer(uid, pc, { iceRestart: true });
        }
      } catch (e) {
        debug('RTC', 'restart_peer_ice_failed', { peer_user_id: uid, error: e.message }, 'warn');
      }
    }, 600);
  };

  const ensurePeer = async (uid) => {
    if (!uid || uid === meId) return null;
    const epoch = room?.epoch;
    if (!epoch) return null;
    const existing = peers.get(uid);
    if (existing && existing._roomEpoch === epoch) return existing;
    if (existing) closePeer(uid);
    const pendingKey = `${epoch}:${uid}`;
    const pending = peerPromises.get(pendingKey);
    if (pending) return pending;
    const creation = createPeer(uid, epoch);
    peerPromises.set(pendingKey, creation);
    try {
      return await creation;
    } finally {
      peerPromises.delete(pendingKey);
    }
  };

  const createPeer = async (uid, epoch) => {
    await loadRtcConfig();
    if (!room || room.epoch !== epoch) return null;
    const stream = await ensureMedia();
    if (!room || room.epoch !== epoch) return null;
    if (peers.has(uid)) return peers.get(uid);
    const offerer = Number(meId) > Number(uid);
    const polite = !offerer;
    const pc = new RTCPeerConnection(rtcConfig);
    debug('RTC', 'peer_created', { peer_user_id: uid, offerer, polite, room, ice_server_count: rtcConfig.iceServers?.length || 0 });
    pc._offerer = offerer;
    pc._polite = polite;
    pc._roomEpoch = epoch;
    pc._roomKind = room.kind;
    pc._roomId = room.id;
    pc._makingOffer = false;
    pc._isSettingRemoteAnswerPending = false;
    pc._ignoreOffer = false;
    pc._pendingCandidates = [];
    pc._negotiated = false;
    pc._reconnectAttempts = 0;
    pc._failureReported = false;
    // fixed transceivers make screen sharing a track swap, not a glare party.
    const audioTransceiver = pc.addTransceiver('audio', { direction: 'sendrecv' });
    const videoTransceiver = pc.addTransceiver('video', { direction: 'sendrecv' });
    const audioTrack = stream.getAudioTracks()[0];
    const videoTrack = stream.getVideoTracks()[0];
    if (audioTrack) audioTransceiver.sender.replaceTrack(audioTrack);
    if (videoTrack) videoTransceiver.sender.replaceTrack(videoTrack);
    pc._audioSender = audioTransceiver.sender;
    pc._videoSender = videoTransceiver.sender;
    pc.onnegotiationneeded = () => {
      if (!pc._offerer) return;
      makeOffer(uid, pc).catch((error) => {
        debug('RTC', 'negotiationneeded_failed', { peer_user_id: uid, error: error.message }, 'warn');
        restartPeerIce(uid, pc, 'offer_failed');
      });
    };
    pc.onicecandidate = (ev) => {
      if (ev.candidate) {
        debug('RTC', 'ice_candidate', { peer_user_id: uid, protocol: ev.candidate.protocol, type: ev.candidate.type });
        sendSignal(uid, { kind: 'candidate', candidate: ev.candidate });
      } else debug('RTC', 'ice_gathering_complete', { peer_user_id: uid });
    };
    pc.ontrack = (ev) => {
      debug('RTC', 'remote_track', { peer_user_id: uid, kind: ev.track.kind, muted: ev.track.muted, ready_state: ev.track.readyState, streams: ev.streams?.length || 0 });
      if (ev.track.kind === 'audio') {
        const markMediaConnected = () => {
          pc._mediaConnected = ev.track.readyState === 'live' && ev.track.muted !== true;
          if (pc._mediaConnected) pc._publishConnectionState?.();
        };
        markMediaConnected();
        ev.track.addEventListener?.('unmute', markMediaConnected);
        ev.track.addEventListener?.('ended', () => {
          pc._mediaConnected = false;
          reportPeerConnection(uid, pc, false);
        });
        const audio = remoteAudio(uid);
        if (ev.streams && ev.streams[0]) {
          audio.srcObject = ev.streams[0];
        } else {
          const s = audio.srcObject instanceof MediaStream ? audio.srcObject : new MediaStream();
          s.addTrack(ev.track);
          audio.srcObject = s;
        }
        audio.muted = deafened;
        playRemoteAudio(audio);
        applySpeaker();
      } else if (ev.track.kind === 'video') {
        // Store stream for later — stage video only shown for screen sharers
        if (!pc._videoStreams) pc._videoStreams = new Map();
        const stream = ev.streams && ev.streams[0] ? ev.streams[0] : new MediaStream([ev.track]);
        pc._videoStreams.set(ev.track.id, stream);
        if (screenSharers.has(uid)) {
          showStageVideo(uid, stream);
        }
      }
    };
    const publishConnectionState = (force = false) => {
      const connected = pc._mediaConnected === true || pc.connectionState === 'connected' || pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed';
      if (!force && pc._reportedConnected === connected) return;
      const firstConnection = connected && pc._reportedConnected !== true;
      pc._reportedConnected = connected;
      reportPeerConnection(uid, pc, connected);
      if (connected) {
        if (pc._connectTimer) clearTimeout(pc._connectTimer);
        if (pc._restartTimer) clearTimeout(pc._restartTimer);
        pc._connectTimer = null;
        pc._restartTimer = null;
        pc._reconnectAttempts = 0;
        pc._failureReported = false;
        pc._negotiated = true;
        reportPeerFailure(uid, pc, false);
        audioContext()?.resume?.();
        playAllRemoteAudio();
        if (firstConnection) send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call audio connected' });
      }
    };
    pc._publishConnectionState = publishConnectionState;
    pc.onconnectionstatechange = () => {
      debug('RTC', 'connection_state', { peer_user_id: uid, state: pc.connectionState });
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') pc._mediaConnected = false;
      publishConnectionState();
      if (pc.connectionState === 'disconnected') {
        if (pc._disconnectTimer) clearTimeout(pc._disconnectTimer);
        pc._disconnectTimer = setTimeout(() => {
          pc._disconnectTimer = null;
          if (pc.connectionState === 'disconnected') restartPeerIce(uid, pc, 'disconnected');
        }, 1800);
      }
      if (pc.connectionState === 'failed') {
        restartPeerIce(uid, pc, 'connection_failed');
      }
    };
    pc.oniceconnectionstatechange = () => {
      debug('RTC', 'ice_connection_state', { peer_user_id: uid, state: pc.iceConnectionState });
      if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'closed') pc._mediaConnected = false;
      publishConnectionState();
      if (pc.iceConnectionState === 'failed') restartPeerIce(uid, pc, 'ice_failed');
    };
    pc.onicegatheringstatechange = () => debug('RTC', 'ice_gathering_state', { peer_user_id: uid, state: pc.iceGatheringState });
    pc.onsignalingstatechange = () => debug('RTC', 'signaling_state', { peer_user_id: uid, state: pc.signalingState });
    peers.set(uid, pc);
    reportPeerFailure(uid, pc, false);
    publishConnectionState(true);
    const checkConnection = () => {
      pc._connectTimer = setTimeout(() => {
        if (pc.connectionState === 'connected' || pc.connectionState === 'closed') return;
        debug('RTC', 'check_connection', {
          peer_user_id: uid,
          connection: pc.connectionState,
          signaling: pc.signalingState,
          ice: pc.iceConnectionState,
          reconnect_attempts: pc._reconnectAttempts,
          offerer: pc._offerer
        });
        if ((pc._reconnectAttempts || 0) >= RTC_MAX_RECOVERY_ATTEMPTS) {
          markPeerFailed(uid, pc);
          return;
        }
        restartPeerIce(uid, pc, 'connection_timeout');
        checkConnection();
      }, RTC_CONNECT_CHECK_MS);
    };
    checkConnection();
    // nudge the offerer, don't invent a second offer.
    if (!offerer) {
      setTimeout(() => {
        if (pc.connectionState === 'connected' || pc.connectionState === 'closed') return;
        if (pc.signalingState === 'stable' && !pc._negotiated) {
          debug('RTC', 'answerer_requesting_initial_offer', { peer_user_id: uid });
          sendSignal(uid, { kind: 'renegotiate' });
        }
      }, 3500);
    }
    return pc;
  };

  const callPeer = async (uid) => {
    const pc = await ensurePeer(uid);
    if (!pc) return;
    await makeOffer(uid, pc);
  };

  const retryRtcPeer = async (uid) => {
    const peerUid = Number(uid || 0);
    if (!room || !peerUid || peerUid === meId) return;
    closePeer(peerUid);
    const pc = await ensurePeer(peerUid);
    if (!pc) return;
    pc._reconnectAttempts = 0;
    pc._lastRecoveryAt = 0;
    pc._failureReported = false;
    reportPeerFailure(peerUid, pc, false);
    if (pc._offerer) await makeOffer(peerUid, pc, { iceRestart: true });
    else sendSignal(peerUid, { kind: 'renegotiate' });
  };

  const drainPendingCandidates = async (uid, pc) => {
    while (pc._pendingCandidates.length) {
      const candidate = pc._pendingCandidates.shift();
      try {
        await pc.addIceCandidate(candidate);
      } catch (error) {
        if (!pc._ignoreOffer) {
          debug('RTC', 'candidate_apply_failed', { peer_user_id: uid, error: error.message }, 'warn');
        }
      }
    }
  };

  const applySignal = async (msg) => {
    const uid = Number(msg.from_user_id || msg.user_id || 0);
    const signal = msg.signal || {};
    debug('RTC', 'signal_received', { peer_user_id: uid, kind: signal.kind, message_type: msg.type });
    if (!uid || uid === meId || !room || !eventMatchesRoom(msg)) {
      debug('RTC', 'stale_signal_ignored', { peer_user_id: uid, event_room: rtcEventRoom(msg), room });
      return;
    }
    const pc = await ensurePeer(uid);
    if (!pc) return;
    try {
      if (signal.kind === 'renegotiate') {
        if (pc._offerer) {
          if (pc._failureReported) pc._reconnectAttempts = 0;
          pc._lastRecoveryAt = 0;
          restartPeerIce(uid, pc, 'peer_requested');
        }
      } else if (signal.kind === 'offer') {
        // offerers don't accept offers. yes, old cached clients try.
        if (pc._offerer) {
          debug('RTC', 'unexpected_offer_ignored', { peer_user_id: uid, signaling: pc.signalingState }, 'warn');
          if (pc.signalingState === 'stable') makeOffer(uid, pc, { iceRestart: true }).catch(() => {});
          return;
        }
        const readyForOffer = !pc._makingOffer &&
          (pc.signalingState === 'stable' || pc._isSettingRemoteAnswerPending);
        const offerCollision = !readyForOffer;
        pc._ignoreOffer = !pc._polite && offerCollision;
        if (pc._ignoreOffer) return;
        try {
          await pc.setRemoteDescription(signal.sdp);
        } catch (error) {
          // fallback for browsers that can't roll ICE back for us.
          if (!offerCollision) throw error;
          await pc.setLocalDescription({ type: 'rollback' });
          await pc.setRemoteDescription(signal.sdp);
        }
        pc._ignoreOffer = false;
        pc._failureReported = false;
        reportPeerFailure(uid, pc, false);
        debug('RTC', 'remote_offer_applied', { peer_user_id: uid });
        await drainPendingCandidates(uid, pc);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        pc._negotiated = true;
        debug('RTC', 'answer_ready', { peer_user_id: uid });
        sendSignal(uid, { kind: 'answer', sdp: pc.localDescription });
      } else if (signal.kind === 'answer') {
        if (pc.signalingState === 'have-local-offer') {
          pc._isSettingRemoteAnswerPending = true;
          try {
            await pc.setRemoteDescription(signal.sdp);
          } finally {
            pc._isSettingRemoteAnswerPending = false;
          }
          pc._ignoreOffer = false;
          pc._negotiated = true;
          debug('RTC', 'remote_answer_applied', { peer_user_id: uid });
          await drainPendingCandidates(uid, pc);
        }
      } else if (signal.kind === 'candidate' && signal.candidate) {
        if (pc.remoteDescription) {
          try {
            await pc.addIceCandidate(signal.candidate);
          } catch (error) {
            if (!pc._ignoreOffer) throw error;
          }
        } else {
          pc._pendingCandidates.push(signal.candidate);
        }
      }
    } catch (e) { debug('RTC', 'signaling_failed', { peer_user_id: uid, kind: signal.kind, name: e.name, error: e.message, signaling: pc.signalingState }, 'error'); }
  };

  const handleSignal = (msg) => {
    const uid = Number(msg?.from_user_id || msg?.user_id || 0);
    const key = `${room?.epoch || 0}:${uid}`;
    const previous = signalQueues.get(key) || Promise.resolve();
    const queued = previous.catch(() => {}).then(() => applySignal(msg));
    signalQueues.set(key, queued);
    return queued.finally(() => {
      if (signalQueues.get(key) === queued) signalQueues.delete(key);
    });
  };

  const joinRtcRoom = async (kind, id, users = []) => {
    if (!roomMatches(kind, id)) {
      debug('RTC', 'stale_roster_ignored', { kind, id, room });
      return;
    }
    room.joined = true;
    resumeInFlight = false;
    persistRtcIntent();
    const epoch = room.epoch;
    debug('RTC', 'room_joined', { kind, id, participant_count: users.length });
    await ensureMedia();
    if (!room || room.epoch !== epoch) return;
    const ids = users.map((u) => Number(u.user_id || u.userId || u.profile?.id || 0)).filter((uid) => uid && uid !== meId);
    const roster = new Set(ids);
    Array.from(peers.keys()).forEach((uid) => { if (!roster.has(uid)) closePeer(uid); });
    ids.forEach((uid) => {
      const shouldOffer = meId > uid;
      ensurePeer(uid).then((pc) => {
        if (shouldOffer) callPeer(uid);
        // roster wins; remind Elm what RTC already decided.
        pc?._publishConnectionState?.(true);
      }).catch(() => {});
    });
  };

  const updateScreenRoster = (users = []) => {
    const next = new Set();
    users.forEach((user) => {
      const uid = Number(user.user_id || user.userId || user.profile?.id || 0);
      if (uid && uid !== meId && user.screen) next.add(uid);
    });
    next.forEach((uid) => {
      if (screenSharers.has(uid)) return;
      const streams = peers.get(uid)?._videoStreams;
      const stream = streams && Array.from(streams.values()).pop();
      if (stream) showStageVideo(uid, stream);
    });
    screenSharers.forEach((uid) => { if (!next.has(uid)) hideStageVideo(uid); });
    screenSharers.clear();
    next.forEach((uid) => screenSharers.add(uid));
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
    if (msg.type === 'voice_state') {
      if (!roomMatches('voice', msg.channel_id)) return;
      joinRtcRoom('voice', msg.channel_id, msg.users || []).catch(() => {});
      updateScreenRoster(msg.users || []);
    }
    if (msg.type === 'call_state') {
      if (!roomMatches('call', msg.conversation_id)) return;
      joinRtcRoom('call', msg.conversation_id, msg.users || []).catch(() => {});
      updateScreenRoster(msg.users || []);
    }
    if ((msg.type === 'call_peer_joined' || msg.type === 'voice_peer_joined') && msg.user_id && eventMatchesRoom(msg)) {
      const peerUid = Number(msg.user_id);
      if (peerUid && peerUid !== meId && !peers.has(peerUid)) {
        const shouldOffer = meId > peerUid;
        ensurePeer(peerUid).then((pc) => {
          if (shouldOffer) callPeer(peerUid);
          pc?._publishConnectionState?.(true);
        }).catch(() => {});
      }
    }
    if ((msg.type === 'call_peer_left' || msg.type === 'voice_peer_left') && eventMatchesRoom(msg)) {
      const leftUid = Number(msg.user_id);
      screenSharers.delete(leftUid);
      closePeer(leftUid);
    }
    if ((msg.type === 'voice_signal' || msg.type === 'call_signal') && eventMatchesRoom(msg)) handleSignal(msg).catch(() => {});
    if (['call_declined', 'call_cancelled', 'call_missed', 'call_ended'].includes(msg.type) && eventMatchesRoom(msg)) leaveRtcRoom();
    if (msg.type === 'call_accepted') stopRingtones();
    if (msg.type === 'error' && resumeInFlight) {
      debug('RTC', 'room_resume_rejected', { error: msg.error }, 'warn');
      leaveRtcRoom();
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'That call could not be rejoined.' });
    }
    if ((msg.type === 'voice_superseded' || msg.type === 'call_superseded') && eventMatchesRoom(msg)) {
      debug('RTC', 'superseded', { type: msg.type });
      leaveRtcRoom();
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Another tab has taken over this session.' });
    }
    if ((msg.type === 'voice_ejected' || msg.type === 'call_ejected') && eventMatchesRoom(msg)) {
      // signaling is gone, but the P2P stream needs an actual shove.
      debug('RTC', 'access_revoked', { type: msg.type, room });
      leaveRtcRoom();
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call ended because access to this room changed.' });
    }
    if (msg.type === 'share_denied') {
      stopScreenShare();
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen share limit reached for this room.' });
    }
  };

  const setMuted = (muted) => {
    micMuted = !!muted;
    if (localStream) localStream.getAudioTracks().forEach((t) => { t.enabled = !micMuted; });
    persistRtcIntent();
    debug('MEDIA', 'microphone_muted_changed', { muted: micMuted, tracks: localStream?.getAudioTracks().length || 0 });
  };

  const setDeafened = (value) => {
    deafened = !!value;
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((el) => { el.muted = deafened; });
    if (deafened) setMuted(true);
    persistRtcIntent();
    debug('MEDIA', 'deafened_changed', { deafened });
  };

  const enableDrag = () => {
    let drag = null;
    let position = null;
    let suppressClick = false;
    const selector = '.call-bar.compact, .call-overlay.expanded, .call-popup';
    document.addEventListener('pointerdown', (ev) => {
      if (window.matchMedia('(max-width: 700px)').matches || ev.button !== 0) return;
      const card = ev.target.closest?.(selector);
      if (!card || ev.target.closest('button, input, select, a')) return;
      if (position) {
        card.style.position = 'fixed';
        card.style.left = position.x + 'px';
        card.style.top = position.y + 'px';
        card.style.right = 'auto';
        card.style.bottom = 'auto';
      }
      const rect = card.getBoundingClientRect();
      drag = { card, pointerId: ev.pointerId, startX: ev.clientX, startY: ev.clientY,
        dx: ev.clientX - rect.left, dy: ev.clientY - rect.top, moved: false };
      card.setPointerCapture?.(ev.pointerId);
    });
    document.addEventListener('pointermove', (ev) => {
      if (!drag || drag.pointerId !== ev.pointerId) return;
      if (!drag.moved && Math.hypot(ev.clientX - drag.startX, ev.clientY - drag.startY) < 5) return;
      drag.moved = true;
      drag.card.style.position = 'fixed';
      const x = Math.max(8, Math.min(window.innerWidth - drag.card.offsetWidth - 8, ev.clientX - drag.dx));
      const y = Math.max(8, Math.min(window.innerHeight - drag.card.offsetHeight - 8, ev.clientY - drag.dy));
      drag.card.style.left = x + 'px';
      drag.card.style.top = y + 'px';
      drag.card.style.right = 'auto';
      drag.card.style.bottom = 'auto';
      drag.card.classList.add('dragging');
      position = { x, y };
      ev.preventDefault();
    });
    document.addEventListener('pointerup', (ev) => {
      if (!drag || drag.pointerId !== ev.pointerId) return;
      suppressClick = drag.moved;
      drag.card.classList.remove('dragging');
      drag = null;
    });
    document.addEventListener('click', (ev) => {
      if (!suppressClick || !ev.target.closest?.(selector)) return;
      suppressClick = false;
      ev.preventDefault();
      ev.stopImmediatePropagation();
    }, true);
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
    if (enabled) playSound('notification');
  });
  recv(app.ports.playRingtone, (enabled) => {
    if (!enabled) return stopRingtones();
    startRingtone('incoming');
  });
  recv(app.ports.playOutgoingRingtone, (enabled) => {
    if (!enabled) return stopRingtones();
    startRingtone('outgoing');
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
      send(app.ports.fileInput, { id, data: null });
      return;
    }
    if (file.size > 8 * 1024 * 1024) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Profile images and GIFs can be up to 8 MB.' });
      send(app.ports.fileInput, { id, data: null });
      return;
    }
    send(app.ports.bridgeReceive, { tag: 'toast', data: `Uploading ${file.name || 'image'}…` });
    uploadOne(file)
      .then((uploaded) => {
        send(app.ports.fileInput, { id, data: uploaded.url || null });
        send(app.ports.bridgeReceive, { tag: 'toast', data: `${file.name || 'Image'} ready — save your profile` });
      })
      .catch((error) => {
        debug('UPLOAD', 'profile_image_failed', { error: error.message }, 'error');
        send(app.ports.fileInput, { id, data: null });
        send(app.ports.bridgeReceive, { tag: 'toast', data: `Image upload failed: ${error.message}` });
      });
  });
  recv(app.ports.requestNotifyPermission, () => {
    if ('Notification' in window && Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  });
  recv(app.ports.bridgeSend, ({ tag, data }) => {
    debug('ELM', 'command', { tag, data });
    switch (tag) {
      case 'preserve_message_scroll': {
        const list = document.getElementById('messages');
        messageScrollSnapshot = list ? { height: list.scrollHeight, top: list.scrollTop } : null;
        break;
      }
      case 'restore_message_scroll':
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const list = document.getElementById('messages');
          if (list && messageScrollSnapshot) {
            list.scrollTop = messageScrollSnapshot.top + (list.scrollHeight - messageScrollSnapshot.height);
          }
          messageScrollSnapshot = null;
          observeMessageHistory();
        }));
        break;
      case 'scroll_messages_to_bottom':
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const list = document.getElementById('messages');
          if (!list || !messagesPinnedToBottom) return;
          list.scrollTop = list.scrollHeight;
          list.querySelectorAll('img, video').forEach((media) => {
            if (media.tagName === 'IMG' && media.complete) return;
            media.addEventListener('load', () => {
              if (messagesPinnedToBottom) list.scrollTop = list.scrollHeight;
            }, { once: true });
          });
          observeMessageHistory();
        }));
        break;
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
      case 'pick_attachments':
        attachmentInput.click();
        break;
      case 'play_ringtone':
        startRingtone('incoming');
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
      case 'block_user':
        if (!window.confirm('Block this user? They will not be able to friend or directly message you.')) break;
        api({ method: 'POST', path: '/friends/block', body: { user_id: data } }).then(() => {
          api({ method: 'GET', path: '/sync?since=0' });
        });
        break;
      case 'unblock_user':
        api({ method: 'POST', path: '/friends/unblock', body: { user_id: data } }).then(() => {
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
            const epoch = switchRtcRoom('call', res.id);
            ensureMedia()
              .then(() => {
                if (!room || room.epoch !== epoch) return;
                startRingtone('outgoing');
                sendWs({ type: 'call_ring', conversation_id: res.id });
              })
              .catch(() => {
                if (room?.epoch === epoch) leaveRtcRoom();
                stopRingtones();
                send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
                send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
              });
          }
        });
        break;
      case 'start_call':
        {
        const epoch = switchRtcRoom('call', data);
        ensureMedia()
          .then(() => {
            if (!room || room.epoch !== epoch) return;
            startRingtone('outgoing');
            sendWs({ type: 'call_ring', conversation_id: data });
          })
          .catch(() => {
            if (room?.epoch === epoch) leaveRtcRoom();
            stopRingtones();
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
          });
        break;
        }
      case 'join_voice':
        {
        const epoch = switchRtcRoom('voice', data);
        ensureMedia()
          .then(() => { if (room?.epoch === epoch) sendWs({ type: 'voice_join', channel_id: data }); })
          .catch(() => {
            if (room?.epoch === epoch) leaveRtcRoom();
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'voice' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for voice.' });
          });
        break;
        }
      case 'accept_call':
        {
        const epoch = switchRtcRoom('call', data);
        ensureMedia()
          .then(() => {
            if (!room || room.epoch !== epoch) return;
            sendWs({ type: 'call_accept', conversation_id: data });
            stopRingtones();
          })
          .catch(() => {
            if (room?.epoch === epoch) leaveRtcRoom();
            stopRingtones();
            send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone permission is required for calls.' });
          });
        break;
        }
      case 'decline_call':
        sendWs({ type: 'call_decline', conversation_id: data });
        stopRingtones();
        stopPendingCallMedia();
        break;
      case 'cancel_call':
        leaveRtcRoom({ notifyServer: true });
        stopRingtones();
        break;
      case 'end_call':
        leaveRtcRoom({ notifyServer: true });
        stopRingtones();
        break;
      case 'voice_mute':
        setMuted(!!data);
        if (room) sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { muted: !!data } });
        break;
      case 'voice_deafen':
        setDeafened(!!data);
        if (room) sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { deafened: !!data, muted: !!data ? true : micMuted } });
        break;
      case 'unlock_audio':
        audioContext()?.resume?.();
        playAllRemoteAudio();
        break;
      case 'retry_rtc_peer':
        retryRtcPeer(data).catch((error) => {
          debug('RTC', 'manual_retry_failed', { peer_user_id: Number(data || 0), error: error.message }, 'error');
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not restart audio yet.' });
        });
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
      case 'delete_forum':
        if (window.confirm('Delete this community and every thread and reply inside it? This cannot be undone.')) {
          api({ method: 'POST', path: '/forum/' + data + '/delete', body: {} }).then((res) => {
            if (res && res.deleted) location.hash = '#forums';
          });
        }
        break;
      case 'delete_thread':
        if (data?.id && window.confirm('Delete this thread and all of its replies? This cannot be undone.')) {
          api({ method: 'POST', path: '/thread/' + data.id + '/delete', body: {} }).then((res) => {
            if (res && res.deleted) location.hash = '#forum/' + (res.forum_id || data.forum_id);
          });
        }
        break;
      case 'set_theme':
        if (data === 'system') {
          document.documentElement.removeAttribute('data-theme');
        } else {
          document.documentElement.setAttribute('data-theme', data);
        }
        break;
      case 'set_sound_preference':
        localStorage.setItem('plainwire_sound_enabled', data ? 'true' : 'false');
        if (!data) stopRingtones();
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
      case 'preview_sound':
        stopRingtones();
        playSound(data === 'incoming' ? 'incoming' : 'notification');
        break;
      case 'list_audio_devices':
        publishAudioDevices();
        break;
      case 'select_audio_input':
        stopMicTest();
        replaceMicrophone(data);
        break;
      case 'select_audio_output':
        selectedOutputId = String(data || '');
        localStorage.setItem('plainwire_audio_output', selectedOutputId);
        applySpeaker().then(publishAudioDevices);
        break;
      case 'start_mic_test':
        startMicTest();
        break;
      case 'stop_mic_test':
        stopMicTest();
        break;
      case 'set_mic_monitor':
        setMicMonitor(!!data);
        break;
      case 'select_voice_processing':
        stopMicTest();
        replaceVoiceProcessing(data);
        break;
      case 'presence_update':
        setDesiredStatus(String(data));
        break;
      case 'start_screen_share':
        startScreenShare();
        break;
      case 'stop_screen_share':
        stopScreenShare();
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

    const fallback = target.dataset.avatarFallback;
    if (fallback) {
      const retries = parseInt(target.dataset.avatarTries || '0', 10);
      if (retries < 3) {
        target.dataset.avatarTries = String(retries + 1);
        setTimeout(() => {
          const originalSrc = target.dataset.avatarSrc || target.src;
          if (originalSrc) {
            target.src = originalSrc;
            target.classList.remove('image-failed');
            target.classList.add('avatar-retrying');
            setTimeout(() => target.classList.remove('avatar-retrying'), 1000);
          }
        }, Math.pow(2, retries) * 1000);
        return;
      }
      target.removeAttribute('src');
      target.removeAttribute('srcset');
      delete target.dataset.avatarTries;
      delete target.dataset.avatarSrc;
      target.alt = fallback;
      target.setAttribute('role', 'img');
      target.setAttribute('aria-label', 'Avatar unavailable');
      target.classList.add('image-failed');
    } else {
      target.removeAttribute('src');
      target.removeAttribute('srcset');
      target.alt = '';
      target.classList.add('image-failed');
    }
  }, true);

  navigator.mediaDevices?.addEventListener?.('devicechange', publishAudioDevices);
  loadVoiceProcessingConfig().then(publishAudioDevices);
  window.addEventListener('pagehide', cleanupRtcMedia);
  window.addEventListener('beforeunload', cleanupRtcMedia);
  window.addEventListener('pageshow', () => {
    resumeIntent = readRtcIntent();
    resumeAttempted = false;
    if (resumeIntent && !room && meId) {
      if (ws?.readyState === WebSocket.OPEN) maybeResumeRtcRoom();
      else connectWs();
    }
  });
  enableDrag();
  document.addEventListener('click', () => audioContext()?.resume?.(), { once: true });
})();
