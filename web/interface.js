// UI-only controls. Each component owns and releases its listeners and observers.
const element = (tag, cls, text) => {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (text) el.textContent = text;
  return el;
};
const preference = (key, value) => {
  try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch (_) {}
};

class QuickSwitcher extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    const dialog = element('dialog', 'quick-switcher');
    dialog.setAttribute('aria-label', 'Jump to a conversation or server');
    const heading = element('div', 'switcher-heading');
    const input = element('input'); input.type = 'search'; input.placeholder = 'Where would you like to go?';
    input.setAttribute('aria-label', 'Find conversations and servers'); input.autocomplete = 'off';
    const close = element('button', 'switcher-close', 'Esc'); close.type = 'button'; close.setAttribute('aria-label', 'Close quick switcher');
    heading.append(input, close);
    const list = element('div', 'switcher-results');
    const foot = element('div', 'switcher-footer', '↑ ↓ to move · Enter to open');
    dialog.append(heading, list, foot); this.append(dialog);
    this.dialog = dialog;
    let items = [], index = 0, matches = [];
    const navigate = item => {
      if (!item || !/^#(?:dm|server|channel)\/\d+$|^#(?:home|friends|settings|notifications|messages)$/.test(item.href)) return;
      dialog.close(); location.hash = item.href;
    };
    const select = next => {
      index = matches.length ? (next + matches.length) % matches.length : 0;
      for (const [i, button] of [...list.querySelectorAll('button')].entries()) {
        button.classList.toggle('selected', i === index);
        if (i === index) button.scrollIntoView({ block: 'nearest' });
      }
    };
    const render = () => {
      const words = input.value.trim().toLocaleLowerCase().split(/\s+/);
      matches = items.filter(item => words.every(word => `${item.name} ${item.detail}`.toLocaleLowerCase().includes(word))).slice(0, 30);
      list.replaceChildren();
      for (const item of matches) {
        const button = element('button', 'switcher-result'); button.type = 'button';
        const initial = element('span', 'switcher-initial', item.name.slice(0, 1).toUpperCase()); initial.setAttribute('aria-hidden', 'true');
        const copy = element('span', 'switcher-copy'); copy.append(element('b', '', item.name), element('small', '', item.detail));
        button.append(initial, copy); button.addEventListener('click', () => navigate(item)); list.append(button);
      }
      if (!matches.length) list.append(element('p', 'switcher-empty', 'No matches. Try a person or server name.'));
      select(0);
    };
    this.show = () => {
      if (dialog.open) { dialog.close(); return; }
      try { items = JSON.parse(this.getAttribute('items') || '[]').filter(item => typeof item.name === 'string' && typeof item.href === 'string').slice(0, 1000); }
      catch (_) { items = []; }
      input.value = ''; render(); dialog.showModal(); input.focus();
    };
    input.addEventListener('input', render);
    input.addEventListener('keydown', event => {
      if (event.isComposing) return;
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); select(index + (event.key === 'ArrowDown' ? 1 : -1)); }
      if (event.key === 'Enter') { event.preventDefault(); navigate(matches[index]); }
    });
    close.addEventListener('click', () => dialog.close());
    dialog.addEventListener('keydown', event => {
      if (event.key === 'Escape' && !event.isComposing) { event.preventDefault(); event.stopPropagation(); dialog.close(); }
    });
    dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
    this.abort = new AbortController();
    document.addEventListener('keydown', event => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && !event.isComposing) { event.preventDefault(); this.show(); }
    }, { signal: this.abort.signal });
    document.addEventListener('click', event => { if (event.target.closest?.('[data-open-switcher]')) this.show(); }, { signal: this.abort.signal });
  }
  disconnectedCallback() { this.dialog?.close(); this.abort?.abort(); this.dialog?.remove(); this.dialog = null; }
}
customElements.define('pw-quick-switcher', QuickSwitcher);

