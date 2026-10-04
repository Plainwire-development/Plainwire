import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { chromium } from 'playwright';
import { me, people, now, sync, servers, message } from './fixtures.mjs';

const root = resolve('priv/static');
const version = (await readFile('VERSION', 'utf8')).trim();
const workerHandler = await readFile('src/pw_plugin_worker.erl', 'utf8');
const workerCsp = workerHandler.match(/<<"(default-src 'none'; script-src 'unsafe-eval';[^"\n]+)"/)[1];
let escapedRequests = 0;
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/plugin-escape') { escapedRequests++; res.writeHead(200); return res.end('{}'); }
    const path = resolve(root, url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/assets\//, ''));
    if (!path.startsWith(root + '/')) throw new Error('path');
    const headers = { 'content-type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' })[extname(path)] || 'application/octet-stream' };
    if (url.pathname === '/assets/plugin-worker.js') headers['content-security-policy'] = workerCsp;
    if (url.pathname === '/') headers['content-security-policy'] = "default-src 'self'; script-src 'self'; worker-src 'self' blob:; connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:";
    res.writeHead(200, headers); res.end(await readFile(path));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const errors = [];
const delayed = new Map();
let invocationNumber = 0;
let socket;
const command = { id: 1, name: 'echo', description: 'Echo', bot: { id: 1, user_id: 5, name: 'Echo' }, options: [] };
const serverData = id => ({ server: servers[id - 1], channels: [{ id, server_id: id, name: `channel-${id}`, kind: 'text', position: 0, created_at: now }], members: [], categories: [] });
const threadData = id => ({ thread: { id, forum_id: id, user_id: me.id, username: me.username, display_name: me.display_name, title: `Thread ${id}`, body: `Body ${id}`, created_at: now, updated_at: now }, replies: [] });

