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
  const bootVersion = document.documentElement.dataset.plainwireVersion || 'dev';
  const clientConfig = Object.freeze({
    version: typeof rawClientConfig.version === 'string' ? rawClientConfig.version.slice(0, 32) : bootVersion,
    assetVersion: typeof rawClientConfig.asset_version === 'string' ? rawClientConfig.asset_version.slice(0, 64) : bootVersion,
    appName: typeof rawClientConfig.app_name === 'string' && rawClientConfig.app_name.trim()
      ? rawClientConfig.app_name.trim().slice(0, 48) : 'Plainwire',
    defaultTheme: ['light', 'dark', 'system'].includes(rawClientConfig.default_theme)
      ? rawClientConfig.default_theme : 'system',
    registrationEnabled: rawClientConfig.registration_enabled !== false,
    passwordResetEnabled: rawClientConfig.password_reset_enabled === true,
    gifSearchEnabled: rawClientConfig.gif_search_enabled === true,
    gifProvider: typeof rawClientConfig.gif_provider === 'string' ? rawClientConfig.gif_provider.trim().slice(0, 24) : '',
    sourceRepository: typeof rawClientConfig.source_repository === 'string' && /^https:\/\//i.test(rawClientConfig.source_repository)
      ? rawClientConfig.source_repository.slice(0, 512) : 'https://github.com/Plainwire-development/Plainwire',
    instanceDescription: typeof rawClientConfig.instance_description === 'string'
      ? rawClientConfig.instance_description.trim().slice(0, 120) : '',
    uploadMaxBytes: finiteInt(rawClientConfig.upload_max_bytes, 250 * 1024 * 1024, 1024 * 1024, 250 * 1024 * 1024),
    profileImageMaxBytes: finiteInt(rawClientConfig.profile_image_max_bytes, 16 * 1024 * 1024, 256 * 1024, 16 * 1024 * 1024),
    uploadMaxFiles: finiteInt(rawClientConfig.upload_max_files, 10, 1, 25),
    idleTimeoutMs: finiteInt(rawClientConfig.idle_timeout_ms, 10 * 60 * 1000, 60 * 1000, 24 * 60 * 60 * 1000),
    compressOversizeUploads: rawClientConfig.compress_oversize_uploads !== false,
    maxImageDimension: finiteInt(rawClientConfig.max_image_dimension, 4096, 512, 8192)
  });

  let gifSearchAbort = null;
  let gifSearchTimer = null;
  let gifPickerNode = null;
  const closeGifPicker = () => {
    if (gifSearchAbort) gifSearchAbort.abort();
    gifSearchAbort = null;
    if (gifSearchTimer) clearTimeout(gifSearchTimer);
    gifSearchTimer = null;
    gifPickerNode?.remove();
    gifPickerNode = null;
  };
  const registerGifShare = (id, query) => {
    if (!id) return;
    fetch('/api/gifs/share', {
      method: 'POST',
      headers: { accept: 'application/json', 'content-type': 'application/json', 'x-csrf-token': csrf },
      body: JSON.stringify({ id, q: query || '' }),
      cache: 'no-store'
    }).catch(() => {});
  };
  const openGifPicker = () => {
    if (!clientConfig.gifSearchEnabled) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'GIF search is not configured on this Plainwire server.' });
      return;
    }
    if (!activeComposer()) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Open a DM, text channel, or thread before choosing a GIF.' });
      return;
    }

    closeGifPicker();
    const backdrop = document.createElement('div');
    backdrop.className = 'gif-picker-backdrop';
    backdrop.setAttribute('role', 'presentation');
    const picker = document.createElement('section');
    picker.className = 'gif-picker-shell';
    picker.setAttribute('role', 'dialog');
    picker.setAttribute('aria-modal', 'true');
    picker.setAttribute('aria-label', 'Search KLIPY GIFs');

    const head = document.createElement('div');
    head.className = 'gif-picker-head';
    const title = document.createElement('div');
    const heading = document.createElement('strong');
    heading.textContent = 'GIFs';
    const provider = document.createElement('small');
    provider.textContent = `Powered by ${clientConfig.gifProvider || 'KLIPY'}`;
    title.append(heading, provider);
    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'gif-picker-close';
    close.setAttribute('aria-label', 'Close GIF search');
    close.textContent = '×';
    head.append(title, close);

    const search = document.createElement('input');
    search.type = 'search';
    search.className = 'gif-picker-search';
    // KLIPY requires this exact placeholder for API integrations.
    search.placeholder = 'Search KLIPY';
    search.setAttribute('aria-label', 'Search KLIPY');
    search.autocomplete = 'off';
    search.spellcheck = true;

    const chips = document.createElement('div');
    chips.className = 'gif-picker-chips';
    chips.setAttribute('aria-label', 'Quick GIF searches');
    ['reaction', 'laugh', 'wow', 'yes', 'no', 'bruh'].forEach((term) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = term;
      button.addEventListener('click', () => {
        search.value = term;
        search.dispatchEvent(new Event('input', { bubbles: true }));
      });
      chips.append(button);
    });

    const status = document.createElement('div');
    status.className = 'gif-picker-status';
    status.setAttribute('role', 'status');
    status.setAttribute('aria-live', 'polite');
    status.textContent = 'Search KLIPY to find a GIF.';
    const grid = document.createElement('div');
    grid.className = 'gif-picker-grid';
    grid.setAttribute('aria-label', 'GIF results');
    const footer = document.createElement('div');
    footer.className = 'gif-picker-footer';
    const loadMore = document.createElement('button');
    loadMore.type = 'button';
    loadMore.className = 'btn secondary gif-picker-more';
    loadMore.textContent = 'Load more';
    loadMore.hidden = true;
    footer.append(loadMore);

    picker.append(head, search, chips, status, grid, footer);
    backdrop.append(picker);
    document.body.append(backdrop);
    gifPickerNode = backdrop;

    let next = '';
    let activeQuery = '';
    let requestSerial = 0;
    let loading = false;
    const seenIds = new Set();

    const renderItem = (item, query) => {
      if (!item?.url || !item?.id || seenIds.has(String(item.id))) return;
      seenIds.add(String(item.id));
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'gif-picker-item';
      button.title = item.title || 'GIF';
      button.setAttribute('aria-label', `Insert GIF: ${item.title || 'GIF'}`);
      if (Number(item.width) > 0 && Number(item.height) > 0) {
        button.style.setProperty('--gif-aspect', `${Number(item.width)} / ${Number(item.height)}`);
      }
      const image = document.createElement('img');
      image.loading = 'lazy';
      image.decoding = 'async';
      image.alt = item.title || 'GIF';
      image.src = item.preview_url || item.url;
      const label = document.createElement('span');
      label.textContent = item.title || 'GIF';
      button.append(image, label);
      button.addEventListener('click', () => {
        const titleText = String(item.title || 'GIF').replace(/[\[\]]/g, '').slice(0, 80);
        if (insertIntoComposer(`![${titleText}](${item.url})`)) {
          registerGifShare(item.id, query);
          closeGifPicker();
        }
      });
      grid.append(button);
    };

    const searchNow = async ({ append = false } = {}) => {
      const query = search.value;
      if (!query.trim()) {
        if (gifSearchAbort) gifSearchAbort.abort();
        requestSerial += 1;
        activeQuery = '';
        next = '';
        loading = false;
        seenIds.clear();
        grid.replaceChildren();
        loadMore.hidden = true;
        status.textContent = 'Search KLIPY to find a GIF.';
        grid.removeAttribute('aria-busy');
        return;
      }
      if (loading || (append && !next)) return;

      const position = append ? next : '';
      if (!append) {
        next = '';
        activeQuery = query;
        seenIds.clear();
      } else if (query !== activeQuery) {
        // The query changed while a pagination request was queued. Start over
        // instead of appending results from two different searches.
        return searchNow({ append: false });
      }

      gifSearchAbort?.abort();
      const controller = new AbortController();
      gifSearchAbort = controller;
      const serial = ++requestSerial;
      loading = true;
      loadMore.disabled = true;
      grid.setAttribute('aria-busy', 'true');
      status.textContent = append ? 'Loading more…' : 'Searching…';

      try {
        const params = new URLSearchParams({ q: query });
        if (position) params.set('pos', position);
        const response = await fetch(`/api/gifs/search?${params}`, {
          headers: { accept: 'application/json' },
          cache: 'no-store',
          credentials: 'same-origin',
          signal: controller.signal
        });
        const payload = await response.json().catch(() => null);
        if (!response.ok || !payload?.ok) throw new Error(payload?.error || `HTTP ${response.status}`);
        if (serial !== requestSerial || gifPickerNode !== backdrop) return;

        const results = Array.isArray(payload.data?.results) ? payload.data.results : [];
        if (!append) grid.replaceChildren();
        for (const item of results) renderItem(item, query);
        next = typeof payload.data?.next === 'string' ? payload.data.next : '';
        loadMore.hidden = !next;
        const visible = grid.childElementCount;
        status.textContent = visible
          ? `${visible} GIF${visible === 1 ? '' : 's'} from KLIPY${next ? ' · more available' : ''}`
          : 'No GIFs matched that search.';
      } catch (error) {
        if (error.name === 'AbortError') return;
        if (!append) grid.replaceChildren();
        status.textContent = error.message === 'rate_limited' || error.message === 'provider_rate_limited'
          ? 'GIF search is being used quickly. Try again in a moment.'
          : 'GIF search is temporarily unavailable.';
        debug('GIF', 'search_failed', { error: error.message }, 'warn');
      } finally {
        if (serial === requestSerial) {
          loading = false;
          loadMore.disabled = false;
          grid.removeAttribute('aria-busy');
        }
      }
    };

    const queueSearch = () => {
      if (gifSearchTimer) clearTimeout(gifSearchTimer);
      next = '';
      loadMore.hidden = true;
      gifSearchTimer = setTimeout(() => searchNow({ append: false }), 260);
    };
    search.addEventListener('input', queueSearch);
    loadMore.addEventListener('click', () => searchNow({ append: true }));
    close.addEventListener('click', closeGifPicker);
    backdrop.addEventListener('click', (event) => { if (event.target === backdrop) closeGifPicker(); });
    backdrop.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        closeGifPicker();
        return;
      }
      if (event.key === 'Tab') {
        const focusable = [...picker.querySelectorAll('button:not(:disabled):not([hidden]), input:not(:disabled)')];
        if (!focusable.length) return;
        const first = focusable[0];
        const last = focusable.at(-1);
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    });
    queueMicrotask(() => search.focus());
  };

  const showAccountRestriction = (restriction = {}) => {
    const existing = document.getElementById('plainwire-account-restriction');
    if (existing) existing.remove();
    const severity = ['info','warning','critical'].includes(String(restriction.severity || '')) ? String(restriction.severity) : 'warning';
    const state = String(restriction.state || 'suspended');
    const overlay = document.createElement('section');
    overlay.id = 'plainwire-account-restriction';
    overlay.className = `account-restriction-screen ${severity}`;
    overlay.setAttribute('role', 'alertdialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'plainwire-restriction-title');
    const card = document.createElement('div');
    card.className = 'account-restriction-card';
    const mark = document.createElement('div'); mark.className = 'account-restriction-mark'; mark.textContent = severity === 'critical' ? '!' : 'i'; mark.setAttribute('aria-hidden','true');
    const eyebrow = document.createElement('div'); eyebrow.className = 'account-restriction-eyebrow'; eyebrow.textContent = state === 'banned' ? 'Account banned' : 'Account suspended';
    const title = document.createElement('h1'); title.id = 'plainwire-restriction-title'; title.textContent = String(restriction.title || (state === 'banned' ? 'Access revoked' : 'Account suspended'));
    const reason = document.createElement('p'); reason.className = 'account-restriction-reason'; reason.textContent = String(restriction.reason || 'This account cannot access this Plainwire instance right now.');
    card.append(mark, eyebrow, title, reason);
    const expiresAt = Number(restriction.expires_at || 0);
    if (expiresAt > 0) {
      const expiry = document.createElement('p'); expiry.className = 'account-restriction-expiry';
      expiry.textContent = `Access is scheduled to return ${new Date(expiresAt).toLocaleString()}.`;
      card.append(expiry);
    } else {
      const expiry = document.createElement('p'); expiry.className = 'account-restriction-expiry'; expiry.textContent = 'No automatic expiry is set.'; card.append(expiry);
    }
    const help = document.createElement('p'); help.className = 'account-restriction-help'; help.textContent = 'Contact this Plainwire instance operator if you believe this action is incorrect.'; card.append(help);
    const retry = document.createElement('button'); retry.type = 'button'; retry.className = 'btn secondary'; retry.textContent = 'Check access again';
    retry.addEventListener('click', () => location.reload()); card.append(retry);
    overlay.append(card); document.body.append(overlay); retry.focus();
  };

  const friendlyApiError = (code) => ({
    forbidden: 'You do not have permission to do that.',
    not_found: 'That item no longer exists.',
    role_hierarchy: 'That role or member is at or above your highest manageable role.',
    owner_role_locked: 'The owner role cannot be reassigned.',
    too_many_roles: 'A member can have at most 50 custom roles.',
    invalid_role: 'One of those roles no longer exists.',
    forum_membership_required: 'Join this forum before posting, replying, or voting.',
    forum_owner_cannot_leave: 'The forum owner cannot leave their own forum.',
    thread_locked: 'That thread is locked.',
    rate_limited: 'Too many requests. Wait a moment and try again.',
    reaction_rate_limited: 'You are reacting too quickly. Wait a moment and try again.',
    invalid_reaction: 'That reaction is not supported.',
    confirmation_mismatch: 'The server name did not match. Type it exactly to confirm deletion.',
    database_unavailable: 'The server database is temporarily unavailable.',
    database_busy: 'The server is busy. Try again in a moment.',
    request_failed: 'The request could not be completed.'
  }[code] || String(code || 'Request failed').replaceAll('_', ' '));

  const directApi = async (path, { method = 'GET', body = null, timeoutMs = 20000 } = {}) => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const headers = { accept: 'application/json', 'x-csrf-token': csrf };
    const options = { method, headers, cache: 'no-store', signal: controller.signal };
    if (body !== null) { headers['content-type'] = 'application/json'; options.body = JSON.stringify(body); }
    try {
      const response = await fetch('/api' + path, options);
      const payload = await response.json().catch(() => ({ ok: false, error: 'bad_json' }));
      if (!response.ok || !payload.ok) {
        const code = payload.error || `HTTP ${response.status}`;
        const error = new Error(friendlyApiError(code));
        error.code = code;
        throw error;
      }
      return payload.data;
    } finally { clearTimeout(timeout); }
  };
  let globalBannerItems = [];
  let globalBannerTimer = null;
  let globalBannerRequest = null;
  const bannerDismissKey = (banner) => `plainwire_banner_dismissed_${Number(banner?.id || 0)}_${Number(banner?.updated_at || 0)}`;
  const safeBannerHref = (value) => {
    if (typeof value !== 'string' || !value) return '';
    try {
      const url = new URL(value, location.origin);
      if (url.protocol !== 'https:' && url.origin !== location.origin) return '';
      return url.href;
    } catch (_) { return ''; }
  };
  const syncGlobalBannerOffset = () => {
    const stack = document.getElementById('pw-global-banners');
    const height = stack && stack.childElementCount ? Math.ceil(stack.getBoundingClientRect().height) : 0;
    document.documentElement.style.setProperty('--pw-global-banner-offset', `${height}px`);
  };
  const renderGlobalBanners = (items = globalBannerItems) => {
    globalBannerItems = Array.isArray(items) ? items.slice(0, 32) : [];
    if (globalBannerTimer) { clearTimeout(globalBannerTimer); globalBannerTimer = null; }
    const now = Date.now();
    const boundaries = [];
    const visible = globalBannerItems.filter((banner) => {
      const starts = Number(banner?.starts_at || 0);
      const ends = Number(banner?.ends_at || 0);
      if (starts > now) { boundaries.push(starts); return false; }
      if (ends > 0) {
        if (ends <= now) return false;
        boundaries.push(ends);
      }
      return storage.getItem(bannerDismissKey(banner)) !== '1';
    });
    let stack = document.getElementById('pw-global-banners');
    if (!visible.length) {
      stack?.remove();
      syncGlobalBannerOffset();
    } else {
      if (!stack) {
        stack = document.createElement('div');
        stack.id = 'pw-global-banners';
        stack.className = 'pw-global-banner-stack';
        stack.setAttribute('aria-label', 'Service announcements');
        // Browser.application owns every child of <body> and patches them by
        // index, so a node inserted there corrupts Elm's view. Mount the stack
        // beside <body> instead; the theme and font live on <html>.
        document.documentElement.append(stack);
      }
      stack.replaceChildren();
      visible.slice(0, 3).forEach((banner) => {
        const severity = ['info', 'success', 'warning', 'critical'].includes(banner?.severity) ? banner.severity : 'info';
        const row = document.createElement('section');
        row.className = `pw-global-banner ${severity}`;
        row.setAttribute('role', severity === 'critical' ? 'alert' : 'status');
        const marker = document.createElement('span'); marker.className = 'pw-global-banner-marker'; marker.setAttribute('aria-hidden', 'true');
        const copy = document.createElement('div'); copy.className = 'pw-global-banner-copy';
        if (banner?.title) { const title = document.createElement('strong'); title.textContent = String(banner.title).slice(0, 80); copy.append(title); }
        const body = document.createElement('span'); body.textContent = String(banner?.body || '').slice(0, 500); copy.append(body);
        const href = safeBannerHref(banner?.link_url || '');
        if (href) {
          const link = document.createElement('a'); link.className = 'pw-global-banner-link'; link.href = href;
          link.textContent = String(banner?.link_label || '').trim().slice(0, 40) || 'Learn more';
          if (new URL(href).origin !== location.origin) { link.target = '_blank'; link.rel = 'noopener noreferrer'; }
          copy.append(link);
        }
        row.append(marker, copy);
        if (banner?.dismissible !== false) {
          const close = document.createElement('button'); close.type = 'button'; close.className = 'pw-global-banner-close'; close.textContent = '×';
          close.setAttribute('aria-label', 'Dismiss announcement');
          close.addEventListener('click', () => { storage.setItem(bannerDismissKey(banner), '1'); renderGlobalBanners(); });
          row.append(close);
        }
        stack.append(row);
      });
      requestAnimationFrame(syncGlobalBannerOffset);
    }
    const next = boundaries.filter((at) => at > now).sort((a, b) => a - b)[0];
    if (next) globalBannerTimer = setTimeout(() => renderGlobalBanners(), Math.min(2147483000, Math.max(100, next - Date.now() + 50)));
  };
  const refreshGlobalBanners = () => {
    if (globalBannerRequest) return globalBannerRequest;
    globalBannerRequest = directApi('/system/banners', { timeoutMs: 10000 })
      .then((items) => { renderGlobalBanners(items); return items; })
      .catch((error) => { debug('SYNC', 'global_banners_failed', { error: error.message }, 'warn'); return globalBannerItems; })
      .finally(() => { globalBannerRequest = null; });
    return globalBannerRequest;
  };
  window.addEventListener('resize', () => requestAnimationFrame(syncGlobalBannerOffset), { passive: true });

  const permissionBit = (data, key) => Number((data?.catalog || []).find(item => item.key === key)?.bit || 0);
  const hasPermission = (data, key) => {
    const permissions = Number(data?.permissions || 0);
    const bit = permissionBit(data, key);
    const admin = permissionBit(data, 'administrator');
    return (admin && (permissions & admin) !== 0) || (bit && (permissions & bit) !== 0);
  };
  const modalShell = (titleText, subtitle = '') => {
    const backdrop = document.createElement('div'); backdrop.className = 'admin-modal-backdrop';
    const dialog = document.createElement('section'); dialog.className = 'admin-modal-shell'; dialog.setAttribute('role', 'dialog'); dialog.setAttribute('aria-modal', 'true'); dialog.tabIndex = -1;
    const head = document.createElement('header'); head.className = 'admin-modal-head';
    const copy = document.createElement('div'); const title = document.createElement('h2'); title.textContent = titleText; copy.append(title);
    if (subtitle) { const sub = document.createElement('p'); sub.textContent = subtitle; copy.append(sub); }
    const close = document.createElement('button'); close.type = 'button'; close.className = 'admin-modal-close'; close.textContent = '×'; close.setAttribute('aria-label', 'Close');
    head.append(copy, close);
    const body = document.createElement('div'); body.className = 'admin-modal-body';
    dialog.append(head, body); backdrop.append(dialog); document.body.append(backdrop);
    const destroy = () => backdrop.remove();
    close.addEventListener('click', destroy); backdrop.addEventListener('click', event => { if (event.target === backdrop) destroy(); });
    backdrop.addEventListener('keydown', event => { if (event.key === 'Escape') { event.preventDefault(); destroy(); } });
    requestAnimationFrame(() => dialog.focus({ preventScroll: true }));
    return { backdrop, dialog, body, destroy, setTitle(value) { title.textContent = value; } };
  };
  const makeField = (labelText, value = '', { multiline = false, type = 'text', placeholder = '', maxLength = null } = {}) => {
    const label = document.createElement('label'); label.className = 'admin-field'; const span = document.createElement('span'); span.textContent = labelText;
    const input = multiline ? document.createElement('textarea') : document.createElement('input');
    if (!multiline) input.type = type; input.value = value || ''; input.placeholder = placeholder;
    if (multiline) { input.value = value || ''; input.rows = 3; input.placeholder = placeholder; }
    if (maxLength) input.maxLength = maxLength;
    label.append(span, input); return { label, input };
  };
  const adminMessage = (container, message, kind = 'muted') => {
    const el = document.createElement('p'); el.className = `admin-inline-message ${kind}`; el.textContent = message; container.append(el); return el;
  };

  const extensionStorageKey = 'plainwire_extensions_v2';
  const extensionWorkers = new Map();
  let lessCompilerPromise = null;

  const readExtensions = () => {
    try {
      const parsed = JSON.parse(storage.getItem(extensionStorageKey) || '{"themes":[],"plugins":[]}');
      return {
        themes: Array.isArray(parsed.themes) ? parsed.themes.filter(Boolean).slice(0, 40) : [],
        plugins: Array.isArray(parsed.plugins) ? parsed.plugins.filter(Boolean).slice(0, 40).map((plugin) => ({
          ...plugin,
          permissions: { apiWrite: plugin?.permissions?.apiWrite === true }
        })) : []
      };
    } catch (_) { return { themes: [], plugins: [] }; }
  };
  const writeExtensions = (value) => storage.setItem(extensionStorageKey, JSON.stringify(value));
  const extensionId = () => `${Date.now().toString(36)}-${crypto.getRandomValues(new Uint32Array(1))[0].toString(36)}`;
  const loadLessCompiler = () => {
    if (window.less?.render) return Promise.resolve(window.less);
    if (lessCompilerPromise) return lessCompilerPromise;
    lessCompilerPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = `/assets/less.min.js?v=${encodeURIComponent(clientConfig.assetVersion || clientConfig.version)}`;
      script.onload = () => window.less?.render ? resolve(window.less) : reject(new Error('Less compiler failed to initialize'));
      script.onerror = () => reject(new Error('Could not load the Less compiler'));
      document.head.append(script);
    }).catch((error) => { lessCompilerPromise = null; throw error; });
    return lessCompilerPromise;
  };
  const validateThemeSource = (source) => {
    if (typeof source !== 'string' || !source.trim() || source.length > 131072) throw new Error('Theme source must be between 1 byte and 128 KiB.');
    if (/@import\b/i.test(source)) throw new Error('Theme @import is disabled. Keep themes self-contained.');
    if (/`[^`]*`/.test(source)) throw new Error('Less JavaScript expressions are disabled.');
    return source;
  };
  const applyClientThemes = async () => {
    document.querySelectorAll('style[data-plainwire-extension-theme]').forEach((node) => node.remove());
    const { themes } = readExtensions();
    const active = themes.filter((theme) => theme.enabled === true);
    if (!active.length) return;
    const less = await loadLessCompiler();
    for (const theme of active) {
      try {
        const source = validateThemeSource(String(theme.source || ''));
        const result = await less.render(source, { javascriptEnabled: false, math: 'parens-division' });
        const style = document.createElement('style');
        style.dataset.plainwireExtensionTheme = String(theme.id || 'theme');
        style.textContent = result.css;
        document.head.append(style);
      } catch (error) {
        console.warn('[Plainwire:EXT] theme_failed', theme?.name, error);
      }
    }
  };
  const stopClientPlugins = () => {
    extensionWorkers.forEach((worker) => { try { worker.terminate(); } catch (_) {} });
    extensionWorkers.clear();
  };
  const pluginStorageKey = (id, key) => `plainwire_plugin_${String(id).slice(0, 80)}_${String(key).slice(0, 120)}`;
  const createPluginWorker = (plugin) => {
    const source = String(plugin.source || '');
    const permissions = Object.freeze({ apiWrite: plugin?.permissions?.apiWrite === true });
    if (!source.trim() || source.length > 262144) throw new Error('Plugin source must be between 1 byte and 256 KiB.');
    const bootstrap = `
      'use strict';
      const __pending = new Map(); let __seq = 0;
      try { self.fetch = undefined; self.XMLHttpRequest = undefined; self.WebSocket = undefined; self.EventSource = undefined; self.importScripts = undefined; } catch (_) {}
      const rpc = (op, data={}) => new Promise((resolve,reject)=>{ const id=++__seq; __pending.set(id,{resolve,reject}); postMessage({kind:'rpc',id,op,data}); });
      const Plainwire = Object.freeze({
        version: ${JSON.stringify(clientConfig.version)},
        toast(text){ postMessage({kind:'toast',text:String(text).slice(0,500)}); },
        request(path, options={}){ return rpc('request',{path:String(path),method:String(options.method||'GET'),body:options.body??null}); },
        insertText(text){ postMessage({kind:'insert_text',text:String(text).slice(0,5000)}); },
        storage: Object.freeze({ get(key){ return rpc('storage_get',{key:String(key)}); }, set(key,value){ return rpc('storage_set',{key:String(key),value}); }, remove(key){ return rpc('storage_remove',{key:String(key)}); } })
      });
      self.onmessage = (event)=>{ const m=event.data||{}; if(m.kind==='rpc_result'){ const p=__pending.get(m.id); if(!p)return; __pending.delete(m.id); m.ok?p.resolve(m.value):p.reject(new Error(m.error||'plugin_rpc_failed')); } };
      try { (new Function('Plainwire', ${JSON.stringify(source)}))(Plainwire); postMessage({kind:'ready'}); }
      catch (error) { postMessage({kind:'error',error:String(error?.stack||error)}); }
    `;
    const url = URL.createObjectURL(new Blob([bootstrap], { type: 'text/javascript' }));
    const worker = new Worker(url, { name: `Plainwire plugin: ${String(plugin.name || plugin.id || 'plugin').slice(0, 80)}` });
    URL.revokeObjectURL(url);
    worker.addEventListener('message', async (event) => {
      const msg = event.data || {};
      if (msg.kind === 'toast') { send(app.ports.bridgeReceive, { tag: 'toast', data: String(msg.text || '').slice(0, 500) }); return; }
      if (msg.kind === 'insert_text') { insertIntoComposer(String(msg.text || '').slice(0, 5000)); return; }
      if (msg.kind === 'error') { console.error('[Plainwire:EXT] plugin_error', plugin.name, msg.error); return; }
      if (msg.kind !== 'rpc') return;
      const respond = (ok, value, error = '') => worker.postMessage({ kind: 'rpc_result', id: msg.id, ok, value, error });
      try {
        if (msg.op === 'request') {
          const path = String(msg.data?.path || '');
          if (!/^\/[A-Za-z0-9_?&=.%+\-\/]*$/.test(path) || path.includes('..')) throw new Error('Only same-origin Plainwire API paths are allowed.');
          const method = String(msg.data?.method || 'GET').toUpperCase();
          if (!['GET','POST','DELETE'].includes(method)) throw new Error('Unsupported plugin request method.');
          if (method !== 'GET' && !permissions.apiWrite) throw new Error('This plugin has read-only API access. Grant API write access in plugin settings to allow changes.');
          const value = await directApi(path, { method, body: msg.data?.body ?? null, timeoutMs: 15000 }); respond(true, value);
        } else if (msg.op === 'storage_get') {
          const raw = storage.getItem(pluginStorageKey(plugin.id, msg.data?.key)); respond(true, raw === null ? null : JSON.parse(raw));
        } else if (msg.op === 'storage_set') {
          const raw = JSON.stringify(msg.data?.value ?? null); if (raw.length > 65536) throw new Error('Plugin storage value too large.'); storage.setItem(pluginStorageKey(plugin.id, msg.data?.key), raw); respond(true, true);
        } else if (msg.op === 'storage_remove') {
          storage.removeItem(pluginStorageKey(plugin.id, msg.data?.key)); respond(true, true);
        } else throw new Error('Unsupported plugin operation.');
      } catch (error) { respond(false, null, String(error?.message || error).slice(0, 500)); }
    });
    return worker;
  };
  const startClientPlugins = () => {
    stopClientPlugins();
    const { plugins } = readExtensions();
    for (const plugin of plugins.filter((item) => item.enabled === true)) {
      try { extensionWorkers.set(plugin.id, createPluginWorker(plugin)); }
      catch (error) { console.error('[Plainwire:EXT] plugin_start_failed', plugin?.name, error); }
    }
  };
  const applyClientExtensions = async () => { await applyClientThemes(); startClientPlugins(); };

  const openExtensionsManager = async () => {
    const shell = modalShell('Themes & plugins', "Client extensions live only in this browser. Themes use Less; plugins run in a Worker under Plainwire's restrictive network policy and use an explicit Plainwire capability API.");
    let activeTab = 'themes';
    const renderEditor = (kind, existing = null) => {
      const isTheme = kind === 'themes';
      const wrap = document.createElement('form'); wrap.className = 'admin-form-stack';
      const name = makeField(isTheme ? 'Theme name' : 'Plugin name', existing?.name || '', { maxLength: 80 });
      const source = makeField(isTheme ? 'Less source' : 'Plugin JavaScript', existing?.source || '', { multiline: true, maxLength: isTheme ? 131072 : 262144 });
      source.input.rows = 15; source.input.spellcheck = false;
      source.input.placeholder = isTheme ? ':root { --pw-accent: #7c5cff; }' : "Plainwire.toast('plugin loaded');";
      const status = document.createElement('div'); status.className = 'admin-inline-message muted';
      let apiWrite = null;
      if (!isTheme) {
        const permission = document.createElement('label'); permission.className = 'admin-permission';
        apiWrite = document.createElement('input'); apiWrite.type = 'checkbox'; apiWrite.checked = existing?.permissions?.apiWrite === true;
        const permissionCopy = document.createElement('span');
        const permissionTitle = document.createElement('strong'); permissionTitle.textContent = 'Allow API write access';
        const permissionHint = document.createElement('small'); permissionHint.textContent = 'Lets this plugin perform POST/DELETE actions as your signed-in account. Leave off unless you trust the plugin.';
        permissionCopy.append(permissionTitle, permissionHint); permission.append(apiWrite, permissionCopy); wrap.append(permission);
      }
      const actions = document.createElement('div'); actions.className = 'admin-row-actions';
      const cancel = document.createElement('button'); cancel.type='button'; cancel.className='btn secondary'; cancel.textContent='Cancel'; cancel.addEventListener('click', render);
      const save = document.createElement('button'); save.type='submit'; save.className='btn'; save.textContent='Save';
      actions.append(cancel, save);
      const existingPermission = apiWrite ? wrap.lastElementChild : null;
      wrap.replaceChildren(name.label, source.label);
      if (existingPermission) wrap.append(existingPermission);
      wrap.append(status, actions);
      wrap.addEventListener('submit', async (event) => {
        event.preventDefault();
        const cleanName = name.input.value.trim(); if (cleanName.length < 2) { status.textContent='Use a name with at least 2 characters.'; return; }
        try { if (isTheme) validateThemeSource(source.input.value); else if (!source.input.value.trim() || source.input.value.length > 262144) throw new Error('Plugin source must be between 1 byte and 256 KiB.'); }
        catch (error) { status.textContent=error.message; status.className='admin-inline-message error'; return; }
        const wantsApiWrite = !isTheme && apiWrite?.checked === true;
        if (wantsApiWrite && existing?.permissions?.apiWrite !== true && !window.confirm('Grant this plugin API write access? It will be able to perform account actions through Plainwire as you. Only continue if you trust its source.')) return;
        const all = readExtensions(); const list = all[kind];
        const item = { id: existing?.id || extensionId(), name: cleanName, source: source.input.value, enabled: existing?.enabled !== false,
          ...(isTheme ? {} : { permissions: { apiWrite: wantsApiWrite } }), updatedAt: Date.now() };
        const index = list.findIndex((entry) => entry.id === item.id); if (index >= 0) list[index]=item; else list.push(item);
        writeExtensions(all); save.disabled=true;
        try { await applyClientExtensions(); render(); }
        catch (error) { status.textContent=error.message; status.className='admin-inline-message error'; save.disabled=false; }
      });
      shell.body.replaceChildren(wrap);
    };
    const render = () => {
      shell.body.replaceChildren();
      const nav = document.createElement('nav'); nav.className='admin-tabs';
      [['themes','Themes'],['plugins','Plugins']].forEach(([id,label])=>{ const b=document.createElement('button'); b.type='button'; b.textContent=label; b.classList.toggle('active',activeTab===id); b.addEventListener('click',()=>{activeTab=id;render()}); nav.append(b); });
      const panel=document.createElement('div'); panel.className='admin-panel'; const all=readExtensions(); const list=all[activeTab] || [];
      const info=document.createElement('p'); info.className='muted'; info.textContent = activeTab==='themes' ? 'Less themes can style the entire Plainwire client. Imports and Less JavaScript are disabled.' : "Plugins have no DOM access. Their Plainwire.request API is read-only by default; write access must be granted explicitly. Outbound connections are restricted by Plainwire's same-origin Content Security Policy.";
      const add=document.createElement('button'); add.type='button'; add.className='btn'; add.textContent=activeTab==='themes'?'Add theme':'Add plugin'; add.addEventListener('click',()=>renderEditor(activeTab)); panel.append(info,add);
      const stack=document.createElement('div'); stack.className='admin-role-stack';
      for (const item of list) {
        const row=document.createElement('section'); row.className='admin-role-card'; const head=document.createElement('div'); head.className='admin-role-head'; const copy=document.createElement('div'); const strong=document.createElement('strong'); strong.textContent=item.name || 'Unnamed'; const small=document.createElement('small'); small.textContent = activeTab === 'plugins' ? `${item.enabled ? 'Enabled' : 'Disabled'} · ${item.permissions?.apiWrite === true ? 'API write access' : 'read-only API'}` : (item.enabled?'Enabled':'Disabled'); copy.append(strong,small);
        const controls=document.createElement('div'); controls.className='admin-row-actions';
        const toggle=document.createElement('button'); toggle.type='button'; toggle.className='btn secondary'; toggle.textContent=item.enabled?'Disable':'Enable'; toggle.addEventListener('click',async()=>{ const next=readExtensions(); const entry=next[activeTab].find((x)=>x.id===item.id); if(entry) entry.enabled=!entry.enabled; writeExtensions(next); await applyClientExtensions(); render(); });
        const edit=document.createElement('button'); edit.type='button'; edit.className='btn secondary'; edit.textContent='Edit'; edit.addEventListener('click',()=>renderEditor(activeTab,item));
        const remove=document.createElement('button'); remove.type='button'; remove.className='btn danger'; remove.textContent='Remove'; remove.addEventListener('click',async()=>{ if(!window.confirm(`Remove ${item.name}?`)) return; const next=readExtensions(); next[activeTab]=next[activeTab].filter((x)=>x.id!==item.id); writeExtensions(next); await applyClientExtensions(); render(); });
        controls.append(toggle,edit,remove); head.append(copy,controls); row.append(head); stack.append(row);
      }
      if(!list.length) adminMessage(stack, activeTab==='themes'?'No client themes installed.':'No client plugins installed.'); panel.append(stack); shell.body.append(nav,panel);
    };
    render();
  };

  const openServerProfileRoleEditor = async (payload) => {
    const serverId = Number(payload?.server_id);
    const userId = Number(payload?.user_id);
    if (!Number.isInteger(serverId) || serverId <= 0 || !Number.isInteger(userId) || userId <= 0) throw new Error('invalid_member');
    const [state, profile] = await Promise.all([
      directApi(`/server/${serverId}/roles`),
      directApi(`/server/${serverId}/member/${userId}/profile`)
    ]);
    const member = (state?.members || []).find((item) => Number(item?.user?.id) === userId);
    if (!member) throw new Error('member_not_found');
    const current = new Set((member.role_ids || []).map(Number));
    const shell = modalShell(`Roles for ${member.nickname || member.user?.display_name || member.user?.username || 'member'}`,
      'Changes are validated against Plainwire role hierarchy on the server.');
    const form = document.createElement('form'); form.className = 'admin-form-stack server-profile-role-editor';
    const list = document.createElement('div'); list.className = 'admin-member-roles';
    for (const role of state?.roles || []) {
      const label = document.createElement('label'); label.className = 'admin-permission';
      const input = document.createElement('input'); input.type = 'checkbox'; input.checked = current.has(Number(role.id)); input.dataset.roleId = String(role.id);
      const copy = document.createElement('span');
      const strong = document.createElement('strong'); strong.textContent = role.name || 'Role'; strong.style.color = role.color || '';
      const small = document.createElement('small'); small.textContent = `Position ${Number(role.position || 0)}`;
      copy.append(strong, small); label.append(input, copy); list.append(label);
    }
    if (!(state?.roles || []).length) adminMessage(list, 'This server has no custom roles yet.');
    const status = document.createElement('div'); status.className = 'account-dialog-status';
    const actions = document.createElement('div'); actions.className = 'admin-row-actions';
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn secondary'; cancel.textContent = 'Cancel'; cancel.addEventListener('click', () => shell.destroy());
    const save = document.createElement('button'); save.type = 'submit'; save.className = 'btn'; save.textContent = 'Save roles';
    actions.append(cancel, save); form.append(list, status, actions); shell.body.append(form);
    form.addEventListener('submit', async (event) => {
      event.preventDefault(); save.disabled = true; status.textContent = '';
      const ids = [...list.querySelectorAll('input:checked')].map((input) => Number(input.dataset.roleId));
      try {
        await directApi(`/server/${serverId}/member/${userId}/roles`, { method: 'POST', body: { role_ids: ids } });
        shell.destroy();
        await Promise.allSettled([api({ method: 'GET', path: `/server/${serverId}` }), api({ method: 'GET', path: `/server/${serverId}/member/${userId}/profile` })]);
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Member roles updated' });
      } catch (error) {
        status.textContent = ({ role_hierarchy: 'You cannot assign a role at or above your highest manageable role.', owner_role_locked: 'The owner role cannot be reassigned.', forbidden: 'You do not have permission to edit this member’s roles.' })[error.message] || `Could not update roles: ${error.message}`;
        save.disabled = false;
      }
    });
  };

  const openGroupAdmin = async (conversationId) => {
    if (!Number.isInteger(Number(conversationId)) || Number(conversationId) <= 0) return;
    const shell = modalShell('Group moderation', 'Manage roles and membership without leaving the conversation.');
    const render = async () => {
      shell.body.replaceChildren(); adminMessage(shell.body, 'Loading group members…');
      try {
        const data = await directApi(`/conversation/${conversationId}`);
        const conversation = data?.conversation || {}; const members = Array.isArray(data?.members) ? data.members : [];
        shell.setTitle(conversation.name || 'Group moderation'); shell.body.replaceChildren();
        const me = members.find(member => Number(member.user?.id) === Number(meId));
        const actorRole = me?.role || me?.group_role || (Number(conversation.owner_id) === Number(meId) ? 'owner' : 'member');
        const intro = document.createElement('div'); intro.className = 'admin-summary';
        const memberCount = document.createElement('strong'); memberCount.textContent = `${members.length} members`;
        const roleSummary = document.createElement('span'); roleSummary.textContent = `Your role: ${actorRole}`;
        intro.append(memberCount, roleSummary); shell.body.append(intro);
        const list = document.createElement('div'); list.className = 'admin-member-list';
        const roleRank = role => ({ owner: 3, moderator: 2, member: 1 }[role] || 1);
        for (const member of members) {
          const user = member.user || {}; const role = member.role || member.group_role || (Number(user.id) === Number(conversation.owner_id) ? 'owner' : 'member');
          const row = document.createElement('div'); row.className = 'admin-member-row';
          const avatar = document.createElement(user.avatar_url ? 'img' : 'div'); avatar.className = 'admin-member-avatar';
          if (user.avatar_url) { avatar.src = user.avatar_url; avatar.alt = ''; } else avatar.textContent = String(user.display_name || user.username || '?').slice(0, 1).toUpperCase();
          const text = document.createElement('button'); text.type = 'button'; text.className = 'admin-member-name'; text.innerHTML = `<strong></strong><span></span>`; text.querySelector('strong').textContent = user.display_name || user.username || 'Unknown'; text.querySelector('span').textContent = `@${user.username || ''} · ${role}`; text.addEventListener('click', () => { location.hash = `#profile/${user.id}`; shell.destroy(); });
          const actions = document.createElement('div'); actions.className = 'admin-row-actions';
          const canManage = Number(user.id) !== Number(meId) && roleRank(actorRole) > roleRank(role) && ['owner','moderator'].includes(actorRole);
          if (actorRole === 'owner' && Number(user.id) !== Number(meId) && role !== 'owner') {
            const roleButton = document.createElement('button'); roleButton.type = 'button'; roleButton.className = 'btn secondary'; roleButton.textContent = role === 'moderator' ? 'Make member' : 'Make moderator';
            roleButton.addEventListener('click', async () => {
              roleButton.disabled = true;
              try { await directApi(`/conversation/${conversationId}/member/${user.id}/role`, { method: 'POST', body: { role: role === 'moderator' ? 'member' : 'moderator' } }); await api({ method: 'GET', path: `/conversation/${conversationId}` }); await render(); }
              catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not change role: ${error.message}` }); roleButton.disabled = false; }
            }); actions.append(roleButton);
          }
          if (canManage) {
            const kick = document.createElement('button'); kick.type = 'button'; kick.className = 'btn danger'; kick.textContent = 'Kick';
            kick.addEventListener('click', async () => {
              if (!window.confirm(`Remove ${user.display_name || user.username} from this group?`)) return;
              kick.disabled = true;
              try { await directApi(`/conversation/${conversationId}/member/${user.id}/kick`, { method: 'POST', body: {} }); await api({ method: 'GET', path: '/sync?since=0' }); await api({ method: 'GET', path: `/conversation/${conversationId}` }); await render(); }
              catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not kick member: ${error.message}` }); kick.disabled = false; }
            }); actions.append(kick);
          }
          row.append(avatar, text, actions); list.append(row);
        }
        shell.body.append(list);
        if (actorRole === 'member') adminMessage(shell.body, 'Only the group owner and moderators can remove members. The owner can promote or demote moderators.');
      } catch (error) {
        shell.body.replaceChildren(); adminMessage(shell.body, `Could not load group moderation: ${error.message}`, 'error');
      }
    };
    await render();
  };

  const openServerAdmin = async (serverId) => {
    serverId = Number(serverId); if (!Number.isInteger(serverId) || serverId <= 0) return;
    const shell = modalShell('Server settings', 'Roles, member profiles, moderation, Wires, and server identity.');
    let state = null; let serverData = null; let activeTab = 'profile'; let lastWireUrl = '';
    const refresh = async () => {
      [state, serverData] = await Promise.all([directApi(`/server/${serverId}/roles`), directApi(`/server/${serverId}`)]);
    };
    const memberRank = (member) => {
      if (!member) return -1;
      if (member.legacy_role === 'owner') return 1_000_000;
      if (member.legacy_role === 'admin') return 10_000;
      const assigned = new Set((member.role_ids || []).map(Number));
      return Math.max(0, ...(state?.roles || []).filter(role => assigned.has(Number(role.id))).map(role => Number(role.position) || 0));
    };
    const actorMember = () => (state?.members || []).find(member => Number(member.user?.id) === Number(meId));
    const actorOwnsServer = () => actorMember()?.legacy_role === 'owner';
    const canActOnMember = (member) => {
      const actor = actorMember();
      if (!actor || !member || Number(member.user?.id) === Number(meId) || member.legacy_role === 'owner') return false;
      return actorOwnsServer() || memberRank(actor) > memberRank(member);
    };
    const canEditMemberRoles = (member) => canActOnMember(member) || (actorOwnsServer() && Number(member?.user?.id) === Number(meId));
    const canEditRole = (role) => {
      if (!hasPermission(state, 'manage_roles')) return false;
      return actorOwnsServer() || memberRank(actorMember()) > Number(role?.position || 0);
    };
    const canAssignRole = (role) => actorOwnsServer() || memberRank(actorMember()) > Number(role?.position || 0);
    const actionButton = (label, handler, danger = false) => {
      const b = document.createElement('button'); b.type = 'button'; b.className = danger ? 'btn danger' : 'btn secondary'; b.textContent = label; b.addEventListener('click', handler); return b;
    };
    const renderOverview = () => {
      const server = serverData?.server || {}; const canManage = hasPermission(state, 'manage_server');
      const wrap = document.createElement('div'); wrap.className = 'admin-form-stack';
      const name = makeField('Server name', server.name || '', { maxLength: 80 }); const description = makeField('Description', server.description || '', { multiline: true, maxLength: 280 });
      const icon = makeField('Icon URL', server.icon_url || '', { placeholder: 'https://…' }); const banner = makeField('Banner URL', server.banner_url || '', { placeholder: 'https://…' }); const accent = makeField('Accent color', server.accent_color || '#5865f2', { type: 'color' }); const welcome = makeField('Welcome message', server.welcome_message || '', { multiline: true, maxLength: 2000 });
      [name,description,icon,banner,accent,welcome].forEach(field => { field.input.disabled = !canManage; wrap.append(field.label); });
      if (canManage) wrap.append(actionButton('Save server', async event => {
        event.currentTarget.disabled = true;
        try { await directApi(`/server/${serverId}`, { method: 'POST', body: { name: name.input.value, description: description.input.value, icon_url: icon.input.value, banner_url: banner.input.value, accent_color: accent.input.value, welcome_message: welcome.input.value } }); await refresh(); await api({ method: 'GET', path: `/server/${serverId}` }); render(); send(app.ports.bridgeReceive, { tag: 'toast', data: 'Server updated' }); }
        catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not update server: ${error.message}` }); event.currentTarget.disabled = false; }
      })); else adminMessage(wrap, 'You can view these settings, but your roles do not grant Manage Server.');
      return wrap;
    };
    const renderProfile = () => {
      const member = (state?.members || []).find(item => Number(item.user?.id) === Number(meId));
      const wrap = document.createElement('div'); wrap.className = 'admin-form-stack';
      const nick = makeField('Nickname in this server', member?.nickname || '', { maxLength: 80, placeholder: member?.user?.display_name || '' });
      const avatar = makeField('Server avatar URL', member?.server_avatar_url || '', { placeholder: 'Leave blank to use your profile avatar' });
      const bio = makeField('Server bio', member?.server_bio || '', { multiline: true, maxLength: 280 });
      wrap.append(nick.label, avatar.label, bio.label);
      wrap.append(actionButton('Save server profile', async event => {
        event.currentTarget.disabled = true;
        try { await directApi(`/server/${serverId}/member/${meId}/profile`, { method: 'POST', body: { nickname: nick.input.value, avatar_url: avatar.input.value, bio: bio.input.value } }); await refresh(); await api({ method: 'GET', path: `/server/${serverId}` }); render(); send(app.ports.bridgeReceive, { tag: 'toast', data: 'Server profile saved' }); }
        catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not save server profile: ${error.message}` }); event.currentTarget.disabled = false; }
      }));
      adminMessage(wrap, 'This identity is scoped to this server; your global Plainwire profile stays unchanged.');
      return wrap;
    };
    const renderRoles = () => {
      const wrap = document.createElement('div'); wrap.className = 'admin-role-stack'; const canManage = hasPermission(state, 'manage_roles');

      const baseline = document.createElement('section');
      baseline.className = 'admin-role-card admin-default-permissions';
      const baselineHead = document.createElement('div');
      baselineHead.className = 'admin-default-permissions-head';
      const baselineCopy = document.createElement('div');
      const baselineTitle = document.createElement('strong'); baselineTitle.textContent = 'Default member permissions';
      const baselineHint = document.createElement('small'); baselineHint.textContent = 'Applied to every ordinary server member before custom roles are added.';
      baselineCopy.append(baselineTitle, baselineHint); baselineHead.append(baselineCopy); baseline.append(baselineHead);
      const baselineGrid = document.createElement('div'); baselineGrid.className = 'admin-permission-grid';
      for (const permission of state?.catalog || []) {
        if (permission.key === 'administrator') continue;
        const label = document.createElement('label'); label.className = 'admin-permission';
        const input = document.createElement('input'); input.type = 'checkbox';
        input.checked = (Number(state?.default_permissions || 0) & Number(permission.bit || 0)) !== 0;
        input.disabled = !actorOwnsServer(); input.dataset.permissionBit = String(permission.bit || 0);
        const copy = document.createElement('span'); copy.innerHTML = '<strong></strong><small></small>';
        copy.querySelector('strong').textContent = permission.label || permission.key;
        copy.querySelector('small').textContent = permission.description || '';
        label.append(input, copy); baselineGrid.append(label);
      }
      baseline.append(baselineGrid);
      if (actorOwnsServer()) {
        baseline.append(actionButton('Save default permissions', async event => {
          let mask = 0;
          baselineGrid.querySelectorAll('input:checked').forEach(input => { mask |= Number(input.dataset.permissionBit || 0); });
          event.currentTarget.disabled = true;
          try {
            await directApi(`/server/${serverId}/default-permissions`, { method: 'POST', body: { permissions: mask } });
            await refresh();
            await api({ method: 'GET', path: `/server/${serverId}` });
            render();
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Default member permissions saved' });
          } catch (error) {
            send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not save default permissions: ${error.message}` });
            event.currentTarget.disabled = false;
          }
        }));
      } else {
        adminMessage(baseline, 'Only the server owner can change the permissions every member starts with.');
      }
      wrap.append(baseline);

      if (canManage) {
        const create = document.createElement('form'); create.className = 'admin-role-create';
        const name = document.createElement('input'); name.placeholder = 'New role name'; name.maxLength = 40; const color = document.createElement('input'); color.type = 'color'; color.value = '#99aab5'; const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'btn'; submit.textContent = 'Create role'; create.append(name,color,submit);
        create.addEventListener('submit', async event => { event.preventDefault(); if (name.value.trim().length < 2) return; submit.disabled = true; try { await directApi(`/server/${serverId}/roles`, { method: 'POST', body: { name: name.value.trim(), color: color.value, permissions: 0, hoist: false, mentionable: false } }); await refresh(); render(); } catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not create role: ${error.message}` }); submit.disabled = false; } });
        wrap.append(create);
      }
      for (const role of state?.roles || []) {
        const editable = canEditRole(role);
        const card = document.createElement('details'); card.className = 'admin-role-card';
        const summary = document.createElement('summary'); const dot = document.createElement('i'); dot.style.background = role.color || '#99aab5'; const text = document.createElement('span'); text.textContent = role.name; const meta = document.createElement('small'); meta.textContent = `position ${role.position}`; summary.append(dot,text,meta); card.append(summary);
        const form = document.createElement('div'); form.className = 'admin-role-editor';
        const name = makeField('Name', role.name, { maxLength: 40 }); const color = makeField('Color', role.color || '#99aab5', { type: 'color' }); const pos = makeField('Position', String(role.position || 1), { type: 'number' });
        [name,color,pos].forEach(field => { field.input.disabled = !editable; form.append(field.label); });
        const toggles = document.createElement('div'); toggles.className = 'admin-permission-grid';
        for (const permission of state?.catalog || []) {
          const label = document.createElement('label'); label.className = 'admin-permission'; const input = document.createElement('input'); input.type = 'checkbox'; input.checked = (Number(role.permissions || 0) & Number(permission.bit || 0)) !== 0; input.disabled = !editable || (permission.key === 'administrator' && !actorOwnsServer()); input.dataset.permissionBit = String(permission.bit || 0); const copy = document.createElement('span'); copy.innerHTML = '<strong></strong><small></small>'; copy.querySelector('strong').textContent = permission.label || permission.key; copy.querySelector('small').textContent = permission.description || ''; label.append(input,copy); toggles.append(label);
        }
        form.append(toggles);
        if (editable) {
          const actions = document.createElement('div'); actions.className = 'admin-row-actions';
          actions.append(actionButton('Save', async event => { let mask = 0; toggles.querySelectorAll('input:checked').forEach(input => { mask |= Number(input.dataset.permissionBit || 0); }); event.currentTarget.disabled = true; try { await directApi(`/server/${serverId}/role/${role.id}`, { method: 'POST', body: { name: name.input.value, color: color.input.value, position: Number(pos.input.value || role.position), permissions: mask } }); await refresh(); render(); } catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not save role: ${error.message}` }); event.currentTarget.disabled = false; } }), actionButton('Delete', async () => { if (!confirm(`Delete role “${role.name}”?`)) return; try { await directApi(`/server/${serverId}/role/${role.id}/delete`, { method: 'POST', body: {} }); await refresh(); render(); } catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not delete role: ${error.message}` }); } }, true)); form.append(actions);
        }
        card.append(form); wrap.append(card);
      }
      if (!(state?.roles || []).length) adminMessage(wrap, canManage ? 'No custom roles yet.' : 'This server has no custom roles you can view.');
      return wrap;
    };
    const renderMembers = () => {
      const wrap = document.createElement('div'); wrap.className = 'admin-member-list'; const canRoles = hasPermission(state, 'manage_roles'); const canKick = hasPermission(state, 'kick_members'); const canBan = hasPermission(state, 'ban_members'); const canProfiles = hasPermission(state, 'manage_profiles');
      const roles = state?.roles || [];
      for (const member of state?.members || []) {
        const row = document.createElement('div'); row.className = 'admin-member-card'; const top = document.createElement('div'); top.className = 'admin-member-row';
        const avatar = document.createElement(member.server_avatar_url || member.user?.avatar_url ? 'img' : 'div'); avatar.className = 'admin-member-avatar'; if (avatar instanceof HTMLImageElement) { avatar.src = member.server_avatar_url || member.user.avatar_url; avatar.alt=''; } else avatar.textContent = String(member.nickname || member.user?.display_name || '?').slice(0,1).toUpperCase();
        const copy = document.createElement('div'); copy.className = 'admin-member-copy'; const strong=document.createElement('strong'); strong.textContent=member.nickname || member.user?.display_name || member.user?.username || 'Unknown'; const small=document.createElement('small'); small.textContent=`@${member.user?.username || ''} · ${member.legacy_role || 'member'}`; copy.append(strong,small); top.append(avatar,copy); row.append(top);
        if (canRoles && canEditMemberRoles(member)) {
          const roleBox = document.createElement('div'); roleBox.className='admin-member-roles';
          roles.forEach(role => {
            const label=document.createElement('label'); const cb=document.createElement('input'); cb.type='checkbox';
            cb.checked=(member.role_ids||[]).map(Number).includes(Number(role.id)); cb.dataset.roleId=String(role.id);
            cb.disabled=!canAssignRole(role);
            if (cb.disabled) label.title='This role is at or above your highest role.';
            label.append(cb,document.createTextNode(role.name)); roleBox.append(label);
          });
          const save=actionButton('Save roles',async event=>{ const ids=[...roleBox.querySelectorAll('input:checked')].map(input=>Number(input.dataset.roleId)); event.currentTarget.disabled=true; try{ await directApi(`/server/${serverId}/member/${member.user.id}/roles`,{method:'POST',body:{role_ids:ids}}); await refresh(); render(); }catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:`Could not assign roles: ${error.message}`});event.currentTarget.disabled=false;} }); roleBox.append(save); row.append(roleBox);
        }
        const actions=document.createElement('div');actions.className='admin-row-actions';
        if (canProfiles && canActOnMember(member)) actions.append(actionButton('Edit server profile',()=>{
          const editor=modalShell(`Edit ${member.nickname || member.user?.display_name || member.user?.username || 'member'}`, 'This identity is visible only inside this server.');
          const form=document.createElement('form');form.className='admin-form-stack';
          const nick=makeField('Server nickname',member.nickname||'',{maxLength:80,placeholder:member.user?.display_name||''});
          const avatarField=makeField('Server avatar URL',member.server_avatar_url||'',{placeholder:'Leave blank to use their global avatar'});
          const bio=makeField('Server bio',member.server_bio||'',{multiline:true,maxLength:280});
          const buttons=document.createElement('div');buttons.className='admin-row-actions';
          const cancel=actionButton('Cancel',()=>editor.destroy()); const save=actionButton('Save profile',async event=>{event.preventDefault();save.disabled=true;try{await directApi(`/server/${serverId}/member/${member.user.id}/profile`,{method:'POST',body:{nickname:nick.input.value,bio:bio.input.value,avatar_url:avatarField.input.value}});await refresh();await api({method:'GET',path:`/server/${serverId}`});editor.destroy();render();send(app.ports.bridgeReceive,{tag:'toast',data:'Server profile updated'});}catch(error){adminMessage(form,`Could not update profile: ${error.message}`,'error');save.disabled=false;}});
          buttons.append(cancel,save);form.append(nick.label,avatarField.label,bio.label,buttons);editor.body.append(form);
        }));
        if (canKick && canActOnMember(member)) actions.append(actionButton('Kick',async()=>{if(!confirm(`Kick ${member.user?.display_name||member.user?.username} from this server?`))return;try{await directApi(`/server/${serverId}/member/${member.user.id}/kick`,{method:'POST',body:{}});await refresh();await api({method:'GET',path:`/server/${serverId}`});render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:`Could not kick member: ${error.message}`});}},true));
        if (canBan && canActOnMember(member)) actions.append(actionButton('Ban',async()=>{if(!confirm(`Ban ${member.user?.display_name||member.user?.username} from this server? They will be unable to rejoin with a Wire until unbanned.`))return;const reason=(prompt('Ban reason (optional):','')||'').trim().slice(0,512);try{await directApi(`/server/${serverId}/member/${member.user.id}/ban`,{method:'POST',body:{reason}});await refresh();await api({method:'GET',path:`/server/${serverId}`});render();send(app.ports.bridgeReceive,{tag:'toast',data:'Member banned'});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:`Could not ban member: ${error.message}`});}},true));
        if(actions.children.length)row.append(actions); wrap.append(row);
      }
      return wrap;
    };
    const renderBans = () => {
      const wrap = document.createElement('div'); wrap.className = 'admin-form-stack';
      if (!hasPermission(state, 'ban_members')) { adminMessage(wrap, 'Your roles do not grant Ban Members.'); return wrap; }
      const list = document.createElement('div'); list.className = 'admin-member-list'; list.setAttribute('aria-busy','true'); wrap.append(list);
      directApi(`/server/${serverId}/bans`).then(items => {
        list.replaceChildren(); list.removeAttribute('aria-busy');
        const bans = Array.isArray(items) ? items : [];
        for (const ban of bans) {
          const row=document.createElement('div'); row.className='admin-member-card';
          const top=document.createElement('div'); top.className='admin-member-row';
          const avatar=document.createElement(ban.avatar_url ? 'img':'div'); avatar.className='admin-member-avatar';
          if (avatar instanceof HTMLImageElement) { avatar.src=ban.avatar_url; avatar.alt=''; } else avatar.textContent=String(ban.display_name||ban.username||'?').slice(0,1).toUpperCase();
          const copy=document.createElement('div'); copy.className='admin-member-copy';
          const strong=document.createElement('strong'); strong.textContent=ban.display_name||ban.username||'Unknown';
          const small=document.createElement('small'); small.textContent=`@${ban.username||''}${ban.banned_by_username ? ` · banned by @${ban.banned_by_username}` : ''}`;
          copy.append(strong,small); if (ban.reason) { const reason=document.createElement('p'); reason.className='muted'; reason.textContent=ban.reason; copy.append(reason); }
          top.append(avatar,copy); row.append(top);
          const actions=document.createElement('div'); actions.className='admin-row-actions';
          actions.append(actionButton('Unban', async event => { event.currentTarget.disabled=true; try { await directApi(`/server/${serverId}/member/${ban.user_id}/unban`,{method:'POST',body:{}}); render(); send(app.ports.bridgeReceive,{tag:'toast',data:'Member unbanned'}); } catch(error) { send(app.ports.bridgeReceive,{tag:'toast',data:`Could not unban member: ${error.message}`}); event.currentTarget.disabled=false; } }));
          row.append(actions); list.append(row);
        }
        if (!bans.length) adminMessage(list,'No banned members.');
      }).catch(error => { list.removeAttribute('aria-busy'); adminMessage(list,`Could not load bans: ${error.message}`,'error'); });
      return wrap;
    };
    const renderWires = () => {
      const wrap = document.createElement('div');
      wrap.className = 'admin-form-stack';
      const canCreate = hasPermission(state, 'create_wires');
      const canManage = hasPermission(state, 'manage_wires');
      const channels = Array.isArray(serverData?.channels) ? serverData.channels : [];

      if (canCreate) {
        const controls = document.createElement('div');
        controls.className = 'wire-create-controls';

        const destination = document.createElement('select');
        destination.setAttribute('aria-label', 'Wire destination');
        const home = document.createElement('option');
        home.value = '';
        home.textContent = 'Server home';
        destination.append(home);
        for (const channel of channels) {
          const option = document.createElement('option');
          option.value = String(channel.id);
          option.textContent = `${channel.kind === 'voice' ? 'Voice' : 'Text'} · ${channel.name}`;
          destination.append(option);
        }

        const expiry = document.createElement('select');
        expiry.setAttribute('aria-label', 'Wire expiration');
        [[3600, '1 hour'], [86400, '1 day'], [604800, '7 days'], [2592000, '30 days'], [0, 'Never']]
          .forEach(([value, label]) => {
            const option = document.createElement('option');
            option.value = String(value);
            option.textContent = label;
            expiry.append(option);
          });
        expiry.value = '86400';

        const uses = document.createElement('input');
        uses.type = 'number';
        uses.min = '0';
        uses.max = '10000';
        uses.step = '1';
        uses.value = '0';
        uses.setAttribute('aria-label', 'Wire use limit');
        uses.title = '0 means unlimited uses';

        const create = actionButton('Create Wire', async event => {
          const button = event.currentTarget;
          button.disabled = true;
          const selectedChannel = Number(destination.value);
          const maxUses = Math.max(0, Math.min(10000, Number.parseInt(uses.value || '0', 10) || 0));
          const expiresIn = Math.max(0, Number.parseInt(expiry.value || '86400', 10) || 0);
          try {
            const data = await directApi(`/server/${serverId}/wires`, {
              method: 'POST',
              body: {
                channel_id: Number.isInteger(selectedChannel) && selectedChannel > 0 ? selectedChannel : null,
                max_uses: maxUses,
                expires_in: expiresIn
              }
            });
            lastWireUrl = new URL((data?.url || `#wire/${data?.code || ''}`).replace('#invite/', '#wire/'), location.origin + '/').href;
            let copied = false;
            try {
              await navigator.clipboard.writeText(lastWireUrl);
              copied = true;
            } catch (_) {}
            render();
            send(app.ports.bridgeReceive, { tag: 'toast', data: copied ? 'Wire created and copied' : 'Wire created. Use Copy Wire below.' });
          } catch (error) {
            send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not create Wire: ${error.message}` });
            button.disabled = false;
          }
        });
        controls.append(destination, expiry, uses, create);
        wrap.append(controls);

        if (lastWireUrl) {
          const result = document.createElement('div');
          result.className = 'wire-created-result';
          const input = document.createElement('input');
          input.readOnly = true;
          input.value = lastWireUrl;
          input.setAttribute('aria-label', 'Newest Wire link');
          input.addEventListener('focus', () => input.select());
          const copy = actionButton('Copy Wire', async () => {
            try {
              await navigator.clipboard.writeText(lastWireUrl);
              send(app.ports.bridgeReceive, { tag: 'toast', data: 'Wire copied' });
            } catch (_) {
              input.focus();
              input.select();
              send(app.ports.bridgeReceive, { tag: 'toast', data: 'Select the Wire link and copy it manually.' });
            }
          });
          result.append(input, copy);
          wrap.append(result);
        }
      } else {
        adminMessage(wrap, 'Your roles do not grant Create Wires.');
      }

      const list = document.createElement('div');
      list.className = 'wire-list';
      wrap.append(list);
      if (canManage) {
        list.setAttribute('aria-busy', 'true');
        directApi(`/server/${serverId}/wires`).then(items => {
          list.replaceChildren();
          list.removeAttribute('aria-busy');
          const wires = Array.isArray(items) ? items : items?.invites || [];
          const now = Date.now();
          for (const wire of wires) {
            const row = document.createElement('div');
            row.className = 'wire-row';
            const expired = Number(wire.expires_at || 0) > 0 && Number(wire.expires_at) <= now;
            const exhausted = Number(wire.max_uses || 0) > 0 && Number(wire.uses || 0) >= Number(wire.max_uses || 0);
            const inactive = wire.revoked === true || expired || exhausted;
            if (inactive) row.classList.add('inactive');

            const identity = document.createElement('div');
            identity.className = 'wire-row-identity';
            const code = document.createElement('code');
            code.textContent = wire.code || '';
            const channel = channels.find(item => Number(item.id) === Number(wire.channel_id));
            const channelText = document.createElement('small');
            channelText.textContent = channel ? `Opens ${channel.kind === 'voice' ? 'voice' : 'text'} · ${channel.name}` : 'Opens server home';
            identity.append(code, channelText);

            const meta = document.createElement('span');
            const usage = Number(wire.max_uses || 0) > 0 ? `${wire.uses || 0} / ${wire.max_uses} uses` : `${wire.uses || 0} uses`;
            const stateText = wire.revoked === true ? 'revoked' : expired ? 'expired' : exhausted ? 'used up' : 'active';
            meta.textContent = `${usage} · ${stateText}`;

            const copy = actionButton('Copy', async () => {
              const url = new URL(`#wire/${wire.code}`, location.origin + '/').href;
              try {
                await navigator.clipboard.writeText(url);
                send(app.ports.bridgeReceive, { tag: 'toast', data: 'Wire copied' });
              } catch (_) {
                lastWireUrl = url;
                render();
              }
            });
            copy.disabled = inactive;

            const revoke = actionButton('Revoke', async event => {
              event.currentTarget.disabled = true;
              try {
                await directApi(`/server/${serverId}/wires/${encodeURIComponent(wire.code)}`, { method: 'DELETE' });
                render();
              } catch (error) {
                send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not revoke Wire: ${error.message}` });
                event.currentTarget.disabled = false;
              }
            }, true);
            revoke.disabled = inactive;
            row.append(identity, meta, copy, revoke);
            list.append(row);
          }
          if (!list.children.length) adminMessage(list, 'No Wires have been created yet.');
        }).catch(error => {
          list.removeAttribute('aria-busy');
          adminMessage(list, `Could not load Wires: ${error.message}`, 'error');
        });
      } else {
        adminMessage(list, 'Your roles do not grant Manage Wires.');
      }
      return wrap;
    };
    const renderChannels = () => {
      const wrap=document.createElement('div'); wrap.className='admin-form-stack';
      const canManage=hasPermission(state,'manage_channels');
      const channels=Array.isArray(serverData?.channels)?serverData.channels:[];
      for(const channel of channels){
        const card=document.createElement('section'); card.className='admin-role-card';
        const head=document.createElement('div'); head.className='admin-role-head';
        const copy=document.createElement('div'); const strong=document.createElement('strong'); strong.textContent=`# ${channel.name}`;
        const small=document.createElement('small'); small.textContent=channel.kind==='voice'?'Voice channel':'Text channel'; copy.append(strong,small); head.append(copy); card.append(head);
        const name=makeField('Channel name',channel.name||'',{maxLength:40});
        const topic=makeField('Topic',channel.topic||'',{multiline:true,maxLength:1024,placeholder:'What is this channel for?'});
        name.input.disabled=!canManage; topic.input.disabled=!canManage;
        card.append(name.label,topic.label);
        if(channel.kind==='text'){
          const slow=document.createElement('label'); slow.className='admin-field'; const label=document.createElement('span'); label.textContent='Slowmode';
          const select=document.createElement('select'); select.disabled=!canManage;
          [[0,'Off'],[5,'5 seconds'],[10,'10 seconds'],[15,'15 seconds'],[30,'30 seconds'],[60,'1 minute'],[120,'2 minutes'],[300,'5 minutes'],[600,'10 minutes'],[1800,'30 minutes'],[3600,'1 hour'],[21600,'6 hours']].forEach(([value,text])=>{const option=document.createElement('option');option.value=String(value);option.textContent=text;if(Number(channel.slowmode_seconds||0)===value)option.selected=true;select.append(option)});
          slow.append(label,select); card.append(slow);
          if(canManage) card.append(actionButton('Save channel',async event=>{event.currentTarget.disabled=true;try{await directApi(`/channel/${channel.id}/settings`,{method:'POST',body:{name:name.input.value.trim(),topic:topic.input.value,slowmode_seconds:Number(select.value)}});await refresh();await api({method:'GET',path:`/server/${serverId}`});render();send(app.ports.bridgeReceive,{tag:'toast',data:'Channel settings saved'});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:`Could not save channel: ${error.message}`});event.currentTarget.disabled=false;}}));
        } else if(canManage) card.append(actionButton('Save channel',async event=>{event.currentTarget.disabled=true;try{await directApi(`/channel/${channel.id}/settings`,{method:'POST',body:{name:name.input.value.trim(),topic:topic.input.value}});await refresh();await api({method:'GET',path:`/server/${serverId}`});render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});event.currentTarget.disabled=false;}}));
        wrap.append(card);
      }
      if(!channels.length) adminMessage(wrap,'No channels yet.');
      if(!canManage) adminMessage(wrap,'Your roles do not grant Manage Channels.');
      return wrap;
    };
    const renderIntegrations = () => {
      const wrap = document.createElement('div'); wrap.className = 'admin-form-stack';
      const canWebhooks = hasPermission(state, 'manage_webhooks');
      const canBots = hasPermission(state, 'manage_bots');

      const webhooksSection = document.createElement('section'); webhooksSection.className = 'admin-role-card';
      const webhookTitle = document.createElement('div'); webhookTitle.className='admin-role-head';
      const webhookCopy = document.createElement('div'); const webhookStrong=document.createElement('strong'); webhookStrong.textContent='Webhooks'; const webhookSmall=document.createElement('small'); webhookSmall.textContent='Signed outbound HTTPS events with retry and delivery tracking.'; webhookCopy.append(webhookStrong,webhookSmall); webhookTitle.append(webhookCopy); webhooksSection.append(webhookTitle);
      const webhookList = document.createElement('div'); webhookList.className='admin-role-stack'; webhooksSection.append(webhookList);
      if (canWebhooks) {
        const create = document.createElement('form'); create.className='admin-form-stack';
        const name=makeField('Webhook name','',{maxLength:80,placeholder:'Build notifications'}); const url=makeField('HTTPS endpoint','',{maxLength:2048,placeholder:'https://example.com/plainwire'});
        const events = ['message.created','message.updated','message.deleted','message.reaction','message.pinned','message.unpinned','member.joined','member.removed','member.banned','member.unbanned','channel.created','channel.updated','bot.added','bot.removed','server.updated'];
        const eventGrid=document.createElement('div'); eventGrid.className='admin-permission-grid';
        events.forEach((key)=>{ const label=document.createElement('label'); label.className='admin-permission'; const input=document.createElement('input'); input.type='checkbox'; input.value=key; input.checked=key==='message.created'; const copy=document.createElement('span'); const strong=document.createElement('strong'); strong.textContent=key; copy.append(strong); label.append(input,copy); eventGrid.append(label); });
        const status=document.createElement('div'); status.className='admin-inline-message muted'; const submit=document.createElement('button'); submit.type='submit'; submit.className='btn'; submit.textContent='Create webhook';
        create.append(name.label,url.label,eventGrid,status,submit); webhooksSection.insertBefore(create,webhookList);
        create.addEventListener('submit',async(event)=>{ event.preventDefault(); submit.disabled=true; try { const selected=[...eventGrid.querySelectorAll('input:checked')].map((input)=>input.value); const data=await directApi(`/server/${serverId}/webhooks`,{method:'POST',body:{name:name.input.value.trim(),url:url.input.value.trim(),events:selected}}); if(data?.secret){ await copySecretDialog('Webhook secret',data.secret,'Use this secret to verify x-plainwire-signature. Plainwire only reveals it on creation or rotation.'); } render(); } catch(error){ status.textContent=error.message; status.className='admin-inline-message error'; submit.disabled=false; } });
        webhookList.setAttribute('aria-busy','true');
        directApi(`/server/${serverId}/webhooks`).then((items)=>{ webhookList.replaceChildren(); webhookList.removeAttribute('aria-busy'); for(const hook of (Array.isArray(items)?items:[])){ const row=document.createElement('section'); row.className='admin-role-card'; const head=document.createElement('div'); head.className='admin-role-head'; const copy=document.createElement('div'); const strong=document.createElement('strong'); strong.textContent=hook.name; const small=document.createElement('small'); small.textContent=`${hook.enabled?'Enabled':'Disabled'} · ${hook.failure_count||0} recent failures · ${(hook.events||[]).join(', ')}`; copy.append(strong,small); const actions=document.createElement('div'); actions.className='admin-row-actions';
          const test=actionButton('Test',async(e)=>{ e.currentTarget.disabled=true; try{await directApi(`/server/${serverId}/webhook/${hook.id}/test`,{method:'POST',body:{}}); send(app.ports.bridgeReceive,{tag:'toast',data:'Webhook test queued'});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{e.currentTarget.disabled=false;}});
          const rotate=actionButton('Rotate secret',async(e)=>{ if(!window.confirm(`Rotate the secret for ${hook.name}? Existing signatures will immediately stop validating.`))return; e.currentTarget.disabled=true; try{const data=await directApi(`/server/${serverId}/webhook/${hook.id}/rotate`,{method:'POST',body:{}}); await copySecretDialog('New webhook secret',data.secret,'Update your receiver before closing this dialog.');}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{e.currentTarget.disabled=false;}});
          const history=actionButton('Deliveries',async()=>{const modal=modalShell(`${hook.name} deliveries`,'Recent outbound delivery metadata. Payload bodies and signing secrets are never shown here.');const list=document.createElement('div');list.className='admin-role-stack';modal.body.append(list);try{const deliveries=await directApi(`/server/${serverId}/webhook/${hook.id}/deliveries?limit=50`);for(const d of (Array.isArray(deliveries)?deliveries:[])){const item=document.createElement('section');item.className='admin-role-card';const head2=document.createElement('div');head2.className='admin-role-head';const c2=document.createElement('div');const s2=document.createElement('strong');s2.textContent=`${d.event} · ${d.status}`;const sm=document.createElement('small');sm.textContent=`attempts ${d.attempts||0}${d.response_code?` · HTTP ${d.response_code}`:''}`;c2.append(s2,sm);const a2=document.createElement('div');a2.className='admin-row-actions';if(d.status==='failed'){a2.append(actionButton('Retry',async ev=>{ev.currentTarget.disabled=true;try{await directApi(`/server/${serverId}/webhook/${hook.id}/delivery/${d.id}/retry`,{method:'POST',body:{}});modal.destroy();send(app.ports.bridgeReceive,{tag:'toast',data:'Webhook delivery queued for retry'});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});ev.currentTarget.disabled=false;}}));}head2.append(c2,a2);item.append(head2);if(d.last_error){const e=document.createElement('small');e.className='muted';e.textContent=d.last_error;item.append(e);}list.append(item);}if(!list.children.length)adminMessage(list,'No deliveries yet.');}catch(error){adminMessage(list,error.message,'error');}});
          const remove=actionButton('Delete',async(e)=>{if(!window.confirm(`Delete webhook ${hook.name}?`))return;e.currentTarget.disabled=true;try{await directApi(`/server/${serverId}/webhook/${hook.id}/delete`,{method:'POST',body:{}});render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});e.currentTarget.disabled=false;}},true);
          actions.append(test,history,rotate,remove); head.append(copy,actions); row.append(head); const endpoint=document.createElement('code'); endpoint.textContent=hook.url; row.append(endpoint); webhookList.append(row); } if(!webhookList.children.length)adminMessage(webhookList,'No webhooks yet.'); }).catch((error)=>{webhookList.removeAttribute('aria-busy');adminMessage(webhookList,error.message,'error');});
      } else adminMessage(webhookList,'Your roles do not grant Manage Webhooks.');
      wrap.append(webhooksSection);

      const incomingSection=document.createElement('section'); incomingSection.className='admin-role-card';
      const incomingHead=document.createElement('div'); incomingHead.className='admin-role-head'; const incomingCopy=document.createElement('div'); const incomingStrong=document.createElement('strong'); incomingStrong.textContent='Incoming webhooks'; const incomingSmall=document.createElement('small'); incomingSmall.textContent='Give external services a fixed, revocable URL that can post into one text channel.'; incomingCopy.append(incomingStrong,incomingSmall); incomingHead.append(incomingCopy); incomingSection.append(incomingHead);
      const incomingList=document.createElement('div'); incomingList.className='admin-role-stack'; incomingSection.append(incomingList);
      if(canWebhooks){
        const form=document.createElement('form');form.className='admin-role-create';const name=document.createElement('input');name.placeholder='Webhook name';name.maxLength=80;const destination=document.createElement('select');destination.setAttribute('aria-label','Destination channel');(serverData?.channels||[]).filter(c=>c.kind==='text').forEach(c=>{const o=document.createElement('option');o.value=String(c.id);o.textContent=`# ${c.name}`;destination.append(o)});const submit=document.createElement('button');submit.type='submit';submit.className='btn';submit.textContent='Create incoming webhook';form.append(name,destination,submit);incomingSection.insertBefore(form,incomingList);
        form.addEventListener('submit',async event=>{event.preventDefault();submit.disabled=true;try{const data=await directApi(`/server/${serverId}/incoming-webhooks`,{method:'POST',body:{name:name.value.trim(),channel_id:Number(destination.value)}});const url=new URL(data.path,window.location.origin).href;await copySecretDialog('Incoming webhook URL',url,'This URL contains the webhook credential. Treat it like a password. POST JSON with a content field. It is shown only on creation or rotation.');render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});submit.disabled=false;}});
        incomingList.setAttribute('aria-busy','true');directApi(`/server/${serverId}/incoming-webhooks`).then(items=>{incomingList.replaceChildren();incomingList.removeAttribute('aria-busy');for(const hook of (Array.isArray(items)?items:[])){const row=document.createElement('section');row.className='admin-role-card';const h=document.createElement('div');h.className='admin-role-head';const c=document.createElement('div');const strong=document.createElement('strong');strong.textContent=hook.name;const small=document.createElement('small');small.textContent=`#${hook.channel_name||hook.channel_id}${hook.last_used_at?` · last used ${new Date(hook.last_used_at).toLocaleString()}`:' · never used'}`;c.append(strong,small);const a=document.createElement('div');a.className='admin-row-actions';const rotate=actionButton('Rotate URL',async ev=>{if(!confirm(`Rotate ${hook.name}'s incoming webhook URL?`))return;ev.currentTarget.disabled=true;try{const data=await directApi(`/server/${serverId}/incoming-webhook/${hook.id}/rotate`,{method:'POST',body:{}});await copySecretDialog('New incoming webhook URL',new URL(data.path,window.location.origin).href,'The previous URL stopped working immediately.');}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{ev.currentTarget.disabled=false;}});const remove=actionButton('Delete',async ev=>{if(!confirm(`Delete incoming webhook ${hook.name}? Historical messages remain.`))return;ev.currentTarget.disabled=true;try{await directApi(`/server/${serverId}/incoming-webhook/${hook.id}/delete`,{method:'POST',body:{}});render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});ev.currentTarget.disabled=false;}},true);a.append(rotate,remove);h.append(c,a);row.append(h);incomingList.append(row);}if(!incomingList.children.length)adminMessage(incomingList,'No incoming webhooks yet.');}).catch(error=>{incomingList.removeAttribute('aria-busy');adminMessage(incomingList,error.message,'error');});
      } else adminMessage(incomingList,'Your roles do not grant Manage Webhooks.');
      wrap.append(incomingSection);

      const botsSection=document.createElement('section'); botsSection.className='admin-role-card'; const botHead=document.createElement('div'); botHead.className='admin-role-head'; const botCopy=document.createElement('div'); const botStrong=document.createElement('strong'); botStrong.textContent='Bots'; const botSmall=document.createElement('small'); botSmall.textContent='Server-scoped bot accounts use the same role and permission model as members.'; botCopy.append(botStrong,botSmall); botHead.append(botCopy); botsSection.append(botHead); const botList=document.createElement('div'); botList.className='admin-role-stack'; botsSection.append(botList);
      if(canBots){ const create=document.createElement('form'); create.className='admin-role-create'; const input=document.createElement('input'); input.placeholder='Bot name'; input.maxLength=48; const submit=document.createElement('button'); submit.type='submit'; submit.className='btn'; submit.textContent='Create bot'; create.append(input,submit); botsSection.insertBefore(create,botList); create.addEventListener('submit',async(event)=>{event.preventDefault();submit.disabled=true;try{const data=await directApi(`/server/${serverId}/bots`,{method:'POST',body:{name:input.value.trim()}}); await copySecretDialog('Bot token',data.token,'This token authenticates the bot SDK and is shown only once. Give the bot roles after creation to control what it can do.',true); render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});submit.disabled=false;}});
        botList.setAttribute('aria-busy','true'); directApi(`/server/${serverId}/bots`).then((items)=>{botList.replaceChildren();botList.removeAttribute('aria-busy');for(const bot of (Array.isArray(items)?items:[])){const row=document.createElement('section');row.className='admin-role-card';const head=document.createElement('div');head.className='admin-role-head';const copy=document.createElement('div');const strong=document.createElement('strong');strong.textContent=bot.name;const small=document.createElement('small');small.textContent=`@${bot.username} · user ${bot.user_id}`;copy.append(strong,small);const actions=document.createElement('div');actions.className='admin-row-actions';const rotate=actionButton('Rotate token',async(e)=>{if(!window.confirm(`Rotate ${bot.name}'s token?`))return;e.currentTarget.disabled=true;try{const data=await directApi(`/server/${serverId}/bot/${bot.id}/rotate`,{method:'POST',body:{}});await copySecretDialog('New bot token',data.token,'The previous token is no longer valid.');}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{e.currentTarget.disabled=false;}});const remove=actionButton('Delete bot',async(e)=>{if(!window.confirm(`Delete bot ${bot.name} and its authored messages?`))return;e.currentTarget.disabled=true;try{await directApi(`/server/${serverId}/bot/${bot.id}/delete`,{method:'POST',body:{}});render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});e.currentTarget.disabled=false;}},true);actions.append(rotate,remove);head.append(copy,actions);row.append(head);botList.append(row);}if(!botList.children.length)adminMessage(botList,'No bots yet.');}).catch((error)=>{botList.removeAttribute('aria-busy');adminMessage(botList,error.message,'error');});
      } else adminMessage(botList,'Your roles do not grant Manage Bots.');
      wrap.append(botsSection);

      const appsSection=document.createElement('section'); appsSection.className='admin-role-card';
      const appHead=document.createElement('div');appHead.className='admin-role-head';const appCopy=document.createElement('div');const appStrong=document.createElement('strong');appStrong.textContent='Applications';const appSmall=document.createElement('small');appSmall.textContent='Browse installable apps, manage installed bot identities, and control where each command is available.';appCopy.append(appStrong,appSmall);appHead.append(appCopy);appsSection.append(appHead);
      const appDirectory=document.createElement('div');appDirectory.className='admin-form-stack';
      const appList=document.createElement('div');appList.className='admin-role-stack';appsSection.append(appDirectory,appList);
      const permissionSubjectLabel=(type,id)=>{
        id=Number(id);
        if(type==='channel'){const channel=(serverData?.channels||[]).find(item=>Number(item.id)===id);return channel?`# ${channel.name}`:`Channel ${id}`;}
        if(type==='role'){const role=(state?.roles||[]).find(item=>Number(item.id)===id);return role?`@${role.name}`:`Role ${id}`;}
        const member=(state?.members||[]).find(item=>Number(item.user?.id)===id);return member?(member.user?.display_name||member.user?.username||`User ${id}`):`User ${id}`;
      };
      const openCommandPermissions=async(item)=>{
        const modal=modalShell(`${item.name} commands`,'Command overrides are optional. With no override, members who can access the channel can use the command. Member rules take precedence over channel rules; role denies take precedence over role allows.');
        const root=document.createElement('div');root.className='admin-role-stack';modal.body.append(root);adminMessage(root,'Loading commands…');
        try{
          const commands=await directApi(`/server/${serverId}/app/${item.installation_id}/commands`);root.replaceChildren();
          for(const command of (Array.isArray(commands)?commands:[])){
            const card=document.createElement('section');card.className='admin-role-card';
            const head=document.createElement('div');head.className='admin-role-head';const copy=document.createElement('div');const title=document.createElement('strong');title.textContent=`/${command.name}`;const meta=document.createElement('small');meta.textContent=`${command.handler||'queue'} · ${command.description||'No description'}`;copy.append(title,meta);head.append(copy);card.append(head);
            let rules=Array.isArray(command.permissions)?command.permissions.map(rule=>({type:String(rule.type||''),id:Number(rule.id),allow:rule.allow===true})):[];
            const rulesBox=document.createElement('div');rulesBox.className='admin-role-stack';
            const controls=document.createElement('div');controls.className='developer-inline';
            const type=document.createElement('select');[['channel','Channel'],['role','Role'],['user','Member']].forEach(([value,label])=>{const option=document.createElement('option');option.value=value;option.textContent=label;type.append(option)});
            const subject=document.createElement('select');const effect=document.createElement('select');[['true','Allow'],['false','Deny']].forEach(([value,label])=>{const option=document.createElement('option');option.value=value;option.textContent=label;effect.append(option)});
            const populateSubjects=()=>{subject.replaceChildren();const add=(id,label)=>{const option=document.createElement('option');option.value=String(id);option.textContent=label;subject.append(option)};if(type.value==='channel'){for(const channel of (serverData?.channels||[]))add(channel.id,`# ${channel.name}`);}else if(type.value==='role'){for(const role of (state?.roles||[]))add(role.id,`@${role.name}`);}else{for(const member of (state?.members||[]))add(member.user?.id,member.user?.display_name||member.user?.username||`User ${member.user?.id}`);}};
            type.addEventListener('change',populateSubjects);populateSubjects();
            const addRule=actionButton('Add override',()=>{const id=Number(subject.value);if(!Number.isInteger(id)||id<=0)return;const next={type:type.value,id,allow:effect.value==='true'};rules=rules.filter(rule=>!(rule.type===next.type&&Number(rule.id)===id));rules.push(next);renderRules();});
            controls.append(type,subject,effect,addRule);
            const renderRules=()=>{rulesBox.replaceChildren();for(const rule of rules){const row=document.createElement('div');row.className='admin-role-head';const c=document.createElement('div');const strong=document.createElement('strong');strong.textContent=permissionSubjectLabel(rule.type,rule.id);const small=document.createElement('small');small.textContent=`${rule.type} · ${rule.allow?'Allowed':'Denied'}`;c.append(strong,small);const remove=actionButton('Remove',()=>{rules=rules.filter(item=>!(item.type===rule.type&&Number(item.id)===Number(rule.id)));renderRules();});row.append(c,remove);rulesBox.append(row);}if(!rules.length)adminMessage(rulesBox,'No overrides. This command follows normal channel access.');};
            renderRules();
            const save=actionButton('Save command access',async event=>{event.currentTarget.disabled=true;try{const data=await directApi(`/server/${serverId}/app/${item.installation_id}/command/${command.id}/permissions`,{method:'POST',body:{permissions:rules}});rules=Array.isArray(data.permissions)?data.permissions:rules;renderRules();send(app.ports.bridgeReceive,{tag:'toast',data:`/${command.name} permissions saved`});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{event.currentTarget.disabled=false;}});
            card.append(rulesBox,controls,save);root.append(card);
          }
          if(!root.children.length)adminMessage(root,'This application has no commands.');
        }catch(error){root.replaceChildren();adminMessage(root,error.message,'error');}
      };
      const installPublicApp=async(publicId,button)=>{
        if(button)button.disabled=true;
        try{const preview=await directApi(`/apps/${encodeURIComponent(publicId)}`);if(!confirm(`Install ${preview.name} in this server? Plainwire will create a bot identity and grant only the application's requested permissions that you are allowed to grant.`))return;const data=await directApi(`/apps/${encodeURIComponent(publicId)}/install`,{method:'POST',body:{server_id:serverId}});if(data.token)await copySecretDialog(`${preview.name} installation token`,data.token,'You own this application, so Plainwire is showing this server-scoped bot token once. Other server managers never receive the developer credential.');render();}
        catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}
        finally{if(button)button.disabled=false;}
      };
      if(canBots){
        const directoryTitle=document.createElement('strong');directoryTitle.textContent='App directory';const directoryHint=document.createElement('small');directoryHint.textContent='Public applications published by Plainwire users.';appDirectory.append(directoryTitle,directoryHint);
        const searchForm=document.createElement('form');searchForm.className='admin-role-create';const search=document.createElement('input');search.placeholder='Search applications';search.maxLength=80;const searchBtn=document.createElement('button');searchBtn.type='submit';searchBtn.className='btn secondary';searchBtn.textContent='Search';searchForm.append(search,searchBtn);const results=document.createElement('div');results.className='admin-role-stack';appDirectory.append(searchForm,results);
        const loadDirectory=async()=>{searchBtn.disabled=true;results.setAttribute('aria-busy','true');try{const q=search.value.trim();const items=await directApi(`/apps?limit=20${q?`&q=${encodeURIComponent(q)}`:''}`);results.replaceChildren();for(const appItem of (Array.isArray(items)?items:[])){const row=document.createElement('section');row.className='admin-role-card';const h=document.createElement('div');h.className='admin-role-head';const c=document.createElement('div');const strong=document.createElement('strong');strong.textContent=appItem.name;const small=document.createElement('small');small.textContent=`${appItem.installation_count||0} installation${Number(appItem.installation_count||0)===1?'':'s'} · ${appItem.public_id}`;c.append(strong,small);const install=actionButton('Install',event=>installPublicApp(appItem.public_id,event.currentTarget));h.append(c,install);row.append(h);if(appItem.description){const desc=document.createElement('p');desc.className='muted';desc.textContent=appItem.description;row.append(desc)}results.append(row);}if(!results.children.length)adminMessage(results,'No public applications matched your search.');}catch(error){results.replaceChildren();adminMessage(results,error.message,'error');}finally{results.removeAttribute('aria-busy');searchBtn.disabled=false;}};
        searchForm.addEventListener('submit',event=>{event.preventDefault();loadDirectory();});loadDirectory();
        const installForm=document.createElement('form');installForm.className='admin-role-create';const appId=document.createElement('input');appId.placeholder='Or paste a Public App ID · app_…';appId.maxLength=96;const installBtn=document.createElement('button');installBtn.type='submit';installBtn.className='btn';installBtn.textContent='Install by ID';installForm.append(appId,installBtn);appDirectory.append(installForm);
        installForm.addEventListener('submit',async event=>{event.preventDefault();const id=appId.value.trim();if(!id)return;await installPublicApp(id,installBtn);appId.value='';});
        appList.setAttribute('aria-busy','true');directApi(`/server/${serverId}/apps`).then(items=>{appList.replaceChildren();appList.removeAttribute('aria-busy');for(const item of (Array.isArray(items)?items:[])){const row=document.createElement('section');row.className='admin-role-card';const h=document.createElement('div');h.className='admin-role-head';const c=document.createElement('div');const strong=document.createElement('strong');strong.textContent=item.name;const small=document.createElement('small');small.textContent=`${item.public_id} · @${item.username}`;c.append(strong,small);const actions=document.createElement('div');actions.className='admin-row-actions';const commands=actionButton('Commands',()=>openCommandPermissions(item));const remove=actionButton('Uninstall',async event=>{if(!confirm(`Uninstall ${item.name} from this server? Its bot token will stop working immediately. Historical messages remain attributed to the disabled bot account.`))return;event.currentTarget.disabled=true;try{await directApi(`/server/${serverId}/app/${item.installation_id}/uninstall`,{method:'POST',body:{}});render();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});event.currentTarget.disabled=false;}},true);const badge=document.createElement('span');badge.className='bot-badge';badge.textContent='APP';actions.append(commands,remove,badge);h.append(c,actions);row.append(h);if(item.description){const p=document.createElement('p');p.className='muted';p.textContent=item.description;row.append(p)}appList.append(row);}if(!appList.children.length)adminMessage(appList,'No reusable applications installed yet.');}).catch(error=>{appList.removeAttribute('aria-busy');adminMessage(appList,error.message,'error');});
      } else adminMessage(appList,'Your roles do not grant Manage Bots.');
      wrap.append(appsSection);
      return wrap;
    };
    const copySecretDialog = async (title, secret, note, showBotStarter = false) => {
      const modal=modalShell(title,note); const field=document.createElement('textarea'); field.readOnly=true; field.rows=4; field.value=String(secret||''); field.className='admin-secret-value'; const actions=document.createElement('div');actions.className='admin-row-actions';const copy=document.createElement('button');copy.type='button';copy.className='btn';copy.textContent='Copy';copy.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(field.value);copy.textContent='Copied';}catch(_){field.focus();field.select();}});const close=document.createElement('button');close.type='button';close.className='btn secondary';close.textContent='I saved it';close.addEventListener('click',modal.destroy);actions.append(copy,close);modal.body.append(field,actions);field.focus();field.select();
      if(showBotStarter){
        const base=window.location.origin;
        const snippets={
          JavaScript:`import { PlainwireBot } from './plainwire-bot.mjs';\nconst bot = new PlainwireBot('${base}', process.env.PLAINWIRE_BOT_TOKEN);\nawait bot.syncCommands([{ name: 'ping', description: 'Replies pong' }]);\nawait bot.commandWorker({ ping: async () => 'pong' }).run();`,
          Python:`import os\nfrom plainwire_bot import Client\nbot = Client('${base}', os.environ['PLAINWIRE_BOT_TOKEN'])\nbot.sync_commands([{'name': 'ping', 'description': 'Replies pong'}])\nbot.command_worker({'ping': lambda claim, client: 'pong'}).run()`,
          Go:`bot, err := plainwirebot.New("${base}", os.Getenv("PLAINWIRE_BOT_TOKEN"))\n_, err = bot.SyncCommands(ctx, []plainwirebot.CommandDefinition{{Name: "ping", Description: "Replies pong"}})\nerr = bot.RunCommandWorker(ctx, handlers, plainwirebot.WorkerOptions{})`,
          Rust:`let bot = plainwire_bot::Client::new("${base}", &std::env::var("PLAINWIRE_BOT_TOKEN")?)?;\nbot.sync_commands(serde_json::json!([{"name":"ping","description":"Replies pong"}]))?;`,
          Erlang:`{ok, Bot} = plainwire_bot:start_link(#{base_url => <<"${base}">>, token => os:getenv("PLAINWIRE_BOT_TOKEN")}),\n{ok, _} = plainwire_bot:sync_commands(Bot, [#{name => <<"ping">>, description => <<"Replies pong">>}]).`,
          C:`pw_bot_client bot;\npw_bot_client_init(&bot, "${base}", getenv("PLAINWIRE_BOT_TOKEN"));\npw_bot_sync_commands(&bot, "[{\\"name\\":\\"ping\\",\\"description\\":\\"Replies pong\\"}]", &response);`,
          'C++':`plainwire::bot_client bot("${base}", std::getenv("PLAINWIRE_BOT_TOKEN"));\nauto result = bot.sync_commands(R"([{"name":"ping","description":"Replies pong"}])");`
        };
        const language=document.createElement('select');language.setAttribute('aria-label','Starter language');Object.keys(snippets).forEach(name=>{const option=document.createElement('option');option.value=name;option.textContent=name;language.append(option)});
        const label=document.createElement('label');label.className='admin-field';const labelText=document.createElement('span');labelText.textContent='Starter';label.append(labelText,language);
        const starter=document.createElement('textarea');starter.readOnly=true;starter.rows=8;starter.className='admin-secret-value';const update=()=>{starter.value=snippets[language.value]||''};language.addEventListener('change',update);update();
        const hint=document.createElement('small');hint.className='muted';hint.textContent='Set PLAINWIRE_BOT_TOKEN to the token above. The starter syncs one command; the SDK guides cover every API.';
        const copyStarter=document.createElement('button');copyStarter.type='button';copyStarter.className='btn secondary';copyStarter.textContent='Copy starter';copyStarter.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(starter.value);copyStarter.textContent='Copied starter';}catch(_){starter.focus();starter.select();}});
        const starterActions=document.createElement('div');starterActions.className='admin-row-actions';starterActions.append(copyStarter);modal.body.insertBefore(label,actions);modal.body.insertBefore(starter,actions);modal.body.insertBefore(hint,actions);modal.body.insertBefore(starterActions,actions);
      }
    };
    const render = () => {
      shell.body.replaceChildren(); const nav=document.createElement('nav');nav.className='admin-tabs';
      const tabs=[['profile','My profile'],['overview','Overview'],['channels','Channels'],['roles','Roles'],['members','Members'],['bans','Bans'],['wires','Wires'],['integrations','Integrations']];
      tabs.forEach(([id,label])=>{const b=document.createElement('button');b.type='button';b.textContent=label;b.classList.toggle('active',activeTab===id);b.addEventListener('click',()=>{activeTab=id;render()});nav.append(b)});shell.body.append(nav);
      const panel=document.createElement('div');panel.className='admin-panel';
      panel.append(activeTab==='overview'?renderOverview():activeTab==='channels'?renderChannels():activeTab==='roles'?renderRoles():activeTab==='members'?renderMembers():activeTab==='bans'?renderBans():activeTab==='wires'?renderWires():activeTab==='integrations'?renderIntegrations():renderProfile());shell.body.append(panel);
    };
    try { await refresh(); shell.setTitle(serverData?.server?.name || 'Server settings'); render(); }
    catch (error) { shell.body.replaceChildren(); adminMessage(shell.body, `Could not load server settings: ${error.message}`, 'error'); }
  };

  const reloadThread = async (threadId) => {
    await api({ method: 'GET', path: `/thread/${Number(threadId)}` });
  };
  const openThreadEditor = async (data) => {
    const threadId = Number(data?.id || 0); if (!threadId) return;
    const shell = modalShell('Edit thread', 'Update the title or Markdown body. Existing replies are not changed.');
    const form = document.createElement('form'); form.className = 'admin-form-stack';
    const title = makeField('Title', String(data?.title || ''), { maxLength: 180 });
    const body = makeField('Body (Markdown)', String(data?.raw_body || data?.body || ''), { multiline: true, maxLength: 20000 });
    body.input.rows = 12;
    const status = document.createElement('div'); status.className = 'admin-inline-message muted';
    const actions = document.createElement('div'); actions.className = 'admin-row-actions';
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn secondary'; cancel.textContent = 'Cancel'; cancel.addEventListener('click', shell.destroy);
    const save = document.createElement('button'); save.type = 'submit'; save.className = 'btn'; save.textContent = 'Save changes';
    actions.append(cancel, save); form.append(title.label, body.label, status, actions); shell.body.append(form);
    form.addEventListener('submit', async event => {
      event.preventDefault(); const cleanedTitle = title.input.value.trim(), cleanedBody = body.input.value.trim();
      if (cleanedTitle.length < 2 || !cleanedBody) { status.textContent = 'A title and body are required.'; status.className = 'admin-inline-message error'; return; }
      save.disabled = true; status.textContent = 'Saving…'; status.className = 'admin-inline-message muted';
      try { await directApi(`/thread/${threadId}/edit`, { method: 'POST', body: { title: cleanedTitle, body: cleanedBody } }); await reloadThread(threadId); shell.destroy(); send(app.ports.bridgeReceive,{tag:'toast',data:'Thread updated'}); }
      catch(error){ status.textContent=`Could not save thread: ${error.message}`; status.className='admin-inline-message error'; save.disabled=false; }
    });
  };
  const moderateThread = async (data) => {
    const threadId = Number(data?.id || 0), action = String(data?.action || ''); if (!threadId || !['pin','lock'].includes(action)) return;
    const value = Boolean(data?.value);
    try { await directApi(`/thread/${threadId}/moderate`, { method:'POST', body:{ action, value } }); await reloadThread(threadId); send(app.ports.bridgeReceive,{tag:'toast',data:`Thread ${action === 'pin' ? (value ? 'pinned' : 'unpinned') : (value ? 'locked' : 'unlocked')}`}); }
    catch(error){ send(app.ports.bridgeReceive,{tag:'toast',data:`Could not moderate thread: ${error.message}`}); }
  };
  const openReplyEditor = async (data) => {
    const threadId=Number(data?.thread_id||0), replyId=Number(data?.id||0); if(!threadId||!replyId)return;
    const shell=modalShell('Edit reply','Edit the original Markdown for this reply.');
    const form=document.createElement('form');form.className='admin-form-stack';
    const body=makeField('Reply (Markdown)',String(data?.raw_body||data?.body||''),{multiline:true,maxLength:12000});body.input.rows=9;
    const status=document.createElement('div');status.className='admin-inline-message muted';
    const actions=document.createElement('div');actions.className='admin-row-actions';
    const cancel=document.createElement('button');cancel.type='button';cancel.className='btn secondary';cancel.textContent='Cancel';cancel.addEventListener('click',shell.destroy);
    const save=document.createElement('button');save.type='submit';save.className='btn';save.textContent='Save reply';actions.append(cancel,save);form.append(body.label,status,actions);shell.body.append(form);
    form.addEventListener('submit',async event=>{event.preventDefault();const cleaned=body.input.value.trim();if(!cleaned){status.textContent='Reply cannot be empty.';status.className='admin-inline-message error';return;}save.disabled=true;try{await directApi(`/thread/${threadId}/reply/${replyId}/edit`,{method:'POST',body:{body:cleaned}});await reloadThread(threadId);shell.destroy();send(app.ports.bridgeReceive,{tag:'toast',data:'Reply updated'});}catch(error){status.textContent=`Could not save reply: ${error.message}`;status.className='admin-inline-message error';save.disabled=false;}});
  };
  const deleteThreadReply = async (data) => {
    const threadId=Number(data?.thread_id||0),replyId=Number(data?.id||0);if(!threadId||!replyId)return;
    if(!window.confirm('Delete this reply? This cannot be undone.'))return;
    try{await directApi(`/thread/${threadId}/reply/${replyId}/delete`,{method:'POST',body:{}});await reloadThread(threadId);send(app.ports.bridgeReceive,{tag:'toast',data:'Reply deleted'});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:`Could not delete reply: ${error.message}`});}
  };

  document.title = clientConfig.appName;
  document.documentElement.dataset.plainwireVersion = clientConfig.version;
  const app = window.Elm.Main.init({
    node: root,
    flags: {
      appName: clientConfig.appName,
      registrationEnabled: clientConfig.registrationEnabled,
      passwordResetEnabled: clientConfig.passwordResetEnabled,
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
  // Set while this client is tearing down a room it had joined, so a peer-left
  // echo of that departure cannot also play the "someone else left" cue.
  let rtcLocalDeparture = false;
  let callAwaitingFirstGuest = false;
  const joinCueIds = new Set();
  let roomEpoch = 0;
  let callHealth = null;
  const RTC_RESUME_KEY = 'plainwire_rtc_room';
  const RTC_RESUME_MAX_AGE_MS = 60000;
  const RTC_RESUME_HEARTBEAT_MS = 5000;
  const RTC_OWNER_KEY = 'plainwire_rtc_owner_v1';
  const RTC_OWNER_STALE_MS = 12000;
  const rtcTabId = globalThis.crypto?.randomUUID?.() || `tab-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  let rtcPersistenceTimer = null;
  let resumeAttempted = false;
  let resumeInFlight = false;
  let pendingRtcAction = null;
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
  let screenShareSession = 0;
  let screenWatchTimer = null;
  const screenWatchAnnounced = new Set();
  let screenAudioMixer = null;
  let screenAudioSource = 'none';
  let screenSenders = new Map(); // uid -> RTCRtpSender for video
  const displayMediaSupported = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia);
  const peerPromises = new Map();
  const signalQueues = new Map();
  // Candidates can leave the browser before the offer or answer is queued.
  // Holding them here, instead of dropping them, is what lets a pair connect
  // without both people reloading.
  const earlyCandidates = new Map();
  const identityRetries = new Map();
  // Bumped whenever a participant's session is replaced, so queued signals from
  // the old session cannot resurrect a peer connection.
  const peerGenerations = new Map();
  // ICE restart is the cheap recovery path. If the receiver/session itself gets
  // wedged, rebuild only that peer connection instead of forcing a page refresh.
  // Budgeted per room+peer so a broken network cannot create a reconnect storm.
  const peerRepairPromises = new Map();
  const peerRepairHistory = new Map();
  const RTC_PEER_REBUILD_WINDOW_MS = 90000;
  const RTC_MAX_PEER_REBUILDS = 2;
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
  let wsLastMessageAt = 0;
  let wsEverConnected = false;
  const WS_HEARTBEAT_MS = 25000;
  const WS_STALE_AFTER_MS = 55000;
  let syncInFlight = null;
  let syncQueued = false;
  const syncRecovery = new Map();
  const syncRecoveryPaths = {
    friends: '/friends',
    servers: '/servers',
    conversations: '/conversations',
    notifications: '/notifications',
  };
  const syncRecoveryComponentsByPath = Object.fromEntries(
    Object.entries(syncRecoveryPaths).map(([component, path]) => [path, component])
  );
  // Recovery is component-scoped, but the status message is intentionally
  // session-scoped. Friends + servers failing together should not produce two
  // identical toasts while the UI is already preserving both last-good lists.
  let syncRecoveryNoticeShown = false;
  let authReloadScheduled = false;
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
  const readRtcOwner = () => {
    try {
      const value = JSON.parse(storage.getItem(RTC_OWNER_KEY) || 'null');
      const id = Number(value?.id || 0);
      const validKind = value?.kind === 'call' || value?.kind === 'voice';
      const fresh = Number.isFinite(value?.at) && Date.now() - value.at <= RTC_OWNER_STALE_MS;
      if (!value?.tab || !validKind || !Number.isInteger(id) || id <= 0 || !fresh) {
        if (value?.tab === rtcTabId || !fresh) storage.removeItem(RTC_OWNER_KEY);
        return null;
      }
      return { tab: value.tab, kind: value.kind, id, at: value.at };
    } catch (_) { return null; }
  };
  const publishRtcOwner = () => {
    if (!room?.joined) return;
    storage.setItem(RTC_OWNER_KEY, JSON.stringify({ tab: rtcTabId, kind: room.kind, id: room.id, at: Date.now() }));
  };
  const clearRtcOwner = () => {
    const owner = readRtcOwner();
    if (!owner || owner.tab === rtcTabId) storage.removeItem(RTC_OWNER_KEY);
  };
  const startRtcPersistence = () => {
    persistRtcIntent();
    publishRtcOwner();
    if (!rtcPersistenceTimer) {
      rtcPersistenceTimer = setInterval(() => {
        if (!room?.joined) return;
        persistRtcIntent();
        publishRtcOwner();
      }, RTC_RESUME_HEARTBEAT_MS);
    }
  };
  const stopRtcPersistence = () => {
    clearInterval(rtcPersistenceTimer);
    rtcPersistenceTimer = null;
    clearRtcOwner();
  };
  const rtcAction = (action, kind, id, epoch) => {
    pendingRtcAction = { action, kind, id: Number(id), epoch };
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
      rtc_owner: readRtcOwner(),
      pending_rtc_action: pendingRtcAction ? { ...pendingRtcAction } : null,
      screen_share: { active: !!screenStream, audio_source: screenAudioSource, audio_mixed: screenAudioMixer?.track?.readyState === 'live' },
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
  queueMicrotask(() => refreshGlobalBanners());

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
    if (!rtcRefreshTimer) rtcRefreshTimer = setInterval(() => {
      if (!room?.joined) return;
      loadRtcConfig();
      auditRtcPeers('periodic');
    }, 15000);
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
      const speed = player.querySelector('[data-media-action="speed"]');
      const elapsed = player.querySelector('.pw-media-time');
      const duration = player.querySelector('.pw-media-duration');
      if (!media || !playButtons.length || !seek) return;

      player.dataset.playerReady = 'true';
      let scrubbing = false;
      let resumeAfterScrub = false;
      let durationProbe = null;
      let durationProbeAttempted = false;
      let playQueuedForProbe = false;
      const durationHint = Math.max(0, Number(player.dataset.duration) || 0);
      const savedSetting = storage.getItem('plainwire_media_volume');
      const savedVolume = savedSetting === null ? NaN : Number(savedSetting);
      media.volume = Number.isFinite(savedVolume) ? Math.max(0, Math.min(1, savedVolume)) : 0.85;
      seek.value = '0';
      if (volume) volume.value = String(media.volume);

      const nativeDuration = () => Number.isFinite(media.duration) && media.duration > 0 ? media.duration : 0;
      const totalDuration = () => nativeDuration() || durationHint;

      // MediaRecorder WebM files commonly omit a duration header. Chromium then
      // reports Infinity until it has scanned the stream, which makes a native
      // seek bar jump to the end. A large metadata-only seek asks the demuxer to
      // discover the real end without playing the whole note. UI updates stay on
      // the known recorder duration while the probe is active.
      const probeDuration = () => {
        if (durationProbe || durationProbeAttempted || nativeDuration() || media.readyState < HTMLMediaElement.HAVE_METADATA) return;
        durationProbeAttempted = true;
        const restoreTime = Number.isFinite(media.currentTime) ? media.currentTime : 0;
        const listeners = ['durationchange', 'timeupdate', 'seeked'];
        const finish = (resolved) => {
          if (!durationProbe) return;
          if (resolved && !nativeDuration()) return;
          const state = durationProbe;
          clearTimeout(state.timer);
          listeners.forEach((event) => media.removeEventListener(event, detect));
          try { media.currentTime = Math.min(restoreTime, nativeDuration() || durationHint || 0); } catch (_) {}
          durationProbe = null;
          player.classList.remove('probing-duration');
          update();
          player.dispatchEvent(new Event('plainwire:duration-probe-finished'));
        };
        const detect = () => finish(true);
        durationProbe = { restoreTime, timer: 0 };
        player.classList.add('probing-duration');
        listeners.forEach((event) => media.addEventListener(event, detect));
        durationProbe.timer = setTimeout(() => finish(false), 1500);
        try { media.currentTime = Number.MAX_SAFE_INTEGER; }
        catch (_) { finish(false); }
      };

      const update = () => {
        const total = totalDuration();
        const current = durationProbe ? durationProbe.restoreTime : (Number.isFinite(media.currentTime) ? media.currentTime : 0);
        if (!scrubbing) seek.value = total > 0 ? String(Math.round(Math.max(0, Math.min(1, current / total)) * 1000)) : '0';
        seek.disabled = !(total > 0);
        seek.setAttribute('aria-valuetext', total > 0 ? `${mediaTime(current)} of ${mediaTime(total)}` : mediaTime(current));
        if (elapsed) elapsed.textContent = mediaTime(current);
        if (duration) duration.textContent = mediaTime(total);
        const label = media.paused ? 'Play' : 'Pause';
        playButtons.forEach((button) => {
          button.textContent = label;
          button.setAttribute('aria-label', `${label} media`);
        });
        if (mute) mute.textContent = media.muted || media.volume === 0 ? 'Muted' : 'Sound';
        if (speed) speed.textContent = `${media.playbackRate}×`;
        player.classList.toggle('playing', !media.paused);
        player.classList.toggle('muted', media.muted || media.volume === 0);
      };

      const togglePlayback = () => {
        if (!media.paused) return media.pause();
        document.querySelectorAll('.pw-media-player audio, .pw-media-player video').forEach((other) => {
          if (other !== media) other.pause();
        });
        const total = totalDuration();
        if (media.ended || (total > 0 && media.currentTime >= total - 0.05)) media.currentTime = 0;
        probeDuration();
        if (durationProbe) {
          if (!playQueuedForProbe) {
            playQueuedForProbe = true;
            playButtons.forEach((button) => { button.disabled = true; button.setAttribute('aria-busy', 'true'); });
            player.addEventListener('plainwire:duration-probe-finished', () => {
              playQueuedForProbe = false;
              playButtons.forEach((button) => { button.disabled = false; button.removeAttribute('aria-busy'); });
              if (media.paused) togglePlayback();
            }, { once: true });
          }
          return;
        }
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
        const total = totalDuration();
        if (total > 0) {
          media.currentTime = Number(seek.value) * total / 1000;
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
      speed?.addEventListener('click', () => {
        const rates = [1, 1.5, 2];
        const index = rates.findIndex((rate) => Math.abs(rate - media.playbackRate) < 0.01);
        media.playbackRate = rates[(index + 1 + rates.length) % rates.length];
        update();
      });
      fullscreen?.addEventListener('click', () => {
        const target = player.querySelector('.pw-video-frame') || media;
        if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
        else target.requestFullscreen?.().catch(() => media.webkitEnterFullscreen?.());
      });

      media.addEventListener('loadedmetadata', () => { update(); probeDuration(); });
      ['durationchange', 'timeupdate', 'play', 'pause', 'volumechange', 'ratechange', 'ended'].forEach((event) => media.addEventListener(event, update));
      ['waiting', 'stalled'].forEach((event) => media.addEventListener(event, () => player.classList.add('buffering')));
      ['canplay', 'playing', 'pause', 'ended'].forEach((event) => media.addEventListener(event, () => player.classList.remove('buffering')));
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

  const parseWireUrl = (url) => {
    try {
      const parsed = new URL(url, location.href);
      if (parsed.origin !== location.origin) return null;
      const hash = parsed.hash || '';
      const prefix = hash.startsWith('#wire/') ? '#wire/' : hash.startsWith('#invite/') ? '#invite/' : '';
      if (!prefix) return null;
      const code = decodeURIComponent(hash.slice(prefix.length)).split(/[?&/]/, 1)[0].trim();
      return /^[A-Za-z0-9_-]{8,80}$/.test(code) ? code : null;
    } catch (_) { return null; }
  };

  const fetchEmbed = (url) => {
    if (embedCache.has(url)) return Promise.resolve(embedCache.get(url));
    if (embedInFlight.has(url)) return embedInFlight.get(url);
    const wireCode = parseWireUrl(url);
    if (wireCode) {
      const request = directApi(`/wires/${encodeURIComponent(wireCode)}`)
        .then((invite) => {
          const server = invite?.server || {};
          const value = { type: 'plainwire_wire', url, code: wireCode, ...invite, server };
          setEmbedCache(url, value); return value;
        })
        .catch(() => { setEmbedCache(url, null); return null; })
        .finally(() => embedInFlight.delete(url));
      embedInFlight.set(url, request);
      return request;
    }
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

  const createWireEmbedCard = (meta) => {
    const card=document.createElement('div'); card.className='link-embed wire-embed'; card.style.setProperty('--wire-accent', meta.server?.accent_color || '#5865f2');
    if (meta.server?.banner_url) { const banner=document.createElement('img'); banner.className='wire-embed-banner'; banner.src=meta.server.banner_url; banner.alt=''; banner.loading='lazy'; banner.addEventListener('error',()=>banner.remove(),{once:true}); card.append(banner); }
    const body=document.createElement('div'); body.className='wire-embed-body';
    const identity=document.createElement('div'); identity.className='wire-embed-identity';
    const icon=document.createElement(meta.server?.icon_url ? 'img':'div'); icon.className='wire-embed-icon';
    if (icon instanceof HTMLImageElement) { icon.src=meta.server.icon_url; icon.alt=''; } else icon.textContent=String(meta.server?.name||'P').slice(0,1).toUpperCase();
    const copy=document.createElement('div'); const eyebrow=document.createElement('small'); eyebrow.textContent='PLAINWIRE SERVER INVITE';
    const title=document.createElement('strong'); title.textContent=meta.server?.name || 'Plainwire server';
    const desc=document.createElement('p'); desc.textContent=meta.server?.description || meta.server?.welcome_message || 'You have been invited to join this server.';
    copy.append(eyebrow,title,desc); identity.append(icon,copy); body.append(identity);
    const metaRow=document.createElement('div'); metaRow.className='wire-embed-meta';
    const members=document.createElement('span'); members.textContent=`${Number(meta.server?.member_count||0)} members`; metaRow.append(members);
    if (meta.channel_name) { const channel=document.createElement('span'); channel.textContent=`# ${meta.channel_name}`; metaRow.append(channel); }
    if (Number(meta.expires_at||0)>0) { const expiry=document.createElement('span'); expiry.textContent=Number(meta.expires_at)<=Date.now()?'Expired':`Expires ${new Date(Number(meta.expires_at)).toLocaleString()}`; metaRow.append(expiry); }
    body.append(metaRow);
    const actions=document.createElement('div'); actions.className='wire-embed-actions';
    const open=document.createElement('a'); open.className='btn'; open.href=`#wire/${encodeURIComponent(meta.code)}`; open.textContent=meta.valid===false?'View invite':'Open Wire'; if(meta.valid===false) open.classList.add('secondary');
    actions.append(open); body.append(actions); card.append(body); return card;
  };

  const createEmbedCard = (meta) => {
    if (meta?.type === 'plainwire_wire') return createWireEmbedCard(meta);
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

  // Put a Discord-style unread divider near the top when it is above the last
  // screen of history. A short unread tail stays pinned to the latest message.
  const revealUnreadMarker = (list) => {
    const marker = list.querySelector('.unread-marker');
    if (!marker || !list.isConnected) return false;
    const top = marker.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop;
    if (list.scrollHeight - top <= list.clientHeight + 48) return false;
    cancelForcedMessageScroll();
    messagesPinnedToBottom = false;
    list.scrollTop = Math.max(0, top - 8);
    return true;
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

  class PwCallTimer extends HTMLElement {
    constructor() {
      super();
      this._root = this.attachShadow({ mode: 'open' });
      this._text = document.createTextNode('0:00');
      this._root.append(this._text);
    }
    connectedCallback() { this.sync(); }
    static get observedAttributes() { return ['data-call-start']; }
    attributeChangedCallback() { this.sync(); }
    sync() {
      const started = Number(this.getAttribute('data-call-start') || 0);
      if (!Number.isFinite(started) || started <= 0) {
        this._text.nodeValue = '0:00';
        return;
      }
      const seconds = Math.max(0, Math.floor((Date.now() - started) / 1000));
      this._text.nodeValue = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
    }
  }
  if (!customElements.get('pw-call-timer')) customElements.define('pw-call-timer', PwCallTimer);

  let callTimerId = null;
  const updateCallTimers = () => {
    const timers = [
      ...document.querySelectorAll('pw-call-timer'),
      ...document.querySelectorAll('.pw-live-call-timer[data-call-start]:not(pw-call-timer)')
    ];
    if (!timers.length) {
      if (callTimerId) clearInterval(callTimerId);
      callTimerId = null;
      return;
    }
    timers.forEach((timer) => {
      if (typeof timer.sync === 'function') {
        timer.sync();
        return;
      }
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
      const heading = document.createElement('h3'); heading.textContent = 'Manage Wires';
      const list = document.createElement('div'); list.className = 'invite-link-list'; list.setAttribute('aria-live', 'polite');
      root.append(heading, list);
      const refresh = async () => {
        list.textContent = 'Loading Wires…';
        try {
          const invites = await accountApi('GET', `/server/${sid}/wires`);
          if (!root.isConnected) return;
          if (!Array.isArray(invites)) throw new Error('Could not load Wires');
          list.textContent = '';
          if (!invites.length) { list.textContent = 'No Wires yet.'; return; }
          for (const invite of invites) {
            const row = document.createElement('div'); row.className = 'invite-link-row';
            const copy = document.createElement('div'); copy.className = 'invite-link-info';
            const expired = invite.expires_at > 0 && invite.expires_at <= Date.now();
            const used = invite.max_uses > 0 && invite.uses >= invite.max_uses;
            const inactive = invite.revoked || expired || used;
            const title = document.createElement('b'); title.textContent = invite.revoked ? 'Revoked Wire' : expired ? 'Expired Wire' : used ? 'Use limit reached' : 'Active Wire';
            const detail = document.createElement('small');
            detail.textContent = `${invite.uses} / ${invite.max_uses || 'unlimited'} uses · ${invite.expires_at ? 'Expires ' + new Date(invite.expires_at).toLocaleString() : 'Never expires'}`;
            copy.append(title, detail); row.append(copy);
            if (!inactive) {
              const copyButton = document.createElement('button'); copyButton.type = 'button'; copyButton.className = 'btn secondary'; copyButton.textContent = 'Copy'; copyButton.setAttribute('aria-label', 'Copy Wire link');
              copyButton.addEventListener('click', async () => {
                try { await navigator.clipboard.writeText(`${location.origin}/#wire/${invite.code}`); copyButton.textContent = 'Copied'; }
                catch (_) { copyButton.textContent = 'Copy failed'; }
              });
              const revoke = document.createElement('button'); revoke.type = 'button'; revoke.className = 'btn ghost danger-text'; revoke.textContent = 'Revoke';
              revoke.addEventListener('click', async () => {
                revoke.disabled = true;
                try { await accountApi('DELETE', `/server/${sid}/wires/${encodeURIComponent(invite.code)}`); await refresh(); }
                catch (_) { revoke.disabled = false; revoke.textContent = 'Retry revoke'; }
              });
              row.append(copyButton, revoke);
            }
            list.append(row);
          }
        } catch (_) {
          if (!root.isConnected) return;
          list.textContent = 'Could not load Wires. ';
          const retry = document.createElement('button'); retry.className = 'btn secondary'; retry.type = 'button'; retry.textContent = 'Retry'; retry.addEventListener('click', refresh); list.append(retry);
        }
      };
      refresh();
    });
  };

  let messageDomFrame = 0;
  const changedMessageRoots = new Set();
  let timersChanged = false, invitesChanged = false, composerChanged = false, editorChanged = false, contextMenuChanged = false;
  const messageDomObserver = new MutationObserver((records) => {
    const contains = (node, selector) => node.matches?.(selector) || node.querySelector?.(selector);
    for (const record of records) {
      for (const node of [...record.addedNodes, ...record.removedNodes]) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (contains(node, 'pw-call-timer, .pw-live-call-timer')) timersChanged = true;
        if (contains(node, '.invite-manager')) invitesChanged = true;
        if (contains(node, '#compose')) composerChanged = true;
        if (node.isConnected && contains(node, '.message-edit-input')) editorChanged = true;
        if (node.isConnected && contains(node, '.ctx-menu')) contextMenuChanged = true;
        if (node.isConnected && contains(node, '#messages, .msg-body, .pw-media-player, .message-link')) changedMessageRoots.add(node.closest('.msg-body') || node);
      }
    }
    if (messageDomFrame || (!changedMessageRoots.size && !timersChanged && !invitesChanged && !composerChanged && !editorChanged && !contextMenuChanged)) return;
    messageDomFrame = requestAnimationFrame(() => {
      messageDomFrame = 0;
      const list = trackMessageScroll();
      if (list && pendingForcedMessageRoute === location.hash) {
        pendingForcedMessageRoute = null;
        if (!revealUnreadMarker(list)) scrollMessageListToBottom(true);
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
      if (editorChanged) {
        const editor = document.querySelector('.message-edit-input');
        if (editor && editor.offsetParent !== null && document.activeElement !== editor) {
          editor.focus({ preventScroll: true });
          const end = editor.value.length;
          editor.setSelectionRange?.(end, end);
        }
      }
      if (contextMenuChanged) {
        const menu = document.querySelector('.ctx-menu');
        if (menu) {
          const view = window.visualViewport;
          const viewportLeft = view?.offsetLeft || 0;
          const viewportTop = view?.offsetTop || 0;
          const viewportWidth = view?.width || window.innerWidth;
          const viewportHeight = view?.height || window.innerHeight;
          const requestedX = Number(menu.dataset.contextX || 0);
          const requestedY = Number(menu.dataset.contextY || 0);
          const rect = menu.getBoundingClientRect();
          const pad = 8;
          const left = Math.max(viewportLeft + pad, Math.min(requestedX, viewportLeft + viewportWidth - rect.width - pad));
          const top = Math.max(viewportTop + pad, Math.min(requestedY, viewportTop + viewportHeight - rect.height - pad));
          menu.style.left = `${Math.round(left)}px`;
          menu.style.top = `${Math.round(top)}px`;
          menu.style.maxHeight = `${Math.max(80, Math.floor(viewportHeight - pad * 2))}px`;
          menu.style.overflowY = 'auto';
          menu.querySelector('.ctx-item')?.focus({ preventScroll: true });
        }
      }
      timersChanged = invitesChanged = composerChanged = editorChanged = contextMenuChanged = false;
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
    outgoing: [[392, 0, 300, 0.025], [523.25, 240, 380, 0.022]],
    tour: [[659.25, 0, 130, 0.024], [783.99, 75, 170, 0.026], [987.77, 165, 230, 0.021]],
    tourMessage: [[783.99, 0, 150, 0.021], [1046.5, 95, 220, 0.019]],
    // Call cues stay short and quiet. Each shape is different: a falling pair
    // when you leave, one low note when someone else leaves, a rising pair when
    // someone joins, and a brief high pair when a viewer starts receiving your screen.
    selfLeave: [[523.25, 0, 130, 0.028], [349.23, 100, 190, 0.022]],
    peerLeave: [[196, 0, 170, 0.034]],
    peerJoin: [[659.25, 0, 90, 0.026], [880, 70, 140, 0.022]],
    screenWatch: [[1567.98, 0, 55, 0.016], [2093, 42, 75, 0.013]]
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
      const group = preview ? 'preview' : ['incoming', 'outgoing'].includes(name) ? 'ringtone' : 'effect';
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
    if (path === '/login' || path === '/register' || path === '/password' || path === '/password/forgot' || path === '/password/reset' || path === '/email' || path === '/email/verify' || path === '/email/resend' || path === '/email/remove') return '[redacted]';
    return body;
  };

  const clearSyncRecovery = (component) => {
    const state = syncRecovery.get(component);
    if (state?.timer) clearTimeout(state.timer);
    syncRecovery.delete(component);
  };

  const clearAllSyncRecovery = () => {
    for (const component of Array.from(syncRecovery.keys())) clearSyncRecovery(component);
    syncRecoveryNoticeShown = false;
  };

  const scheduleAuthReload = () => {
    if (authReloadScheduled) return;
    authReloadScheduled = true;
    clearAllSyncRecovery();
    debug('AUTH', 'session_expired_reload');
    // Yield once so any current fetch/finally handlers can unwind before Elm is
    // reinitialized into the signed-out state. This is intentionally one-shot.
    setTimeout(() => location.reload(), 0);
  };

  const kickSyncRecovery = (component) => {
    const current = syncRecovery.get(component);
    if (!current || authReloadScheduled) return;
    if (current.timer) clearTimeout(current.timer);
    current.timer = null;
    syncRecovery.set(component, current);
    if (!current.inFlight) scheduleSyncRecovery(component, 0);
  };

  const scheduleSyncRecovery = (component, delay = 500) => {
    const path = syncRecoveryPaths[component];
    if (!path || authReloadScheduled) return;
    const current = syncRecovery.get(component) || { attempts: 0, timer: null, inFlight: false };
    if (current.timer || current.inFlight) return;
    current.timer = setTimeout(async () => {
      current.timer = null;
      if (authReloadScheduled) return;
      if (!navigator.onLine) {
        syncRecovery.set(component, current);
        scheduleSyncRecovery(component, 1500);
        return;
      }
      current.inFlight = true;
      syncRecovery.set(component, current);
      const data = await performApi({ method: 'GET', path, silent: true });
      // A newer full sync/direct refresh may have cleared or replaced this
      // recovery while the request was in flight. Never resurrect stale state.
      if (syncRecovery.get(component) !== current) return;
      current.inFlight = false;
      if (authReloadScheduled) return;
      if (data !== null) {
        debug('API', 'sync_component_recovered', { component, attempts: current.attempts });
        clearSyncRecovery(component);
        return;
      }
      current.attempts += 1;
      if (current.attempts >= 3 && !syncRecoveryNoticeShown) {
        syncRecoveryNoticeShown = true;
        send(app.ports.bridgeReceive, {
          tag: 'toast',
          data: 'Some account data is reconnecting. Plainwire kept your existing view and will retry automatically.'
        });
      }
      syncRecovery.set(component, current);
      const nextDelay = current.attempts <= 5
        ? Math.min(8000, 500 * (2 ** current.attempts))
        : 30000;
      scheduleSyncRecovery(component, nextDelay);
    }, Math.max(0, delay));
    syncRecovery.set(component, current);
  };

  const performApi = async ({ method = 'GET', path, body, request_id = null, silent = false }) => {
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
      if (method === 'POST' && (/^\/channels\/\d+\/messages$/.test(path) || /^\/conversation\/\d+\/messages$/.test(path))) {
        stopTypingForCurrentComposer();
      }
      const res = await fetch('/api' + path, options);
      const json = await res.json().catch(() => ({ ok: false, error: 'bad_json' }));
      // HTTP and application envelopes must agree. Keeping one success bit avoids
      // clearing recovery state on a non-2xx response while telling Elm the same
      // request failed.
      const succeeded = res.ok && json.ok === true;
      debug('API', 'response', { method, path, status: res.status, ok: succeeded, duration_ms: Math.round(performance.now() - requestStarted), error: json.error });
      if (!succeeded && path === '/login' && json.error === 'account_restricted' && json.data) showAccountRestriction(json.data);
      if (res.status === 401 && json.error === 'not_authenticated' && !['/me', '/login', '/register', '/password/forgot', '/password/reset', '/email/verify'].includes(path)) {
        // A retry loop cannot repair an expired authenticated session. Reload
        // once so /me can render the signed-out shell instead of hammering
        // every recovery path. The unauthenticated boot /me request is excluded
        // to avoid a reload loop on the login screen.
        scheduleAuthReload();
      }
      if (method === 'GET' && /^\/(messages\?|thread\/|threads\?|profile\/|server\/|users\?)/.test(path) && requestRoute !== location.hash) return null;
      if (succeeded && json.data && json.data.csrf) csrf = json.data.csrf;
      if (succeeded && json.data && json.data.user && json.data.user.id) meId = json.data.user.id;
      if (succeeded && json.data) updatePresenceWatch(json.data);
      if (succeeded && path.startsWith('/sync?')) {
        const warnings = Array.isArray(json.data?.sync_warnings) ? json.data.sync_warnings.map(String) : [];
        const failed = new Set(warnings);
        if (warnings.length) debug('API', 'sync_degraded', { components: warnings }, 'warn');
        Object.keys(syncRecoveryPaths).forEach((component) => {
          if (failed.has(component)) scheduleSyncRecovery(component, 250);
          else clearSyncRecovery(component);
        });
        if (failed.size === 0 && syncRecovery.size === 0) syncRecoveryNoticeShown = false;
      } else if (method === 'GET') {
        const recoveredComponent = syncRecoveryComponentsByPath[path];
        if (succeeded && recoveredComponent) {
          clearSyncRecovery(recoveredComponent);
          if (syncRecovery.size === 0) syncRecoveryNoticeShown = false;
        } else if (!succeeded && recoveredComponent && !silent && !authReloadScheduled) {
          // Direct list refreshes (for example opening Friends) deserve the
          // same resilient recovery as a degraded bootstrap sync. Keep Elm's
          // last-known-good state and retry the one failed component only.
          scheduleSyncRecovery(recoveredComponent, 500);
        }
      }
      if (succeeded && method === 'POST' && path === '/logout') {
        clearAllSyncRecovery();
        resetTypingState({ skipNetwork: true });
      }
      if (succeeded && method === 'POST' && /^\/server\/\d+\/wires$/.test(path) && typeof json.data?.url === 'string' && (json.data.url.startsWith('#wire/') || json.data.url.startsWith('#invite/'))) {
        json.data.url = new URL(json.data.url.replace('#invite/', '#wire/'), location.origin + '/').href;
      }
      if (succeeded || !silent) {
        send(app.ports.apiReceive, {
          path,
          method,
          request_id,
          ok: succeeded,
          data: json.data ?? null,
          error: json.error || (succeeded ? null : 'request_failed')
        });
      }
      return succeeded ? json.data : null;
    } catch (error) {
      debug('API', 'request_failed', { method, path, duration_ms: Math.round(performance.now() - requestStarted), error: error.message }, silent ? 'warn' : 'error');
      const recoveryComponent = method === 'GET' ? syncRecoveryComponentsByPath[path] : undefined;
      if (!silent && recoveryComponent && !authReloadScheduled) scheduleSyncRecovery(recoveryComponent, 500);
      if (!silent) {
        send(app.ports.apiReceive, { path, method, request_id, ok: false, data: null, error: error.name === 'AbortError' ? 'request_timeout' : 'request_failed' });
      }
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


  // Realtime remains the fast path. This low-frequency reconciliation is a
  // safety net for an event missed without an obvious socket failure (proxy
  // oddities, suspended mobile tabs, or a server-side subscription race). It
  // only runs for a visible/authenticated/online tab and refreshes the current
  // route rather than polling every surface in the application.
  const APP_RECONCILE_MS = 180000;
  const reconcileVisibleApp = (reason = 'periodic') => {
    if (!meId || document.hidden || !navigator.onLine) return;
    debug('SYNC', 'visible_reconcile', { reason, route: location.hash || '#' });
    api({ method: 'GET', path: '/sync?since=0' });
    applyClientExtensions().catch((error) => console.warn('[Plainwire:EXT] apply_failed', error));
  refreshGlobalBanners();

    const hash = String(location.hash || '#').replace(/^#\/?/, '');
    let match = hash.match(/^dm\/(\d+)$/);
    if (match) {
      api({ method: 'GET', path: `/messages?scope=direct&scope_id=${match[1]}` });
      api({ method: 'GET', path: `/conversation/${match[1]}` });
      return;
    }
    match = hash.match(/^channel\/(\d+)$/);
    if (match) { api({ method: 'GET', path: `/messages?scope=channel&scope_id=${match[1]}` }); return; }
    match = hash.match(/^server\/(\d+)$/);
    if (match) { api({ method: 'GET', path: `/server/${match[1]}` }); return; }
    match = hash.match(/^profile\/(\d+)$/);
    if (match) { api({ method: 'GET', path: `/profile/${match[1]}` }); return; }
    match = hash.match(/^(?:f|forum)\/(\d+)$/);
    if (match) { api({ method: 'GET', path: `/threads?forum_id=${match[1]}` }); return; }
    match = hash.match(/^(?:t|thread)\/(\d+)$/);
    if (match) { api({ method: 'GET', path: `/thread/${match[1]}` }); return; }
    if (hash === 'friends') api({ method: 'GET', path: '/friends' });
    else if (hash === 'forums') api({ method: 'GET', path: '/forums' });
  };

  setInterval(() => reconcileVisibleApp('periodic_safety_net'), APP_RECONCILE_MS);

  // The public banner endpoint exposes only announcements whose start time has
  // arrived, so future operator announcements are not leaked before schedule.
  // A tiny visibility-aware poll gives scheduled banners minute-level activation
  // even when no operator mutation occurs at the exact start time. Realtime is
  // still the fast path for create/edit/pause/delete operations.
  const PUBLIC_BANNER_RECONCILE_MS = 60000;
  setInterval(() => {
    if (!document.hidden && navigator.onLine) refreshGlobalBanners();
  }, PUBLIC_BANNER_RECONCILE_MS);

  const activeComposer = () => {
    const composers = Array.from(document.querySelectorAll('#compose'));
    return composers.reverse().find((element) => element.offsetParent !== null) || null;
  };

  // Typing state is deliberately ephemeral: no database writes, no replay after
  // reconnect, and no "typing forever" if a tab disappears. The sender refreshes
  // at a low cadence while text is changing; receivers expire stale state even if
  // an inactive packet is lost.
  const TYPING_IDLE_MS = 5200;
  const TYPING_REFRESH_MS = 3000;
  const TYPING_REMOTE_TTL_MS = 7500;
  const typingTabId = globalThis.crypto?.randomUUID?.() || `typing-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const typingRemote = new Map();
  const typingClaims = new Map();
  let localTyping = null;
  let typingIdleTimer = null;
  let typingSweepTimer = null;
  const typingBroadcast = (() => {
    try { return typeof BroadcastChannel === 'function' ? new BroadcastChannel('plainwire-typing-v1') : null; }
    catch (_) { return null; }
  })();

  const parseTypingScope = (scopeKey) => {
    const match = /^(direct|channel|thread):(\d+)$/.exec(String(scopeKey || ''));
    if (!match) return null;
    const id = Number(match[2]);
    return Number.isSafeInteger(id) && id > 0 ? { key: `${match[1]}:${id}`, scope: match[1], id } : null;
  };
  const composerTypingScope = (composer = activeComposer()) => parseTypingScope(composer?.closest?.('.composer')?.dataset?.draft);
  const emitTyping = (scope, active) => {
    if (!scope) return;
    sendWs({ type: 'typing', scope: scope.scope, scope_id: scope.id, active: active === true });
  };
  const announceTypingClaim = (scope, active) => {
    const message = { tab: typingTabId, scope: scope?.key || '', active: active === true, expires: Date.now() + TYPING_IDLE_MS + 800 };
    try { typingBroadcast?.postMessage(message); } catch (_) {}
    if (!scope) return;
    let claims = typingClaims.get(scope.key);
    if (!claims) { claims = new Map(); typingClaims.set(scope.key, claims); }
    if (active) claims.set(typingTabId, message.expires);
    else claims.delete(typingTabId);
  };
  const pruneTypingClaims = (scopeKey) => {
    const claims = typingClaims.get(scopeKey);
    if (!claims) return false;
    const now = Date.now();
    for (const [tab, expires] of claims) if (expires <= now) claims.delete(tab);
    if (!claims.size) { typingClaims.delete(scopeKey); return false; }
    return true;
  };
  typingBroadcast?.addEventListener('message', (event) => {
    const msg = event.data;
    if (!msg || msg.tab === typingTabId || typeof msg.scope !== 'string') return;
    const scope = parseTypingScope(msg.scope);
    if (!scope) return;
    let claims = typingClaims.get(scope.key);
    if (!claims) { claims = new Map(); typingClaims.set(scope.key, claims); }
    if (msg.active === true) claims.set(String(msg.tab || ''), Number(msg.expires) || (Date.now() + TYPING_IDLE_MS));
    else claims.delete(String(msg.tab || ''));
  });

  const stopTyping = (scope = localTyping?.scope, { skipNetwork = false } = {}) => {
    if (typingIdleTimer) { clearTimeout(typingIdleTimer); typingIdleTimer = null; }
    if (!scope) { localTyping = null; return; }
    announceTypingClaim(scope, false);
    if (localTyping?.scope?.key === scope.key) localTyping = null;
    if (skipNetwork) return;
    // Give a sibling tab's BroadcastChannel claim one turn to arrive before
    // sending inactive. Without this, one tab blurring could erase another tab's
    // still-active indicator for the same account.
    setTimeout(() => {
      if (!pruneTypingClaims(scope.key)) emitTyping(scope, false);
    }, 40);
  };
  const refreshLocalTyping = (composer) => {
    const scope = composerTypingScope(composer);
    if (!scope || !composer || !String(composer.value || '').trim()) {
      if (localTyping) stopTyping(localTyping.scope);
      return;
    }
    if (localTyping?.scope?.key && localTyping.scope.key !== scope.key) stopTyping(localTyping.scope);
    const now = Date.now();
    const lastSent = localTyping?.scope?.key === scope.key ? localTyping.lastSent : 0;
    localTyping = { scope, lastSent };
    announceTypingClaim(scope, true);
    if (!lastSent || now - lastSent >= TYPING_REFRESH_MS) {
      emitTyping(scope, true);
      localTyping.lastSent = now;
    }
    if (typingIdleTimer) clearTimeout(typingIdleTimer);
    typingIdleTimer = setTimeout(() => stopTyping(scope), TYPING_IDLE_MS);
  };
  const stopTypingForCurrentComposer = () => {
    const scope = composerTypingScope();
    if (scope) stopTyping(scope);
    else if (localTyping) stopTyping(localTyping.scope);
  };

  const typingLabel = (actors) => {
    const names = actors.map((actor) => actor.display_name || actor.username || 'Someone');
    if (names.length === 1) return `${names[0]} is typing`;
    if (names.length === 2) return `${names[0]} and ${names[1]} are typing`;
    if (names.length === 3) return `${names[0]}, ${names[1]}, and ${names[2]} are typing`;
    return `${names[0]}, ${names[1]}, and ${names.length - 2} others are typing`;
  };
  const typingActorsFor = (scopeKey) => {
    const bucket = typingRemote.get(scopeKey);
    if (!bucket) return [];
    const now = Date.now();
    for (const [uid, actor] of bucket) if (actor.expires <= now) bucket.delete(uid);
    if (!bucket.size) typingRemote.delete(scopeKey);
    return [...bucket.values()].sort((a, b) => a.startedAt - b.startedAt);
  };
  const refreshTypingIndicators = (scopeKey = null) => {
    document.querySelectorAll('pw-typing-indicator').forEach((node) => {
      if (!scopeKey || node.getAttribute('data-scope') === scopeKey) node.render?.();
    });
  };
  const clearRemoteTyping = (predicate = () => true) => {
    const changedScopes = [];
    for (const scopeKey of typingRemote.keys()) {
      if (predicate(scopeKey)) { typingRemote.delete(scopeKey); changedScopes.push(scopeKey); }
    }
    changedScopes.forEach(refreshTypingIndicators);
  };
  const resetTypingState = ({ skipNetwork = true } = {}) => {
    if (localTyping) stopTyping(localTyping.scope, { skipNetwork });
    if (typingIdleTimer) { clearTimeout(typingIdleTimer); typingIdleTimer = null; }
    typingClaims.clear();
    clearRemoteTyping();
  };
  const setSyntheticTyping = (scopeKey, actor, active) => {
    if (!scopeKey || !actor?.user_id) return;
    let bucket = typingRemote.get(scopeKey);
    if (!bucket) { bucket = new Map(); typingRemote.set(scopeKey, bucket); }
    if (active) {
      const previous = bucket.get(String(actor.user_id));
      bucket.set(String(actor.user_id), { ...actor, startedAt: previous?.startedAt || Date.now(), expires: Date.now() + TYPING_REMOTE_TTL_MS });
    } else {
      bucket.delete(String(actor.user_id));
      if (!bucket.size) typingRemote.delete(scopeKey);
    }
    refreshTypingIndicators(scopeKey);
  };
  const handleTypingEvent = (msg) => {
    if (msg?.type !== 'typing') return false;
    const scope = parseTypingScope(`${msg.scope}:${msg.scope_id}`);
    if (!scope) return true;
    if (Number(msg.user_id) === Number(meId)) return true;
    const actor = {
      user_id: String(msg.user_id),
      username: String(msg.username || ''),
      display_name: String(msg.display_name || msg.username || 'Someone'),
      avatar_url: String(msg.avatar_url || ''),
      startedAt: Date.now(),
      expires: Date.now() + TYPING_REMOTE_TTL_MS
    };
    setSyntheticTyping(scope.key, actor, msg.active === true);
    return true;
  };

  class PlainwireTypingIndicator extends HTMLElement {
    static get observedAttributes() { return ['data-scope']; }
    connectedCallback() { this.render(); }
    attributeChangedCallback() { this.render(); }
    render() {
      const actors = typingActorsFor(this.getAttribute('data-scope') || '');
      this.replaceChildren();
      this.classList.toggle('is-active', actors.length > 0);
      if (!actors.length) { this.setAttribute('aria-hidden', 'true'); return; }
      this.removeAttribute('aria-hidden');
      const label = document.createElement('span');
      label.className = 'typing-label';
      label.textContent = typingLabel(actors);
      const dots = document.createElement('span');
      dots.className = 'typing-dots';
      dots.setAttribute('aria-hidden', 'true');
      dots.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
      this.append(label, dots);
    }
  }
  if (!customElements.get('pw-typing-indicator')) customElements.define('pw-typing-indicator', PlainwireTypingIndicator);
  typingSweepTimer = setInterval(() => {
    let changed = false;
    for (const [scopeKey, bucket] of typingRemote) {
      const before = bucket.size;
      typingActorsFor(scopeKey);
      if (bucket.size !== before) changed = true;
    }
    if (changed) refreshTypingIndicators();
  }, 1000);

  document.addEventListener('input', (event) => {
    if (event.target instanceof HTMLTextAreaElement && event.target.id === 'compose') refreshLocalTyping(event.target);
  }, true);
  document.addEventListener('focusout', (event) => {
    if (event.target instanceof HTMLTextAreaElement && event.target.id === 'compose') stopTyping(composerTypingScope(event.target));
  }, true);
  window.addEventListener('hashchange', () => { if (localTyping) stopTyping(localTyping.scope); });
  window.addEventListener('pagehide', () => {
    // Do not broadcast a definitive inactive packet while the document is
    // disappearing. A sibling Plainwire tab may still be typing for this same
    // account, and pagehide timers are not reliable enough to coordinate that
    // handoff. Receivers already expire typing state after a short TTL; active
    // sibling tabs keep refreshing it normally.
    if (localTyping) stopTyping(localTyping.scope, { skipNetwork: true });
    try { typingBroadcast?.close?.(); } catch (_) {}
  });

  // First-run onboarding lives outside the message database on purpose. Account
  // progress is durable, but the guide's messages are delivered live only after
  // the user opens Plainwire's welcome conversation.
  const ONBOARDING_SCOPE = 'onboarding:0';
  const ONBOARDING_ACTOR = {
    user_id: 'plainwire-guide', username: 'plainwire', display_name: 'Plainwire', avatar_url: ''
  };
  const onboardingEntries = new Set();
  let onboardingState = null;
  let onboardingStateRequest = null;
  let onboardingHopTimer = null;
  let onboardingChatNode = null;
  let onboardingGuideNode = null;
  let onboardingSpotlightNode = null;
  let onboardingSpotlightTarget = null;
  let onboardingSpotlightRaf = 0;
  let onboardingEpoch = 0;
  let onboardingGuideActive = false;
  let onboardingTourLock = false;
  let onboardingMaskNode = null;

  const onboardingSteps = [
    {
      route: '#dms', selector: '.rail-btn[aria-label="Direct messages"]', mobileSelector: '.mobile-nav-btn[aria-label^="Messages"]',
      title: 'Your conversations live here',
      body: 'Direct Messages keeps one-to-one chats and groups together. Unread conversations rise naturally, and the × on a one-to-one DM hides it without deleting the history.',
      hint: 'Tip: Alt + Shift + ↑ / ↓ jumps between unread DMs.'
    },
    {
      route: '#dms', selector: '.dm-inbox .page-heading .btn', mobileSelector: '.dm-inbox .page-heading .btn',
      title: 'Start with people, not setup',
      body: 'New message lets you start a DM or build a group. Group owners can promote moderators, remove members, and manage the conversation without leaving chat.',
      hint: 'Groups keep explicit owner / moderator / member authority.'
    },
    {
      route: '#friends', selector: '.rail-btn[aria-label="Friends"]', mobileSelector: '.mobile-nav-btn[aria-label^="Friends"]',
      title: 'Friends and people',
      body: 'Friends is the cleanest place to find people you already know, handle requests, open profiles, and jump into a conversation or call.',
      hint: 'Clicking @mentions anywhere also opens that person’s profile.'
    },
    {
      route: '#new-server', selector: '.server-create-form', mobileSelector: '.server-create-form',
      title: 'Servers can grow with you',
      body: 'A server starts simple, then owners can add channels, categories, colored roles, permissions, per-server profiles, moderation, voice rooms, and Wires for inviting people.',
      hint: 'Nothing here forces you to create one right now.'
    },
    {
      route: '#dms', selector: '.workspace-menu > summary', mobileSelector: '.mobile-nav-btn[aria-label^="Servers"]',
      title: 'Wires connect people to servers',
      body: 'Open Workspace whenever you want to create a server or join one with a Wire. Wires are Plainwire’s server access links, with usage and expiry controls for moderators.',
      hint: 'Old invite links still work, but new links are Wires.'
    },
    {
      route: '#forums', selector: '.rail-btn[aria-label="Forums"]', mobileSelector: '.forum-directory-hero',
      title: 'Longer conversations belong in f/ and t/',
      body: 'Forums are f/ spaces and individual discussions are t/ threads. Threads support replies, editing, pinning, locking, moderation, and Markdown while keeping the interface distinctly Plainwire.',
      hint: 'Use chat for live conversation and threads when the discussion should stay easy to revisit.'
    },
    {
      route: '#dms', selector: '[data-open-switcher]', mobileSelector: '[data-open-switcher]',
      title: 'Jump instead of hunting',
      body: 'The quick switcher searches conversations, servers, channels, and destinations from one keyboard-friendly surface.',
      hint: 'Ctrl / Cmd + K opens it from almost anywhere.'
    },
    {
      route: '#settings', selector: '.rail-btn[aria-label="Settings"]', mobileSelector: '.mobile-nav-btn[aria-label^="You"]',
      title: 'Make Plainwire yours',
      body: 'Settings covers identity, appearance, chat behavior, voice and screen-sharing devices, alerts, privacy, sessions, diagnostics, and the full shortcut sheet.',
      hint: 'The tour can be replayed later from Account settings.'
    },
    {
      route: '#notifications', selector: '.side a[href="#notifications"]', mobileSelector: '.notifications-head',
      title: 'Mentions and activity stay out of the way',
      body: 'Notifications collects mentions and useful activity without turning every event into a modal. Calls and live voice still surface immediately when they need you.',
      hint: 'Ctrl / Cmd + I opens activity quickly.'
    }
  ];

  const reducedMotion = () => document.documentElement.dataset.reduceMotion === 'true'
    || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;
  const sleep = (ms) => new Promise(resolve => setTimeout(resolve, Math.max(0, ms)));
  const updateOnboardingEntries = () => onboardingEntries.forEach(entry => entry.render?.());
  const setOnboardingState = (state) => {
    if (state && typeof state === 'object') onboardingState = {
      state: String(state.state || 'complete'),
      step: Math.max(0, Number(state.step) || 0),
      updated_at: Number(state.updated_at) || 0
    };
    updateOnboardingEntries();
    scheduleOnboardingHop();
    return onboardingState;
  };
  const loadOnboardingState = async ({ force = false } = {}) => {
    if (onboardingState && !force) return onboardingState;
    if (onboardingStateRequest) return onboardingStateRequest;
    onboardingStateRequest = directApi('/onboarding')
      .then(setOnboardingState)
      .catch((error) => {
        debug('TOUR', 'state_load_failed', { error: error.message }, 'warn');
        return null;
      })
      .finally(() => { onboardingStateRequest = null; });
    return onboardingStateRequest;
  };
  const mutateOnboarding = async (action, body = null) => {
    const state = await directApi(`/onboarding/${action}`, { method: 'POST', body });
    return setOnboardingState(state);
  };

  const clearOnboardingHop = () => {
    if (onboardingHopTimer) clearTimeout(onboardingHopTimer);
    onboardingHopTimer = null;
    onboardingEntries.forEach(entry => entry.classList.remove('is-hopping'));
  };
  const scheduleOnboardingHop = () => {
    clearOnboardingHop();
    if (!onboardingState || !['pending', 'active'].includes(onboardingState.state) || onboardingChatNode || onboardingGuideActive) return;
    const delay = 4300 + Math.floor(Math.random() * 1700);
    onboardingHopTimer = setTimeout(() => {
      const visible = [...onboardingEntries].filter(entry => !entry.hidden && entry.isConnected && entry.offsetParent !== null);
      if (visible.length) {
        visible.forEach(entry => {
          entry.classList.remove('is-hopping');
          void entry.offsetWidth;
          entry.classList.add('is-hopping');
          setTimeout(() => entry.classList.remove('is-hopping'), reducedMotion() ? 500 : 900);
        });
        playSound('tour');
      }
      scheduleOnboardingHop();
    }, delay);
  };

  class PlainwireOnboardingEntry extends HTMLElement {
    connectedCallback() {
      onboardingEntries.add(this);
      this.render();
      loadOnboardingState().then(() => this.render());
    }
    disconnectedCallback() { onboardingEntries.delete(this); }
    render() {
      const state = onboardingState?.state;
      const visible = state === 'pending' || state === 'active';
      this.hidden = !visible;
      this.replaceChildren();
      if (!visible) return;
      const variant = this.dataset.variant === 'inbox' ? 'inbox' : 'sidebar';
      this.className = `pw-onboarding-entry pw-onboarding-entry-${variant}${this.classList.contains('is-hopping') ? ' is-hopping' : ''}`;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'pw-onboarding-entry-button';
      button.setAttribute('aria-label', onboardingState?.step > 0 ? 'Resume Plainwire welcome tour' : 'Open Plainwire welcome message');
      const mark = document.createElement('span'); mark.className = 'pw-onboarding-mark'; mark.textContent = 'P'; mark.setAttribute('aria-hidden', 'true');
      const copy = document.createElement('span'); copy.className = 'pw-onboarding-entry-copy';
      const title = document.createElement('strong'); title.textContent = 'Plainwire';
      const sub = document.createElement('small'); sub.textContent = onboardingState?.step > 0 ? 'Continue your tour' : 'Welcome — start here';
      copy.append(title, sub);
      const dot = document.createElement('span'); dot.className = 'pw-onboarding-unread'; dot.setAttribute('aria-hidden', 'true');
      button.append(mark, copy, dot);
      if (variant === 'inbox') {
        const description = document.createElement('span');
        description.className = 'pw-onboarding-entry-description';
        description.textContent = 'A short interactive tour that moves with you and explains Plainwire as you use it.';
        copy.append(description);
      }
      button.addEventListener('click', () => {
        if (onboardingTourLock || onboardingChatNode) return;
        onboardingTourLock = true;
        openOnboardingChat().catch((error) => {
          send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not open the welcome tour: ${error.message}` });
        }).finally(() => { onboardingTourLock = false; });
      });
      this.append(button);
    }
  }
  if (!customElements.get('pw-onboarding-entry')) customElements.define('pw-onboarding-entry', PlainwireOnboardingEntry);

  const clearTourTarget = () => {
    document.querySelectorAll('.pw-tour-target').forEach((node) => node.classList.remove('pw-tour-target'));
  };
  const removeTourMask = () => {
    onboardingMaskNode?.remove();
    onboardingMaskNode = null;
  };
  const ensureTourMask = () => {
    if (onboardingMaskNode?.isConnected) return onboardingMaskNode;
    const mask = document.createElement('div');
    mask.className = 'pw-tour-mask';
    mask.setAttribute('aria-hidden', 'true');
    document.body.append(mask);
    onboardingMaskNode = mask;
    return mask;
  };
  const removeTourSpotlight = () => {
    if (onboardingSpotlightRaf) cancelAnimationFrame(onboardingSpotlightRaf);
    onboardingSpotlightRaf = 0;
    onboardingSpotlightTarget = null;
    onboardingSpotlightNode?.remove();
    onboardingSpotlightNode = null;
    clearTourTarget();
    if (!onboardingGuideActive && !onboardingChatNode) removeTourMask();
  };
  const positionTourSpotlight = () => {
    onboardingSpotlightRaf = 0;
    const target = onboardingSpotlightTarget;
    const node = onboardingSpotlightNode;
    if (!node) return;
    if (!target?.isConnected) { removeTourSpotlight(); return; }
    const rect = target.getBoundingClientRect();
    const pad = 7;
    const viewportWidth = window.visualViewport?.width || innerWidth;
    const viewportHeight = window.visualViewport?.height || innerHeight;
    if (onboardingGuideNode) onboardingGuideNode.classList.toggle('is-top', rect.top + rect.height / 2 > viewportHeight * .58);
    node.style.left = `${Math.max(4, rect.left - pad)}px`;
    node.style.top = `${Math.max(4, rect.top - pad)}px`;
    node.style.width = `${Math.max(12, Math.min(rect.right + pad, viewportWidth - 4) - Math.max(4, rect.left - pad))}px`;
    node.style.height = `${Math.max(12, Math.min(rect.bottom + pad, viewportHeight - 4) - Math.max(4, rect.top - pad))}px`;
  };
  const requestTourSpotlightPosition = () => {
    if (!onboardingSpotlightRaf) onboardingSpotlightRaf = requestAnimationFrame(positionTourSpotlight);
  };
  const spotlightTourTarget = (target) => {
    removeTourSpotlight();
    ensureTourMask();
    if (!target) return;
    const node = document.createElement('div');
    node.className = 'pw-tour-spotlight';
    node.setAttribute('aria-hidden', 'true');
    document.body.append(node);
    onboardingSpotlightNode = node;
    onboardingSpotlightTarget = target;
    target.classList.add('pw-tour-target');
    target.scrollIntoView?.({ block: 'nearest', inline: 'nearest', behavior: reducedMotion() ? 'auto' : 'smooth' });
    requestTourSpotlightPosition();
  };
  window.addEventListener('resize', requestTourSpotlightPosition, { passive: true });
  window.addEventListener('scroll', requestTourSpotlightPosition, { passive: true, capture: true });
  window.visualViewport?.addEventListener?.('resize', requestTourSpotlightPosition, { passive: true });
  window.visualViewport?.addEventListener?.('scroll', requestTourSpotlightPosition, { passive: true });

  const usableTourTarget = (selector) => {
    if (!selector) return null;
    for (const node of document.querySelectorAll(selector)) {
      if (!node?.isConnected) continue;
      const style = getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
      if (rect.width < 2 || rect.height < 2) continue;
      return node;
    }
    return null;
  };
  const tourSelector = (step) => window.matchMedia?.('(max-width: 760px)').matches
    ? (step.mobileSelector || step.selector)
    : step.selector;
  const waitForTourTarget = (selector, timeoutMs = 4000) => new Promise((resolve) => {
    const immediate = usableTourTarget(selector);
    if (immediate) return resolve(immediate);
    if (!selector) return resolve(null);
    let done = false;
    let checks = 0;
    const finish = (node) => {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      clearInterval(poll);
      observer.disconnect();
      resolve(node || usableTourTarget(selector));
    };
    const observer = new MutationObserver(() => {
      const found = usableTourTarget(selector);
      if (found) finish(found);
    });
    const poll = setInterval(() => {
      checks += 1;
      const found = usableTourTarget(selector);
      if (found || checks >= 20) finish(found);
    }, 200);
    const timeout = setTimeout(() => finish(usableTourTarget(selector)), timeoutMs);
    observer.observe(document.getElementById('app') || document.body, { childList: true, subtree: true });
  });

  const closeOnboardingChat = ({ resumeHop = true } = {}) => {
    onboardingEpoch += 1;
    setSyntheticTyping(ONBOARDING_SCOPE, ONBOARDING_ACTOR, false);
    onboardingChatNode?.remove();
    onboardingChatNode = null;
    if (!onboardingGuideActive) {
      removeTourSpotlight();
      removeTourMask();
    }
    if (resumeHop) scheduleOnboardingHop();
  };
  const closeOnboardingGuide = () => {
    setSyntheticTyping(ONBOARDING_SCOPE, ONBOARDING_ACTOR, false);
    onboardingGuideNode?.remove();
    onboardingGuideNode = null;
    onboardingGuideActive = false;
    removeTourSpotlight();
    removeTourMask();
  };

  const onboardingBotSay = async (messages, { container, epoch, typingMs = 900 } = {}) => {
    const lines = (Array.isArray(messages) ? messages : [messages])
      .map((item) => String(item || '').trim())
      .filter(Boolean)
      .slice(0, 8);
    for (const item of lines) {
      if (epoch !== onboardingEpoch || !container?.isConnected) return false;
      setSyntheticTyping(ONBOARDING_SCOPE, ONBOARDING_ACTOR, true);
      const pause = reducedMotion()
        ? Math.min(220, 80 + Math.min(120, item.length * 2))
        : typingMs + Math.min(650, item.length * 9);
      await sleep(pause);
      if (epoch !== onboardingEpoch || !container?.isConnected) return false;
      setSyntheticTyping(ONBOARDING_SCOPE, ONBOARDING_ACTOR, false);
      const row = document.createElement('div'); row.className = 'pw-tour-message';
      const avatar = document.createElement('span'); avatar.className = 'pw-tour-message-avatar'; avatar.textContent = 'P'; avatar.setAttribute('aria-hidden', 'true');
      const body = document.createElement('div'); body.className = 'pw-tour-message-body';
      const name = document.createElement('strong'); name.textContent = 'Plainwire';
      const bubble = document.createElement('p'); bubble.textContent = item;
      body.append(name, bubble); row.append(avatar, body); container.append(row);
      try { playSound('tourMessage'); } catch (_) {}
      container.scrollTo?.({ top: container.scrollHeight, behavior: reducedMotion() ? 'auto' : 'smooth' });
      await sleep(reducedMotion() ? 90 : 260);
    }
    return epoch === onboardingEpoch && !!container?.isConnected;
  };

  const makeTourAction = (label, className, handler) => {
    const button = document.createElement('button');
    button.type = 'button'; button.className = className; button.textContent = label;
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (button.disabled) return;
      button.disabled = true;
      Promise.resolve(handler(event)).catch(() => {}).finally(() => {
        if (button.isConnected) button.disabled = false;
      });
    });
    return button;
  };

  const dismissOnboarding = async () => {
    try {
      await mutateOnboarding('dismiss');
      closeOnboardingChat({ resumeHop: false });
      closeOnboardingGuide();
      updateOnboardingEntries();
    } catch (error) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not save that choice: ${error.message}` });
    }
  };

  const confirmSkipTour = (host, restore) => {
    if (!host) return dismissOnboarding();
    host.replaceChildren();
    const note = document.createElement('p');
    note.className = 'pw-tour-guide-hint';
    note.textContent = 'Skip the welcome tour? You can replay it later from Settings → Account.';
    host.append(
      note,
      makeTourAction('Keep going', 'btn', () => { if (typeof restore === 'function') restore(); else openOnboardingChat().catch(() => {}); }),
      makeTourAction('Skip tour', 'btn ghost', dismissOnboarding)
    );
  };

  const renderOnboardingSourceCard = (container) => {
    const card = document.createElement('div'); card.className = 'pw-tour-source-card';
    const icon = document.createElement('span'); icon.className = 'pw-tour-source-icon'; icon.textContent = '</>'; icon.setAttribute('aria-hidden', 'true');
    const copy = document.createElement('div');
    const title = document.createElement('strong'); title.textContent = 'Plainwire source code';
    const repo = document.createElement('small'); repo.textContent = clientConfig.sourceRepository;
    copy.append(title, repo);
    const actions = document.createElement('div'); actions.className = 'pw-tour-source-actions';
    const open = makeTourAction('Open repository', 'btn', () => window.open(clientConfig.sourceRepository, '_blank', 'noopener,noreferrer'));
    const copyButton = makeTourAction('Copy link', 'btn secondary', async () => {
      try { await navigator.clipboard.writeText(clientConfig.sourceRepository); copyButton.textContent = 'Copied'; }
      catch (_) { send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not access the clipboard.' }); }
    });
    actions.append(open, copyButton); card.append(icon, copy, actions); container.append(card);
  };

  const finishOnboarding = async () => {
    closeOnboardingGuide();
    const navigationEpoch = ++onboardingEpoch;
    location.hash = '#dms';
    await sleep(160);
    if (navigationEpoch !== onboardingEpoch) return;
    const chat = await openOnboardingChat({ final: true, skipStart: true });
    if (!chat) return;
    const epoch = onboardingEpoch;
    const messages = chat.querySelector('.pw-onboarding-messages');
    const ok = await onboardingBotSay([
      'That’s the core of Plainwire. You can keep using it normally from here — the guide gets out of your way.',
      'One last thing: Plainwire is open source. If you ever want to inspect it, self-host it, report an issue, or build on it, this is the real repository.'
    ], { container: messages, epoch });
    if (!ok) return;
    renderOnboardingSourceCard(messages);
    const actions = chat.querySelector('.pw-onboarding-actions');
    actions.replaceChildren(makeTourAction('Finish', 'btn', async () => {
      try {
        await mutateOnboarding('complete');
        updateOnboardingEntries();
        const done = document.createElement('span'); done.className = 'pw-tour-complete'; done.textContent = 'Tour complete ✓';
        actions.replaceChildren(done, makeTourAction('Close', 'btn secondary', () => closeOnboardingChat({ resumeHop: false })));
      } catch (error) {
        send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not save tour completion: ${error.message}` });
      }
    }));
  };

  const renderTourGuide = async (stepNumber, step, target, epoch) => {
    if (epoch !== onboardingEpoch) return;
    closeOnboardingGuide();
    if (epoch !== onboardingEpoch) return;
    onboardingGuideActive = true;
    clearOnboardingHop();
    ensureTourMask();
    spotlightTourTarget(target && target.isConnected ? target : null);
    const guide = document.createElement('aside'); guide.className = 'pw-tour-guide'; guide.setAttribute('role', 'dialog'); guide.setAttribute('aria-label', 'Plainwire tour guide'); guide.tabIndex = -1;
    const head = document.createElement('div'); head.className = 'pw-tour-guide-head';
    const mark = document.createElement('span'); mark.className = 'pw-onboarding-mark compact'; mark.textContent = 'P'; mark.setAttribute('aria-hidden', 'true');
    const headCopy = document.createElement('div'); const brand = document.createElement('strong'); brand.textContent = 'Plainwire guide';
    const progress = document.createElement('small'); progress.textContent = `${stepNumber} of ${onboardingSteps.length}`; headCopy.append(brand, progress);
    const pause = document.createElement('button'); pause.type = 'button'; pause.className = 'pw-tour-guide-close'; pause.textContent = '×'; pause.setAttribute('aria-label', 'Pause tour');
    pause.addEventListener('click', () => { closeOnboardingGuide(); scheduleOnboardingHop(); });
    head.append(mark, headCopy, pause);
    const body = document.createElement('div'); body.className = 'pw-tour-guide-body';
    const title = document.createElement('h3'); title.textContent = step.title;
    const message = document.createElement('p'); message.textContent = step.body;
    const hint = document.createElement('small'); hint.className = 'pw-tour-guide-hint';
    hint.textContent = target ? step.hint : (step.hint + ' This control was not visible, so the guide stayed on screen instead of waiting.');
    body.append(title, message, hint);
    const footer = document.createElement('div'); footer.className = 'pw-tour-guide-actions';
    const mountActions = () => {
      footer.replaceChildren();
      if (stepNumber > 1) footer.append(makeTourAction('Back', 'btn secondary', () => showTourStep(stepNumber - 1)));
      footer.append(
        makeTourAction('Skip tour', 'btn ghost', () => confirmSkipTour(footer, mountActions)),
        makeTourAction(stepNumber === onboardingSteps.length ? 'Back to Plainwire' : 'Next', 'btn', () => {
          if (stepNumber === onboardingSteps.length) finishOnboarding(); else showTourStep(stepNumber + 1);
        })
      );
    };
    mountActions();
    const progressBar = document.createElement('div'); progressBar.className = 'pw-tour-progress';
    progressBar.setAttribute('role', 'progressbar'); progressBar.setAttribute('aria-label', 'Tour progress');
    progressBar.setAttribute('aria-valuemin', '0'); progressBar.setAttribute('aria-valuemax', String(onboardingSteps.length)); progressBar.setAttribute('aria-valuenow', String(stepNumber));
    onboardingSteps.forEach((_, index) => { const segment = document.createElement('span'); segment.classList.toggle('is-complete', index < stepNumber); progressBar.append(segment); });
    guide.append(head, progressBar, body, footer); document.body.append(guide); onboardingGuideNode = guide;
    if (window.matchMedia?.('(max-width: 760px)').matches && target) {
      const targetRect = target.getBoundingClientRect();
      const viewportHeight = window.visualViewport?.height || window.innerHeight;
      guide.classList.toggle('is-top', targetRect.top + targetRect.height / 2 > viewportHeight * 0.58);
    }
    guide.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') { event.preventDefault(); closeOnboardingGuide(); scheduleOnboardingHop(); }
    });
    try { playSound('tourMessage'); } catch (_) {}
    requestAnimationFrame(() => { guide.classList.add('is-visible'); guide.focus({ preventScroll: true }); });
  };

  const showTourStep = async (stepNumber) => {
    const step = onboardingSteps[stepNumber - 1];
    if (!step) return finishOnboarding();
    if (onboardingTourLock) return;
    onboardingTourLock = true;
    closeOnboardingChat({ resumeHop: false });
    clearOnboardingHop();
    const epoch = ++onboardingEpoch;
    try {
      await mutateOnboarding('progress', { step: stepNumber });
      clearOnboardingHop();
      if (epoch !== onboardingEpoch) return;
      if (location.hash !== step.route) location.hash = step.route;
      const target = await waitForTourTarget(tourSelector(step));
      if (epoch !== onboardingEpoch) return;
      await renderTourGuide(stepNumber, step, target, epoch);
    } catch (error) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not save tour progress: ${error.message}` });
      if (epoch === onboardingEpoch) scheduleOnboardingHop();
    } finally {
      onboardingTourLock = false;
    }
  };

  const openOnboardingChat = async ({ final = false, skipStart = false } = {}) => {
    clearOnboardingHop(); closeOnboardingGuide();
    let state = await loadOnboardingState({ force: true });
    if (!state) throw new Error('welcome state unavailable');
    if (!skipStart && state.state === 'pending') state = await mutateOnboarding('start');
    if (!final && !['pending', 'active'].includes(state.state)) return null;
    closeOnboardingChat({ resumeHop: false });
    const epoch = ++onboardingEpoch;
    const main = document.querySelector('.main');
    if (!main) throw new Error('workspace unavailable');
    const layer = document.createElement('section'); layer.className = 'pw-onboarding-chat-layer'; layer.setAttribute('role', 'region'); layer.setAttribute('aria-label', 'Welcome to Plainwire');
    const header = document.createElement('header'); header.className = 'pw-onboarding-chat-head';
    const mark = document.createElement('span'); mark.className = 'pw-onboarding-mark'; mark.textContent = 'P'; mark.setAttribute('aria-hidden', 'true');
    const title = document.createElement('div'); const h = document.createElement('h2'); h.textContent = 'Plainwire'; const sub = document.createElement('small'); sub.textContent = 'Interactive welcome tour'; title.append(h, sub);
    const close = document.createElement('button'); close.type = 'button'; close.className = 'pw-tour-guide-close'; close.textContent = '×'; close.setAttribute('aria-label', 'Close welcome conversation');
    close.addEventListener('click', () => closeOnboardingChat()); header.append(mark, title, close);
    const messages = document.createElement('div'); messages.className = 'pw-onboarding-messages'; messages.setAttribute('aria-live', 'polite');
    const typing = document.createElement('pw-typing-indicator'); typing.setAttribute('data-scope', ONBOARDING_SCOPE); messages.append(typing);
    const actions = document.createElement('div'); actions.className = 'pw-onboarding-actions';
    const resumeAt = Math.max(0, Number(state.step) || 0);
    const mountChatActions = () => {
      if (epoch !== onboardingEpoch || !actions.isConnected) return;
      actions.replaceChildren();
      if (final) return;
      const startLabel = resumeAt > 0 ? 'Resume tour' : 'Show me around';
      actions.append(
        makeTourAction(startLabel, 'btn', () => showTourStep(Math.max(1, Math.min(resumeAt || 1, onboardingSteps.length)))),
        makeTourAction('Maybe later', 'btn secondary', () => closeOnboardingChat()),
        makeTourAction('Skip tour', 'btn ghost', () => confirmSkipTour(actions, mountChatActions))
      );
    };
    mountChatActions();
    layer.append(header, messages, actions); main.append(layer); onboardingChatNode = layer;
    requestAnimationFrame(() => layer.classList.add('is-open'));
    if (final) return layer;

    const intro = resumeAt > 0
      ? [
          'Welcome back. Your tour progress is still here — no need to start over.',
          `We left off around stop ${Math.min(resumeAt, onboardingSteps.length)} of ${onboardingSteps.length}. I can jump right back there when you’re ready.`
        ]
      : [
          'Hey — I’m Plainwire. Welcome aboard 👋',
          'I can show you around without dumping a wall of tooltips on the screen.',
          'When we leave this chat, I’ll move into a small guide in the corner, highlight the real controls, and walk with you page by page.'
        ];
    await onboardingBotSay(intro, { container: messages, epoch, typingMs: 760 });
    mountChatActions();
    return layer;
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
      // Ctrl/Cmd+E belongs to the chat-wide emoji picker, matching Discord.
      // Keep inline code on the formatting panel so audio/emoji shortcuts never
      // have a second meaning while the composer is focused.
      const kind = { b: 'bold', i: 'italic' }[event.key.toLowerCase()];
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

  const insertIntoComposer = (text, { block = false } = {}) => {
    const composer = activeComposer();
    if (!composer) return false;
    const start = composer.selectionStart ?? composer.value.length;
    const end = composer.selectionEnd ?? start;
    const before = composer.value.slice(0, start);
    const after = composer.value.slice(end);
    const leading = block && before && !before.endsWith('\n') ? '\n' : '';
    const trailing = block && !after.startsWith('\n') ? '\n' : '';
    composer.setRangeText(leading + text + trailing, start, end, 'end');
    composer.dispatchEvent(new Event('input', { bubbles: true }));
    composer.focus({ preventScroll: true });
    return true;
  };

  const appendToComposer = (text) => insertIntoComposer(text, { block: true });

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
    const uploadComposer = activeComposer();
    const uploadFromModal = !!uploadComposer?.closest?.('.modal');
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
        const sameComposer = uploadComposer?.isConnected && activeComposer() === uploadComposer;
        if (sameComposer) {
          appendToComposer(markup);
          send(app.ports.bridgeReceive, { tag: 'toast', data: `${safeName} ready to send` });
        } else if (!uploadFromModal) {
          // Chat routes have durable Elm drafts, so a navigation/rerender can
          // safely deliver the finished upload back to the route that started it.
          send(app.ports.bridgeReceive, { tag: 'attachment_ready', route: uploadRoute, data: markup });
          send(app.ports.bridgeReceive, { tag: 'toast', data: `${safeName} added to the original draft` });
        } else {
          // A modal draft has no durable route key. Never leak an attachment into
          // an unrelated background composer if the thread modal was closed while
          // the upload was in flight.
          send(app.ports.bridgeReceive, { tag: 'toast', data: `${safeName} uploaded, but the thread editor was closed. Reopen it and attach the file again.` });
        }
      } catch (error) {
        const messages = {
          file_too_large: `Files can be up to ${humanBytes(clientConfig.uploadMaxBytes)}.`,
          compression_failed: `Could not compress that file below ${humanBytes(clientConfig.uploadMaxBytes)}.`,
          compression_input_too_large: `That file is too large to compress safely in the browser. The compression limit is ${humanBytes(Math.min(Math.max(clientConfig.uploadMaxBytes * 2, clientConfig.uploadMaxBytes + 32 * 1024 * 1024), 512 * 1024 * 1024))}.`,
          upload_quota_exceeded: 'Upload quota reached. Try again later.',
          upload_storage_unavailable: 'Upload storage is temporarily unavailable.',
          upload_finalize_unavailable: 'The file uploaded, but finalizing it failed. Try again shortly.',
          upload_reservation_lost: 'The upload reservation expired before finalization. Please retry.',
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
  const formatVoiceDuration = (seconds) => {
    const whole = Math.max(0, Math.round(Number(seconds) || 0));
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
  };

  const voiceNoteMimeType = () => {
    const candidates = ['audio/webm;codecs=opus', 'audio/ogg;codecs=opus', 'audio/webm', 'audio/mp4'];
    return candidates.find((type) => globalThis.MediaRecorder?.isTypeSupported?.(type)) || '';
  };

  const voiceNoteDuration = (label) => {
    const match = String(label || '').match(/(?:^|·\s*)(\d+):([0-5]\d)\s*$/);
    return match ? Number(match[1]) * 60 + Number(match[2]) : 0;
  };

  const makeVoiceNotePlayer = ({ src, label = 'Voice note', seconds = 0, preview = false }) => {
    const wrap = document.createElement('span');
    wrap.className = `voice-note-player pw-media-player pw-audio-player${preview ? ' voice-note-preview-player' : ''}`;
    if (seconds > 0) wrap.dataset.duration = String(seconds);
    const audio = document.createElement('audio');
    audio.className = 'pw-audio-element'; audio.preload = 'metadata'; audio.src = src;
    const play = document.createElement('button');
    play.type = 'button'; play.className = 'pw-media-play'; play.dataset.mediaAction = 'play'; play.textContent = 'Play'; play.setAttribute('aria-label', `Play ${label}`);
    const copy = document.createElement('span'); copy.className = 'pw-media-copy';
    const heading = document.createElement('span'); heading.className = 'pw-media-heading';
    const name = document.createElement('strong'); name.className = 'pw-media-name'; name.textContent = label;
    heading.append(name);
    if (!preview) {
      const download = document.createElement('a');
      download.className = 'pw-media-download'; download.href = src; download.download = 'voice-note'; download.textContent = 'Download'; download.title = 'Download voice note';
      heading.append(download);
    }
    const timeline = document.createElement('span'); timeline.className = 'pw-media-timeline';
    const elapsed = document.createElement('span'); elapsed.className = 'pw-media-time'; elapsed.textContent = '0:00';
    const seek = document.createElement('input');
    seek.className = 'pw-media-seek'; seek.type = 'range'; seek.min = '0'; seek.max = '1000'; seek.step = '1'; seek.value = '0'; seek.setAttribute('aria-label', `Seek ${label}`);
    const duration = document.createElement('span'); duration.className = 'pw-media-duration'; duration.textContent = seconds > 0 ? mediaTime(seconds) : '-:--';
    timeline.append(elapsed, seek, duration); copy.append(heading, timeline);
    const speed = document.createElement('button');
    speed.type = 'button'; speed.className = 'voice-note-speed'; speed.dataset.mediaAction = 'speed'; speed.textContent = '1×'; speed.setAttribute('aria-label', 'Change voice-note playback speed');
    const mute = document.createElement('button');
    mute.type = 'button'; mute.className = 'pw-media-mute'; mute.dataset.mediaAction = 'mute'; mute.textContent = 'Sound'; mute.setAttribute('aria-label', 'Mute voice note');
    wrap.append(audio, play, copy, speed, mute);
    return wrap;
  };

  const openVoiceNoteRecorder = async () => {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder !== 'function') {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Voice notes are not supported by this browser.' });
      return;
    }
    const recordingComposer = activeComposer();
    const recordingRoute = location.hash;
    if (!recordingComposer) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Open a DM, thread, or text channel before recording a voice note.' });
      return;
    }
    let stream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: microphoneConstraints('standard'), video: false }); }
    catch (_) { send(app.ports.bridgeReceive, { tag: 'toast', data: 'Microphone access is required to record a voice note.' }); return; }
    const mimeType = voiceNoteMimeType();
    let recorder;
    try { recorder = new MediaRecorder(stream, mimeType ? { mimeType, audioBitsPerSecond: 96000 } : { audioBitsPerSecond: 96000 }); }
    catch (_) { stream.getTracks().forEach((track) => track.stop()); send(app.ports.bridgeReceive, { tag: 'toast', data: 'Could not start the voice recorder.' }); return; }
    const chunks = [];
    const startedAt = performance.now();
    let stopped = false;
    let durationSeconds = 0;
    let recordedBlob = null;
    let previewUrl = '';
    let abandoned = false;
    const shell = document.createElement('div'); shell.className = 'account-password-fields voice-note-recorder';
    const meter = document.createElement('div'); meter.className = 'voice-note-live';
    const dot = document.createElement('span'); dot.className = 'voice-note-live-dot';
    const elapsed = document.createElement('strong'); elapsed.textContent = '0:00';
    const hint = document.createElement('p'); hint.className = 'muted'; hint.textContent = 'Recording locally. Nothing uploads until you choose Use voice note.';
    const preview = document.createElement('div'); preview.className = 'voice-note-preview'; preview.hidden = true;
    meter.append(dot, elapsed); shell.append(meter, hint, preview);
    const dialog = showAccountDialog({ title: 'Record voice note', subtitle: 'Up to 5 minutes. Opus is used when your browser supports it.', content: shell, actions: [] });
    const footer = document.createElement('div'); footer.className = 'account-dialog-actions'; dialog.dialog.append(footer);
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn secondary'; cancel.textContent = 'Cancel';
    const stop = document.createElement('button'); stop.type = 'button'; stop.className = 'btn danger'; stop.textContent = 'Stop recording';
    const use = document.createElement('button'); use.type = 'button'; use.className = 'btn'; use.textContent = 'Use voice note'; use.disabled = true;
    footer.append(cancel, stop, use);
    const finishTracks = () => stream.getTracks().forEach((track) => { try { track.stop(); } catch (_) {} });
    let timer = 0;
    const cleanupRecorder = () => {
      if (abandoned) return;
      abandoned = true;
      clearInterval(timer);
      if (!stopped && recorder.state !== 'inactive') { try { recorder.stop(); } catch (_) {} }
      finishTracks();
      if (previewUrl) { URL.revokeObjectURL(previewUrl); previewUrl = ''; }
    };
    dialog.backdrop.addEventListener('plainwire:dialog-close', cleanupRecorder, { once: true });
    timer = setInterval(() => {
      if (stopped) return;
      durationSeconds = Math.min(300, (performance.now() - startedAt) / 1000);
      elapsed.textContent = formatVoiceDuration(durationSeconds);
      if (durationSeconds >= 300 && recorder.state !== 'inactive') recorder.stop();
    }, 200);
    recorder.addEventListener('dataavailable', (event) => { if (event.data?.size) chunks.push(event.data); });
    recorder.addEventListener('stop', () => {
      stopped = true; clearInterval(timer); finishTracks();
      if (abandoned || !dialog.backdrop.isConnected) return;
      durationSeconds = Math.min(300, Math.max(0.1, (performance.now() - startedAt) / 1000));
      recordedBlob = new Blob(chunks, { type: recorder.mimeType || mimeType || 'audio/webm' });
      elapsed.textContent = formatVoiceDuration(durationSeconds); dot.classList.add('stopped'); stop.disabled = true; stop.textContent = 'Recorded'; use.disabled = !recordedBlob.size;
      if (recordedBlob.size) {
        previewUrl = URL.createObjectURL(recordedBlob);
        const player = makeVoiceNotePlayer({ src: previewUrl, label: 'Preview', seconds: durationSeconds, preview: true });
        preview.replaceChildren(player); preview.hidden = false; mountMediaPlayers(player);
        hint.textContent = 'Review the recording, then attach it. It is still local until you choose Use voice note.';
      }
    }, { once: true });
    recorder.start(250);
    cancel.addEventListener('click', closeAccountDialog);
    stop.addEventListener('click', () => { if (recorder.state !== 'inactive') recorder.stop(); });
    use.addEventListener('click', async () => {
      if (!stopped || !recordedBlob?.size) return;
      use.disabled = true; cancel.disabled = true;
      use.textContent = 'Uploading…';
      try {
        const type = recordedBlob.type || recorder.mimeType || mimeType || 'audio/webm';
        const ext = type.includes('ogg') ? 'ogg' : type.includes('mp4') ? 'm4a' : 'webm';
        const file = new File([recordedBlob], `voice-note-${Date.now()}.${ext}`, { type, lastModified: Date.now() });
        const uploaded = await uploadOne(file);
        const markup = `[Voice note · ${formatVoiceDuration(durationSeconds)}](${uploaded.url}#plainwire-voice-note)`;
        closeAccountDialog();
        const sameComposer = recordingComposer.isConnected && location.hash === recordingRoute && activeComposer() === recordingComposer;
        if (sameComposer) {
          appendToComposer(markup);
        } else {
          send(app.ports.bridgeReceive, { tag: 'attachment_ready', route: recordingRoute, data: markup });
        }
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Voice note attached. Send when ready.' });
      } catch (error) {
        use.disabled = false; cancel.disabled = false; use.textContent = 'Retry upload';
        send(app.ports.bridgeReceive, { tag: 'toast', data: `Voice note upload failed: ${error.message}` });
      }
    });
  };

  const upgradeVoiceNoteLinks = (root = document) => {
    matchingNodes(root, 'a[href*="#plainwire-voice-note"]:not([data-voice-upgraded])').forEach((link) => {
      link.dataset.voiceUpgraded = 'true';
      const href = link.getAttribute('href') || '';
      if (!href.startsWith('/api/files/')) return;
      const text = link.textContent || 'Voice note';
      const seconds = voiceNoteDuration(text);
      const label = text.split('·', 1)[0].trim() || 'Voice note';
      const wrap = makeVoiceNotePlayer({ src: href.replace('#plainwire-voice-note', ''), label, seconds });
      const parent = link.parentNode;
      if (parent) { parent.insertBefore(wrap, link); link.remove(); mountMediaPlayers(wrap); }
    });
  };
  const voiceNoteObserver = new MutationObserver((records) => {
    for (const record of records) for (const node of record.addedNodes) if (node.nodeType === 1) upgradeVoiceNoteLinks(node);
  });
  voiceNoteObserver.observe(document.documentElement, { childList: true, subtree: true });
  upgradeVoiceNoteLinks();

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
      const reconnected = wsEverConnected;
      wsEverConnected = true;
      wsLastMessageAt = Date.now();
      wsReconnectAttempt = 0;
      const queued = wsQueue;
      wsQueue = [];
      debug('WS', 'connected', { queued: queued.length, room });
      send(app.ports.bridgeReceive, { tag: 'ws_status', data: true });
      publishPresence(true);
      if (room && room.joined && localStream) {
        // The server detached the old socket and peers closed their old transport.
        // Rejoin first, then replay only durable queued work. Old ICE/signaling and
        // state patches belong to the dead socket session and must never race ahead
        // of the new room seat.
        room.epoch = ++roomEpoch;
        room.stateSynced = false;
        peers.forEach((_, uid) => closePeer(uid));
        peerPromises.clear();
        signalQueues.clear();
        const join = room.kind === 'voice'
          ? { type: 'voice_join', channel_id: room.id }
          : { type: 'call_join', conversation_id: room.id };
        rtcAction('reconnect', room.kind, room.id, room.epoch);
        sendWs(join);
        const staleRtcTypes = new Set(['voice_signal', 'call_signal', 'voice_state', 'call_state', 'voice_activity', 'call_quality']);
        queued.filter((value) => !staleRtcTypes.has(value?.type)).forEach((value) => sendWs(value));
      } else {
        queued.forEach((value) => sendWs(value));
      }
      if (wsPingTimer) clearInterval(wsPingTimer);
      wsPingTimer = setInterval(() => {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        const idleFor = Date.now() - wsLastMessageAt;
        if (idleFor >= WS_STALE_AFTER_MS) {
          // Browsers and proxies can leave a WebSocket looking OPEN after the
          // underlying path died. Force the normal reconnect/reconcile path
          // instead of waiting for the user to refresh the whole application.
          debug('WS', 'heartbeat_stale_socket', { idle_ms: idleFor }, 'warn');
          try { ws.close(4000, 'heartbeat timeout'); } catch (_) {}
          return;
        }
        sendWs({ type: 'ping' });
      }, WS_HEARTBEAT_MS);
      refreshGlobalBanners();
      if (reconnected) {
        // WsStatus also asks Elm to reconcile the active route. This direct sync
        // closes the small gap before Elm processes that port event and keeps
        // account navigation fresh even after an aggressively suspended tab.
        api({ method: 'GET', path: '/sync?since=0' });
      }
    };
    ws.onmessage = (event) => {
      try {
        wsLastMessageAt = Date.now();
        const msg = JSON.parse(event.data);
        debug('WS', 'received', { message: msg });
        if (msg.session && msg.session.user && msg.session.user.id) meId = msg.session.user.id;
        if (msg.type === 'hello') maybeResumeRtcRoom();
        const systemConsumed = handleSystemEvent(msg) === true;
        handlePresenceEvent(msg);
        const typingConsumed = handleTypingEvent(msg) === true;
        const rtcConsumed = handleRtcEvent(msg) === true;
        if (!systemConsumed && !typingConsumed && !rtcConsumed) send(app.ports.wsReceive, msg);
      } catch (error) { debug('WS', 'invalid_message', { error: error.message, bytes: String(event.data).length }, 'error'); }
    };
    ws.onerror = () => debug('WS', 'transport_error', { ready_state: ws?.readyState }, 'error');
    ws.onclose = (event) => {
      if (ws !== socket) return;
      if (wsPingTimer) { clearInterval(wsPingTimer); wsPingTimer = null; }
      // Typing is socket-epoch state. Never keep indicators or a local claim
      // alive across reconnect; a later keystroke will publish a fresh claim.
      resetTypingState({ skipNetwork: true });
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
    if (value.type === 'ping' || value.type === 'typing') return;
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
    try { clearInterval(mixer.energyTimer); } catch (_) {}
    try { mixer.microphoneSource.disconnect(); } catch (_) {}
    try { mixer.screenSource.disconnect(); } catch (_) {}
    try { mixer.analyser?.disconnect(); } catch (_) {}
    try { mixer.destination.disconnect?.(); } catch (_) {}
    stopStream(mixer.destination.stream);
  };
  const createScreenAudioMixer = async (displayStream, microphoneStream = localStream) => {
    const screenTrack = displayStream?.getAudioTracks().find((track) => track.readyState === 'live');
    if (!screenTrack) return null;
    const microphoneTrack = microphoneStream?.getAudioTracks().find((track) => track.readyState === 'live');
    if (!microphoneTrack) throw new Error('No live microphone track for screen audio');
    const ctx = audioContext();
    if (!ctx) throw new Error('Web Audio is unavailable for screen audio');
    if (ctx.state === 'suspended') {
      try { await ctx.resume(); } catch (_) {}
    }
    if (ctx.state !== 'running') throw new Error(`Web Audio is ${ctx.state}; interact with Plainwire and try screen audio again`);
    const destination = ctx.createMediaStreamDestination();
    let microphoneSource;
    let screenSource;
    try {
      microphoneSource = ctx.createMediaStreamSource(new MediaStream([microphoneTrack]));
      screenSource = ctx.createMediaStreamSource(new MediaStream([screenTrack]));
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      analyser.smoothingTimeConstant = 0.25;
      microphoneSource.connect(destination);
      screenSource.connect(destination);
      // The analyser is diagnostic-only. The screen source remains directly
      // connected to the outgoing mix, so metering can never mute/modify it.
      screenSource.connect(analyser);
      const track = destination.stream.getAudioTracks()[0];
      if (!track) throw new Error('Could not create a mixed screen audio track');
      const mixer = {
        track, destination, microphoneSource, screenSource, screenTrack, analyser,
        energyTimer: null, audioDetected: false, audioEverDetected: false,
        lastEnergyAt: 0, disposed: false
      };
      const samples = new Uint8Array(analyser.fftSize);
      mixer.energyTimer = setInterval(() => {
        if (mixer.disposed || screenTrack.readyState !== 'live') return;
        analyser.getByteTimeDomainData(samples);
        let sum = 0;
        for (let i = 0; i < samples.length; i++) {
          const value = (samples[i] - 128) / 128;
          sum += value * value;
        }
        const now = performance.now();
        const rms = Math.sqrt(sum / samples.length);
        const wasActive = mixer.audioDetected;
        if (rms >= 0.004) {
          mixer.lastEnergyAt = now;
          mixer.audioEverDetected = true;
        }
        // Hysteresis avoids flickering between active/quiet between packets,
        // while still telling the user when a source that once worked is now quiet.
        mixer.audioDetected = mixer.lastEnergyAt > 0 && now - mixer.lastEnergyAt < 1800;
        if (wasActive !== mixer.audioDetected) updateScreenControls();
      }, 350);
      return mixer;
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
  const SYSTEM_AUDIO_DEVICE_RE = /(?:monitor of|output monitor|monitor source|stereo mix|what (?:u|you) hear|loopback|desktop audio|system audio)/i;
  let selectedScreenAudioId = storage.getItem('plainwire_screen_audio_device') || '';
  let screenAudioDeviceLabel = '';
  const enumerateScreenAudioInputs = async () => {
    if (!navigator.mediaDevices?.enumerateDevices) return [];
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.filter((item) => item.kind === 'audioinput' && item.deviceId && item.deviceId !== selectedInputId);
  };
  const captureSystemAudioFallback = async () => {
    if (!shareScreenAudio || !navigator.mediaDevices?.enumerateDevices || !navigator.mediaDevices?.getUserMedia) return null;
    const devices = await enumerateScreenAudioInputs();
    let device = selectedScreenAudioId ? devices.find((item) => item.deviceId === selectedScreenAudioId) : null;
    if (!device) {
      if (selectedScreenAudioId) {
        selectedScreenAudioId = '';
        storage.removeItem('plainwire_screen_audio_device');
      }
      device = devices.find((item) => SYSTEM_AUDIO_DEVICE_RE.test(item.label || ''));
    }
    if (!device) return null;
    const stream = await navigator.mediaDevices.getUserMedia({
      video: false,
      audio: {
        deviceId: { exact: device.deviceId },
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: { ideal: 2 },
        sampleRate: { ideal: 48000 }
      }
    });
    const track = stream.getAudioTracks().find((item) => item.readyState === 'live');
    if (!track) { stopStream(stream); return null; }
    try { track.contentHint = 'music'; } catch (_) {}
    const label = device.label || 'system audio monitor';
    return { stream, track, label, deviceId: device.deviceId };
  };
  const replaceActiveScreenAudioWithCapture = async (capture, source = 'loopback') => {
    if (!capture?.track || capture.track.readyState !== 'live' || !screenStream || !room) {
      stopStream(capture?.stream);
      return false;
    }
    const activeScreen = screenStream;
    const epoch = room.epoch;
    const previousMixer = screenAudioMixer;
    const previousSource = screenAudioSource;
    const previousLabel = screenAudioDeviceLabel;
    const previousAudioTrack = outgoingAudioTrack(localStream, previousMixer);
    let nextMixer;
    try {
      nextMixer = await createScreenAudioMixer(new MediaStream([capture.track]));
      if (!nextMixer) throw new Error('The selected system audio source did not provide a live track');
    } catch (error) {
      stopStream(capture.stream);
      debug('MEDIA', 'screen_audio_source_mix_failed', { error: error.message }, 'warn');
      throw error;
    }
    if (!room || room.epoch !== epoch || screenStream !== activeScreen) {
      disposeScreenAudioMixer(nextMixer);
      stopStream(capture.stream);
      return false;
    }
    const nextAudioTrack = outgoingAudioTrack(localStream, nextMixer);
    const targets = Array.from(peers.values()).filter((pc) => pc._audioSender && pc.signalingState !== 'closed');
    const results = await Promise.allSettled(targets.map((pc) => pc._audioSender.replaceTrack(nextAudioTrack)));
    if (!room || room.epoch !== epoch || screenStream !== activeScreen) {
      disposeScreenAudioMixer(nextMixer);
      stopStream(capture.stream);
      return false;
    }
    if (results.some((result, index) => result.status === 'rejected' && targets[index].signalingState !== 'closed')) {
      await Promise.allSettled(Array.from(peers.values())
        .filter((pc) => pc._audioSender && pc.signalingState !== 'closed')
        .map((pc) => pc._audioSender.replaceTrack(previousAudioTrack)));
      disposeScreenAudioMixer(nextMixer);
      stopStream(capture.stream);
      screenAudioMixer = previousMixer;
      screenAudioSource = previousSource;
      screenAudioDeviceLabel = previousLabel;
      throw new Error('Could not switch the outgoing shared-audio track for every participant');
    }

    const oldSourceTracks = activeScreen.getAudioTracks().filter((track) => track !== capture.track);
    for (const track of oldSourceTracks) {
      try { activeScreen.removeTrack(track); } catch (_) {}
      try { track.stop(); } catch (_) {}
    }
    if (!activeScreen.getAudioTracks().includes(capture.track)) {
      try { activeScreen.addTrack(capture.track); } catch (_) {}
    }
    screenAudioMixer = nextMixer;
    screenAudioSource = source;
    screenAudioDeviceLabel = capture.label || 'system audio source';
    disposeScreenAudioMixer(previousMixer);
    sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen_audio: true } });
    updateScreenControls();
    debug('MEDIA', 'screen_audio_source_changed', { source, label: screenAudioDeviceLabel });
    return true;
  };

  const applySelectedScreenAudioSource = async () => {
    if (!screenStream || !room || !shareScreenAudio) return false;
    const capture = await captureSystemAudioFallback();
    if (!capture) return false;
    return replaceActiveScreenAudioWithCapture(capture, 'loopback');
  };

  const disableActiveScreenAudio = async () => {
    if (!screenStream || !room || screenAudioSource === 'none') return true;
    const activeScreen = screenStream;
    const epoch = room.epoch;
    const previousMixer = screenAudioMixer;
    const microphoneTrack = outgoingAudioTrack(localStream, null);
    const targets = Array.from(peers.values()).filter((pc) => pc._audioSender && pc.signalingState !== 'closed');
    const previousAudioTrack = outgoingAudioTrack(localStream, previousMixer);
    const results = await Promise.allSettled(targets.map((pc) => pc._audioSender.replaceTrack(microphoneTrack)));
    if (!room || room.epoch !== epoch || screenStream !== activeScreen) return false;
    if (results.some((result, index) => result.status === 'rejected' && targets[index].signalingState !== 'closed')) {
      await Promise.allSettled(Array.from(peers.values())
        .filter((pc) => pc._audioSender && pc.signalingState !== 'closed')
        .map((pc) => pc._audioSender.replaceTrack(previousAudioTrack)));
      return false;
    }
    for (const track of activeScreen.getAudioTracks()) {
      try { activeScreen.removeTrack(track); } catch (_) {}
      try { track.stop(); } catch (_) {}
    }
    screenAudioMixer = null;
    screenAudioSource = 'none';
    screenAudioDeviceLabel = '';
    disposeScreenAudioMixer(previousMixer);
    sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen_audio: false } });
    updateScreenControls();
    debug('MEDIA', 'screen_audio_disabled_live');
    return true;
  };

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
      replacementMixer = await createScreenAudioMixer(screenStream, replacementLease.stream);
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
  const populateScreenAudioSourceSelect = async (select) => {
    if (!select?.isConnected) return;
    const previous = selectedScreenAudioId;
    const inputs = await enumerateScreenAudioInputs().catch(() => []);
    select.replaceChildren();
    const automatic = document.createElement('option');
    automatic.value = '';
    automatic.textContent = 'Automatic · browser audio, then system monitor';
    select.append(automatic);
    const detected = inputs.filter((item) => SYSTEM_AUDIO_DEVICE_RE.test(item.label || ''));
    const other = inputs.filter((item) => !SYSTEM_AUDIO_DEVICE_RE.test(item.label || ''));
    const addGroup = (label, items) => {
      if (!items.length) return;
      const group = document.createElement('optgroup'); group.label = label;
      items.forEach((item, index) => {
        const option = document.createElement('option'); option.value = item.deviceId;
        option.textContent = item.label || `Audio input ${index + 1}`;
        group.append(option);
      });
      select.append(group);
    };
    addGroup('System / loopback sources', detected);
    addGroup('Other audio inputs', other);
    if (previous && inputs.some((item) => item.deviceId === previous)) select.value = previous;
    else select.value = '';
  };
  class ScreenSettings extends HTMLElement {
    connectedCallback() { this.render(); }
    render() {
      if (this.childElementCount) {
        const active = !!screenStream;
        const change = this.querySelector('[data-screen-change]');
        const preview = this.querySelector('[data-screen-preview]');
        const status = this.querySelector('[data-screen-audio-status]');
        const sourceSelect = this.querySelector('[data-screen-audio-source]');
        if (sourceSelect && sourceSelect.value !== selectedScreenAudioId) sourceSelect.value = selectedScreenAudioId;
        if (change) change.disabled = !active;
        if (preview) preview.disabled = !active;
        if (status) {
          const hasAudioSource = active && screenAudioSource !== 'none' && screenAudioMixer?.track?.readyState === 'live';
          const audioVerified = hasAudioSource && screenAudioMixer?.audioDetected === true;
          const audioWasVerified = hasAudioSource && screenAudioMixer?.audioEverDetected === true;
          status.textContent = active
            ? hasAudioSource
              ? audioVerified
                ? screenAudioSource === 'loopback'
                  ? `System audio is flowing through ${screenAudioDeviceLabel || 'your system monitor/loopback input'}. Headphones are recommended because loopback can include call playback.`
                  : 'Shared audio is flowing and mixed with your microphone.'
                : audioWasVerified
                  ? screenAudioSource === 'loopback'
                    ? `System audio through ${screenAudioDeviceLabel || 'your monitor/loopback input'} was verified and is currently quiet.`
                    : 'Shared audio was verified and is currently quiet.'
                  : screenAudioSource === 'loopback'
                    ? `System audio source ${screenAudioDeviceLabel || 'monitor/loopback input'} is attached, but Plainwire has not detected output audio yet. Play something on the shared system to verify it.`
                    : 'The browser supplied a shared-audio track, but Plainwire has not detected audio energy yet. Play audio in the shared tab/window to verify it.'
              : shareScreenAudio
                ? 'Video is sharing, but this browser/OS did not expose a shared-audio source. Enable Share audio in the browser picker or choose a PipeWire/Pulse monitor/loopback source.'
                : 'Shared audio is off. Your microphone is still sent normally.'
            : 'When available, tab or system audio is mixed with your microphone. Plainwire verifies actual audio energy instead of assuming that a silent track works.';
          status.classList.toggle('active', audioVerified);
          status.classList.toggle('attached', hasAudioSource && !audioVerified);
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
      audioToggle.addEventListener('change', async () => {
        shareScreenAudio = audioToggle.checked;
        storage.setItem('plainwire_screen_audio', String(shareScreenAudio));
        for (const control of document.querySelectorAll('pw-screen-settings .screen-audio-option input')) control.checked = shareScreenAudio;
        if (!screenStream) return;
        try {
          if (!shareScreenAudio) {
            if (!(await disableActiveScreenAudio())) throw new Error('Could not update every participant');
          } else if (screenAudioSource === 'none' || selectedScreenAudioId) {
            const changed = await applySelectedScreenAudioSource();
            if (!changed) send(app.ports.bridgeReceive, { tag: 'toast', data: 'Shared audio is enabled, but no usable system/loopback source is available. You can change the shared screen to request browser audio again.' });
          }
        } catch (error) {
          shareScreenAudio = !audioToggle.checked;
          storage.setItem('plainwire_screen_audio', String(shareScreenAudio));
          for (const control of document.querySelectorAll('pw-screen-settings .screen-audio-option input')) control.checked = shareScreenAudio;
          send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not change shared audio: ${error.message}` });
        }
        updateScreenControls();
      });
      audioLabel.append(audioToggle, audioCopy);
      const sourceLabel = document.createElement('label'); sourceLabel.className = 'screen-audio-source';
      const sourceHeading = document.createElement('span'); sourceHeading.textContent = 'System audio fallback source';
      const sourceSelect = document.createElement('select'); sourceSelect.dataset.screenAudioSource = 'true';
      sourceSelect.setAttribute('aria-label', 'System audio fallback source');
      sourceSelect.addEventListener('change', async () => {
        const previousId = selectedScreenAudioId;
        selectedScreenAudioId = sourceSelect.value;
        if (selectedScreenAudioId) storage.setItem('plainwire_screen_audio_device', selectedScreenAudioId);
        else storage.removeItem('plainwire_screen_audio_device');
        document.querySelectorAll('pw-screen-settings [data-screen-audio-source]').forEach((control) => { if (control !== sourceSelect) control.value = selectedScreenAudioId; });
        if (!screenStream || !shareScreenAudio) {
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'System audio source saved.' });
          return;
        }
        try {
          if (!selectedScreenAudioId && screenAudioSource === 'display') {
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Automatic browser audio is already active.' });
            return;
          }
          const changed = await applySelectedScreenAudioSource();
          if (!changed) throw new Error('The selected source is unavailable or did not expose an audio track');
          send(app.ports.bridgeReceive, { tag: 'toast', data: `Shared audio switched to ${screenAudioDeviceLabel}.` });
        } catch (error) {
          selectedScreenAudioId = previousId;
          if (selectedScreenAudioId) storage.setItem('plainwire_screen_audio_device', selectedScreenAudioId);
          else storage.removeItem('plainwire_screen_audio_device');
          document.querySelectorAll('pw-screen-settings [data-screen-audio-source]').forEach((control) => { control.value = selectedScreenAudioId; });
          send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not switch system audio: ${error.message}` });
        }
        updateScreenControls();
      });
      sourceLabel.append(sourceHeading, sourceSelect);
      populateScreenAudioSourceSelect(sourceSelect).catch(() => {});
      const note = document.createElement('p');
      note.textContent = 'Text & detail keeps writing sharp. Smooth motion prefers frame rate. On Linux, choose a PipeWire/Pulse monitor source here if your browser does not expose system audio directly.';
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
      details.append(summary, label, audioLabel, sourceLabel, audioStatus, note, hdr, actions); this.append(details);
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
    const previousAudioDeviceLabel = screenAudioDeviceLabel;
    let captured;
    try {
      captured = await navigator.mediaDevices.getDisplayMedia({
        video: screenConstraints(),
        audio: shareScreenAudio,
        systemAudio: shareScreenAudio ? 'include' : 'exclude',
        // A window and the whole system are separate audio choices in the
        // Screen Capture API. Asking for system audio here left application
        // windows silent even when the picker offered an audio checkbox.
        windowAudio: shareScreenAudio ? 'window' : 'exclude',
        audioSelection: shareScreenAudio ? 'preferred' : undefined,
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
    let capturedAudioSource = captured.getAudioTracks().some((track) => track.readyState === 'live') ? 'display' : 'none';
    let capturedAudioDeviceLabel = capturedAudioSource === 'display' ? (captured.getAudioTracks()[0]?.label || 'browser capture') : '';
    let loopbackCapture = null;
    // An explicit monitor/loopback selection is authoritative. Some browsers
    // return a live display-audio track that is silent or only captures a tab;
    // ignoring the user's chosen PipeWire/Pulse source in that case makes the
    // setting look broken. Automatic mode still prefers browser capture first.
    if (shareScreenAudio && (selectedScreenAudioId || capturedAudioSource === 'none')) {
      try {
        loopbackCapture = await captureSystemAudioFallback();
        if (loopbackCapture) {
          for (const track of captured.getAudioTracks()) {
            captured.removeTrack(track);
            track.stop();
          }
          captured.addTrack(loopbackCapture.track);
          capturedAudioSource = 'loopback';
          capturedAudioDeviceLabel = loopbackCapture.label;
          debug('MEDIA', 'screen_audio_loopback_selected', { label: loopbackCapture.label, explicit: !!selectedScreenAudioId });
        }
      } catch (error) {
        stopStream(loopbackCapture?.stream);
        debug('MEDIA', 'screen_audio_loopback_failed', { name: error.name, error: error.message }, 'warn');
      }
    }
    // The user may leave while a loopback permission prompt is open too.
    if (!room || room.epoch !== epoch || screenStream !== previous) { stopStream(captured); stopStream(loopbackCapture?.stream); return; }
    const previousMixer = screenAudioMixer;
    const previousAudioSource = screenAudioSource;
    let capturedMixer = null;
    try {
      capturedMixer = await createScreenAudioMixer(captured);
    } catch (error) {
      captured.getAudioTracks().forEach((track) => track.stop());
      capturedAudioSource = 'none';
      debug('MEDIA', 'screen_audio_mix_failed', { error: error.message }, 'warn');
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'The screen is sharing, but its audio could not be mixed.' });
    }
    if (!capturedMixer) capturedAudioSource = 'none';
    const previousAudioTrack = outgoingAudioTrack(localStream, previousMixer);
    const capturedAudioTrack = outgoingAudioTrack(localStream, capturedMixer);
    screenStream = captured;
    screenAudioMixer = capturedMixer;
    screenAudioSource = capturedAudioSource;
    screenAudioDeviceLabel = capturedAudioSource === 'none' ? '' : capturedAudioDeviceLabel;
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
      screenAudioSource = previousAudioSource;
      screenAudioDeviceLabel = previousAudioDeviceLabel;
      // Re-snapshot peers for rollback. A participant can join while the screen
      // chooser/replacement promises are pending; limiting rollback to the old
      // target list would leave that new peer watching the rejected capture.
      const rollbackPeers = Array.from(peers.entries()).filter(([, pc]) => pc.signalingState !== 'closed');
      await Promise.allSettled(rollbackPeers.map(([, pc]) => Promise.all([
        pc._videoSender ? pc._videoSender.replaceTrack(previous?.getVideoTracks()[0] || null) : Promise.resolve(),
        pc._audioSender ? pc._audioSender.replaceTrack(previousAudioTrack) : Promise.resolve()
      ])));
      disposeScreenAudioMixer(capturedMixer);
      stopStream(captured);
      screenSenders.clear();
      if (previous) rollbackPeers.forEach(([uid, pc]) => { if (pc._videoSender) screenSenders.set(uid, pc._videoSender); });
      send(app.ports.bridgeReceive, { tag: 'toast', data: previous ? 'Could not switch screens. Your previous share is unchanged.' : 'Could not start sharing. Please try again.' });
      return;
    }
    disposeScreenAudioMixer(previousMixer);
    if (previous) stopStream(previous);
    const hasScreenAudio = !!capturedMixer && capturedAudioSource !== 'none';
    sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen: true, screen_audio: hasScreenAudio } });
    send(app.ports.bridgeReceive, { tag: 'screen_share_started', user_id: meId });
    showLocalScreenPreview(captured);
    updateScreenControls();
    if (shareScreenAudio && !hasScreenAudio) {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Screen video is live, but this browser did not provide system audio. Choose a source with Share audio enabled or expose a monitor/loopback input.' });
    } else if (capturedAudioSource === 'loopback') {
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Plainwire is using your system monitor/loopback input for shared audio. Headphones are recommended because loopback can include call playback.' });
    }
    const sharedInputTrack = capturedMixer?.screenTrack;
    sharedInputTrack?.addEventListener?.('ended', () => {
      if (screenStream !== captured || screenAudioMixer !== capturedMixer || screenAudioSource === 'none') return;
      screenAudioSource = 'none';
      screenAudioDeviceLabel = '';
      screenAudioMixer = null;
      const microphoneTrack = outgoingAudioTrack(localStream, null);
      Promise.allSettled(Array.from(peers.values(), pc =>
        pc._audioSender ? pc._audioSender.replaceTrack(microphoneTrack) : Promise.resolve()
      )).finally(() => disposeScreenAudioMixer(capturedMixer));
      updateScreenControls();
      if (room && ws?.readyState === WebSocket.OPEN) {
        sendWs({ type: room.kind === 'voice' ? 'voice_state' : 'call_state', patch: { screen_audio: false } });
      }
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Shared system audio stopped; screen video and microphone are still live.' });
    });
    debug('MEDIA', 'screen_share_started', { tracks: captured.getTracks().length, shared_audio: hasScreenAudio, audio_source: capturedAudioSource });
    if (!screenWatchTimer) startScreenWatchMonitor();
  };

  const stopScreenWatchMonitor = () => {
    screenShareSession += 1;
    if (screenWatchTimer) clearInterval(screenWatchTimer);
    screenWatchTimer = null;
    screenWatchAnnounced.clear();
  };

  const readOutboundVideo = async (sender) => {
    const stats = await sender.getStats();
    let sample = null;
    stats.forEach((report) => {
      if (report.type !== 'outbound-rtp' || report.isRemote) return;
      if (report.kind !== 'video' && report.mediaType !== 'video') return;
      sample = { bytes: Number(report.bytesSent || 0), frames: Number(report.framesSent || 0) };
    });
    return sample;
  };

  // One cue per remote viewer per share. A stats poll only notices the edge
  // where outbound screen video starts flowing; renegotiation rebases the
  // counter instead of dinging again.
  const noteScreenViewer = async (uid, pc, session) => {
    if (!screenStream || session !== screenShareSession || screenWatchAnnounced.has(uid)) return;
    const track = screenStream.getVideoTracks()[0];
    const sender = pc?._videoSender;
    if (!track || track.readyState !== 'live' || !sender || sender.track !== track) return;
    const transportUp = pc.connectionState === 'connected' || pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed';
    if (!transportUp) return;
    let sample = null;
    try { sample = await readOutboundVideo(sender); }
    catch (_) { return; }
    if (!sample || session !== screenShareSession || !screenStream || screenWatchAnnounced.has(uid) || sender.track !== track) return;
    const slot = `_screenWatchBase${session}`;
    const baseline = pc[slot];
    if (!baseline) {
      pc[slot] = sample;
      return;
    }
    if (sample.frames < baseline.frames || sample.bytes + 200 < baseline.bytes) {
      pc[slot] = sample;
      return;
    }
    const advanced = sample.frames > baseline.frames || sample.bytes > baseline.bytes + 2500;
    if (!advanced) return;
    screenWatchAnnounced.add(uid);
    playSound('screenWatch');
  };

  const startScreenWatchMonitor = () => {
    stopScreenWatchMonitor();
    const session = screenShareSession;
    const poll = () => {
      if (!screenStream || session !== screenShareSession || !room?.joined) return;
      peers.forEach((pc, uid) => {
        if (!uid || Number(uid) === Number(meId) || pc.signalingState === 'closed') return;
        noteScreenViewer(Number(uid), pc, session).catch(() => {});
      });
    };
    screenWatchTimer = setInterval(poll, 1000);
    poll();
  };

  const stopScreenShare = () => {
    if (!screenStream) return;
    stopScreenWatchMonitor();
    const stoppedStream = screenStream;
    const stoppedMixer = screenAudioMixer;
    screenStream = null;
    screenAudioMixer = null;
    screenAudioSource = 'none';
    screenAudioDeviceLabel = '';
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

  const remoteAudioHost = () => {
    let host = document.getElementById('pw-remote-audio-host');
    if (!host) {
      host = document.createElement('div');
      host.id = 'pw-remote-audio-host';
      host.setAttribute('aria-hidden', 'true');
      host.style.cssText = 'position:fixed;left:0;bottom:0;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none;';
      document.body.appendChild(host);
    }
    return host;
  };
  const remoteAudio = (uid) => {
    let el = document.getElementById('remote-audio-' + uid);
    if (!el) {
      el = document.createElement('audio');
      el.id = 'remote-audio-' + uid;
      el.autoplay = true;
      el.playsInline = true;
      el.setAttribute('playsinline', '');
      el.setAttribute('webkit-playsinline', '');
      el.setAttribute('autoplay', '');
      el.controls = false;
      el.preload = 'auto';
      el.volume = readVolume(peerVolumeKey(uid), 100) / 100;
      remoteAudioHost().appendChild(el);
    }
    return el;
  };

  const playAllRemoteAudio = () => {
    audioContext()?.resume?.().catch(() => {});
    document.querySelectorAll('audio[id^="remote-audio-"]').forEach((audio) => {
      audio.muted = deafened;
      const play = audio.play();
      if (play && typeof play.then === 'function') {
        play.then(() => { audioUnlockToastShown = false; }).catch(() => false);
      }
    });
  };

  const playRemoteAudio = (audio) => {
    if (!audio) return;
    audio.muted = deafened;
    audioContext()?.resume?.().catch(() => {});
    const tryPlay = () => audio.play().then(() => { audioUnlockToastShown = false; }).catch(() => false);
    tryPlay().then((ok) => {
      if (ok === false) {
        audioContext()?.resume?.().catch(() => {});
        tryPlay().then((retryOk) => {
          if (retryOk === false && !audioUnlockToastShown && room?.joined && !deafened) {
            audioUnlockToastShown = true;
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Tap Enable audio to hear the call.' });
          }
        });
      }
    });
    if (!remoteAudioUnlockInstalled) {
      remoteAudioUnlockInstalled = true;
      let lastUnlock = 0;
      const unlock = () => {
        const now = Date.now();
        if (now - lastUnlock < 400) return;
        lastUnlock = now;
        audioContext()?.resume?.().catch(() => {});
        playAllRemoteAudio();
        applySpeaker().catch(() => {});
      };
      ['click', 'touchend', 'keydown', 'pointerdown'].forEach((ev) => {
        document.addEventListener(ev, unlock, { passive: true });
      });
      document.addEventListener('visibilitychange', () => {
        lastUnlock = 0;
        if (!document.hidden && room?.joined) unlock();
      }, { passive: true });
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
    if (!pc || pc._failureReported) return;
    if (schedulePeerRebuild(uid, pc, reason)) return;
    if (pc.signalingState === 'closed') return;
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
      if (pc._statsTimer) clearInterval(pc._statsTimer);
      pc._statsTimer = null;
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
    earlyCandidates.delete(`${room?.epoch || 0}:${Number(uid)}`);
    closePeer(uid);
  };

  const peerStillExpected = (uid, epoch) => {
    if (!room || room.epoch !== epoch || !room.joined) return false;
    // Once a roster exists it is authoritative. Before the first roster, a
    // signal may legitimately arrive first, so do not reject solely for that.
    return !(room.roster instanceof Set) || room.roster.has(Number(uid));
  };

  const consumePeerRepairBudget = (uid, epoch) => {
    const key = `${epoch}:${Number(uid)}`;
    const cutoff = Date.now() - RTC_PEER_REBUILD_WINDOW_MS;
    const recent = (peerRepairHistory.get(key) || []).filter((at) => at >= cutoff);
    if (recent.length >= RTC_MAX_PEER_REBUILDS) {
      peerRepairHistory.set(key, recent);
      return false;
    }
    recent.push(Date.now());
    peerRepairHistory.set(key, recent);
    return true;
  };

  function schedulePeerRebuild(uid0, pc, reason = 'media_session_stalled') {
    const uid = Number(uid0 || 0);
    const epoch = Number(pc?._roomEpoch || room?.epoch || 0);
    if (!uid || !epoch || !peerStillExpected(uid, epoch)) return false;
    const key = `${epoch}:${uid}`;
    if (peerRepairPromises.has(key)) return true;
    if (!consumePeerRepairBudget(uid, epoch)) {
      debug('RTC', 'peer_rebuild_budget_exhausted', { peer_user_id: uid, reason, epoch }, 'warn');
      return false;
    }

    if (pc) {
      pc._repairScheduled = true;
      pc._failureReported = false;
    }
    reportPeerFailure(uid, pc, false);
    reportPeerConnection(uid, pc, false);
    debug('RTC', 'peer_rebuild_scheduled', { peer_user_id: uid, reason, epoch });

    const repair = (async () => {
      // Give a just-fired track/ICE event a moment to settle. This also lets
      // both peers observe the same room roster before signalling again.
      await new Promise((resolve) => setTimeout(resolve, 320));
      if (!peerStillExpected(uid, epoch)) return;

      const current = peers.get(uid);
      if (current && current !== pc && current._roomEpoch === epoch && current._mediaConnected === true) return;
      replacePeerSession(uid);
      await new Promise((resolve) => setTimeout(resolve, 80));
      if (!peerStillExpected(uid, epoch)) return;

      const next = await ensurePeer(uid);
      if (!next || !peerStillExpected(uid, epoch)) return;
      next._autoRebuilt = true;
      next._rebuildReason = reason;
      next._reconnectAttempts = 0;
      next._lastRecoveryAt = 0;
      next._failureReported = false;
      reportPeerFailure(uid, next, false);
      if (next._offerer) await makeOffer(uid, next, { iceRestart: true });
      else sendSignal(uid, { kind: 'renegotiate' });
      debug('RTC', 'peer_rebuild_started', { peer_user_id: uid, reason, epoch });
    })().catch((error) => {
      debug('RTC', 'peer_rebuild_failed', { peer_user_id: uid, reason, error: error.message }, 'warn');
      const current = peers.get(uid) || pc;
      if (peerStillExpected(uid, epoch)) {
        reportPeerConnection(uid, current, false);
        reportPeerFailure(uid, current, true, 'auto_repair_failed');
      }
    }).finally(() => {
      if (peerRepairPromises.get(key) === repair) peerRepairPromises.delete(key);
    });
    peerRepairPromises.set(key, repair);
    return true;
  }

  const auditRtcPeers = (reason = 'periodic') => {
    if (!room?.joined) return;
    const now = Date.now();
    for (const [uid, pc] of peers) {
      if (!pc || pc._roomEpoch !== room.epoch) continue;
      if (pc.signalingState === 'closed' || pc.connectionState === 'closed') {
        schedulePeerRebuild(uid, pc, `${reason}_closed_peer`);
        continue;
      }

      const transportConnected = pc.connectionState === 'connected'
        || pc.iceConnectionState === 'connected'
        || pc.iceConnectionState === 'completed';
      const audioTrack = pc.getReceivers?.()
        .map((receiver) => receiver.track)
        .find((track) => track?.kind === 'audio' && track.readyState === 'live')
        || (pc._remoteAudioTrack?.readyState === 'live' ? pc._remoteAudioTrack : null);

      if (transportConnected && !audioTrack && now - (pc._createdAt || now) > 8000) {
        pc._mediaConnected = false;
        pc._publishConnectionState?.(true);
        schedulePeerRebuild(uid, pc, `${reason}_missing_receiver`);
        continue;
      }

      if (!transportConnected || !audioTrack) {
        pc._stalledAudioSince = 0;
        continue;
      }

      // Repair browser playback state without touching the transport. Mobile
      // browsers in particular can suspend an <audio> element while the WebRTC
      // receiver itself remains healthy.
      const audio = remoteAudio(uid);
      const currentTrack = audio.srcObject?.getAudioTracks?.()[0];
      if (currentTrack !== audioTrack) audio.srcObject = new MediaStream([audioTrack]);
      audio.muted = deafened;
      if (!deafened && (audio.paused || audio.readyState < HTMLMediaElement.HAVE_CURRENT_DATA)) playRemoteAudio(audio);

      const rtpStaleFor = pc._lastRtpProgressAt > 0
        ? now - pc._lastRtpProgressAt
        : (pc._lastInboundPackets !== null ? now - (pc._createdAt || now) : 0);
      const looksStalled = audioTrack.muted === true && rtpStaleFor >= 15000;
      if (!looksStalled) {
        pc._stalledAudioSince = 0;
        continue;
      }
      if (!pc._stalledAudioSince) pc._stalledAudioSince = now;
      if (now - pc._stalledAudioSince >= 15000) {
        debug('RTC', 'sustained_audio_stall', { peer_user_id: uid, reason, rtp_stale_ms: rtpStaleFor }, 'warn');
        pc._mediaConnected = false;
        pc._publishConnectionState?.(true);
        if (schedulePeerRebuild(uid, pc, `${reason}_stalled_receiver`)) pc._stalledAudioSince = 0;
      }
    }
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

  const rtcJoinErrorCopy = (error, action, kind) => {
    const voice = kind === 'voice';
    switch (error) {
      case 'no_active_call': return action === 'accept' ? 'That incoming call has already ended.' : 'That call has ended.';
      case 'room_full': return voice ? 'That voice channel is full.' : 'That call is full.';
      case 'forbidden': return voice ? 'You no longer have access to that voice channel.' : 'You no longer have access to that call.';
      case 'unavailable': return voice ? 'Voice service is temporarily unavailable. Try again.' : 'Call service is temporarily unavailable. Try again.';
      case 'no_peers': return 'There is nobody else in this conversation to call.';
      default: return voice ? 'Could not join voice. Please try again.' : 'Could not join the call. Please try again.';
    }
  };
  const failPendingRtcAction = (msg) => {
    if (msg.type !== 'error' || !pendingRtcAction || !room || pendingRtcAction.epoch !== room.epoch) return false;
    if (!['no_active_call', 'room_full', 'forbidden', 'unavailable', 'no_peers'].includes(msg.error)) return false;
    const errorKind = typeof msg.rtc_kind === 'string' ? msg.rtc_kind : '';
    const errorId = Number(msg.rtc_id || 0);
    if (errorKind !== pendingRtcAction.kind || errorId !== pendingRtcAction.id) {
      debug('RTC', 'unrelated_error_while_joining', {
        pending_kind: pendingRtcAction.kind, pending_id: pendingRtcAction.id,
        error_kind: errorKind || '(unscoped)', error_id: errorId || 0, error: msg.error
      }, 'warn');
      return false;
    }
    const failed = { ...pendingRtcAction };
    const copy = rtcJoinErrorCopy(msg.error, failed.action, failed.kind);
    debug('RTC', 'room_join_rejected', { action: failed.action, kind: failed.kind, id: failed.id, error: msg.error }, 'warn');
    leaveRtcRoom();
    stopRingtones();
    send(app.ports.bridgeReceive, { tag: 'rtc_join_failed', data: failed.kind });
    send(app.ports.bridgeReceive, { tag: 'toast', data: copy });
    return true;
  };

  const playPeerJoin = (uid) => {
    const id = Number(uid);
    if (!id || id === Number(meId) || rtcLocalDeparture || joinCueIds.has(id)) return;
    joinCueIds.add(id);
    playSound('peerJoin');
  };

  const leaveRtcRoom = ({ notifyServer = false, preserveResume = false } = {}) => {
    const previous = room ? { ...room } : null;
    joinCueIds.clear();
    callAwaitingFirstGuest = false;
    if (previous?.joined) rtcLocalDeparture = true;
    debug('RTC', 'room_leaving', { room: previous, peers: peers.size, notify_server: notifyServer, preserve_resume: preserveResume });
    if (preserveResume) persistRtcIntent();
    else clearRtcIntent();
    stopRtcPersistence();
    pendingRtcAction = null;
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
    peerRepairPromises.clear();
    peerRepairHistory.clear();
    earlyCandidates.clear();
    identityRetries.clear();
    if (screenStream) {
      screenStream.getTracks().forEach((t) => t.stop());
      screenStream = null;
    }
    disposeScreenAudioMixer(screenAudioMixer);
    screenAudioMixer = null;
    screenAudioSource = 'none';
    screenSenders.clear();
    cleanupAllFloatWindows();
    screenSharers.clear();
    stopScreenWatchMonitor();
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
    // After this function returns, some callers stop ringtones again. Defer the
    // cue so that epoch bump cannot swallow it, and so a peer-left echo of this
    // same departure is not what plays the "you left" sound.
    if (previous?.joined && !preserveResume) queueMicrotask(() => playSound('selfLeave'));
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
    const owner = readRtcOwner();
    if (owner && owner.tab !== rtcTabId && owner.kind === intent.kind && owner.id === intent.id) {
      debug('RTC', 'room_resume_suppressed_other_tab', { intent, owner });
      send(app.ports.bridgeReceive, {
        tag: 'toast',
        data: intent.kind === 'voice'
          ? 'This voice session is active in another Plainwire tab. Join here if you want to move it to this tab.'
          : 'This call is active in another Plainwire tab. Use Take over if you want to move it here.'
      });
      return;
    }
    resumeInFlight = true;
    micMuted = intent.muted;
    deafened = intent.deafened;
    mutedBeforeDeafen = intent.mutedBeforeDeafen;
    const epoch = ++roomEpoch;
    room = { kind: intent.kind, id: intent.id, joined: false, epoch };
    rtcAction('resume', intent.kind, intent.id, epoch);
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
      // Candidates gathered during setLocalDescription stay behind the offer.
      pc._releaseLocalCandidates?.();
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
        if (pc.signalingState === 'have-local-offer' && pc.localDescription && !pc.remoteDescription) {
          // The other side asked again, or the first answer never arrived.
          // Send the pending offer now. Resending the same description lets
          // them repeat the answer they already created.
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
    if (!uid || Number(uid) === Number(meId)) return null;
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

  const transceiverKind = (transceiver) => transceiver?.receiver?.track?.kind || transceiver?.sender?.track?.kind || '';

  const bindPeerMedia = async (pc, stream) => {
    const active = pc.getTransceivers().filter((t) => t && !t.stopped);
    // receiver.track can still be null immediately after setRemoteDescription.
    // Throwing there used to abort the answer, so neither side ever heard the other.
    const audio = active.find((t) => transceiverKind(t) === 'audio') || active[0];
    const video = active.find((t) => transceiverKind(t) === 'video');
    const track = outgoingAudioTrack(stream);
    if (!audio || !track || transceiverKind(audio) === 'video') {
      debug('RTC', 'microphone_bind_deferred', { has_audio_transceiver: !!audio && transceiverKind(audio) !== 'video', has_track: !!track }, 'warn');
      return;
    }
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
    const mine = Number(meId);
    if (!Number.isInteger(mine) || mine <= 0) {
      // Guessing the offerer before we know our own id makes both sides wait
      // for an offer that nobody sends.
      const attempts = identityRetries.get(uid) || 0;
      if (attempts < 8) {
        identityRetries.set(uid, attempts + 1);
        debug('RTC', 'peer_waiting_for_identity', { peer_user_id: uid, attempt: attempts + 1 }, 'warn');
        setTimeout(() => {
          if (stale()) return;
          ensurePeer(uid).then((pc) => {
            if (pc?._offerer && !pc._negotiated) makeOffer(uid, pc).catch(() => {});
          }).catch(() => {});
        }, 400);
      }
      return null;
    }
    identityRetries.delete(uid);
    const offerer = mine > Number(uid);
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
    pc._remoteAudioTrack = null;
    pc._lastInboundBytes = null;
    pc._lastInboundPackets = null;
    pc._lastRtpProgressAt = 0;
    pc._createdAt = Date.now();
    pc._lastNegotiationAt = 0;
    pc._turnValidUntil = rtcHasTurn() ? rtcConfigValidUntil : 0;
    pc._holdLocalCandidates = true;
    pc._heldLocalCandidates = [];
    pc._releaseLocalCandidates = () => {
      pc._holdLocalCandidates = false;
      const queued = pc._heldLocalCandidates.splice(0);
      queued.forEach((candidate) => sendSignal(uid, { kind: 'candidate', candidate }));
    };
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
        if (pc._holdLocalCandidates) pc._heldLocalCandidates.push(ev.candidate);
        else sendSignal(uid, { kind: 'candidate', candidate: ev.candidate });
      } else debug('RTC', 'ice_gathering_complete', { peer_user_id: uid });
    };
    const transportConnected = () => pc.connectionState === 'connected' || pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed';
    const liveRemoteAudioTrack = () => {
      const receiverTrack = pc.getReceivers?.().map((receiver) => receiver.track).find((track) => track?.kind === 'audio' && track.readyState === 'live');
      if (receiverTrack) return receiverTrack;
      return pc._remoteAudioTrack?.readyState === 'live' ? pc._remoteAudioTrack : null;
    };
    const publishConnectionState = (force = false) => {
      // "Connected" means the RTC transport is up and a live remote audio
      // receiver exists. MediaStreamTrack.muted is deliberately NOT part of
      // this decision: browsers can toggle it during silence, PipeWire graph
      // changes and source switches while audio is still healthy/audible.
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
        if (room?.epoch === pc._roomEpoch) {
          if (pc._autoRebuilt && room.audioConnectedAnnounced && !pc._repairAnnounced) {
            pc._repairAnnounced = true;
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Audio reconnected' });
          } else if (!room.audioConnectedAnnounced) {
            room.audioConnectedAnnounced = true;
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call audio connected' });
          }
        }
      }
    };
    pc._publishConnectionState = publishConnectionState;
    const markRemoteAudioHealthy = (reason = 'receiver_live') => {
      const track = liveRemoteAudioTrack();
      if (!track || !transportConnected() || pc.signalingState === 'closed') return false;
      pc._remoteAudioTrack = track;
      pc._remoteAudioSeen = true;
      pc._mediaConnected = true;
      if (pc._remoteMuteTimer) clearTimeout(pc._remoteMuteTimer);
      if (pc._mediaTimer) clearTimeout(pc._mediaTimer);
      pc._remoteMuteTimer = null;
      pc._mediaTimer = null;
      publishConnectionState();
      const audio = remoteAudio(uid);
      if (!deafened) playRemoteAudio(audio);
      debug('RTC', 'remote_audio_healthy', { peer_user_id: uid, reason, track_muted: track.muted === true });
      return true;
    };
    const sampleInboundAudio = async () => {
      if (pc.signalingState === 'closed') return;
      const track = liveRemoteAudioTrack();
      if (transportConnected() && track) markRemoteAudioHealthy('live_receiver');
      try {
        const receiver = pc.getReceivers?.().find((item) => item.track?.kind === 'audio');
        const stats = receiver?.getStats ? await receiver.getStats() : await pc.getStats();
        let inbound = null;
        stats?.forEach?.((report) => {
          if (report.type === 'inbound-rtp' && !report.isRemote && (report.kind === 'audio' || report.mediaType === 'audio')) inbound = report;
        });
        if (!inbound) return;
        const bytes = Number(inbound.bytesReceived || 0);
        const packets = Number(inbound.packetsReceived || 0);
        const progressed = (pc._lastInboundBytes !== null && bytes > pc._lastInboundBytes) ||
          (pc._lastInboundPackets !== null && packets > pc._lastInboundPackets);
        pc._lastInboundBytes = bytes;
        pc._lastInboundPackets = packets;
        if (progressed) {
          pc._lastRtpProgressAt = Date.now();
          pc._stalledAudioSince = 0;
          markRemoteAudioHealthy('rtp_progress');
        }
      } catch (error) {
        debug('RTC', 'remote_audio_stats_failed', { peer_user_id: uid, error: error.message }, 'warn');
      }
    };
    const startInboundAudioMonitor = () => {
      if (pc._statsTimer || pc.signalingState === 'closed') return;
      pc._statsTimer = setInterval(() => { sampleInboundAudio().catch(() => {}); }, 2000);
      sampleInboundAudio().catch(() => {});
    };
    const reconcileRemoteAudio = (reason) => {
      if (transportConnected() && liveRemoteAudioTrack()) markRemoteAudioHealthy(reason);
      startInboundAudioMonitor();
    };
    pc.ontrack = (ev) => {
      debug('RTC', 'remote_track', { peer_user_id: uid, kind: ev.track.kind, muted: ev.track.muted, ready_state: ev.track.readyState, streams: ev.streams?.length || 0 });
      if (ev.track.kind === 'audio') {
        pc._remoteAudioSeen = true;
        pc._remoteAudioTrack = ev.track;
        const audio = remoteAudio(uid);
        ev.track.addEventListener?.('unmute', () => {
          debug('RTC', 'remote_track_unmuted', { peer_user_id: uid });
          reconcileRemoteAudio('track_unmute');
        });
        ev.track.addEventListener?.('mute', () => {
          // `mute` only says the source temporarily has no media available. It
          // is not a call-disconnect signal, so keep the transport healthy and
          // let receiver/ICE state decide whether recovery is needed.
          debug('RTC', 'remote_track_temporarily_muted', { peer_user_id: uid });
          if (pc._remoteMuteTimer) clearTimeout(pc._remoteMuteTimer);
          pc._remoteMuteTimer = setTimeout(() => {
            pc._remoteMuteTimer = null;
            if (!room || pc._roomEpoch !== room.epoch || pc.signalingState === 'closed') return;
            reconcileRemoteAudio('muted_recheck');
          }, 3000);
        });
        ev.track.addEventListener?.('ended', () => {
          if (pc._remoteAudioTrack === ev.track) pc._remoteAudioTrack = null;
          pc._mediaConnected = false;
          publishConnectionState(true);
          if (!schedulePeerRebuild(uid, pc, 'remote_audio_ended')) {
            restartPeerIce(uid, pc, 'remote_audio_ended', { force: true });
          }
        });
        audio.srcObject = new MediaStream([ev.track]);
        audio.muted = deafened;
        ['loadedmetadata', 'canplay', 'playing'].forEach((eventName) => {
          audio.addEventListener(eventName, () => {
            reconcileRemoteAudio(`audio_${eventName}`);
            if (!deafened) playRemoteAudio(audio);
          }, { passive: true });
        });
        reconcileRemoteAudio('track_received');
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
        if (liveRemoteAudioTrack()) {
          // Event ordering can deliver ontrack before ICE/DTLS becomes
          // connected. Reconcile here rather than needlessly restarting ICE.
          markRemoteAudioHealthy('watchdog_live_receiver');
          return;
        }
        debug('RTC', 'remote_audio_missing', {
          peer_user_id: uid,
          remote_audio_seen: pc._remoteAudioSeen === true,
          connection: pc.connectionState,
          ice: pc.iceConnectionState
        }, 'warn');
        if (!schedulePeerRebuild(uid, pc, 'remote_audio_missing')) {
          restartPeerIce(uid, pc, 'remote_audio_missing', { force: true });
          if ((pc._reconnectAttempts || 0) < RTC_MAX_RECOVERY_ATTEMPTS) armMediaWatchdog();
        }
      }, 10000);
    };
    // Media gets a full watchdog period after the transport (re)connects.
    const rearmMediaWatchdog = () => {
      if (pc._mediaTimer) clearTimeout(pc._mediaTimer);
      pc._mediaTimer = null;
      reconcileRemoteAudio('transport_reconcile');
      if (pc._mediaConnected !== true) armMediaWatchdog();
    };
    pc.onconnectionstatechange = () => {
      debug('RTC', 'connection_state', { peer_user_id: uid, state: pc.connectionState });
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') pc._mediaConnected = false;
      if (pc.connectionState === 'connected') reconcileRemoteAudio('connection_connected');
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
      if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') reconcileRemoteAudio('ice_connected');
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

  const earlyCandidateKey = (uid) => `${room?.epoch || 0}:${Number(uid)}`;
  const rememberEarlyCandidate = (uid, candidate) => {
    if (!candidate || !room) return;
    const key = earlyCandidateKey(uid);
    const queued = earlyCandidates.get(key) || [];
    queued.push(candidate);
    if (queued.length > 64) queued.shift();
    earlyCandidates.set(key, queued);
  };
  const takeEarlyCandidates = (uid, pc) => {
    const queued = earlyCandidates.get(earlyCandidateKey(uid)) || [];
    earlyCandidates.delete(earlyCandidateKey(uid));
    queued.forEach((candidate) => pc._pendingCandidates.push(candidate));
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
    if (!pc) {
      // The offer that creates the peer may still be behind this candidate.
      if (signal.kind === 'candidate' && signal.candidate) rememberEarlyCandidate(uid, signal.candidate);
      else if (signal.kind === 'offer' && (identityRetries.get(uid) || 0) > 0 && (identityRetries.get(uid) || 0) < 8) {
        setTimeout(() => {
          if ((peerGenerations.get(uid) || 0) === generation) handleSignal(msg).catch(() => {});
        }, 450);
      }
      return;
    }
    takeEarlyCandidates(uid, pc);
    if (pc.remoteDescription) await drainPendingCandidates(uid, pc);
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
          // The offerer missed our answer and sent the same description again.
          if (pc.signalingState === 'stable' && pc.localDescription?.type === 'answer') {
            debug('RTC', 'offer_already_answered', { peer_user_id: uid });
            sendSignal(uid, { kind: 'answer', sdp: pc.localDescription });
            pc._releaseLocalCandidates?.();
            return;
          }
          // fallback for browsers that can't roll ICE back for us.
          if (!offerCollision) throw error;
          await pc.setLocalDescription({ type: 'rollback' });
          await pc.setRemoteDescription(signal.sdp);
        }
        pc._ignoreOffer = false;
        pc._failureReported = false;
        reportPeerFailure(uid, pc, false);
        debug('RTC', 'remote_offer_applied', { peer_user_id: uid });
        try {
          await bindPeerMedia(pc, await ensureMedia());
        } catch (error) {
          debug('RTC', 'microphone_bind_failed', { peer_user_id: uid, error: error.message }, 'warn');
        }
        if (!room || room.epoch !== pc._roomEpoch || pc.signalingState === 'closed') return;
        await drainPendingCandidates(uid, pc);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        markNegotiated(pc);
        debug('RTC', 'answer_ready', { peer_user_id: uid });
        sendSignal(uid, { kind: 'answer', sdp: pc.localDescription });
        pc._releaseLocalCandidates?.();
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
        } else if (!pc.remoteDescription) {
          // An answer for a description we no longer have cannot be applied.
          // Ask again with a fresh offer instead of waiting for a page reload.
          debug('RTC', 'answer_dropped', { peer_user_id: uid, signaling: pc.signalingState }, 'warn');
          if (pc._offerer) {
            pc._lastRecoveryAt = 0;
            restartPeerIce(uid, pc, 'answer_dropped', { force: true });
          }
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
    pendingRtcAction = null;
    startRtcPersistence();
    const epoch = room.epoch;
    debug('RTC', 'room_joined', { kind, id, participant_count: users.length });
    await ensureMedia();
    if (!room || room.epoch !== epoch) return;
    rtcLocalDeparture = false;
    if (!room.stateSynced) {
      // The server forgets seat state across a fresh join or reconnect and drops
      // changes made while ringing. Tell it what this client is actually doing.
      room.stateSynced = true;
      sendWs({ type: kind === 'voice' ? 'voice_state' : 'call_state', patch: { muted: micMuted, deafened, screen: !!screenStream, screen_audio: !!screenStream && screenAudioSource !== 'none' } });
    }
    const userId = (u) => Number(u.user_id || u.userId || u.profile?.id || 0);
    const mine = Number(meId);
    const roster = new Set(users.map(userId).filter((uid) => uid && uid !== mine));
    room.roster = roster;
    if (!room.joinRosterSeeded) {
      room.joinRosterSeeded = true;
      const liveIds = users.filter((user) => !user.reconnecting).map(userId).filter((uid) => uid && uid !== mine);
      // The caller is already seated when the other person accepts, and that
      // accept is not delivered as peer-joined. People already in the room
      // when we enter are not new joins. Reconnecting seats are not seeded,
      // so their later rejoin still dings.
      if (callAwaitingFirstGuest) {
        callAwaitingFirstGuest = false;
        liveIds.forEach(playPeerJoin);
      } else {
        liveIds.forEach((uid) => joinCueIds.add(uid));
      }
    }
    // A reconnecting participant has no socket, so offers to them are dropped.
    // Their rejoin announces a fresh session and the connection starts then.
    const ids = users.filter((u) => !u.reconnecting).map(userId).filter((uid) => uid && uid !== mine);
    Array.from(peers.keys()).forEach((uid) => { if (!roster.has(uid)) closePeer(uid); });
    ids.forEach((uid) => {
      const shouldOffer = Number(meId) > Number(uid);
      ensurePeer(uid).then((pc) => {
        if (!pc) return;
        if (shouldOffer && !pc._negotiated) callPeer(uid).catch(() => {});
        else if (!shouldOffer && pc.signalingState === 'stable' && !pc.remoteDescription) {
          // We cannot invent the offer. Asking immediately covers an offer that
          // was relayed before this client had joined the room.
          sendSignal(uid, { kind: 'renegotiate' });
        } else if (shouldOffer && pc.signalingState === 'have-local-offer' && pc.localDescription && !pc.remoteDescription) {
          sendSignal(uid, { kind: 'offer', sdp: pc.localDescription });
        }
        // roster wins; remind Elm what RTC already decided.
        pc._publishConnectionState?.(true);
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

  const handleSystemEvent = (msg) => {
    if (msg.type === 'account_restricted') {
      showAccountRestriction({ ...(msg.moderation || {}), state: msg.account_state || msg.moderation?.state || 'suspended' });
      return true;
    }
    if (msg.type === 'account_restored') {
      document.getElementById('plainwire-account-restriction')?.remove();
      return true;
    }
    if (msg.type === 'account_disabled') {
      const moderation = msg.moderation || {};
      if (moderation.reason || moderation.title) showAccountRestriction({ ...moderation, state: msg.account_state || 'disabled' });
      else scheduleAuthReload();
      return true;
    }
    if (msg.type === 'sessions_revoked') {
      scheduleAuthReload();
      return true;
    }
    if (msg.type === 'system_banners_changed') {
      refreshGlobalBanners();
      // Active-banner reads are cached very briefly on each API node. A hosted
      // deployment can have several API nodes, so do one delayed reconciliation
      // as well; this closes the tiny cross-node cache window without reloads or
      // continuous polling.
      setTimeout(() => { if (!document.hidden) refreshGlobalBanners(); }, 1400);
      return true;
    }
    if (msg.type === 'service_settings_changed') {
      // Registration and similar host controls are authoritative server-side.
      // Existing signed-in tabs only need a light config refresh; no full reload.
      fetch('/api/client-config', { headers: { accept: 'application/json' }, cache: 'no-store' }).catch(() => {});
      return true;
    }
    return false;
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
      // Rebuild server-side presence-watch indexes after a realtime registry
      // restart even when the browser's local Set itself did not change.
      sendWs({ type: 'presence_watch', user_ids: Array.from(presenceWatch) });
      const route = location.hash.match(/^#(dm|channel)\/(\d+)$/);
      if (route) api({ method: 'GET', path: `/messages?scope=${route[1] === 'dm' ? 'direct' : 'channel'}&scope_id=${route[2]}` });
      return;
    }
    if (/^(voice|call)_/.test(msg.type || '')) debug('RTC', 'server_event', { message: msg });
    if (['voice_state', 'call_state', 'voice_peer_joined', 'call_peer_joined', 'call_ringing', 'call_incoming'].includes(msg.type)) markActive();
    if (msg.type === 'call_ringing' && pendingRtcAction?.action === 'start') pendingRtcAction = null;
    if (failPendingRtcAction(msg)) return true;
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
      if (peerUid && peerUid !== Number(meId)) {
        playPeerJoin(peerUid);
        // A join is always a fresh session on their side (new tab, reload or new
        // socket). Pairing it with our old connection's ICE/DTLS state never connects.
        replacePeerSession(peerUid);
        const shouldOffer = Number(meId) > Number(peerUid);
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
      // Own id, or any leave that arrives while this client is itself departing,
      // is the echo of us leaving — not someone else leaving.
      if (leftUid && leftUid !== Number(meId) && !rtcLocalDeparture) {
        joinCueIds.delete(leftUid);
        playSound('peerLeave');
      }
    }
    if ((msg.type === 'voice_signal' || msg.type === 'call_signal') && eventMatchesRoom(msg)) handleSignal(msg).catch(() => {});
    if (['call_declined', 'call_cancelled', 'call_missed', 'call_ended'].includes(msg.type) && eventMatchesRoom(msg)) leaveRtcRoom();
    if (msg.type === 'call_accepted') stopRingtones();
    if ((msg.type === 'voice_superseded' || msg.type === 'call_superseded') && eventMatchesRoom(msg)) {
      debug('RTC', 'superseded', { type: msg.type });
      leaveRtcRoom();
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'Another tab has taken over this session.' });
    }
    if (msg.type === 'access_revoked') {
      if (msg.scope === 'direct' && Number(msg.conversation_id) > 0) {
        const key = `direct:${Number(msg.conversation_id)}`;
        clearRemoteTyping((scopeKey) => scopeKey === key);
        if (localTyping?.scope?.key === key) stopTyping(localTyping.scope, { skipNetwork: true });
      } else if (msg.scope === 'server' && Array.isArray(msg.channel_ids)) {
        const revoked = new Set(msg.channel_ids.map(Number).filter((id) => Number.isInteger(id) && id > 0).map((id) => `channel:${id}`));
        clearRemoteTyping((scopeKey) => revoked.has(scopeKey));
        if (localTyping?.scope?.key && revoked.has(localTyping.scope.key)) stopTyping(localTyping.scope, { skipNetwork: true });
      }
      const revokedRtc = (msg.scope === 'server' && room?.kind === 'voice' && Array.isArray(msg.channel_ids) && msg.channel_ids.map(Number).includes(Number(room.id)))
        || (msg.scope === 'direct' && room?.kind === 'call' && Number(msg.conversation_id) === Number(room.id));
      if (revokedRtc) {
        debug('RTC', 'access_revoked', { scope: msg.scope, room });
        leaveRtcRoom();
        send(app.ports.bridgeReceive, { tag: 'toast', data: 'Call ended because access to this room changed.' });
      }
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
    // Muting is a media-track state change only. Never tear down, replace or
    // renegotiate peers here; doing so turns a UI toggle into a call drop.
    micMuted = !!muted;
    if (localStream) localStream.getAudioTracks().forEach((t) => { t.enabled = !micMuted; });
    if (!deafened) mutedBeforeDeafen = micMuted;
    persistRtcIntent();
    publishAudioState();
    debug('MEDIA', 'microphone_muted_changed', { muted: micMuted, tracks: localStream?.getAudioTracks().length || 0 });
  };

  const setDeafened = (value) => {
    // Deafening is local playback + microphone state only. Existing RTC
    // transports remain alive so undeafening is immediate.
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
      document.documentElement.classList.add('pw-call-detached');
      document.documentElement.style.setProperty('--pw-call-left', next.x + 'px');
      document.documentElement.style.setProperty('--pw-call-top', next.y + 'px');
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
      document.documentElement.classList.remove('pw-call-detached');
      document.documentElement.style.removeProperty('--pw-call-left');
      document.documentElement.style.removeProperty('--pw-call-top');
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

    const keepLayerOnScreen = (target) => {
      if (!target || !desktop() || drag || resizing) return;
      const rect = target.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8) return;
      if (rect.top >= 10 && rect.left >= 10 && rect.bottom <= innerHeight - 10 && rect.right <= innerWidth - 10) return;
      setLayerPosition(target, clamp(target, rect.left, rect.top), false);
    };

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
      if (saved) requestAnimationFrame(() => { setLayerPosition(node, saved, false); keepLayerOnScreen(node); });
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
      if (!handle) return;
      if (ev.target.closest('.call-bar-controls, .call-overlay-controls, .call-popup-actions, .call-minimize')) return;
      const blocking = ev.target.closest('input, select, a, textarea');
      if (blocking) return;
      const node = handle.closest('.call-layer') || layer();
      if (!node) return;
      const rect = node.getBoundingClientRect();
      drag = {
        node,
        pointerId: ev.pointerId,
        handle,
        startX: ev.clientX,
        startY: ev.clientY,
        originX: rect.left,
        originY: rect.top,
        nextX: rect.left,
        nextY: rect.top,
        moved: false
      };
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
      if (!drag.moved && Math.hypot(dx, dy) < 10) return;
      if (!drag.moved) {
        drag.moved = true;
        drag.handle?.setPointerCapture?.(ev.pointerId);
      }
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
      if (!handle) return;
      if (ev.target.closest('.call-bar-controls, .call-overlay-controls, .call-popup-actions, .call-minimize, input, select, a')) return;
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
    observer.observe(root || document.body, { childList: true, subtree: true });
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
  // Plainwire owns context menus for app surfaces. Editable controls retain the
  // browser menu so privileged Cut/Copy/Paste remains reliable; links, images and
  // non-editable selections get a small fallback when Elm has no richer menu.
  let fallbackContextMenu = null;
  const closeFallbackContextMenu = () => { fallbackContextMenu?.remove(); fallbackContextMenu = null; };
  const nativeEditingContextTarget = (target) => target?.closest?.('input:not([type="button"]):not([type="submit"]), textarea, [contenteditable]:not([contenteditable="false"])');
  const openFallbackContextMenu = (target, x, y) => {
    closeFallbackContextMenu();
    const link = target?.closest?.('a[href]');
    const image = target?.closest?.('img[src]');
    const selectedText = String(window.getSelection?.()?.toString?.() || '').trim();
    const actions = [];
    if (selectedText) {
      actions.push(['Copy selection', () => navigator.clipboard.writeText(selectedText).catch(() => {}), false]);
    }
    if (link) {
      let href = '';
      try { href = new URL(link.href, location.href).href; } catch (_) {}
      if (href) {
        actions.push(['Open link in new tab', () => window.open(href, '_blank', 'noopener,noreferrer'), false]);
        actions.push(['Copy link', () => navigator.clipboard.writeText(href).catch(() => {}), false]);
      }
    }
    if (image) {
      let src = '';
      try { src = new URL(image.currentSrc || image.src, location.href).href; } catch (_) {}
      if (src) {
        actions.push(['Open image in new tab', () => window.open(src, '_blank', 'noopener,noreferrer'), false]);
        actions.push(['Copy image address', () => navigator.clipboard.writeText(src).catch(() => {}), false]);
      }
    }
    if (!actions.length) return;
    const menu = document.createElement('div'); menu.className = 'fallback-context-menu'; menu.setAttribute('role', 'menu'); menu.tabIndex = -1;
    actions.forEach(([label, action, disabled]) => {
      const button = document.createElement('button'); button.type = 'button'; button.textContent = label; button.disabled = !!disabled; button.setAttribute('role', 'menuitem');
      button.addEventListener('click', async () => { closeFallbackContextMenu(); await action(); }); menu.append(button);
    });
    menu.addEventListener('keydown', event => {
      const items = [...menu.querySelectorAll('button:not(:disabled)')];
      const index = items.indexOf(document.activeElement);
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeFallbackContextMenu(); target?.focus?.({ preventScroll: true }); return; }
      if (!items.length || !['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items[next].focus();
    });
    document.body.append(menu); fallbackContextMenu = menu;
    const rect = menu.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(x, innerWidth - rect.width - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, innerHeight - rect.height - 8))}px`;
    menu.querySelector('button:not(:disabled)')?.focus({ preventScroll: true });
  };
  document.addEventListener('contextmenu', (event) => {
    const target = event.target;
    // Clipboard reads from a scripted menu are permission-gated and may be
    // rejected even though the user just right-clicked. Native editing menus
    // can paste without granting page-level clipboard-read permission.
    if (nativeEditingContextTarget(target)) {
      closeFallbackContextMenu();
      return;
    }
    event.preventDefault();
    const x = event.clientX, y = event.clientY;
    closeFallbackContextMenu();
    requestAnimationFrame(() => {
      // Elm message/user/server/channel menus win. Only supply the generic
      // desktop menu if no richer Plainwire menu appeared for this gesture.
      if (!document.querySelector('.ctx-menu')) openFallbackContextMenu(target, x, y);
    });
  }, true);
  let longPressContext = null;
  let suppressLongPressClickUntil = 0;
  let suppressLongPressTarget = null;
  const clearLongPressContext = () => {
    if (longPressContext?.timer) clearTimeout(longPressContext.timer);
    longPressContext = null;
  };
  document.addEventListener('pointerdown', event => {
    if (fallbackContextMenu && !fallbackContextMenu.contains(event.target)) closeFallbackContextMenu();
    clearLongPressContext();
    if (event.pointerType !== 'touch' || event.button !== 0) return;
    const target = event.target?.closest?.('[data-long-context="true"]');
    if (!target || event.target?.closest?.('button, a, input, textarea, select, [contenteditable="true"]')) return;
    const state = {
      pointerId: event.pointerId,
      x: event.clientX, y: event.clientY,
      target, timer: null
    };
    state.timer = setTimeout(() => {
      if (longPressContext !== state || !target.isConnected) return;
      suppressLongPressClickUntil = Date.now() + 700;
      suppressLongPressTarget = target;
      // Do not retain a detached message/member node indefinitely if the browser
      // suppresses the synthetic follow-up click after a long press.
      setTimeout(() => {
        if (suppressLongPressTarget === target && Date.now() >= suppressLongPressClickUntil) {
          suppressLongPressTarget = null;
          suppressLongPressClickUntil = 0;
        }
      }, 760);
      target.dispatchEvent(new MouseEvent('contextmenu', {
        bubbles: true, cancelable: true, composed: true,
        clientX: state.x, clientY: state.y, button: 2, buttons: 0
      }));
      if (navigator.vibrate) navigator.vibrate(12);
      clearLongPressContext();
    }, 520);
    longPressContext = state;
  }, true);
  document.addEventListener('pointermove', event => {
    const state = longPressContext;
    if (!state || state.pointerId !== event.pointerId) return;
    if (Math.hypot(event.clientX - state.x, event.clientY - state.y) > 12) clearLongPressContext();
  }, true);
  ['pointerup', 'pointercancel'].forEach((name) => document.addEventListener(name, clearLongPressContext, true));
  document.addEventListener('scroll', clearLongPressContext, true);
  document.addEventListener('click', event => {
    if (Date.now() > suppressLongPressClickUntil || !suppressLongPressTarget) return;
    if (event.target === suppressLongPressTarget || suppressLongPressTarget.contains(event.target)) {
      event.preventDefault();
      event.stopPropagation();
      suppressLongPressClickUntil = 0;
      suppressLongPressTarget = null;
    }
  }, true);

  const shortcutEditableTarget = (target) => Boolean(target?.closest?.('input, textarea, select, [contenteditable="true"]'));
  const shortcutDialogOpen = () => Boolean(document.querySelector('dialog[open], .modal'));
  const emitShortcut = (data) => send(app.ports.bridgeReceive, { tag: 'shortcut', data });

  document.addEventListener('keydown', (event) => {
    if (event.isComposing) return;

    const contextMenu = event.target?.closest?.('.ctx-menu');
    if (contextMenu) {
      const items = [...contextMenu.querySelectorAll('.ctx-item:not(:disabled)')];
      const index = Math.max(0, items.indexOf(document.activeElement));
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const delta = event.key === 'ArrowDown' ? 1 : -1;
        items[(index + delta + items.length) % items.length]?.focus({ preventScroll: true });
        return;
      }
      if (event.key === 'Home' || event.key === 'End') {
        event.preventDefault();
        items[event.key === 'Home' ? 0 : items.length - 1]?.focus({ preventScroll: true });
        return;
      }
    }

    const editor = event.target?.closest?.('textarea[data-message-editor="true"]');
    if (editor) {
      if (event.key === 'Escape') {
        event.preventDefault();
        editor.closest('.message-editor')?.querySelector('[data-edit-cancel="true"]')?.click();
        return;
      }
      if (event.key === 'Enter' && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
        event.preventDefault();
        editor.closest('.message-editor')?.querySelector('[data-edit-save="true"]:not(:disabled)')?.click();
        return;
      }
    }

    if (event.key === 'Escape') {
      const close = document.querySelector('.modal .modal-head > button');
      if (close) { event.preventDefault(); close.click(); return; }
      const contextBackdrop = document.querySelector('.ctx-backdrop');
      if (contextBackdrop) { event.preventDefault(); contextBackdrop.click(); return; }
      // With no transient UI open, Escape doubles as Discord's incoming-call
      // decline shortcut. Elm ignores this when there is no incoming call.
      emitShortcut('decline_call');
      return;
    }

    if (event.repeat) return;
    const mod = event.ctrlKey || event.metaKey;
    const editable = shortcutEditableTarget(event.target);
    const key = event.key.toLowerCase();

    // Discord-style quick edit: Up on an empty active composer edits the most
    // recent editable message authored by this account. Restrict this to the
    // actual composer so arrow navigation elsewhere is never stolen.
    const composer = activeComposer();
    if (!event.repeat && event.target === composer && event.key === 'ArrowUp'
        && !mod && !event.altKey && composer.value.trim() === '') {
      event.preventDefault();
      emitShortcut('edit_last_message');
      return;
    }

    // Ctrl/Cmd+K is intentionally left to <pw-quick-switcher>, which owns its
    // search field and focus lifecycle. The shortcuts below route through Elm.
    if (mod && event.shiftKey && key === 'm') {
      event.preventDefault();
      emitShortcut('toggle_mute');
      return;
    }
    if (mod && event.shiftKey && key === 'd') {
      event.preventDefault();
      emitShortcut('toggle_deafen');
      return;
    }
    if (mod && event.shiftKey && key === 'l') {
      event.preventDefault();
      const composer = activeComposer();
      if (composer) composer.focus({ preventScroll: false });
      else send(app.ports.bridgeReceive, { tag: 'toast', data: 'Open a conversation or text channel to focus the message box.' });
      return;
    }
    if (mod && event.shiftKey && key === 'u' && (!editable || event.target === composer)) {
      event.preventDefault();
      emitShortcut('upload');
      return;
    }
    if (mod && event.shiftKey && key === 's' && !editable) {
      event.preventDefault();
      emitShortcut('screen_share');
      return;
    }
    if (mod && event.shiftKey && key === 'c' && !editable) {
      event.preventDefault();
      emitShortcut('toggle_call_window');
      return;
    }
    if (mod && event.shiftKey && event.key === 'Backspace' && !editable) {
      event.preventDefault();
      emitShortcut('close_dm');
      return;
    }
    if (mod && event.shiftKey && key === 'h' && !editable) {
      event.preventDefault();
      emitShortcut('help');
      return;
    }
    if (mod && event.shiftKey && key === 'n' && !editable) {
      event.preventDefault();
      emitShortcut('new_server');
      return;
    }
    if (mod && event.shiftKey && key === 't' && !editable) {
      event.preventDefault();
      emitShortcut('new_group');
      return;
    }
    if (mod && event.altKey && key === 'a' && !editable) {
      event.preventDefault();
      emitShortcut('active_audio');
      return;
    }
    if (mod && event.altKey && !editable && !shortcutDialogOpen()
        && ['ArrowLeft', 'ArrowUp'].includes(event.key)) {
      event.preventDefault();
      emitShortcut('prev_server');
      return;
    }
    if (mod && event.altKey && !editable && !shortcutDialogOpen()
        && ['ArrowRight', 'ArrowDown'].includes(event.key)) {
      event.preventDefault();
      emitShortcut('next_server');
      return;
    }
    if (mod && event.key === 'Enter' && !editable && !event.altKey) {
      event.preventDefault();
      emitShortcut('answer_call');
      return;
    }
    if (mod && event.key === '[' && !editable && !event.altKey && !event.shiftKey) {
      event.preventDefault();
      emitShortcut('start_call');
      return;
    }
    if (mod && key === ',' && !editable) {
      event.preventDefault();
      emitShortcut('settings');
      return;
    }
    if (mod && key === 'g' && !event.altKey && (!editable || event.target === composer)) {
      event.preventDefault();
      openGifPicker();
      return;
    }
    if (mod && key === 'e' && !event.altKey && (!editable || event.target === composer)) {
      event.preventDefault();
      emitShortcut('emoji_picker');
      return;
    }
    if (mod && key === 'i' && !editable && !event.altKey && !event.shiftKey) {
      event.preventDefault();
      emitShortcut('notifications');
      return;
    }
    if (mod && key === '/' && !editable) {
      event.preventDefault();
      emitShortcut('help');
      return;
    }
    if (mod && key === 'f' && !editable && !shortcutDialogOpen()) {
      event.preventDefault();
      emitShortcut('search');
      return;
    }
    if (mod && key === 'b' && !editable && !event.altKey && !event.shiftKey && !shortcutDialogOpen()) {
      event.preventDefault();
      emitShortcut('prev_route');
      return;
    }
    if (event.altKey && event.shiftKey && !mod && !editable && !shortcutDialogOpen() && event.key === 'ArrowUp') {
      event.preventDefault();
      emitShortcut('prev_unread');
      return;
    }
    if (event.altKey && event.shiftKey && !mod && !editable && !shortcutDialogOpen() && event.key === 'ArrowDown') {
      event.preventDefault();
      emitShortcut('next_unread');
      return;
    }
    if (event.altKey && !event.shiftKey && !mod && !editable && !shortcutDialogOpen() && event.key === 'ArrowUp') {
      event.preventDefault();
      emitShortcut('prev_route');
      return;
    }
    if (event.altKey && !event.shiftKey && !mod && !editable && !shortcutDialogOpen() && event.key === 'ArrowDown') {
      event.preventDefault();
      emitShortcut('next_route');
    }
  }, true);
  recv(app.ports.copyText, async (text) => {
    try {
      await navigator.clipboard.writeText((text.startsWith('#wire/') || text.startsWith('#invite/')) ? new URL(text.replace('#invite/','#wire/'), location.origin + '/').href : text);
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

  const closeAccountDialog = () => {
    const backdrop = document.querySelector('.account-dialog-backdrop');
    if (!backdrop) return;
    backdrop.dispatchEvent(new Event('plainwire:dialog-close'));
    backdrop.remove();
  };

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

  const openUsernameDialog = (currentUsername = '') => {
    const content = document.createElement('div');
    content.className = 'account-password-fields';

    const usernameField = document.createElement('label');
    usernameField.className = 'field';
    const usernameLabel = document.createElement('span');
    usernameLabel.textContent = 'New username';
    const username = document.createElement('input');
    username.type = 'text';
    username.autocomplete = 'username';
    username.spellcheck = false;
    username.maxLength = 24;
    username.value = String(currentUsername || '').toLowerCase();
    username.placeholder = 'username';
    username.setAttribute('aria-describedby', 'username-change-help');
    const usernameHelp = document.createElement('small');
    usernameHelp.id = 'username-change-help';
    usernameHelp.className = 'muted';
    usernameHelp.textContent = '3–24 characters: lowercase letters, numbers, _ or -. This changes your global @username.';
    usernameField.append(usernameLabel, username, usernameHelp);

    const passwordField = document.createElement('label');
    passwordField.className = 'field';
    const passwordLabel = document.createElement('span');
    passwordLabel.textContent = 'Current password';
    const password = document.createElement('input');
    password.type = 'password';
    password.autocomplete = 'current-password';
    password.maxLength = 256;
    passwordField.append(passwordLabel, password);

    const status = document.createElement('div');
    status.className = 'account-dialog-status';
    content.append(usernameField, passwordField, status);

    username.addEventListener('input', () => {
      const normalized = username.value.toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 24);
      if (username.value !== normalized) username.value = normalized;
      status.textContent = '';
    });

    showAccountDialog({
      title: 'Change username',
      subtitle: 'Your numeric account identity stays the same, so friends, DMs, servers, roles, and operator access remain attached to you.',
      content,
      actions: [
        { label: 'Cancel', onClick: closeAccountDialog },
        { label: 'Change username', className: 'btn', onClick: async (button) => {
          status.textContent = '';
          const next = username.value.trim().toLowerCase();
          if (!/^[a-z0-9_-]{3,24}$/.test(next)) {
            status.textContent = 'Use 3–24 lowercase letters, numbers, underscores, or hyphens.';
            username.focus();
            return;
          }
          if (!password.value) {
            status.textContent = 'Enter your current password to confirm this identity change.';
            password.focus();
            return;
          }
          button.disabled = true;
          try {
            const data = await accountApi('POST', '/username', { username: next, expected_username: String(currentUsername || '').toLowerCase(), current_password: password.value });
            closeAccountDialog();
            await Promise.allSettled([
              api({ method: 'GET', path: '/me' }),
              api({ method: 'GET', path: '/sync?since=0' })
            ]);
            reconcileVisibleApp('username_changed');
            send(app.ports.bridgeReceive, {
              tag: 'toast',
              data: data?.changed === false ? `Your username is already @${next}.` : `Username changed to @${data?.username || next}.`
            });
          } catch (error) {
            const message = {
              username_taken: 'That username is already taken.',
              invalid_username: 'Use 3–24 lowercase letters, numbers, underscores, or hyphens.',
              bad_password: 'Current password is incorrect.',
              rate_limited: 'Too many username changes. Try again later.',
              username_changed_elsewhere: 'Your username changed in another session. Close this dialog and reopen Account settings before trying again.'
            }[error.message] || 'Could not change the username.';
            status.textContent = message;
          } finally {
            button.disabled = false;
          }
        } }
      ]
    });
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

  const mailFailureText = (reason, saved) => {
    const lead = saved ? 'The address was saved, but ' : '';
    if (reason === 'mail_disabled') return `${lead}mail is not enabled on this server.`;
    if (reason === 'mail_auth') return `${lead}the mail server rejected the login.`;
    if (reason === 'mail_tls') return `${lead}a secure connection to the mail server could not be started.`;
    if (reason === 'mail_timeout') return `${lead}the mail server did not answer in time.`;
    if (reason === 'mail_unavailable') return `${lead}the mail server could not be reached.`;
    return `${lead}the mail server did not accept the verification message.`;
  };

  const openEmailDialog = (currentEmail = '') => {
    const content = document.createElement('div');
    content.className = 'account-password-fields';
    const intro = document.createElement('p');
    intro.className = 'muted';
    intro.textContent = currentEmail
      ? 'A verified email is required to reset a forgotten password. Changing it sends a new verification link.'
      : 'Password reset is unavailable until this account has a verified email.';
    const emailField = document.createElement('label'); emailField.className = 'field';
    const emailLabel = document.createElement('span'); emailLabel.textContent = 'Email';
    const email = document.createElement('input'); email.type = 'email'; email.autocomplete = 'email'; email.maxLength = 254; email.value = currentEmail;
    emailField.append(emailLabel, email);
    const passwordField = document.createElement('label'); passwordField.className = 'field';
    const passwordLabel = document.createElement('span'); passwordLabel.textContent = 'Current password';
    const password = document.createElement('input'); password.type = 'password'; password.autocomplete = 'current-password'; password.maxLength = 256;
    passwordField.append(passwordLabel, password);
    const status = document.createElement('div'); status.className = 'account-dialog-status';
    content.append(intro, emailField, passwordField, status);
    const actions = [
      { label: 'Cancel', onClick: closeAccountDialog },
      { label: 'Save email', className: 'btn', onClick: async (button) => {
        status.textContent = '';
        const next = email.value.trim();
        if (!next || !next.includes('@') || !next.includes('.')) { status.textContent = 'Enter a valid email address.'; return; }
        button.disabled = true;
        try {
          const saved = await accountApi('POST', '/email', { email: next, password: password.value });
          api({ method: 'GET', path: '/me' });
          if (saved.email_delivery === false) {
            status.textContent = mailFailureText(saved.email_error, true);
            return;
          }
          closeAccountDialog();
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Check your inbox to verify this email.' });
        } catch (error) {
          status.textContent = error.message === 'bad_password' ? 'Current password is incorrect.'
            : error.message === 'email_taken' ? 'That email is already verified on another account.'
            : error.message === 'invalid_email' ? 'Enter a valid email address.'
            : 'Could not save the email.';
        } finally { button.disabled = false; }
      } }
    ];
    if (currentEmail) {
      actions.splice(1, 0, {
        label: 'Resend verification', className: 'btn secondary', onClick: async (button) => {
          button.disabled = true; status.textContent = '';
          try {
            const sent = await accountApi('POST', '/email/resend', {});
            if (sent.already_verified) {
              send(app.ports.bridgeReceive, { tag: 'toast', data: 'This email is already verified.' });
            } else if (sent.email_delivery === false) {
              status.textContent = mailFailureText(sent.email_error, false);
            } else {
              send(app.ports.bridgeReceive, { tag: 'toast', data: 'Verification email sent.' });
            }
          } catch (error) {
            status.textContent = error.message === 'email_required' ? 'Add an email first.' : 'Could not resend verification.';
          } finally { button.disabled = false; }
        }
      });
      actions.splice(1, 0, {
        label: 'Remove email', className: 'btn ghost', onClick: async (button) => {
          if (!password.value) { status.textContent = 'Enter your current password to remove the email.'; return; }
          button.disabled = true; status.textContent = '';
          try {
            await accountApi('POST', '/email/remove', { password: password.value });
            closeAccountDialog();
            send(app.ports.bridgeReceive, { tag: 'toast', data: 'Email removed. Password reset is unavailable until you add a verified address.' });
            api({ method: 'GET', path: '/me' });
          } catch (error) {
            status.textContent = error.message === 'bad_password' ? 'Current password is incorrect.' : 'Could not remove the email.';
          } finally { button.disabled = false; }
        }
      });
    }
    showAccountDialog({
      title: 'Email and verification',
      subtitle: 'Reset links are only sent to a verified address.',
      content,
      actions
    });
  };

  const openAccountLifecycleDialog = (mode) => {
    const deleting = mode === 'delete';
    const content = document.createElement('div');
    content.className = 'account-password-fields';
    const warning = document.createElement('p');
    warning.className = deleting ? 'account-destructive-warning' : 'muted';
    warning.textContent = deleting
      ? 'This permanently removes your account row and account-owned data that cannot survive without an owner. Servers, group DMs, and forums with other members are transferred to an existing member where possible. This cannot be undone.'
      : 'Disabling signs out every session immediately. Your durable data stays in PostgreSQL, and signing in again with your password reactivates the account.';
    const field = document.createElement('label'); field.className = 'field';
    const label = document.createElement('span'); label.textContent = 'Current password';
    const password = document.createElement('input'); password.type = 'password'; password.autocomplete = 'current-password'; password.maxLength = 256;
    field.append(label, password);
    const confirm = document.createElement('label'); confirm.className = 'field';
    const confirmLabel = document.createElement('span'); confirmLabel.textContent = deleting ? 'Type DELETE to confirm' : 'Type DISABLE to confirm';
    const confirmInput = document.createElement('input'); confirmInput.type = 'text'; confirmInput.autocomplete = 'off'; confirmInput.spellcheck = false;
    confirm.append(confirmLabel, confirmInput);
    const status = document.createElement('div'); status.className = 'account-dialog-status';
    content.append(warning, field, confirm, status);
    showAccountDialog({
      title: deleting ? 'Delete account permanently' : 'Disable account',
      subtitle: deleting ? 'Plainwire will not keep a ghost user profile behind.' : 'This is reversible by signing in again.',
      content,
      actions: [
        { label: 'Cancel', onClick: closeAccountDialog },
        { label: deleting ? 'Delete account' : 'Disable account', className: 'btn danger', onClick: async (button) => {
          status.textContent = '';
          const expected = deleting ? 'DELETE' : 'DISABLE';
          if (confirmInput.value.trim() !== expected) { status.textContent = `Type ${expected} exactly to continue.`; confirmInput.focus(); return; }
          if (!password.value) { status.textContent = 'Enter your current password.'; password.focus(); return; }
          button.disabled = true;
          try {
            await accountApi('POST', deleting ? '/account/delete' : '/account/disable', { password: password.value });
            closeAccountDialog();
            try { ws?.close?.(1000, deleting ? 'account deleted' : 'account disabled'); } catch (_) {}
            location.hash = '#login';
            location.reload();
          } catch (error) {
            status.textContent = ({ bad_password: 'Current password is incorrect.', rate_limited: 'Too many attempts. Try again later.' })[error.message]
              || (deleting ? 'Could not delete the account.' : 'Could not disable the account.');
            button.disabled = false;
          }
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

  // Entries render hidden until this resolves. Auth screens contain no entry,
  // so an unauthenticated 401 here is harmless and is retried once the app renders.
  queueMicrotask(() => loadOnboardingState());


  class PlainwireDeveloperPortal extends HTMLElement {
    constructor() {
      super();
      this.apps = [];
      this.servers = [];
      this.permissions = [];
      this.selectedId = 0;
      this.detailTab = 'general';
      this.loadGeneration = 0;
    }
    connectedCallback() { this.refresh(); }
    disconnectedCallback() { this.loadGeneration += 1; }
    el(tag, className = '', text = '') {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (text) node.textContent = text;
      return node;
    }
    button(label, fn, className = 'btn') {
      const button = this.el('button', className, label); button.type = 'button';
      button.addEventListener('click', fn); return button;
    }
    field(label, value = '', { multiline = false, placeholder = '', type = 'text', maxLength = 2048 } = {}) {
      const wrap = this.el('label', 'developer-field');
      const title = this.el('span', '', label);
      const input = multiline ? document.createElement('textarea') : document.createElement('input');
      if (!multiline) input.type = type;
      input.value = String(value ?? ''); input.placeholder = placeholder; input.maxLength = maxLength;
      if (multiline) input.rows = 4;
      wrap.append(title, input); return { wrap, input };
    }
    async refresh(preferId = this.selectedId) {
      const generation = ++this.loadGeneration;
      this.replaceChildren(this.el('div', 'developer-loading', 'Loading applications…'));
      try {
        const [apps, servers, permissions] = await Promise.all([
          directApi('/developer/apps'), directApi('/servers'), directApi('/developer/permissions')
        ]);
        if (!this.isConnected || generation !== this.loadGeneration) return;
        this.apps = Array.isArray(apps) ? apps : [];
        this.servers = Array.isArray(servers) ? servers : (Array.isArray(servers?.servers) ? servers.servers : []);
        this.permissions = Array.isArray(permissions) ? permissions : [];
        this.selectedId = this.apps.some(item => Number(item.id) === Number(preferId)) ? Number(preferId) : Number(this.apps[0]?.id || 0);
        this.render();
      } catch (error) {
        if (!this.isConnected || generation !== this.loadGeneration) return;
        const box = this.el('div', 'developer-empty'); box.append(this.el('strong', '', 'Developer Portal unavailable'), this.el('p', '', error.message)); this.replaceChildren(box);
      }
    }
    async selectApp(id) { this.selectedId = Number(id); this.detailTab = 'general'; this.render(); await this.renderDetail(); }
    render() {
      const root = this.el('div', 'developer-portal');
      const toolbar = this.el('div', 'developer-toolbar');
      const intro = this.el('div'); intro.append(this.el('h2', '', 'Your applications'), this.el('p', '', 'Build Discord-style slash commands, signed HTTPS bots, or a no-code AI chatbot. Mix them whenever you want more control.'));
      toolbar.append(intro, this.button('New application', () => this.createApp()));
      root.append(toolbar);
      const layout = this.el('div', 'developer-layout');
      const sidebar = this.el('aside', 'developer-app-list');
      for (const appItem of this.apps) {
        const btn = this.el('button', 'developer-app-row'); btn.type = 'button'; btn.classList.toggle('active', Number(appItem.id) === this.selectedId);
        const avatar = this.el('span', 'developer-app-avatar', String(appItem.name || '?').slice(0, 1).toUpperCase());
        if (appItem.avatar_url) { avatar.style.backgroundImage = `url(${JSON.stringify(String(appItem.avatar_url)).slice(1,-1)})`; avatar.textContent = ''; }
        const copy = this.el('span', 'developer-app-copy'); copy.append(this.el('b', '', appItem.name || 'Application'), this.el('small', '', appItem.public ? 'Public application' : 'Private application'));
        btn.append(avatar, copy); btn.addEventListener('click', () => this.selectApp(appItem.id)); sidebar.append(btn);
      }
      if (!this.apps.length) sidebar.append(this.el('div', 'developer-empty compact', 'No applications yet. Create one to get started.'));
      const panel = this.el('section', 'developer-panel'); panel.dataset.developerPanel = 'true';
      layout.append(sidebar, panel); root.append(layout); this.replaceChildren(root); this.renderDetail();
    }
    async createApp() {
      const modal = modalShell('Create application', 'Start no-code, connect your own code later, or combine both. Every server install gets an isolated bot identity and token.');
      const name = this.field('Application name', '', { placeholder: 'My Plainwire Bot', maxLength: 48 });
      const kindWrap = this.el('label', 'developer-field'); kindWrap.append(this.el('span', '', 'Start with'));
      const kind = document.createElement('select');
      [['ai','AI assistant · no code'],['commands','Command bot · use an SDK'],['interactions','HTTPS interaction bot'],['general','Blank application']].forEach(([value,label]) => { const option=document.createElement('option'); option.value=value; option.textContent=label; kind.append(option); });
      kindWrap.append(kind, this.el('small','developer-provider-help','This only chooses the next setup screen. You can mix AI, SDK commands, and HTTPS interactions at any time.'));
      const actions = this.el('div', 'developer-actions');
      const create = this.button('Create application', async () => {
        create.disabled = true;
        try { const appData = await directApi('/developer/apps', { method: 'POST', body: { name: name.input.value.trim() } }); modal.destroy(); this.detailTab=kind.value; await this.refresh(appData.id); }
        catch (error) { send(app.ports.bridgeReceive, { tag: 'toast', data: error.message }); create.disabled = false; }
      });
      actions.append(create); modal.body.append(name.wrap, kindWrap, actions); name.input.focus();
    }
    async renderDetail() {
      const panel = this.querySelector('[data-developer-panel]'); if (!panel) return;
      panel.replaceChildren(); if (!this.selectedId) { panel.append(this.el('div', 'developer-empty', 'Create an application to manage bots and commands.')); return; }
      let appData;
      try { appData = await directApi(`/developer/apps/${this.selectedId}`); }
      catch (error) { panel.append(this.el('div', 'developer-empty', error.message)); return; }
      if (!this.isConnected || Number(appData.id) !== this.selectedId) return;
      const head = this.el('div', 'developer-detail-head');
      const title = this.el('div'); title.append(this.el('h2', '', appData.name), this.el('p', '', `${appData.public_id} · ${appData.public ? 'Public' : 'Private'}`)); head.append(title);
      const tabs = this.el('nav', 'developer-tabs');
      [['general','General'],['installations','Installations'],['commands','Commands'],['interactions','Interactions'],['ai','AI assistant'],['activity','Activity']].forEach(([id,label]) => {
        const b=this.el('button','',label); b.type='button'; b.classList.toggle('active',this.detailTab===id); b.addEventListener('click',()=>{this.detailTab=id;this.renderDetail()}); tabs.append(b);
      });
      panel.append(head,tabs);
      if (this.detailTab === 'general') this.renderGeneral(panel, appData);
      else if (this.detailTab === 'installations') await this.renderInstallations(panel, appData);
      else if (this.detailTab === 'commands') await this.renderCommands(panel, appData);
      else if (this.detailTab === 'interactions') this.renderInteractions(panel, appData);
      else if (this.detailTab === 'ai') this.renderAi(panel, appData);
      else if (this.detailTab === 'activity') await this.renderActivity(panel, appData);
    }
    renderGeneral(panel, appData) {
      const form=this.el('div','developer-form');
      const name=this.field('Name',appData.name,{maxLength:48}); const desc=this.field('Description',appData.description,{multiline:true,maxLength:500,placeholder:'What does this app do?'}); const avatar=this.field('Avatar URL',appData.avatar_source||'',{maxLength:2048,placeholder:'https://… or /api/files/…'});
      const publicLabel=this.el('label','developer-check'); const publicInput=document.createElement('input');publicInput.type='checkbox';publicInput.checked=appData.public===true;publicLabel.append(publicInput,this.el('span','', 'Public application · other server managers can install it by App ID'));
      const publicId=this.el('div','developer-copy-row'); const code=this.el('code','',appData.public_id); publicId.append(this.el('span','','Application ID'),code,this.button('Copy',async()=>{try{await navigator.clipboard.writeText(appData.public_id)}catch(_){}} ,'btn ghost'));
      const perms=this.el('fieldset','developer-permissions'); perms.append(this.el('legend','','Default requested permissions'));
      for(const permission of this.permissions){const bit=Number(permission.bit||permission.mask||0);if(!bit)continue;const label=this.el('label','developer-check');const input=document.createElement('input');input.type='checkbox';input.checked=(Number(appData.default_permissions||0)&bit)!==0;input.dataset.permissionBit=String(bit);const copy=this.el('span');copy.append(this.el('b','',permission.label||permission.name),this.el('small','',permission.description||''));label.append(input,copy);perms.append(label)}
      const actions=this.el('div','developer-actions');const save=this.button('Save changes',async()=>{save.disabled=true;try{let mask=0;perms.querySelectorAll('[data-permission-bit]:checked').forEach(i=>{mask|=Number(i.dataset.permissionBit)});await directApi(`/developer/apps/${appData.id}`,{method:'POST',body:{name:name.input.value.trim(),description:desc.input.value,avatar_url:avatar.input.value.trim(),public:publicInput.checked,default_permissions:mask}});await this.refresh(appData.id);send(app.ports.bridgeReceive,{tag:'toast',data:'Application saved'});}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});save.disabled=false;}});const remove=this.button('Delete application',async()=>{if(!confirm(`Delete ${appData.name}? All installations and tokens will be revoked. Historical bot messages stay.`))return;remove.disabled=true;try{await directApi(`/developer/apps/${appData.id}/delete`,{method:'POST',body:{}});await this.refresh(0);}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});remove.disabled=false;}},'btn danger');actions.append(save,remove);form.append(publicId,name.wrap,desc.wrap,avatar.wrap,publicLabel,perms,actions);panel.append(form);
    }
    async renderInstallations(panel, appData) {
      const wrap=this.el('div','developer-form');const intro=this.el('div','developer-section-copy');intro.append(this.el('h3','','Server installations'),this.el('p','','Each server installation has its own bot identity and revocable token, limiting the blast radius of a leaked credential.'));wrap.append(intro);
      const installRow=this.el('div','developer-inline');const select=document.createElement('select');const empty=document.createElement('option');empty.value='';empty.textContent='Choose a server';select.append(empty);for(const server of this.servers){const o=document.createElement('option');o.value=String(server.id);o.textContent=server.name||`Server ${server.id}`;select.append(o)}const install=this.button('Install',async()=>{const sid=Number(select.value);if(!sid)return;install.disabled=true;try{const data=await directApi(`/developer/apps/${appData.id}/install`,{method:'POST',body:{server_id:sid}});await this.showSecret('Installation token',data.token,'This token controls only this server installation. Save it now.');await this.renderDetail();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});install.disabled=false;}});installRow.append(select,install);wrap.append(installRow);
      let items=[];try{items=await directApi(`/developer/apps/${appData.id}/installations`)}catch(error){wrap.append(this.el('p','developer-error',error.message));panel.append(wrap);return}
      const list=this.el('div','developer-stack');for(const item of (Array.isArray(items)?items:[])){const row=this.el('section','developer-install-card');const copy=this.el('div');copy.append(this.el('b','',item.server_name||`Server ${item.server_id}`),this.el('small','',`@${item.username} · installation ${item.id}`));const actions=this.el('div','developer-actions');actions.append(this.button('Rotate token',async e=>{e.currentTarget.disabled=true;try{const data=await directApi(`/developer/apps/${appData.id}/installation/${item.id}/rotate`,{method:'POST',body:{}});await this.showSecret('New installation token',data.token,'The previous token stopped working immediately.');}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{e.currentTarget.disabled=false;}} ,'btn secondary'),this.button('Uninstall',async e=>{if(!confirm(`Uninstall ${appData.name} from ${item.server_name}?`))return;e.currentTarget.disabled=true;try{await directApi(`/developer/apps/${appData.id}/installation/${item.id}/uninstall`,{method:'POST',body:{}});await this.renderDetail();}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});e.currentTarget.disabled=false;}},'btn danger'));row.append(copy,actions);list.append(row)}if(!list.children.length)list.append(this.el('div','developer-empty compact','Not installed on any servers yet.'));wrap.append(list);panel.append(wrap);
    }
    async renderCommands(panel, appData) {
      const wrap = this.el('div', 'developer-form');
      const intro = this.el('div', 'developer-section-copy');
      intro.append(
        this.el('h3', '', 'Application commands'),
        this.el('p', '', 'Create Discord-style slash commands visually. They sync to every installation; advanced bots can claim them with any Plainwire SDK.')
      );
      wrap.append(intro);

      const templates = this.el('div', 'developer-template-row');
      templates.append(this.el('span', 'developer-template-label', 'Start with'));
      const templateData = [
        ['Ping', {name:'ping', description:'Check whether the bot is online', handler:'queue', options:[]}],
        ['Echo', {name:'echo', description:'Repeat supplied text', handler:'queue', options:[{name:'text',type:'string',required:true,description:'Text to repeat'}]}],
        ['AI chat', {name:'chat', description:'Ask the AI assistant', handler:'ai', options:[{name:'prompt',type:'string',required:true,description:'What you want to ask'}]}]
      ];

      const form = this.el('form', 'developer-command-form developer-command-builder');
      const name = this.field('Command name', '', {placeholder:'summarize', maxLength:32});
      const desc = this.field('Description', '', {placeholder:'What this command does', maxLength:160});
      const handlerLabel = this.el('label', 'developer-field');
      handlerLabel.append(this.el('span', '', 'How it runs'));
      const handler = document.createElement('select');
      [['queue','Your code · Bot SDK'],['webhook','Your HTTPS endpoint'],['ai','No-code AI assistant']].forEach(([value,label]) => {
        const option = document.createElement('option'); option.value = value; option.textContent = label; handler.append(option);
      });
      handlerLabel.append(handler);
      const optionsSection = this.el('section', 'developer-option-builder');
      const optionsHead = this.el('div', 'developer-option-head');
      optionsHead.append(
        this.el('div', '', ''),
        this.button('Add option', () => addOption(), 'btn secondary')
      );
      optionsHead.firstChild.append(
        this.el('b', '', 'Command options'),
        this.el('small', '', 'Add typed fields instead of writing JSON.')
      );
      const optionsList = this.el('div', 'developer-option-list');
      optionsSection.append(optionsHead, optionsList);
      const formActions = this.el('div', 'developer-actions developer-command-actions');
      const submit = this.el('button', 'btn', 'Save command'); submit.type = 'submit';
      const clear = this.button('Clear', () => resetForm(), 'btn ghost');
      formActions.append(submit, clear);
      form.append(name.wrap, desc.wrap, handlerLabel, optionsSection, formActions);

      const addOption = (value = {}) => {
        if (optionsList.children.length >= 25) return;
        const row = this.el('div', 'developer-option-row');
        const optionName = document.createElement('input'); optionName.placeholder = 'name'; optionName.maxLength = 32; optionName.value = value.name || '';
        const optionType = document.createElement('select');
        [['string','Text'],['integer','Whole number'],['number','Number'],['boolean','Yes / no'],['user','Member'],['channel','Channel']].forEach(([kind,label]) => {
          const choice = document.createElement('option'); choice.value = kind; choice.textContent = label; choice.selected = (value.type || 'string') === kind; optionType.append(choice);
        });
        const optionDescription = document.createElement('input'); optionDescription.placeholder = 'What should the user enter?'; optionDescription.maxLength = 120; optionDescription.value = value.description || '';
        const requiredLabel = this.el('label', 'developer-option-required'); const required = document.createElement('input'); required.type = 'checkbox'; required.checked = value.required === true; requiredLabel.append(required, this.el('span', '', 'Required'));
        const remove = this.button('Remove', () => row.remove(), 'btn ghost');
        row.append(optionName, optionType, optionDescription, requiredLabel, remove); optionsList.append(row);
      };
      const readOptions = () => Array.from(optionsList.children).map(row => {
        const [optionName, optionType, optionDescription] = row.querySelectorAll('input:not([type="checkbox"]), select');
        return {name: optionName.value.trim(), type: optionType.value, required: row.querySelector('input[type="checkbox"]').checked, description: optionDescription.value.trim()};
      }).filter(option => option.name);
      const resetForm = (definition = {}) => {
        name.input.value = definition.name || '';
        desc.input.value = definition.description || '';
        handler.value = definition.handler || 'queue';
        optionsList.replaceChildren();
        (Array.isArray(definition.options) ? definition.options : []).forEach(addOption);
        submit.textContent = definition.id ? `Update /${definition.name}` : 'Save command';
        name.input.readOnly = Boolean(definition.id);
      };
      for (const [label, definition] of templateData) templates.append(this.button(label, () => { resetForm(definition); name.input.focus(); }, 'btn ghost'));
      wrap.append(templates, form);

      form.addEventListener('submit', async event => {
        event.preventDefault(); submit.disabled = true;
        try {
          const commandName = name.input.value.trim().toLowerCase();
          if (!/^[a-z][a-z0-9_-]{0,31}$/.test(commandName)) throw new Error('Command names start with a letter and use lowercase letters, numbers, _ or -.');
          const options = readOptions();
          if (options.some(option => !/^[a-z][a-z0-9_-]{0,31}$/.test(option.name))) throw new Error('Every option needs a valid lowercase name.');
          await directApi(`/developer/apps/${appData.id}/commands`, {method:'POST', body:{name:commandName, description:desc.input.value.trim(), handler:handler.value, options}});
          resetForm(); await this.renderDetail();
          send(app.ports.bridgeReceive, {tag:'toast', data:`/${commandName} saved`});
        } catch (error) {
          send(app.ports.bridgeReceive, {tag:'toast', data:error.message}); submit.disabled = false;
        }
      });

      let commands = [];
      try { commands = await directApi(`/developer/apps/${appData.id}/commands`); }
      catch (error) { wrap.append(this.el('p', 'developer-error', error.message)); panel.append(wrap); return; }
      const list = this.el('div', 'developer-stack');
      for (const command of (Array.isArray(commands) ? commands : [])) {
        const row = this.el('section', 'developer-command-card');
        const copy = this.el('div');
        const title = this.el('div', 'developer-command-title');
        title.append(this.el('b', '', `/${command.name}`), this.el('span', `developer-handler-badge ${command.handler}`, ({queue:'SDK',webhook:'HTTP',ai:'AI'})[command.handler] || command.handler));
        copy.append(title, this.el('small', '', command.description || 'No description'));
        const chips = this.el('div', 'developer-option-chips');
        for (const option of (Array.isArray(command.options) ? command.options : [])) chips.append(this.el('span', '', `${option.name}: ${option.type}${option.required ? ' · required' : ''}`));
        if (chips.children.length) copy.append(chips);
        const actions = this.el('div', 'developer-actions');
        actions.append(
          this.button('Edit', () => { resetForm(command); form.scrollIntoView({behavior:'smooth', block:'start'}); }, 'btn secondary'),
          this.button('Delete', async event => {
            if (!confirm(`Delete /${command.name}?`)) return;
            event.currentTarget.disabled = true;
            try { await directApi(`/developer/apps/${appData.id}/commands/${command.id}`, {method:'DELETE'}); await this.renderDetail(); }
            catch (error) { send(app.ports.bridgeReceive, {tag:'toast', data:error.message}); event.currentTarget.disabled = false; }
          }, 'btn danger')
        );
        row.append(copy, actions); list.append(row);
      }
      if (!list.children.length) list.append(this.el('div', 'developer-empty compact', 'No commands yet. Pick a starter above or build your own.'));
      wrap.append(list); panel.append(wrap);
    }
    renderInteractions(panel, appData) {
      const wrap=this.el('div','developer-form');const intro=this.el('div','developer-section-copy');intro.append(this.el('h3','','Signed interaction endpoint'),this.el('p','','Run a bot without a persistent WebSocket worker. Plainwire POSTs command invocations to your HTTPS endpoint and verifies the destination before connecting.'));wrap.append(intro);const url=this.field('Interaction endpoint',appData.interaction?.url||'',{placeholder:'https://bot.example.com/plainwire/interactions',maxLength:2048});const status=this.el('p','developer-status',appData.interaction?.configured?'Configured · command webhooks are active':'Not configured');const actions=this.el('div','developer-actions');const save=this.button('Save endpoint',async()=>{save.disabled=true;try{const data=await directApi(`/developer/apps/${appData.id}/interactions`,{method:'POST',body:{url:url.input.value.trim()}});if(data.secret)await this.showSecret('Interaction signing secret',data.secret,'Use this secret to verify X-Plainwire-Interaction-Signature. It is shown once.');await this.refresh(appData.id);}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});save.disabled=false;}});const rotate=this.button('Rotate signing secret',async()=>{rotate.disabled=true;try{const data=await directApi(`/developer/apps/${appData.id}/interactions/rotate`,{method:'POST',body:{}});await this.showSecret('New interaction signing secret',data.secret,'Update your endpoint before sending more commands. The old secret is invalid.');}catch(error){send(app.ports.bridgeReceive,{tag:'toast',data:error.message});}finally{rotate.disabled=false;}},'btn secondary');rotate.disabled=!appData.interaction?.configured;actions.append(save,rotate);wrap.append(url.wrap,status,actions);panel.append(wrap);
    }
    renderAi(panel, appData) {
      const ai = appData.ai || {};
      const wrap = this.el('div', 'developer-form developer-ai-form');
      const intro = this.el('div', 'developer-section-copy');
      intro.append(
        this.el('h3', '', 'No-code AI assistant'),
        this.el('p', '', 'Choose a provider, paste a key, and Plainwire can run AI slash commands or answer mentions and replies as this bot. No worker, JSON, or custom code is required.')
      );
      wrap.append(intro);

      const presets = {
        openai: {label:'OpenAI · Chat Completions', endpoint:'https://api.openai.com/v1/chat/completions', model:'gpt-5-mini', help:'Works with OpenAI chat-completions models.'},
        openai_responses: {label:'OpenAI · Responses API', endpoint:'https://api.openai.com/v1/responses', model:'gpt-5-mini', help:'Uses OpenAI’s newer Responses endpoint.'},
        anthropic: {label:'Anthropic', endpoint:'https://api.anthropic.com/v1/messages', model:'claude-sonnet-4-5', help:'Uses the native Anthropic Messages API.'},
        google: {label:'Google Gemini', endpoint:'https://generativelanguage.googleapis.com/v1beta/models', model:'gemini-2.5-flash', help:'Plainwire appends the selected model and generateContent path.'},
        openrouter: {label:'OpenRouter', endpoint:'https://openrouter.ai/api/v1/chat/completions', model:'openai/gpt-5-mini', help:'Access multiple providers through one OpenAI-compatible endpoint.'},
        groq: {label:'Groq', endpoint:'https://api.groq.com/openai/v1/chat/completions', model:'llama-3.3-70b-versatile', help:'Fast OpenAI-compatible inference.'},
        mistral: {label:'Mistral', endpoint:'https://api.mistral.ai/v1/chat/completions', model:'mistral-small-latest', help:'Uses Mistral’s OpenAI-compatible endpoint.'},
        ollama: {label:'Ollama · local', endpoint:'http://127.0.0.1:11434/v1/chat/completions', model:'llama3.2', help:'No API key. Enable PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP on the host first; remote HTTP stays blocked.'},
        openai_compatible: {label:'Custom OpenAI-compatible', endpoint:'', model:'', help:'Use any HTTPS endpoint that accepts chat-completions requests.'}
      };
      const providerWrap = this.el('label', 'developer-field'); providerWrap.append(this.el('span', '', 'AI provider'));
      const provider = document.createElement('select');
      for (const [value, preset] of Object.entries(presets)) { const option=document.createElement('option'); option.value=value; option.textContent=preset.label; provider.append(option); }
      provider.value = presets[ai.provider] ? ai.provider : 'openai_compatible'; providerWrap.append(provider);
      const providerHelp = this.el('small', 'developer-provider-help', presets[provider.value].help); providerWrap.append(providerHelp);
      const endpoint = this.field('API endpoint', ai.endpoint || presets[provider.value].endpoint, {placeholder:'https://provider.example/v1/chat/completions', maxLength:2048});
      const model = this.field('Model', ai.model || presets[provider.value].model, {placeholder:'provider model name', maxLength:160});
      const key = this.field(ai.has_api_key ? 'API key · leave blank to keep current' : 'API key', '', {type:'password', placeholder:'Encrypted at rest and never shown again', maxLength:1024});
      provider.addEventListener('change', () => {
        const previousDefaults = Object.values(presets);
        const preset = presets[provider.value];
        if (!endpoint.input.value || previousDefaults.some(item => item.endpoint === endpoint.input.value)) endpoint.input.value = preset.endpoint;
        if (!model.input.value || previousDefaults.some(item => item.model === model.input.value)) model.input.value = preset.model;
        providerHelp.textContent = preset.help;
        key.wrap.hidden = provider.value === 'ollama';
      });
      key.wrap.hidden = provider.value === 'ollama';

      const behavior = this.el('section', 'developer-ai-behavior');
      behavior.append(this.el('h4', '', 'Behavior'));
      const enabledLabel = this.el('label', 'developer-check'); const enabled = document.createElement('input'); enabled.type='checkbox'; enabled.checked=ai.enabled===true;
      const enabledCopy = this.el('span'); enabledCopy.append(this.el('b','','Enable AI commands'), this.el('small','','Commands using the AI handler can run without your own bot process.')); enabledLabel.append(enabled, enabledCopy);
      const chatLabel = this.el('label', 'developer-check'); const chat = document.createElement('input'); chat.type='checkbox'; chat.checked=ai.chat_enabled===true;
      const chatCopy = this.el('span'); chatCopy.append(this.el('b','','Answer mentions and replies'), this.el('small','','Creates /chat automatically and replies in the channel. Bot messages never trigger another AI bot.')); chatLabel.append(chat, chatCopy);
      const triggerWrap = this.el('label', 'developer-field'); triggerWrap.append(this.el('span', '', 'When to answer'));
      const trigger = document.createElement('select');
      [['mention_or_reply','Mentions and replies to the bot'],['mention','Mentions only']].forEach(([value,label]) => {
        const option=document.createElement('option'); option.value=value; option.textContent=label; option.selected=(ai.chat_trigger||'mention_or_reply')===value; trigger.append(option);
      });
      triggerWrap.append(trigger, this.el('small','developer-provider-help','Replies still require the original message to be from this bot. Random channel chatter is ignored.'));
      const syncChatUi = () => { triggerWrap.hidden = !chat.checked; if (chat.checked) enabled.checked = true; };
      chat.addEventListener('change', syncChatUi); syncChatUi();
      const historyLabel = this.el('label', 'developer-check'); const history = document.createElement('input'); history.type='checkbox'; history.checked=ai.include_history===true;
      const historyCopy = this.el('span'); historyCopy.append(this.el('b','','Include recent channel context'), this.el('small','','Opt in to sending a bounded window of messages the bot is already allowed to read.')); historyLabel.append(history, historyCopy);
      behavior.append(enabledLabel, chatLabel, triggerWrap, historyLabel);

      const tuning = this.el('div', 'developer-ai-tuning');
      const historyCount = this.field('Context messages', ai.history_messages ?? 8, {type:'number'}); historyCount.input.min='0'; historyCount.input.max='20';
      const temperature = this.field('Creativity', ai.temperature ?? 0.7, {type:'number'}); temperature.input.min='0'; temperature.input.max='2'; temperature.input.step='0.1';
      const maxTokens = this.field('Maximum output tokens', ai.max_output_tokens ?? 1000, {type:'number'}); maxTokens.input.min='64'; maxTokens.input.max='8192';
      tuning.append(historyCount.wrap, temperature.wrap, maxTokens.wrap);

      const prompt = this.field('Assistant instructions', ai.system_prompt || '', {multiline:true, maxLength:8000, placeholder:'You are a helpful assistant for this Plainwire server. Be concise and say when you are unsure.'});
      const promptTemplates = this.el('div', 'developer-template-row'); promptTemplates.append(this.el('span','developer-template-label','Instruction starter'));
      const promptChoices = [
        ['Helpful', 'You are a helpful Plainwire community assistant. Be concise, friendly, and honest when you are unsure.'],
        ['Support', 'You are a support assistant. Ask one clarifying question when needed, give numbered troubleshooting steps, and never invent account or system status.'],
        ['Coding', 'You are a practical coding assistant. Prefer secure, maintainable examples and explain important tradeoffs briefly.']
      ];
      for (const [label, value] of promptChoices) promptTemplates.append(this.button(label, () => { prompt.input.value=value; prompt.input.focus(); }, 'btn ghost'));

      const privacy = this.el('div', 'developer-ai-privacy');
      privacy.append(
        this.el('b', '', 'What leaves your server'),
        this.el('p', '', 'The command or triggering message, your instructions, and—only when enabled—the bounded recent context. API keys and instructions are encrypted in PostgreSQL. Private-network destinations stay blocked except explicitly enabled loopback development.')
      );
      const status = this.el('p', `developer-status ${ai.configured ? 'good' : ''}`, ai.configured ? `${presets[provider.value].label} is configured` : 'Add provider details and save to enable the assistant.');
      const save = this.button('Save AI assistant', async () => {
        save.disabled = true;
        try {
          await directApi(`/developer/apps/${appData.id}/ai`, {method:'POST', body:{
            enabled:enabled.checked, provider:provider.value, endpoint:endpoint.input.value.trim(), model:model.input.value.trim(), api_key:key.input.value,
            system_prompt:prompt.input.value, temperature:Number(temperature.input.value), max_output_tokens:Number(maxTokens.input.value),
            include_history:history.checked, history_messages:Number(historyCount.input.value), chat_enabled:chat.checked, chat_trigger:trigger.value
          }});
          key.input.value=''; await this.refresh(appData.id); this.detailTab='ai'; await this.renderDetail();
          send(app.ports.bridgeReceive,{tag:'toast',data:chat.checked?'AI assistant saved · mention the bot or use /chat':'AI assistant saved'});
        } catch (error) {
          const message = error.message === 'ai_chat_command_conflict' ? 'The app already has a non-AI /chat command. Rename or remove it first.' : error.message;
          send(app.ports.bridgeReceive,{tag:'toast',data:message}); save.disabled=false;
        }
      });
      wrap.append(providerWrap, endpoint.wrap, model.wrap, key.wrap, behavior, tuning, promptTemplates, prompt.wrap, privacy, status, save); panel.append(wrap);
    }
    async renderActivity(panel, appData) {
      const wrap = this.el('div', 'developer-form');
      const intro = this.el('div', 'developer-section-copy developer-activity-head');
      const copy = this.el('div'); copy.append(this.el('h3','','Command activity'), this.el('p','','Recent command and AI deliveries across every installation. Arguments and secrets are never shown here.'));
      const refresh = this.button('Refresh', () => this.renderDetail(), 'btn secondary'); intro.append(copy, refresh); wrap.append(intro);
      let activity = [];
      try { activity = await directApi(`/developer/apps/${appData.id}/activity?limit=50`); }
      catch (error) { wrap.append(this.el('p','developer-error',error.message)); panel.append(wrap); return; }
      const summary = this.el('div', 'developer-activity-summary');
      const counts = {pending:0, claimed:0, completed:0, failed:0};
      for (const item of (Array.isArray(activity) ? activity : [])) if (item.status in counts) counts[item.status] += 1;
      for (const [status,count] of Object.entries(counts)) { const card=this.el('div',''); card.append(this.el('b','',String(count)),this.el('span','',status)); summary.append(card); }
      wrap.append(summary);
      const list = this.el('div', 'developer-stack');
      for (const item of (Array.isArray(activity) ? activity : [])) {
        const row = this.el('section', 'developer-activity-row');
        const state = this.el('span', `developer-activity-state ${item.status}`, item.status || 'unknown');
        const body = this.el('div'); body.append(this.el('b','',`/${item.command}`), this.el('small','',`${item.server_name || `Server ${item.server_id}`} · channel ${item.channel_id} · ${new Date(Number(item.created_at || 0)).toLocaleString()}`));
        if (item.fail_reason) body.append(this.el('p','developer-activity-error',item.fail_reason));
        const attempts = this.el('span','developer-activity-attempts',`${item.attempts || 0} attempt${Number(item.attempts) === 1 ? '' : 's'}`);
        row.append(state, body, attempts); list.append(row);
      }
      if (!list.children.length) list.append(this.el('div','developer-empty compact','No command activity yet. Install the application and invoke a command to see delivery status here.'));
      wrap.append(list); panel.append(wrap);
    }
    async showSecret(title, secret, note) {
      const modal=modalShell(title,note);const field=document.createElement('textarea');field.className='admin-secret-value';field.readOnly=true;field.rows=4;field.value=String(secret||'');const actions=this.el('div','developer-actions');const copy=this.button('Copy',async()=>{try{await navigator.clipboard.writeText(field.value);copy.textContent='Copied';}catch(_){field.focus();field.select();}});const close=this.button('I saved it',()=>modal.destroy(),'btn secondary');actions.append(copy,close);modal.body.append(field,actions);field.focus();field.select();
    }
  }
  if (!customElements.get('pw-developer-portal')) customElements.define('pw-developer-portal', PlainwireDeveloperPortal);

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
          const marker = list.querySelector('.unread-marker');
          if (data === true && !marker) pendingForcedMessageRoute = location.hash;
          else pendingForcedMessageRoute = null;
          if (data === true && marker && revealUnreadMarker(list)) {
            observeMessageHistory();
            break;
          }
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
      case 'jump_to_message': {
        const id = Number(data);
        if (!Number.isSafeInteger(id) || id <= 0) break;
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const list = document.getElementById('messages');
          if (!list) return;
          const wanted = String(id);
          const target = [...list.querySelectorAll('.msg[data-mid]')].find((node) => node.dataset.mid === wanted);
          if (!target) {
            send(app.ports.bridgeReceive, { tag: 'message_jump_missing', data: id });
            return;
          }
          const reduceMotion = document.documentElement.dataset.reduceMotion === 'true'
            || window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches;
          target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: reduceMotion ? 'auto' : 'smooth' });
          target.classList.remove('message-jump-highlight');
          // Restart the highlight if the same reply is clicked twice.
          void target.offsetWidth;
          target.classList.add('message-jump-highlight');
          window.setTimeout(() => target.classList.remove('message-jump-highlight'), 2200);
        }));
        break;
      }
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
      case 'open_gif_picker':
        openGifPicker();
        break;
      case 'account_change_username':
      case 'change_username':
        openUsernameDialog(String(data || ''));
        break;
      case 'replay_onboarding':
        mutateOnboarding('replay').then(() => openOnboardingChat()).catch((error) => {
          send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not start the tour: ${error.message}` });
        });
        break;
      case 'open_server_admin':
        openServerAdmin(Number(data)).catch(error => send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not open server settings: ${error.message}` }));
        break;
      case 'server_profile_edit_roles':
        openServerProfileRoleEditor(data).catch(error => send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not edit member roles: ${error.message}` }));
        break;
      case 'server_profile_ban': {
        const serverId = Number(data?.server_id); const userId = Number(data?.user_id); const name = String(data?.display_name || 'this member');
        if (!Number.isInteger(serverId) || !Number.isInteger(userId) || !window.confirm(`Ban ${name} from this server? They will be unable to rejoin with a Wire until unbanned.`)) break;
        const reason = (window.prompt('Ban reason (optional):', '') || '').trim().slice(0, 512);
        directApi(`/server/${serverId}/member/${userId}/ban`, { method: 'POST', body: { reason } }).then(async () => {
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Member banned' });
          await api({ method: 'GET', path: '/sync?since=0' });
          location.hash = `#server/${serverId}`;
        }).catch(error => send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not ban member: ${error.message}` }));
        break;
      }
      case 'open_group_admin':
        openGroupAdmin(Number(data)).catch(error => send(app.ports.bridgeReceive, { tag: 'toast', data: `Could not open group moderation: ${error.message}` }));
        break;
      case 'edit_thread':
        openThreadEditor(data).catch(error => send(app.ports.bridgeReceive,{tag:'toast',data:`Could not edit thread: ${error.message}`}));
        break;
      case 'moderate_thread':
        moderateThread(data);
        break;
      case 'edit_thread_reply':
        openReplyEditor(data).catch(error => send(app.ports.bridgeReceive,{tag:'toast',data:`Could not edit reply: ${error.message}`}));
        break;
      case 'delete_thread_reply':
        deleteThreadReply(data);
        break;
      case 'insert_composer_text':
        if (!insertIntoComposer(String(data || ''))) {
          send(app.ports.bridgeReceive, { tag: 'toast', data: 'Open a DM or text channel before inserting emoji.' });
        }
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
            rtcAction('start', 'call', res.id, epoch);
            ensureMedia()
              .then(() => {
            if (!room || room.epoch !== epoch) return;
            startRingtone('outgoing');
            callAwaitingFirstGuest = true;
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
        rtcAction('start', 'call', data, epoch);
        ensureMedia()
          .then(() => {
          if (!room || room.epoch !== epoch) return;
          startRingtone('outgoing');
          callAwaitingFirstGuest = true;
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
        rtcAction('join', 'voice', data, epoch);
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
        rtcAction('accept', 'call', data, epoch);
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
      case 'join_call':
        {
        const epoch = switchRtcRoom('call', data);
        rtcAction('join', 'call', data, epoch);
        ensureMedia()
          .then(() => {
            if (!room || room.epoch !== epoch) return;
            sendWs({ type: 'call_join', conversation_id: data });
          })
          .catch(() => {
            if (room?.epoch === epoch) leaveRtcRoom();
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
        if (window.confirm('Delete this forum and every thread and reply inside it? This cannot be undone.')) {
          api({ method: 'POST', path: '/forum/' + data + '/delete', body: {} }).then((res) => {
            if (res && res.deleted) location.hash = '#forums';
          });
        }
        break;
      case 'delete_thread':
        if (data?.id && window.confirm('Delete this thread and all of its replies? This cannot be undone.')) {
          api({ method: 'POST', path: '/thread/' + data.id + '/delete', body: {} }).then((res) => {
            if (res && res.deleted) location.hash = '#f/' + (res.forum_id || data.forum_id);
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
      case 'account_change_email':
        openEmailDialog(String(data || ''));
        break;
      case 'account_disable':
        openAccountLifecycleDialog('disable');
        break;
      case 'account_delete':
        openAccountLifecycleDialog('delete');
        break;
      case 'record_voice_note':
        openVoiceNoteRecorder();
        break;
      case 'account_sessions':
        openSessionsDialog();
        break;
      case 'account_diagnostics':
        openDiagnosticsDialog();
        break;
      case 'open_extensions':
        openExtensionsManager();
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
  window.addEventListener('online', () => {
    debug('NETWORK', 'browser_online');
    Array.from(syncRecovery.keys()).forEach(kickSyncRecovery);
    connectWs();
    if (meId) api({ method: 'GET', path: '/sync?since=0' });
    if (room?.joined) {
      playAllRemoteAudio();
      auditRtcPeers('browser_online');
    }
  });
  window.addEventListener('offline', () => debug('NETWORK', 'browser_offline', {}, 'warn'));
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    if (!ws || ws.readyState === WebSocket.CLOSED) connectWs();
    if (room?.joined) {
      audioContext()?.resume?.();
      playAllRemoteAudio();
      auditRtcPeers('foreground');
    }
  }, { passive: true });
  window.addEventListener('unhandledrejection', (event) => debug('ERROR', 'unhandled_promise_rejection', { error: event.reason?.message || String(event.reason) }, 'error'));
  window.addEventListener('error', (event) => {
    if (event.target !== window) return;
    debug('ERROR', 'uncaught_exception', { error: event.message, file: event.filename, line: event.lineno, column: event.colno }, 'error');
  });
  document.addEventListener('error', (event) => {
    const target = event.target;
    if (!(target instanceof HTMLImageElement)) return;

    const fallback = String(target.dataset.avatarFallback || '').trim();
    if (fallback && target.dataset.fallbackApplied !== '1') {
      const initial = fallback.slice(0, 1).toUpperCase();
      const palette = ['#5865f2', '#3b82f6', '#16877a', '#37854f', '#9a6716', '#b64d6b', '#7c5bb5', '#a75432'];
      const color = palette[(initial.codePointAt(0) || 0) % palette.length];
      const safeInitial = initial.replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[ch]);
      const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96"><rect width="96" height="96" rx="22" fill="${color}"/><text x="48" y="55" text-anchor="middle" dominant-baseline="middle" font-family="system-ui,sans-serif" font-size="38" font-weight="700" fill="white">${safeInitial}</text></svg>`;
      target.dataset.fallbackApplied = '1';
      target.removeAttribute('srcset');
      target.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
      target.classList.add('image-failed');
      target.alt = `${fallback} avatar`;
      return;
    }

    target.removeAttribute('src');
    target.removeAttribute('srcset');
    target.alt = '';
    target.classList.add('image-failed');
  }, true);

  navigator.mediaDevices?.addEventListener?.('devicechange', publishAudioDevices);
  loadVoiceProcessingConfig().then(publishAudioDevices);
  window.addEventListener('pagehide', cleanupRtcMedia);
  window.addEventListener('beforeunload', cleanupRtcMedia);
  window.addEventListener('storage', (event) => {
    if (event.key !== RTC_OWNER_KEY) return;
    const owner = readRtcOwner();
    if (room?.joined && owner && owner.tab !== rtcTabId
        && owner.kind === room.kind && owner.id === room.id) {
      // The replacement tab publishes ownership only after the server accepted
      // its seat. Stop local capture immediately instead of waiting for the
      // superseded event to travel back over this socket.
      debug('RTC', 'room_superseded_storage', { room, owner });
      leaveRtcRoom({ preserveResume: true });
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'This call moved to another Plainwire tab.' });
      return;
    }
    if (!room && resumeIntent && !owner) {
      // Do not auto-open the microphone in a background duplicate tab. Make the
      // handoff visible and let the user explicitly rejoin/take over instead.
      resumeAttempted = false;
      send(app.ports.bridgeReceive, { tag: 'toast', data: 'The other Plainwire call tab closed. You can rejoin from this tab.' });
    }
  });
  window.addEventListener('pageshow', () => {
    resumeIntent = readRtcIntent();
    resumeAttempted = false;
    if (!ws || ws.readyState === WebSocket.CLOSED) connectWs();
    if (meId) api({ method: 'GET', path: '/sync?since=0' });
    if (resumeIntent && !room && meId) {
      if (ws?.readyState === WebSocket.OPEN) maybeResumeRtcRoom();
      else connectWs();
    }
    if (room?.joined) {
      audioContext()?.resume?.();
      playAllRemoteAudio();
      auditRtcPeers('pageshow');
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
