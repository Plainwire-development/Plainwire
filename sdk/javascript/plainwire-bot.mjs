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
  constructor(status, body, retryAfterMs = 0) {
    super(`Plainwire API returned HTTP ${status}`);
    this.name = 'PlainwireAPIError';
    this.status = status;
    this.body = body;
    this.retryAfterMs = retryAfterMs;
    try { this.code = JSON.parse(body).error; } catch { this.code = undefined; }
  }
}

function boundedInteger(value, min, max, name) {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new RangeError(`invalid ${name}`);
  return value;
}

function retryDelay(res) {
  const header = res.headers?.get?.('retry-after');
  if (!header) return 1000;
  const seconds = Number(header);
  const ms = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(header) - Date.now();
  return Number.isFinite(ms) ? Math.max(25, ms) : 1000;
}

async function responseText(res, limit, signal) {
  const len = Number(res.headers?.get?.('content-length') || 0);
  if (len > limit) { await res.body?.cancel?.(); throw new RangeError('Plainwire response too large'); }
  const reader = res.body?.getReader?.();
  if (!reader) {
    const array = new Uint8Array(await res.arrayBuffer());
    signal.throwIfAborted();
    if (array.byteLength > limit) throw new RangeError('Plainwire response too large');
    return new TextDecoder().decode(array);
  }
  const decoder = new TextDecoder();
  let text = '', size = 0;
  try {
    while (true) {
      signal.throwIfAborted();
      const {done, value} = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new RangeError('Plainwire response too large');
      text += decoder.decode(value, {stream: true});
    }
    return text + decoder.decode();
  } finally {
    // Cancel unfinished streams on timeouts, malformed replies, and size limits.
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const done = () => { signal?.removeEventListener('abort', abort); resolve(); };
    const timer = setTimeout(done, ms);
    const abort = () => { clearTimeout(timer); signal.removeEventListener('abort', abort); reject(signal.reason); };
    signal?.addEventListener('abort', abort, {once: true});
  });
}

export class PlainwireBot {
  constructor(baseUrl, token, { timeoutMs = 15000, maxResponseBytes = MAX_RESPONSE, maxRateLimitRetries = 2, fetchImpl = globalThis.fetch } = {}) {
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
    this.timeoutMs = boundedInteger(timeoutMs, 1, 300000, 'timeoutMs');
    this.maxResponseBytes = boundedInteger(maxResponseBytes, 1, 16 * 1024 * 1024, 'maxResponseBytes');
    this.maxRateLimitRetries = boundedInteger(maxRateLimitRetries, 0, 5, 'maxRateLimitRetries');
    this.fetch = fetchImpl;
  }

