const API = '/api/bot/v1';
const MAX_RESPONSE = 2 * 1024 * 1024;
const MAX_REQUEST = 64 * 1024;

function loopback(host) {
  const h = host.toLowerCase();
  if (h === 'localhost' || h === '[::1]' || h === '::1') return true;
  // Do not use a prefix check here. A DNS name such as 127.attacker.example
  // is not loopback and must never be allowed to receive a bot token over HTTP.
  const parts = h.split('.');
  if (parts.length !== 4 || parts.some(part => !/^(?:0|[1-9]\d{0,2})$/.test(part))) return false;
  const octets = parts.map(Number);
  return octets[0] === 127 && octets.every(octet => octet >= 0 && octet <= 255);
}

export class PlainwireAPIError extends Error {
  constructor(status, body) {
    super(`Plainwire API returned HTTP ${status}`);
    this.name = 'PlainwireAPIError';
    this.status = status;
    this.body = body;
  }
}

export class PlainwireBot {
  constructor(baseUrl, token, { timeoutMs = 15000, maxResponseBytes = MAX_RESPONSE, fetchImpl = globalThis.fetch } = {}) {
    if (typeof fetchImpl !== 'function') throw new TypeError('fetch is unavailable');
    const u = new URL(baseUrl);
    if (u.username || u.password || u.search || u.hash) throw new TypeError('invalid Plainwire base URL');
    if (u.protocol !== 'https:' && !(u.protocol === 'http:' && loopback(u.hostname))) {
      throw new TypeError('Plainwire bots require HTTPS except on loopback');
    }
    if (typeof token !== 'string' || !token.startsWith('pwb_') || token.length < 16 || token.length > 256 || /[\r\n]/.test(token)) {
      throw new TypeError('invalid Plainwire bot token');
    }
    this.base = u.href.replace(/\/$/, '');
    this.token = token;
    this.timeoutMs = timeoutMs;
    this.maxResponseBytes = maxResponseBytes;
    this.fetch = fetchImpl;
  }

  async request(method, path, body) {
    if (typeof path !== 'string' || !path.startsWith('/') || path.includes('://') || /[\r\n]/.test(path)) throw new TypeError('invalid API path');
    let payload;
    if (body !== undefined) {
      payload = JSON.stringify(body);
      if (new TextEncoder().encode(payload).byteLength > MAX_REQUEST) throw new RangeError('request body too large');
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res;
    try {
      res = await this.fetch(this.base + path, {
        method,
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          Authorization: `Bot ${this.token}`,
          Accept: 'application/json',
          'User-Agent': 'plainwire-js-bot/2.4',
          ...(payload === undefined ? {} : {'Content-Type': 'application/json'})
        },
        body: payload
      });
    } finally {
      clearTimeout(timer);
    }
    if (res.status >= 300 && res.status < 400) throw new PlainwireAPIError(res.status, 'redirect refused');
    const len = Number(res.headers?.get?.('content-length') || 0);
    if (len > this.maxResponseBytes) throw new RangeError('Plainwire response too large');
    const array = new Uint8Array(await res.arrayBuffer());
    if (array.byteLength > this.maxResponseBytes) throw new RangeError('Plainwire response too large');
    const text = new TextDecoder().decode(array);
    if (!res.ok) throw new PlainwireAPIError(res.status, text);
    return {status: res.status, text, json: () => JSON.parse(text)};
  }

  capabilities() { return this.request('GET', API); }
  me() { return this.request('GET', `${API}/me`); }
  server() { return this.request('GET', `${API}/server`); }
  channels() { return this.request('GET', `${API}/channels`); }
  messages(channelId, {before, after} = {}) {
    const q = new URLSearchParams(); if (before > 0) q.set('before', before); if (after > 0) q.set('after', after);
    return this.request('GET', `${API}/channels/${Number(channelId)}/messages${q.size ? `?${q}` : ''}`);
  }
  sendMessage(channelId, body, replyToId) { return this.request('POST', `${API}/channels/${Number(channelId)}/messages`, {body, ...(replyToId ? {reply_to_id: Number(replyToId)} : {})}); }
  deleteMessage(messageId) { return this.request('POST', `${API}/messages/${Number(messageId)}/delete`, {}); }
  toggleReaction(messageId, emoji) { return this.request('POST', `${API}/messages/${Number(messageId)}/reaction`, {emoji}); }
  editMessage(messageId, body) { return this.request('POST', `${API}/messages/${Number(messageId)}/edit`, {body}); }
  pinMessage(messageId, pinned = true) { return this.request('POST', `${API}/messages/${Number(messageId)}/pin`, {pinned: Boolean(pinned)}); }
  pins(channelId) { return this.request('GET', `${API}/channels/${Number(channelId)}/pins`); }
  messageContext(messageId) { return this.request('GET', `${API}/messages/${Number(messageId)}/context`); }
  createChannel(name, kind = 'text', categoryId) { return this.request('POST', `${API}/channels`, {name, kind, ...(categoryId ? {category_id: Number(categoryId)} : {})}); }
  updateChannel(channelId, patch = {}) { return this.request('POST', `${API}/channels/${Number(channelId)}/settings`, patch); }
  roles() { return this.request('GET', `${API}/roles`); }
  createRole(name, patch = {}) { return this.request('POST', `${API}/roles`, {name, ...patch}); }
  updateRole(roleId, patch = {}) { return this.request('POST', `${API}/roles/${Number(roleId)}`, patch); }
  deleteRole(roleId) { return this.request('DELETE', `${API}/roles/${Number(roleId)}`); }
  members({after, limit = 50} = {}) {
    const q = new URLSearchParams(); if (after > 0) q.set('after', after); q.set('limit', Math.max(1, Math.min(200, Number(limit) || 50)));
    return this.request('GET', `${API}/members?${q}`);
  }
  member(userId) { return this.request('GET', `${API}/members/${Number(userId)}`); }
  setMemberRoles(userId, roleIds = []) { return this.request('POST', `${API}/members/${Number(userId)}/roles`, {role_ids: roleIds.map(Number)}); }
  kickMember(userId) { return this.request('POST', `${API}/members/${Number(userId)}/kick`, {}); }
  banMember(userId, reason = '') { return this.request('POST', `${API}/members/${Number(userId)}/ban`, {reason}); }
  unbanMember(userId) { return this.request('POST', `${API}/members/${Number(userId)}/unban`, {}); }
  bans() { return this.request('GET', `${API}/bans`); }
  wires() { return this.request('GET', `${API}/wires`); }
  createWire(channelId, {maxUses = 0, expiresIn = 86400} = {}) { return this.request('POST', `${API}/wires`, {channel_id: Number(channelId), max_uses: Number(maxUses), expires_in: Number(expiresIn)}); }
  registerCommand(name, description = '', options = []) { return this.request('POST', `${API}/commands`, {name, description, options}); }
  syncCommands(commands = []) { return this.request('PUT', `${API}/commands`, {commands}); }
  commands() { return this.request('GET', `${API}/commands`); }
  deleteCommand(commandId) { return this.request('DELETE', `${API}/commands/${Number(commandId)}`); }
  claimCommands(limit = 10) { return this.request('GET', `${API}/commands/claims?limit=${Math.max(1, Math.min(50, Number(limit) || 10))}`); }
  deferCommand(id, claimToken, leaseMs = 120000) { return this.request('POST', `${API}/commands/claims/${Number(id)}/defer`, {claim_token: claimToken, lease_ms: Math.max(5000, Math.min(120000, Number(leaseMs) || 120000))}); }
  respondCommand(id, claimToken, body) { return this.request('POST', `${API}/commands/claims/${Number(id)}/respond`, {claim_token: claimToken, body}); }
  failCommand(id, claimToken, reason) { return this.request('POST', `${API}/commands/claims/${Number(id)}/fail`, {claim_token: claimToken, reason}); }

