// Plainwire Source Hub: refreshed, read-only GitHub development visibility.
// All GitHub API traffic is proxied by the Plainwire backend. The browser only
// receives public metadata and never sees a GitHub token.
const SOURCE_ORG = 'Plainwire-development';
const SOURCE_ROOT = `https://github.com/${SOURCE_ORG}`;
const SOURCE_REFRESH_MS = 60_000;
const SOURCE_TIMEOUT_MS = 15_000;
const SOURCE_MAX_JSON = 180_000;
const SOURCE_MAX_PATCH = 120_000;
const SOURCE_MAX_DIFF_FILES = 100;

const textNode = (tag, cls, text = '') => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  node.textContent = String(text ?? '');
  return node;
};

const button = (label, cls = 'btn secondary', action) => {
  const node = textNode('button', cls, label);
  node.type = 'button';
  if (action) node.addEventListener('click', action);
  return node;
};

const safeExternalUrl = (raw, { githubOnly = false } = {}) => {
  try {
    const url = new URL(String(raw || ''));
    if (url.protocol !== 'https:') return '';
    if (githubOnly && url.hostname.toLowerCase() !== 'github.com') return '';
    return url.href;
  } catch (_) { return ''; }
};

const safeAvatarUrl = raw => {
  try {
    const url = new URL(String(raw || ''));
    if (url.protocol !== 'https:' || url.hostname.toLowerCase() !== 'avatars.githubusercontent.com') return '';
    return url.href;
  } catch (_) { return ''; }
};

const externalLink = (label, href, cls = '', options = {}) => {
  const safe = safeExternalUrl(href, options);
  if (!safe) return textNode('span', cls, label);
  const node = textNode('a', cls, label);
  node.href = safe;
  node.target = '_blank';
  node.rel = 'noopener noreferrer';
  node.referrerPolicy = 'no-referrer';
  return node;
};

const githubLink = (label, href, cls = '') => externalLink(label, href, cls, { githubOnly: true });
const validRepoName = value => {
  const name = String(value || '');
  return /^[A-Za-z0-9._-]{1,100}$/.test(name) && name !== '.' && name !== '..';
};
const validGitHubLogin = value => /^(?!-)(?!.*-$)[A-Za-z0-9-]{1,39}$/.test(String(value || ''));

const formatNumber = value => {
  const n = Number(value || 0);
  if (!Number.isFinite(n)) return '0';
  return new Intl.NumberFormat(undefined, { notation: n >= 10_000 ? 'compact' : 'standard', maximumFractionDigits: 1 }).format(n);
};

const formatBytes = value => {
  let bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let unit = 0;
  while (bytes >= 1024 && unit < units.length - 1) { bytes /= 1024; unit += 1; }
  return `${bytes >= 10 || unit === 0 ? bytes.toFixed(0) : bytes.toFixed(1)} ${units[unit]}`;
};

const formatDate = raw => {
  const date = new Date(raw || 0);
  if (!Number.isFinite(date.getTime())) return 'Unknown date';
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
};

