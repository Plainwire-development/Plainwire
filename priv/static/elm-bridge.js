(() => {
  'use strict';

  const storage = {
    getItem(key) { try { return window.localStorage.getItem(key); } catch (_) { return null; } },
    setItem(key, value) { try { window.localStorage.setItem(key, value); } catch (_) {} },
    removeItem(key) { try { window.localStorage.removeItem(key); } catch (_) {} },
    key(index) { try { return window.localStorage.key(index); } catch (_) { return null; } },
    get length() { try { return window.localStorage.length; } catch (_) { return 0; } }
  };
  const root = document.getElementById('app');
  if (!root || !window.Elm || !window.Elm.Main) return;

  const rawClientConfig = window.PLAINWIRE_CLIENT_CONFIG || {};
  const finiteInt = (value, fallback, min, max) => {
    const n = Number(value);
    return Number.isFinite(n) ? Math.max(min, Math.min(max, Math.floor(n))) : fallback;
  };
  const clientConfig = Object.freeze({
    version: typeof rawClientConfig.version === 'string' ? rawClientConfig.version.slice(0, 32) : '1.6.1',
    assetVersion: typeof rawClientConfig.asset_version === 'string' ? rawClientConfig.asset_version.slice(0, 64) : '1.6.1',
    appName: typeof rawClientConfig.app_name === 'string' && rawClientConfig.app_name.trim()
      ? rawClientConfig.app_name.trim().slice(0, 48) : 'Plainwire',
    defaultTheme: ['light', 'dark', 'system'].includes(rawClientConfig.default_theme)
      ? rawClientConfig.default_theme : 'system',
    registrationEnabled: rawClientConfig.registration_enabled !== false,
    instanceDescription: typeof rawClientConfig.instance_description === 'string'
      ? rawClientConfig.instance_description.trim().slice(0, 120) : '',
    uploadMaxBytes: finiteInt(rawClientConfig.upload_max_bytes, 250 * 1024 * 1024, 1024 * 1024, 250 * 1024 * 1024),
    profileImageMaxBytes: finiteInt(rawClientConfig.profile_image_max_bytes, 16 * 1024 * 1024, 256 * 1024, 16 * 1024 * 1024),
    uploadMaxFiles: finiteInt(rawClientConfig.upload_max_files, 10, 1, 25),
    idleTimeoutMs: finiteInt(rawClientConfig.idle_timeout_ms, 10 * 60 * 1000, 60 * 1000, 24 * 60 * 60 * 1000),
    compressOversizeUploads: rawClientConfig.compress_oversize_uploads !== false,
    maxImageDimension: finiteInt(rawClientConfig.max_image_dimension, 4096, 512, 8192)
  });
  document.title = clientConfig.appName;
  document.documentElement.dataset.plainwireVersion = clientConfig.version;
  const app = window.Elm.Main.init({
    node: root,
    flags: {
      appName: clientConfig.appName,
      registrationEnabled: clientConfig.registrationEnabled,
      instanceDescription: clientConfig.instanceDescription,
      defaultTheme: clientConfig.defaultTheme,
      version: clientConfig.version
    }
  });
  let csrf = '';
  let ws = null;
  let wsQueue = [];
  let wsReconnectTimer = null;
  let wsReconnectAttempt = 0;
  const WS_QUEUE_LIMIT = 512;
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
  let callHealth = null;
  const RTC_RESUME_KEY = 'plainwire_rtc_room';
  const RTC_RESUME_MAX_AGE_MS = 60000;
  let resumeAttempted = false;
  let resumeInFlight = false;
  let speakerOn = true;
  let micMuted = false;
  let deafened = false;
  // Deafening also mutes; undeafening restores whatever the microphone was before.
  let mutedBeforeDeafen = false;
  let selectedInputId = storage.getItem('plainwire_audio_input') || '';
  let selectedOutputId = storage.getItem('plainwire_audio_output') || '';
  const readVolume = (key, maximum) => {
    const saved = storage.getItem(key);
    const value = saved === null ? 100 : Number(saved);
    return Number.isFinite(value) ? Math.max(0, Math.min(maximum, value)) : 100;
  };
  let inputVolume = readVolume('plainwire_input_volume', 200);
  const inputGains = new Set();
  const peerVolumeKey = uid => `plainwire_peer_volume_${meId}_${uid}`;
  class PlainwireVolume extends HTMLElement {
    static observedAttributes = ['user-id', 'user-name'];
    connectedCallback() { this.render(); }
    attributeChangedCallback() { if (this.isConnected) this.render(); }
    render() {
      const uid = Number(this.getAttribute('user-id'));
      const input = this.localName === 'pw-input-volume';
      if (!input && (!Number.isSafeInteger(uid) || uid <= 0)) return;
      const label = document.createElement('label');
      const title = document.createElement('span');
      title.textContent = input ? 'Input volume' : 'Listening volume';
      const output = document.createElement('output');
      const range = document.createElement('input');
      range.type = 'range'; range.min = '0'; range.max = input ? '200' : '100'; range.step = '1';
      range.value = String(input ? inputVolume : readVolume(peerVolumeKey(uid), 100));
      range.setAttribute('aria-label', input ? 'Input volume' : `${this.getAttribute('user-name') || 'Participant'} listening volume`);
      output.textContent = `${range.value}%`;
      range.addEventListener('input', () => {
        const value = Math.max(0, Math.min(input ? 200 : 100, Number(range.value)));
        output.textContent = `${value}%`;
        if (input) {
          inputVolume = value;
          storage.setItem('plainwire_input_volume', String(value));
          for (const gain of inputGains) gain.gain.setTargetAtTime(value / 100, gain.context.currentTime, 0.02);
        } else {
          storage.setItem(peerVolumeKey(uid), String(value));
          const audio = document.getElementById(`remote-audio-${uid}`);
          if (audio) audio.volume = value / 100;
        }
        for (const other of document.querySelectorAll(input ? 'pw-input-volume' : `pw-user-volume[user-id="${uid}"]`)) {
          if (other === this) continue;
          const slider = other.querySelector('input'); const readout = other.querySelector('output');
          if (slider) slider.value = String(value);
          if (readout) readout.textContent = `${value}%`;
        }
      });
      label.append(title, output, range); this.replaceChildren(label);
    }
  }
  customElements.define('pw-input-volume', class extends PlainwireVolume {});
  customElements.define('pw-user-volume', class extends PlainwireVolume {});
  const normalizeProcessingMode = (value) => ['noise', 'studio', 'krisp'].includes(value) ? value : 'noise';
  let voiceProcessingMode = normalizeProcessingMode(storage.getItem('plainwire_voice_processing') || 'noise');
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
  let screenAudioMixer = null;
  let screenSenders = new Map(); // uid -> RTCRtpSender for video
  const displayMediaSupported = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia);
  const peerPromises = new Map();
  const signalQueues = new Map();
  // Bumped whenever a participant's session is replaced, so queued signals from
  // the old session cannot resurrect a peer connection.
  const peerGenerations = new Map();
  const defaultRtcConfig = { iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }] };
  const RTC_CONNECT_CHECK_MS = 7000;
  // Relay (TURN over TCP/TLS) paths can take well over one check interval. An ICE
  // restart discards in-progress checks, so give checking time to finish first.
  const RTC_ICE_CHECKING_GRACE_MS = 15000;
  const RTC_MAX_RECOVERY_ATTEMPTS = 6;
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
  const watchedScreens = new Set();
  // very noisy. off unless somebody actually asks for it.
  const debugEnabled = window.PLAINWIRE_DEBUG === true || storage.getItem('plainwire_debug') === 'true';
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
      return {
        kind: value.kind,
        id,
        muted: value.muted === true,
        deafened: value.deafened === true,
        mutedBeforeDeafen: value.muted_before_deafen === true || value.restore_muted === true,
        at: value.at
      };
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
    resumeIntent = {
      kind: room.kind,
      id: room.id,
      muted: micMuted,
      deafened,
      muted_before_deafen: mutedBeforeDeafen,
      restore_muted: mutedBeforeDeafen,
      at: Date.now()
    };
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
      voice_state: { muted: micMuted, deafened, muted_before_deafen: mutedBeforeDeafen },
      local_tracks: localStream ? localStream.getTracks().map((t) => ({ kind: t.kind, enabled: t.enabled, muted: t.muted, readyState: t.readyState })) : [],
      peers: Array.from(peers, ([user_id, pc]) => ({
        user_id, connection: pc.connectionState, ice: pc.iceConnectionState,
        signaling: pc.signalingState, offerer: pc._offerer,
        recovery_attempts: pc._reconnectAttempts || 0,
        failed: pc._failureReported === true
      }))
    }),
    setEnabled: (enabled) => { storage.setItem('plainwire_debug', enabled ? 'true' : 'false'); location.reload(); }
  };
  debug('BOOT', 'bridge_initialized', { debug: debugEnabled, secure_context: window.isSecureContext, online: navigator.onLine, client_config: clientConfig });

  let rtcConfigNextRefresh = 0;
  let rtcConfigValidUntil = 0;
  let rtcRefreshTimer = null;
  const loadRtcConfig = () => {
    if (window.PLAINWIRE_RTC_CONFIG) return Promise.resolve(rtcConfig);
    if (rtcConfigRequest) return rtcConfigRequest;
    if (Date.now() < rtcConfigNextRefresh) return Promise.resolve(rtcConfig);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 6500);
    rtcConfigRequest = fetch('/api/rtc-config', { headers: { accept: 'application/json' }, cache: 'no-store', signal: controller.signal })
      .then(res => { if (!res.ok) throw new Error('Relay configuration unavailable'); return res.json(); })
      .then(json => {
        const config = json?.ok && json.data;
        if (!config || !Array.isArray(config.iceServers)) throw new Error('Invalid relay configuration');
        const before = JSON.stringify(rtcConfig.iceServers);
        rtcConfig = config;
        rtcConfigFetchedAt = Date.now();
        rtcConfigValidUntil = Date.now() + (Number(config.turnTtlSeconds) || 3600) * 1000;
        rtcConfigNextRefresh = Date.now() + Math.max(30, Math.min(300, Number(config.refreshAfterSeconds) || 300)) * 1000;
        const ttlMs = (Number(config.turnTtlSeconds) || 3600) * 1000;
        for (const [uid, pc] of peers) {
          if (pc.signalingState === 'closed') continue;
          try {
            pc.setConfiguration({ ...pc.getConfiguration(), iceServers: config.iceServers, iceTransportPolicy: config.iceTransportPolicy || 'all' });
            // Short-lived TURN credentials change on every fetch. Restarting ICE on
            // each refresh drops audio on healthy calls and throws away progress on
            // calls still checking, so only renew relays whose credentials are about
            // to expire. Recovery restarts pick up the new servers anyway.
            const expiring = pc._turnValidUntil > 0 && pc._turnValidUntil - Date.now() < Math.min(600000, ttlMs / 3);
            if (before !== JSON.stringify(config.iceServers) && config.turnStatus === 'ready' && room?.joined &&
                pc.connectionState === 'connected' && expiring) {
              restartPeerIce(uid, pc, 'relay_credentials_refreshed', { force: true });
            }
          } catch (error) { debug('RTC', 'configuration_update_failed', { error: error.message }, 'warn'); }
        }
        return rtcConfig;
      })
      .catch(error => {
        rtcConfigNextRefresh = Date.now() + 30000;
        if (Date.now() >= rtcConfigValidUntil) rtcConfig = { ...rtcConfig, iceServers: defaultRtcConfig.iceServers, turnStatus: 'unavailable' };
        debug('RTC', 'config_fetch_failed', { error: error.message }, 'warn');
        return rtcConfig;
      }).finally(() => { clearTimeout(timeout); rtcConfigRequest = null; });
    return rtcConfigRequest;
  };
  const startRtcRefresh = () => {
    if (!rtcRefreshTimer) rtcRefreshTimer = setInterval(() => { if (room?.joined) loadRtcConfig(); }, 15000);
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
          storage.setItem('plainwire_voice_processing', voiceProcessingMode);
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
  const IDLE_TIMEOUT_MS = clientConfig.idleTimeoutMs;

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
    data: storage.getItem('plainwire_sound_enabled') !== 'false'
  });
  send(app.ports.bridgeReceive, {
    tag: 'chat_enter_sends',
    data: storage.getItem('plainwire_chat_enter_mode') !== 'newline'
  });
  send(app.ports.bridgeReceive, { tag: 'link_previews_enabled', data: storage.getItem('plainwire_link_previews') !== 'false' });
  send(app.ports.bridgeReceive, { tag: 'animated_media_enabled', data: storage.getItem('plainwire_animated_media') !== 'false' });
  send(app.ports.bridgeReceive, { tag: 'compact_messages', data: storage.getItem('plainwire_compact_messages') === 'true' });
  send(app.ports.bridgeReceive, { tag: 'media_preload_enabled', data: storage.getItem('plainwire_media_preload') !== 'false' });

  const syncThemeMeta = () => {
    const meta = document.querySelector('meta[name="theme-color"]');
    if (!meta) return;
    const explicit = document.documentElement.dataset.theme;
    const isDark = explicit === 'dark' || (!explicit && window.matchMedia?.('(prefers-color-scheme: dark)').matches);
    meta.setAttribute('content', isDark ? '#121418' : '#eef0f3');
  };
  window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener?.('change', syncThemeMeta);
  syncThemeMeta();

  // Mobile browsers resize the visual viewport when the software keyboard opens.
  // Mark that state so the fixed bottom navigation gets out of the composer's way.
  let mobileViewportBaseline = 0;
  const syncMobileViewport = () => {
    const viewport = window.visualViewport;
    const visibleHeight = viewport?.height || window.innerHeight;
    const compact = window.innerWidth <= 760;
    if (!compact) {
      mobileViewportBaseline = 0;
    } else if (document.documentElement.dataset.mobileKeyboard !== 'open') {
      mobileViewportBaseline = Math.max(mobileViewportBaseline, window.innerHeight, visibleHeight);
    }
    const focused = document.activeElement;
    const editing = focused instanceof HTMLInputElement || focused instanceof HTMLTextAreaElement || focused instanceof HTMLSelectElement;
    const keyboardHeight = Math.max(0, mobileViewportBaseline - visibleHeight);
    const keyboardOpen = compact && editing && keyboardHeight > 140;
    document.documentElement.dataset.mobileKeyboard = keyboardOpen ? 'open' : 'closed';
    document.documentElement.style.setProperty('--pw-visual-height', `${Math.round(visibleHeight)}px`);
  };
  window.visualViewport?.addEventListener('resize', syncMobileViewport, { passive: true });
  window.visualViewport?.addEventListener('scroll', syncMobileViewport, { passive: true });
  document.addEventListener('focusin', syncMobileViewport, { passive: true });
  document.addEventListener('focusout', () => requestAnimationFrame(syncMobileViewport), { passive: true });
  window.addEventListener('orientationchange', () => {
    mobileViewportBaseline = 0;
    setTimeout(syncMobileViewport, 180);
  }, { passive: true });
  window.addEventListener('resize', syncMobileViewport, { passive: true });
  window.addEventListener('pageshow', syncMobileViewport, { passive: true });
  document.addEventListener('visibilitychange', syncMobileViewport, { passive: true });
  syncMobileViewport();

  const resizeComposer = (textarea) => {
    if (!(textarea instanceof HTMLTextAreaElement) || textarea.id !== 'compose') return;
    textarea._measuredDraft = textarea.value;
    textarea.style.height = 'auto';
    const visibleHeight = window.visualViewport?.height || window.innerHeight || 720;
    const mobileLimit = Math.max(72, Math.min(112, Math.round(visibleHeight * 0.2)));
    const limit = window.innerWidth <= 760 ? mobileLimit : 180;
    textarea.style.height = `${Math.min(limit, Math.max(48, textarea.scrollHeight))}px`;
    textarea.style.overflowY = textarea.scrollHeight > limit ? 'auto' : 'hidden';
  };
  // Elm stops propagation for onInput; capture is required for autosizing.
  document.addEventListener('input', (event) => resizeComposer(event.target), { passive: true, capture: true });
  document.addEventListener('focusin', (event) => {
    resizeComposer(event.target);
    if (window.innerWidth <= 760 && event.target instanceof HTMLElement) {
      // Let the keyboard finish opening before asking the browser to reveal the
      // focused control. This prevents iOS/Android from leaving a field under
      // the browser chrome after viewport resize.
      setTimeout(() => event.target?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' }), 90);
    }
  }, { passive: true });

  // Touch screens do not have hover. A tap on message whitespace reveals its
  // actions without permanently filling every message with buttons.
  let touchActionMessage = null;
  const closeTouchMessageActions = () => {
    if (touchActionMessage?.isConnected) delete touchActionMessage.dataset.touchActions;
    touchActionMessage = null;
  };
  document.addEventListener('pointerup', (event) => {
    if (event.pointerType !== 'touch') return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target || target.closest('a, button, input, textarea, select, video, audio')) return;
    const message = target.closest('.msg');
    if (!message) {
      closeTouchMessageActions();
      return;
    }
    if (touchActionMessage === message) {
      closeTouchMessageActions();
      return;
    }
    closeTouchMessageActions();
    message.dataset.touchActions = 'open';
    touchActionMessage = message;
  }, { passive: true });
  document.addEventListener('scroll', (event) => {
    if (touchActionMessage && event.target instanceof Element && event.target.closest?.('.messages')) {
      closeTouchMessageActions();
    }
  }, { capture: true, passive: true });

  // Native-feeling drawer dismissal on phones. Only the close gesture is
  // captured so we do not fight the browser's edge-swipe back navigation.
  let drawerSwipeStart = null;
  document.addEventListener('touchstart', (event) => {
    if (window.innerWidth > 760 || event.touches.length !== 1) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target?.closest('.side.open')) return;
    const touch = event.touches[0];
    drawerSwipeStart = { x: touch.clientX, y: touch.clientY };
  }, { passive: true });
  document.addEventListener('touchend', (event) => {
    if (!drawerSwipeStart || event.changedTouches.length !== 1) {
      drawerSwipeStart = null;
      return;
    }
    const touch = event.changedTouches[0];
    const dx = touch.clientX - drawerSwipeStart.x;
    const dy = touch.clientY - drawerSwipeStart.y;
    drawerSwipeStart = null;
    if (dx < -56 && Math.abs(dx) > Math.abs(dy) * 1.25) {
      document.querySelector('.drawer-overlay.open')?.click();
    }
  }, { passive: true });

  const accentPresets = Object.freeze({
    blue: ['#326b98', '#28597f'],
    teal: ['#16877a', '#116b61'],
    green: ['#37854f', '#2c6b40'],
    amber: ['#9a6716', '#7d5312'],
    rose: ['#b64d6b', '#963e58']
  });
  const applyUiPreferences = () => {
    const density = storage.getItem('plainwire_density') || 'comfortable';
    const reduceMotion = storage.getItem('plainwire_reduce_motion') === 'true';
    const fontScale = storage.getItem('plainwire_font_scale') || 'default';
    const cornerStyle = storage.getItem('plainwire_corner_style') || 'default';
    const animatedMedia = storage.getItem('plainwire_animated_media') !== 'false';
    const linkPreviews = storage.getItem('plainwire_link_previews') !== 'false';
    const accentName = storage.getItem('plainwire_accent') || 'blue';
    const accent = accentPresets[accentName] || accentPresets.blue;
    document.documentElement.dataset.density = density === 'compact' ? 'compact' : 'comfortable';
    document.documentElement.dataset.reduceMotion = reduceMotion ? 'true' : 'false';
    document.documentElement.dataset.fontScale = ['small', 'large'].includes(fontScale) ? fontScale : 'default';
    document.documentElement.dataset.cornerStyle = ['compact', 'rounded'].includes(cornerStyle) ? cornerStyle : 'default';
    document.documentElement.dataset.animatedMedia = animatedMedia ? 'true' : 'false';
    document.documentElement.dataset.linkPreviews = linkPreviews ? 'true' : 'false';
    document.documentElement.style.setProperty('--accent', accent[0]);
    document.documentElement.style.setProperty('--accent2', accent[1]);
    send(app.ports.bridgeReceive, {
      tag: 'ui_preferences',
      data: {
        density: density === 'compact' ? 'compact' : 'comfortable',
        reduce_motion: reduceMotion,
        font_scale: ['small', 'large'].includes(fontScale) ? fontScale : 'default',
        corner_style: ['compact', 'rounded'].includes(cornerStyle) ? cornerStyle : 'default',
        accent: accentPresets[accentName] ? accentName : 'blue'
      }
    });
  };
  applyUiPreferences();

  const recv = (port, fn) => {
    if (port && typeof port.subscribe === 'function') port.subscribe(fn);
  };

  let historyObserver = null;
  let historySentinel = null;
  let historyRoot = null;
  const mediaTime = (seconds) => {
    if (!Number.isFinite(seconds) || seconds < 0) return '-:--';
    const whole = Math.floor(seconds);
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
  };

  const matchingNodes = (root, selector) => root.matches?.(selector) ? [root, ...root.querySelectorAll(selector)] : root.querySelectorAll(selector);
  const mountMediaPlayers = (root = document) => {
    matchingNodes(root, '.pw-media-player:not([data-player-ready])').forEach((player) => {
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
      const savedSetting = storage.getItem('plainwire_media_volume');
      const savedVolume = savedSetting === null ? NaN : Number(savedSetting);
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
        storage.setItem('plainwire_media_volume', String(next));
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

  const embedCache = new Map();
  const embedInFlight = new Map();
  const EMBED_CACHE_LIMIT = 256;
  const setEmbedCache = (url, value) => {
    if (embedCache.has(url)) embedCache.delete(url);
    embedCache.set(url, value);
    while (embedCache.size > EMBED_CACHE_LIMIT) {
      const oldest = embedCache.keys().next().value;
      embedCache.delete(oldest);
    }
  };

  const fetchEmbed = (url) => {
    if (embedCache.has(url)) return Promise.resolve(embedCache.get(url));
    if (embedInFlight.has(url)) return embedInFlight.get(url);
    const request = fetch('/api/embed?url=' + encodeURIComponent(url), {
      headers: { accept: 'application/json' },
      credentials: 'same-origin'
    })
      .then((res) => res.ok ? res.json() : null)
      .then((json) => {
        const data = json?.ok && json.data ? json.data : null;
        setEmbedCache(url, data);
        return data;
      })
      .catch(() => {
        setEmbedCache(url, null);
        return null;
      })
      .finally(() => embedInFlight.delete(url));
    embedInFlight.set(url, request);
    return request;
  };

  const createEmbedCard = (meta) => {
    const card = document.createElement('a');
    card.className = 'link-embed';
    card.href = meta.url;
    card.target = '_blank';
    card.rel = 'noopener noreferrer';

    const copy = document.createElement('div');
    copy.className = 'link-embed-copy';
    if (meta.site_name) {
      const site = document.createElement('div');
      site.className = 'link-embed-site';
      site.textContent = String(meta.site_name).slice(0, 200);
      copy.appendChild(site);
    }
    if (meta.title) {
      const title = document.createElement('div');
      title.className = 'link-embed-title';
      title.textContent = String(meta.title).slice(0, 300);
      copy.appendChild(title);
    }
    if (meta.description) {
      const desc = document.createElement('div');
      desc.className = 'link-embed-description';
      desc.textContent = String(meta.description).slice(0, 700);
      copy.appendChild(desc);
    }
    card.appendChild(copy);
    if (typeof meta.image === 'string' && meta.image.startsWith('/api/media/')) {
      const image = document.createElement('img');
      image.className = 'link-embed-image';
      image.loading = 'lazy';
      image.decoding = 'async';
      image.alt = '';
      image.src = meta.image;
      image.addEventListener('error', () => image.remove(), { once: true });
      card.appendChild(image);
    }
    return card;
  };

  const mountLinkEmbeds = (root = document) => {
    matchingNodes(root, '.msg-body').forEach((body) => {
      if (body.dataset.embedsMounted === 'true') return;
      const links = Array.from(body.querySelectorAll('.message-link[data-embed-url]'))
        .map((link) => ({ link, url: link.dataset.embedUrl || '' }))
        .filter(({ url }) => /^https?:\/\//i.test(url))
        .slice(0, 2);
      body.dataset.embedsMounted = 'true';
      links.forEach(({ url }) => {
        fetchEmbed(url).then((meta) => {
          const alreadyMounted = Array.from(body.querySelectorAll('[data-embed-card-for]'))
            .some((node) => node.dataset.embedCardFor === url);
          if (!meta || !body.isConnected || alreadyMounted) return;
          const wrapper = document.createElement('div');
          wrapper.className = 'link-embed-wrap';
          wrapper.dataset.embedCardFor = url;
          wrapper.appendChild(createEmbedCard(meta));
          body.appendChild(wrapper);
        });
      });
    });
  };

  let forcedMessageScroll = 0;
  let forcedMessageList = null;
  let forcedMessageSettle = null;
  let pendingForcedMessageRoute = null;
  const traceMessageScroll = (event, list = forcedMessageList) => {
    window.__plainwireScrollTrace = (window.__plainwireScrollTrace || []).slice(-30);
    window.__plainwireScrollTrace.push({ event, at: Math.round(performance.now()), top: list?.scrollTop, height: list?.scrollHeight, client: list?.clientHeight, token: forcedMessageScroll });
  };
  const cancelForcedMessageScroll = () => {
    traceMessageScroll('cancel');
    forcedMessageScroll += 1;
    forcedMessageList = null;
    forcedMessageSettle = null;
    pendingForcedMessageRoute = null;
  };

  const trackMessageScroll = () => {
    const list = document.getElementById('messages');
    if (!list || list === messageListElement) return list;
    messageListElement = list;
    messagesPinnedToBottom = true;
    list.addEventListener('wheel', cancelForcedMessageScroll, { passive: true });
    list.addEventListener('touchstart', cancelForcedMessageScroll, { passive: true });
    list.addEventListener('pointerdown', cancelForcedMessageScroll, { passive: true });
    list.addEventListener('scroll', () => {
      messagesPinnedToBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 120;
    }, { passive: true });
    return list;
  };

  const scrollMessageListToBottom = (force = false) => {
    const list = trackMessageScroll();
    if (!list || (!force && !messagesPinnedToBottom)) return;
    const forcedToken = force ? ++forcedMessageScroll : forcedMessageScroll;
    traceMessageScroll(force ? 'force' : 'follow', list);
    messagesPinnedToBottom = true;
    const settle = () => {
      if (!list.isConnected || list !== document.getElementById('messages')) return;
      if (force ? forcedToken !== forcedMessageScroll : !messagesPinnedToBottom) return;
      list.scrollTop = list.scrollHeight;
      messagesPinnedToBottom = true;
      traceMessageScroll(force ? 'settle-force' : 'settle-follow', list);
    };
    if (force) {
      forcedMessageList = list;
      forcedMessageSettle = settle;
    }
    settle();
    requestAnimationFrame(() => requestAnimationFrame(settle));
    setTimeout(settle, 90);
    setTimeout(settle, 260);
    if (force) {
      // Markdown previews and proxied media can gain their final height after the
      // first paint. Keep a newly opened room at its latest message while that
      // layout settles, unless the reader starts scrolling themselves.
      setTimeout(settle, 600);
      setTimeout(settle, 1200);
      setTimeout(settle, 2400);
    }
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

  const inviteRoots = new WeakSet();
  const mountInviteManagers = () => {
    document.querySelectorAll('[data-invite-server]').forEach(root => {
      if (inviteRoots.has(root)) return;
      inviteRoots.add(root);
      const sid = Number(root.dataset.inviteServer);
      if (!Number.isSafeInteger(sid) || sid < 1) return;
      const heading = document.createElement('h3'); heading.textContent = 'Manage links';
      const list = document.createElement('div'); list.className = 'invite-link-list'; list.setAttribute('aria-live', 'polite');
      root.append(heading, list);
      const refresh = async () => {
        list.textContent = 'Loading invite links…';
        try {
          const invites = await accountApi('GET', `/server/${sid}/invites`);
          if (!root.isConnected) return;
          if (!Array.isArray(invites)) throw new Error('Could not load invites');
          list.textContent = '';
          if (!invites.length) { list.textContent = 'No invite links yet.'; return; }
          for (const invite of invites) {
            const row = document.createElement('div'); row.className = 'invite-link-row';
            const copy = document.createElement('div'); copy.className = 'invite-link-info';
            const expired = invite.expires_at > 0 && invite.expires_at <= Date.now();
            const used = invite.max_uses > 0 && invite.uses >= invite.max_uses;
            const inactive = invite.revoked || expired || used;
            const title = document.createElement('b'); title.textContent = invite.revoked ? 'Revoked link' : expired ? 'Expired link' : used ? 'Use limit reached' : 'Active invite';
            const detail = document.createElement('small');
            detail.textContent = `${invite.uses} / ${invite.max_uses || 'unlimited'} uses · ${invite.expires_at ? 'Expires ' + new Date(invite.expires_at).toLocaleString() : 'Never expires'}`;
            copy.append(title, detail); row.append(copy);
            if (!inactive) {
              const copyButton = document.createElement('button'); copyButton.type = 'button'; copyButton.className = 'btn secondary'; copyButton.textContent = 'Copy'; copyButton.setAttribute('aria-label', 'Copy invite link');
              copyButton.addEventListener('click', async () => {
                try { await navigator.clipboard.writeText(`${location.origin}/#invite/${invite.code}`); copyButton.textContent = 'Copied'; }
                catch (_) { copyButton.textContent = 'Copy failed'; }
              });
              const revoke = document.createElement('button'); revoke.type = 'button'; revoke.className = 'btn ghost danger-text'; revoke.textContent = 'Revoke';
              revoke.addEventListener('click', async () => {
                revoke.disabled = true;
                try { await accountApi('DELETE', `/server/${sid}/invites/${encodeURIComponent(invite.code)}`); await refresh(); }
                catch (_) { revoke.disabled = false; revoke.textContent = 'Retry revoke'; }
              });
              row.append(copyButton, revoke);
            }
            list.append(row);
          }
        } catch (_) {
          if (!root.isConnected) return;
          list.textContent = 'Could not load invite links. ';
          const retry = document.createElement('button'); retry.className = 'btn secondary'; retry.type = 'button'; retry.textContent = 'Retry'; retry.addEventListener('click', refresh); list.append(retry);
        }
      };
      refresh();
    });
  };

  let messageDomFrame = 0;
  const changedMessageRoots = new Set();
  let timersChanged = false, invitesChanged = false, composerChanged = false;
  const messageDomObserver = new MutationObserver((records) => {
    const contains = (node, selector) => node.matches?.(selector) || node.querySelector?.(selector);
    for (const record of records) {
      for (const node of [...record.addedNodes, ...record.removedNodes]) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (contains(node, '.pw-live-call-timer')) timersChanged = true;
        if (contains(node, '.invite-manager')) invitesChanged = true;
        if (contains(node, '#compose')) composerChanged = true;
        if (node.isConnected && contains(node, '#messages, .msg-body, .pw-media-player, .message-link')) changedMessageRoots.add(node.closest('.msg-body') || node);
      }
    }
    if (messageDomFrame || (!changedMessageRoots.size && !timersChanged && !invitesChanged && !composerChanged)) return;
    messageDomFrame = requestAnimationFrame(() => {
      messageDomFrame = 0;
      const list = trackMessageScroll();
      if (list && pendingForcedMessageRoute === location.hash) {
        pendingForcedMessageRoute = null;
        scrollMessageListToBottom(true);
      } else if (pendingForcedMessageRoute && pendingForcedMessageRoute !== location.hash) {
        pendingForcedMessageRoute = null;
      }
      observeMessageHistory();
      // Visit only added subtrees, rather than rescanning every old message.
      for (const root of changedMessageRoots) {
        if (!root.isConnected) continue;
        let covered = false;
        for (let parent = root.parentElement; parent; parent = parent.parentElement) { if (changedMessageRoots.has(parent)) { covered = true; break; } }
        if (covered) continue;
        mountMediaPlayers(root);
        mountLinkEmbeds(root);
      }
      if (changedMessageRoots.size) {
        list?.dispatchEvent(new Event('plainwire:messages'));
        if (forcedMessageList === list && forcedMessageSettle) forcedMessageSettle();
        else if (messagesPinnedToBottom) scrollMessageListToBottom();
        const composer = document.getElementById('compose');
        if (composer && composer._measuredDraft !== composer.value) composerChanged = true;
      }
      changedMessageRoots.clear();
      if (timersChanged) updateCallTimers();
      if (invitesChanged) mountInviteManagers();
      if (composerChanged) resizeComposer(document.getElementById('compose'));
      timersChanged = invitesChanged = composerChanged = false;
    });
  });
  messageDomObserver.observe(document.body, { childList: true, subtree: true });
  document.addEventListener('load', (event) => {
    const media = event.target;
    if ((media instanceof HTMLImageElement || media instanceof HTMLVideoElement)
        && media.closest?.('#messages') === forcedMessageList) forcedMessageSettle?.();
  }, true);
  document.addEventListener('keydown', (event) => {
    if (!forcedMessageList || event.target?.matches?.('input, textarea, select, [contenteditable="true"]')) return;
    if (['PageUp', 'PageDown', 'Home', 'End', 'ArrowUp', 'ArrowDown', ' '].includes(event.key)) cancelForcedMessageScroll();
  });
  trackMessageScroll();
  observeMessageHistory();
  mountMediaPlayers();
  mountLinkEmbeds();
  updateCallTimers();

  const audioContext = () => {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    audioCtx = audioCtx || new Ctx();
    return audioCtx;
  };

  const soundNodes = new Set();
  let soundEpoch = 0;
  let lastNotificationAt = -Infinity;
  const stopSoundGroup = (group) => {
    const ctx = audioCtx;
    if (!ctx || !soundNodes.size) return;
    for (const node of soundNodes) {
      if (group && node.group !== group) continue;
      const now = ctx.currentTime;
      try {
        if (node.gain.gain.cancelAndHoldAtTime) node.gain.gain.cancelAndHoldAtTime(now);
        else { node.gain.gain.cancelScheduledValues(now); node.gain.gain.setValueAtTime(0.0001, now); }
        node.gain.gain.linearRampToValueAtTime(0, now + 0.015);
        node.osc.stop(now + 0.02);
      } catch (_) {}
    }
  };
  const playTone = ({ freq = 660, dur = 240, delay = 0, vol = 0.04, group = 'effect' } = {}) => {
    const ctx = audioContext();
    if (!ctx || ctx.state !== 'running' || soundNodes.size >= 36) return null;
    const start = ctx.currentTime + Math.max(0, delay) / 1000;
    const stop = start + Math.max(60, dur) / 1000;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(Math.max(80, Math.min(4000, freq)), start);
    gain.gain.setValueAtTime(0, start);
    gain.gain.linearRampToValueAtTime(Math.min(0.08, Math.max(0.0002, vol)), start + 0.009);
    gain.gain.exponentialRampToValueAtTime(0.0001, stop);
    gain.gain.linearRampToValueAtTime(0, stop + 0.015);
    osc.connect(gain);
    gain.connect(ctx.destination);
    const node = { osc, gain, group };
    soundNodes.add(node);
    osc.onended = () => {
      soundNodes.delete(node);
      try { osc.disconnect(); gain.disconnect(); } catch (_) {}
    };
    osc.start(start);
    osc.stop(stop + 0.02);
    return osc;
  };

  // Rounded, fixed-pitch bell tones. A quiet upper partial adds warmth without
  // sharp waveforms, pitch sweeps, downloads, or a new AudioContext per alert.
  const soundPatterns = {
    notification: [[784, 0, 250, 0.035], [1046.5, 85, 330, 0.026]],
    mention: [[880, 0, 200, 0.045], [1174.66, 110, 260, 0.05], [1567.98, 235, 340, 0.042]],
    incoming: [[523.25, 0, 430, 0.038], [659.25, 160, 430, 0.033], [783.99, 320, 540, 0.028]],
    outgoing: [[392, 0, 300, 0.025], [523.25, 240, 380, 0.022]]
  };
  let lastMentionAt = 0;
  const playSound = (name, { preview = false } = {}) => {
    if (!soundPatterns[name] || (!preview && storage.getItem('plainwire_sound_enabled') === 'false')) return;
    if (!preview && name === 'notification') {
      if (performance.now() - lastNotificationAt < 700) return;
      lastNotificationAt = performance.now();
    }
    if (!preview && name === 'mention') {
      if (performance.now() - lastMentionAt < 1200) return;
      lastMentionAt = performance.now();
    }
    const epoch = soundEpoch;
    const ctx = audioContext();
    if (!ctx) return;
    const play = () => {
      if (epoch !== soundEpoch || ctx.state !== 'running') return;
      if (!preview && storage.getItem('plainwire_sound_enabled') === 'false') return;
      const group = preview ? 'preview' : name === 'notification' ? 'effect' : 'ringtone';
      stopSoundGroup(group);
      soundPatterns[name].forEach(([freq, delay, dur, vol]) => {
        playTone({ freq, delay, dur, vol, group });
        playTone({ freq: freq * 2, delay, dur: dur * 0.55, vol: vol * 0.12, group });
      });
    };
    if (ctx.state === 'suspended') ctx.resume().then(play).catch(() => {});
    else play();
  };

  const stopRingtones = () => {
    if (ringtoneTimer) clearInterval(ringtoneTimer);
    if (outgoingTimer) clearInterval(outgoingTimer);
    ringtoneTimer = null;
    outgoingTimer = null;
    soundEpoch++;
    stopSoundGroup('ringtone');
  };

  const startRingtone = (kind) => {
    stopRingtones();
    if (storage.getItem('plainwire_sound_enabled') === 'false') return;
    if (kind === 'incoming') {
      playSound('incoming');
      ringtoneTimer = setInterval(() => playSound('incoming'), 3800);
    } else {
      playSound('outgoing');
      outgoingTimer = setInterval(() => playSound('outgoing'), 4200);
    }
  };

  const debugApiBody = (path, body) => {
    if (path === '/login' || path === '/register' || path === '/password') return '[redacted]';
    return body;
  };

  const performApi = async ({ method = 'GET', path, body, request_id = null }) => {
    const requestRoute = location.hash;
    const requestStarted = performance.now();
    debug('API', 'request', { method, path, body: debugApiBody(path, body) });
    const headers = { accept: 'application/json', 'x-csrf-token': csrf };
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);
    const options = { method, headers, signal: controller.signal, cache: 'no-store' };
    if (body !== null && body !== undefined) {
      headers['content-type'] = 'application/json';
      options.body = JSON.stringify(body);
    }

    try {
      const res = await fetch('/api' + path, options);
      const json = await res.json().catch(() => ({ ok: false, error: 'bad_json' }));
      debug('API', 'response', { method, path, status: res.status, ok: !!json.ok, duration_ms: Math.round(performance.now() - requestStarted), error: json.error });
      if (method === 'GET' && /^\/(messages\?|thread\/|threads\?|profile\/|server\/|users\?)/.test(path) && requestRoute !== location.hash) return null;
      if (json.ok && json.data && json.data.csrf) csrf = json.data.csrf;
      if (json.ok && json.data && json.data.user && json.data.user.id) meId = json.data.user.id;
      if (json.ok && json.data) updatePresenceWatch(json.data);
      if (json.ok && method === 'POST' && /^\/server\/\d+\/invites$/.test(path) && typeof json.data?.url === 'string' && json.data.url.startsWith('#invite/')) {
        json.data.url = new URL(json.data.url, location.origin + '/').href;
      }
      send(app.ports.apiReceive, {
        path,
        method,
        request_id,
        ok: res.ok && !!json.ok,
        data: json.data || null,
        error: json.error || (json.ok ? null : 'request_failed')
      });
      return json.ok ? json.data : null;
    } catch (error) {
      debug('API', 'request_failed', { method, path, duration_ms: Math.round(performance.now() - requestStarted), error: error.message }, 'error');
      send(app.ports.apiReceive, { path, method, request_id, ok: false, data: null, error: error.name === 'AbortError' ? 'request_timeout' : 'request_failed' });
      return null;
    } finally {
      clearTimeout(timeout);
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

  const closeFormatting = (restoreFocus = false) => {
    for (const details of document.querySelectorAll('.compose-format-help[open]')) {
      details.open = false;
      if (restoreFocus) details.querySelector('summary')?.focus();
    }
  };
  const placeFormatting = () => {
    for (const details of document.querySelectorAll('.compose-format-help[open]')) {
      const panel = details.querySelector('.compose-format-panel');
      if (!panel) continue;
      const view = window.visualViewport;
      const top = view?.offsetTop || 0, left = view?.offsetLeft || 0;
      const width = view?.width || innerWidth, height = view?.height || innerHeight;
      const anchor = details.closest('.composer').getBoundingClientRect();
      panel.style.width = `${Math.min(440, width - 24)}px`;
      panel.style.maxHeight = `${Math.max(80, Math.min(360, height - 24, anchor.top - top - 20))}px`;
      panel.style.left = `${Math.max(left + 12, Math.min(anchor.left, left + width - panel.offsetWidth - 12))}px`;
      panel.style.top = `${Math.max(top + 12, Math.min(anchor.top - panel.offsetHeight - 8, top + height - panel.offsetHeight - 12))}px`;
    }
  };
  let formattingFrame = 0;
  const scheduleFormatting = () => {
    if (formattingFrame) return;
    formattingFrame = requestAnimationFrame(() => { formattingFrame = 0; placeFormatting(); });
  };
  const applyFormatting = (kind) => {
    const field = activeComposer();
    if (!field) return;
    const start = field.selectionStart, end = field.selectionEnd;
    const selected = field.value.slice(start, end);
    const styles = { bold: ['**', '**', 'text'], italic: ['*', '*', 'text'], code: ['`', '`', 'code'], block: ['```text\n', '\n```', 'code'], quote: ['> ', '', 'quote'] };
    const style = styles[kind];
    if (!style) return;
    let [before, after, fallback] = style;
    if ((kind === 'quote' || kind === 'block') && start > 0 && field.value[start - 1] !== '\n') before = '\n' + before;
    if ((kind === 'quote' || kind === 'block') && end < field.value.length && field.value[end] !== '\n') after += '\n';
    const content = kind === 'quote' ? (selected || fallback).replaceAll('\n', '\n> ') : selected || fallback;
    const replacement = before + content + after;
    if (field.value.length - (end - start) + replacement.length > field.maxLength) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'This message has reached the 5,000 character limit.' });
      return;
    }
    field.setRangeText(replacement, start, end, 'end');
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.focus({ preventScroll: true });
    field.setSelectionRange(start + before.length, start + before.length + content.length);
    scheduleFormatting();
  };
  document.addEventListener('toggle', event => {
    if (event.target.matches?.('.compose-format-help')) scheduleFormatting();
  }, true);
  document.addEventListener('pointerdown', event => {
    if (!event.target.closest?.('.compose-format-help')) closeFormatting();
  }, true);
  document.addEventListener('click', event => {
    if (event.target.closest?.('[data-format-close]')) { event.preventDefault(); closeFormatting(true); }
    const tool = event.target.closest?.('[data-format]');
    if (tool) { event.preventDefault(); applyFormatting(tool.dataset.format); }
  }, true);
  document.addEventListener('keydown', event => {
    if (event.isComposing) return;
    if (event.key === 'Escape' && document.querySelector('.compose-format-help[open]')) {
      event.preventDefault(); event.stopImmediatePropagation(); closeFormatting(true);
    } else if (event.target === activeComposer() && (event.ctrlKey || event.metaKey) && !event.altKey) {
      const kind = { b: 'bold', i: 'italic', e: 'code' }[event.key.toLowerCase()];
      if (kind) { event.preventDefault(); event.stopPropagation(); applyFormatting(kind); }
    }
  }, true);
  document.addEventListener('input', event => { if (event.target.id === 'compose') scheduleFormatting(); }, true);
  document.addEventListener('focusin', event => {
    if (!event.target.closest?.('.compose-format-help, .composer')) closeFormatting();
  });
  window.addEventListener('hashchange', () => closeFormatting());
  window.addEventListener('resize', scheduleFormatting, { passive: true });
  window.visualViewport?.addEventListener('resize', scheduleFormatting, { passive: true });
  window.visualViewport?.addEventListener('scroll', scheduleFormatting, { passive: true });

  const appendToComposer = (text) => {
    const composer = activeComposer();
    if (!composer) return;
    const start = composer.selectionStart ?? composer.value.length;
    const end = composer.selectionEnd ?? start;
    const before = composer.value.slice(0, start);
    const after = composer.value.slice(end);
    const leading = before && !before.endsWith('\n') ? '\n' : '';
    const trailing = after.startsWith('\n') ? '' : '\n';
    composer.setRangeText(leading + text + trailing, start, end, 'end');
    composer.dispatchEvent(new Event('input', { bubbles: true }));
    composer.focus({ preventScroll: true });
  };

  const humanBytes = (bytes) => {
    const n = Number(bytes || 0);
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(n < 10 * 1024 ? 1 : 0)} KB`;
    return `${(n / (1024 * 1024)).toFixed(n < 10 * 1024 * 1024 ? 1 : 0)} MB`;
  };

  const blobToFile = (blob, source, suffix = '') => new File(
    [blob],
    `${source.name || 'file'}${suffix}`,
    { type: blob.type || source.type || 'application/octet-stream', lastModified: Date.now() }
  );

  const canvasBlob = (canvas, type, quality) => new Promise((resolve) => {
    canvas.toBlob((blob) => resolve(blob), type, quality);
  });

  const compressImageForUpload = async (file, targetBytes) => {
    if (!/^image\/(jpeg|png|webp|avif)$/i.test(file.type || '')) return null;
    let bitmap;
    try {
      bitmap = await createImageBitmap(file);
    } catch (_) {
      return null;
    }
    try {
      const originalMax = Math.max(bitmap.width, bitmap.height);
      const targetMax = Math.min(clientConfig.maxImageDimension, originalMax);
      const alphaSource = /png|webp|avif/i.test(file.type || '');
      const outputType = alphaSource ? 'image/webp' : 'image/jpeg';
      const qualitySteps = [0.9, 0.82, 0.74, 0.64, 0.54, 0.44, 0.34];
      const scaleSteps = [1, 0.88, 0.76, 0.64, 0.52, 0.42, 0.34];
      let smallest = null;
      for (const scale of scaleSteps) {
        const maxDim = Math.max(320, Math.floor(targetMax * scale));
        const ratio = Math.min(1, maxDim / originalMax);
        const width = Math.max(1, Math.round(bitmap.width * ratio));
        const height = Math.max(1, Math.round(bitmap.height * ratio));
        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext('2d', { alpha: alphaSource });
        if (!ctx) continue;
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(bitmap, 0, 0, width, height);
        for (const quality of qualitySteps) {
          const blob = await canvasBlob(canvas, outputType, quality);
          if (!blob) continue;
          if (!smallest || blob.size < smallest.size) smallest = blob;
          if (blob.size <= targetBytes) {
            const ext = outputType === 'image/webp' ? '.webp' : '.jpg';
            const base = (file.name || 'image').replace(/\.[^.]+$/, '');
            return new File([blob], `${base}${ext}`, { type: outputType, lastModified: Date.now() });
          }
        }
      }
      if (smallest && smallest.size < file.size && smallest.size <= targetBytes) {
        return blobToFile(smallest, file, '.compressed');
      }
      return null;
    } finally {
      bitmap.close?.();
    }
  };

  const gzipForUpload = async (file, targetBytes) => {
    if (typeof CompressionStream !== 'function') return null;
    try {
      const gz = file.stream().pipeThrough(new CompressionStream('gzip'));
      const blob = await new Response(gz).blob();
      if (!blob.size || blob.size >= file.size || blob.size > targetBytes) return null;
      return new File([blob], `${file.name || 'file'}.gz`, { type: 'application/gzip', lastModified: Date.now() });
    } catch (_) {
      return null;
    }
  };

  const prepareFileForUpload = async (file, targetBytes = clientConfig.uploadMaxBytes, { ask = true } = {}) => {
    if (!file || file.size <= 0) throw new Error('empty_file');
    if (file.size <= targetBytes) return file;
    if (!clientConfig.compressOversizeUploads) throw new Error('file_too_large');
    // Browser-side compression is intentionally bounded. Decoding or buffering a
    // multi-gigabyte file just to discover it cannot fit would freeze the tab.
    const compressionInputLimit = Math.min(Math.max(targetBytes * 2, targetBytes + 32 * 1024 * 1024), 512 * 1024 * 1024);
    if (file.size > compressionInputLimit) throw new Error('compression_input_too_large');
    if (ask) {
      const accepted = window.confirm(
        `${file.name || 'This file'} is ${humanBytes(file.size)}, above the ${humanBytes(targetBytes)} limit. Try to compress it before uploading?`
      );
      if (!accepted) throw new Error('upload_cancelled');
    }
    send(app.ports.bridgeReceive, { tag: 'toast', data: `Compressing ${file.name || 'file'}...` });
    const image = await compressImageForUpload(file, targetBytes);
    if (image) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Compressed to ${humanBytes(image.size)}.` });
      return image;
    }
    const gzip = await gzipForUpload(file, targetBytes);
    if (gzip) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Compressed to ${humanBytes(gzip.size)} as gzip.` });
      return gzip;
    }
    throw new Error('compression_failed');
  };

  const uploadOne = (file) => new Promise((resolve, reject) => {
    if (!file || file.size <= 0) return reject(new Error('empty_file'));
    if (file.size > clientConfig.uploadMaxBytes) return reject(new Error('file_too_large'));
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/uploads');
    xhr.responseType = 'json';
    xhr.timeout = 10 * 60 * 1000;
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
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Uploading ${file.name || 'image'}... ${progress}%` });
    };
    xhr.onload = () => {
      const json = xhr.response;
      if (xhr.status >= 200 && xhr.status < 300 && json?.ok && json.data) resolve(json.data);
      else reject(new Error(json?.error || 'upload_failed'));
    };
    xhr.onerror = () => reject(new Error('network_error'));
    xhr.ontimeout = () => reject(new Error('network_timeout'));
    xhr.onabort = () => reject(new Error('upload_cancelled'));
    xhr.send(file);
  });

  const uploadFiles = async (files) => {
    const selected = Array.from(files || []);
    const uploadRoute = location.hash;
    if (selected.length > clientConfig.uploadMaxFiles) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Only the first ${clientConfig.uploadMaxFiles} files will be uploaded.` });
    }
    for (const sourceFile of selected.slice(0, clientConfig.uploadMaxFiles)) {
      try {
        const file = await prepareFileForUpload(sourceFile);
        const uploaded = await uploadOne(file);
        const safeName = String(uploaded.name || 'file').replace(/[\]()[\r\n]/g, '_');
        const markup = String(uploaded.content_type || '').startsWith('image/')
          ? `![${safeName}](${uploaded.url})` : `[${safeName}](${uploaded.url})`;
        if (location.hash === uploadRoute) appendToComposer(markup);
        else send(app.ports.bridgeReceive, { tag: 'attachment_ready', route: uploadRoute, data: markup });
        send(app.ports.bridgeReceive, { tag: 'toast', data: `${safeName} ready to send` });
      } catch (error) {
        const messages = {
          file_too_large: `Files can be up to ${humanBytes(clientConfig.uploadMaxBytes)}.`,
          compression_failed: `Could not compress that file below ${humanBytes(clientConfig.uploadMaxBytes)}.`,
          compression_input_too_large: `That file is too large to compress safely in the browser. The compression limit is ${humanBytes(Math.min(Math.max(clientConfig.uploadMaxBytes * 2, clientConfig.uploadMaxBytes + 32 * 1024 * 1024), 512 * 1024 * 1024))}.`,
          upload_quota_exceeded: 'Upload quota reached. Try again later.',
          too_many_concurrent_uploads: 'Too many uploads are already in progress.',
          network_error: 'Upload connection interrupted.',
          network_timeout: 'Upload timed out. Try again on a steadier connection.',
          upload_cancelled: 'Upload cancelled.'
        };
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
    const clipboard = event.clipboardData;
    const itemFiles = Array.from(clipboard?.items || []).filter(item => item.kind === 'file').map(item => item.getAsFile()).filter(Boolean);
    const files = itemFiles.length ? itemFiles : Array.from(clipboard?.files || []);
    const html = String(clipboard?.getData('text/html') || '').slice(0, 2 * 1024 * 1024);
    let imageSource = '';
    if (html) {
      try { imageSource = new DOMParser().parseFromString(html, 'text/html').querySelector('img')?.getAttribute('src') || ''; }
      catch (_) {}
    }
    const remoteImage = (() => {
      try {
        const url = new URL(imageSource);
        return /^https?:$/.test(url.protocol) && /\.(?:gif|png|jpe?g|webp|avif)$/i.test(url.pathname) ? url.href : '';
      } catch (_) { return ''; }
    })();
    if (remoteImage && (/\.gif(?:$|[?#])/i.test(remoteImage) || !files.length)) {
      event.preventDefault();
      const name = /\.gif(?:$|[?#])/i.test(remoteImage) ? 'animated.gif' : 'image';
      appendToComposer(`![${name}](${remoteImage})`);
    } else if (files.length) {
      event.preventDefault();
      uploadFiles(files);
    } else if (/^data:image\/(?:gif|png|jpeg|webp|avif);base64,/i.test(imageSource) && imageSource.length <= clientConfig.uploadMaxBytes * 1.5) {
      event.preventDefault();
      fetch(imageSource).then(response => response.blob()).then(blob => {
        const extension = { 'image/gif': 'gif', 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/avif': 'avif' }[blob.type] || 'image';
        return uploadFiles([new File([blob], `pasted-image.${extension}`, { type: blob.type, lastModified: Date.now() })]);
      }).catch(() => send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not read that pasted image.' }));
    }
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
    const socket = ws;
    ws.onopen = () => {
      if (wsReconnectTimer) { clearTimeout(wsReconnectTimer); wsReconnectTimer = null; }
      wsReconnectAttempt = 0;
      const queued = wsQueue;
      wsQueue = [];
      debug('WS', 'connected', { queued: queued.length, room });
      send(app.ports.bridgeReceive, { tag: 'ws_status', data: true });
      queued.forEach((value) => sendWs(value));
      publishPresence(true);
      if (room && room.joined && localStream) {
        // The server told everyone we left when the old socket dropped, so they
        // have closed their side. Start clean instead of keeping half a connection.
        room.epoch = ++roomEpoch;
        room.stateSynced = false;
        peers.forEach((_, uid) => closePeer(uid));
        peerPromises.clear();
        signalQueues.clear();
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
      if (ws !== socket) return;
      if (wsPingTimer) { clearInterval(wsPingTimer); wsPingTimer = null; }
      send(app.ports.bridgeReceive, { tag: 'ws_status', data: false });
      ws = null;
      wsReconnectAttempt = Math.min(wsReconnectAttempt + 1, 8);
      const base = Math.min(15000, 500 * Math.pow(2, wsReconnectAttempt));
      const delay = Math.max(500, Math.round(base * (0.75 + Math.random() * 0.5)));
      debug('WS', 'closed', { code: event.code, reason: event.reason || '(none)', clean: event.wasClean, reconnect_ms: delay }, 'warn');
      if (!wsReconnectTimer) {
        wsReconnectTimer = setTimeout(() => {
          wsReconnectTimer = null;
          connectWs();
        }, delay);
      }
    };
  };

  const queueWs = (value) => {
    if (!value || typeof value !== 'object') return;
    if (value.type === 'ping') return;
    if (value.type === 'presence_update' || value.type === 'presence_watch') {
      for (let i = wsQueue.length - 1; i >= 0; i--) {
        if (wsQueue[i]?.type === value.type) {
          wsQueue[i] = value;
          return;
        }
      }
    }
    if (wsQueue.length >= WS_QUEUE_LIMIT) {
      const disposable = wsQueue.findIndex((item) => ['presence_update', 'presence_watch', 'voice_activity'].includes(item?.type));
      if (disposable >= 0) wsQueue.splice(disposable, 1);
      else wsQueue.shift();
    }
    wsQueue.push(value);
  };

  const sendWs = (value) => {
    connectWs();
    if (ws && ws.readyState === WebSocket.OPEN) {
      debug('WS', 'sent', { message: value });
      ws.send(JSON.stringify(value));
    } else {
      queueWs(value);
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
  const disposeScreenAudioMixer = (mixer) => {
    if (!mixer || mixer.disposed) return;
    mixer.disposed = true;
    try { mixer.microphoneSource.disconnect(); } catch (_) {}
    try { mixer.screenSource.disconnect(); } catch (_) {}
    try { mixer.destination.disconnect?.(); } catch (_) {}
    stopStream(mixer.destination.stream);
  };
  const createScreenAudioMixer = (displayStream, microphoneStream = localStream) => {
    const screenTrack = displayStream?.getAudioTracks().find((track) => track.readyState === 'live');
    if (!screenTrack) return null;
    const microphoneTrack = microphoneStream?.getAudioTracks().find((track) => track.readyState === 'live');
    if (!microphoneTrack) throw new Error('No live microphone track for screen audio');
    const ctx = audioContext();
    if (!ctx) throw new Error('Web Audio is unavailable for screen audio');
    const destination = ctx.createMediaStreamDestination();
    let microphoneSource;
    let screenSource;
    try {
      microphoneSource = ctx.createMediaStreamSource(new MediaStream([microphoneTrack]));
      screenSource = ctx.createMediaStreamSource(new MediaStream([screenTrack]));
      microphoneSource.connect(destination);
      screenSource.connect(destination);
      const track = destination.stream.getAudioTracks()[0];
      if (!track) throw new Error('Could not create a mixed screen audio track');
      ctx.resume?.().catch(() => {});
      return { track, destination, microphoneSource, screenSource, screenTrack, disposed: false };
    } catch (error) {
      try { microphoneSource?.disconnect(); } catch (_) {}
      try { screenSource?.disconnect(); } catch (_) {}
      stopStream(destination.stream);
      throw error;
    }
  };
  const outgoingAudioTrack = (microphoneStream = localStream, mixer = screenAudioMixer) =>
    mixer?.track?.readyState === 'live'
      ? mixer.track
      : microphoneStream?.getAudioTracks().find((track) => track.readyState === 'live') || null;
  const openRawMicrophone = async (mode = voiceProcessingMode) => {
    try {
      return await navigator.mediaDevices.getUserMedia({ audio: microphoneConstraints(mode), video: false });
    } catch (error) {
      if (!selectedInputId || !['NotFoundError', 'OverconstrainedError'].includes(error.name)) throw error;
      // Device IDs can expire or refer to an unplugged headset. Keep permission
      // failures explicit, but recover an unavailable saved device to the default.
      const { deviceId, ...audio } = microphoneConstraints(mode);
      const stream = await navigator.mediaDevices.getUserMedia({ audio, video: false });
      selectedInputId = '';
      storage.setItem('plainwire_audio_input', '');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Saved microphone unavailable. Using your system default.' });
      publishAudioDevices();
      return stream;
    }
  };

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
    const lease = mode === 'krisp' ? await krispMicrophoneLease() : nativeMicrophoneLease(await openRawMicrophone(mode), mode);
    let source, gain, destination;
    try {
      const ctx = audioContext();
      if (!ctx) throw new Error('Microphone volume requires Web Audio support');
      await ctx.resume();
      if (ctx.state !== 'running') throw new Error('Click the call button again to enable microphone audio');
      source = ctx.createMediaStreamSource(lease.stream);
      gain = ctx.createGain(); destination = ctx.createMediaStreamDestination();
      gain.gain.value = inputVolume / 100;
      source.connect(gain); gain.connect(destination); inputGains.add(gain);
      let released = false;
      return { stream: destination.stream, rawStream: lease.rawStream, mode, release: async () => {
        if (released) return;
        released = true; inputGains.delete(gain);
        source.disconnect(); gain.disconnect(); destination.disconnect();
        stopStream(destination.stream);
        await lease.release();
      } };
    } catch (error) {
      try { source?.disconnect(); gain?.disconnect(); destination?.disconnect(); } catch (_) {}
      if (destination) stopStream(destination.stream);
      if (gain) inputGains.delete(gain);
      await lease.release();
      throw error;
    }
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
        publishAudioDevices();
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
    let replacementMixer = null;
    try {
      replacementMixer = createScreenAudioMixer(screenStream, replacementLease.stream);
    } catch (error) {
      await replacementLease.release();
      throw error;
    }
    const replacementTrack = outgoingAudioTrack(replacementLease.stream, replacementMixer);
    const senders = Array.from(peers.values()).filter((pc) => pc._audioSender && pc.signalingState !== 'closed')
      .map((pc) => ({ pc, sender: pc._audioSender, previous: pc._audioSender.track }));
    const results = await Promise.allSettled(senders.map(({ sender }) => sender.replaceTrack(replacementTrack)));
    const failed = results.find((result, i) => result.status === 'rejected' && senders[i].pc.signalingState !== 'closed');
    if (failed || changeEpoch !== microphoneEpoch) {
      // Wait for every swap before rolling back. Otherwise a slow successful swap
      // can leave a peer transmitting a stopped replacement microphone.
      await Promise.allSettled(senders.map(({ pc, sender, previous }) =>
        pc.signalingState !== 'closed' && sender.track === replacementTrack
          ? sender.replaceTrack(changeEpoch === microphoneEpoch ? previous : localStream?.getAudioTracks()[0] || null)
          : Promise.resolve()));
      disposeScreenAudioMixer(replacementMixer);
      await replacementLease.release();
      throw failed?.reason || new Error('microphone_request_cancelled');
    }
    const previousMixer = screenAudioMixer;
    screenAudioMixer = replacementMixer;
    localMicrophoneLease = replacementLease;
    localStream = replacementLease.stream;
    observeMicrophoneTracks(localStream);
    startVoiceDetection(localStream);
    disposeScreenAudioMixer(previousMixer);
    if (previousLease) previousLease.release().catch(() => {});
    else stopStream(previousStream);
    return true;
  };

  const replaceMicrophone = async (deviceId) => {
    const previousId = selectedInputId;
    selectedInputId = String(deviceId || '');
    storage.setItem('plainwire_audio_input', selectedInputId);
    try {
      const changed = await rebuildLocalMicrophone();
      if (changed) send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone changed' });
    } catch (error) {
      selectedInputId = previousId;
      storage.setItem('plainwire_audio_input', selectedInputId);
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
    storage.setItem('plainwire_voice_processing', voiceProcessingMode);
    try {
      const changed = await rebuildLocalMicrophone();
      if (changed) send(app.ports.bridgeReceive, { tag: 'toast', data: nextMode === 'studio' ? 'Studio microphone enabled' : nextMode === 'krisp' ? 'Krisp noise cancellation enabled' : 'Noise cancellation enabled' });
    } catch (error) {
      voiceProcessingMode = previousMode;
      storage.setItem('plainwire_voice_processing', voiceProcessingMode);
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
    ctx.resume().catch(() => {});
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
      // Update the small native meter without dispatching 25 Elm renders/second.
      if (!vad.nextMeterAt || performance.now() >= vad.nextMeterAt) {
        vad.nextMeterAt = performance.now() + 120;
        const meter = document.querySelector('[data-call-mic-meter]');
        const level = micMuted ? 0 : Math.round(Math.max(0, Math.min(100, (db + 60) * 100 / 54)));
        if (meter && meter.getAttribute('aria-valuenow') !== String(level)) {
          meter.setAttribute('aria-valuenow', String(level));
          if (meter.firstElementChild) meter.firstElementChild.style.width = `${level}%`;
        }
      }
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

  // ---- Floating window system (draggable, resizable, remembered) ----
  const floatWindows = new Map(); // id -> { wrapper, video, title, bar }
  let floatZIndex = 900;
  const FLOAT_STATE_KEY = 'plainwire_float_windows_v2';
  const loadFloatStates = () => {
    try {
      const value = JSON.parse(storage.getItem(FLOAT_STATE_KEY) || '{}');
      return value && typeof value === 'object' ? value : {};
    } catch (_) {
      return {};
    }
  };
  const floatPositions = loadFloatStates();
  const isCompactFloatLayout = () => window.matchMedia?.('(max-width: 760px)').matches === true;
  let floatSaveTimer = null;
  const saveFloatStates = () => {
    if (floatSaveTimer) clearTimeout(floatSaveTimer);
    floatSaveTimer = setTimeout(() => {
      floatSaveTimer = null;
      try { storage.setItem(FLOAT_STATE_KEY, JSON.stringify(floatPositions)); } catch (_) {}
    }, 120);
  };
  const clampFloatWindow = (wrapper) => {
    const rect = wrapper.getBoundingClientRect();
    const maxW = Math.max(220, window.innerWidth - 16);
    const maxH = Math.max(160, window.innerHeight - 16);
    if (rect.width > maxW) wrapper.style.width = maxW + 'px';
    if (rect.height > maxH) wrapper.style.height = maxH + 'px';
    const next = wrapper.getBoundingClientRect();
    const x = Math.max(8, Math.min(Math.max(8, window.innerWidth - next.width - 8), next.left));
    const y = Math.max(8, Math.min(Math.max(8, window.innerHeight - next.height - 8), next.top));
    wrapper.style.left = x + 'px';
    wrapper.style.top = y + 'px';
    wrapper.style.right = 'auto';
    wrapper.style.bottom = 'auto';
    return { x, y, w: wrapper.offsetWidth, h: wrapper.offsetHeight };
  };

  const makeFloatWindow = (id, titleText, _accentColor, opts = {}) => {
    const wrapper = document.createElement('div');
    wrapper.id = 'pw-float-' + id;
    wrapper.className = 'pw-float';
    wrapper.style.display = 'flex';
    wrapper.style.zIndex = String(900 + (floatZIndex++ % 100));
    wrapper.setAttribute('role', 'region');
    wrapper.setAttribute('aria-label', titleText);
    const compactAtCreation = isCompactFloatLayout();
    if (!compactAtCreation) {
      wrapper.style.width = id === 'local-preview' ? '340px' : 'min(800px, calc(100vw - 460px))';
      wrapper.style.height = id === 'local-preview' ? '280px' : 'min(520px, calc(100dvh - 110px))';
    }

    const saved = compactAtCreation ? null : floatPositions[id];
    if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) {
      if (Number.isFinite(saved.w)) wrapper.style.width = Math.max(220, saved.w) + 'px';
      if (Number.isFinite(saved.h)) wrapper.style.height = Math.max(160, saved.h) + 'px';
      wrapper.style.left = saved.x + 'px';
      wrapper.style.top = saved.y + 'px';
    } else if (!compactAtCreation && opts.top != null) {
      wrapper.style.left = '24px';
      wrapper.style.top = opts.top + 'px';
    } else if (!compactAtCreation && opts.right != null && opts.bottom != null) {
      wrapper.style.right = opts.right + 'px';
      wrapper.style.bottom = opts.bottom + 'px';
    }

    const bar = document.createElement('div');
    bar.className = 'pw-float-bar';

    const titleWrap = document.createElement('div');
    titleWrap.className = 'pw-float-title-wrap';

    const title = document.createElement('span');
    title.className = 'pw-float-title';
    title.textContent = titleText;

    const state = document.createElement('span');
    state.className = 'pw-float-state';
    state.innerHTML = '<span class="pw-float-state-dot" aria-hidden="true"></span><span>Live</span>';

    titleWrap.appendChild(title);
    titleWrap.appendChild(state);

    const controls = document.createElement('div');
    controls.className = 'pw-float-controls';

    const makeWindowButton = (className, titleText, iconClass) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'pw-float-btn ' + className;
      button.title = titleText;
      button.setAttribute('aria-label', titleText);
      const icon = document.createElement('span');
      icon.className = 'pw-float-window-icon ' + iconClass;
      icon.setAttribute('aria-hidden', 'true');
      button.appendChild(icon);
      return button;
    };

    const btnHide = makeWindowButton('pw-float-hide', 'Hide shared screen', 'hide');
    const btnFit = makeWindowButton('pw-float-fit', 'Center and fit window', 'fit');
    const btnFs = makeWindowButton('pw-float-fs', 'Fullscreen screen share', 'fullscreen');
    const btnClose = makeWindowButton('pw-float-close', opts.closeLabel || 'Stop watching screen', 'close');
    const btnPip = makeWindowButton('pw-float-pip', 'Picture in picture', 'pip');

    controls.appendChild(btnHide);
    controls.appendChild(btnFit);
    controls.appendChild(btnFs);
    if (document.pictureInPictureEnabled) controls.appendChild(btnPip);
    controls.appendChild(btnClose);
    bar.appendChild(titleWrap);
    bar.appendChild(controls);

    const video = document.createElement('video');
    video.autoplay = true;
    video.playsInline = true;
    video.muted = true;
    video.controls = false;

    wrapper.appendChild(bar);
    wrapper.appendChild(video);
    const footer = document.createElement('div'); footer.className = 'screen-viewer-footer';
    const resolution = document.createElement('span'); resolution.textContent = 'Waiting for video';
    const colour = document.createElement('span'); colour.textContent = 'Colour not reported';
    const fitMode = document.createElement('button'); fitMode.type = 'button'; fitMode.textContent = 'Fill view'; fitMode.setAttribute('aria-pressed', 'false');
    fitMode.addEventListener('click', () => {
      const filled = fitMode.getAttribute('aria-pressed') !== 'true';
      fitMode.setAttribute('aria-pressed', String(filled)); fitMode.textContent = filled ? 'Fit view' : 'Fill view';
      video.style.objectFit = filled ? 'cover' : 'contain';
    });
    footer.append(resolution, colour, fitMode); wrapper.append(footer);
    const retry = document.createElement('button'); retry.type = 'button'; retry.className = 'screen-play-retry'; retry.textContent = 'Play screen share'; retry.hidden = true;
    retry.addEventListener('click', () => video.play().catch(() => { retry.hidden = false; })); wrapper.append(retry);
    const updateVideoInfo = () => {
      resolution.textContent = video.videoWidth ? `${video.videoWidth} × ${video.videoHeight}` : 'Waiting for video';
      let frame, transfer = null;
      try { if (video.readyState >= 2 && typeof VideoFrame === 'function') { frame = new VideoFrame(video); transfer = frame.colorSpace?.transfer; } }
      catch (_) {} finally { frame?.close(); }
      const hdr = transfer === 'pq' || transfer === 'hlg';
      colour.textContent = hdr ? `HDR · ${transfer.toUpperCase()}` : ['bt709', 'smpte170m', 'iec61966-2-1'].includes(transfer) ? 'SDR' : 'Colour not reported';
      colour.title = hdr ? 'HDR metadata detected in this video. Display output depends on your browser and screen.' : 'An HDR-capable display alone does not confirm HDR capture or transmission.';
      wrapper.dataset.hdr = String(hdr);
    };
    video.addEventListener('loadeddata', updateVideoInfo); video.addEventListener('resize', updateVideoInfo);
    video.addEventListener('playing', () => { retry.hidden = true; state.lastElementChild.textContent = 'Live'; updateVideoInfo(); });
    video.addEventListener('waiting', () => { state.lastElementChild.textContent = 'Buffering'; });
    const play = () => video.play().catch(() => { retry.hidden = false; });
    document.body.appendChild(wrapper);

    const bringForward = () => {
      for (const window of floatWindows.values()) window.wrapper.style.zIndex = '900';
      wrapper.style.zIndex = '901';
    };
    let fitRestore = null;
    let fitted = false;
    let visualHidden = false;
    wrapper.addEventListener('pointerdown', bringForward);

    btnHide.addEventListener('click', (e) => {
      e.stopPropagation();
      visualHidden = !visualHidden;
      wrapper.classList.toggle('screen-visual-hidden', visualHidden);
      btnHide.classList.toggle('active', visualHidden);
      btnHide.title = visualHidden ? 'Show shared screen' : 'Hide shared screen';
      btnHide.setAttribute('aria-label', btnHide.title);
      btnHide.setAttribute('aria-pressed', String(visualHidden));
      if (visualHidden) {
        if (document.fullscreenElement === wrapper) document.exitFullscreen?.().catch(() => {});
        if (document.pictureInPictureElement === video) document.exitPictureInPicture?.().catch(() => {});
      } else {
        play();
      }
    });

    btnFs.addEventListener('click', (e) => {
      e.stopPropagation();
      if (document.fullscreenElement === wrapper) document.exitFullscreen?.().catch(() => {});
      else if (wrapper.requestFullscreen) wrapper.requestFullscreen().catch(() => {});
      else if (video.webkitRequestFullscreen) video.webkitRequestFullscreen();
    });
    btnPip.addEventListener('click', async () => {
      try { if (document.pictureInPictureElement === video) await document.exitPictureInPicture(); else await video.requestPictureInPicture(); }
      catch (_) { send(app.ports.bridgeReceive, { tag: 'toast', data: 'Picture in picture is not available for this stream.' }); }
    });
    video.addEventListener('dblclick', () => btnFs.click());
    btnClose.addEventListener('click', (e) => {
      e.stopPropagation();
      if (document.fullscreenElement === wrapper) document.exitFullscreen?.().catch(() => {});
      if (document.pictureInPictureElement === video) document.exitPictureInPicture?.().catch(() => {});
      if (opts.onClose) opts.onClose();
      else wrapper.style.display = 'none';
    });

    const fitToScreen = () => {
      if (isCompactFloatLayout()) {
        wrapper.classList.toggle('expanded-view');
        btnFit.setAttribute('aria-pressed', String(wrapper.classList.contains('expanded-view')));
        wrapper.style.removeProperty('left');
        wrapper.style.removeProperty('top');
        wrapper.style.removeProperty('right');
        wrapper.style.removeProperty('bottom');
        wrapper.style.removeProperty('width');
        wrapper.style.removeProperty('height');
        return;
      }

      if (fitted && fitRestore) {
        wrapper.style.width = Math.max(220, fitRestore.w) + 'px';
        wrapper.style.height = Math.max(160, fitRestore.h) + 'px';
        wrapper.style.left = fitRestore.x + 'px';
        wrapper.style.top = fitRestore.y + 'px';
        wrapper.style.right = 'auto';
        wrapper.style.bottom = 'auto';
        fitted = false;
        btnFit.classList.remove('active');
        btnFit.title = 'Center and fit window';
        btnFit.setAttribute('aria-label', 'Center and fit screen share window');
      } else {
        const current = wrapper.getBoundingClientRect();
        fitRestore = { x: current.left, y: current.top, w: current.width, h: current.height };
        const w = Math.min(960, Math.max(300, window.innerWidth - 48));
        const h = Math.min(620, Math.max(220, window.innerHeight - 120));
        wrapper.style.width = w + 'px';
        wrapper.style.height = h + 'px';
        wrapper.style.left = Math.max(8, Math.round((window.innerWidth - w) / 2)) + 'px';
        wrapper.style.top = Math.max(8, Math.round((window.innerHeight - h) / 2)) + 'px';
        wrapper.style.right = 'auto';
        wrapper.style.bottom = 'auto';
        fitted = true;
        btnFit.classList.add('active');
        btnFit.title = 'Restore window size';
        btnFit.setAttribute('aria-label', 'Restore screen share window size');
      }
      floatPositions[id] = clampFloatWindow(wrapper);
      saveFloatStates();
    };
    btnFit.addEventListener('click', (e) => { e.stopPropagation(); fitToScreen(); });
    bar.addEventListener('dblclick', (e) => {
      if (!e.target.closest('.pw-float-btn')) fitToScreen();
    });

    let dragging = false;
    let dragPointer = null;
    let dragOffX = 0;
    let dragOffY = 0;
    bar.addEventListener('pointerdown', (e) => {
      if (isCompactFloatLayout() || e.button !== 0 || e.target.closest('.pw-float-btn')) return;
      fitted = false;
      btnFit.classList.remove('active');
      btnFit.title = 'Center and fit window';
      btnFit.setAttribute('aria-label', 'Center and fit screen share window');
      dragging = true;
      dragPointer = e.pointerId;
      const rect = wrapper.getBoundingClientRect();
      dragOffX = e.clientX - rect.left;
      dragOffY = e.clientY - rect.top;
      wrapper.style.left = rect.left + 'px';
      wrapper.style.top = rect.top + 'px';
      wrapper.style.right = 'auto';
      wrapper.style.bottom = 'auto';
      bar.style.cursor = 'grabbing';
      bar.setPointerCapture?.(e.pointerId);
      e.preventDefault();
    });
    bar.addEventListener('pointermove', (e) => {
      if (!dragging || e.pointerId !== dragPointer) return;
      const nx = Math.max(8, Math.min(window.innerWidth - wrapper.offsetWidth - 8, e.clientX - dragOffX));
      const ny = Math.max(8, Math.min(window.innerHeight - wrapper.offsetHeight - 8, e.clientY - dragOffY));
      wrapper.style.left = nx + 'px';
      wrapper.style.top = ny + 'px';
      floatPositions[id] = { ...floatPositions[id], x: nx, y: ny, w: wrapper.offsetWidth, h: wrapper.offsetHeight };
      saveFloatStates();
    });
    const finishDrag = (e) => {
      if (!dragging || e.pointerId !== dragPointer) return;
      dragging = false;
      dragPointer = null;
      bar.style.cursor = 'grab';
      floatPositions[id] = clampFloatWindow(wrapper);
      saveFloatStates();
    };
    bar.addEventListener('pointerup', finishDrag);
    bar.addEventListener('pointercancel', finishDrag);
    bar.addEventListener('lostpointercapture', finishDrag);

    // CSS resize gives the same resize-anywhere-at-the-corner interaction users
    // expect from desktop chat apps. ResizeObserver persists and clamps the size.
    let resizeObserved = false;
    let resizeObserver = null;
    if ('ResizeObserver' in window) {
      const observer = new ResizeObserver(() => {
        if (wrapper.style.display === 'none' || isCompactFloatLayout() || document.fullscreenElement === wrapper) return;
        const rect = wrapper.getBoundingClientRect();
        const w = Math.min(Math.max(220, rect.width), Math.max(220, window.innerWidth - 16));
        const h = Math.min(Math.max(160, rect.height), Math.max(160, window.innerHeight - 16));
        if (Math.abs(w - rect.width) > 1) wrapper.style.width = w + 'px';
        if (Math.abs(h - rect.height) > 1) wrapper.style.height = h + 'px';
        floatPositions[id] = { ...floatPositions[id], x: rect.left, y: rect.top, w, h };
        saveFloatStates();
      });
      observer.observe(wrapper);
      resizeObserver = observer;
      resizeObserved = true;
    }
    if (!resizeObserved) {
      wrapper.addEventListener('pointerup', () => {
        floatPositions[id] = clampFloatWindow(wrapper);
        saveFloatStates();
      });
    }

    const onViewportResize = () => {
      if (wrapper.style.display === 'none' || document.fullscreenElement === wrapper) return;
      if (isCompactFloatLayout()) {
        wrapper.style.removeProperty('left');
        wrapper.style.removeProperty('top');
        wrapper.style.removeProperty('right');
        wrapper.style.removeProperty('bottom');
        wrapper.style.removeProperty('width');
        wrapper.style.removeProperty('height');
        return;
      }
      floatPositions[id] = clampFloatWindow(wrapper);
      saveFloatStates();
    };
    window.addEventListener('resize', onViewportResize, { passive: true });

    // Resolve right/bottom positioning to pixels after first layout so later
    // dragging and persistence never fight with opposing CSS anchors.
    requestAnimationFrame(() => {
      if (!saved && !isCompactFloatLayout()) {
        const rect = wrapper.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
          wrapper.style.left = rect.left + 'px';
          wrapper.style.top = rect.top + 'px';
          wrapper.style.right = 'auto';
          wrapper.style.bottom = 'auto';
        }
      }
    });

    const dispose = () => { resizeObserver?.disconnect(); window.removeEventListener('resize', onViewportResize); };
    floatWindows.set(id, { wrapper, video, title, bar, dispose, play });
    return { wrapper, video, bar, title, play };
  };

  const ensureFloatWindow = (id, titleText, accentColor, opts) => {
    if (floatWindows.has(id)) return floatWindows.get(id);
    return makeFloatWindow(id, titleText, accentColor, opts);
  };

  // ---- Stage video for screenshare viewers ----
  const showStageVideo = (uid, stream) => {
    const { wrapper, video, play } = ensureFloatWindow('stage-' + uid, (document.querySelector(`[data-peer-id="${uid}"] .call-user-name`)?.textContent || 'Participant') + ' · Screen', 'var(--accent,#5865f2)', {
      top: 80,
      closeLabel: 'Stop watching screen',
      onClose: () => { watchedScreens.delete(uid); wrapper.style.display = 'none'; video.srcObject = null; }
    });
    if (stream) {
      video.srcObject = stream;
      play();
    }
    wrapper.style.display = 'flex';
  };

  const hideStageVideo = (uid) => {
    const w = floatWindows.get('stage-' + uid);
    if (w) {
      if (document.fullscreenElement === w.wrapper) document.exitFullscreen?.().catch(() => {});
      if (document.pictureInPictureElement === w.video) document.exitPictureInPicture?.().catch(() => {});
      w.wrapper.style.display = 'none'; w.video.srcObject = null;
    }
  };

  const removeStageVideo = (uid) => {
    const w = floatWindows.get('stage-' + uid);
    if (w) {
      if (w.video.srcObject) { w.video.srcObject.getTracks().forEach((t) => t.stop()); w.video.srcObject = null; }
      w.dispose?.();
      w.wrapper.remove();
      floatWindows.delete('stage-' + uid);
    }
    screenSharers.delete(uid);
    watchedScreens.delete(uid);
  };

  // ---- Local screen share preview ----
  const showLocalScreenPreview = (stream) => {
    const { wrapper, video, play } = ensureFloatWindow('local-preview', 'Your screen', 'var(--ok,#23a55a)', {
      top: 80,
      closeLabel: 'Stop sharing screen',
      onClose: () => { stopScreenShare(); }
    });
    video.srcObject = stream;
    play();
    wrapper.style.display = 'flex';
  };

  const removeLocalScreenPreview = () => {
    const w = floatWindows.get('local-preview');
    if (w) {
      if (w.video.srcObject) { w.video.srcObject.getTracks().forEach((t) => t.stop()); w.video.srcObject = null; }
      w.dispose?.();
      w.wrapper.remove();
      floatWindows.delete('local-preview');
    }
  };

  // ---- Screen sharing ----
  const screenProfiles = {
    balanced: { label: 'Balanced', width: 1600, height: 900, fps: 30, bitrate: 2500000, hint: 'detail' },
    text: { label: 'Text & detail', width: 1920, height: 1080, fps: 30, bitrate: 3500000, hint: 'text' },
    motion: { label: 'Smooth motion', width: 1920, height: 1080, fps: 60, bitrate: 4500000, hint: 'motion' }
  };
  let screenProfile = storage.getItem('plainwire_screen_profile') || 'balanced';
  let shareScreenAudio = storage.getItem('plainwire_screen_audio') !== 'false';
  if (!Object.hasOwn(screenProfiles, screenProfile)) screenProfile = 'balanced';
  const screenConstraints = () => {
    const p = screenProfiles[screenProfile];
    return { width: { ideal: p.width, max: p.width }, height: { ideal: p.height, max: p.height }, frameRate: { ideal: p.fps, max: p.fps } };
  };
  class ScreenSettings extends HTMLElement {
    connectedCallback() { this.render(); }
    render() {
      if (this.childElementCount) {
        const active = !!screenStream;
        const change = this.querySelector('[data-screen-change]');
        const preview = this.querySelector('[data-screen-preview]');
        const status = this.querySelector('[data-screen-audio-status]');
        if (change) change.disabled = !active;
        if (preview) preview.disabled = !active;
        if (status) {
          const hasAudio = active && screenStream.getAudioTracks().some((track) => track.readyState === 'live');
          status.textContent = active
            ? hasAudio
              ? 'Shared audio is included with your microphone.'
              : 'This source has no shared audio. In the browser chooser, select a tab or screen and enable audio when offered.'
            : 'When available, tab or system audio is mixed with your microphone without changing the call connection.';
          status.classList.toggle('active', hasAudio);
        }
        return;
      }
      const details = document.createElement('details');
      const summary = document.createElement('summary'); summary.textContent = 'Screen sharing';
      const label = document.createElement('label'); label.textContent = 'Share quality';
      const select = document.createElement('select'); select.setAttribute('aria-label', 'Screen sharing quality');
      for (const [value, profile] of Object.entries(screenProfiles)) {
        const option = document.createElement('option'); option.value = value; option.textContent = `${profile.label} · up to ${profile.height}p / ${profile.fps} fps`; select.append(option);
      }
      select.value = screenProfile;
      select.addEventListener('change', async () => {
        screenProfile = select.value; storage.setItem('plainwire_screen_profile', screenProfile);
        for (const control of document.querySelectorAll('pw-screen-settings select')) control.value = screenProfile;
        if (screenStream) {
          const track = screenStream.getVideoTracks()[0];
          try { track.contentHint = screenProfiles[screenProfile].hint; await track.applyConstraints(screenConstraints()); }
          catch (_) { send(app.ports.bridgeReceive, { tag: 'toast', data: 'The browser kept its available capture resolution.' }); }
          await Promise.allSettled(Array.from(peers.values(), pc => applyEncoderTier(pc._videoSender, peers.size + 1)));
        }
      });
      label.append(select);
      const audioLabel = document.createElement('label'); audioLabel.className = 'screen-audio-option';
      const audioToggle = document.createElement('input'); audioToggle.type = 'checkbox'; audioToggle.checked = shareScreenAudio;
      audioToggle.setAttribute('aria-label', 'Request audio when sharing a screen');
      const audioCopy = document.createElement('span');
      const audioHeading = document.createElement('b'); audioHeading.textContent = 'Include shared audio';
      const audioDescription = document.createElement('small'); audioDescription.textContent = 'Requests tab or system audio when the browser and chosen source support it.';
      audioCopy.append(audioHeading, audioDescription);
      audioToggle.addEventListener('change', () => {
        shareScreenAudio = audioToggle.checked;
        storage.setItem('plainwire_screen_audio', String(shareScreenAudio));
        for (const control of document.querySelectorAll('pw-screen-settings .screen-audio-option input')) control.checked = shareScreenAudio;
      });
      audioLabel.append(audioToggle, audioCopy);
      const note = document.createElement('p');
      note.textContent = 'Text & detail keeps writing sharp. Smooth motion prefers frame rate. Group calls use lower limits to protect your upload.';
      const audioStatus = document.createElement('p'); audioStatus.dataset.screenAudioStatus = 'true'; audioStatus.className = 'screen-audio-status';
      audioStatus.setAttribute('role', 'status'); audioStatus.setAttribute('aria-live', 'polite');
      const hdr = document.createElement('p');
      hdr.textContent = window.matchMedia?.('(dynamic-range: high)').matches ? 'HDR display detected. Capture and stream colour depend on your browser; the viewer reports detected video colour.' : 'Colour is managed by your browser. The viewer reports HDR only when detected in the video.';
      const actions = document.createElement('div'); actions.className = 'screen-settings-actions';
      const change = document.createElement('button'); change.type = 'button'; change.className = 'btn secondary'; change.textContent = 'Change shared screen'; change.dataset.screenChange = 'true'; change.disabled = !screenStream;
      change.addEventListener('click', () => startScreenShare(true));
      const preview = document.createElement('button'); preview.type = 'button'; preview.className = 'btn ghost'; preview.textContent = 'Show my preview'; preview.dataset.screenPreview = 'true'; preview.disabled = !screenStream;
      preview.addEventListener('click', () => { if (screenStream) showLocalScreenPreview(screenStream); });
      actions.append(change, preview);
      details.append(summary, label, audioLabel, audioStatus, note, hdr, actions); this.append(details);
      this.render();
    }
  }
  customElements.define('pw-screen-settings', ScreenSettings);
  const updateScreenControls = () => document.querySelectorAll('pw-screen-settings').forEach(control => control.render());

  const applyEncoderTier = async (sender, participantCount) => {
    if (!sender?.track) return;
    const profile = screenProfiles[screenProfile];
    const load = Math.max(0, Math.min(participantCount - 2, 2));
    const tier = { maxBitrate: Math.round(profile.bitrate * [1, .6, .3][load]), maxFramerate: Math.min(profile.fps, [60, 30, 20][load]), scaleResolutionDownBy: [1, 1.5, 2][load] };
    try {
      // getParameters is synchronous; treating it as a Promise used to abort
      // screen sharing at the first participant.
      const params = sender.getParameters();
      if (!params.encodings?.length) return;
      Object.assign(params.encodings[0], tier);
      if (sender._qualityLimited) {
        params.encodings[0].maxBitrate = Math.min(params.encodings[0].maxBitrate, 750000);
        params.encodings[0].maxFramerate = Math.min(params.encodings[0].maxFramerate, 15);
      }
      await sender.setParameters(params);
    } catch (error) {
      debug('MEDIA', 'encoder_tier_skipped', { error: error.message }, 'warn');
    }
  };

  let screenCapturePending = false;
  const startScreenShare = async (replace = false) => {
    if (screenCapturePending) return;
    screenCapturePending = true;
    try { await performScreenShare(replace); }
    finally { screenCapturePending = false; }
  };
  const performScreenShare = async (replace) => {
    if (screenStream && !replace) return;
    if (!displayMediaSupported) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen sharing is unavailable in this browser.' });
      return;
    }
    if (!room) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Join a call or voice channel to share your screen.' });
      return;
    }
    const epoch = room.epoch;
    const previous = screenStream;
    let captured;
    try {
      captured = await navigator.mediaDevices.getDisplayMedia({
        video: screenConstraints(),
        audio: shareScreenAudio,
        systemAudio: shareScreenAudio ? 'include' : 'exclude',
        windowAudio: shareScreenAudio ? 'system' : 'exclude',
        selfBrowserSurface: 'exclude',
        surfaceSwitching: 'include'
      });
    } catch (error) {
      debug('MEDIA', 'display_media_failed', { name: error.name, error: error.message }, 'warn');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen sharing was cancelled or is unavailable.' });
      return;
    }
    // The user can leave while the browser's screen chooser is open.
    if (!room || room.epoch !== epoch || screenStream !== previous) { stopStream(captured); return; }
    const videoTrack = captured.getVideoTracks()[0];
    if (!videoTrack) { stopStream(captured); return; }
    const previousMixer = screenAudioMixer;
    let capturedMixer = null;
    try {
      capturedMixer = createScreenAudioMixer(captured);
    } catch (error) {
      captured.getAudioTracks().forEach((track) => track.stop());
      debug('MEDIA', 'screen_audio_mix_failed', { error: error.message }, 'warn');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'The screen is sharing, but its audio could not be mixed.' });
    }
    const previousAudioTrack = outgoingAudioTrack(localStream, previousMixer);
    const capturedAudioTrack = outgoingAudioTrack(localStream, capturedMixer);
    screenStream = captured;
    screenAudioMixer = capturedMixer;
    videoTrack.contentHint = screenProfiles[screenProfile].hint;
    videoTrack.onended = () => { if (screenStream === captured) stopScreenShare(); };
    const targets = Array.from(peers.entries()).filter(([, pc]) => pc._videoSender && pc.signalingState !== 'closed');
    const results = await Promise.allSettled(targets.map(async ([uid, pc]) => {
      await Promise.all([
        pc._videoSender.replaceTrack(videoTrack),
        pc._audioSender && capturedAudioTrack !== previousAudioTrack
          ? pc._audioSender.replaceTrack(capturedAudioTrack)
          : Promise.resolve()
      ]);
      await applyEncoderTier(pc._videoSender, peers.size + 1);
      if (room?.epoch === epoch && screenStream === captured) screenSenders.set(uid, pc._videoSender);
    }));
    if (!room || room.epoch !== epoch || screenStream !== captured) {
      disposeScreenAudioMixer(capturedMixer);
      stopStream(captured);
      disposeScreenAudioMixer(previousMixer);
      if (previous) stopStream(previous);
      return;
    }
    if (results.some((result, i) => result.status === 'rejected' && targets[i][1].signalingState !== 'closed')) {
      screenStream = previous;
      screenAudioMixer = previousMixer;
      await Promise.allSettled(targets.map(([, pc]) => Promise.all([
        pc._videoSender.replaceTrack(previous?.getVideoTracks()[0] || null),
        pc._audioSender ? pc._audioSender.replaceTrack(previousAudioTrack) : Promise.resolve()
      ])));
      disposeScreenAudioMixer(capturedMixer);
      stopStream(captured);
      screenSenders.clear();
      if (previous) targets.forEach(([uid, pc]) => screenSenders.set(uid, pc._videoSender));
      send(app.ports.bridgeReceive, { tag: 'toast', data: previous ? 'Could not switch screens. Your previous share is unchanged.' : 'Could not start sharing. Please try again.' });
      return;
    }
    disposeScreenAudioMixer(previousMixer);
    if (previous) stopStream(previous);
    const hasScreenAudio = !!capturedMixer;
    sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen: true, screen_audio: hasScreenAudio } });
    send(app.ports.bridgeReceive, { tag: 'screen_share_started', user_id: meId });
    showLocalScreenPreview(captured);
    updateScreenControls();
    debug('MEDIA', 'screen_share_started', { tracks: captured.getTracks().length, shared_audio: hasScreenAudio });
  };

  const stopScreenShare = () => {
    if (!screenStream) return;
    const stoppedStream = screenStream;
    const stoppedMixer = screenAudioMixer;
    screenStream = null;
    screenAudioMixer = null;
    disposeScreenAudioMixer(stoppedMixer);
    stoppedStream.getTracks().forEach((t) => t.stop());
    updateScreenControls();
    // Restore camera video on all peer senders
    const cameraTrack = localStream && localStream.getVideoTracks()[0];
    peers.forEach((pc, peerUid) => {
      if (pc._videoSender) {
        pc._videoSender.replaceTrack(cameraTrack || null).catch(() => {});
      }
      if (pc._audioSender) {
        pc._audioSender.replaceTrack(outgoingAudioTrack()).catch(() => {});
      }
    });
    screenSenders.clear();
    removeLocalScreenPreview();
    // Clear screen flag on server
    if (room && ws?.readyState === WebSocket.OPEN) {
      sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen: false, screen_audio: false } });
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
      el.volume = readVolume(peerVolumeKey(uid), 100) / 100;
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
    // Keep the dedupe flag in step with what Elm was told. Otherwise a peer that
    // recovers after a restart is never reported as connected again.
    if (pc) pc._reportedConnected = !!connected;
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
      if (pc._remoteMuteTimer) clearTimeout(pc._remoteMuteTimer);
      if (pc._mediaTimer) clearTimeout(pc._mediaTimer);
      pc.close();
    }
    peers.delete(uid);
    debug('RTC', 'peer_closed', { peer_user_id: uid, remaining_peers: peers.size });
    removeStageVideo(uid);
    document.getElementById('remote-audio-' + uid)?.remove();
    reportPeerConnection(uid, pc, false);
  };

  // A participant's session was replaced or ended. Queued signals and pending
  // peer creation from the old session become stale.
  const replacePeerSession = (uid) => {
    peerGenerations.set(uid, (peerGenerations.get(uid) || 0) + 1);
    closePeer(uid);
  };

  const cleanupAllFloatWindows = () => {
    floatWindows.forEach((w, id) => {
      if (w.video.srcObject) { w.video.srcObject.getTracks().forEach((t) => t.stop()); w.video.srcObject = null; }
      w.dispose?.();
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
    callHealth?.stop();
    clearInterval(rtcRefreshTimer); rtcRefreshTimer = null;
    watchedScreens.clear();
    peers.forEach((_, uid) => closePeer(uid));
    peerPromises.clear();
    signalQueues.clear();
    if (screenStream) {
      screenStream.getTracks().forEach((t) => t.stop());
      screenStream = null;
    }
    disposeScreenAudioMixer(screenAudioMixer);
    screenAudioMixer = null;
    screenSenders.clear();
    cleanupAllFloatWindows();
    screenSharers.clear();
    room = null;
    resumeInFlight = false;
    releaseCurrentMicrophone();
    // Leaving a room resets mute and deafen (resume stored its intent above).
    // Choices made before joining anything carry into the join. Elm is told either
    // way so its buttons can never disagree with the real audio state.
    if (previous) {
      micMuted = false;
      deafened = false;
      mutedBeforeDeafen = false;
    }
    publishAudioState();
    stopRingtones();
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
    mutedBeforeDeafen = intent.mutedBeforeDeafen;
    const epoch = ++roomEpoch;
    room = { kind: intent.kind, id: intent.id, joined: false, epoch };
    send(app.ports.bridgeReceive, {
      tag: 'rtc_resuming', room_kind: intent.kind, room_id: intent.id,
      muted: micMuted, deafened, muted_before_deafen: mutedBeforeDeafen
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

  const markNegotiated = (pc) => {
    pc._negotiated = true;
    pc._lastNegotiationAt = Date.now();
    pc._turnValidUntil = rtcHasTurn() ? rtcConfigValidUntil : 0;
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

  const restartPeerIce = (uid, pc, reason = 'network', { force = false } = {}) => {
    if (!pc || pc.signalingState === 'closed' || (pc.connectionState === 'connected' && !force)) return;
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
      peer_user_id: uid, reason, attempt: pc._reconnectAttempts, force,
      offerer: pc._offerer, signaling: pc.signalingState
    });
    pc._restartTimer = setTimeout(async () => {
      pc._restartTimer = null;
      if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed' || (pc.connectionState === 'connected' && !force)) return;
      try {
        await loadRtcConfig();
        if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed') return;
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
    const generation = peerGenerations.get(uid) || 0;
    const pendingKey = `${epoch}:${uid}:${generation}`;
    const pending = peerPromises.get(pendingKey);
    if (pending) return pending;
    const creation = createPeer(uid, epoch, generation);
    peerPromises.set(pendingKey, creation);
    try {
      return await creation;
    } finally {
      peerPromises.delete(pendingKey);
    }
  };

  const bindPeerMedia = async (pc, stream) => {
    const active = pc.getTransceivers().filter((t) => !t.stopped);
    const audio = active.find((t) => t.receiver.track.kind === 'audio');
    const video = active.find((t) => t.receiver.track.kind === 'video');
    const track = outgoingAudioTrack(stream);
    if (!audio || !track) throw new Error('No negotiated microphone channel');
    stream?.getAudioTracks().forEach((microphoneTrack) => { microphoneTrack.enabled = !micMuted; });
    audio.direction = 'sendrecv';
    await audio.sender.replaceTrack(track);
    audio.sender.setStreams?.(stream);
    pc._audioSender = audio.sender;
    try {
      const codecs = RTCRtpReceiver.getCapabilities?.('audio')?.codecs || [];
      const opus = codecs.filter((codec) => /audio\/opus/i.test(codec.mimeType || ''));
      const rest = codecs.filter((codec) => !/audio\/opus/i.test(codec.mimeType || ''));
      if (opus.length) audio.setCodecPreferences?.([...opus, ...rest]);
    } catch (error) {
      debug('RTC', 'codec_preference_skipped', { error: error.message }, 'warn');
    }
    if (video) {
      video.direction = 'sendrecv';
      await video.sender.replaceTrack(screenStream?.getVideoTracks()[0] || stream.getVideoTracks()[0] || null);
      pc._videoSender = video.sender;
      if (screenStream) await applyEncoderTier(video.sender, peers.size + 1);
    }
  };

  const createPeer = async (uid, epoch, generation) => {
    const stale = () => !room || room.epoch !== epoch || (peerGenerations.get(uid) || 0) !== generation;
    await loadRtcConfig();
    if (stale()) return null;
    const stream = await ensureMedia();
    if (stale()) return null;
    if (peers.has(uid)) return peers.get(uid);
    const offerer = Number(meId) > Number(uid);
    const polite = !offerer;
    const peerConfig = {
      ...rtcConfig,
      bundlePolicy: rtcConfig.bundlePolicy || 'max-bundle',
      rtcpMuxPolicy: 'require',
      iceCandidatePoolSize: Number.isFinite(rtcConfig.iceCandidatePoolSize) ? rtcConfig.iceCandidatePoolSize : 4
    };
    const pc = new RTCPeerConnection(peerConfig);
    debug('RTC', 'peer_created', { peer_user_id: uid, offerer, polite, room, ice_server_count: peerConfig.iceServers?.length || 0 });
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
    pc._mediaConnected = false;
    pc._remoteAudioSeen = false;
    pc._createdAt = Date.now();
    pc._lastNegotiationAt = 0;
    pc._turnValidUntil = rtcHasTurn() ? rtcConfigValidUntil : 0;
    // Only the offerer creates m-lines. An answerer must bind its microphone to
    // the offered transceiver; pre-created addTransceiver senders stay unassociated.
    if (offerer) {
      pc.addTransceiver('audio', { direction: 'sendrecv' });
      pc.addTransceiver('video', { direction: 'sendrecv' });
      await bindPeerMedia(pc, stream);
      if (stale()) { pc.close(); return null; }
    }
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
        pc._remoteAudioSeen = true;
        const audio = remoteAudio(uid);
        const markMediaConnected = () => {
          const healthy = ev.track.readyState === 'live' && ev.track.muted !== true;
          pc._mediaConnected = healthy;
          if (healthy) {
            if (pc._remoteMuteTimer) clearTimeout(pc._remoteMuteTimer);
            if (pc._mediaTimer) clearTimeout(pc._mediaTimer);
            pc._remoteMuteTimer = null;
            pc._mediaTimer = null;
            pc._publishConnectionState?.();
            playRemoteAudio(audio);
          }
        };
        const scheduleMutedRecovery = () => {
          pc._mediaConnected = false;
          pc._publishConnectionState?.();
          if (pc._remoteMuteTimer) clearTimeout(pc._remoteMuteTimer);
          pc._remoteMuteTimer = setTimeout(() => {
            pc._remoteMuteTimer = null;
            if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed') return;
            if (ev.track.readyState === 'live' && ev.track.muted === true && transportConnected()) {
              debug('RTC', 'remote_audio_stalled', { peer_user_id: uid }, 'warn');
              restartPeerIce(uid, pc, 'remote_audio_stalled', { force: true });
            }
          }, 7000);
        };
        ev.track.addEventListener?.('unmute', markMediaConnected);
        ev.track.addEventListener?.('mute', scheduleMutedRecovery);
        ev.track.addEventListener?.('ended', () => {
          pc._mediaConnected = false;
          pc._publishConnectionState?.(true);
          restartPeerIce(uid, pc, 'remote_audio_ended', { force: true });
        });
        audio.srcObject = new MediaStream([ev.track]);
        audio.muted = deafened;
        ['loadedmetadata', 'canplay', 'playing'].forEach((eventName) => {
          audio.addEventListener(eventName, () => {
            markMediaConnected();
            if (!deafened) playRemoteAudio(audio);
          }, { passive: true });
        });
        if (ev.track.muted) scheduleMutedRecovery();
        else markMediaConnected();
        playRemoteAudio(audio);
        applySpeaker();
      } else if (ev.track.kind === 'video') {
        // Store stream for later  -  stage video only shown for screen sharers
        if (!pc._videoStreams) pc._videoStreams = new Map();
        const stream = new MediaStream([ev.track]);
        pc._videoStreams.set(ev.track.id, stream);
        if (screenSharers.has(uid) && watchedScreens.has(uid)) {
          showStageVideo(uid, stream);
        }
      }
    };
    const transportConnected = () => pc.connectionState === 'connected' || pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed';
    const publishConnectionState = (force = false) => {
      // A WebRTC transport can be connected while the remote audio path is dead.
      // Only expose a healthy call once a live remote audio track has actually arrived.
      const connected = transportConnected() && pc._mediaConnected === true;
      if (!force && pc._reportedConnected === connected) return;
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
        if (!pc._announcedConnected) {
          pc._announcedConnected = true;
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call audio connected' });
        }
      }
    };
    pc._publishConnectionState = publishConnectionState;
    const armMediaWatchdog = () => {
      if (pc._mediaConnected === true || pc._mediaTimer || pc.signalingState === 'closed') return;
      pc._mediaTimer = setTimeout(() => {
        pc._mediaTimer = null;
        if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed' || pc._mediaConnected === true) return;
        if (!transportConnected()) {
          // No transport yet: that is the connection check's job, not a media fault.
          armMediaWatchdog();
          return;
        }
        debug('RTC', 'remote_audio_missing', {
          peer_user_id: uid,
          remote_audio_seen: pc._remoteAudioSeen === true,
          connection: pc.connectionState,
          ice: pc.iceConnectionState
        }, 'warn');
        restartPeerIce(uid, pc, 'remote_audio_missing', { force: true });
        if ((pc._reconnectAttempts || 0) < RTC_MAX_RECOVERY_ATTEMPTS) armMediaWatchdog();
      }, 10000);
    };
    // Media gets a full watchdog period after the transport (re)connects.
    const rearmMediaWatchdog = () => {
      if (pc._mediaTimer) clearTimeout(pc._mediaTimer);
      pc._mediaTimer = null;
      armMediaWatchdog();
    };
    pc.onconnectionstatechange = () => {
      debug('RTC', 'connection_state', { peer_user_id: uid, state: pc.connectionState });
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') pc._mediaConnected = false;
      publishConnectionState();
      if (pc.connectionState === 'connected' && pc._mediaConnected !== true) rearmMediaWatchdog();
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
      if ((pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') && pc._mediaConnected !== true) rearmMediaWatchdog();
      if (pc.iceConnectionState === 'failed') restartPeerIce(uid, pc, 'ice_failed');
    };
    pc.onicegatheringstatechange = () => debug('RTC', 'ice_gathering_state', { peer_user_id: uid, state: pc.iceGatheringState });
    pc.onsignalingstatechange = () => debug('RTC', 'signaling_state', { peer_user_id: uid, state: pc.signalingState });
    peers.set(uid, pc);
    reportPeerFailure(uid, pc, false);
    publishConnectionState(true);
    const checkConnection = () => {
      pc._connectTimer = setTimeout(() => {
        pc._connectTimer = null;
        if (pc.connectionState === 'closed' || pc._mediaConnected === true) return;
        const signalingDone = !!pc.remoteDescription && pc.signalingState === 'stable';
        const sinceNegotiation = Date.now() - (pc._lastNegotiationAt || pc._createdAt);
        const stillChecking = ['new', 'checking'].includes(pc.iceConnectionState) && sinceNegotiation < RTC_ICE_CHECKING_GRACE_MS;
        debug('RTC', 'check_connection', {
          peer_user_id: uid,
          connection: pc.connectionState,
          signaling: pc.signalingState,
          ice: pc.iceConnectionState,
          since_negotiation_ms: sinceNegotiation,
          reconnect_attempts: pc._reconnectAttempts,
          offerer: pc._offerer
        });
        if ((pc._reconnectAttempts || 0) >= RTC_MAX_RECOVERY_ATTEMPTS) {
          markPeerFailed(uid, pc);
          return;
        }
        if (transportConnected()) {
          // Transport is up but audio is not: the media watchdog owns that case.
        } else if (!signalingDone) {
          // Lost offer or answer: resend the pending offer or ask for a new one.
          restartPeerIce(uid, pc, 'signaling_timeout');
        } else if (!stillChecking) {
          // ICE failures also restart from the state handlers; this covers a
          // check that neither connects nor reports failure.
          restartPeerIce(uid, pc, 'connection_timeout');
        }
        checkConnection();
      }, RTC_CONNECT_CHECK_MS);
    };
    checkConnection();
    armMediaWatchdog();
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

  const existingPeer = async (uid) => {
    const epoch = room?.epoch;
    const pc = peers.get(uid);
    if (pc && pc._roomEpoch === epoch) return pc;
    return (await peerPromises.get(`${epoch}:${uid}:${peerGenerations.get(uid) || 0}`)) || null;
  };

  const applySignal = async (msg, generation) => {
    const uid = Number(msg.from_user_id || msg.user_id || 0);
    const signal = msg.signal || {};
    debug('RTC', 'signal_received', { peer_user_id: uid, kind: signal.kind, message_type: msg.type });
    if (!uid || uid === meId || !room || !eventMatchesRoom(msg) || (peerGenerations.get(uid) || 0) !== generation) {
      debug('RTC', 'stale_signal_ignored', { peer_user_id: uid, event_room: rtcEventRoom(msg), room });
      return;
    }
    // Only an offer, or a request for one, may start a connection. A late
    // candidate or answer from someone who already left must not create a
    // zombie peer that retries and then reports failure.
    const pc = signal.kind === 'offer' || signal.kind === 'renegotiate' ? await ensurePeer(uid) : await existingPeer(uid);
    if (!pc) return;
    try {
      if (signal.kind === 'renegotiate') {
        if (pc._offerer) {
          // Answer at once if we gave up or never finished an offer. Otherwise keep
          // the normal spacing: both sides run check timers, and back-to-back ICE
          // restarts never leave enough time for a slow path to connect.
          if (pc._failureReported) pc._reconnectAttempts = 0;
          if (pc._failureReported || !pc.remoteDescription) pc._lastRecoveryAt = 0;
          restartPeerIce(uid, pc, 'peer_requested', { force: true });
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
        await bindPeerMedia(pc, await ensureMedia());
        if (!room || room.epoch !== pc._roomEpoch || pc.signalingState === 'closed') return;
        await drainPendingCandidates(uid, pc);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        markNegotiated(pc);
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
          markNegotiated(pc);
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
    const generation = peerGenerations.get(uid) || 0;
    const previous = signalQueues.get(key) || Promise.resolve();
    const queued = previous.catch(() => {}).then(() => applySignal(msg, generation));
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
    callHealth?.start();
    startRtcRefresh();
    resumeInFlight = false;
    persistRtcIntent();
    const epoch = room.epoch;
    debug('RTC', 'room_joined', { kind, id, participant_count: users.length });
    await ensureMedia();
    if (!room || room.epoch !== epoch) return;
    if (!room.stateSynced) {
      // The server forgets seat state across a fresh join or reconnect and drops
      // changes made while ringing. Tell it what this client is actually doing.
      room.stateSynced = true;
      sendWs({ type: kind === 'voice' ? 'voice_state' : 'call_state', patch: { muted: micMuted, deafened, screen: !!screenStream } });
    }
    const userId = (u) => Number(u.user_id || u.userId || u.profile?.id || 0);
    const roster = new Set(users.map(userId).filter((uid) => uid && uid !== meId));
    // A reconnecting participant has no socket, so offers to them are dropped.
    // Their rejoin announces a fresh session and the connection starts then.
    const ids = users.filter((u) => !u.reconnecting).map(userId).filter((uid) => uid && uid !== meId);
    Array.from(peers.keys()).forEach((uid) => { if (!roster.has(uid)) closePeer(uid); });
    ids.forEach((uid) => {
      const shouldOffer = meId > uid;
      ensurePeer(uid).then((pc) => {
        if (shouldOffer && pc && !pc._negotiated) callPeer(uid).catch(() => {});
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
      if (screenSharers.has(uid) || !watchedScreens.has(uid)) return;
      const streams = peers.get(uid)?._videoStreams;
      const stream = streams && Array.from(streams.values()).pop();
      if (stream) showStageVideo(uid, stream);
    });
    screenSharers.forEach((uid) => { if (!next.has(uid)) { hideStageVideo(uid); watchedScreens.delete(uid); } });
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
    if (msg.type === 'call_quality_result') { callHealth?.receive(msg); return; }
    if (msg.type === 'realtime_resync') {
      api({ method: 'GET', path: '/sync?since=0' });
      const route = location.hash.match(/^#(dm|channel)\/(\d+)$/);
      if (route) api({ method: 'GET', path: `/messages?scope=${route[1] === 'dm' ? 'direct' : 'channel'}&scope_id=${route[2]}` });
      return;
    }
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
      if (peerUid && peerUid !== meId) {
        // A join is always a fresh session on their side (new tab, reload or new
        // socket). Pairing it with our old connection's ICE/DTLS state never connects.
        replacePeerSession(peerUid);
        const shouldOffer = meId > peerUid;
        ensurePeer(peerUid).then((pc) => {
          if (shouldOffer && pc) callPeer(peerUid).catch(() => {});
          pc?._publishConnectionState?.(true);
        }).catch(() => {});
      }
    }
    if ((msg.type === 'call_peer_left' || msg.type === 'voice_peer_left') && eventMatchesRoom(msg)) {
      const leftUid = Number(msg.user_id);
      screenSharers.delete(leftUid);
      replacePeerSession(leftUid);
    }
    if ((msg.type === 'voice_signal' || msg.type === 'call_signal') && eventMatchesRoom(msg)) handleSignal(msg).catch(() => {});
    if (['call_declined', 'call_cancelled', 'call_missed', 'call_ended'].includes(msg.type) && eventMatchesRoom(msg)) leaveRtcRoom();
    if (msg.type === 'call_accepted') stopRingtones();
    if (msg.type === 'error' && msg.error === 'no_active_call' && room?.kind === 'call') {
      debug('RTC', 'call_accept_rejected', { conversation_id: room.id }, 'warn');
      leaveRtcRoom();
      stopRingtones();
      send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: 'call' });
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'That call is no longer available.' });
      return;
    }
    if (msg.type === 'error' && resumeInFlight && !['rate_limited', 'too_many_subscriptions'].includes(msg.error)) {
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

  const publishAudioState = () => {
    send(app.ports.bridgeReceive, { tag: 'rtc_audio_state', muted: micMuted, deafened });
  };

  const setMuted = (muted) => {
    micMuted = !!muted;
    if (localStream) localStream.getAudioTracks().forEach((t) => { t.enabled = !micMuted; });
    if (!deafened) mutedBeforeDeafen = micMuted;
    persistRtcIntent();
    publishAudioState();
    debug('MEDIA', 'microphone_muted_changed', { muted: micMuted, tracks: localStream?.getAudioTracks().length || 0 });
  };

  const setDeafened = (value) => {
    const next = !!value;
    if (next === deafened) return publishAudioState();
    deafened = next;
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((el) => { el.muted = deafened; });
    if (deafened) {
      mutedBeforeDeafen = micMuted;
      setMuted(true);
    } else {
      // Restore the microphone as it was. Staying silently muted after undeafening
      // looks like the other side can no longer hear you.
      setMuted(mutedBeforeDeafen);
      if (room) playAllRemoteAudio();
    }
    persistRtcIntent();
    debug('MEDIA', 'deafened_changed', { deafened, muted: micMuted, muted_before_deafen: mutedBeforeDeafen });
  };

  const enableDrag = () => {
    const key = 'plainwire_call_window_v2';
    let saved = null;
    try {
      const parsed = JSON.parse(storage.getItem(key) || 'null');
      if (parsed && Number.isFinite(parsed.x) && Number.isFinite(parsed.y)) saved = parsed;
    } catch (_) {}

    let drag = null;
    let suppressClick = false;
    let raf = 0;
    const desktop = () => window.matchMedia?.('(min-width: 761px)').matches === true;
    const sizeKey = 'plainwire_call_size_v1';
    let preferredSize = null, resizing = null;
    try {
      const value = JSON.parse(storage.getItem(sizeKey) || 'null');
      if (Number.isFinite(value?.w) && Number.isFinite(value?.h)) preferredSize = value;
    } catch (_) {}

    const layer = () => document.querySelector('.call-layer');
    const clamp = (node, x, y) => {
      const rect = node.getBoundingClientRect();
      const margin = 10;
      const maxX = Math.max(margin, window.innerWidth - rect.width - margin);
      const maxY = Math.max(margin, window.innerHeight - rect.height - margin);
      return {
        x: Math.max(margin, Math.min(maxX, x)),
        y: Math.max(margin, Math.min(maxY, y))
      };
    };

    const setLayerPosition = (node, pos, persist = false) => {
      if (!node || !desktop() || !pos) return;
      const next = clamp(node, pos.x, pos.y);
      node.style.left = next.x + 'px';
      node.style.top = next.y + 'px';
      node.style.right = 'auto';
      node.style.bottom = 'auto';
      node.classList.add('detached');
      saved = next;
      if (persist) {
        try { storage.setItem(key, JSON.stringify(next)); } catch (_) {}
      }
    };

    const resetLayerPosition = (node, persist = true) => {
      if (!node) return;
      node.style.removeProperty('left');
      node.style.removeProperty('top');
      node.style.removeProperty('right');
      node.style.removeProperty('bottom');
      node.style.removeProperty('transform');
      node.classList.remove('detached', 'dragging');
      saved = null;
      if (persist) {
        try { storage.removeItem(key); } catch (_) {}
      }
    };

    // Elm reuses the same element when the expanded panel is minimized into the
    // compact bar, so a size written here would stick to the small bar. Track the
    // element that carries the size, and watch class changes inside the layer
    // because that swap adds or removes no call-layer nodes.
    let sizedPanel = null;
    let observedLayer = null;
    let classFrame = 0;
    const clearPanelSize = (panel) => {
      panel.style.removeProperty('width');
      panel.style.removeProperty('height');
    };
    const classObserver = new MutationObserver(() => {
      if (classFrame || drag || resizing) return;
      classFrame = requestAnimationFrame(() => { classFrame = 0; applySaved(); });
    });

    const applySaved = () => {
      const node = layer();
      if (node !== observedLayer) {
        classObserver.disconnect();
        if (node) classObserver.observe(node, { attributes: true, attributeFilter: ['class'], subtree: true });
        observedLayer = node;
      }
      if (!node) { sizedPanel = null; return; }
      const panel = node.querySelector('.call-overlay.expanded');
      if (sizedPanel && sizedPanel !== panel) { clearPanelSize(sizedPanel); sizedPanel = null; }
      if (panel) {
        if (desktop() && preferredSize) {
          panel.style.width = `${Math.min(Math.max(340, preferredSize.w), innerWidth - 24)}px`;
          panel.style.height = `${Math.min(Math.max(380, preferredSize.h), innerHeight - 24)}px`;
          sizedPanel = panel;
        } else { clearPanelSize(panel); sizedPanel = null; }
      }
      if (!desktop()) {
        resetLayerPosition(node, false);
        return;
      }
      if (saved) requestAnimationFrame(() => setLayerPosition(node, saved, false));
    };

    document.addEventListener('pointerdown', (ev) => {
      if (!desktop() || ev.button !== 0) return;
      const grip = ev.target.closest?.('[data-call-resize]');
      if (grip) {
        const node = layer(), panel = grip.closest('.call-overlay');
        if (!node || !panel) return;
        const bounds = node.getBoundingClientRect(), rect = panel.getBoundingClientRect();
        setLayerPosition(node, { x: bounds.left, y: bounds.top });
        resizing = { node, panel, pointer: ev.pointerId, x: ev.clientX, y: ev.clientY, w: rect.width, h: rect.height };
        grip.setPointerCapture(ev.pointerId); ev.preventDefault(); return;
      }
      const handle = ev.target.closest?.('[data-call-drag-handle="true"]');
      if (!handle || ev.target.closest('button, input, select, a')) return;
      const node = handle.closest('.call-layer') || layer();
      if (!node) return;
      const rect = node.getBoundingClientRect();
      node.style.left = rect.left + 'px';
      node.style.top = rect.top + 'px';
      node.style.right = 'auto';
      node.style.bottom = 'auto';
      node.classList.add('detached');
      drag = {
        node,
        pointerId: ev.pointerId,
        startX: ev.clientX,
        startY: ev.clientY,
        originX: rect.left,
        originY: rect.top,
        nextX: rect.left,
        nextY: rect.top,
        moved: false
      };
      handle.setPointerCapture?.(ev.pointerId);
      ev.preventDefault();
    });

    document.addEventListener('pointermove', (ev) => {
      if (resizing && ev.pointerId === resizing.pointer) {
        const r = resizing, bounds = r.node.getBoundingClientRect();
        const w = Math.min(Math.max(340, r.w + ev.clientX - r.x), innerWidth - bounds.left - 12);
        const h = Math.min(Math.max(380, r.h + ev.clientY - r.y), innerHeight - bounds.top - 12);
        r.panel.style.width = `${w}px`; r.panel.style.height = `${h}px`; sizedPanel = r.panel;
        preferredSize = { w, h }; ev.preventDefault(); return;
      }
      if (!drag || drag.pointerId !== ev.pointerId) return;
      const dx = ev.clientX - drag.startX;
      const dy = ev.clientY - drag.startY;
      if (!drag.moved && Math.hypot(dx, dy) < 4) return;
      drag.moved = true;
      const next = clamp(drag.node, drag.originX + dx, drag.originY + dy);
      drag.nextX = next.x;
      drag.nextY = next.y;
      if (!raf) {
        raf = requestAnimationFrame(() => {
          raf = 0;
          if (!drag) return;
          drag.node.style.transform = `translate3d(${drag.nextX - drag.originX}px, ${drag.nextY - drag.originY}px, 0)`;
          drag.node.classList.add('dragging');
        });
      }
      ev.preventDefault();
    }, { passive: false });

    const finish = (ev) => {
      if (resizing && ev.pointerId === resizing.pointer) {
        resizing = null; storage.setItem(sizeKey, JSON.stringify(preferredSize)); return;
      }
      if (!drag || drag.pointerId !== ev.pointerId) return;
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      const finished = drag;
      drag = null;
      finished.node.style.removeProperty('transform');
      finished.node.classList.remove('dragging');
      if (finished.moved) {
        suppressClick = true;
        setLayerPosition(finished.node, { x: finished.nextX, y: finished.nextY }, true);
      }
    };
    document.addEventListener('pointerup', finish);
    document.addEventListener('pointercancel', finish);
    document.addEventListener('lostpointercapture', finish);
    document.addEventListener('keydown', ev => {
      const grip = ev.target.closest?.('[data-call-resize]');
      if (!grip || !desktop() || !['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(ev.key)) return;
      const rect = grip.closest('.call-overlay').getBoundingClientRect();
      preferredSize = { w: rect.width + (ev.key === 'ArrowRight' ? 24 : ev.key === 'ArrowLeft' ? -24 : 0), h: rect.height + (ev.key === 'ArrowDown' ? 24 : ev.key === 'ArrowUp' ? -24 : 0) };
      storage.setItem(sizeKey, JSON.stringify(preferredSize)); applySaved(); ev.preventDefault();
    });

    document.addEventListener('dblclick', (ev) => {
      if (!desktop()) return;
      const handle = ev.target.closest?.('[data-call-drag-handle="true"]');
      if (!handle || ev.target.closest('button, input, select, a')) return;
      const node = handle.closest('.call-layer') || layer();
      preferredSize = null; storage.removeItem(sizeKey); applySaved();
      resetLayerPosition(node, true);
      ev.preventDefault();
    });

    document.addEventListener('click', (ev) => {
      if (!suppressClick || !ev.target.closest?.('.call-layer')) return;
      suppressClick = false;
      ev.preventDefault();
      ev.stopImmediatePropagation();
    }, true);

    window.addEventListener('resize', () => {
      applySaved();
      const node = layer();
      if (!node) return;
      if (!desktop()) {
        resetLayerPosition(node, false);
      } else if (saved) {
        setLayerPosition(node, saved, true);
      }
    }, { passive: true });

    let positionFrame = 0;
    const observer = new MutationObserver((records) => {
      const selector = '.call-layer, .call-overlay, .call-compact-bar, .call-popup';
      const changed = records.some((record) => [...record.addedNodes, ...record.removedNodes].some((node) =>
        node.nodeType === Node.ELEMENT_NODE && (node.matches?.(selector) || node.querySelector?.(selector))));
      if (!changed || positionFrame || drag) return;
      positionFrame = requestAnimationFrame(() => { positionFrame = 0; applySaved(); });
    });
    observer.observe(document.body, { childList: true, subtree: true });
    applySaved();
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
  const mentionNotifications = new Map();
  recv(app.ports.notify, ({ title = clientConfig.appName, body = '', url = '', tag = '' } = {}) => {
    if (!('Notification' in window) || Notification.permission !== 'granted') return;
    const key = tag || `${url}:${title}`;
    if (mentionNotifications.has(key)) return;
    const notification = new Notification(title, { body, tag: key });
    mentionNotifications.set(key, notification);
    notification.onclose = () => mentionNotifications.delete(key);
    notification.onclick = () => {
      if (url && url.startsWith('#')) location.hash = url;
      window.focus();
      notification.close();
    };
  });
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || event.isComposing) return;
    const close = document.querySelector('.modal .modal-head > button');
    if (close) { event.preventDefault(); close.click(); }
  }, true);
  recv(app.ports.copyText, async (text) => {
    try {
      await navigator.clipboard.writeText(text.startsWith('#invite/') ? new URL(text, location.origin + '/').href : text);
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Copied to clipboard' });
    } catch (_) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not copy. Select the text and copy it manually.' });
    }
  });
  recv(app.ports.localStorageGet, ({ key }) => {
    send(app.ports.bridgeReceive, { tag: 'local_storage', key, data: storage.getItem(key) });
  });
  recv(app.ports.localStorageSet, ({ key, value }) => {
    storage.setItem(key, value);
  });
  recv(app.ports.playTone, playTone);
  recv(app.ports.playNotification, (enabled) => {
    if (enabled) playSound('notification');
  });
  recv(app.ports.playMention, (enabled) => {
    if (enabled) playSound('mention');
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
    cancelForcedMessageScroll();
    document.querySelector(selector)?.scrollIntoView({ block: 'center' });
  });
  recv(app.ports.readFile, (id) => {
    const input = document.getElementById(id);
    const sourceFile = input && input.files && input.files[0];
    if (!sourceFile) return send(app.ports.fileInput, { id, data: null });
    if (!/^image\/(jpeg|png|gif|webp|avif)$/i.test(sourceFile.type)) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Use a JPEG, PNG, GIF, WebP, or AVIF image.' });
      send(app.ports.fileInput, { id, data: null });
      return;
    }
    const prepare = sourceFile.size > clientConfig.profileImageMaxBytes
      ? prepareFileForUpload(sourceFile, clientConfig.profileImageMaxBytes, { ask: true })
      : Promise.resolve(sourceFile);
    prepare
      .then((file) => {
        send(app.ports.bridgeReceive, { tag: 'toast', data: `Uploading ${file.name || 'image'}...` });
        return uploadOne(file);
      })
      .then((uploaded) => {
        send(app.ports.fileInput, { id, data: uploaded.url || null });
        const saveTarget = id === 'serverIconFile' || id === 'serverBannerFile' ? 'server' : 'profile';
        send(app.ports.bridgeReceive, { tag: 'toast', data: `${sourceFile.name || 'Image'} ready. Save the ${saveTarget} to apply it.` });
      })
      .catch((error) => {
        debug('UPLOAD', 'profile_image_failed', { error: error.message }, 'error');
        send(app.ports.fileInput, { id, data: null });
        const message = error.message === 'compression_failed'
          ? `That image could not be reduced below ${humanBytes(clientConfig.profileImageMaxBytes)}.`
          : error.message === 'upload_cancelled' ? 'Image upload cancelled.' : `Image upload failed: ${error.message}`;
        send(app.ports.bridgeReceive, { tag: 'toast', data: message });
      });
  });
  recv(app.ports.requestNotifyPermission, () => {
    if ('Notification' in window && Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  });
  const accountApi = async (method, path, body) => {
    const headers = { accept: 'application/json', 'x-csrf-token': csrf };
    const options = { method, headers, credentials: 'same-origin' };
    if (body !== undefined) {
      headers['content-type'] = 'application/json';
      options.body = JSON.stringify(body);
    }
    const response = await fetch('/api' + path, options);
    const json = await response.json().catch(() => ({ ok: false, error: 'bad_json' }));
    if (!response.ok || !json.ok) throw new Error(json.error || 'request_failed');
    return json.data;
  };

  const closeAccountDialog = () => document.querySelector('.account-dialog-backdrop')?.remove();

  const showAccountDialog = ({ title, subtitle, content, actions = [] }) => {
    closeAccountDialog();
    const backdrop = document.createElement('div');
    backdrop.className = 'account-dialog-backdrop';
    const dialog = document.createElement('section');
    dialog.className = 'account-dialog';
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    const head = document.createElement('div');
    head.className = 'account-dialog-head';
    const heading = document.createElement('div');
    const h = document.createElement('h3');
    h.textContent = title;
    heading.appendChild(h);
    if (subtitle) {
      const p = document.createElement('p');
      p.className = 'muted';
      p.textContent = subtitle;
      heading.appendChild(p);
    }
    const close = document.createElement('button');
    close.className = 'btn icon-btn';
    close.type = 'button';
    close.textContent = '×';
    close.setAttribute('aria-label', 'Close');
    close.addEventListener('click', closeAccountDialog);
    head.append(heading, close);
    dialog.appendChild(head);
    const body = document.createElement('div');
    body.className = 'account-dialog-body';
    if (content) body.appendChild(content);
    dialog.appendChild(body);
    if (actions.length) {
      const footer = document.createElement('div');
      footer.className = 'account-dialog-actions';
      actions.forEach(({ label, className = 'btn secondary', onClick }) => {
        const button = document.createElement('button');
        button.className = className;
        button.type = 'button';
        button.textContent = label;
        button.addEventListener('click', () => onClick(button, body));
        footer.appendChild(button);
      });
      dialog.appendChild(footer);
    }
    backdrop.appendChild(dialog);
    backdrop.addEventListener('mousedown', (event) => { if (event.target === backdrop) closeAccountDialog(); });
    document.body.appendChild(backdrop);
    requestAnimationFrame(() => dialog.querySelector('input,button')?.focus());
    return { backdrop, dialog, body };
  };

  const openPasswordDialog = () => {
    const content = document.createElement('div');
    content.className = 'account-password-fields';
    const makeField = (labelText, autocomplete) => {
      const field = document.createElement('label');
      field.className = 'field';
      const label = document.createElement('span');
      label.textContent = labelText;
      const input = document.createElement('input');
      input.type = 'password';
      input.autocomplete = autocomplete;
      input.maxLength = 256;
      field.append(label, input);
      content.appendChild(field);
      return input;
    };
    const current = makeField('Current password', 'current-password');
    const next = makeField('New password', 'new-password');
    const confirm = makeField('Confirm new password', 'new-password');
    const status = document.createElement('div');
    status.className = 'account-dialog-status';
    content.appendChild(status);
    showAccountDialog({
      title: 'Change password',
      subtitle: 'Changing your password signs out every other session.',
      content,
      actions: [
        { label: 'Cancel', onClick: closeAccountDialog },
        { label: 'Update password', className: 'btn', onClick: async (button) => {
          status.textContent = '';
          if (next.value.length < 10) { status.textContent = 'Use at least 10 characters.'; return; }
          if (next.value !== confirm.value) { status.textContent = 'The new passwords do not match.'; return; }
          button.disabled = true;
          try {
            await accountApi('POST', '/password', { current_password: current.value, new_password: next.value });
            closeAccountDialog();
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Password changed. Other sessions were signed out.' });
          } catch (error) {
            status.textContent = error.message === 'bad_password' ? 'Current password is incorrect.' : 'Could not change the password.';
          } finally { button.disabled = false; }
        } }
      ]
    });
  };

  const openSessionsDialog = async () => {
    const content = document.createElement('div');
    content.className = 'session-list';
    content.textContent = 'Loading sessions...';
    showAccountDialog({
      title: 'Active sessions',
      subtitle: 'Sessions are listed by activity time. Device fingerprints are intentionally not stored.',
      content,
      actions: [
        { label: 'Close', onClick: closeAccountDialog },
        { label: 'Log out other sessions', className: 'btn danger', onClick: async (button) => {
          button.disabled = true;
          try {
            const data = await accountApi('POST', '/sessions/logout-others', {});
            send(app.ports.bridgeReceive, { tag: 'toast', data: `${data?.revoked || 0} other session${data?.revoked === 1 ? '' : 's'} signed out.` });
            closeAccountDialog();
          } catch (_) {
            button.disabled = false;
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not sign out other sessions.' });
          }
        } }
      ]
    });
    try {
      const sessions = await accountApi('GET', '/sessions');
      content.textContent = '';
      (Array.isArray(sessions) ? sessions : []).forEach((session) => {
        const row = document.createElement('div');
        row.className = 'session-row';
        const copy = document.createElement('div');
        const title = document.createElement('b');
        title.textContent = session.current ? 'This browser' : 'Signed-in session';
        const meta = document.createElement('small');
        meta.className = 'muted';
        const last = Number(session.last_seen || 0);
        meta.textContent = last ? `Last active ${new Date(last).toLocaleString()}` : 'Activity time unavailable';
        copy.append(title, meta);
        const badge = document.createElement('span');
        badge.className = 'pill';
        badge.textContent = session.current ? 'Current' : 'Active';
        row.append(copy, badge);
        content.appendChild(row);
      });
      if (!content.children.length) content.textContent = 'No active sessions were returned.';
    } catch (_) {
      content.textContent = 'Could not load active sessions.';
    }
  };

  const openDiagnosticsDialog = async () => {
    const content = document.createElement('div');
    content.className = 'diagnostics-panel';
    const status = document.createElement('div');
    status.className = 'account-dialog-status';
    const list = document.createElement('div');
    list.className = 'diagnostics-list';
    content.append(list, status);

    let reportText = '';
    const socketName = () => ws ? ['Connecting', 'Open', 'Closing', 'Closed'][ws.readyState] || 'Unknown' : 'Not started';
    const valueRow = (labelText, valueText, tone = '') => {
      const row = document.createElement('div');
      row.className = 'diagnostics-row';
      const label = document.createElement('span');
      label.textContent = labelText;
      const value = document.createElement('b');
      value.textContent = valueText;
      if (tone) value.className = `diagnostics-value ${tone}`;
      row.append(label, value);
      return row;
    };

    const refresh = async () => {
      status.textContent = '';
      list.textContent = '';
      list.append(
        valueRow('Plainwire', clientConfig.version || 'unknown'),
        valueRow('Browser network', navigator.onLine ? 'Online' : 'Offline', navigator.onLine ? 'good' : 'bad'),
        valueRow('WebSocket', socketName(), ws?.readyState === WebSocket.OPEN ? 'good' : 'warn'),
        valueRow('Secure context', window.isSecureContext ? 'Yes' : 'No', window.isSecureContext ? 'good' : 'bad'),
        valueRow('WebRTC', typeof RTCPeerConnection === 'function' ? 'Supported' : 'Unavailable', typeof RTCPeerConnection === 'function' ? 'good' : 'bad')
      );

      let healthText = 'Unavailable';
      let databaseText = 'Unknown';
      let serverVersion = 'Unavailable';
      let serverAssetVersion = 'Unavailable';
      try {
        const [health, version] = await Promise.all([
          accountApi('GET', '/health'),
          accountApi('GET', '/version')
        ]);
        healthText = health?.app === 'ok' ? 'Healthy' : 'Degraded';
        databaseText = health?.database === 'ok' ? 'Healthy' : String(health?.database || 'Unknown');
        serverVersion = String(version?.version || 'Unknown');
        serverAssetVersion = String(version?.asset_version || 'Unknown');
      } catch (_) {
        healthText = 'Unavailable';
      }
      const versionMatches = serverVersion === clientConfig.version;
      const assetsMatch = serverAssetVersion === clientConfig.assetVersion;
      list.append(
        valueRow('Backend', healthText, healthText === 'Healthy' ? 'good' : 'bad'),
        valueRow('Database', databaseText, databaseText === 'Healthy' ? 'good' : 'warn'),
        valueRow('Server version', serverVersion, versionMatches ? 'good' : 'warn'),
        valueRow('Asset fingerprint', assetsMatch ? 'Matched' : 'Mismatch', assetsMatch ? 'good' : 'warn')
      );

      let turnReady = false;
      let iceCount = 0;
      try {
        const config = await loadRtcConfig();
        const servers = Array.isArray(config?.iceServers) ? config.iceServers : [];
        iceCount = servers.length;
        turnReady = servers.some((server) => {
          const urls = Array.isArray(server?.urls) ? server.urls : [server?.urls];
          return urls.some((url) => typeof url === 'string' && (url.startsWith('turn:') || url.startsWith('turns:')));
        });
      } catch (_) {}
      list.append(
        valueRow('ICE servers', String(iceCount), iceCount > 0 ? 'good' : 'warn'),
        valueRow('TURN relay', turnReady ? 'Ready' : ({ over_limit: 'Usage limit reached', usage_unavailable: 'Usage check unavailable', unavailable: 'Temporarily unavailable' }[rtcConfig.turnStatus] || 'Not configured'), turnReady ? 'good' : 'warn')
      );

      reportText = [
        `Plainwire ${clientConfig.version || 'unknown'}`,
        `Browser network: ${navigator.onLine ? 'online' : 'offline'}`,
        `WebSocket: ${socketName()}`,
        `Secure context: ${window.isSecureContext ? 'yes' : 'no'}`,
        `WebRTC: ${typeof RTCPeerConnection === 'function' ? 'supported' : 'unavailable'}`,
        `Backend: ${healthText}`,
        `Database: ${databaseText}`,
        `Server version: ${serverVersion}`,
        `Client version: ${clientConfig.version}`,
        `Asset fingerprint: ${assetsMatch ? 'matched' : 'mismatch'}`,
        `ICE servers: ${iceCount}`,
        `TURN relay: ${turnReady ? 'configured' : 'not detected'}`
      ].join('\n');
    };

    showAccountDialog({
      title: 'Connection diagnostics',
      subtitle: 'A quick local check. Credentials and session tokens are never included.',
      content,
      actions: [
        { label: 'Close', onClick: closeAccountDialog },
        { label: 'Refresh', onClick: async (button) => {
          button.disabled = true;
          try { await refresh(); } finally { button.disabled = false; }
        } },
        { label: 'Copy report', className: 'btn', onClick: async (button) => {
          if (!reportText) return;
          button.disabled = true;
          try {
            await navigator.clipboard?.writeText(reportText);
            status.textContent = 'Diagnostic report copied.';
          } catch (_) {
            status.textContent = 'Clipboard access was not available.';
          } finally { button.disabled = false; }
        } }
      ]
    });
    await refresh();
  };

  recv(app.ports.bridgeSend, ({ tag, data }) => {
    debug('ELM', 'command', { tag, data });
    switch (tag) {
      case 'preserve_message_scroll': {
        const list = document.getElementById('messages');
        messageScrollSnapshot = list ? { element: list, route: location.hash, height: list.scrollHeight, top: list.scrollTop } : null;
        break;
      }
      case 'restore_message_scroll':
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const list = document.getElementById('messages');
          if (list && messageScrollSnapshot?.element === list && messageScrollSnapshot.route === location.hash) {
            list.scrollTop = messageScrollSnapshot.top + (list.scrollHeight - messageScrollSnapshot.height);
          }
          messageScrollSnapshot = null;
          observeMessageHistory();
        }));
        break;
      case 'settings_section_changed':
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const content = document.querySelector('.settings-content');
          if (content) content.scrollTop = 0;
          document.querySelector('.settings-mobile-tab.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        }));
        break;
      case 'scroll_messages_to_bottom':
        {
          const list = document.getElementById('messages');
          if (!list) {
            if (data === true) pendingForcedMessageRoute = location.hash;
            break;
          }
          pendingForcedMessageRoute = null;
          if (!messagesPinnedToBottom && data !== true) break;
          scrollMessageListToBottom(data === true);
          list.querySelectorAll('img, video').forEach((media) => {
            if (media.tagName === 'IMG' && media.complete) return;
            media.addEventListener('load', () => {
              if (messagesPinnedToBottom) scrollMessageListToBottom();
            }, { once: true });
          });
          observeMessageHistory();
        }
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
        if (room) sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { deafened, muted: micMuted } });
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
          document.documentElement.setAttribute('data-theme', data === 'dark' ? 'dark' : 'light');
        }
        syncThemeMeta();
        break;
      case 'set_sound_preference':
        storage.setItem('plainwire_sound_enabled', data ? 'true' : 'false');
        if (!data) { stopRingtones(); stopSoundGroup(); }
        if (!data) stopRingtones();
        break;
      case 'ui_density':
        storage.setItem('plainwire_density', data === 'compact' ? 'compact' : 'comfortable');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: data === 'compact' ? 'Compact layout enabled' : 'Comfortable layout enabled' });
        break;
      case 'reduce_motion':
        storage.setItem('plainwire_reduce_motion', data ? 'true' : 'false');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: data ? 'Reduced motion enabled' : 'Standard motion enabled' });
        break;
      case 'ui_font_scale':
        storage.setItem('plainwire_font_scale', ['small', 'large'].includes(data) ? data : 'default');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Text size updated' });
        break;
      case 'ui_corner_style':
        storage.setItem('plainwire_corner_style', ['compact', 'rounded'].includes(data) ? data : 'default');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Corner style updated' });
        break;
      case 'ui_accent':
        storage.setItem('plainwire_accent', Object.hasOwn(accentPresets, data) ? data : 'blue');
        applyUiPreferences();
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Accent updated' });
        break;
      case 'chat_enter_mode':
        storage.setItem('plainwire_chat_enter_mode', data === 'newline' ? 'newline' : 'send');
        break;
      case 'chat_set_link_previews': {
        const enabled = data === true;
        storage.setItem('plainwire_link_previews', enabled ? 'true' : 'false');
        document.documentElement.dataset.linkPreviews = enabled ? 'true' : 'false';
        document.querySelectorAll('pw-markdown').forEach((node) => node.refreshEmbeds?.());
        break;
      }
      case 'chat_set_animated_media': {
        const enabled = data === true;
        storage.setItem('plainwire_animated_media', enabled ? 'true' : 'false');
        applyUiPreferences();
        break;
      }
      case 'chat_set_compact_messages': {
        const enabled = data === true;
        storage.setItem('plainwire_compact_messages', enabled ? 'true' : 'false');
        applyUiPreferences();
        break;
      }
      case 'privacy_set_media_preload': {
        const enabled = data === true;
        storage.setItem('plainwire_media_preload', enabled ? 'true' : 'false');
        applyUiPreferences();
        break;
      }
      case 'privacy_clear_drafts':
        send(app.ports.bridgeReceive, { tag: 'clear_drafts' });
        Array.from({ length: storage.length }, (_, i) => storage.key(i))
          .filter((key) => key && (key.startsWith('plainwire_draft') || key.startsWith('draft:')))
          .forEach((key) => storage.removeItem(key));
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Local drafts cleared' });
        break;
      case 'privacy_reset_device':
        if (window.confirm('Reset Plainwire preferences stored in this browser?')) {
          Array.from({ length: storage.length }, (_, i) => storage.key(i))
            .filter((key) => key && key.startsWith('plainwire_'))
            .forEach((key) => storage.removeItem(key));
          location.reload();
        }
        break;
      case 'account_change_password':
        openPasswordDialog();
        break;
      case 'account_sessions':
        openSessionsDialog();
        break;
      case 'account_diagnostics':
        openDiagnosticsDialog();
        break;
      case 'request_notifications':
        if ('Notification' in window) {
          Notification.requestPermission().then((permission) => {
            send(app.ports.bridgeReceive, { tag: 'toast', data: permission === 'granted' ? 'Desktop notifications enabled' : 'Notifications were not enabled' });
          }).catch(() => {});
        }
        break;
      case 'preview_sound':
        playSound(data, { preview: true });
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
        storage.setItem('plainwire_audio_output', selectedOutputId);
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
      case 'watch_screen': {
        const uid = Number(data);
        if (uid === meId && screenStream) { showLocalScreenPreview(screenStream); break; }
        if (!room?.joined || !screenSharers.has(uid)) break;
        watchedScreens.add(uid);
        const streams = peers.get(uid)?._videoStreams;
        const stream = streams && Array.from(streams.values()).pop();
        showStageVideo(uid, stream);
        break;
      }
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

  window.addEventListener('hashchange', () => {
    closeTouchMessageActions();
    syncMobileViewport();
    send(app.ports.onHashChange, location.hash);
  });
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
      const palette = ['#5865f2', '#3b82f6', '#16877a', '#37854f', '#9a6716', '#b64d6b', '#7c5bb5', '#a75432'];
      const replacement = document.createElement('div');
      replacement.className = target.className + ' image-failed';
      replacement.textContent = String(fallback).slice(0, 1).toUpperCase();
      replacement.style.backgroundColor = palette[(String(fallback).codePointAt(0) || 0) % palette.length];
      replacement.style.color = '#fff';
      replacement.setAttribute('role', 'img');
      replacement.setAttribute('aria-label', 'Avatar unavailable');
      target.replaceWith(replacement);
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
  callHealth = window.PlainwireCallHealth?.create({
    getPeers: () => peers, getRoom: () => room, send: sendWs,
    analysisEnabled: rawClientConfig.media_quality_enabled !== false,
    adaptiveScreen: rawClientConfig.adaptive_screen === true,
    getLabel: (uid) => document.querySelector(`.call-user-row[data-peer-id="${uid}"] .call-user-name`)?.textContent || 'Participant',
    adapt: (pc, limited) => {
      if (!pc._videoSender) return;
      pc._videoSender._qualityLimited = limited;
      if (screenStream) applyEncoderTier(pc._videoSender, peers.size + 1);
    }
  });
})();
