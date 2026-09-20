import MarkdownIt from 'markdown-it';
import './interface.js';

// Raw HTML is deliberately disabled. Markdown never supplies attributes,
// script, frames, style, or remote tracking images to the document.
const md = new MarkdownIt({ html: false, linkify: true, breaks: true, typographer: false });
md.linkify.set({ fuzzyEmail: false });
const escape = md.utils.escapeHtml;
function firstPartyImage(url) {
  try {
    const parsed = new URL(url, location.origin);
    return parsed.origin === location.origin && /^\/api\/(?:files|media)\/[A-Za-z0-9._~-]+$/.test(parsed.pathname);
  } catch { return false; }
}
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  tokens[idx].attrSet('target', '_blank');
  tokens[idx].attrSet('rel', 'noopener noreferrer ugc');
  tokens[idx].attrSet('class', 'message-link');
  return self.renderToken(tokens, idx, options);
};
md.renderer.rules.image = (tokens, idx) => {
  const token = tokens[idx], url = token.attrGet('src') || '';
  const label = token.content || 'Image';
  if (md.validateLink(url) && firstPartyImage(url)) {
    const animated = /\.gif$/i.test(label);
    return `<a href="${escape(url)}" target="_blank" rel="noopener noreferrer ugc" class="message-image-link${animated ? ' message-gif-link' : ''}"><img src="${escape(url)}" alt="${escape(label)}" class="message-image${animated ? ' animated-image' : ''}" loading="lazy" decoding="async"></a>`;
  }
  return md.validateLink(url)
    ? `<a href="${escape(url)}" target="_blank" rel="noopener noreferrer ugc" class="message-link message-image-source">${escape(label)}</a>`
    : escape(label);
};
md.renderer.rules.fence = (tokens, idx) => {
  const token = tokens[idx];
  const lang = (token.info.trim().split(/\s+/)[0] || 'text').toLowerCase().replace(/[^a-z0-9+#_.-]/g, '').slice(0, 40);
  return `<div class="code-block"><div class="code-heading"><span>${escape(lang || 'text')}</span><button type="button" class="code-copy" aria-label="Copy code">Copy</button></div><pre tabindex="0" aria-label="Code block"><code data-language="${escape(lang)}">${escape(token.content)}</code></pre></div>`;
};

// Familiar chat shortcodes. Transform text tokens instead of raw source so
// code spans/blocks and URLs keep their literal contents.
const emojiShortcodes = Object.freeze({
  eyes: '👀', smile: '😄', grin: '😁', joy: '😂', laugh: '😂', rofl: '🤣',
  wink: '😉', blush: '😊', heart_eyes: '😍', thinking: '🤔', neutral_face: '😐',
  sweat_smile: '😅', sob: '😭', cry: '😢', angry: '😠', rage: '😡',
  scream: '😱', skull: '💀', pleading_face: '🥺', melting_face: '🫠',
  sunglasses: '😎', clown: '🤡', poop: '💩', fire: '🔥', sparkles: '✨',
  tada: '🎉', heart: '❤️', broken_heart: '💔', blue_heart: '💙', purple_heart: '💜',
  green_heart: '💚', yellow_heart: '💛', orange_heart: '🧡', white_heart: '🤍',
  black_heart: '🖤', thumbsup: '👍', '+1': '👍', thumbsdown: '👎', '-1': '👎',
  clap: '👏', pray: '🙏', wave: '👋', ok_hand: '👌', muscle: '💪',
  point_up: '☝️', raised_hands: '🙌', handshake: '🤝', check: '✅', x: '❌',
  warning: '⚠️', question: '❓', exclamation: '❗', star: '⭐', rocket: '🚀',
  bug: '🐛', gear: '⚙️', lock: '🔒', unlock: '🔓', pin: '📌', bell: '🔔',
  mute: '🔇', speaker: '🔊', microphone: '🎙️', camera: '📷', phone: '📞'
});
const emojiShortcodePattern = /:([a-z0-9_+\-]+):/gi;
md.core.ruler.after('inline', 'plainwire_emoji_shortcodes', (state) => {
  for (const token of state.tokens) {
    if (token.type !== 'inline' || !token.children) continue;
    let linkDepth = 0;
    for (const child of token.children) {
      if (child.type === 'link_open') { linkDepth += 1; continue; }
      if (child.type === 'link_close') { linkDepth = Math.max(0, linkDepth - 1); continue; }
      if (child.type !== 'text' || linkDepth) continue;
      child.content = child.content.replace(emojiShortcodePattern, (full, name) => emojiShortcodes[name.toLowerCase()] || full);
    }
  }
});

let highlighter;
function loadHighlighter() {
  if (!highlighter) highlighter = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    const url = new URL('/assets/highlight-all.js', location.origin);
    const own = document.querySelector('script[src*="/assets/markdown.js"]');
    if (own) url.search = new URL(own.src).search;
    script.src = url.href;
    const timeout = setTimeout(() => reject(new Error('Highlight loading timed out')), 8000);
    script.onload = () => { clearTimeout(timeout); resolve(globalThis.PlainwireHighlight); };
    script.onerror = () => { clearTimeout(timeout); reject(new Error('Highlight unavailable')); };
    document.head.append(script);
  }).catch(() => {
    highlighter = null;
    return null;
  });
  return highlighter;
}
async function highlight(code) {
  if (code.dataset.processed || code.dataset.highlighting || !code.isConnected) return;
  const source = code.textContent;
  // Explicit languages only: trying every grammar on a chat message is costly.
  if (source.length > 20000 || /^(text|plain|plaintext|txt)?$/.test(code.dataset.language)) {
    code.dataset.processed = 'true';
    return;
  }
  code.dataset.highlighting = 'true';
  try {
    const hl = await loadHighlighter();
    if (!code.isConnected || !hl?.getLanguage(code.dataset.language)) return;
    code.innerHTML = hl.highlight(source, { language: code.dataset.language, ignoreIllegals: true }).value;
    code.dataset.processed = 'true';
  } catch (_) {
    code.textContent = source;
  } finally {
    delete code.dataset.highlighting;
  }
}
const observer = 'IntersectionObserver' in globalThis ? new IntersectionObserver(entries => {
  for (const entry of entries) if (entry.isIntersecting) { observer.unobserve(entry.target); highlight(entry.target); }
}, { rootMargin: '100px' }) : null;

