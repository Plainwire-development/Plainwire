(() => {
  'use strict';

  const fallback = {
    app_name: 'Plainwire',
    default_theme: 'light',
    registration_enabled: true,
    instance_description: 'A fast, self-hosted place to talk.',
    upload_max_bytes: 250 * 1024 * 1024,
    profile_image_max_bytes: 16 * 1024 * 1024,
    upload_max_files: 10,
    idle_timeout_ms: 10 * 60 * 1000,
    compress_oversize_uploads: true,
    max_image_dimension: 4096
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
      themeMeta.setAttribute('content', dark ? '#1e1f22' : '#e3e5e8');
    }
    const boot = document.querySelector('#app .boot');
    if (boot) boot.textContent = `Loading ${config.app_name}...`;
  };

  const loadScript = (src) => new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = src;
    script.defer = false;
    script.onload = resolve;
    script.onerror = () => reject(new Error(`failed to load ${src}`));
    document.body.appendChild(script);
  });

  const boot = async () => {
    let config = fallback;
    try {
      const response = await fetch('/api/client-config', { headers: { accept: 'application/json' }, cache: 'no-store' });
      if (response.ok) config = normalize(await response.json());
    } catch (_) {
      config = normalize(fallback);
    }
    applyEarlyUi(config);
    try {
      await loadScript('/assets/app.js');
      await loadScript('/assets/elm-bridge.js');
    } catch (error) {
      const root = document.getElementById('app');
      if (root) root.textContent = `${config.app_name} could not start. Refresh the page and try again.`;
      console.error('[Plainwire:BOOT] startup_failed', error);
    }
  };

  boot();
})();
