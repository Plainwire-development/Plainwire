(() => {
  'use strict';

  const PREFIX = 'pw-e2ee-v1:';
  const encoder = new TextEncoder();
  const modes = new Map();
  const messages = new Map();
  const keys = new Map();
  const decrypted = new Map();
  let userId = null, generation = 0, database, hooks;

  const boundedSet = (map, key, value, limit = 256) => {
    map.delete(key); map.set(key, value);
    while (map.size > limit) map.delete(map.keys().next().value);
  };
  const encode64 = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const decode64 = text => {
    if (typeof text !== 'string' || !/^[A-Za-z0-9_-]+$/.test(text) || text.length > 8192) throw new Error('Invalid encrypted text');
    const bytes = Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - text.length % 4) % 4)), c => c.charCodeAt(0));
    if (encode64(bytes) !== text) throw new Error('Invalid encrypted text');
    return bytes;
  };
  const validId = id => Number.isSafeInteger(id) && id > 0;
  const requireSession = () => { if (!validId(userId)) throw new Error('Sign in before managing encryption keys'); };
  const isEnvelope = value => typeof value === 'string' && value.startsWith(PREFIX);
  const aad = (cid, sender, keyId) => encoder.encode(`plainwire-dm-v1\n${cid}\n${sender}\n${keyId}`);
  const replyId = value => value == null ? null : validId(value) ? value : (() => { throw new Error('Invalid reply'); })();

  async function importSecret(secret) {
    if (!window.isSecureContext || !crypto.subtle) throw new Error('Encrypted text requires HTTPS or localhost');
    if (typeof secret !== 'string' || !/^pwkey1_[A-Za-z0-9_-]{43}$/.test(secret.trim())) throw new Error('Use the full generated DM key, not a password');
    const bytes = decode64(secret.trim().slice(7));
    if (bytes.length !== 32) throw new Error('Invalid DM key');
    try {
      const label = encoder.encode('plainwire-dm-key-v1\0');
      const tagged = new Uint8Array(label.length + bytes.length);
      tagged.set(label); tagged.set(bytes, label.length);
      const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', tagged));
      tagged.fill(0);
      const keyId = Array.from(digest, x => x.toString(16).padStart(2, '0')).join('');
      const key = await crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
      return {key, keyId};
    } finally { bytes.fill(0); }
  }

  async function generateSecret() {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const secret = 'pwkey1_' + encode64(bytes);
    bytes.fill(0);
    return {secret, ...await importSecret(secret)};
  }

  function openDatabase() {
    if (!database) database = new Promise((resolve, reject) => {
      const request = indexedDB.open('plainwire-e2ee-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('keys');
      request.onsuccess = () => {
        const db = request.result;
        db.onversionchange = () => { db.close(); database = undefined; };
        resolve(db);
      };
      request.onerror = () => reject(new Error('This browser cannot store an encryption key'));
      request.onblocked = () => reject(new Error('Close other Plainwire tabs and try again'));
    }).catch(error => { database = undefined; throw error; });
    return database;
  }

  async function storageOperation(mode, operation) {
    requireSession();
    const epoch = generation;
    const db = await openDatabase();
    if (epoch !== generation) throw new Error('Account changed while managing encryption');
    return new Promise((resolve, reject) => {
      const tx = db.transaction('keys', mode);
      const request = operation(tx.objectStore('keys'));
      tx.oncomplete = () => epoch === generation ? resolve(request?.result) : reject(new Error('Account changed while managing encryption'));
      tx.onerror = tx.onabort = () => reject(new Error('Encryption key storage failed'));
    });
  }

  const pinName = cid => `pin:${userId}:${cid}`;
  const keyName = (cid, keyId) => `${userId}:${cid}:${keyId}`;
  async function saveKey(cid, bundle, pinKey = true) {
    requireSession();
    const pin = pinName(cid), name = keyName(cid, bundle.keyId);
    await storageOperation('readwrite', store => {
      if (pinKey) store.put(bundle.keyId, pin);
      return store.put(bundle.key, name);
    });
    keys.set(name, bundle.key);
    decrypted.clear();
  }

  async function getKey(cid, keyId) {
    requireSession();
    const name = keyName(cid, keyId);
    if (keys.has(name)) return keys.get(name);
    const loading = storageOperation('readonly', store => store.get(name)).then(key =>
      key && key.algorithm?.name === 'AES-GCM' && key.algorithm.length === 256 && key.extractable === false ? key : null);
    keys.set(name, loading);
    try {
      const key = await loading;
      if (!key && keys.get(name) === loading) keys.delete(name);
      return key;
    } catch (error) { if (keys.get(name) === loading) keys.delete(name); throw error; }
  }

  function setUser(id) {
    const next = validId(id) ? id : null;
    if (next === userId) return;
    userId = next; generation++;
    keys.clear(); modes.clear(); messages.clear(); decrypted.clear();
  }

  function remember(data) {
    if (!data || typeof data !== 'object') return;
    if (Array.isArray(data)) { data.forEach(remember); return; }
    const cid = data.conversation_id || data.id;
    if (validId(cid) && typeof data.e2ee_key_id === 'string') {
      const previous = modes.get(cid);
      // Activation is permanent. A stale sync may precede its realtime event.
      if (!previous || !previous.keyId || data.e2ee_key_id === previous.keyId) {
        modes.set(cid, {keyId: data.e2ee_key_id, memberCount: data.member_count ?? data.members?.length ?? previous?.memberCount});
      }
    }
    Object.values(data).forEach(value => { if (value && typeof value === 'object') remember(value); });
  }

  async function modeFor(cid) {
    requireSession();
    const epoch = generation;
    if (!modes.has(cid)) {
      const data = await hooks.request('GET', `/conversation/${cid}`);
      if (epoch !== generation) throw new Error('Account changed while checking encryption');
      remember(data);
      if (!modes.has(cid)) throw new Error('Could not verify DM encryption settings');
    }
    const mode = modes.get(cid);
    const pinned = await storageOperation('readonly', store => store.get(pinName(cid)));
    if (epoch !== generation) throw new Error('Account changed while checking encryption');
    if (pinned && pinned !== mode.keyId) throw new Error('DM encryption settings changed. Sending is blocked; verify the key with your contact');
    return mode;
  }

  async function seal(cid, sender, text, replyTo = null) {
    if (!validId(cid) || !validId(sender) || typeof text !== 'string' || !text.trim() || encoder.encode(text).length > 5000) throw new Error('Message must contain between 1 and 5000 UTF-8 bytes');
    const epoch = generation;
    const mode = await modeFor(cid);
    if (epoch !== generation) throw new Error('Account changed while encrypting');
    if (!mode.keyId) return text;
    const key = await getKey(cid, mode.keyId);
    if (!key) throw new Error('Unlock this encrypted DM with its key before sending');
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const textBytes = encoder.encode(text);
    const payload = new Uint8Array(9 + textBytes.length);
    payload[0] = 1;
    new DataView(payload.buffer).setBigUint64(1, BigInt(replyId(replyTo) || 0));
    payload.set(textBytes, 9); textBytes.fill(0);
    const cipher = new Uint8Array(await crypto.subtle.encrypt({name: 'AES-GCM', iv, additionalData: aad(cid, sender, mode.keyId), tagLength: 128}, key, payload));
    payload.fill(0);
    if (epoch !== generation) throw new Error('Account changed while encrypting');
    const body = `${PREFIX}${mode.keyId}:${encode64(iv)}:${encode64(cipher)}`;
    if (body.length > 8192) throw new Error('Encrypted message is too large');
    return body;
  }

  async function unseal(cid, sender, body, expectedReply, checkReply = true) {
    if (!validId(cid) || !validId(sender) || !isEnvelope(body) || body.length > 8192) throw new Error('Invalid encrypted text');
    const parts = body.split(':');
    if (parts.length !== 4 || !/^[0-9a-f]{64}$/.test(parts[1])) throw new Error('Invalid encrypted text');
    const iv = decode64(parts[2]), cipher = decode64(parts[3]);
    if (iv.length !== 12 || cipher.length < 26 || cipher.length > 6000) throw new Error('Invalid encrypted text');
    const key = await getKey(cid, parts[1]);
    if (!key) throw new Error('DM key is unavailable on this device');
    const cacheKey = `${cid}:${sender}:${checkReply ? replyId(expectedReply) : 'preview'}:${body}`;
    if (decrypted.has(cacheKey)) return decrypted.get(cacheKey);
    const epoch = generation;
    const bytes = new Uint8Array(await crypto.subtle.decrypt({name: 'AES-GCM', iv, additionalData: aad(cid, sender, parts[1]), tagLength: 128}, key, cipher));
    let text, reply;
    try {
      if (bytes.length < 10 || bytes.length > 5009 || bytes[0] !== 1) throw new Error('Invalid encrypted text');
      reply = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigUint64(1);
      if (reply > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Invalid encrypted reply');
      text = new TextDecoder('utf-8', {fatal: true}).decode(bytes.subarray(9));
    }
    finally { bytes.fill(0); }
    if (epoch !== generation || !text.trim() || (checkReply && Number(reply) !== (replyId(expectedReply) || 0))) throw new Error('Encrypted text could not be authenticated');
    boundedSet(decrypted, cacheKey, text);
    return text;
  }

  async function decodeData(data, contextCid = null, remembered = false) {
    if (!data || typeof data !== 'object') return data;
    if (!remembered) remember(data);
    if (Array.isArray(data)) return Promise.all(data.map(value => decodeData(value, contextCid, true)));
    const result = {...data};
    const cid = data.scope === 'direct' ? data.scope_id : data.conversation_id || contextCid;
    const isMessage = data.scope === 'direct' && validId(data.id) && validId(data.user_id);
    if (validId(data.id) && validId(data.user_id) && typeof data.scope === 'string') boundedSet(messages, data.id, {cid: data.scope === 'direct' ? cid : null, replyTo: data.reply_to_id, encrypted: isEnvelope(data.body)}, 512);
    if (isEnvelope(data.body)) {
      result.encryption_state = 'locked';
      result.body = 'Encrypted text · unlock this DM to read it';
      try {
        result.body = await unseal(cid, data.user_id, data.body, data.reply_to_id, isMessage);
        result.encryption_state = 'encrypted';
      } catch (error) {
        if (error.message !== 'DM key is unavailable on this device') result.body = 'Encrypted text could not be authenticated';
      }
    }
    for (const [name, value] of Object.entries(data)) {
      if (value && typeof value === 'object') result[name] = await decodeData(value, cid, true);
    }
    return result;
  }

  async function encodeRequest({method = 'GET', path, body}) {
    if (method !== 'POST' || !body || typeof body.body !== 'string') return body;
    const direct = path.match(/^\/conversation\/(\d+)\/messages$/);
    const edit = path.match(/^\/edit_message\/(\d+)$/);
    const meta = edit ? messages.get(Number(edit[1])) : null;
    if (edit && !meta) throw new Error('Reload the message before editing it');
    const cid = direct ? Number(direct[1]) : meta?.cid;
    if (!cid) return body;
    return {...body, body: await seal(cid, userId, body.body, direct ? body.reply_to_id : meta.replyTo)};
  }

  const activeEncrypted = () => {
    const match = location.hash.match(/^#\/?dm\/(\d+)/);
    return !!(match && modes.get(Number(match[1]))?.keyId);
  };
  const refreshElements = () => document.querySelectorAll('pw-dm-security').forEach(element => element.render());
  const fingerprint = id => id.match(/.{1,8}/g)?.join(' ') || '';

  async function openKeyDialog(cid) {
    try {
      const mode = await modeFor(cid);
      const epoch = generation;
      const content = document.createElement('div'); content.className = 'dm-key-setup';
      const description = document.createElement('p');
      description.textContent = 'Encrypted text uses a shared DM key. Exchange the key in person or through another trusted, encrypted channel. Never send it in this chat. Save it safely: a password reset cannot recover it.';
      const limits = document.createElement('p'); limits.className = 'muted';
      limits.textContent = 'Text only. Earlier messages, calls, attachments, and metadata are outside this mode. Links stay as text. This mode has no forward secrecy. Once enabled, this DM cannot return to plaintext or gain members.';
      const label = document.createElement('label'); label.textContent = mode.keyId ? 'Enter your saved DM key' : 'Generate a key or enter one shared by your contact';
      const input = document.createElement('input'); input.type = 'password'; input.autocomplete = 'off'; input.spellcheck = false; input.setAttribute('aria-label', 'DM encryption key'); input.maxLength = 50;
      const reveal = document.createElement('button'); reveal.type = 'button'; reveal.className = 'btn secondary'; reveal.textContent = 'Show key';
      reveal.onclick = () => { input.type = input.type === 'password' ? 'text' : 'password'; reveal.textContent = input.type === 'password' ? 'Show key' : 'Hide key'; };
      const keyRow = document.createElement('div'); keyRow.className = 'dm-key-input'; keyRow.append(input, reveal); label.append(keyRow);
      const check = document.createElement('input'); check.type = 'checkbox';
      const checkLabel = document.createElement('label'); checkLabel.className = 'dm-key-confirm'; checkLabel.append(check, document.createTextNode('I saved this key and will verify its fingerprint with my contact through a trusted channel.'));
      const status = document.createElement('p'); status.className = 'dm-key-status'; status.setAttribute('role', 'status');
      if (mode.keyId) status.textContent = 'Expected fingerprint: ' + fingerprint(mode.keyId);
      const buttons = document.createElement('div'); buttons.className = 'dm-key-actions';
      const generate = document.createElement('button'); generate.type = 'button'; generate.className = 'btn secondary'; generate.textContent = 'Generate a new key'; generate.hidden = !!mode.keyId;
      const save = document.createElement('button'); save.type = 'button'; save.className = 'btn'; save.textContent = mode.keyId ? 'Unlock on this device' : 'Enable encrypted text'; save.disabled = !mode.keyId;
      check.onchange = () => { save.disabled = !check.checked && !mode.keyId; };
      generate.onclick = async () => {
        try {
          const bundle = await generateSecret();
          if (epoch !== generation || !content.isConnected) return;
          input.value = bundle.secret; input.type = 'text'; reveal.textContent = 'Hide key';
          status.textContent = 'Fingerprint: ' + fingerprint(bundle.keyId);
          check.checked = false; save.disabled = true;
        } catch (error) { status.textContent = error.message; }
      };
      input.oninput = () => { check.checked = false; save.disabled = !mode.keyId; };
      buttons.append(generate, save);
      content.append(description, limits, label, status, checkLabel, buttons);
      const dialog = hooks.showDialog({title: mode.keyId ? 'Unlock encrypted DM' : 'Encrypt this private DM', subtitle: 'Keep the key private and backed up', content, actions: []});
      dialog.backdrop.addEventListener('plainwire:dialog-close', () => { input.value = ''; }, {once: true});
      save.onclick = async () => {
        save.disabled = true; generate.disabled = true;
        try {
          const bundle = await importSecret(input.value);
          if (mode.keyId && bundle.keyId !== mode.keyId) throw new Error('This key does not match the DM fingerprint');
          if (epoch !== generation || !content.isConnected) return;
          await saveKey(cid, bundle, !!mode.keyId);
          if (!mode.keyId) {
            const data = await hooks.request('POST', `/conversation/${cid}/encryption`, {key_id: bundle.keyId});
            remember(data);
            await saveKey(cid, bundle);
          }
          input.value = '';
          hooks.closeDialog();
          refreshElements(); hooks.refresh(cid);
          hooks.toast('Encrypted text unlocked on this device. Verify the fingerprint with your contact.');
        } catch (error) { status.textContent = error.message; save.disabled = !mode.keyId && !check.checked; generate.disabled = false; }
      };
    } catch (error) { hooks.toast(error.message); }
  }

  function configure(options) {
    hooks = options;
    if (!customElements.get('pw-dm-security')) customElements.define('pw-dm-security', class extends HTMLElement {
      static get observedAttributes() { return ['data-conversation', 'data-key-id']; }
      connectedCallback() { this.render(); }
      attributeChangedCallback() { if (this.isConnected) this.render(); }
      render() {
        const cid = Number(this.getAttribute('data-conversation'));
        if (!validId(cid)) return;
        const keyId = this.getAttribute('data-key-id') || modes.get(cid)?.keyId || '';
        remember({id: cid, e2ee_key_id: keyId});
        const button = document.createElement('button'); button.type = 'button'; button.className = 'dm-security-button';
        button.textContent = modes.get(cid)?.keyId ? 'Encrypted text · unlock / verify key' : 'Enable encrypted text';
        button.onclick = () => openKeyDialog(cid);
        const help = document.createElement('small'); help.textContent = modes.get(cid)?.keyId ? 'New text requires the DM key. Earlier messages are unchanged.' : 'Optional for private, accepted DMs';
        this.replaceChildren(button, help);
      }
    });
  }

  Object.defineProperty(window, 'PlainwireE2EE', {value: Object.freeze({
    configure, setUser, remember, decodeData, encodeRequest, activeEncrypted, refreshElements,
    generateSecret, importSecret, seal, unseal, saveKey, getKey
  })});
})();
