import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {createDecipheriv} from 'node:crypto';
import {chromium} from 'playwright';
import {me, people, now, sync, conversations, message} from './fixtures.mjs';

const root = resolve('priv/static');
const version = (await readFile('VERSION', 'utf8')).trim();
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const path = resolve(root, url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/assets\//, ''));
    if (!path.startsWith(root + '/')) throw Error('path');
    res.writeHead(200, {'content-type': ({'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml'})[extname(path)] || 'application/octet-stream'});
    res.end(await readFile(path));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage']});
const errors = [], posts = [], sockets = [], stored = [message(1, 'Earlier unencrypted message')];
let keyId = '';
const conversation = () => ({...conversations[0], request_state: 'accepted', e2ee_key_id: keyId});
const refresh = () => sockets.forEach(socket => socket.send(JSON.stringify({type: 'conversation_updated', conversation_id: 1, e2ee_key_id: keyId})));
async function setup(person = me) {
  const context = await browser.newContext({viewport: {width: 1280, height: 900}});
  await context.addInitScript(() => { localStorage.setItem('plainwire_link_previews', 'true'); window.PLAINWIRE_DEBUG = true; });
  await context.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    const reply = data => route.fulfill({json: {ok: true, data}});
    if (path === '/api/client-config') return route.fulfill({json: {version, app_name: 'Plainwire', registration_enabled: true}});
    if (path === '/api/me') return reply({user: person, csrf: 'encryption-csrf', server_time: now});
    if (path === '/api/sync') return reply({...sync, conversations: [conversation()]});
    if (path === '/api/conversations') return reply([conversation()]);
    if (path === '/api/conversation/1') return reply({conversation: conversation(), members: conversation().members});
    if (path === '/api/conversation/1/encryption') {
      const data = req.postDataJSON(); posts.push({path, data});
      assert.equal(req.headers()['x-csrf-token'], 'encryption-csrf');
      assert.deepEqual(Object.keys(data), ['key_id']);
      keyId = data.key_id; refresh();
      return reply({conversation_id: 1, e2ee_key_id: keyId});
    }
    if (path === '/api/messages') return reply(url.searchParams.get('scope') === 'channel' ? [] : stored);
    if (path === '/api/conversation/1/messages') {
      const data = req.postDataJSON(); posts.push({path, data});
      assert.match(data.body, /^pw-e2ee-v1:/, 'new text travels as ciphertext');
      const msg = {...message(stored.length + 1, data.body, 1, person), reply_to_id: data.reply_to_id ?? null}; stored.push(msg);
      return reply(msg);
    }
    if (/^\/api\/edit_message\/\d+$/.test(path)) {
      const data = req.postDataJSON(); posts.push({path, data});
      const msg = stored.find(m => m.id === Number(path.split('/').pop()));
      Object.assign(msg, data, {edited_at: now});
      return reply(msg);
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

try {
  const sender = await setup(); const {page} = sender;
  await page.locator('pw-dm-security button').click();
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
  const privateText = 'Private text "quotes"\nhttps://example.com/private?secret=private-link\n![image](https://example.com/private.png)';
  const sent = page.waitForResponse(response => new URL(response.url()).pathname === '/api/conversation/1/messages');
  await page.locator('#compose').fill(privateText); await page.locator('.composer-send').click(); await sent;
  await page.waitForSelector('.msg[data-mid="2"] .encrypted-text');
  await page.getByText(privateText, {exact: true}).waitFor();
  const wire = stored.at(-1).body;
  assert(!wire.includes('Private text') && !JSON.stringify(posts).includes(secret));
  const [, actualKey, iv64, cipher64] = wire.split(':');
  assert.equal(actualKey, keyId);
  const cipher = Buffer.from(cipher64, 'base64url');
  const decipher = createDecipheriv('aes-256-gcm', Buffer.from(secret.slice(7), 'base64url'), Buffer.from(iv64, 'base64url'));
  decipher.setAAD(Buffer.from(`plainwire-dm-v1\n1\n1\n${keyId}`));
  decipher.setAuthTag(cipher.subarray(-16));
  const payload = Buffer.concat([decipher.update(cipher.subarray(0, -16)), decipher.final()]);
  assert.equal(payload[0], 1); assert.equal(payload.readBigUInt64BE(1), 0n); assert.equal(payload.subarray(9).toString(), privateText);
  assert.equal(await page.locator('.encrypted-text pw-markdown, .encrypted-text img, .encrypted-text a').count(), 0, 'private links never become network previews');
  assert(await page.getByRole('button', {name: 'Attach files or images', exact: true}).isDisabled());
  assert(await page.getByRole('button', {name: 'Search GIFs', exact: false}).isDisabled());
  const keyInfo = await page.evaluate(async ({keyId, secret}) => {
    const key = await PlainwireE2EE.getKey(1, keyId);
    let exported = false; try { await crypto.subtle.exportKey('raw', key); exported = true; } catch {}
    return {extractable: key.extractable, exported, storage: Object.values(localStorage).join(' ').includes(secret)};
  }, {keyId, secret});
  assert.deepEqual(keyInfo, {extractable: false, exported: false, storage: false});
  const cryptoResults = await page.evaluate(async ({body, keyId}) => {
    const e = PlainwireE2EE, result = {};
    for (const [name, cid, sender, text, reply] of [
      ['conversation', 2, 1, body, null], ['sender', 1, 2, body, null], ['reply', 1, 1, body, 33],
      ['tamper', 1, 1, body.slice(0, -2) + (body.at(-2) === 'A' ? 'B' : 'A') + body.at(-1), null]
    ]) {
      try { await e.unseal(cid, sender, text, reply); result[name] = false; } catch { result[name] = true; }
    }
    const first = await e.seal(1, 1, 'repeat'), second = await e.seal(1, 1, 'repeat'); result.uniqueIV = first !== second;
    const max = await e.seal(1, 1, '"'.repeat(5000)); result.max = (await e.unseal(1, 1, max, null)).length === 5000;
    try { await e.seal(1, 1, '😀'.repeat(1251)); result.tooLarge = false; } catch { result.tooLarge = true; }
    e.setUser(2); result.accountIsolated = !(await e.getKey(1, keyId)); e.setUser(1); e.remember({id: 1, e2ee_key_id: keyId});
    return result;
  }, {body: wire, keyId});
  assert.deepEqual(cryptoResults, {conversation: true, sender: true, reply: true, tamper: true, uniqueIV: true, max: true, tooLarge: true, accountIsolated: true});
  // Switching accounts clears message metadata as well as the in-memory keys.
  // Reload before editing so the normal HTTP decoder repopulates that metadata.
  await page.reload(); await page.waitForSelector('#compose');
  await page.getByText(privateText, {exact: true}).waitFor();

  const receiver = await setup(people[1]);
  await receiver.page.getByText('Encrypted text · unlock this DM to read it', {exact: true}).waitFor();
  await receiver.page.locator('pw-dm-security button').click();
  await receiver.page.getByRole('textbox', {name: 'DM encryption key'}).fill('pwkey1_' + 'A'.repeat(43));
  await receiver.page.getByRole('button', {name: 'Unlock on this device', exact: true}).click();
  await receiver.page.getByText('This key does not match the DM fingerprint', {exact: true}).waitFor();
  await receiver.page.getByRole('textbox', {name: 'DM encryption key'}).fill(secret);
  await receiver.page.getByRole('button', {name: 'Unlock on this device', exact: true}).click();
  await receiver.page.getByText(privateText, {exact: true}).waitFor();
  await receiver.page.reload(); await receiver.page.waitForSelector('#compose');
  await receiver.page.evaluate(() => { location.hash = '#dm/1'; });
  await receiver.page.getByText(privateText, {exact: true}).waitFor();
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
  assert.match(posts.at(-1).data.body, /^pw-e2ee-v1:/);
  assert(!JSON.stringify(posts).includes('Edited private text'));
  await page.reload(); await page.waitForSelector('#compose');
  await page.evaluate(() => { location.hash = '#dm/1'; });
  await page.getByText('Edited private text', {exact: true}).waitFor();
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
  console.log('PASS: private DM setup/unlock, independent AES-GCM decryption, key persistence/isolation, tamper/context checks, encrypted edits, UTF-8 limits, no key/plaintext API leak or private embeds, and mobile touch targets.');
} finally { await browser.close(); await new Promise(r => server.close(r)); }