  commandWorker(handlers, options = {}) { return new CommandWorker(this, handlers, options); }
  listen(handlers, options = {}) { return this.commandWorker(handlers, options).run(); }
  options(claim) { return commandOptions(claim); }
  option(claim, name, fallback) { return commandOption(claim, name, fallback); }
}

export function commandOptions(claim = {}) {
  if (claim && typeof claim.options === 'object' && claim.options && !Array.isArray(claim.options)) return { ...claim.options };
  const args = claim && typeof claim.args === 'object' && claim.args && !Array.isArray(claim.args) ? claim.args : {};
  const rest = { ...args };
  delete rest.raw;
  delete rest.source;
  return rest;
}

export function commandOption(claim, name, fallback) {
  const options = commandOptions(claim);
  return Object.prototype.hasOwnProperty.call(options, name) ? options[name] : fallback;
}

export class CommandWorker {
  constructor(bot, handlers, {batchSize = 20, concurrency = 4, idleMs = 500, leaseMs = 120000, onError = console.error} = {}) {
    if (!(bot instanceof PlainwireBot)) throw new TypeError('bot must be a PlainwireBot');
    if (!(handlers instanceof Map) && (handlers === null || typeof handlers !== 'object')) throw new TypeError('handlers must be an object or Map');
    this.bot = bot;
    this.handlers = handlers;
    this.batchSize = Math.max(1, Math.min(50, Number(batchSize) || 20));
    this.concurrency = Math.max(1, Math.min(32, Number(concurrency) || 4));
    this.idleMs = Math.max(25, Number(idleMs) || 500);
    this.leaseMs = Math.max(5000, Math.min(120000, Number(leaseMs) || 120000));
    this.onError = typeof onError === 'function' ? onError : () => {};
  }

  handler(name) { return this.handlers instanceof Map ? this.handlers.get(name) : this.handlers[name]; }

  async handle(claim) {
    const handler = this.handler(claim.command);
    if (typeof handler !== 'function') {
      await this.bot.failCommand(claim.id, claim.claim_token, `No handler registered for /${claim.command}`);
      return;
    }
    try {
      await this.bot.deferCommand(claim.id, claim.claim_token, this.leaseMs);
      const result = await handler(claim, this.bot);
      const body = typeof result === 'string' ? result : result?.body;
      if (typeof body === 'string' && body.trim()) await this.bot.respondCommand(claim.id, claim.claim_token, body);
    } catch (error) {
      this.onError(error, claim);
      const reason = String(error?.message || error || 'command failed').slice(0, 240);
      try { await this.bot.failCommand(claim.id, claim.claim_token, reason); } catch (failure) { this.onError(failure, claim); }
    }
  }

  async runOnce() {
    const envelope = (await this.bot.claimCommands(this.batchSize)).json();
    const claims = Array.isArray(envelope?.data) ? envelope.data : [];
    let next = 0;
    const consume = async () => { while (next < claims.length) { const claim = claims[next++]; await this.handle(claim); } };
    await Promise.all(Array.from({length: Math.min(this.concurrency, claims.length)}, consume));
    return claims.length;
  }

  async run({signal} = {}) {
    while (!signal?.aborted) {
      let count = 0;
      try { count = await this.runOnce(); } catch (error) { this.onError(error); }
      if (!count && !signal?.aborted) await new Promise(resolve => {
        let timer;
        const done = () => { clearTimeout(timer); signal?.removeEventListener('abort', done); resolve(); };
        timer = setTimeout(done, this.idleMs);
        signal?.addEventListener('abort', done, {once: true});
      });
    }
  }
}