/* ---- Link embeds (Discord-style). ---------------------------------------
   Bare http(s) links in a message are upgraded into cards:
   - YouTube / Vimeo get a poster + Watch control that swaps in a privacy
     respecting player on click (youtube-nocookie, no autoplay until a gesture);
   - everything else is unfurled server-side through /api/embed (auth, rate
     limited, SSRF-safe, og/twitter metadata + proxied thumbnails) and rendered
     as a rich card. Failed lookups render nothing; the plain link stays.
   First-party Wire links are resolved through the invite API rather than the
   generic crawler, including canonical plainwi.re URLs. Never more than
   EMBED_LIMIT cards per rendered chunk, and compact (inbox preview) rendering
   never embeds. */
const EMBED_LIMIT = 5;
const embedCache = new Map();

function wireCodeForUrl(href) {
  let url;
  try { url = new URL(href, location.href); } catch { return null; }
  const host = url.hostname.toLowerCase().replace(/^www\./, '');
  const sameInstance = url.origin === location.origin;
  if (!sameInstance && (host !== 'plainwi.re' || url.protocol !== 'https:')) return null;
  const candidates = [url.hash.replace(/^#\/?/, ''), url.pathname.replace(/^\/+/, '')];
  const queryCode = url.searchParams.get('wire') || url.searchParams.get('invite');
  if (queryCode) candidates.push(`wire/${queryCode}`);
  for (const candidate of candidates) {
    const match = candidate.match(/^(?:wire|invite|w)\/([^/?#&]+)/i);
    if (!match) continue;
    let code = match[1];
    try { code = decodeURIComponent(code); } catch { /* keep the encoded value */ }
    code = code.trim();
    if (/^[A-Za-z0-9_-]{8,80}$/.test(code)) return code;
  }
  return null;
}

function embedKind(href) {
  let u; try { u = new URL(href); } catch { return null; }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  const host = u.hostname.toLowerCase();
  const hostNoWww = host.replace(/^(www\.|m\.|music\.)/, '');
  if (hostNoWww === 'youtube.com' || host === 'youtu.be') {
    let id = null;
    if (host === 'youtu.be') {
      const p = u.pathname.slice(1);
      if (/^[A-Za-z0-9_-]{6,20}$/.test(p)) id = p;
    } else if (u.pathname === '/watch' || u.pathname === '/') {
      id = u.searchParams.get('v');
    } else {
      const m = u.pathname.match(/^\/(?:embed|shorts|live|v)\/([A-Za-z0-9_-]{6,20})/);
      if (m) id = m[1];
    }
    if (id) return { kind: 'youtube', id };
  }
  if (hostNoWww === 'vimeo.com') {
    const m = u.pathname.match(/^\/(\d{4,14})(?:[\/?#]|$)/);
    if (m) return { kind: 'vimeo', id: m[1] };
  }
  return null;
}

function isBareLink(a) {
  if (a.closest('.link-video, .link-embed, .link-embed-wrap, pre, code, table, blockquote')) return false;
  const href = a.getAttribute('href') || '';
  if (!/^https?:\/\//i.test(href)) return false;
  if (a.classList.contains('message-image-source')) return true;
  const label = a.textContent.trim();
  if (href === label) return true;
  // markdown-it expands fuzzy links such as plainwi.re/#wire/… to an absolute
  // href. Treat those as bare links while preserving the explicit-label rule.
  return href === `http://${label}` || href === `https://${label}`;
}

function embedIframe(kind) {
  const iframe = document.createElement('iframe');
  iframe.setAttribute('loading', 'lazy');
  iframe.setAttribute('allow', 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share');
  iframe.setAttribute('allowfullscreen', '');
  // The page policy is same-origin, which sends no Referer to the player. YouTube
  // now refuses embeds without one (player error 153), so send just the origin.
  iframe.referrerPolicy = 'strict-origin-when-cross-origin';
  if (kind.kind === 'youtube') {
    iframe.title = 'YouTube video player';
    iframe.src = `https://www.youtube-nocookie.com/embed/${encodeURIComponent(kind.id)}?autoplay=1&rel=0`;
  } else {
    iframe.title = 'Vimeo player';
    iframe.src = `https://player.vimeo.com/video/${encodeURIComponent(kind.id)}?autoplay=1&title=0&byline=0&portrait=0`;
  }
  return iframe;
}

function videoCard(kind, href) {
  const root = document.createElement('div');
  root.className = 'link-video';
  const frame = document.createElement('div');
  frame.className = 'link-video-frame';
  if (kind.kind === 'youtube') {
    const img = document.createElement('img');
    img.className = 'link-video-thumb';
    img.src = `https://i.ytimg.com/vi/${encodeURIComponent(kind.id)}/hqdefault.jpg`;
    img.alt = '';
    img.loading = 'lazy';
    img.decoding = 'async';
    img.addEventListener('error', () => img.remove(), { once: true });
    frame.append(img);
  }
  const shade = document.createElement('div');
  shade.className = 'link-video-shade';
  shade.setAttribute('aria-hidden', 'true');
  frame.append(shade);
  const play = document.createElement('button');
  play.type = 'button';
  play.className = 'link-video-play';
  play.setAttribute('aria-label', kind.kind === 'youtube' ? 'Play YouTube video' : 'Play Vimeo video');
  play.innerHTML = '<span class="link-video-chip"><span class="link-video-ico" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M8 5.5v13l11-6.5z"/></svg></span><span>Watch</span></span>';
  play.addEventListener('click', () => {
    if (frame.querySelector('iframe')) return;
    play.remove();
    shade.remove();
    frame.append(embedIframe(kind));
  }, { once: true });
  frame.append(play);
  root.append(frame);
  if (href) {
    const note = document.createElement('a');
    note.href = href;
    note.target = '_blank';
    note.rel = 'noopener noreferrer ugc';
    note.className = 'link-video-open';
    note.textContent = kind.kind === 'youtube' ? 'Watch on YouTube' : 'Watch on Vimeo';
    root.append(note);
  }
  return root;
}

function embedCardSkeleton(href) {
  const card = document.createElement('a');
  card.className = 'link-embed embed-loading';
  card.href = href;
  card.target = '_blank';
  card.rel = 'noopener noreferrer ugc';
  card.setAttribute('aria-busy', 'true');
  for (let i = 0; i < 3; i++) {
    const ghost = document.createElement('span');
    ghost.className = 'link-embed-ghost' + (i === 1 ? ' line-2' : i === 2 ? ' line-3' : '');
    card.append(ghost);
  }
  return card;
}

function fillEmbedCard(card, href, meta) {
  card.classList.remove('embed-loading');
  card.removeAttribute('aria-busy');
  card.textContent = '';
  const host = meta.site_name || safeHost(href);
  const title = meta.title || meta.url || href;
  const desc = meta.description || '';
  const image = meta.image || '';
  const copy = document.createElement('span');
  copy.className = 'link-embed-copy';
  const site = document.createElement('span');
  site.className = 'link-embed-site';
  if (typeof meta.favicon === 'string' && meta.favicon.startsWith('/api/media/')) {
    const icon = document.createElement('img');
    icon.className = 'link-embed-site-icon';
    icon.src = meta.favicon;
    icon.alt = '';
    icon.loading = 'lazy';
    icon.addEventListener('error', () => {
      const mono = document.createElement('span');
      mono.className = 'link-embed-favicon'; mono.setAttribute('aria-hidden', 'true');
      mono.textContent = (host || href).replace(/^www\./, '').charAt(0).toUpperCase();
      icon.replaceWith(mono);
    }, { once: true });
    site.append(icon);
  } else {
    const mono = document.createElement('span');
    mono.className = 'link-embed-favicon';
    mono.setAttribute('aria-hidden', 'true');
    mono.textContent = (host || href).replace(/^www\./, '').charAt(0).toUpperCase();
    site.append(mono);
  }
  const siteLabel = document.createElement('span');
  siteLabel.className = 'link-embed-site-label';
  siteLabel.textContent = host || safeHost(href);
  site.append(siteLabel);
  const typeLabel = embedTypeLabel(meta.kind);
  if (typeLabel) {
    const kind = document.createElement('span');
    kind.className = 'link-embed-kind'; kind.textContent = typeLabel; site.append(kind);
  }
  copy.append(site);
  if (title) {
    const t = document.createElement('span');
    t.className = 'link-embed-title';
    t.textContent = title;
    copy.append(t);
  }
  if (desc) {
    const d = document.createElement('span');
    d.className = 'link-embed-description';
    d.textContent = desc;
    copy.append(d);
  }
  const destination = document.createElement('span');
  destination.className = 'link-embed-destination';
  destination.textContent = `${safeHost(href)} ↗`;
  copy.append(destination);
  card.append(copy);
  if (image) {
    const img = document.createElement('img');
    img.className = 'link-embed-thumb';
    img.src = image;
    img.alt = '';
    img.loading = 'lazy';
    img.decoding = 'async';
    img.addEventListener('error', () => { img.remove(); card.classList.remove('has-image'); }, { once: true });
    card.classList.add('has-image');
    card.append(img);
  }
}

function embedTypeLabel(kind) {
  const normalized = String(kind || '').toLowerCase();
  if (normalized === 'pdf') return 'PDF';
  if (normalized === 'code' || normalized === 'application/json') return 'CODE';
  if (normalized === 'text') return 'TEXT';
  if (normalized === 'video' || normalized === 'music' || normalized === 'article') return normalized.toUpperCase();
  return '';
}

function wireEmbedCard(meta) {
  const server = meta.server || {};
  const root = document.createElement('article');
  root.className = 'link-embed wire-embed' + (meta.valid === false ? ' is-unavailable' : '');
  root.style.setProperty('--wire-accent', /^#[0-9a-f]{6}$/i.test(server.accent_color || '') ? server.accent_color : '#5865f2');
  root.setAttribute('aria-label', `${server.name || 'Plainwire server'} Wire invite`);
  if (server.banner_url) {
    const banner = document.createElement('img');
    banner.className = 'wire-embed-banner'; banner.src = server.banner_url; banner.alt = '';
    banner.loading = 'lazy'; banner.decoding = 'async';
    banner.addEventListener('error', () => banner.remove(), { once: true }); root.append(banner);
  }
  const body = document.createElement('div'); body.className = 'wire-embed-body';
  const eyebrow = document.createElement('div'); eyebrow.className = 'wire-embed-eyebrow';
  const label = document.createElement('span'); label.textContent = 'PLAINWIRE WIRE';
  const state = document.createElement('span'); state.className = 'wire-embed-state';
  state.textContent = meta.valid === false ? 'Unavailable' : 'Invite'; eyebrow.append(label, state); body.append(eyebrow);
  const identity = document.createElement('div'); identity.className = 'wire-embed-identity';
  const icon = document.createElement(server.icon_url ? 'img' : 'div'); icon.className = 'wire-embed-icon';
  if (icon instanceof HTMLImageElement) {
    icon.src = server.icon_url; icon.alt = ''; icon.loading = 'lazy';
    icon.addEventListener('error', () => {
      const fallback = document.createElement('div'); fallback.className = 'wire-embed-icon';
      fallback.textContent = String(server.name || 'P').slice(0, 1).toUpperCase(); icon.replaceWith(fallback);
    }, { once: true });
  } else icon.textContent = String(server.name || 'P').slice(0, 1).toUpperCase();
  const copy = document.createElement('div');
  const title = document.createElement('strong'); title.textContent = server.name || 'Plainwire server';
  const desc = document.createElement('p');
  desc.textContent = server.description || server.welcome_message || 'You have been invited to join this server.';
  copy.append(title, desc); identity.append(icon, copy); body.append(identity);
  const details = document.createElement('div'); details.className = 'wire-embed-meta';
  const memberCount = Number(server.member_count || 0);
  const members = document.createElement('span'); members.textContent = `${memberCount.toLocaleString()} member${memberCount === 1 ? '' : 's'}`; details.append(members);
  if (meta.channel_name) { const channel = document.createElement('span'); channel.textContent = `# ${meta.channel_name}`; details.append(channel); }
  if (meta.creator?.display_name) { const creator = document.createElement('span'); creator.textContent = `From ${meta.creator.display_name}`; details.append(creator); }
  if (Number(meta.expires_at || 0) > 0) {
    const expiry = document.createElement('span');
    expiry.textContent = Number(meta.expires_at) <= Date.now() ? 'Expired' : `Expires ${new Date(Number(meta.expires_at)).toLocaleDateString()}`;
    details.append(expiry);
  }
  body.append(details);
  const actions = document.createElement('div'); actions.className = 'wire-embed-actions';
  const open = document.createElement('a'); open.className = meta.valid === false ? 'btn secondary' : 'btn';
  open.href = `#wire/${encodeURIComponent(meta.code)}`; open.textContent = meta.valid === false ? 'View Wire' : 'Open Wire';
  actions.append(open);
  const origin = document.createElement('span'); origin.className = 'wire-embed-origin'; origin.textContent = 'plainwi.re'; actions.append(origin);
  body.append(actions); root.append(body); return root;
}

function imageEmbed(href, source, label, animated) {
  const link = document.createElement('a');
  link.className = 'message-image-link remote-image-embed' + (animated ? ' message-gif-link' : '');
  link.href = href;
  link.target = '_blank';
  link.rel = 'noopener noreferrer ugc';
  const image = document.createElement('img');
  image.className = 'message-image' + (animated ? ' animated-image' : '');
  image.src = source;
  image.alt = label || 'Animated image';
  image.loading = 'lazy';
  image.decoding = 'async';
  image.addEventListener('error', () => link.remove(), { once: true });
  link.append(image);
  return link;
}

function safeHost(href) {
  try { return new URL(href).hostname.replace(/^www\./, ''); } catch { return href; }
}

function embedFetch(href) {
  const wireCode = wireCodeForUrl(href);
  const key = wireCode ? `wire:${wireCode}` : href.split('#')[0];
  let p = embedCache.get(key);
  if (!p) {
    const endpoint = wireCode ? `/api/wires/${encodeURIComponent(wireCode)}` : `/api/embed?url=${encodeURIComponent(key)}`;
    const started = fetch(endpoint, { credentials: 'same-origin', headers: { Accept: 'application/json' } })
      .then(r => { if (!r.ok) throw new Error(`embed ${r.status}`); return r.json(); })
      .then(j => {
        if (!j || !j.ok || !j.data) throw new Error('embed empty');
        return wireCode ? { type: 'plainwire_wire', url: href, code: wireCode, ...j.data } : j.data;
      });
    p = started.catch(err => { embedCache.delete(key); throw err; });
    embedCache.set(key, p);
  }
  return p;
}

function hydrateEmbed(wrap) {
  if (wrap.dataset.hydrating) return;
  wrap.dataset.hydrating = '1';
  const href = wrap.dataset.url;
  const card = wrap.querySelector('.link-embed');
  if (!card) return;
  embedFetch(href).then(meta => {
    if (!wrap.isConnected) return;
    if (meta.type === 'plainwire_wire') {
      card.replaceWith(wireEmbedCard(meta));
      return;
    }
    if ((meta.kind === 'gif' || meta.kind === 'image') && meta.image) {
      const source = [...wrap.parentElement.querySelectorAll('.message-image-source')]
        .find(link => link.href === href);
      const label = source ? source.textContent.trim() : 'Animated image';
      wrap.replaceWith(imageEmbed(href, meta.image, label, meta.kind === 'gif'));
      source?.classList.add('embedded-image-source');
      return;
    }
    fillEmbedCard(card, href, meta);
  }).catch(() => {
    if (wrap.isConnected) wrap.remove();
  });
}

const embedObserver = 'IntersectionObserver' in globalThis ? new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (entry.isIntersecting) { embedObserver.unobserve(entry.target); hydrateEmbed(entry.target); }
  }
}, { rootMargin: '700px 0px' }) : null;

function emitEmbed(root, a) {
  const kind = embedKind(a.href);
  if (kind && (kind.kind === 'youtube' || kind.kind === 'vimeo')) {
    root.append(videoCard(kind, a.href));
    return;
  }
  const wrap = document.createElement('div');
  wrap.className = 'link-embed-wrap';
  wrap.dataset.url = wireCodeForUrl(a.href) ? a.href : a.href.split('#')[0];
  if (wireCodeForUrl(a.href)) wrap.classList.add('wire-embed-wrap');
  wrap.append(embedCardSkeleton(a.href));
  root.append(wrap);
  if (embedObserver) embedObserver.observe(wrap); else hydrateEmbed(wrap);
}

function enhanceLinks(root) {
  if (root.dataset.embeds === '1') return;
  root.dataset.embeds = '1';
  try {
    const seen = new Set();
    const chosen = [...root.querySelectorAll('a.message-link')].filter(isBareLink).filter(link => {
      const key = wireCodeForUrl(link.href) ? `wire:${wireCodeForUrl(link.href)}` : link.href.split('#')[0];
      if (seen.has(key)) return false;
      seen.add(key); return true;
    }).slice(0, EMBED_LIMIT);
    for (const a of chosen) emitEmbed(root, a);
  } catch { /* one bad link must never break message rendering */ }
  if (!root.querySelector('.link-video, .link-embed')) delete root.dataset.embeds;
}

function enhanceMentions(root) {
  if (root.dataset.mentions === '1') return;
  root.dataset.mentions = '1';
  const me = (root.getAttribute('data-me') || root.closest('[data-me]')?.getAttribute('data-me') || '').toLowerCase();
  const re = /(^|[^\w.-])@([\w-]+)/g;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  let wrapped = false;
  for (const node of nodes) {
    const el = node.parentElement;
    if (!el || node.nodeValue.length > 3000) continue;
    if (el.closest('pre, code, a, table, blockquote, .mention, .link-embed, .link-embed-wrap, .link-video, .markdown-table')) continue;
    const value = node.nodeValue;
    const parts = [];
    let last = 0, match;
    while ((match = re.exec(value))) {
      parts.push(document.createTextNode(value.slice(last, match.index + match[1].length)));
      const mention = document.createElement('button');
      mention.type = 'button';
      mention.className = 'mention' + (me && match[2].toLowerCase() === me ? ' mention-self' : '');
      mention.dataset.mentionUsername = match[2];
      mention.title = `View @${match[2]}'s profile`;
      mention.setAttribute('aria-label', `View @${match[2]}'s profile`);
      mention.textContent = '@' + match[2];
      parts.push(mention);
      last = re.lastIndex;
      wrapped = true;
    }
    if (parts.length) {
      parts.push(document.createTextNode(value.slice(last)));
      node.replaceWith(...parts);
    }
  }
  if (!wrapped) delete root.dataset.mentions;
}

const mentionProfileCache = new Map();
const MENTION_PROFILE_TTL_MS = 5 * 60 * 1000;
async function openMentionProfile(username, element) {
  const normalized = String(username || '').trim().toLowerCase();
  if (!normalized) return;
  const cached = mentionProfileCache.get(normalized);
  let userId = cached && Date.now() - cached.at < MENTION_PROFILE_TTL_MS ? cached.userId : undefined;
  if (userId === undefined) {
    try {
      const response = await fetch(`/api/profile-by-username?username=${encodeURIComponent(normalized)}`, {
        method: 'GET', credentials: 'same-origin', headers: { Accept: 'application/json' }
      });
      const payload = await response.json().catch(() => null);
      userId = response.ok && payload?.ok ? Number(payload.data?.user?.id || 0) : 0;
    } catch { userId = 0; }
    mentionProfileCache.set(normalized, { userId, at: Date.now() });
  }
  if (userId > 0) {
    location.hash = `#profile/${userId}`;
  } else if (element?.isConnected) {
    element.classList.add('mention-unresolved');
    element.title = `@${username} could not be found`;
  }
}

document.addEventListener('click', (event) => {
  const mention = event.target.closest?.('.mention[data-mention-username]');
  if (!mention) return;
  event.preventDefault();
  event.stopPropagation();
  openMentionProfile(mention.dataset.mentionUsername, mention);
});

class PlainwireMarkdown extends HTMLElement {
  static observedAttributes = ['source', 'compact', 'data-me', 'no-embeds', 'no-mentions'];
  connectedCallback() { this.render(); }
  attributeChangedCallback() { if (this.isConnected) this.render(); }
  disconnectedCallback() { for (const code of this.querySelectorAll('code[data-language]')) observer?.unobserve(code); }
  refreshEmbeds() {
    for (const embed of this.querySelectorAll('.link-embed-wrap, .link-video, .remote-image-embed')) embed.remove();
    for (const source of this.querySelectorAll('.embedded-image-source')) source.classList.remove('embedded-image-source');
    delete this.dataset.embeds;
    if (!this.hasAttribute('compact') && !this.hasAttribute('no-embeds') && document.documentElement.dataset.linkPreviews !== 'false') enhanceLinks(this);
  }
  render() {
    const source = this.getAttribute('source') || '';
    const compact = this.hasAttribute('compact');
    const currentUser = this.getAttribute('data-me') || this.closest('[data-me]')?.getAttribute('data-me') || '';
    const renderKey = `${compact ? 'compact' : 'full'}:${this.hasAttribute('no-embeds') ? 'no-embeds' : 'embeds'}:${this.hasAttribute('no-mentions') ? 'no-mentions' : 'mentions'}:${currentUser}:${source}`;
    if (this.lastSource === renderKey) return;
    this.lastSource = renderKey;
    for (const code of this.querySelectorAll('code[data-language]')) observer?.unobserve(code);
    this.innerHTML = compact
      ? md.renderInline(source.slice(0, 1000).replace(/\s+/g, ' ').trim())
      : md.render(source.slice(0, 20000));
    for (const table of this.querySelectorAll('table')) {
      const wrap = document.createElement('div'); wrap.className = 'markdown-table'; wrap.tabIndex = 0;
      table.before(wrap); wrap.append(table);
    }
    for (const paragraph of this.querySelectorAll('p')) {
      const attachments = [...paragraph.children].filter(node => node.classList.contains('message-image-link'));
      for (const attachment of attachments.reverse()) paragraph.after(attachment);
      if (!paragraph.textContent.trim() && !paragraph.children.length) paragraph.remove();
    }
    for (const button of this.querySelectorAll('.code-copy')) button.addEventListener('click', async () => {
      const code = button.closest('.code-block').querySelector('code').textContent;
      try { await navigator.clipboard.writeText(code); button.textContent = 'Copied'; }
      catch (_) { button.textContent = 'Select to copy'; }
      setTimeout(() => { if (button.isConnected) button.textContent = 'Copy'; }, 2000);
    });
    for (const code of this.querySelectorAll('code[data-language]')) {
      // Start the one shared grammar download immediately. IntersectionObserver
      // remains an early path, while this call also guarantees that nested
      // scrollers and content-visibility cannot strand an explicit code block.
      if (observer) observer.observe(code);
      highlight(code);
    }
    if (!compact && !this.hasAttribute('no-embeds') && document.documentElement.dataset.linkPreviews !== 'false') enhanceLinks(this);
    if (!compact && !this.hasAttribute('no-mentions')) enhanceMentions(this);
  }
}
customElements.define('pw-markdown', PlainwireMarkdown);