class ScrollTools extends HTMLElement {
  connectedCallback() {
    this.abort = new AbortController();
    this.frame = requestAnimationFrame(() => {
      const surface = this.closest('.chat-surface');
      const list = surface?.querySelector('#messages'), composer = surface?.querySelector('.composer');
      if (!list || !composer) return;
      const button = element('button', 'jump-latest', 'Jump to latest ↓'); button.type = 'button'; button.hidden = true; this.replaceChildren(button);
      const update = () => {
        this.frame = 0;
        button.hidden = list.scrollHeight - list.scrollTop - list.clientHeight < 120;
        const height = `${Math.ceil(composer.getBoundingClientRect().height) + 30}px`;
        if (this.style.getPropertyValue('--composer-height') !== height) this.style.setProperty('--composer-height', height);
      };
      const schedule = () => { if (!this.frame) this.frame = requestAnimationFrame(update); };
      button.addEventListener('click', () => { list.scrollTop = list.scrollHeight; update(); });
      list.addEventListener('scroll', schedule, { passive: true, signal: this.abort.signal });
      list.addEventListener('plainwire:messages', schedule, { signal: this.abort.signal });
      this.observer = new ResizeObserver(schedule); this.observer.observe(list); this.observer.observe(composer);
      update();
    });
  }
  disconnectedCallback() { this.abort?.abort(); this.observer?.disconnect(); cancelAnimationFrame(this.frame); }
}
customElements.define('pw-scroll-tools', ScrollTools);

class SidebarResize extends HTMLElement {
  connectedCallback() {
    const side = this.closest('.side'); if (!side) return;
    const grip = element('button', 'sidebar-resize'); grip.type = 'button'; grip.setAttribute('aria-label', 'Resize navigation'); grip.title = 'Drag or use arrow keys to resize. Double-click to reset.';
    this.replaceChildren(grip);
    const resize = width => {
      const clamped = Math.round(Math.max(220, Math.min(360, width)));
      document.documentElement.style.setProperty('--navigation-width', `${clamped}px`);
      return clamped;
    };
    const saved = Number(preference('plainwire_navigation_width')); if (saved >= 220 && saved <= 360) resize(saved);
    let drag;
    grip.addEventListener('pointerdown', event => {
      if (event.button !== 0) return;
      drag = { x: event.clientX, width: side.getBoundingClientRect().width, pointer: event.pointerId };
      grip.setPointerCapture(event.pointerId); event.preventDefault();
    });
    grip.addEventListener('pointermove', event => {
      if (drag?.pointer !== event.pointerId) return;
      drag.current = resize(drag.width + event.clientX - drag.x);
    });
    const finish = () => { if (drag) preference('plainwire_navigation_width', String(drag.current || drag.width)); drag = null; };
    grip.addEventListener('pointerup', finish); grip.addEventListener('pointercancel', finish); grip.addEventListener('lostpointercapture', finish);
    grip.addEventListener('keydown', event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home'].includes(event.key)) return;
      event.preventDefault(); preference('plainwire_navigation_width', String(resize(event.key === 'Home' ? 264 : side.getBoundingClientRect().width + (event.key === 'ArrowRight' ? 16 : -16))));
    });
    grip.addEventListener('dblclick', () => { resize(264); preference('plainwire_navigation_width', '264'); });
  }
}
customElements.define('pw-sidebar-resize', SidebarResize);

// Menus dismiss consistently; internal form and slider interactions stay open.
document.addEventListener('pointerdown', event => {
  for (const menu of document.querySelectorAll('.workspace-menu[open]')) if (!menu.contains(event.target)) menu.open = false;
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') for (const menu of document.querySelectorAll('.workspace-menu[open]')) { menu.open = false; menu.querySelector('summary')?.focus(); }
});
document.addEventListener('click', event => {
  const action = event.target.closest?.('.workspace-menu button, .workspace-menu a');
  if (action) action.closest('details').open = false;
});
