(() => {
  'use strict';

  const PREFIX = 'pw-e2ee-v2:';
  const encoder = new TextEncoder();
  const modes = new Map();
  const messages = new Map();
  const keys = new Map();
  const decrypted = new Map();
  const policyLoads = new Map(), deviceLocks = new Map(), deviceEpochs = new Map(), drafts = new Map();
  let userId = null, generation = 0, database, hooks;
  let deviceChannel;
  try { deviceChannel = new BroadcastChannel('plainwire-e2ee-device-v1'); } catch (_) {}

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
  const isEnvelope = value => typeof value === 'string' && value.startsWith('pw-e2ee-');
  const aad = (cid, sender, keyId, nonce) => encoder.encode(nonce
    ? `plainwire-dm-v2\n${cid}\n${sender}\n${keyId}\n${nonce}` : `plainwire-dm-v1\n${cid}\n${sender}\n${keyId}`);
  const nonceOf = body => body?.startsWith(PREFIX) ? body.split(':')[2] : null;
  const deviceToken = cid => `${generation}:${deviceEpochs.get(cid) || 0}`;
  const applyDeviceState = (cid, locked) => {
    deviceEpochs.set(cid, (deviceEpochs.get(cid) || 0) + 1);
    deviceLocks.set(cid, locked); keys.clear(); decrypted.clear();
  };
  const notifyDeviceState = (cid, locked) => deviceChannel?.postMessage({userId, cid, locked});
  if (deviceChannel) deviceChannel.onmessage = event => {
    const data = event.data;
    if (!hooks || !data || data.userId !== userId || !validId(data.cid) || typeof data.locked !== 'boolean') return;
    applyDeviceState(data.cid, data.locked);
    refreshElements(); hooks.refresh(data.cid);
  };
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
  const lockName = cid => `lock:${userId}:${cid}`;
  const keyName = (cid, keyId) => `${userId}:${cid}:${keyId}`;
  async function saveKey(cid, bundle, pinKey = true) {
    requireSession();
    if (!validId(cid)) throw new Error('Invalid conversation');
    const epoch = generation;
    const pinned = await storageOperation('readonly', store => store.get(pinName(cid)));
    if (epoch !== generation) throw new Error('Account changed while saving encryption');
    if (pinned && (typeof pinned === 'string' ? pinned : pinned.keyId) !== bundle.keyId) throw new Error('The saved DM fingerprint does not match');
    const pin = pinName(cid), name = keyName(cid, bundle.keyId);
    await storageOperation('readwrite', store => {
      if (pinKey) store.put({keyId: bundle.keyId, revision: modes.get(cid)?.revision || 0}, pin);
      store.put(false, lockName(cid));
      return store.put(bundle.key, name);
    });
    if (epoch !== generation) throw new Error('Account changed while saving encryption');
    applyDeviceState(cid, false);
    keys.set(name, bundle.key);
    notifyDeviceState(cid, false);
  }

  async function getKey(cid, keyId, ignoreLock = false) {
    requireSession();
    const epoch = generation;
    if (!deviceLocks.has(cid)) {
      const locked = await storageOperation('readonly', store => store.get(lockName(cid)));
      if (epoch !== generation) throw new Error('Account changed while loading encryption');
      deviceLocks.set(cid, locked === true);
    }
    if (!ignoreLock && deviceLocks.get(cid)) return null;
    const name = keyName(cid, keyId);
    if (keys.has(name)) return keys.get(name);
    const loading = storageOperation('readonly', store => store.get(name)).then(key =>
      key && key.algorithm?.name === 'AES-GCM' && key.algorithm.length === 256 && key.extractable === false ? key : null);
    keys.set(name, loading);
    try {
      const key = await loading;
      if (epoch !== generation) throw new Error('Account changed while loading encryption');
      if (!key && keys.get(name) === loading) keys.delete(name);
      return key;
    } catch (error) { if (keys.get(name) === loading) keys.delete(name); throw error; }
  }

  function setUser(id) {
    const next = validId(id) ? id : null;
    if (next === userId) return;
    for (const cid of drafts.keys()) hooks?.draftChanged(cid, false);
    userId = next; generation++;
    keys.clear(); modes.clear(); messages.clear(); decrypted.clear(); policyLoads.clear(); deviceLocks.clear(); deviceEpochs.clear(); drafts.clear();
  }

  function remember(data) {
    if (!data || typeof data !== 'object') return;
    if (Array.isArray(data)) { data.forEach(remember); return; }
    const cid = data.conversation_id || data.id;
    if (validId(cid) && typeof data.e2ee_key_id === 'string') {
      const previous = modes.get(cid);
      const revision = Number.isSafeInteger(data.e2ee_revision) ? data.e2ee_revision : data.e2ee_key_id ? 1 : 0;
      if (!previous || revision >= previous.revision) {
        const next = {keyId: data.e2ee_key_id, enabled: data.e2ee_enabled ?? !!data.e2ee_key_id, revision,
          requester: data.e2ee_disable_requested_by || 0, memberCount: data.member_count ?? data.members?.length ?? previous?.memberCount};
        if (previous?.keyId && next.keyId !== previous.keyId) next.invalid = true;
        if (previous && revision === previous.revision && (next.keyId !== previous.keyId || next.enabled !== previous.enabled)) next.invalid = true;
        boundedSet(modes, cid, next, 512);
      }
    }
    Object.values(data).forEach(value => { if (value && typeof value === 'object') remember(value); });
  }

  async function modeFor(cid, fresh = false) {
    requireSession();
    const epoch = generation;
    if (fresh || !modes.has(cid)) {
      if (!policyLoads.has(cid)) {
        const loading = hooks.request('GET', `/conversation/${cid}`).finally(() => { if (policyLoads.get(cid) === loading) policyLoads.delete(cid); });
        policyLoads.set(cid, loading);
      }
      const data = await policyLoads.get(cid);
      if (epoch !== generation) throw new Error('Account changed while checking encryption');
      remember(data);
      if (!modes.has(cid)) throw new Error('Could not verify DM encryption settings');
    }
    const mode = modes.get(cid);
    const pinned = await storageOperation('readonly', store => store.get(pinName(cid)));
    if (epoch !== generation) throw new Error('Account changed while checking encryption');
    if (mode.invalid || (pinned && ((typeof pinned === 'string' ? pinned : pinned.keyId) !== mode.keyId || (pinned.revision || 0) > mode.revision))) throw new Error('DM encryption settings changed unexpectedly. Sending is blocked; refresh and verify with your contact');
    if (mode.keyId && (!pinned || (pinned.revision || 0) < mode.revision)) {
      await storageOperation('readwrite', store => store.put({keyId: mode.keyId, revision: mode.revision}, pinName(cid)));
    }
    return mode;
  }

  async function seal(cid, sender, text, replyTo = null, force = false, existingNonce = null) {
    if (!validId(cid) || !validId(sender) || typeof text !== 'string' || !text.trim() || encoder.encode(text).length > 5000) throw new Error('Message must contain between 1 and 5000 UTF-8 bytes');
    const epoch = generation, token = deviceToken(cid);
    const mode = await modeFor(cid);
    if (epoch !== generation) throw new Error('Account changed while encrypting');
    if (!mode.enabled && !force) return text;
    const key = await getKey(cid, mode.keyId);
    if (!key) throw new Error('Unlock this encrypted DM with its key before sending');
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const nonce = existingNonce || encode64(crypto.getRandomValues(new Uint8Array(16)));
    if (decode64(nonce).length !== 16) throw new Error('Invalid encrypted message identity');
    const textBytes = encoder.encode(text);
    const payload = new Uint8Array(9 + textBytes.length);
    payload[0] = 2;
    new DataView(payload.buffer).setBigUint64(1, BigInt(replyId(replyTo) || 0));
    payload.set(textBytes, 9); textBytes.fill(0);
    let cipher;
    try { cipher = new Uint8Array(await crypto.subtle.encrypt({name: 'AES-GCM', iv, additionalData: aad(cid, sender, mode.keyId, nonce), tagLength: 128}, key, payload)); }
    finally { payload.fill(0); }
    if (epoch !== generation || token !== deviceToken(cid)) throw new Error('Device locked or account changed while encrypting');
    const body = `${PREFIX}${mode.keyId}:${nonce}:${encode64(iv)}:${encode64(cipher)}`;
    if (body.length > 8192) throw new Error('Encrypted message is too large');
    return body;
  }

  async function unseal(cid, sender, body, expectedReply, checkReply = true) {
    const epoch = generation, token = deviceToken(cid);
    if (!validId(cid) || !validId(sender) || !isEnvelope(body) || body.length > 8192) throw new Error('Invalid encrypted text');
    const parts = body.split(':');
    const modern = parts[0] === 'pw-e2ee-v2';
    if ((modern ? parts.length !== 5 : parts[0] !== 'pw-e2ee-v1' || parts.length !== 4) || !/^[0-9a-f]{64}$/.test(parts[1])) throw new Error('Invalid encrypted text');
    const nonce = modern ? parts[2] : null;
    if (nonce && decode64(nonce).length !== 16) throw new Error('Invalid encrypted message identity');
    const iv = decode64(parts[modern ? 3 : 2]), cipher = decode64(parts[modern ? 4 : 3]);
    if (iv.length !== 12 || cipher.length < 26 || cipher.length > 6000) throw new Error('Invalid encrypted text');
    const key = await getKey(cid, parts[1]);
    if (!key) throw new Error('DM key is unavailable on this device');
    if (epoch !== generation || token !== deviceToken(cid)) throw new Error('Device locked or account changed while decrypting');
    const cacheKey = `${cid}:${sender}:${checkReply ? replyId(expectedReply) : 'preview'}:${body}`;
    if (decrypted.has(cacheKey)) return decrypted.get(cacheKey);
    if (epoch !== generation || token !== deviceToken(cid)) throw new Error('Device locked or account changed while decrypting');
    const bytes = new Uint8Array(await crypto.subtle.decrypt({name: 'AES-GCM', iv, additionalData: aad(cid, sender, parts[1], nonce), tagLength: 128}, key, cipher));
    let text, reply;
    try {
      if (bytes.length < 10 || bytes.length > 5009 || bytes[0] !== (modern ? 2 : 1)) throw new Error('Invalid encrypted text');
      reply = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigUint64(1);
      if (reply > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Invalid encrypted reply');
      text = new TextDecoder('utf-8', {fatal: true}).decode(bytes.subarray(9));
    }
    finally { bytes.fill(0); }
    if (epoch !== generation || token !== deviceToken(cid) || !text.trim() || (checkReply && Number(reply) !== (replyId(expectedReply) || 0))) throw new Error('Encrypted text could not be authenticated');
    boundedSet(decrypted, cacheKey, text);
    return text;
  }

  async function decodeData(data, contextCid = null, remembered = false, epoch = generation) {
    if (!data || typeof data !== 'object') return data;
    if (!remembered) remember(data);
    if (Array.isArray(data)) {
      const result = await Promise.all(data.map(value => decodeData(value, contextCid, true, epoch)));
      if (epoch !== generation) throw new Error('Account changed while loading messages');
      return result;
    }
    const result = {...data};
    const cid = data.scope === 'direct' ? data.scope_id : data.conversation_id || contextCid;
    const isMessage = data.scope === 'direct' && validId(data.id) && validId(data.user_id);
    if (validId(data.id) && validId(data.user_id) && typeof data.scope === 'string') boundedSet(messages, data.id, {cid: data.scope === 'direct' ? cid : null, sender: data.user_id, replyTo: data.reply_to_id, body: data.body, encrypted: isEnvelope(data.body)}, 512);
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
      if (value && typeof value === 'object') result[name] = await decodeData(value, cid, true, epoch);
    }
    if (epoch !== generation) throw new Error('Account changed while loading messages');
    if (isEnvelope(data.body) && deviceLocks.get(cid)) {
      result.encryption_state = 'locked'; result.body = 'Encrypted text · unlock this DM to read it';
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
    const mode = await modeFor(cid);
    const force = !!(direct ? typeof body.encrypt_message === 'boolean' ? body.encrypt_message : drafts.get(cid) : meta.encrypted);
    return {...body, encryption_revision: mode.revision,
      body: await seal(cid, userId, body.body, direct ? body.reply_to_id : meta.replyTo, force, direct ? null : nonceOf(meta.body))};
  }

  const activeEncrypted = () => {
    const match = location.hash.match(/^#\/?dm\/(\d+)/);
    return !!(match && (modes.get(Number(match[1]))?.enabled || drafts.get(Number(match[1]))));
  };
  const refreshElements = () => document.querySelectorAll('pw-dm-security, pw-message-security').forEach(element => element.render());
  const fingerprint = id => id.match(/.{1,8}/g)?.join(' ') || '';

  async function openKeyDialog(cid, enableWide = true) {
    try {
      const epoch = generation;
      const mode = await modeFor(cid, true);
      if (epoch !== generation) return;
      const content = document.createElement('div'); content.className = 'dm-key-setup';
      const description = document.createElement('p');
      description.textContent = 'Encrypted text uses a shared DM key. Exchange the key in person or through another trusted, encrypted channel. Never send it in this chat. Save it safely: a password reset cannot recover it.';
      const limits = document.createElement('p'); limits.className = 'muted';
      limits.textContent = 'Text only. Files, calls and earlier plaintext are outside this protection. There is no forward secrecy. Turning DM encryption off needs both people’s approval and keeps locked history encrypted.';
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
      const save = document.createElement('button'); save.type = 'button'; save.className = 'btn'; save.textContent = mode.keyId ? 'Unlock on this device' : enableWide ? 'Enable encrypted text' : 'Set up message locks'; save.disabled = !mode.keyId;
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
      const saved = mode.keyId && await getKey(cid, mode.keyId, true);
      if (epoch !== generation) return;
      if (saved) {
        const useSaved = document.createElement('button'); useSaved.type = 'button'; useSaved.className = 'btn'; useSaved.textContent = 'Unlock saved key';
        useSaved.onclick = async () => {
          useSaved.disabled = true;
          try {
            if (epoch !== generation) return;
            await saveKey(cid, {key: saved, keyId: mode.keyId});
            if (epoch !== generation) return;
            hooks.closeDialog(); refreshElements(); hooks.refresh(cid);
          } catch (error) { status.textContent = error.message; useSaved.disabled = false; }
        };
        buttons.prepend(useSaved);
      }
      const dialog = hooks.showDialog({title: mode.keyId ? 'Unlock encrypted text' : enableWide ? 'Encrypt this private DM' : 'Lock individual messages', subtitle: 'Keep the key private and backed up', content, actions: []});
      dialog.backdrop.addEventListener('plainwire:dialog-close', () => { input.value = ''; }, {once: true});
      save.onclick = async () => {
        save.disabled = true; generate.disabled = true;
        try {
          const bundle = await importSecret(input.value);
          if (mode.keyId && bundle.keyId !== mode.keyId) throw new Error('This key does not match the DM fingerprint');
          if (epoch !== generation || !content.isConnected) return;
          await saveKey(cid, bundle, !!mode.keyId);
          if (epoch !== generation) return;
          if (!mode.keyId) {
            const data = await hooks.request('POST', `/conversation/${cid}/encryption`, {key_id: bundle.keyId, enabled: enableWide});
            if (epoch !== generation) return;
            remember(data);
            await saveKey(cid, bundle);
          }
          if (epoch !== generation) return;
          if (!enableWide) setDraftLock(cid, true);
          input.value = '';
          hooks.closeDialog();
          refreshElements(); hooks.refresh(cid);
          hooks.toast('Encrypted text unlocked on this device. Verify the fingerprint with your contact.');
        } catch (error) { status.textContent = error.message; save.disabled = !mode.keyId && !check.checked; generate.disabled = false; }
      };
    } catch (error) { hooks.toast(error.message); }
  }

  const buttonFor = (label, action, className = 'btn secondary') => {
    const button = document.createElement('button'); button.type = 'button'; button.className = className; button.textContent = label;
    button.onclick = async () => {
      button.disabled = true;
      try { await action(); } catch (error) { hooks.toast(error.message); }
      finally { if (button.isConnected) button.disabled = false; }
    };
    return button;
  };

  function setDraftLock(cid, enabled) {
    if (enabled) drafts.set(cid, true); else drafts.delete(cid);
    hooks.draftChanged(cid, enabled);
    refreshElements();
  }

  async function lockDevice(cid) {
    const epoch = generation;
    applyDeviceState(cid, true);
    await storageOperation('readwrite', store => store.put(true, lockName(cid)));
    if (epoch !== generation) return;
    notifyDeviceState(cid, true);
    hooks.closeDialog(); refreshElements(); hooks.refresh(cid);
    hooks.toast('Encrypted text is locked on this device. Your saved key is kept.');
  }

  async function openSettings(cid) {
    const epoch = generation;
    const mode = await modeFor(cid, true);
    if (epoch !== generation) return;
    const content = document.createElement('div'); content.className = 'dm-key-setup';
    const status = document.createElement('p'); status.textContent = mode.enabled ? 'All new text is encrypted.' : 'DM encryption is off. You can still lock individual text messages.';
    const privacy = document.createElement('p'); privacy.className = 'muted';
    privacy.textContent = 'Turning encryption off affects new text only. Both people must approve. Locked history stays encrypted; only its sender can remove a message lock while DM encryption is off. This reveals that text to the relay.';
    const identity = document.createElement('p'); identity.className = 'dm-key-status'; identity.textContent = 'Fingerprint: ' + fingerprint(mode.keyId);
    const actions = document.createElement('div'); actions.className = 'dm-key-actions';
    const change = async (action) => {
      if (epoch !== generation) return;
      const data = await hooks.request('POST', `/conversation/${cid}/encryption/disable`, {action, revision: mode.revision});
      if (epoch !== generation) return;
      remember(data); hooks.closeDialog(); refreshElements(); hooks.refresh(cid);
    };
    if (mode.enabled) {
      if (!mode.requester) actions.append(buttonFor('Request turning off', () => change('request')));
      else {
        const pending = document.createElement('p'); pending.textContent = mode.requester === userId ? 'Waiting for your contact to approve turning encryption off.' : 'Your contact asked to turn DM encryption off.'; content.append(pending);
        if (mode.requester !== userId) actions.append(buttonFor('Approve turning off', () => change('approve'), 'btn danger'));
        actions.append(buttonFor('Keep encryption on', () => change('cancel')));
      }
    } else {
      actions.append(buttonFor('Turn DM encryption on', async () => {
        if (epoch !== generation) return;
        if (!(await getKey(cid, mode.keyId))) { hooks.closeDialog(); return openKeyDialog(cid); }
        if (epoch !== generation) return;
        const data = await hooks.request('POST', `/conversation/${cid}/encryption`, {key_id: mode.keyId, enabled: true});
        if (epoch !== generation) return;
        remember(data); hooks.closeDialog(); refreshElements(); hooks.refresh(cid);
      }));
    }
    actions.append(buttonFor('Unlock on this device', () => { hooks.closeDialog(); return openKeyDialog(cid); }));
    actions.append(buttonFor('Lock this device', () => lockDevice(cid)));
    content.prepend(status, privacy, identity); content.append(actions);
    hooks.showDialog({title: 'DM encryption settings', subtitle: 'Choose how new text is sent', content, actions: []});
  }

  async function changeMessageLock(mid, lock) {
    const epoch = generation;
    const meta = messages.get(mid);
    if (!meta?.cid || meta.sender !== userId) throw new Error('Only the sender can change this message lock');
    const mode = await modeFor(meta.cid, true);
    if (epoch !== generation) return;
    if (!mode.keyId) { await openKeyDialog(meta.cid, false); return; }
    if (!lock && mode.enabled) throw new Error('Both people must turn DM encryption off before a message lock can be removed');
    if (!(await getKey(meta.cid, mode.keyId))) { await openKeyDialog(meta.cid, false); return; }
    const text = meta.encrypted ? await unseal(meta.cid, meta.sender, meta.body, meta.replyTo) : meta.body;
    if (epoch !== generation) return;
    const content = document.createElement('div'); content.className = 'dm-key-setup';
    const notice = document.createElement('p');
    notice.textContent = lock ? 'Lock this text message for both people. Existing plaintext copies, backups and screenshots cannot be erased.' : 'Remove this message’s encryption and publish its text to the relay. It can then appear in search, previews and moderation. This affects only your selected message.';
    const actions = document.createElement('div'); actions.className = 'dm-key-actions';
    actions.append(buttonFor(lock ? 'Lock this message' : 'Remove lock and publish text', async () => {
      if (epoch !== generation) return;
      const body = lock ? await seal(meta.cid, userId, text, meta.replyTo, true) : text;
      if (epoch !== generation) return;
      const data = await hooks.request('POST', `/message/${mid}/encryption`, {action: lock ? 'lock' : 'unlock', body, expected_body: meta.body, encryption_revision: mode.revision});
      if (epoch !== generation) return;
      await decodeData(data); hooks.closeDialog(); hooks.refresh(meta.cid);
    }, lock ? 'btn' : 'btn danger'));
    content.append(notice, actions);
    hooks.showDialog({title: lock ? 'Lock message' : 'Remove message lock', subtitle: lock ? 'Encrypt selected text' : 'This reveals the text to the server', content, actions: []});
  }

  function configure(options) {
    hooks = options;
    if (!customElements.get('pw-dm-security')) customElements.define('pw-dm-security', class extends HTMLElement {
      static get observedAttributes() { return ['data-conversation', 'data-key-id', 'data-revision', 'data-enabled', 'data-requester']; }
      connectedCallback() { this.render(); }
      attributeChangedCallback() { if (this.isConnected) this.render(); }
      render() {
        const cid = Number(this.getAttribute('data-conversation'));
        if (!validId(cid)) return;
        const keyId = this.getAttribute('data-key-id') || '';
        remember({id: cid, e2ee_key_id: keyId, e2ee_enabled: this.getAttribute('data-enabled') === 'true', e2ee_revision: Number(this.getAttribute('data-revision') || 0), e2ee_disable_requested_by: Number(this.getAttribute('data-requester') || 0)});
        const mode = modes.get(cid);
        const button = document.createElement('button'); button.type = 'button'; button.className = 'dm-security-button';
        button.textContent = mode?.keyId ? `DM encryption: ${mode.enabled ? 'On' : 'Off'}${mode.requester ? ' · approval pending' : ''}` : 'Enable encrypted text';
        button.onclick = () => (mode?.keyId ? openSettings(cid) : openKeyDialog(cid)).catch(error => hooks.toast(error.message));
        const single = buttonFor(mode?.enabled ? 'All new text locked' : drafts.get(cid) ? 'Message lock: On' : 'Lock this message', async () => {
          if (!mode?.keyId) return openKeyDialog(cid, false);
          if (!(await getKey(cid, mode.keyId))) return openKeyDialog(cid, false);
          setDraftLock(cid, !drafts.get(cid));
        }, 'dm-security-button');
        single.disabled = !!mode?.enabled; single.setAttribute('aria-pressed', String(!!mode?.enabled || !!drafts.get(cid)));
        const help = document.createElement('small'); help.textContent = mode?.enabled ? 'Encrypted text; history stays locked when turned off.' : 'Individual message locks use your shared DM key.';
        this.replaceChildren(button, single, help);
      }
    });
    if (!customElements.get('pw-message-security')) customElements.define('pw-message-security', class extends HTMLElement {
      static get observedAttributes() { return ['data-mid', 'data-state']; }
      connectedCallback() { this.render(); }
      attributeChangedCallback() { if (this.isConnected) this.render(); }
      render() {
        const mid = Number(this.getAttribute('data-mid')), meta = messages.get(mid);
        if (!meta?.cid || meta.sender !== userId) { this.replaceChildren(); return; }
        const button = buttonFor(meta.encrypted ? 'Remove lock' : 'Lock message', () => changeMessageLock(mid, !meta.encrypted), 'msg-action');
        button.disabled = this.getAttribute('data-state') === 'locked' || (meta.encrypted && !!modes.get(meta.cid)?.enabled);
        if (button.disabled) button.title = meta.encrypted && modes.get(meta.cid)?.enabled ? 'Turn DM encryption off with your contact before removing a lock' : 'Unlock on this device first';
        this.replaceChildren(button);
      }
    });
  }

  Object.defineProperty(window, 'PlainwireE2EE', {value: Object.freeze({
    configure, setUser, remember, decodeData, encodeRequest, activeEncrypted, refreshElements,
    generateSecret, importSecret, seal, unseal, saveKey, getKey, lockDevice, changeMessageLock
  })});
})();
