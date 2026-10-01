'use strict';

// This asset is served with its own CSP. Only this worker allows evaluation;
// its CSP denies every network destination, script import, and nested worker.
(() => {
  const pending = new Map();
  let sequence = 0;
  let initialized = false;
  const emit = self.postMessage.bind(self);
  const listen = self.addEventListener.bind(self);
  const evaluate = Function;
  self.fetch = undefined;
  self.XMLHttpRequest = undefined;
  self.WebSocket = undefined;
  self.EventSource = undefined;
  self.importScripts = undefined;

  const rpc = (op, data = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    emit({ kind: 'rpc', id, op, data });
  });

  listen('message', (event) => {
    const message = event.data || {};
    if (message.kind === 'rpc_result') {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.ok) request.resolve(message.value);
      else request.reject(new Error(message.error || 'plugin_rpc_failed'));
      return;
    }
    if (message.kind !== 'initialize' || initialized) return;
    initialized = true;
    const Plainwire = Object.freeze({
      version: String(message.version || ''),
      toast(text) { emit({ kind: 'toast', text: String(text).slice(0, 500) }); },
      request(path, options = {}) {
        return rpc('request', { path: String(path), method: String(options.method || 'GET'), body: options.body ?? null });
      },
      insertText(text) { emit({ kind: 'insert_text', text: String(text).slice(0, 5000) }); },
      storage: Object.freeze({
        get(key) { return rpc('storage_get', { key: String(key) }); },
        set(key, value) { return rpc('storage_set', { key: String(key), value }); },
        remove(key) { return rpc('storage_remove', { key: String(key) }); }
      })
    });
    try {
      const source = String(message.source || '');
      if (!source.trim() || source.length > 262144) throw new Error('Invalid plugin source');
      evaluate('Plainwire', source)(Plainwire);
      emit({ kind: 'ready' });
    } catch (error) {
      emit({ kind: 'error', error: String(error?.stack || error).slice(0, 2000) });
    }
  });
})();