const relativeDate = raw => {
  const time = new Date(raw || 0).getTime();
  if (!Number.isFinite(time)) return 'unknown';
  const seconds = Math.round((time - Date.now()) / 1000);
  const abs = Math.abs(seconds);
  const units = abs < 60 ? ['second', seconds] : abs < 3600 ? ['minute', Math.round(seconds / 60)] : abs < 86400 ? ['hour', Math.round(seconds / 3600)] : abs < 2_592_000 ? ['day', Math.round(seconds / 86400)] : ['month', Math.round(seconds / 2_592_000)];
  try { return new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' }).format(units[1], units[0]); }
  catch (_) { return formatDate(raw); }
};

const firstLine = value => String(value || '').split(/\r?\n/, 1)[0].trim();
const clampText = (value, max = 180) => {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
};
const repoShortName = full => String(full || '').replace(`${SOURCE_ORG}/`, '');

const languageFromPath = path => {
  const name = String(path || '').split('/').pop() || '';
  const lower = name.toLowerCase();
  const exact = {
    makefile: 'Makefile', dockerfile: 'Dockerfile', gemfile: 'Ruby', rakefile: 'Ruby',
    'rebar.config': 'Erlang', 'rebar.lock': 'Erlang', 'elm.json': 'Elm', 'package.json': 'JSON',
    'package-lock.json': 'JSON', 'license': 'Text', 'copying': 'Text'
  };
  if (exact[lower]) return exact[lower];
  const ext = lower.includes('.') ? lower.split('.').pop() : '';
  return ({
    erl: 'Erlang', hrl: 'Erlang', ex: 'Elixir', exs: 'Elixir', elm: 'Elm', js: 'JavaScript', mjs: 'JavaScript', cjs: 'JavaScript',
    ts: 'TypeScript', tsx: 'TypeScript', jsx: 'JavaScript', css: 'CSS', scss: 'SCSS', sass: 'Sass', less: 'Less', html: 'HTML', htm: 'HTML',
    haml: 'Haml', md: 'Markdown', markdown: 'Markdown', json: 'JSON', yml: 'YAML', yaml: 'YAML', toml: 'TOML', xml: 'XML', svg: 'SVG',
    sh: 'Shell', bash: 'Shell', zsh: 'Shell', fish: 'Fish', py: 'Python', rb: 'Ruby', go: 'Go', rs: 'Rust', c: 'C', h: 'C', cc: 'C++',
    cpp: 'C++', cxx: 'C++', hpp: 'C++', f: 'Fortran', f90: 'Fortran', f95: 'Fortran', java: 'Java', kt: 'Kotlin', kts: 'Kotlin',
    sql: 'SQL', pl: 'Perl', pm: 'Perl', txt: 'Text', ini: 'INI', conf: 'Config', service: 'systemd', desktop: 'Desktop Entry'
  })[ext] || (ext ? ext.toUpperCase() : 'Text');
};

const avatar = (user, size = 'md') => {
  const wrap = textNode('span', `source-avatar source-avatar-${size}`);
  const login = String(user?.login || user?.name || '?');
  const src = safeAvatarUrl(user?.avatar_url);
  if (src) {
    const image = document.createElement('img');
    image.src = src;
    image.alt = '';
    image.loading = 'lazy';
    image.decoding = 'async';
    image.referrerPolicy = 'no-referrer';
    image.addEventListener('error', () => { image.remove(); wrap.textContent = login.slice(0, 1).toUpperCase(); }, { once: true });
    wrap.append(image);
  } else wrap.textContent = login.slice(0, 1).toUpperCase();
  return wrap;
};

const stat = (label, value) => {
  const node = textNode('div', 'source-stat');
  node.append(textNode('strong', '', value), textNode('span', '', label));
  return node;
};

const pill = (label, tone = '') => textNode('span', `source-pill${tone ? ` ${tone}` : ''}`, label);

function markdown(source, compact = false) {
  const node = document.createElement('pw-markdown');
  node.setAttribute('source', String(source || ''));
  node.setAttribute('no-embeds', '');
  node.setAttribute('no-mentions', '');
  if (compact) node.setAttribute('compact', '');
  return node;
}

const jsonDetails = (title, value) => {
  const details = textNode('details', 'source-metadata');
  const summary = textNode('summary', '', title);
  const pre = textNode('pre', 'source-json');
  let source = '';
  try { source = JSON.stringify(value, null, 2); } catch (_) { source = String(value); }
  pre.textContent = source.length > SOURCE_MAX_JSON ? `${source.slice(0, SOURCE_MAX_JSON)}\n… metadata truncated in the viewer` : source;
  details.append(summary, pre);
  return details;
};

const emptyState = (title, copy) => {
  const node = textNode('div', 'source-empty');
  node.append(textNode('strong', '', title), textNode('p', 'muted', copy));
  return node;
};

const pushCommitCount = payload => {
  const candidates = [payload?.distinct_size, payload?.size, Array.isArray(payload?.commits) ? payload.commits.length : undefined];
  for (const value of candidates) {
    const count = Number(value);
    if (Number.isInteger(count) && count > 0) return count;
  }
  return null;
};

const eventLabel = event => {
  const payload = event?.payload || {};
  switch (event?.type) {
    case 'PushEvent': {
      const count = pushCommitCount(payload);
      return count ? `pushed ${count} commit${count === 1 ? '' : 's'}` : 'pushed updates';
    }
    case 'CreateEvent': return `created ${payload.ref_type || 'repository item'}${payload.ref ? ` ${payload.ref}` : ''}`;
    case 'DeleteEvent': return `deleted ${payload.ref_type || 'repository item'}${payload.ref ? ` ${payload.ref}` : ''}`;
    case 'ReleaseEvent': return `${payload.action || 'published'} release ${payload.release?.tag_name || ''}`.trim();
    case 'PullRequestEvent': return `${payload.action || 'updated'} pull request #${payload.number || payload.pull_request?.number || ''}`.trim();
    case 'IssuesEvent': return `${payload.action || 'updated'} issue #${payload.issue?.number || ''}`.trim();
    case 'IssueCommentEvent': return `${payload.action || 'posted'} an issue comment`;
    case 'ForkEvent': return 'forked the repository';
    case 'WatchEvent': return 'starred the repository';
    case 'MemberEvent': return `${payload.action || 'updated'} collaborator ${payload.member?.login || ''}`.trim();
    case 'PublicEvent': return 'made the repository public';
    case 'GollumEvent': return 'updated the wiki';
    default: return String(event?.type || 'GitHub activity').replace(/Event$/, '').replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase();
  }
};

const architecture = [
  { key: 'ui', title: 'Elm application', subtitle: 'Routes, state, views, settings', path: 'priv/static/elm/src/Main.elm', detail: 'The typed browser application owns route state and renders Plainwire’s main interface.' },
  { key: 'bridge', title: 'Browser bridge', subtitle: 'WebSocket, WebRTC, media, native browser APIs', path: 'priv/static/elm-bridge.js', detail: 'Imperative browser capabilities stay behind the Elm port boundary: realtime sync, calls, uploads, onboarding, and device APIs.' },
  { key: 'api', title: 'Cowboy API', subtitle: 'Authenticated HTTP boundary', path: 'src/pw_api.erl', detail: 'The API validates sessions, CSRF/rate limits writes, and hands requests to narrow domain functions.' },
  { key: 'realtime', title: 'Realtime hub', subtitle: 'Presence, calls, voice, event fan-out', path: 'src/pw_hub.erl', detail: 'The hub coordinates connected sessions and realtime room state without turning database work into a websocket bottleneck.' },
  { key: 'data', title: 'Data layer', subtitle: 'epgsql + PostgreSQL', path: 'src/pw_db.erl', detail: 'Plainwire’s durable state and permission checks live in the database layer, backed by versioned migrations.' },
  { key: 'media', title: 'Media boundary', subtitle: 'Signed proxy, SSRF controls, bounded fetches', path: 'src/pw_media.erl', detail: 'Remote media uses signed same-origin URLs and network validation so arbitrary message content cannot become an internal-network fetch primitive.' },
  { key: 'quality', title: 'Call quality worker', subtitle: 'C + Fortran analysis worker', path: 'native/media_quality/worker.c', detail: 'Optional native signal analysis runs outside the Erlang VM and degrades cleanly when unavailable.' },
  { key: 'desktop', title: 'Desktop client', subtitle: 'Native Plainwire shell', repo: 'Plainwire-desktop', path: '', detail: 'The desktop repository packages Plainwire as a native desktop experience while staying compatible with a normal hosted Plainwire server.' }
];

class PlainwireSourceHub extends HTMLElement {
  constructor() {
    super();
    this.state = {
      overview: null,
      overviewError: '',
      section: 'pulse',
      repoName: '',
      repo: null,
      repoError: '',
      repoTab: 'overview',
      profileLogin: '',
      profile: null,
      profileError: '',
      commit: null,
      file: null,
      filePath: '',
      fileRef: '',
      fileError: '',
      loading: new Set(),
      lastRefresh: 0
    };
    this.routeSerial = 0;
    this.dialogSerial = 0;
  }

  connectedCallback() {
    if (this.connected) return;
    this.connected = true;
    this.abort = new AbortController();
    this.parseRoute();
    this.renderShell();
    this.loadOverview();
    if (this.state.repoName) this.loadRepository(this.state.repoName);
    if (this.state.profileLogin) this.loadProfile(this.state.profileLogin);
    window.addEventListener('hashchange', this.onHashChange, { signal: this.abort.signal });
    document.addEventListener('visibilitychange', this.onVisibility, { signal: this.abort.signal });
    this.poll = setInterval(() => { if (!document.hidden && this.isConnected) this.refreshVisible(); }, SOURCE_REFRESH_MS);
  }

  disconnectedCallback() {
    this.connected = false;
    this.routeSerial += 1;
    this.dialogSerial += 1;
    this.abort?.abort();
    clearInterval(this.poll);
    this.cancelRequests();
    this.closeDialog();
    this.stopTour();
  }

  onHashChange = () => {
    if (!location.hash.startsWith('#source')) return;
    const before = `${this.state.repoName}|${this.state.profileLogin}`;
    this.parseRoute();
    const after = `${this.state.repoName}|${this.state.profileLogin}`;
    if (before === after) return;
    this.routeSerial += 1;
    this.dialogSerial += 1;
    this.closeDialog();
    this.stopTour();
    this.state.repo = null; this.state.profile = null; this.state.commit = null; this.state.file = null;
    this.render();
    if (this.state.repoName) this.loadRepository(this.state.repoName);
    if (this.state.profileLogin) this.loadProfile(this.state.profileLogin);
  };

  onVisibility = () => { if (!document.hidden && Date.now() - this.state.lastRefresh > SOURCE_REFRESH_MS) this.refreshVisible(); };

  parseRoute() {
    let raw = '';
    try { raw = decodeURIComponent(location.hash.replace(/^#source\/?/, '')); }
    catch (_) { raw = ''; }
    const bits = raw.split('/').filter(Boolean);
    this.state.repoName = '';
    this.state.profileLogin = '';
    if (bits[0] === 'repo' && validRepoName(bits[1])) this.state.repoName = bits[1];
    if (bits[0] === 'profile' && validGitHubLogin(bits[1])) this.state.profileLogin = bits[1];
  }

  cancelRequests() {
    for (const controller of this.controllers || []) controller.abort();
    this.controllers = new Set();
  }

  async api(path) {
    if (!this.controllers) this.controllers = new Set();
    const controller = new AbortController();
    this.controllers.add(controller);
    const timeout = setTimeout(() => controller.abort(), SOURCE_TIMEOUT_MS);
    try {
      const response = await fetch(`/api/development/${path}`, { headers: { accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store', signal: controller.signal });
      let body = null;
      try { body = await response.json(); } catch (_) {}
      if (!response.ok || body?.ok === false) {
        const error = new Error(body?.error || `request_failed_${response.status}`);
        error.status = response.status;
        throw error;
      }
      return body?.data ?? body;
    } finally {
      clearTimeout(timeout);
      this.controllers.delete(controller);
    }
  }

  setLoading(key, value) {
    if (value) this.state.loading.add(key); else this.state.loading.delete(key);
    this.updateBusy();
  }

  hasDataErrors() {
    const nested = [this.state.overview?.errors, this.state.overview?.contributor_errors, this.state.repo?.errors, this.state.profile?.errors];
    return Boolean(this.state.overviewError || this.state.repoError || this.state.profileError || this.state.fileError || nested.some(value => value && typeof value === 'object' && Object.keys(value).length));
  }

  updateBusy() {
    if (!this.isConnected) return;
    const loading = this.state.loading.size > 0;
    const degraded = !loading && this.hasDataErrors();
    this.toggleAttribute('aria-busy', loading);
    const chip = this.querySelector('[data-source-status]');
    if (chip) {
      chip.classList.toggle('is-loading', loading);
      chip.classList.toggle('is-warning', degraded);
      chip.textContent = loading
        ? 'Refreshing GitHub data…'
        : degraded
          ? `Cached · refresh incomplete · ${relativeDate(this.state.lastRefresh || Date.now())}`
          : `GitHub · refreshed ${relativeDate(this.state.lastRefresh || Date.now())}`;
    }
  }

  async loadOverview({ silent = false } = {}) {
    if (this.state.loading.has('overview')) return;
    this.setLoading('overview', true);
    if (!silent && !this.state.overview) this.render();
    try {
      this.state.overview = await this.api('overview');
      this.state.overviewError = '';
      this.state.lastRefresh = Date.now();
    } catch (error) {
      this.state.overviewError = error.message || 'github_unavailable';
    } finally {
      this.setLoading('overview', false);
      this.render();
    }
  }

  async loadRepository(name, { silent = false } = {}) {
    if (!validRepoName(name) || this.state.loading.has(`repo:${name}`)) return;
    this.state.repoName = name;
    this.state.profileLogin = '';
    const routeSerial = this.routeSerial;
    this.setLoading(`repo:${name}`, true);
    if (!silent) { this.state.repo = null; this.state.repoError = ''; this.render(); }
    try {
      const data = await this.api(`repository?repo=${encodeURIComponent(name)}`);
      if (routeSerial !== this.routeSerial || this.state.repoName !== name || this.state.profileLogin) return;
      this.state.repo = data;
      this.state.repoError = '';
      this.state.lastRefresh = Date.now();
    } catch (error) {
      if (routeSerial === this.routeSerial && this.state.repoName === name && !this.state.profileLogin) {
        this.state.repoError = error.message || 'github_unavailable';
      }
    } finally {
      this.setLoading(`repo:${name}`, false);
      if (routeSerial === this.routeSerial && this.state.repoName === name && !this.state.profileLogin) this.render();
    }
  }

  async loadProfile(login, { silent = false } = {}) {
    if (!validGitHubLogin(login) || this.state.loading.has(`profile:${login}`)) return;
    this.state.profileLogin = login;
    this.state.repoName = '';
    const routeSerial = this.routeSerial;
    this.setLoading(`profile:${login}`, true);
    if (!silent) { this.state.profile = null; this.state.profileError = ''; this.render(); }
    try {
      const data = await this.api(`profile?login=${encodeURIComponent(login)}`);
      if (routeSerial !== this.routeSerial || this.state.profileLogin !== login || this.state.repoName) return;
      this.state.profile = data;
      this.state.profileError = '';
      this.state.lastRefresh = Date.now();
    } catch (error) {
      if (routeSerial === this.routeSerial && this.state.profileLogin === login && !this.state.repoName) {
        this.state.profileError = error.message || 'github_unavailable';
      }
    } finally {
      this.setLoading(`profile:${login}`, false);
      if (routeSerial === this.routeSerial && this.state.profileLogin === login && !this.state.repoName) this.render();
    }
  }

  async loadCommit(repo, sha) {
    const key = `commit:${repo}:${sha}`;
    if (!validRepoName(repo) || !/^[0-9a-f]{7,64}$/i.test(sha || '') || this.state.loading.has(key)) return;
    const dialogSerial = ++this.dialogSerial;
    this.setLoading(key, true);
    try {
      const data = await this.api(`commit?repo=${encodeURIComponent(repo)}&sha=${encodeURIComponent(sha)}`);
      if (dialogSerial !== this.dialogSerial || !this.isConnected) return;
      this.state.commit = data;
      this.showCommitDialog(data, repo);
    } catch (error) {
      if (dialogSerial === this.dialogSerial && this.isConnected) this.showNotice('Could not load commit', this.humanError(error.message));
    } finally { this.setLoading(key, false); }
  }

  async loadContent(repo, path = '', ref = '', { openViewer = true } = {}) {
    if (!validRepoName(repo) || this.state.loading.has(`file:${repo}:${path}:${ref}`)) return null;
    const key = `file:${repo}:${path}:${ref}`;
    const dialogSerial = ++this.dialogSerial;
    this.setLoading(key, true);
    this.state.fileError = '';
    try {
      const query = new URLSearchParams({ repo });
      if (path) query.set('path', path);
      if (ref) query.set('ref', ref);
      const data = await this.api(`content?${query}`);
      if (dialogSerial !== this.dialogSerial || !this.isConnected) return null;
      this.state.file = data;
      this.state.filePath = path;
      this.state.fileRef = ref;
      if (openViewer) this.showFileDialog(data, repo, path, ref);
      return data;
    } catch (error) {
      if (dialogSerial !== this.dialogSerial || !this.isConnected) return null;
      this.state.fileError = error.message || 'github_unavailable';
      if (openViewer) this.showNotice('Could not load source file', this.humanError(error.message));
      return null;
    } finally { this.setLoading(key, false); }
  }

  refreshVisible() {
    this.loadOverview({ silent: true });
    if (this.state.repoName) this.loadRepository(this.state.repoName, { silent: true });
    if (this.state.profileLogin) this.loadProfile(this.state.profileLogin, { silent: true });
  }

  navigateSource(path = '') {
    const next = `#source${path ? `/${path}` : ''}`;
    if (location.hash === next) return;
    location.hash = next;
  }

  humanError(error) {
    return ({
      github_rate_limited: 'GitHub’s public API limit is temporarily exhausted. Plainwire will keep using cached data where possible.',
      source_rate_limited: 'This Plainwire session refreshed development data too quickly. Try again in a moment.',
      source_not_found: 'That GitHub resource no longer exists or is not public.',
      invalid_repository: 'That repository name is invalid.', invalid_commit: 'That commit identifier is invalid.',
      invalid_profile: 'That GitHub profile name is invalid.', invalid_path: 'That source path is invalid.', invalid_ref: 'That Git reference is invalid.',
      not_authenticated: 'Your Plainwire session is no longer authenticated. Sign in again to refresh development data.',
      github_unavailable: 'GitHub is temporarily unavailable from this Plainwire server.'
    })[error] || 'GitHub data could not be loaded right now.';
  }

  renderShell() { this.replaceChildren(textNode('div', 'source-hub-skeleton', 'Loading Plainwire development data…')); }

  render() {
    if (!this.isConnected) return;
    const root = textNode('div', 'source-hub');
    root.append(this.renderHero());
    if (this.state.profileLogin) root.append(this.renderProfilePage());
    else if (this.state.repoName) root.append(this.renderRepositoryPage());
    else root.append(this.renderLanding());
    this.replaceChildren(root);
    this.updateBusy();
  }

  renderHero() {
    const hero = textNode('section', 'source-hero card');
    const copy = textNode('div', 'source-hero-copy');
    copy.append(textNode('span', 'eyebrow', 'Open development'), textNode('h1', '', 'Plainwire, under the hood'));
    copy.append(textNode('p', 'muted', 'A current view of Plainwire’s public code, releases, contributors, architecture, and development activity.'));
    const actions = textNode('div', 'source-hero-actions');
    const status = textNode('span', 'source-live-chip', 'GitHub'); status.dataset.sourceStatus = 'true';
    actions.append(status, button('Take the tour', 'btn secondary source-tour-button', () => this.startTour()), button('Refresh', 'btn secondary', () => this.refreshVisible()), githubLink('Open GitHub ↗', SOURCE_ROOT, 'btn ghost source-external'));
    hero.append(copy, actions);
    return hero;
  }

  renderLanding() {
    const wrap = textNode('div', 'source-landing');
    if (this.state.overviewError && !this.state.overview) {
      const error = emptyState('GitHub data is unavailable', this.humanError(this.state.overviewError));
      error.append(button('Try again', 'btn secondary', () => this.loadOverview()));
      wrap.append(error);
      return wrap;
    }
    if (!this.state.overview) { wrap.append(this.renderLoadingGrid()); return wrap; }
    const overview = this.state.overview;
    const repos = Array.isArray(overview.repositories) ? overview.repositories : [];
    const org = overview.organization || {};
    const totals = repos.reduce((acc, repo) => ({ stars: acc.stars + Number(repo.stargazers_count || 0), forks: acc.forks + Number(repo.forks_count || 0), issues: acc.issues + Number(repo.open_issues_count || 0) }), { stars: 0, forks: 0, issues: 0 });
    const summary = textNode('section', 'source-summary source-tour-overview');
    const orgCard = textNode('div', 'source-org-card card');
    const orgTop = textNode('div', 'source-org-top');
    const orgIcon = textNode('div', 'source-org-mark', 'P');
    const orgCopy = textNode('div', 'source-org-copy');
    orgCopy.append(textNode('h2', '', org.name || SOURCE_ORG), textNode('p', 'muted', org.description || 'Plainwire development organization'));
    orgTop.append(orgIcon, orgCopy);
    const stats = textNode('div', 'source-stats');
    stats.append(stat('Public repositories', formatNumber(repos.length)), stat('Stars', formatNumber(totals.stars)), stat('Forks', formatNumber(totals.forks)), stat('Open issues', formatNumber(totals.issues)));
    orgCard.append(orgTop, stats);
    summary.append(orgCard);
    wrap.append(summary, this.renderLandingTabs());
    return wrap;
  }

  renderLoadingGrid() {
    const grid = textNode('div', 'source-loading-grid');
    for (let i = 0; i < 6; i += 1) grid.append(textNode('div', 'source-loading-card card'));
    return grid;
  }

  renderLandingTabs() {
    const section = textNode('section', 'source-workspace');
    const tabs = textNode('div', 'source-tabs');
    const defs = [['pulse', 'Activity'], ['repositories', 'Repositories'], ['architecture', 'Architecture'], ['metadata', 'Metadata']];
    for (const [key, label] of defs) {
      const tab = button(label, `source-tab${this.state.section === key ? ' active' : ''}`, () => { this.state.section = key; this.render(); });
      tab.setAttribute('aria-pressed', String(this.state.section === key)); tabs.append(tab);
    }
    section.append(tabs);
    if (this.state.section === 'repositories') section.append(this.renderRepositories());
    else if (this.state.section === 'architecture') section.append(this.renderArchitecture());
    else if (this.state.section === 'metadata') section.append(this.renderOrgMetadata());
    else section.append(this.renderActivity());
    return section;
  }

  renderActivity() {
    const panel = textNode('div', 'source-panel source-tour-pulse');
    const head = textNode('div', 'source-section-head');
    head.append(textNode('div', '', ''), textNode('small', 'muted', 'Public GitHub events · automatically refreshed'));
    head.firstChild.append(textNode('span', 'eyebrow', 'Development pulse'), textNode('h2', '', 'What changed recently'));
    panel.append(head);
    const events = Array.isArray(this.state.overview?.activity) ? this.state.overview.activity : [];
    const grid = textNode('div', 'source-activity-grid');
    const list = textNode('div', 'source-activity-list');
    if (events.length) {
      for (const event of events.slice(0, 40)) list.append(this.renderEvent(event));
    } else {
      list.append(emptyState('No recent public activity', 'GitHub did not return recent organization events. Commit authors are still loaded independently from repository history.'));
    }
    grid.append(list, this.renderActiveContributors(events, this.state.overview?.contributors || []));
    panel.append(grid);
    return panel;
  }

  renderActiveContributors(events, contributors) {
    const card = textNode('aside', 'card source-active-contributors source-tour-contributors');
    card.append(textNode('span', 'eyebrow', 'Contributors'), textNode('h3', '', 'People committing across Plainwire'));
    const people = new Map();
    const orgKey = SOURCE_ORG.toLowerCase();

    for (const raw of Array.isArray(contributors) ? contributors : []) {
      const login = String(raw?.login || '').trim();
      const name = String(raw?.name || '').trim();
      if (login && login.toLowerCase() === orgKey) continue;
      const anonymous = raw?.anonymous === true || !login;
      const key = login ? `login:${login.toLowerCase()}` : name ? `anonymous:${name.toLowerCase()}` : '';
      if (!key) continue;
      people.set(key, {
        person: raw,
        anonymous,
        contributions: Math.max(0, Number(raw?.contributions || 0)),
        repositories: Array.isArray(raw?.repositories) ? raw.repositories : [],
        events: 0,
        last: ''
      });
    }

    for (const event of Array.isArray(events) ? events : []) {
      const actor = event?.actor || {};
      const login = String(actor.login || '').trim();
      if (!login || login.toLowerCase() === orgKey || !validGitHubLogin(login)) continue;
      const key = `login:${login.toLowerCase()}`;
      const current = people.get(key) || { person: actor, anonymous: false, contributions: 0, repositories: [], events: 0, last: '' };
      current.events += 1;
      if (String(event.created_at || '') > String(current.last || '')) current.last = event.created_at || '';
      if (!current.person?.avatar_url && actor.avatar_url) current.person = { ...current.person, ...actor };
      people.set(key, current);
    }

    const ranked = [...people.values()].sort((a, b) =>
      b.contributions - a.contributions || b.events - a.events || String(b.last).localeCompare(String(a.last))
    );
    if (!ranked.length) {
      card.append(textNode('p', 'muted', 'No public commit authors were returned for the current Plainwire repositories.'));
      return card;
    }

    const list = textNode('div', 'source-active-contributor-list');
    for (const entry of ranked) {
      const person = entry.person || {};
      const login = String(person.login || '').trim();
      const name = String(person.name || login || 'Unlinked author').trim();
      const interactive = !entry.anonymous && validGitHubLogin(login);
      const row = textNode(interactive ? 'button' : 'div', `source-active-contributor${entry.anonymous ? ' is-anonymous' : ''}`);
      if (interactive) row.type = 'button';
      const copy = textNode('span', 'source-active-contributor-copy');
      const repositoryCount = entry.repositories.length;
      const detail = entry.contributions > 0
        ? `${formatNumber(entry.contributions)} commit contribution${entry.contributions === 1 ? '' : 's'}${repositoryCount ? ` · ${repositoryCount} repo${repositoryCount === 1 ? '' : 's'}` : ''}`
        : entry.events > 0
          ? `${entry.events} recent public event${entry.events === 1 ? '' : 's'}`
          : 'Public commit author';
      copy.append(textNode('strong', '', interactive ? login : name), textNode('small', 'muted', detail));
      row.append(avatar(person, 'sm'), copy, interactive ? textNode('span', 'source-row-chevron', '›') : pill('Unlinked', 'subtle'));
      if (interactive) row.addEventListener('click', () => this.navigateSource(`profile/${encodeURIComponent(login)}`));
      list.append(row);
    }
    card.append(list, textNode('p', 'muted source-active-note', 'Commit counts come from GitHub’s contributor data across every public Plainwire repository. Unlinked authors are counted without exposing commit e-mail addresses.'));
    return card;
  }

  renderEvent(event) {
    const row = textNode('article', 'source-activity-row');
    const actor = event.actor || {};
    const av = avatar(actor, 'sm');
    const body = textNode('div', 'source-activity-copy');
    const line = textNode('div', 'source-activity-line');
    const actorLogin = String(actor.login || '').trim();
    const actorIsOrganization = actorLogin.toLowerCase() === SOURCE_ORG.toLowerCase();
    const actorBtn = actorIsOrganization || !validGitHubLogin(actorLogin)
      ? textNode('strong', 'source-activity-actor', actorIsOrganization ? 'Plainwire Development' : (actorLogin || 'GitHub user'))
      : button(actorLogin, 'source-inline-button', () => this.navigateSource(`profile/${encodeURIComponent(actorLogin)}`));
    const repo = repoShortName(event.repo?.name);
    const repoBtn = button(repo || 'repository', 'source-inline-button', () => repo && this.navigateSource(`repo/${encodeURIComponent(repo)}`));
    line.append(actorBtn, document.createTextNode(` ${eventLabel(event)} in `), repoBtn);
    const meta = textNode('div', 'source-activity-meta');
    meta.append(textNode('time', '', relativeDate(event.created_at)), pill(String(event.type || 'event').replace(/Event$/, '')));
    body.append(line, meta);
    const payload = event.payload || {};
    if (event.type === 'PushEvent' && Array.isArray(payload.commits) && payload.commits.length) {
      const commits = textNode('div', 'source-event-commits');
      for (const commit of payload.commits.slice(0, 4)) {
        const sha = String(commit.sha || '');
        const label = `${sha.slice(0, 7)} · ${clampText(firstLine(commit.message), 120)}`;
        if (repo && /^[0-9a-f]{7,64}$/i.test(sha)) {
          const openCommit = button(label, 'source-event-commit-button', () => this.loadCommit(repo, sha));
          commits.append(openCommit);
        } else commits.append(textNode('div', '', label));
      }
      body.append(commits);
    } else if (event.type === 'ReleaseEvent' && payload.release) {
      body.append(textNode('p', 'muted source-event-detail', clampText(payload.release.name || payload.release.tag_name || '', 180)));
    }
    row.append(av, body);
    return row;
  }

  renderRepositories() {
    const panel = textNode('div', 'source-panel source-tour-repos');
    const head = textNode('div', 'source-section-head');
    const copy = textNode('div'); copy.append(textNode('span', 'eyebrow', 'Repositories'), textNode('h2', '', 'Everything Plainwire publishes'));
    const search = textNode('input', 'source-search'); search.type = 'search'; search.placeholder = 'Filter repositories…'; search.setAttribute('aria-label', 'Filter Plainwire repositories');
    head.append(copy, search); panel.append(head);
    const grid = textNode('div', 'source-repo-grid');
    const repos = [...(this.state.overview?.repositories || [])].sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || '')));
    const render = () => {
      const q = search.value.trim().toLowerCase(); grid.replaceChildren();
      const matches = repos.filter(repo => !q || `${repo.name} ${repo.description || ''} ${repo.language || ''} ${(repo.topics || []).join(' ')}`.toLowerCase().includes(q));
      if (!matches.length) grid.append(emptyState('No repositories match', 'Try a shorter name, language, or topic.'));
      for (const repo of matches) grid.append(this.renderRepoCard(repo));
    };
    search.addEventListener('input', render); render(); panel.append(grid);
    return panel;
  }

  renderRepoCard(repo) {
    const card = textNode('article', 'source-repo-card card'); card.dataset.repo = repo.name || '';
    const top = textNode('div', 'source-repo-card-top');
    const heading = textNode('div'); heading.append(textNode('h3', '', repo.name || 'Repository'), textNode('p', 'muted', clampText(repo.description || 'No repository description.', 180)));
    const visibility = pill(repo.archived ? 'Archived' : (repo.visibility || (repo.private ? 'Private' : 'Public')), repo.archived ? 'warning' : '');
    top.append(heading, visibility);
    const meta = textNode('div', 'source-repo-meta');
    if (repo.language) meta.append(pill(repo.language));
    meta.append(textNode('span', '', `★ ${formatNumber(repo.stargazers_count)}`), textNode('span', '', `⑂ ${formatNumber(repo.forks_count)}`), textNode('span', '', `Updated ${relativeDate(repo.updated_at)}`));
    const topics = textNode('div', 'source-topic-row');
    for (const topic of (repo.topics || []).slice(0, 6)) topics.append(pill(topic, 'subtle'));
    const actions = textNode('div', 'source-card-actions');
    actions.append(button('Explore source', 'btn secondary', () => this.navigateSource(`repo/${encodeURIComponent(repo.name)}`)), githubLink('GitHub ↗', repo.html_url, 'btn ghost source-external'));
    card.append(top, meta); if (topics.children.length) card.append(topics); card.append(actions);
    return card;
  }

  renderArchitecture() {
    const panel = textNode('div', 'source-panel source-tour-architecture');
    const head = textNode('div', 'source-section-head');
    const copy = textNode('div'); copy.append(textNode('span', 'eyebrow', 'Source architecture'), textNode('h2', '', 'How Plainwire fits together'), textNode('p', 'muted', 'Follow a user action from the typed interface through realtime/API boundaries to durable storage and optional native workers.'));
    head.append(copy); panel.append(head);
    const flow = textNode('div', 'source-architecture-flow');
    for (const [index, part] of architecture.entries()) {
      const card = textNode('article', `source-architecture-card source-arch-${part.key}`);
      const marker = textNode('span', 'source-architecture-index', String(index + 1).padStart(2, '0'));
      const body = textNode('div', 'source-architecture-copy');
      body.append(textNode('h3', '', part.title), textNode('small', 'muted', part.subtitle), textNode('p', '', part.detail));
      const actions = textNode('div', 'source-architecture-actions');
      if (part.repo) actions.append(button('Open repository', 'btn secondary', () => this.navigateSource(`repo/${encodeURIComponent(part.repo)}`)));
      else actions.append(button('Open source file', 'btn secondary', () => this.loadContent('Plainwire', part.path)));
      body.append(actions); card.append(marker, body); flow.append(card);
    }
    panel.append(flow);
    return panel;
  }

  renderOrgMetadata() {
    const panel = textNode('div', 'source-panel source-tour-metadata');
    const copy = textNode('div', 'source-section-head');
    const title = textNode('div'); title.append(textNode('span', 'eyebrow', 'Raw metadata'), textNode('h2', '', 'The GitHub view, without hiding fields'), textNode('p', 'muted', 'Useful when you want the details behind the polished cards. Tokens and private GitHub data never reach this page.'));
    copy.append(title); panel.append(copy);
    panel.append(jsonDetails('Organization metadata', this.state.overview?.organization || {}), jsonDetails('Repository metadata', this.state.overview?.repositories || []), jsonDetails('Recent event metadata', this.state.overview?.activity || []));
    return panel;
  }

  renderRepositoryPage() {
    const wrap = textNode('div', 'source-repository-page');
    const back = button('← All Plainwire development', 'source-back', () => this.navigateSource());
    wrap.append(back);
    if (this.state.repoError && !this.state.repo) { const error = emptyState('Repository unavailable', this.humanError(this.state.repoError)); error.append(button('Try again', 'btn secondary', () => this.loadRepository(this.state.repoName))); wrap.append(error); return wrap; }
    if (!this.state.repo) { wrap.append(this.renderLoadingGrid()); return wrap; }
    const data = this.state.repo;
    const repo = data.repository || {};
    const header = textNode('section', 'source-repo-hero card source-tour-code');
    const main = textNode('div', 'source-repo-hero-copy');
    main.append(textNode('span', 'eyebrow', `${SOURCE_ORG} / repository`), textNode('h1', '', repo.name || this.state.repoName), textNode('p', 'muted', repo.description || 'No repository description.'));
    const badges = textNode('div', 'source-topic-row');
    if (repo.language) badges.append(pill(repo.language));
    if (repo.license?.spdx_id) badges.append(pill(repo.license.spdx_id, 'subtle'));
    if (repo.archived) badges.append(pill('Archived', 'warning'));
    for (const topic of (repo.topics || []).slice(0, 8)) badges.append(pill(topic, 'subtle'));
    main.append(badges);
    const actions = textNode('div', 'source-repo-hero-actions');
    actions.append(githubLink('Open on GitHub ↗', repo.html_url, 'btn secondary source-external'));
    header.append(main, actions);
    const stats = textNode('div', 'source-stats source-repo-stats');
    stats.append(stat('Stars', formatNumber(repo.stargazers_count)), stat('Forks', formatNumber(repo.forks_count)), stat('Open issues', formatNumber(repo.open_issues_count)), stat('Watchers', formatNumber(repo.subscribers_count ?? repo.watchers_count)), stat('Size', formatBytes(Number(repo.size || 0) * 1024)), stat('Default branch', repo.default_branch || '—'));
    header.append(stats); wrap.append(header, this.renderRepositoryTabs(data));
    return wrap;
  }

  renderRepositoryTabs(data) {
    const workspace = textNode('section', 'source-workspace');
    const tabs = textNode('div', 'source-tabs source-repo-tabs');
    const defs = [['overview', 'Overview'], ['commits', 'Commits'], ['releases', 'Releases & tags'], ['code', 'Files'], ['contributors', 'Contributors'], ['metadata', 'Metadata']];
    for (const [key, label] of defs) tabs.append(button(label, `source-tab${this.state.repoTab === key ? ' active' : ''}`, () => { this.state.repoTab = key; this.render(); }));
    workspace.append(tabs);
    switch (this.state.repoTab) {
      case 'commits': workspace.append(this.renderCommits(data)); break;
      case 'releases': workspace.append(this.renderReleases(data)); break;
      case 'code': workspace.append(this.renderCode(data)); break;
      case 'contributors': workspace.append(this.renderContributors(data)); break;
      case 'metadata': workspace.append(this.renderRepoMetadata(data)); break;
      default: workspace.append(this.renderRepoOverview(data));
    }
    return workspace;
  }

  renderRepoOverview(data) {
    const panel = textNode('div', 'source-panel');
    const grid = textNode('div', 'source-overview-grid');
    const readmeCard = textNode('section', 'source-readme card');
    const readmeHead = textNode('div', 'source-card-head'); readmeHead.append(textNode('h2', '', 'README'), textNode('small', 'muted', 'Rendered with Plainwire’s safe Markdown pipeline'));
    readmeCard.append(readmeHead);
    const readme = data.readme?.decoded_content || '';
    if (readme) readmeCard.append(markdown(readme)); else readmeCard.append(emptyState('No README returned', 'The repository may not have a README on its default branch.'));
    const side = textNode('aside', 'source-overview-side');
    side.append(this.renderLanguages(data.languages || {}));
    const repo = data.repository || {};
    const facts = textNode('section', 'source-facts card'); facts.append(textNode('h3', '', 'Repository facts'));
    const rows = [
      ['Created', formatDate(repo.created_at)], ['Last push', formatDate(repo.pushed_at)], ['Default branch', repo.default_branch || '—'],
      ['Issues', repo.has_issues === false ? 'Disabled' : 'Enabled'], ['Wiki', repo.has_wiki ? 'Enabled' : 'Disabled'], ['Discussions', repo.has_discussions ? 'Enabled' : 'Disabled'],
      ['Visibility', repo.visibility || (repo.private ? 'private' : 'public')]
    ];
    for (const [label, value] of rows) { const row = textNode('div', 'source-fact-row'); row.append(textNode('span', 'muted', label), textNode('strong', '', value)); facts.append(row); }
    side.append(facts); grid.append(readmeCard, side); panel.append(grid); return panel;
  }

  renderLanguages(languages) {
    const card = textNode('section', 'source-language-card card'); card.append(textNode('h3', '', 'Language detector'));
    const entries = Object.entries(languages || {}).sort((a, b) => Number(b[1]) - Number(a[1]));
    const total = entries.reduce((sum, [, bytes]) => sum + Number(bytes || 0), 0);
    if (!entries.length || !total) { card.append(textNode('p', 'muted', 'GitHub did not report language data for this repository.')); return card; }
    const bar = textNode('div', 'source-language-bar');
    for (const [language, bytes] of entries) { const segment = textNode('span', 'source-language-segment'); segment.style.width = `${Math.max(.7, Number(bytes) / total * 100)}%`; segment.title = `${language}: ${(Number(bytes) / total * 100).toFixed(1)}%`; bar.append(segment); }
    card.append(bar);
    const list = textNode('div', 'source-language-list');
    for (const [language, bytes] of entries.slice(0, 12)) { const row = textNode('div', 'source-language-row'); row.append(textNode('span', '', language), textNode('span', 'muted', `${(Number(bytes) / total * 100).toFixed(1)}% · ${formatBytes(bytes)}`)); list.append(row); }
    card.append(list); return card;
  }

  renderCommits(data) {
    const panel = textNode('div', 'source-panel');
    const head = textNode('div', 'source-section-head');
    const title = textNode('div'); title.append(textNode('span', 'eyebrow', 'Commit history'), textNode('h2', '', 'Recent changes'));
    head.append(title, textNode('small', 'muted', 'Select a commit for its file-by-file diff')); panel.append(head);
    const commits = Array.isArray(data.commits) ? data.commits : [];
    if (!commits.length) { panel.append(emptyState('No commits returned', 'GitHub did not return recent commits.')); return panel; }
    const list = textNode('div', 'source-commit-list');
    for (const commit of commits) {
      const row = textNode('article', 'source-commit-row');
      const linked = commit.author || {};
      const authored = commit.commit?.author || {};
      const av = avatar(linked.login ? linked : { login: authored.name }, 'sm');
      const body = textNode('div', 'source-commit-copy');
      body.append(textNode('strong', 'source-commit-message', firstLine(commit.commit?.message || 'Commit')));
      const meta = textNode('div', 'source-commit-meta');
      if (linked.login) meta.append(button(linked.login, 'source-inline-button', event => { event.stopPropagation(); this.navigateSource(`profile/${encodeURIComponent(linked.login)}`); }));
      else meta.append(textNode('span', '', authored.name || 'Unknown author'));
      meta.append(document.createTextNode(` · ${relativeDate(authored.date || commit.commit?.committer?.date)}`), textNode('code', 'source-sha', String(commit.sha || '').slice(0, 7)));
      body.append(meta); row.append(av, body, textNode('span', 'source-row-chevron', '›'));
      row.tabIndex = 0; row.setAttribute('role', 'button'); row.setAttribute('aria-label', `Open commit ${String(commit.sha || '').slice(0, 7)} diff`);
      const open = () => this.loadCommit(this.state.repoName, commit.sha);
      row.addEventListener('click', open); row.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
      list.append(row);
    }
    panel.append(list); return panel;
  }

  renderReleases(data) {
    const panel = textNode('div', 'source-panel');
    const releases = Array.isArray(data.releases) ? data.releases : [];
    const tags = Array.isArray(data.tags) ? data.tags : [];
    const branches = Array.isArray(data.branches) ? data.branches : [];
    const head = textNode('div', 'source-section-head'); const title = textNode('div'); title.append(textNode('span', 'eyebrow', 'Versions'), textNode('h2', '', 'Releases, tags, and branches')); head.append(title); panel.append(head);
    const grid = textNode('div', 'source-version-grid');
    const releaseCol = textNode('section', 'source-release-list'); releaseCol.append(textNode('h3', '', 'Releases'));
    if (!releases.length) releaseCol.append(emptyState('No GitHub releases', 'This repository may ship through tags or another release channel.'));
    for (const release of releases) releaseCol.append(this.renderRelease(release));
    const refCol = textNode('aside', 'source-ref-column');
    const tagCard = textNode('div', 'card source-ref-card'); tagCard.append(textNode('h3', '', 'Tags'));
    for (const tag of tags.slice(0, 30)) { const row = textNode('div', 'source-ref-row'); row.append(textNode('span', '', tag.name || 'tag'), textNode('code', '', String(tag.commit?.sha || '').slice(0, 7))); tagCard.append(row); }
    if (!tags.length) tagCard.append(textNode('p', 'muted', 'No tags returned.'));
    const branchCard = textNode('div', 'card source-ref-card'); branchCard.append(textNode('h3', '', 'Branches'));
    for (const branch of branches.slice(0, 30)) { const row = textNode('div', 'source-ref-row'); row.append(textNode('span', '', branch.name || 'branch'), branch.protected ? pill('Protected', 'subtle') : textNode('span')); branchCard.append(row); }
    if (!branches.length) branchCard.append(textNode('p', 'muted', 'No branches returned.'));
    refCol.append(tagCard, branchCard); grid.append(releaseCol, refCol); panel.append(grid); return panel;
  }

  renderRelease(release) {
    const card = textNode('article', 'source-release card');
    const head = textNode('div', 'source-release-head');
    const copy = textNode('div'); copy.append(textNode('h3', '', release.name || release.tag_name || 'Release'));
    const meta = textNode('div', 'source-release-meta');
    if (release.author?.login) meta.append(avatar(release.author, 'xs'), button(release.author.login, 'source-inline-button', () => this.navigateSource(`profile/${encodeURIComponent(release.author.login)}`)));
    meta.append(textNode('span', 'muted', `Published ${relativeDate(release.published_at || release.created_at)}`));
    copy.append(meta); head.append(copy, pill(release.prerelease ? 'Pre-release' : release.draft ? 'Draft' : release.tag_name || 'Release', release.prerelease ? 'warning' : ''));
    card.append(head);
    if (release.body) { const body = textNode('div', 'source-release-body'); body.append(markdown(release.body)); card.append(body); }
    const foot = textNode('div', 'source-release-foot');
    if (Array.isArray(release.assets) && release.assets.length) foot.append(textNode('span', 'muted', `${release.assets.length} asset${release.assets.length === 1 ? '' : 's'} · ${formatNumber(release.assets.reduce((n, a) => n + Number(a.download_count || 0), 0))} downloads`));
    foot.append(githubLink('Release on GitHub ↗', release.html_url, 'source-inline-link')); card.append(foot); return card;
  }

  renderCode(data) {
    const panel = textNode('div', 'source-panel');
    const head = textNode('div', 'source-section-head'); const title = textNode('div'); title.append(textNode('span', 'eyebrow', 'Code browser'), textNode('h2', '', 'Files on the default branch'), textNode('p', 'muted', 'Directories and text files load through the same bounded, read-only GitHub proxy.')); head.append(title); panel.append(head);
    panel.append(this.renderDirectory(data.contents || [], '', data.repository?.default_branch || ''));
    return panel;
  }

  renderDirectory(entries, path, ref) {
    const browser = textNode('div', 'source-file-browser card');
    const bar = textNode('div', 'source-file-browser-head');
    const crumbs = textNode('div', 'source-breadcrumbs'); crumbs.append(textNode('span', '', this.state.repoName)); if (path) for (const part of path.split('/')) crumbs.append(textNode('span', '', part));
    bar.append(crumbs, pill(ref || 'default branch', 'subtle')); browser.append(bar);
    const list = textNode('div', 'source-file-list');
    const sorted = [...(Array.isArray(entries) ? entries : [])].sort((a, b) => (a.type === b.type ? String(a.name).localeCompare(String(b.name)) : a.type === 'dir' ? -1 : 1));
    if (!sorted.length) list.append(emptyState('Directory is empty', 'No public entries were returned for this path.'));
    for (const entry of sorted) {
      const row = textNode('button', 'source-file-row'); row.type = 'button';
      const icon = textNode('span', 'source-file-icon', entry.type === 'dir' ? '▱' : '⌘');
      const copy = textNode('span', 'source-file-copy'); copy.append(textNode('strong', '', entry.name || entry.path || 'entry'), textNode('small', 'muted', entry.type === 'dir' ? 'Directory' : `${languageFromPath(entry.path)} · ${formatBytes(entry.size)}`));
      row.append(icon, copy, textNode('span', 'source-row-chevron', '›'));
      row.addEventListener('click', async () => {
        if (entry.type === 'dir') {
          const children = await this.loadContent(this.state.repoName, entry.path, ref, { openViewer: false });
          if (Array.isArray(children)) this.showDirectoryDialog(children, this.state.repoName, entry.path, ref);
        } else this.loadContent(this.state.repoName, entry.path, ref);
      });
      list.append(row);
    }
    browser.append(list); return browser;
  }

  renderContributors(data) {
    const panel = textNode('div', 'source-panel source-tour-contributors');
    const head = textNode('div', 'source-section-head');
    const title = textNode('div');
    title.append(textNode('span', 'eyebrow', 'Contributors'), textNode('h2', '', 'Commit authors in this repository'), textNode('p', 'muted', 'GitHub-linked authors open a public profile mirror. Commits from unlinked e-mail addresses are still counted and shown without exposing the address.'));
    head.append(title); panel.append(head);
    const people = Array.isArray(data.contributors) ? data.contributors : [];
    if (!people.length) { panel.append(emptyState('No contributor list returned', 'GitHub may omit contributor data for a new or empty repository.')); return panel; }
    const grid = textNode('div', 'source-contributor-grid');
    for (const person of people) {
      const login = String(person?.login || '').trim();
      const anonymous = person?.anonymous === true || !login;
      const name = String(person?.name || login || 'Unlinked author');
      const interactive = !anonymous && validGitHubLogin(login) && login.toLowerCase() !== SOURCE_ORG.toLowerCase();
      const card = textNode(interactive ? 'button' : 'article', `source-contributor-card card${anonymous ? ' is-anonymous' : ''}`);
      if (interactive) card.type = 'button';
      const copy = textNode('span', 'source-contributor-copy');
      copy.append(textNode('strong', '', interactive ? login : name), textNode('small', 'muted', `${formatNumber(person.contributions)} commit contribution${Number(person.contributions) === 1 ? '' : 's'}${anonymous ? ' · unlinked author' : ''}`));
      card.append(avatar(person, 'lg'), copy, interactive ? textNode('span', 'source-row-chevron', '›') : pill('Unlinked', 'subtle'));
      if (interactive) card.addEventListener('click', () => this.navigateSource(`profile/${encodeURIComponent(login)}`));
      grid.append(card);
    }
    panel.append(grid); return panel;
  }

  renderRepoMetadata(data) {
    const panel = textNode('div', 'source-panel');
    panel.append(jsonDetails('Repository', data.repository || {}), jsonDetails('Languages', data.languages || {}), jsonDetails('Commits', data.commits || []), jsonDetails('Releases', data.releases || []), jsonDetails('Tags', data.tags || []), jsonDetails('Branches', data.branches || []), jsonDetails('Contributors', data.contributors || []), jsonDetails('Root contents', data.contents || []));
    return panel;
  }

  renderProfilePage() {
    const wrap = textNode('div', 'source-profile-page');
    wrap.append(button('← Back to Plainwire development', 'source-back', () => this.navigateSource()));
    if (this.state.profileError && !this.state.profile) { const error = emptyState('Profile unavailable', this.humanError(this.state.profileError)); error.append(button('Try again', 'btn secondary', () => this.loadProfile(this.state.profileLogin))); wrap.append(error); return wrap; }
    if (!this.state.profile) { wrap.append(this.renderLoadingGrid()); return wrap; }
    const data = this.state.profile;
    const profile = data.profile || {};
    const hero = textNode('section', 'source-profile-hero card source-tour-profile');
    const identity = textNode('div', 'source-profile-identity'); identity.append(avatar(profile, 'xl'));
    const isOrganization = String(profile.type || '').toLowerCase() === 'organization';
    const copy = textNode('div', 'source-profile-copy');
    copy.append(textNode('span', 'eyebrow', isOrganization ? 'GitHub organization' : 'GitHub profile mirror'), textNode('h1', '', profile.name || profile.login || this.state.profileLogin), textNode('div', 'source-profile-login', isOrganization ? (profile.login || this.state.profileLogin) : `@${profile.login || this.state.profileLogin}`));
    if (profile.bio) copy.append(textNode('p', '', profile.bio));
    const facts = textNode('div', 'source-profile-facts');
    for (const value of [profile.company, profile.location]) if (value) facts.append(pill(value, 'subtle'));
    if (profile.blog) facts.append(externalLink('Website ↗', /^https?:\/\//i.test(profile.blog) ? profile.blog : `https://${profile.blog}`, 'source-inline-link'));
    copy.append(facts); identity.append(copy);
    const actions = textNode('div', 'source-profile-actions'); actions.append(githubLink('Open GitHub ↗', profile.html_url, 'btn secondary source-external'));
    hero.append(identity, actions);
    const stats = textNode('div', 'source-stats source-profile-stats'); stats.append(stat('Followers', formatNumber(profile.followers)), stat('Following', formatNumber(profile.following)), stat('Public repos', formatNumber(profile.public_repos)), stat('Public gists', formatNumber(profile.public_gists)), stat('Joined GitHub', profile.created_at ? new Date(profile.created_at).getFullYear() : '—'));
    hero.append(stats); wrap.append(hero);
    const grid = textNode('div', 'source-profile-grid');
    const main = textNode('section', 'source-panel source-profile-main'); main.append(this.renderProfileRepos(data.repositories || []), this.renderProfileActivity(data.activity || []));
    const side = textNode('aside', 'source-profile-side'); side.append(this.renderProfileOrganizations(data.organizations || []), jsonDetails('Raw profile metadata', profile));
    grid.append(main, side); wrap.append(grid); return wrap;
  }

  renderProfileRepos(repos) {
    const section = textNode('section', 'source-profile-section'); section.append(textNode('h2', '', 'Public repositories'));
    if (!repos.length) { section.append(textNode('p', 'muted', 'No public repositories returned.')); return section; }
    const list = textNode('div', 'source-mini-repo-list');
    for (const repo of [...repos].sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || ''))).slice(0, 20)) {
      const row = textNode('article', 'source-mini-repo card'); const copy = textNode('div'); copy.append(textNode('strong', '', repo.name || 'Repository'), textNode('p', 'muted', clampText(repo.description || '', 140)));
      const meta = textNode('div', 'source-repo-meta'); if (repo.language) meta.append(pill(repo.language)); meta.append(textNode('span', '', `★ ${formatNumber(repo.stargazers_count)}`), textNode('span', '', `Updated ${relativeDate(repo.updated_at)}`)); copy.append(meta); row.append(copy, githubLink('GitHub ↗', repo.html_url, 'source-inline-link')); list.append(row);
    }
    section.append(list); return section;
  }

  renderProfileActivity(events) {
    const section = textNode('section', 'source-profile-section'); section.append(textNode('h2', '', 'Recent public activity'));
    if (!events.length) { section.append(textNode('p', 'muted', 'No recent public events returned.')); return section; }
    const list = textNode('div', 'source-profile-event-list');
    for (const event of events.slice(0, 20)) { const row = textNode('div', 'source-profile-event'); row.append(textNode('strong', '', eventLabel(event)), textNode('span', 'muted', `${repoShortName(event.repo?.name)} · ${relativeDate(event.created_at)}`)); list.append(row); }
    section.append(list); return section;
  }

  renderProfileOrganizations(orgs) {
    const card = textNode('section', 'card source-profile-orgs'); card.append(textNode('h3', '', 'Organizations'));
    if (!orgs.length) { card.append(textNode('p', 'muted', 'No public organization memberships returned.')); return card; }
    for (const org of orgs) { const row = textNode('div', 'source-org-row'); row.append(avatar(org, 'sm'), textNode('strong', '', org.login || 'Organization')); card.append(row); }
    return card;
  }

  ensureDialog(label) {
    this.closeDialog();
    const dialog = textNode('dialog', 'source-dialog'); dialog.setAttribute('aria-label', label);
    const shell = textNode('div', 'source-dialog-shell');
    const close = button('×', 'source-dialog-close', () => this.dismissDialog()); close.setAttribute('aria-label', 'Close');
    shell.append(close); dialog.append(shell); document.body.append(dialog); this.dialog = dialog;
    dialog.addEventListener('close', () => { if (this.dialog === dialog) this.dialog = null; dialog.remove(); }, { once: true });
    dialog.addEventListener('click', event => { if (event.target === dialog) this.dismissDialog(); });
    dialog.addEventListener('cancel', event => { event.preventDefault(); this.dismissDialog(); });
    dialog.showModal(); return shell;
  }

  dismissDialog() { this.dialogSerial += 1; this.closeDialog(); }

  closeDialog() { if (this.dialog?.open) this.dialog.close(); else this.dialog?.remove(); this.dialog = null; }

  showNotice(title, copy) {
    const shell = this.ensureDialog(title); const body = textNode('div', 'source-dialog-body source-notice'); body.append(textNode('h2', '', title), textNode('p', 'muted', copy)); shell.append(body);
  }

  showCommitDialog(commit, repo) {
    const shell = this.ensureDialog('Commit details');
    const body = textNode('div', 'source-dialog-body');
    const heading = textNode('div', 'source-dialog-heading');
    heading.append(textNode('span', 'eyebrow', `${repo} · ${String(commit.sha || '').slice(0, 12)}`), textNode('h2', '', firstLine(commit.commit?.message || 'Commit')));
    const author = commit.author || {};
    const authored = commit.commit?.author || {};
    const meta = textNode('div', 'source-commit-dialog-meta'); meta.append(avatar(author.login ? author : { login: authored.name }, 'sm'));
    if (author.login) meta.append(button(author.login, 'source-inline-button', () => { this.closeDialog(); this.navigateSource(`profile/${encodeURIComponent(author.login)}`); })); else meta.append(textNode('span', '', authored.name || 'Unknown author'));
    meta.append(textNode('span', 'muted', formatDate(authored.date || commit.commit?.committer?.date))); heading.append(meta); body.append(heading);
    const stats = textNode('div', 'source-stats source-diff-stats'); stats.append(stat('Files changed', formatNumber(commit.files?.length || 0)), stat('Additions', `+${formatNumber(commit.stats?.additions)}`), stat('Deletions', `−${formatNumber(commit.stats?.deletions)}`), stat('Total changes', formatNumber(commit.stats?.total))); body.append(stats);
    if (commit.commit?.message && commit.commit.message.includes('\n')) body.append(markdown(commit.commit.message));
    const files = textNode('div', 'source-diff-files');
    const changedFiles = Array.isArray(commit.files) ? commit.files : [];
    for (const file of changedFiles.slice(0, SOURCE_MAX_DIFF_FILES)) files.append(this.renderDiffFile(file));
    if (!files.children.length) files.append(emptyState('No patch data returned', 'GitHub did not include file patches for this commit.'));
    if (changedFiles.length > SOURCE_MAX_DIFF_FILES) files.append(emptyState('Diff view bounded', `${changedFiles.length - SOURCE_MAX_DIFF_FILES} additional changed files are available on GitHub. Plainwire limits one in-app diff to ${SOURCE_MAX_DIFF_FILES} files to keep the page responsive.`));
    body.append(files, jsonDetails('Raw commit metadata', commit)); shell.append(body);
  }

  renderDiffFile(file) {
    const card = textNode('section', 'source-diff-file card');
    const head = textNode('div', 'source-diff-file-head'); const copy = textNode('div'); copy.append(textNode('strong', '', file.filename || 'File'), textNode('small', 'muted', `${file.status || 'modified'} · +${formatNumber(file.additions)} −${formatNumber(file.deletions)}`)); head.append(copy, pill(languageFromPath(file.filename), 'subtle')); card.append(head);
    if (file.patch) {
      const pre = textNode('pre', 'source-diff');
      const fullPatch = String(file.patch);
      const patch = fullPatch.length > SOURCE_MAX_PATCH ? `${fullPatch.slice(0, SOURCE_MAX_PATCH)}\n… diff preview truncated in Plainwire` : fullPatch;
      for (const line of patch.split('\n')) {
        const span = textNode('span', line.startsWith('+') && !line.startsWith('+++') ? 'add' : line.startsWith('-') && !line.startsWith('---') ? 'del' : line.startsWith('@@') ? 'hunk' : '', line);
        pre.append(span, document.createTextNode('\n'));
      }
      card.append(pre);
    } else card.append(textNode('p', 'muted source-no-patch', 'Patch omitted by GitHub (common for binary or very large changes).'));
    return card;
  }

  showFileDialog(data, repo, path, ref) {
    if (Array.isArray(data)) return this.showDirectoryDialog(data, repo, path, ref);
    const shell = this.ensureDialog(path || 'Source file');
    const body = textNode('div', 'source-dialog-body');
    const head = textNode('div', 'source-file-view-head');
    const copy = textNode('div'); copy.append(textNode('span', 'eyebrow', `${repo} · ${ref || 'default branch'}`), textNode('h2', '', path || data?.name || 'Source file'));
    const actions = textNode('div', 'source-file-view-actions'); actions.append(pill(languageFromPath(path || data?.name), 'subtle')); if (data?.html_url) actions.append(githubLink('GitHub ↗', data.html_url, 'btn ghost source-external'));
    head.append(copy, actions); body.append(head);
    if (data?.type === 'symlink' || data?.type === 'submodule') body.append(textNode('p', 'muted', `${data.type} → ${data.target || data.submodule_git_url || 'target unavailable'}`));
    const decoded = typeof data?.decoded_content === 'string' ? data.decoded_content : '';
    if (decoded) {
      const pre = textNode('pre', 'source-file-code'); pre.dataset.language = languageFromPath(path || data.name); pre.textContent = decoded; body.append(pre);
    } else body.append(emptyState('Preview unavailable', 'This file is binary, too large for the bounded source viewer, or GitHub did not include inline content. Use the GitHub link for the full file.'));
    body.append(jsonDetails('File metadata', data || {})); shell.append(body);
  }

  showDirectoryDialog(entries, repo, path, ref) {
    const shell = this.ensureDialog(path || repo);
    const body = textNode('div', 'source-dialog-body');
    const head = textNode('div', 'source-file-view-head');
    const copy = textNode('div'); copy.append(textNode('span', 'eyebrow', `${repo} · code browser`), textNode('h2', '', path || '/'));
    const actions = textNode('div', 'source-file-view-actions');
    if (path) {
      const parent = path.split('/').slice(0, -1).join('/');
      actions.append(button('↑ Up one level', 'btn ghost', async () => {
        const parentEntries = await this.loadContent(repo, parent, ref, { openViewer: false });
        if (Array.isArray(parentEntries)) this.showDirectoryDialog(parentEntries, repo, parent, ref);
      }));
    }
    const defaultBranch = this.state.repo?.repository?.default_branch || 'main';
    const repoUrl = `https://github.com/${SOURCE_ORG}/${encodeURIComponent(repo)}/tree/${encodeURIComponent(ref || defaultBranch)}${path ? `/${path.split('/').map(encodeURIComponent).join('/')}` : ''}`;
    actions.append(githubLink('GitHub ↗', repoUrl, 'btn ghost source-external'));
    head.append(copy, actions); body.append(head, this.renderDirectory(entries, path, ref)); shell.append(body);
  }

  startTour() {
    this.stopTour();
    this.tourReturnFocus = document.activeElement;
    this.tour = { index: 0 };
    this.tourAbort = new AbortController();
    window.addEventListener('resize', this.repositionTour, { signal: this.tourAbort.signal });
    window.visualViewport?.addEventListener('resize', this.repositionTour, { signal: this.tourAbort.signal });
    window.visualViewport?.addEventListener('scroll', this.repositionTour, { signal: this.tourAbort.signal });
    document.addEventListener('scroll', this.repositionTour, { capture: true, passive: true, signal: this.tourAbort.signal });
    document.addEventListener('keydown', event => { if (event.key === 'Escape') this.stopTour(); }, { signal: this.tourAbort.signal });
    this.showTourStep(0);
  }

  stopTour() {
    const returnFocus = this.tourReturnFocus;
    this.tourReturnFocus = null;
    this.tourResize?.disconnect();
    this.tour = null;
    this.tourAbort?.abort(); this.tourAbort = null;
    this.tourTarget = null;
    this.tourGuide?.remove(); this.tourGuide = null;
    this.tourSpotlight?.remove(); this.tourSpotlight = null;
    if (returnFocus?.isConnected) returnFocus.focus({ preventScroll: true });
    else if (this.isConnected) this.querySelector('.source-tour-button')?.focus({ preventScroll: true });
  }

  tourSteps() {
    return [
      { title: 'Plainwire Source', copy: 'Follow what’s being built, explore the code, and meet the people behind Plainwire. This short tour shows you where to start.', section: 'pulse', selector: '.source-tour-overview' },
      { title: 'Development pulse', copy: 'See recent changes across Plainwire in one place. Open an activity item to follow a commit, release, or discussion.', section: 'pulse', selector: '.source-tour-pulse' },
      { title: 'Every public repository', copy: 'Find the server, desktop app, forum, and other projects. Search by name, then open a repository to explore its work.', section: 'repositories', selector: '.source-tour-repos' },
      { title: 'Source architecture', copy: 'See how Plainwire fits together, from the interface to calls and storage. Select a component to jump into its source files.', section: 'architecture', selector: '.source-tour-architecture' },
      { title: 'Repository inspector', copy: 'Read the README, browse files, or inspect exactly what changed in a commit. Releases and branches are here too.', section: 'repositories', selector: '.source-repo-card', fallbackSelector: '.source-tour-repos' },
      { title: 'Contributor mirrors', copy: 'Meet the people contributing to Plainwire. Select a linked name to explore their public profile, projects, and recent work.', section: 'pulse', selector: '.source-active-contributors', fallbackSelector: '.source-tour-pulse' },
      { title: 'Raw metadata when you need it', copy: 'For a closer look, expand the public data behind this page. You’re ready to explore — you can replay this tour any time.', section: 'metadata', selector: '.source-tour-metadata' }
    ];
  }

  showTourStep(index) {
    const steps = this.tourSteps();
    if (!this.tour || index < 0 || index >= steps.length) return this.stopTour();
    this.tour.index = index;
    const step = steps[index];
    if (this.state.section !== step.section) { this.state.section = step.section; this.render(); }
    requestAnimationFrame(() => {
      if (!this.tour || this.tour.index !== index) return;
      const target = this.querySelector(step.selector) || (step.fallbackSelector ? this.querySelector(step.fallbackSelector) : null) || this.querySelector('.source-workspace');
      if (!target) return this.stopTour();
      this.tourTarget = target;
      target.scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'center' });
      setTimeout(() => this.placeTour(target, step, index, steps.length), 120);
    });
  }

  placeTour(target, step, index, total) {
    if (!this.tour || this.tour.index !== index || !target?.isConnected) return;
    this.tourGuide?.remove(); this.tourSpotlight?.remove();
    const spotlight = textNode('div', 'pw-tour-spotlight source-tour-spotlight');
    spotlight.setAttribute('aria-hidden', 'true');
    const guide = textNode('aside', 'pw-tour-guide source-tour-guide');
    guide.setAttribute('role', 'dialog'); guide.setAttribute('aria-modal', 'false'); guide.setAttribute('aria-label', 'Plainwire Source tour'); guide.tabIndex = -1;
    const head = textNode('div', 'pw-tour-guide-head');
    const brand = textNode('span', 'pw-onboarding-mark compact', 'P');
    const headCopy = textNode('div'); headCopy.append(textNode('strong', '', 'Source tour'), textNode('small', '', `${index + 1} of ${total}`));
    const close = button('×', 'pw-tour-guide-close', () => this.stopTour()); close.setAttribute('aria-label', 'Close source tour');
    head.append(brand, headCopy, close);
    const body = textNode('div', 'pw-tour-guide-body');
    body.append(textNode('h3', '', step.title), textNode('p', '', step.copy), textNode('small', 'pw-tour-guide-hint', 'Use ← and → to move between stops. Escape closes the tour.'));
    const foot = textNode('div', 'pw-tour-guide-actions');
    if (index > 0) foot.append(button('Back', 'btn ghost', () => this.showTourStep(index - 1)));
    foot.append(button(index === total - 1 ? 'Done' : 'Next', 'btn', () => index === total - 1 ? this.stopTour() : this.showTourStep(index + 1)));
    const progress = textNode('div', 'pw-tour-progress');
    progress.setAttribute('role', 'progressbar'); progress.setAttribute('aria-label', 'Tour progress');
    progress.setAttribute('aria-valuemin', '0'); progress.setAttribute('aria-valuemax', String(total)); progress.setAttribute('aria-valuenow', String(index + 1));
    for (let i = 0; i < total; i++) progress.append(textNode('span', i <= index ? 'is-complete' : ''));
    guide.append(head, progress, body, foot);
    guide.addEventListener('keydown', event => {
      if (event.altKey || event.ctrlKey || event.metaKey || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
      event.preventDefault();
      if (event.key === 'ArrowLeft' && index > 0) this.showTourStep(index - 1);
      if (event.key === 'ArrowRight') index === total - 1 ? this.stopTour() : this.showTourStep(index + 1);
    });
    document.body.append(spotlight, guide);
    this.tourSpotlight = spotlight; this.tourGuide = guide; this.tourTarget = target;
    this.tourResize?.disconnect();
    this.tourResize = new ResizeObserver(this.repositionTour);
    this.tourResize.observe(target); this.tourResize.observe(guide);
    this.repositionTour();
    requestAnimationFrame(() => { if (guide.isConnected) guide.classList.add('is-visible'); });
    guide.focus({ preventScroll: true });
  }

  repositionTour = () => {
    const target = this.tourTarget, spotlight = this.tourSpotlight, guide = this.tourGuide;
    if (!this.tour || !target?.isConnected || !spotlight?.isConnected || !guide?.isConnected) return;
    const rect = target.getBoundingClientRect();
    const view = window.visualViewport;
    const left = view?.offsetLeft || 0, top = view?.offsetTop || 0;
    const width = view?.width || innerWidth, height = view?.height || innerHeight;
    const x = Math.max(left + 6, Math.min(rect.left - 7, left + width - 18));
    const y = Math.max(top + 6, Math.min(rect.top - 7, top + height - 18));
    spotlight.style.left = `${x}px`; spotlight.style.top = `${y}px`;
    spotlight.style.width = `${Math.max(12, Math.min(rect.right + 7, left + width - 6) - x)}px`;
    spotlight.style.height = `${Math.max(12, Math.min(rect.bottom + 7, top + height - 6) - y)}px`;
    const mobile = width <= 760;
    const nav = mobile ? (parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--mobile-nav-h')) || 64) : 0;
    guide.style.maxHeight = `${Math.max(100, height - nav - 28)}px`;
    guide.style.width = `${Math.min(400, width - 24)}px`;
    const guideHeight = guide.offsetHeight, guideWidth = guide.offsetWidth;
    // Prefer a free side of the target; on phones use the opposite end of the viewport.
    let gx = left + width - guideWidth - 12;
    let gy = rect.top + rect.height / 2 > top + height / 2 ? top + 12 : top + height - nav - guideHeight - 12;
    if (!mobile && rect.right + guideWidth + 24 < left + width) gx = rect.right + 14;
    else if (!mobile && rect.left - guideWidth - 14 > left) gx = rect.left - guideWidth - 14;
    guide.style.left = `${Math.max(left + 12, gx)}px`;
    guide.style.top = `${Math.max(top + 12, Math.min(gy, top + height - guideHeight - 12))}px`;
    guide.style.right = 'auto'; guide.style.bottom = 'auto';
  };

}

if (!customElements.get('pw-source-hub')) customElements.define('pw-source-hub', PlainwireSourceHub);
