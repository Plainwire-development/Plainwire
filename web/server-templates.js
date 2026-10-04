// Elm owns the host element; this component owns only its internal controls.
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
};
const workspaceRequest = (accountId, path, body) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('The request timed out. Try again.')), 22000);
  document.dispatchEvent(new CustomEvent('plainwire-workspace-request', { detail: {
    accountId, path, method: 'POST', body,
    resolve: value => { clearTimeout(timer); resolve(value); },
    reject: error => { clearTimeout(timer); reject(error); }
  } }));
});

class ServerTemplatePicker extends HTMLElement {
  static get observedAttributes() { return ['account-id']; }
  attributeChangedCallback() { if (this.isConnected) this.initialize(); }
  connectedCallback() { this.initialize(); }
  disconnectedCallback() { this.generation = (this.generation || 0) + 1; }
  initialize() {
    this.generation = (this.generation || 0) + 1;
    this.replaceChildren();
    const label = el('label', '', 'Start from a template');
    this.select = el('select');
    this.select.setAttribute('aria-label', 'Server template');
    for (const [value, name] of [['blank','Blank server'],['friends','Friends'],['gaming','Gaming'],['study','Study group'],['community','Community'],['import','Import from Discord or JSON']]) {
      const option = el('option', '', name); option.value = value; this.select.append(option);
    }
    label.append(this.select);
    this.importPanel = el('div', 'template-import'); this.importPanel.hidden = true;
    const discordLabel = el('label', '', 'Discord template link or code');
    const code = el('input'); code.type = 'text'; code.maxLength = 256; code.placeholder = 'https://discord.new/…'; discordLabel.append(code);
    const load = el('button', 'btn secondary', 'Preview Discord template'); load.type = 'button';
    load.addEventListener('click', () => this.load('/server-templates/discord', { code: code.value.trim() }));
    const fileLabel = el('label', '', 'Or choose an exported template JSON file');
    const file = el('input'); file.type = 'file'; file.accept = '.json,application/json'; fileLabel.append(file);
    file.addEventListener('change', async () => {
      const chosen = file.files?.[0]; if (!chosen) return;
      // Invalidate an earlier preview before asynchronous file reading starts.
      const generation = ++this.generation;
      this.publish(null, false); this.status.textContent = 'Reading template…';
      try {
        if (chosen.size > 262144) throw new Error('Choose a JSON template smaller than 256 KiB.');
        const content = await chosen.text();
        if (!this.isConnected || generation !== this.generation) return;
        await this.load('/server-templates/preview', { template: JSON.parse(content) });
      } catch (error) {
        if (this.isConnected && generation === this.generation) this.status.textContent = error instanceof SyntaxError ? 'This file is not valid JSON.' : error.message;
      }
    });
    this.importPanel.append(discordLabel, load, fileLabel);
    this.status = el('div', 'template-status'); this.status.setAttribute('role', 'status');
    this.preview = el('div', 'template-preview');
    this.append(label, this.importPanel, this.status, this.preview);
    this.select.addEventListener('change', () => {
      ++this.generation; this.preview.replaceChildren(); this.status.textContent = '';
      this.importPanel.hidden = this.select.value !== 'import';
      if (this.select.value === 'import') { this.publish(null, false); code.focus(); }
      else this.load('/server-templates/preview', { template: this.select.value });
    });
    this.showPreview({ name: 'Blank server', categories: [], roles: [], channels: [{ name: 'general', kind: 'text' }, { name: 'Lounge', kind: 'voice' }] }, []);
    this.publish(null, true);
  }
  publish(template, ready) {
    this.dispatchEvent(new CustomEvent('templatechange', { bubbles: true, detail: { template, ready } }));
  }
  async load(path, body) {
    const generation = ++this.generation;
    const accountId = Number(this.getAttribute('account-id'));
    this.publish(null, false); this.preview.replaceChildren(); this.status.textContent = 'Loading preview…';
    try {
      const result = await workspaceRequest(accountId, path, body);
      if (!this.isConnected || generation !== this.generation || Number(this.getAttribute('account-id')) !== accountId) return;
      this.showPreview(result.preview, result.warnings || []);
      this.status.textContent = result.permissions_review ? 'Review access permissions after creating this server.' : 'Ready to create.';
      this.publish(result.template, true);
    } catch (error) {
      if (this.isConnected && generation === this.generation) this.status.textContent = error.message || 'Could not load this template.';
    }
  }
  showPreview(template, warnings) {
    this.preview.replaceChildren();
    const channels = Array.isArray(template?.channels) ? template.channels : [];
    const categories = Array.isArray(template?.categories) ? template.categories : [];
    const roles = Array.isArray(template?.roles) ? template.roles : [];
    this.preview.append(el('b', '', template?.name || 'Server template'), el('p', 'muted', channels.length + ' channels · ' + categories.length + ' categories · ' + roles.length + ' roles'));
    const list = el('ul', 'template-channel-list');
    for (const channel of channels) {
      const category = categories[channel.category]?.name;
      list.append(el('li', '', (channel.kind === 'voice' ? 'Voice · ' : '# ') + channel.name + (category ? ' · ' + category : '')));
    }
    this.preview.append(list);
    for (const warning of warnings) this.preview.append(el('p', 'template-warning', String(warning)));
  }
}
if (!customElements.get('pw-server-template-picker')) customElements.define('pw-server-template-picker', ServerTemplatePicker);