try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 960 } });
  await context.addInitScript(() => {
    localStorage.setItem('plainwire_extensions_v2', JSON.stringify({ themes: [], plugins: [{
      id: 'audit', name: 'Audit', enabled: true, permissions: { apiWrite: false },
      source: `(async () => {
        const result = {};
        await Plainwire.request('/me'); result.read = 'allowed';
        try { await Plainwire.request('/plugin-escape', { method: 'POST', body: {} }); result.write = 'escaped'; }
        catch { result.write = 'blocked'; }
        try { await Plainwire.request('/%2e%2e/plugin-escape'); result.traversal = 'escaped'; }
        catch { result.traversal = 'blocked'; }
        await Plainwire.storage.set('result', result);
      })();`
    }] }));
  });
  await context.route('**/api/**', async route => {
    const request = route.request(), url = new URL(request.url()), path = url.pathname;
    const reply = data => route.fulfill({ json: { ok: true, data } });
    if (path === '/api/client-config') return route.fulfill({ json: { app_name: 'Plainwire', version, registration_enabled: true } });
    if (path === '/api/me') return reply({ user: me, csrf: 'audit-csrf', server_time: now });
    if (path === '/api/sync') return reply(sync);
    if (path === '/api/messages') return reply([]);
    if (path.startsWith('/api/server/')) {
      const id = Number(path.split('/')[3]);
      if (id === 1 && !delayed.has('server')) { delayed.set('server', () => reply(serverData(id))); return; }
      return reply(serverData(id));
    }
    if (path.startsWith('/api/thread/')) {
      const id = Number(path.split('/')[3]);
      if (id === 1) { delayed.set('thread', () => reply(threadData(id))); return; }
      return reply(threadData(id));
    }
    if (path.startsWith('/api/profile/')) {
      const id = Number(path.split('/')[3]);
      if (id === 2) { delayed.set('profile', () => reply({ user: people[1] })); return; }
      return reply({ user: people.find(user => user.id === id) });
    }
    if (path === '/api/commands') return reply(url.searchParams.get('channel_id') === '1' ? [command] : []);
    if (path === '/api/commands/echo/invoke') {
      const number = ++invocationNumber;
      delayed.set(`invoke-${number}`, () => reply({ message: { ...message(100 + number, `/echo request-${number}`, 1, me), scope: 'channel' } }));
      return;
    }
    if (path === '/api/plugin-escape') { escapedRequests++; return reply({}); }
    return reply([]);
  });
  await context.routeWebSocket('**/ws', connection => {
    socket = connection;
    connection.send(JSON.stringify({ type: 'hello', session: { user: me } }));
  });
  const page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin); await page.waitForSelector('.home-welcome');
  await page.waitForFunction(() => localStorage.getItem('plainwire_plugin_audit_result'));
  assert.deepEqual(await page.evaluate(() => JSON.parse(localStorage.getItem('plainwire_plugin_audit_result'))), {
    read: 'allowed', write: 'blocked', traversal: 'blocked'
  }, 'installed plugins use the parent RPC permissions and their own storage namespace');

  // Execute a real plugin under the page's production-style script policy.
  // Restore networking from its prototype to test the browser boundary itself.
  const workerResult = await page.evaluate(() => new Promise((resolve, reject) => {
    const worker = new Worker('/assets/plugin-worker.js');
    const timeout = setTimeout(() => { worker.terminate(); reject(new Error('plugin timed out')); }, 10000);
    worker.onerror = event => { clearTimeout(timeout); worker.terminate(); reject(new Error(event.message)); };
    worker.onmessage = event => {
      if (event.data.kind === 'toast') { clearTimeout(timeout); worker.terminate(); resolve(JSON.parse(event.data.text)); }
      if (event.data.kind === 'error') { clearTimeout(timeout); worker.terminate(); reject(new Error(event.data.error)); }
    };
    worker.postMessage({ kind: 'initialize', version: 'test', source: `
      (async () => {
        const result = {};
        try { await Object.getPrototypeOf(self).fetch.call(self, '/api/plugin-escape', { method: 'POST', body: '{}' }); result.fetch = 'escaped'; }
        catch { result.fetch = 'blocked'; }
        try { Object.getPrototypeOf(self).importScripts.call(self, '/api/plugin-escape'); result.import = 'escaped'; }
        catch { result.import = 'blocked'; }
        try { result.worker = await new Promise((resolve, reject) => {
          const nested = new Worker('/api/plugin-escape');
          const timer = setTimeout(() => { nested.terminate(); reject(new Error('nested worker did not report denial')); }, 5000);
          nested.onerror = event => { event.preventDefault(); clearTimeout(timer); nested.terminate(); resolve('blocked'); };
          nested.onmessage = () => { clearTimeout(timer); nested.terminate(); resolve('escaped'); };
        }); }
        catch { result.worker = 'blocked'; }
        Plainwire.toast(JSON.stringify(result));
      })();` });
  }));
  assert.deepEqual(workerResult, { fetch: 'blocked', import: 'blocked', worker: 'blocked' });
  assert.equal(escapedRequests, 0);

  const navigate = async hash => {
    await page.evaluate(value => { location.hash = value; }, hash);
    const channel = hash.match(/^#channel\/(\d+)$/);
    if (channel) await page.locator(`.composer[data-draft="channel:${channel[1]}"]`).waitFor();
  };
  const waitDelayed = async key => { for (let i = 0; i < 100 && !delayed.has(key); i++) await page.waitForTimeout(20); assert(delayed.has(key), `request ${key} arrived`); };
  const release = async key => { await delayed.get(key)(); await page.waitForTimeout(100); };
  await navigate('#server/1'); await waitDelayed('server');
  await navigate('#server/2'); await page.locator('.server-side-head h1').filter({ hasText: servers[1].name }).waitFor();
  await release('server');
  assert.equal(await page.locator('.server-side-head h1').textContent(), servers[1].name, 'late server data cannot replace the current server');
  await navigate('#t/1'); await waitDelayed('thread');
  await navigate('#t/2'); await page.locator('.thread-page h1').filter({ hasText: 'Thread 2' }).waitFor();
  await release('thread');
  assert.equal(await page.locator('.thread-page h1').textContent(), 'Thread 2');
  await navigate('#profile/2'); await waitDelayed('profile');
  await navigate('#profile/3'); await page.getByRole('heading', { name: people[2].display_name, exact: true }).waitFor();
  await release('profile');
  await page.getByRole('heading', { name: people[2].display_name, exact: true }).waitFor();

  await navigate('#server/1'); await page.locator('.server-side-head h1').filter({ hasText: servers[0].name }).waitFor();
  await navigate('#channel/1'); await page.waitForSelector('#compose');
  socket.send(JSON.stringify({ type: 'typing', scope: 'channel', scope_id: 1,
    user_id: people[2].id, username: people[2].username, display_name: people[2].display_name, active: true }));
  await page.locator('pw-typing-indicator.is-active').filter({ hasText: people[2].display_name }).waitFor();
  socket.send(JSON.stringify({ type: 'typing', scope: 'channel', scope_id: 1,
    user_id: people[2].id, active: false }));
  await page.locator('#compose').fill('/echo first');
  await page.keyboard.press('Enter'); await waitDelayed('invoke-1');
  await page.locator('#compose').fill('A newer draft'); await release('invoke-1');
  assert.equal(await page.locator('#compose').inputValue(), 'A newer draft', 'command acknowledgement preserves a newer draft');
  await page.locator('#compose').fill('/echo second');
  await page.keyboard.press('Enter'); await waitDelayed('invoke-2');
  await navigate('#channel/2'); await page.locator('#compose').fill('Another channel draft');
  await release('invoke-2');
  assert.equal(await page.locator('#compose').inputValue(), 'Another channel draft', 'late command acknowledgement preserves another channel draft');
  await navigate('#channel/1');
  assert.equal(await page.locator('#compose').inputValue(), '', 'only the acknowledged original draft is cleared');

  await navigate('#settings'); await page.locator('[data-setting="appearance"]').click();
  const manage = page.locator('.setting-row').filter({ hasText: 'Themes & plugins' }).getByRole('button', { name: 'Manage', exact: true });
  await manage.click();
  const dialog = page.getByRole('dialog', { name: 'Themes & plugins', exact: true });
  await dialog.waitFor();
  assert.equal(await page.evaluate(() => document.body.inert), true);
  await dialog.getByRole('button', { name: 'Close', exact: true }).focus();
  await page.keyboard.press('Shift+Tab');
  assert.equal(await dialog.evaluate(node => node.contains(document.activeElement)), true, 'reverse tab stays inside the modal');
  await page.keyboard.press('Escape');
  assert.equal(await dialog.count(), 0);
  assert.equal(await page.evaluate(() => document.body.inert), false);
  assert.equal(await manage.evaluate(node => document.activeElement === node), true, 'closing restores the trigger focus');
  assert.deepEqual(errors, []);
  console.log('PASS: installed plugin RPC permissions and CSP block restored networking; delayed server/thread/profile responses; command draft isolation; accessible modal focus lifecycle.');
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
