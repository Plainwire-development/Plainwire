import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {chromium} from 'playwright';
import {me, people, sync, conversations, message} from './fixtures.mjs';

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
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage']});
const errors = [];
async function setup({storageDenied = false, group = false} = {}) {
  const context = await browser.newContext({viewport: {width: 1280, height: 900}});
  if (storageDenied) await context.addInitScript(() => { Object.defineProperty(window, 'indexedDB', {get() { throw new DOMException('Storage denied', 'SecurityError'); }}); });
  const state = {token: 'first-session', person: me, meRequests: 0, requests: [], stored: [], holds: new Map(), fail: '', heldHistory: null};
  const c = {...conversations[0], e2ee_key_id: '', e2ee_enabled: false, e2ee_revision: 0, request_state: 'accepted',
    ...(group ? {name: 'group dm 1', member_count: 3, members: people.slice(0, 3).map(user => ({user, role: 'member'}))} : {})};
  await context.route('**/api/**', async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    const reply = data => route.fulfill({json: {ok: true, data}});
    if (path === '/api/client-config') return route.fulfill({json: {version, app_name: 'Plainwire'}});
    if (path === '/api/me') { state.meRequests++; return reply({user: state.person, csrf: state.token, server_time: Date.now()}); }
    if (path === '/api/sync') return reply({...sync, now: Date.now(), conversations: [c]});
    if (path === '/api/conversations') return reply([c]);
    if (path === '/api/conversation/1') return reply({conversation: c, members: c.members});
    if (path === '/api/messages') {
      if (state.heldHistory === true) { const snapshot = state.stored.map(row => ({...row})).reverse(); state.heldHistory = () => reply(snapshot); return; }
      return reply(state.stored.slice().reverse());
    }
    if (path === '/api/conversation/1/messages') {
      const data = req.postDataJSON(); state.requests.push({data, token: req.headers()['x-csrf-token']});
      if (req.headers()['x-csrf-token'] !== state.token) return route.fulfill({status: 403, json: {ok: false, error: 'bad_csrf'}});
      if (state.fail) return route.fulfill({status: 503, json: {ok: false, error: state.fail}});
      const result = {...message(100 + state.stored.length, data.body, 1, me), created_at: Date.now(), client_nonce: data.client_nonce};
      state.stored.push(result);
      if (state.holds.has(data.body)) { state.holds.set(data.body, () => reply(result)); return; }
      return reply(result);
    }
    return reply([]);
  });
  await context.routeWebSocket('**/ws', socket => socket.send(JSON.stringify({type: 'hello', session: {user: state.person}})));
  const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${origin}/#dm/1`); await page.locator('#compose').waitFor();
  await page.waitForFunction(() => document.querySelector('.chat-header h2')?.textContent.includes('Jamie') || document.querySelector('.chat-header h2')?.textContent === 'group dm 1');
  return {context, page, state};
}
async function send(page, body) { await page.locator('#compose').fill(body); await page.getByRole('button', {name: 'Send message', exact: true}).click(); }
try {
  const {context, page, state} = await setup();
  state.token = 'renewed-session';
  await send(page, 'First load after a renewed session');
  await page.locator('.msg[data-mid="100"]').waitFor({timeout: 7000});
  assert.equal(state.requests.length, 2, 'only a confirmed CSRF rejection is replayed');
  assert.equal(state.meRequests, 2, 'same-account session refresh repairs the first send');
  assert.equal(state.stored.length, 1, 'the first message is stored once without a manual refresh');

  state.fail = 'database_busy';
  await send(page, 'A rejected send stays available');
  await page.locator('.msg.failed').waitFor();
  const failures = state.requests.length;
  await page.waitForTimeout(300);
  assert.equal(state.requests.length, failures, 'server and ambiguous transport failures are not blindly replayed');
  state.fail = '';
  await page.locator('.msg.failed').getByRole('button', {name: 'Dismiss', exact: true}).click();

  state.stored.push({...message(500, 'Repeated words', 1, me), created_at: Date.now() - 86400000});
  await page.evaluate(() => { location.hash = '#dms'; });
  await page.locator('#compose').waitFor({state: 'detached'});
  state.heldHistory = true;
  await page.evaluate(() => { location.hash = '#dm/1'; });
  await page.locator('#compose').waitFor();
  state.holds.set('Repeated words', null);
  await send(page, 'Repeated words');
  await page.waitForFunction(() => !!document.querySelector('.msg.pending'));
  // Return only the old row, as a history request started before the POST would.
  const held = state.heldHistory; assert.equal(typeof held, 'function');
  await held();
  await page.locator('.msg[data-mid="500"]').waitFor();
  assert.equal(await page.locator('.msg.pending').count(), 1, 'identical history cannot consume a new pending message');
  await state.holds.get('Repeated words')();
  await page.locator('.msg.pending').waitFor({state: 'detached'});

  await page.evaluate(() => { location.hash = '#dms'; }); await page.locator('#compose').waitFor({state: 'detached'});
  state.heldHistory = true;
  const historyRequest = page.waitForRequest(request => new URL(request.url()).pathname === '/api/messages');
  await page.evaluate(() => { location.hash = '#dm/1'; }); await historyRequest;
  for (let attempt = 0; typeof state.heldHistory !== 'function' && attempt < 100; attempt++) await page.waitForTimeout(10);
  const staleHistory = state.heldHistory; assert.equal(typeof staleHistory, 'function');
  await page.evaluate(() => { location.hash = '#dms'; }); await page.locator('#compose').waitFor({state: 'detached'});
  state.heldHistory = null; state.stored[0] = {...state.stored[0], body: 'Fresh history after returning', edited_at: Date.now()};
  await page.evaluate(() => { location.hash = '#dm/1'; }); await page.getByText('Fresh history after returning', {exact: true}).waitFor();
  await staleHistory();
  assert.equal(await page.getByText('Fresh history after returning', {exact: true}).count(), 1, 'returning to the same route cannot admit an earlier visit’s response');

  await page.locator('#compose').fill('😀'.repeat(1251));
  assert.equal(await page.getByRole('button', {name: 'Send message', exact: true}).isDisabled(), true, 'UTF-8 limits match the backend before sending');
  await page.locator('#compose').fill('😀'.repeat(1250));
  assert.equal(await page.getByRole('button', {name: 'Send message', exact: true}).isDisabled(), false, 'the exact UTF-8 boundary is accepted');
  await page.locator('#compose').fill('');
  if (await page.locator('.toast button').count()) await page.locator('.toast button').click();
  await mkdir('test-results', {recursive: true});
  await page.screenshot({path: 'test-results/chat-refined-desktop.png'});
  for (const width of [320, 360, 390, 540, 768, 1280, 1920]) {
    await page.setViewportSize({width, height: 844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `chat fits ${width}px`);
    const sendBox = await page.locator('.composer-send').boundingBox();
    assert(sendBox && sendBox.width >= 44 && sendBox.height >= 44 && sendBox.y + sendBox.height < 844, `send is reachable at ${width}px`);
  }
  await page.setViewportSize({width: 390, height: 844});
  await page.screenshot({path: 'test-results/chat-refined-mobile.png'});
  await context.close();

  const group = await setup({storageDenied: true, group: true});
  await send(group.page, 'Groups do not need a key database');
  await group.page.locator('.msg[data-mid="100"]').waitFor({timeout: 7000});
  assert.equal(group.state.requests.length, 1, 'unencrypted group sends work with browser key storage denied');
  await group.context.close();

  const changed = await setup(); changed.state.token = 'other-account'; changed.state.person = people[1];
  const refreshed = changed.page.waitForResponse(response => new URL(response.url()).pathname === '/api/me');
  const reloaded = changed.page.waitForEvent('framenavigated', frame => frame === changed.page.mainFrame());
  await send(changed.page, 'Never send this as another account');
  await refreshed; await reloaded;
  assert.equal(changed.state.requests.length, 1, 'account changes never replay a private draft under the new account');
  assert.equal(changed.state.stored.length, 0);
  await changed.context.close();
  assert.deepEqual(errors, []);
  console.log('PASS: first-send session recovery, safe replay boundaries, pending-message identity, UTF-8 limits, group storage isolation, account-change protection and responsive chat.');
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
