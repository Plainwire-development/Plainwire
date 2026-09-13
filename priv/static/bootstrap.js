(() => {
  'use strict';

  const fallback = {
    app_name: 'Plainwire',
    default_theme: 'system',
    registration_enabled: true,
    instance_description: 'A fast, self-hosted place to talk.',
    upload_max_bytes: 250 * 1024 * 1024,
    profile_image_max_bytes: 16 * 1024 * 1024,
    upload_max_files: 10,
    idle_timeout_ms: 10 * 60 * 1000,
    compress_oversize_uploads: true,
    max_image_dimension: 4096,
    version: '1.7.1',
    asset_version: '1.7.1'
  };

  const normalize = (raw) => {
    const config = { ...fallback, ...(raw && typeof raw === 'object' ? raw : {}) };
    if (!['light', 'dark', 'system'].includes(config.default_theme)) config.default_theme = fallback.default_theme;
    if (typeof config.app_name !== 'string' || !config.app_name.trim()) config.app_name = fallback.app_name;
    config.app_name = config.app_name.trim().slice(0, 48);
    return config;
  };

  const applyEarlyUi = (config) => {
    window.PLAINWIRE_CLIENT_CONFIG = config;
    document.title = config.app_name;
    const root = document.documentElement;
    if (config.default_theme === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', config.default_theme);
    const themeMeta = document.querySelector('meta[name="theme-color"]');
    if (themeMeta) {
      const dark = config.default_theme === 'dark' || (config.default_theme === 'system' && window.matchMedia?.('(prefers-color-scheme: dark)').matches);
      themeMeta.setAttribute('content', dark ? '#121418' : '#eef0f3');
    }
    const boot = document.querySelector('#app .boot');
    if (boot) boot.textContent = `Loading ${config.app_name}...`;
  };

  const assetUrl = (path, config) => {
    const version = encodeURIComponent(String(config.asset_version || config.version || '1.7.1'));
    return `${path}?v=${version}`;
  };

  const loadScript = (src) => new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = src;
    script.defer = false;
    script.onload = resolve;
    script.onerror = () => reject(new Error(`failed to load ${src}`));
    document.body.appendChild(script);
  });

  const loadStyles = (config) => new Promise((resolve) => {
    const link = document.getElementById('plainwireStyles');
    if (!link) return resolve();
    const next = assetUrl('/assets/app.css', config);
    if (link.getAttribute('href') === next) return resolve();
    const done = () => resolve();
    link.addEventListener('load', done, { once: true });
    link.addEventListener('error', done, { once: true });
    link.setAttribute('href', next);
    // A stylesheet error should not strand the whole application forever.
    setTimeout(done, 3000);
  });

  const boot = async () => {
    let config = fallback;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch('/api/client-config', { headers: { accept: 'application/json' }, cache: 'no-store', signal: controller.signal });
      if (response.ok) config = normalize(await response.json());
    } catch (_) {
      config = normalize(fallback);
    } finally { clearTimeout(timeout); }
    applyEarlyUi(config);
    try {
      await loadStyles(config);
      await loadScript(assetUrl('/assets/app.js', config));
      // Optional diagnostics must never prevent the chat client from starting.
      await Promise.all(['/assets/call-health.js', '/assets/markdown.js'].map(path =>
        Promise.race([loadScript(assetUrl(path, config)).catch(() => {}), new Promise(resolve => setTimeout(resolve, 2500))])));
      await loadScript(assetUrl('/assets/elm-bridge.js', config));
    } catch (error) {
      const root = document.getElementById('app');
      if (root) root.textContent = `${config.app_name} could not start. Refresh the page and try again.`;
      console.error('[Plainwire:BOOT] startup_failed', error);
    }
  };

  boot();
})();