  async request(method, path, body, {signal} = {}) {
    if (typeof path !== 'string' || !path.startsWith(API) || /[\\#\r\n]/.test(path)) throw new TypeError('invalid API path');
    const url = new URL(this.base + path);
    // URL normalization and percent-encoded dot segments must not escape the bot API.
    const expected = new URL(this.base + API);
    if (url.origin !== expected.origin || !(url.pathname === expected.pathname || url.pathname.startsWith(expected.pathname + '/')) || /%2f|%5c|%25/i.test(url.pathname)) throw new TypeError('invalid API path');
    let payload;
    if (body !== undefined) {
      payload = JSON.stringify(body);
      if (new TextEncoder().encode(payload).byteLength > MAX_REQUEST) throw new RangeError('request body too large');
    }
    for (let attempt = 0; ; attempt++) {
      signal?.throwIfAborted();
      const controller = new AbortController();
      const abort = () => controller.abort(signal.reason);
      signal?.addEventListener('abort', abort, {once: true});
      const timer = setTimeout(() => controller.abort(new DOMException('Plainwire request timed out', 'TimeoutError')), this.timeoutMs);
      let res, text;
      try {
        res = await this.fetch(url.href, {
        method,
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          Authorization: `Bot ${this.token}`,
          Accept: 'application/json',
          'User-Agent': 'plainwire-js-bot/2.7',
          ...(payload === undefined ? {} : {'Content-Type': 'application/json'})
        },
        body: payload
        });
        if (res.status >= 300 && res.status < 400) {
          await res.body?.cancel?.();
          throw new PlainwireAPIError(res.status, 'redirect refused');
        }
        text = await responseText(res, this.maxResponseBytes, controller.signal);
      } finally {
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
      }
      // Retry only explicit rate-limit rejections. A failed mutation with an
      // ambiguous transport/5xx result may already have committed on the server.
      if (res.status === 429 && attempt < this.maxRateLimitRetries && retryDelay(res) <= 60000) {
        await wait(retryDelay(res), signal);
        continue;
      }
      if (!res.ok) throw new PlainwireAPIError(res.status, text, res.status === 429 ? retryDelay(res) : 0);
      return {status: res.status, text, json: () => JSON.parse(text)};
    }
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

function typedOption(claim, name, required, validate, type) {
  if (typeof required !== 'boolean') throw new TypeError('required must be a boolean');
  const value = commandOption(claim, name);
  if (value == null) {
    if (required) throw new TypeError(`${name} is required`);
    return null;
  }
  if (!validate(value)) throw new TypeError(`${name} must be ${type}`);
  return value;
}

export class CommandInteraction {
  constructor(bot, claim, leaseMs = 120000) {
    this.bot = bot;
    for (const name of ['id', 'command', 'command_id', 'claim_token', 'args', 'user_id', 'channel_id', 'server_id', 'guild_id', 'request_message_id', 'lease_until', 'attempt', 'created_at']) this[name] = claim[name];
    this.options = commandOptions(claim);
    this.commandName = claim.command;
    this.channelId = claim.channel_id;
    this.guildId = claim.guild_id ?? claim.server_id;
    this.userId = claim.user_id;
    this.leaseMs = leaseMs;
    this.deferred = false;
    this.replied = false;
    this.failed = false;
    this.finishing = false;
  }
  getString(name, required = false) { return typedOption(this, name, required, value => typeof value === 'string', 'a string'); }
  getInteger(name, required = false) { return typedOption(this, name, required, Number.isSafeInteger, 'an integer'); }
  getBoolean(name, required = false) { return typedOption(this, name, required, value => typeof value === 'boolean', 'a boolean'); }
  async deferReply() {
    if (this.replied || this.failed) throw new Error('interaction already completed');
    await this.bot.deferCommand(this.id, this.claim_token, this.leaseMs);
    this.deferred = true;
  }
  async reply(content) {
    if (this.replied || this.failed || this.finishing) throw new Error('interaction already completed');
    const body = typeof content === 'string' ? content : content?.content ?? content?.body;
    if (typeof body !== 'string' || !body.trim()) throw new TypeError('reply requires text');
    this.finishing = true;
    try { const response = await this.bot.respondCommand(this.id, this.claim_token, body); this.replied = true; return response; }
    finally { this.finishing = false; }
  }
  async fail(reason = 'Command failed') {
    if (this.replied || this.failed || this.finishing) return;
    this.finishing = true;
    try { await this.bot.failCommand(this.id, this.claim_token, reason); this.failed = true; }
    finally { this.finishing = false; }
  }
}

export class CommandWorker {
  constructor(bot, handlers, {batchSize = 20, concurrency = 4, idleMs = 500, leaseMs = 120000, onError = console.error} = {}) {
    if (!(bot instanceof PlainwireBot)) throw new TypeError('bot must be a PlainwireBot');
    if (!(handlers instanceof Map) && (handlers === null || typeof handlers !== 'object')) throw new TypeError('handlers must be an object or Map');
    this.bot = bot;
    this.handlers = handlers;
    this.batchSize = boundedInteger(batchSize, 1, 50, 'batchSize');
    this.concurrency = boundedInteger(concurrency, 1, 32, 'concurrency');
    this.idleMs = boundedInteger(idleMs, 25, 60000, 'idleMs');
    this.leaseMs = boundedInteger(leaseMs, 5000, 120000, 'leaseMs');
    this.onError = typeof onError === 'function' ? onError : () => {};
  }

  handler(name) { return this.handlers instanceof Map ? this.handlers.get(name) : Object.prototype.hasOwnProperty.call(this.handlers, name) ? this.handlers[name] : undefined; }

  async handle(claim) {
    const handler = this.handler(claim.command);
    if (typeof handler !== 'function') {
      await this.bot.failCommand(claim.id, claim.claim_token, `No handler registered for /${claim.command}`);
      return;
    }
    const interaction = new CommandInteraction(this.bot, claim, this.leaseMs);
    let renewTimer;
    let stopped = false;
    const renew = async () => {
      if (stopped || interaction.replied || interaction.failed) return;
      try { await interaction.deferReply(); } catch (error) { this.onError(error, claim); return; }
      if (!stopped) renewTimer = setTimeout(renew, Math.floor(this.leaseMs / 2));
    };
    try {
      await interaction.deferReply();
      renewTimer = setTimeout(renew, Math.floor(this.leaseMs / 2));
      const result = await handler(interaction, this.bot);
      const body = typeof result === 'string' ? result : result?.content ?? result?.body;
      if (!interaction.replied && !interaction.failed) {
        if (typeof body === 'string' && body.trim()) await interaction.reply(body);
        else await interaction.fail('Command handler did not reply');
      }
    } catch (error) {
      this.onError(error, claim);
      // Exception strings can contain API keys or internal URLs. Keep detailed
      // errors in the bot's onError hook, away from user-visible failure reasons.
      try { await interaction.fail('Command failed'); } catch (failure) { this.onError(failure, claim); }
    } finally {
      stopped = true;
      clearTimeout(renewTimer);
    }
  }

  async runOnce() {
    const envelope = (await this.bot.claimCommands(Math.min(this.batchSize, this.concurrency))).json();
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
