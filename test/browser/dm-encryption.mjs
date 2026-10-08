import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {createDecipheriv, createCipheriv, randomBytes} from 'node:crypto';
import {chromium} from 'playwright';
import {me, people, now, sync, conversations, message} from './fixtures.mjs';

const root = resolve('priv/static');
const version = (await readFile('VERSION', 'utf8')).trim();
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const path = resolve(root, url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/assets\//, ''));
    if (!path.startsWith(root + '/')) throw Error('path');
    const headers = {'content-type': ({'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml'})[extname(path)] || 'application/octet-stream'};
    if (url.pathname === '/') {
      headers['content-security-policy'] = "default-src 'self'; script-src 'self'; worker-src 'self' blob:; connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; media-src 'self' blob: https:; frame-src https://www.youtube-nocookie.com https://player.vimeo.com";
      headers['referrer-policy'] = 'same-origin';
    }
    res.writeHead(200, headers);
    res.end(await readFile(path));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage']});
const errors = [], posts = [], sockets = [], remoteRequests = [], stored = [message(1, 'Earlier unencrypted message')];
let keyId = '', wideEnabled = false, revision = 0, requester = 0;
const policy = () => ({e2ee_key_id: keyId, e2ee_enabled: wideEnabled, e2ee_revision: revision, e2ee_disable_requested_by: requester});
const conversation = () => ({...conversations[0], request_state: 'accepted', ...policy()});
const refresh = () => sockets.forEach(socket => socket.send(JSON.stringify({type: 'conversation_updated', conversation_id: 1, ...policy()})));
async function setup(person = me) {
  const context = await browser.newContext({viewport: {width: 1280, height: 900}});
  await context.addInitScript(() => { localStorage.setItem('plainwire_link_previews', 'true'); window.PLAINWIRE_DEBUG = true; });
  await context.route(/^https:\/\//, route => {
    remoteRequests.push({url: route.request().url(), headers: route.request().headers()});
    return route.fulfill({contentType: 'image/gif', body: Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64')});
  });
  await context.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    const reply = data => route.fulfill({json: {ok: true, data}});
    if (path === '/api/client-config') return route.fulfill({json: {version, app_name: 'Plainwire', registration_enabled: true, gif_search_enabled: true}});
    if (path === '/api/gifs/search') return reply({results: [{id: 'private-gif', title: 'Happy GIF', url: 'https://media.example.com/happy.gif', preview_url: 'https://media.example.com/thumb.gif', width: 100, height: 100}], next: ''});
    if (path === '/api/gifs/share') return reply({shared: true});
    if (path === '/api/me') return reply({user: person, csrf: 'encryption-csrf', server_time: now});
    if (path === '/api/sync') return reply({...sync, conversations: [conversation()]});
    if (path === '/api/conversations') return reply([conversation()]);
    if (path === '/api/conversation/1') return reply({conversation: conversation(), members: conversation().members});
    if (path === '/api/conversation/1/encryption') {
      const data = req.postDataJSON(); posts.push({path, data});
      assert.equal(req.headers()['x-csrf-token'], 'encryption-csrf');
      assert.deepEqual(Object.keys(data).sort(), ['enabled', 'key_id']);
      keyId = data.key_id; wideEnabled = data.enabled; revision++; requester = 0; refresh();
      return reply({conversation_id: 1, ...policy()});
    }
    if (path === '/api/conversation/1/encryption/disable') {
      const data = req.postDataJSON(); posts.push({path, data}); assert.equal(data.revision, revision);
      if (data.action === 'request') requester = person.id;
      else if (data.action === 'approve') { assert(requester && requester !== person.id); wideEnabled = false; requester = 0; }
      else requester = 0;
      revision++; refresh(); return reply({conversation_id: 1, ...policy()});
    }
    if (path === '/api/messages') return reply(url.searchParams.get('scope') === 'channel' ? [] : stored);
    if (path === '/api/conversation/1/messages') {
      const data = req.postDataJSON(); posts.push({path, data});
      assert.equal(data.encryption_revision, revision);
      if (wideEnabled || data.encrypt_message) assert.match(data.body, /^pw-e2ee-v2:/, 'locked text travels as ciphertext');
      const msg = {...message(stored.length + 1, data.body, 1, person), client_nonce: data.client_nonce, reply_to_id: data.reply_to_id ?? null}; stored.push(msg);
      return reply(msg);
    }
    if (/^\/api\/edit_message\/\d+$/.test(path)) {
      const data = req.postDataJSON(); posts.push({path, data});
      const msg = stored.find(m => m.id === Number(path.split('/').pop()));
      Object.assign(msg, data, {edited_at: now});
      return reply(msg);
    }
    if (/^\/api\/message\/\d+\/encryption$/.test(path)) {
      const data = req.postDataJSON(); posts.push({path, data});
      const msg = stored.find(m => m.id === Number(path.split('/')[3]));
      assert.equal(msg.user_id, person.id); assert.equal(msg.body, data.expected_body); assert.equal(data.encryption_revision, revision);
      if (data.action === 'unlock') assert.equal(wideEnabled, false);
      else assert.match(data.body, /^pw-e2ee-v2:/);
      Object.assign(msg, {body: data.body, edited_at: now}); return reply(msg);
    }
    if (path === '/api/embed' || path.startsWith('/api/media/') || path === '/api/uploads') throw Error('encrypted text must not request embeds or upload files');
    return reply([]);
  });
  await context.routeWebSocket('**/ws', socket => { sockets.push(socket); socket.send(JSON.stringify({type: 'hello', session: {user: person}})); });
  const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin);
  try { await page.waitForSelector('.home-welcome', {timeout: 10000}); }
  catch (error) { console.error('Boot errors:', errors, 'Body:', (await page.locator('body').innerText()).slice(0, 1000)); throw error; }
  await page.evaluate(() => { location.hash = '#dm/1'; });
  await page.waitForSelector('#compose'); await page.waitForSelector('pw-dm-security button');
  return {context, page};
}

