import MarkdownIt from 'markdown-it';

// Raw HTML is deliberately disabled. Markdown never supplies attributes,
// script, frames, style, or remote tracking images to the document.
const md = new MarkdownIt({ html: false, linkify: true, breaks: true, typographer: false });
md.linkify.set({ fuzzyEmail: false });
const escape = md.utils.escapeHtml;
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  tokens[idx].attrSet('target', '_blank');
  tokens[idx].attrSet('rel', 'noopener noreferrer ugc');
  tokens[idx].attrSet('class', 'message-link');
  return self.renderToken(tokens, idx, options);
};
md.renderer.rules.image = (tokens, idx) => {
  const token = tokens[idx], url = token.attrGet('src') || '';
  const label = token.content || 'Image';
  return md.validateLink(url) ? `<a href="${escape(url)}" target="_blank" rel="noopener noreferrer ugc">${escape(label)}</a>` : escape(label);
};
md.renderer.rules.fence = (tokens, idx) => {
  const token = tokens[idx];
  const lang = (token.info.trim().split(/\s+/)[0] || 'text').toLowerCase().replace(/[^a-z0-9+#_.-]/g, '').slice(0, 40);
  return `<div class="code-block"><div class="code-heading"><span>${escape(lang || 'text')}</span><button type="button" class="code-copy" aria-label="Copy code">Copy</button></div><pre tabindex="0" aria-label="Code block"><code data-language="${escape(lang)}">${escape(token.content)}</code></pre></div>`;
};

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
  }).catch(() => null);
  return highlighter;
}
async function highlight(code) {
  if (code.dataset.processed || !code.isConnected) return;
  code.dataset.processed = 'true';
  const source = code.textContent;
  // Explicit languages only: trying every grammar on a chat message is costly.
  if (source.length > 20000 || /^(text|plain|plaintext|txt)?$/.test(code.dataset.language)) return;
  const hl = await loadHighlighter();
  if (!code.isConnected || !hl?.getLanguage(code.dataset.language)) return;
  try { code.innerHTML = hl.highlight(source, { language: code.dataset.language, ignoreIllegals: true }).value; }
  catch (_) { code.textContent = source; }
}
const observer = 'IntersectionObserver' in globalThis ? new IntersectionObserver(entries => {
  for (const entry of entries) if (entry.isIntersecting) { observer.unobserve(entry.target); highlight(entry.target); }
}, { rootMargin: '100px' }) : null;

class PlainwireMarkdown extends HTMLElement {
  static observedAttributes = ['source'];
  connectedCallback() { this.render(); }
  attributeChangedCallback() { if (this.isConnected) this.render(); }
  disconnectedCallback() { for (const code of this.querySelectorAll('code[data-language]')) observer?.unobserve(code); }
  render() {
    const source = this.getAttribute('source') || '';
    if (this.lastSource === source) return;
    this.lastSource = source;
    for (const code of this.querySelectorAll('code[data-language]')) observer?.unobserve(code);
    this.innerHTML = md.render(source.slice(0, 20000));
    for (const table of this.querySelectorAll('table')) {
      const wrap = document.createElement('div'); wrap.className = 'markdown-table'; wrap.tabIndex = 0;
      table.before(wrap); wrap.append(table);
    }
    for (const button of this.querySelectorAll('.code-copy')) button.addEventListener('click', async () => {
      const code = button.closest('.code-block').querySelector('code').textContent;
      try { await navigator.clipboard.writeText(code); button.textContent = 'Copied'; }
      catch (_) { button.textContent = 'Select to copy'; }
      setTimeout(() => { if (button.isConnected) button.textContent = 'Copy'; }, 2000);
    });
    for (const code of this.querySelectorAll('code[data-language]')) observer ? observer.observe(code) : highlight(code);
  }
}
customElements.define('pw-markdown', PlainwireMarkdown);