async function waitForBody(page, id, body, encrypted = true) {
  await page.waitForFunction(({id, body, encrypted}) => {
    const msg = document.querySelector(`.msg[data-mid="${id}"] .msg-body`);
    return encrypted ? msg?.classList.contains('encrypted-text') && msg.querySelector('pw-markdown')?.getAttribute('source') === body : msg && !msg.classList.contains('encrypted-text') && msg.textContent.includes(body);
  }, {id, body, encrypted});
}

async function sendText(page, text) {
  const response = page.waitForResponse(r => new URL(r.url()).pathname === '/api/conversation/1/messages');
  await page.locator('#compose').fill(text); await page.locator('.composer-send').click(); await response;
  return stored.at(-1);
}

async function settings(page, state = wideEnabled ? 'On' : 'Off') {
  await page.getByRole('button', {name: `DM encryption: ${state}`, exact: true}).click();
}

try {
  const sender = await setup(); const {page} = sender;
  await page.getByRole('button', {name: 'Enable encrypted text', exact: true}).click();
  await page.getByRole('button', {name: 'Generate a new key', exact: true}).click();
  const input = page.getByRole('textbox', {name: 'DM encryption key'});
  await page.waitForFunction(() => document.querySelector('[aria-label="DM encryption key"]')?.value.startsWith('pwkey1_'));
  const secret = await input.inputValue();
  assert.match(secret, /^pwkey1_[A-Za-z0-9_-]{43}$/);
  assert(await page.getByRole('button', {name: 'Enable encrypted text', exact: true}).last().isDisabled(), 'saving and verification consent required');
  await page.locator('.dm-key-confirm input').check();
  await page.getByRole('button', {name: 'Enable encrypted text', exact: true}).last().click();
  await page.waitForFunction(() => !document.querySelector('.dm-key-setup'));
  await page.waitForFunction(() => document.querySelector('pw-dm-security')?.getAttribute('data-key-id')?.length === 64);
  const privateText = 'Private text "quotes"\nhttps://example.com/private?secret=private-link\n![image](https://example.com/private.png)\nhttps://example.com/private.gif\nhttps://www.youtube.com/watch?v=abcdefghijk';
  const sent = page.waitForResponse(response => new URL(response.url()).pathname === '/api/conversation/1/messages');
  await page.locator('#compose').fill(privateText); await page.locator('.composer-send').click(); await sent;
  await page.waitForSelector('.msg[data-mid="2"] .encrypted-text');
  await waitForBody(page, 2, privateText);
  const wire = stored.at(-1).body;
  const retried = await page.evaluate(async () => {
    const request = {method: 'POST', path: '/conversation/1/messages', body: {body: 'A retry must retain its encrypted identity', encrypt_message: true, client_nonce: 'audit-encrypted-retry-0001'}};
    const first = await window.PlainwireE2EE.encodeRequest(request);
    const element = document.querySelector('pw-dm-security');
    const attributes = ['data-key-id', 'data-enabled', 'data-revision'].map(name => [name, element.getAttribute(name)]);
    element.setAttribute('data-key-id', ''); element.setAttribute('data-enabled', 'false'); element.setAttribute('data-revision', '9999');
    const second = await window.PlainwireE2EE.encodeRequest(request);
    attributes.forEach(([name, value]) => element.setAttribute(name, value));
    return [first, second];
  });
  assert.equal(retried[0].body, retried[1].body, 'retry keeps the ciphertext, IV and nonce stable');
  assert.equal(retried[0].encryption_revision, revision, 'DOM patches cannot replace the authoritative encryption policy');
  assert(!wire.includes('Private text') && !JSON.stringify(posts).includes(secret));
  const [, actualKey, nonce, iv64, cipher64] = wire.split(':');
  assert.equal(actualKey, keyId);
  const cipher = Buffer.from(cipher64, 'base64url');
  const decipher = createDecipheriv('aes-256-gcm', Buffer.from(secret.slice(7), 'base64url'), Buffer.from(iv64, 'base64url'));
  decipher.setAAD(Buffer.from(`plainwire-dm-v2\n1\n1\n${keyId}\n${nonce}`));
  decipher.setAuthTag(cipher.subarray(-16));
  const payload = Buffer.concat([decipher.update(cipher.subarray(0, -16)), decipher.final()]);
  assert.equal(payload[0], 2); assert.equal(payload.readBigUInt64BE(1), 0n); assert.equal(payload.subarray(9).toString(), privateText);
  const privateMessage = page.locator('.msg[data-mid="2"] .encrypted-text');
  assert.equal(await privateMessage.locator('.private-link-embed').count(), 4, 'local link, image, GIF, and video cards work in an actively encrypted DM');
  assert.equal(remoteRequests.length, 0, 'decryption creates no remote preview or thumbnail requests');
  await privateMessage.getByRole('button', {name: 'Load image', exact: true}).click();
  await page.waitForFunction(() => document.querySelector('.msg[data-mid="2"] .private-link-embed img')?.naturalWidth === 1, null, {timeout: 5000}).catch(async error => {
    console.error('Private image:', await privateMessage.innerHTML(), 'Remote requests:', remoteRequests); throw error;
  });
  assert.equal(remoteRequests.at(-1).url, 'https://example.com/private.png');
  assert.equal(remoteRequests.at(-1).headers.referer, undefined, 'private media sends no referrer');
  await privateMessage.getByRole('button', {name: 'Load GIF', exact: true}).click();
  await page.waitForFunction(() => document.querySelectorAll('.msg[data-mid="2"] .private-link-embed img').length === 2);
  assert.equal(remoteRequests.at(-1).url, 'https://example.com/private.gif');
  assert(await page.getByRole('button', {name: 'Attach files or images', exact: true}).isDisabled());
  assert(!(await page.getByRole('button', {name: 'Search GIFs', exact: false}).isDisabled()));
  const keyInfo = await page.evaluate(async ({keyId, secret}) => {
    const key = await PlainwireE2EE.getKey(1, keyId);
    let exported = false; try { await crypto.subtle.exportKey('raw', key); exported = true; } catch {}
    return {extractable: key.extractable, exported, storage: Object.values(localStorage).join(' ').includes(secret)};
  }, {keyId, secret});
  assert.deepEqual(keyInfo, {extractable: false, exported: false, storage: false});
  const cryptoResults = await page.evaluate(async ({body, keyId, secret}) => {
    const e = PlainwireE2EE, result = {};
    for (const [name, cid, sender, text, reply] of [
      ['conversation', 2, 1, body, null], ['sender', 1, 2, body, null], ['reply', 1, 1, body, 33],
      ['tamper', 1, 1, body.slice(0, -2) + (body.at(-2) === 'A' ? 'B' : 'A') + body.at(-1), null],
      ['nonce', 1, 1, body.replace(body.split(':')[2], 'AAAAAAAAAAAAAAAAAAAAAA'), null]
    ]) {
      try { await e.unseal(cid, sender, text, reply); result[name] = false; } catch { result[name] = true; }
    }
    const first = await e.seal(1, 1, 'repeat'), second = await e.seal(1, 1, 'repeat'); result.uniqueIV = first !== second;
    const max = await e.seal(1, 1, '"'.repeat(5000)); result.max = (await e.unseal(1, 1, max, null)).length === 5000;
    try { await e.seal(1, 1, '😀'.repeat(1251)); result.tooLarge = false; } catch { result.tooLarge = true; }
    const bundle = await e.importSecret(secret);
    const descriptor = Object.getOwnPropertyDescriptor(IDBTransaction.prototype, 'oncomplete');
    let switchAccount = true, saveRejected = false;
    Object.defineProperty(IDBTransaction.prototype, 'oncomplete', {...descriptor, set(handler) {
      descriptor.set.call(this, function(event) {
        handler.call(this, event);
        if (switchAccount && this.mode === 'readonly') { switchAccount = false; e.setUser(2); }
      });
    }});
    try { await e.saveKey(1, bundle); } catch (error) { saveRejected = error.message === 'Account changed while saving encryption'; }
    finally { Object.defineProperty(IDBTransaction.prototype, 'oncomplete', descriptor); }
    result.savingAccountChanged = !switchAccount && saveRejected && !(await e.getKey(1, keyId));
    e.setUser(1);
    e.setUser(2); result.accountIsolated = !(await e.getKey(1, keyId)); e.setUser(1); e.remember({id: 1, e2ee_key_id: keyId});
    return result;
  }, {body: wire, keyId, secret});
  assert.deepEqual(cryptoResults, {conversation: true, sender: true, reply: true, tamper: true, nonce: true, uniqueIV: true, max: true, tooLarge: true, savingAccountChanged: true, accountIsolated: true});
  // Switching accounts clears message metadata as well as the in-memory keys.
  // Reload before editing so the normal HTTP decoder repopulates that metadata.
  await page.reload(); await page.waitForSelector('#compose');
  await waitForBody(page, 2, privateText);

  const receiver = await setup(people[1]);
  await receiver.page.getByText('Encrypted text · unlock this DM to read it', {exact: true}).waitFor();
  await receiver.page.getByRole('button', {name: 'DM encryption: On', exact: true}).click();
  await receiver.page.getByRole('button', {name: 'Unlock on this device', exact: true}).click();
  await receiver.page.getByRole('textbox', {name: 'DM encryption key'}).fill('pwkey1_' + 'A'.repeat(43));
  await receiver.page.getByRole('button', {name: 'Unlock on this device', exact: true}).click();
  await receiver.page.getByText('This key does not match the DM fingerprint', {exact: true}).waitFor();
  await receiver.page.getByRole('textbox', {name: 'DM encryption key'}).fill(secret);
  await receiver.page.getByRole('button', {name: 'Unlock on this device', exact: true}).click();
  await waitForBody(receiver.page, 2, privateText);
  await receiver.page.reload(); await receiver.page.waitForSelector('#compose');
  await receiver.page.evaluate(() => { location.hash = '#dm/1'; });
  await waitForBody(receiver.page, 2, privateText);
  const tampered = {...stored.at(-1), id: 77, user_id: 2};
  sockets.at(-1).send(JSON.stringify({type: 'message_created', scope: 'direct', scope_id: 1, message: tampered}));
  await receiver.page.getByText('Encrypted text could not be authenticated', {exact: true}).waitFor();

  // Authenticate the unchanged reply context when editing a previous ciphertext.
  await page.locator('.msg[data-mid="2"]').hover();
  await page.locator('.msg[data-mid="2"]').getByRole('button', {name: 'Edit', exact: true}).click({timeout: 5000}).catch(async error => {
    console.error('Edit state:', await page.locator('.msg').evaluateAll(nodes => nodes.map(node => ({id: node.dataset.mid, classes: node.className, text: node.innerText.slice(0, 250)})))); throw error;
  });
  await page.locator('.message-edit-input').fill('Edited private text');
  const edited = page.waitForResponse(response => new URL(response.url()).pathname === '/api/edit_message/2');
  await page.getByRole('button', {name: 'Save', exact: true}).click(); await edited;
  await page.getByText('Edited private text', {exact: true}).waitFor();
  assert.match(posts.at(-1).data.body, /^pw-e2ee-v2:/);
  assert(!JSON.stringify(posts).includes('Edited private text'));
  assert.equal(posts.at(-1).data.body.split(':')[2], nonce, 'edits preserve authenticated message identity');
  await page.reload(); await page.waitForSelector('#compose');
  await page.evaluate(() => { location.hash = '#dm/1'; });
  await page.getByText('Edited private text', {exact: true}).waitFor();

  // Previously stored v1 history remains readable with the original key.
  const legacyIv = randomBytes(12), legacyPayload = Buffer.alloc(9); legacyPayload[0] = 1;
  const legacyCipher = createCipheriv('aes-256-gcm', Buffer.from(secret.slice(7), 'base64url'), legacyIv);
  legacyCipher.setAAD(Buffer.from(`plainwire-dm-v1\n1\n1\n${keyId}`));
  const legacyBody = Buffer.concat([legacyCipher.update(Buffer.concat([legacyPayload, Buffer.from('Legacy encrypted history')])), legacyCipher.final(), legacyCipher.getAuthTag()]);
  stored.push(message(3, `pw-e2ee-v1:${keyId}:${legacyIv.toString('base64url')}:${legacyBody.toString('base64url')}`, 1, me));
  await page.reload(); await page.waitForSelector('#compose'); await waitForBody(page, 3, 'Legacy encrypted history');

  // Selecting a GIF does not downgrade the active DM or disclose its URL in a
  // message post. Search is a deliberate separate request to the GIF provider.
  await page.getByRole('button', {name: 'Search GIFs', exact: true}).click();
  await page.getByText('GIF searches go to the relay and KLIPY.', {exact: false}).waitFor();
  await page.getByRole('searchbox', {name: 'Search KLIPY'}).fill('happy');
  await page.getByRole('button', {name: 'Insert GIF: Happy GIF', exact: true}).click();
  const gifDraft = await page.locator('#compose').inputValue();
  assert.equal(gifDraft, '![Happy GIF](https://media.example.com/happy.gif)');
  const gifMessage = await sendText(page, gifDraft); await waitForBody(page, gifMessage.id, gifDraft);
  assert.match(gifMessage.body, /^pw-e2ee-v2:/);
  assert(!JSON.stringify(posts).includes('media.example.com/happy.gif'));
  await page.locator(`.msg[data-mid="${gifMessage.id}"]`).getByRole('button', {name: 'Load GIF', exact: true}).click();
  await page.waitForFunction(id => document.querySelector(`.msg[data-mid="${id}"] .private-link-embed img`)?.naturalWidth === 1, gifMessage.id);

  // A device lock persists across reloads and reaches the account's other tabs.
  const otherTab = await sender.context.newPage(); await otherTab.goto(origin + '/#dm/1');
  await waitForBody(otherTab, 2, 'Edited private text');
  await settings(page); await page.getByRole('button', {name: 'Lock this device', exact: true}).click();
  await page.locator('.msg[data-mid="2"]').getByText('Encrypted text · unlock this DM to read it', {exact: true}).waitFor();
  await otherTab.locator('.msg[data-mid="2"]').getByText('Encrypted text · unlock this DM to read it', {exact: true}).waitFor();
  assert.equal(await otherTab.locator('.encrypted-text .private-link-embed').count(), 0, 'locked messages have no embeds');
  await page.reload(); await page.waitForSelector('#compose');
  await page.locator('.msg[data-mid="2"]').getByText('Encrypted text · unlock this DM to read it', {exact: true}).waitFor();
  await settings(page); await page.getByRole('button', {name: 'Unlock on this device', exact: true}).click();
  await page.getByRole('button', {name: 'Unlock saved key', exact: true}).click();
  await waitForBody(page, 2, 'Edited private text'); await waitForBody(otherTab, 2, 'Edited private text'); await otherTab.close();

  const historyBeforeOff = stored.filter(m => m.body.startsWith('pw-e2ee-')).map(m => m.body);
  await settings(page); await page.getByRole('button', {name: 'Request turning off', exact: true}).click();
  assert.equal(wideEnabled, true, 'one person cannot downgrade the DM');
  await receiver.page.getByRole('button', {name: 'DM encryption: On · approval pending', exact: true}).click();
  await receiver.page.getByRole('button', {name: 'Approve turning off', exact: true}).click();
  await page.getByRole('button', {name: 'DM encryption: Off', exact: true}).waitFor();
  assert.deepEqual(stored.filter(m => m.body.startsWith('pw-e2ee-')).map(m => m.body), historyBeforeOff, 'turning the DM off preserves encrypted history');
  const plain = await sendText(page, 'Ordinary text after mutual approval'); await waitForBody(page, plain.id, plain.body, false);
  assert.equal(plain.body, 'Ordinary text after mutual approval');
  await page.getByRole('button', {name: 'Lock this message', exact: true}).click();
  const single = await sendText(page, 'Only this text is locked'); await waitForBody(page, single.id, 'Only this text is locked');
  assert.match(single.body, /^pw-e2ee-v2:/); assert.equal(wideEnabled, false);
  await page.getByRole('button', {name: 'Message lock: On', exact: true}).click();
  await page.locator('.msg[data-mid="2"]').hover();
  await page.locator('.msg[data-mid="2"]').focus();
  await page.locator('.msg[data-mid="2"]').getByRole('button', {name: 'Remove lock', exact: true}).click({timeout: 5000}).catch(async error => {
    console.error('Lock action layout:', await page.locator('.msg[data-mid="2"]').evaluate(node => [node, node.querySelector('.msg-actions'), node.querySelector('pw-message-security'), node.querySelector('pw-message-security button')].map(el => ({tag: el.tagName, hover: el.matches(':hover'), display: getComputedStyle(el).display, visibility: getComputedStyle(el).visibility, rect: el.getBoundingClientRect().toJSON()})))); throw error;
  });
  await page.getByRole('button', {name: 'Remove lock and publish text', exact: true}).click();
  await waitForBody(page, 2, 'Edited private text', false);
  assert.equal(stored.find(m => m.id === 2).body, 'Edited private text', 'explicit sender removal publishes only selected text');
  await page.locator('.msg[data-mid="2"]').click({button: 'right'});
  await page.getByRole('menuitem', {name: 'Lock message', exact: false}).click();
  await page.locator('.dm-key-setup').getByRole('button', {name: 'Lock this message', exact: true}).click();
  await waitForBody(page, 2, 'Edited private text');
  assert.match(stored.find(m => m.id === 2).body, /^pw-e2ee-v2:/);
  assert.notEqual(stored.find(m => m.id === 2).body.split(':')[2], nonce, 'relocking creates a fresh identity while server keeps old replay tombstone');
  await receiver.page.reload(); await receiver.page.waitForSelector('#compose');
  assert.equal(await receiver.page.locator('.msg[data-mid="2"] pw-message-security button').count(), 0, 'recipients have no sender lock action');
  await settings(page, 'Off'); await page.getByRole('button', {name: 'Turn DM encryption on', exact: true}).click();
  await page.getByRole('button', {name: 'DM encryption: On', exact: true}).waitFor();
  const replayPolicy = await page.evaluate(async () => {
    const mode = document.querySelector('pw-dm-security');
    PlainwireE2EE.remember({id: 1, e2ee_key_id: mode.dataset.keyId, e2ee_enabled: false, e2ee_revision: Number(mode.dataset.revision) - 1});
    return (await PlainwireE2EE.encodeRequest({method: 'POST', path: '/conversation/1/messages', body: {body: 'stale event must not downgrade'}})).body;
  });
  assert.match(replayPolicy, /^pw-e2ee-v2:/, 'old policy events cannot silently turn off encryption');
  for (const width of [320, 390, 760]) {
    await page.setViewportSize({width, height: 740});
    await page.locator('#compose').fill('A mobile draft');
    const layout = await page.evaluate(() => {
      const buttons = [...document.querySelectorAll('.composer-footer .composer-action, .composer-footer summary')];
      return {overflow: document.documentElement.scrollWidth > innerWidth, buttons: buttons.map(b => ({w: b.getBoundingClientRect().width, h: b.getBoundingClientRect().height, right: b.getBoundingClientRect().right})), font: getComputedStyle(document.querySelector('#compose')).fontSize};
    });
    assert.equal(layout.overflow, false, `no horizontal scroll at ${width}`);
    assert.equal(layout.font, '16px', 'mobile typing avoids automatic zoom');
    for (const box of layout.buttons) assert(box.w >= 43.9 && box.h >= 43.9 && box.right <= width, `${width}px touch target: ${JSON.stringify(box)}`);
  }
  await mkdir('test-results', {recursive: true});
  await page.setViewportSize({width: 390, height: 740}); await page.screenshot({path: 'test-results/encrypted-dm-mobile.png'});
  await page.setViewportSize({width: 390, height: 420});
  // Playwright can return before the visual-viewport resize event updates the
  // keyboard layout. Wait for that observable layout, preserving the bounds.
  await page.waitForFunction(() => {
    const box = document.querySelector('#compose')?.getBoundingClientRect();
    return document.documentElement.style.getPropertyValue('--pw-visual-height') === '420px'
      && box && box.top >= 0 && box.bottom <= 420;
  }, null, {timeout: 5000});
  const composer = await page.locator('#compose').boundingBox(); assert(composer.y >= 0 && composer.y + composer.height <= 420, `composer fits short keyboard viewport: ${JSON.stringify(composer)}`);
  assert.deepEqual(errors, [], 'no browser exceptions');
  await sender.context.close(); await receiver.context.close(); sockets.length = 0;
  keyId = ''; wideEnabled = false; revision = 0; requester = 0; stored.splice(0, stored.length, message(1, 'Earlier unencrypted message'));
  const individual = await setup();
  await individual.page.getByRole('button', {name: 'Lock this message', exact: true}).click();
  await individual.page.getByRole('button', {name: 'Generate a new key', exact: true}).click();
  await individual.page.waitForFunction(() => document.querySelector('[aria-label="DM encryption key"]')?.value.startsWith('pwkey1_'));
  await individual.page.locator('.dm-key-confirm input').check();
  await individual.page.getByRole('button', {name: 'Set up message locks', exact: true}).click();
  await individual.page.getByRole('button', {name: 'DM encryption: Off', exact: true}).waitFor();
  const lockedOnly = await sendText(individual.page, 'Single lock without activating DM-wide encryption');
  assert.match(lockedOnly.body, /^pw-e2ee-v2:/); assert.equal(wideEnabled, false);
  assert.deepEqual(errors, [], 'no browser exceptions');
  console.log('PASS: v1/v2 decryption, authenticated edits/context, local encrypted link/GIF/video cards and picker, no automatic remote previews, cross-tab device locks, mutual disable consent, preserved history, sender-only individual locks/removal, stale policy protection, key isolation, and mobile layouts.');
} finally { await browser.close(); await new Promise(r => server.close(r)); }
