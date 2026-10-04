import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';
import { me, people, servers as fixtureServers, conversations } from './fixtures.mjs';

const root = resolve('priv/static');
const version = (await readFile('VERSION', 'utf8')).trim();
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const path = resolve(root, url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/assets\//, ''));
    if (!path.startsWith(root + '/')) throw Error('path');
    res.writeHead(200, { 'content-type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' })[extname(path)] || 'application/octet-stream' });
    res.end(await readFile(path));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = 'http://127.0.0.1:' + server.address().port;
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const errors = [];
let servers = fixtureServers.map(s => ({ ...s, role: 'owner', permissions: 2147483647 }));
let layout = { items: servers.map(s => ({ server_id: s.id })), revision: 0 };
let serverAdvance = 0;
const serverNow = () => Date.now() + serverAdvance;
let failChannel = true;
let failServer = true;
let lastCreation;
let lastMessage;
let heldGaming;
let holdServerOne = false;
let heldServerOne;
let channels = [{ id: 10, server_id: 1, name: 'general', kind: 'text', position: 1, category_id: null, topic: '', created_at: Date.now() }];
const imported = { format: 'plainwire-server-template-v1', name: '<img src=x onerror=alert(1)>', categories: [{ name: 'Project' }], roles: [{ name: 'Staff', color: '#99aab5' }], channels: [{ name: 'planning', kind: 'text', category: 0, topic: '', slowmode_seconds: 0 }] };
const preview = name => ({ template: name, permissions_review: false, warnings: [], preview: { name: name === 'friends' ? 'Friends' : 'Gaming', categories: [{ name: 'Hangout' }], roles: [], channels: [{ name: 'general', kind: 'text', category: 0 }, { name: 'Lounge', kind: 'voice', category: 0 }] } });
const group = { ...conversations[0], name: 'group dm 1', member_count: 3, e2ee_key_id: '', e2ee_enabled: false, e2ee_revision: 0, members: people.slice(0, 3).map(user => ({ user, role: user.id === 1 ? 'owner' : 'member' })) };
async function setup(context) {
  await context.route('**/api/**', async route => {
    const req = route.request(); const path = new URL(req.url()).pathname; const method = req.method();
    const reply = data => route.fulfill({ json: { ok: true, data } });
    const error = (code, status = 400) => route.fulfill({ status, json: { ok: false, error: code } });
    if (path === '/api/client-config') return route.fulfill({ json: { app_name: 'Plainwire', version, asset_version: version, registration_enabled: true } });
    if (path === '/api/me') return reply({ user: me, csrf: 'workspace-test', server_time: serverNow() });
    if (path === '/api/sync') return reply({ conversations: [group], servers, friends: [], notifications: [], now: serverNow() });
    if (path === '/api/server-layout') {
      if (method === 'POST') {
        const body = req.postDataJSON(); if (body.revision !== layout.revision) return error('server_layout_changed', 409);
        layout = { items: body.items, revision: layout.revision + 1 };
      }
      const existing = layout.items.flatMap(item => item.server_ids || [item.server_id]);
      return reply({ ...layout, items: [...layout.items, ...servers.filter(s => !existing.includes(s.id)).map(s => ({ server_id: s.id }))] });
    }
    if (path === '/api/server-templates/preview') {
      const template = req.postDataJSON().template;
      if (template === 'gaming') { heldGaming = () => reply(preview('gaming')); return; }
      if (typeof template === 'string') return reply(preview(template));
      return reply({ template: imported, preview: imported, permissions_review: true, warnings: ['Imported servers start with member access disabled.'] });
    }
    if (path === '/api/server-templates/discord') return error('template_not_found', 404);
    if (path === '/api/servers' && method === 'POST') {
      lastCreation = req.postDataJSON();
      if (failServer) { failServer = false; return error('server_exists'); }
      servers = [...servers, { ...servers[0], id: 3, name: lastCreation.name }];
      return reply({ id: 3, permissions_review: true });
    }
    if (/^\/api\/server\/\d+$/.test(path)) {
      const sid = Number(path.split('/').at(-1));
      if (sid === 1 && holdServerOne) { heldServerOne = () => reply({ server: servers[0], channels, categories: [], members: group.members }); return; }
      return reply({ server: servers.find(s => s.id === sid), channels: sid === 1 ? channels : [], categories: [], members: group.members });
    }
    if (path === '/api/server/1/channels' && method === 'POST') {
      if (failChannel) { failChannel = false; return error('channel_exists'); }
      const data = { ...req.postDataJSON(), id: 11, server_id: 1, position: 2, topic: '', created_at: serverNow() }; channels.push(data); return reply(data);
    }
    if (path === '/api/conversation/1') return reply({ conversation: group, members: group.members });
    if (path === '/api/messages') return reply([]);
    if (path === '/api/conversation/1/messages') { lastMessage = req.postDataJSON(); return reply({ id: 99, scope: 'direct', scope_id: 1, user_id: me.id, username: me.username, display_name: me.display_name, avatar_url: '', body: lastMessage.body, reply_to_id: null, created_at: serverNow(), edited_at: null, deleted_at: null }); }
    if (path === '/api/rtc-config') return reply({ iceServers: [] });
    if (path === '/api/voice-processing-config') return reply({ krisp_available: false });
    return reply({});
  });
  await context.routeWebSocket('**/ws', ws => ws.send(JSON.stringify({ type: 'hello', session: { user: me } })));
}
try {
  await mkdir('test-results', { recursive: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } }); await setup(context);
  const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin); await page.getByRole('button', { name: 'More servers', exact: true }).waitFor();
  await page.locator('.rail button[title="The Workshop"]').dragTo(page.locator('.rail button[title="After Hours"]'));
  await page.locator('.rail-folder').waitFor();
  assert.deepEqual([...layout.items[0].server_ids].sort(), [1,2], 'dragging servers onto each other creates a persisted folder');
  await page.locator('.rail-folder .server-folder-toggle').click();
  await page.locator('.rail-folder .server-folder-members').waitFor({ state: 'detached' });
  assert.equal(await page.locator('.rail-folder .server-folder-members').count(), 0, 'collapsed folder hides members');
  await page.reload(); await page.locator('.rail-folder .server-folder-toggle[aria-expanded="false"]').waitFor();
  await page.setViewportSize({ width: 360, height: 640 });
  await page.evaluate(() => document.querySelector('.rail button[title="More servers"]').click());
  await page.getByRole('button', { name: 'Organize servers', exact: true }).click();
  await page.getByLabel('Rename New folder', { exact: true }).fill('Friends & projects');
  await page.getByRole('button', { name: 'Save name', exact: true }).click();
  await page.getByLabel('Rename Friends & projects', { exact: true }).waitFor();
  assert.equal(layout.items[0].name, 'Friends & projects');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'mobile organizer fits the viewport');
  await page.screenshot({ path: 'test-results/server-folders-mobile.png' });
  await page.getByRole('button', { name: 'Ungroup servers', exact: true }).click();
  await page.getByText('Folders saved.', { exact: true }).waitFor();
  assert(layout.items.every(item => item.server_id), 'ungrouping restores loose servers');
  await page.keyboard.press('Escape');
  await page.evaluate(() => { location.hash = '#new-server'; });
  await page.waitForFunction(() => !!customElements.get('pw-server-template-picker'));
  await page.getByRole('combobox', { name: 'Server template' }).selectOption('gaming');
  await page.getByRole('button', { name: 'Create server', exact: true }).isDisabled().then(disabled => assert(disabled, 'creation waits for template preview'));
  await page.getByRole('combobox', { name: 'Server template' }).selectOption('friends');
  await page.locator('.template-preview').getByText('Friends', { exact: true }).waitFor();
  await heldGaming();
  assert.equal(await page.locator('.template-preview').getByText('Friends', { exact: true }).count(), 1, 'late preview cannot replace newer selection');
  await page.getByRole('combobox', { name: 'Server template' }).selectOption('import');
  await page.getByPlaceholder('https://discord.new/…').fill('https://discord.new/missing');
  await page.getByRole('button', { name: 'Preview Discord template', exact: true }).click();
  await page.getByText('This Discord template does not exist or is no longer available.', { exact: true }).waitFor();
  assert(await page.getByRole('button', { name: 'Create server', exact: true }).isDisabled(), 'invalid import cannot create a server');
  await page.locator('pw-server-template-picker input[type="file"]').setInputFiles({ name: 'template.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(imported)) });
  await page.getByText('Review access permissions after creating this server.', { exact: true }).waitFor();
  assert.equal(await page.locator('.template-preview img').count(), 0, 'template names render as text');
  await page.getByPlaceholder('Weekend crew').fill('Project space');
  await page.getByRole('button', { name: 'Create server', exact: true }).click();
  await page.getByRole('button', { name: 'Create server', exact: true }).waitFor({ state: 'visible' });
  await page.getByText('You already have a server with that name.', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Create server', exact: true }).isEnabled().then(enabled => assert(enabled, 'failed creation is retryable'));
  assert.equal(await page.getByPlaceholder('Weekend crew').inputValue(), 'Project space', 'failed creation preserves the name');
  await page.screenshot({ path: 'test-results/server-template-mobile.png' });
  await page.getByRole('button', { name: 'Create server', exact: true }).click();
  await page.waitForFunction(() => location.hash === '#server/3');
  assert.deepEqual(lastCreation.template, imported, 'creation uses the previewed import');
  await page.locator('.rail button[title="Project space"]').waitFor({ state: 'attached' });
  await page.setViewportSize({ width: 1280, height: 900 });
  holdServerOne = true;
  await page.evaluate(() => { location.hash = '#server/1'; });
  await page.locator('.server-side-head').waitFor({ state: 'detached' });
  assert.equal(await page.getByRole('button', { name: 'Add channel', exact: true }).count(), 0, 'navigation does not expose creation controls for the previous server');
  const deadline = Date.now() + 5000;
  while (!heldServerOne && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
  assert(heldServerOne); holdServerOne = false; await heldServerOne();
  await page.locator('.side-title-copy').getByText('The Workshop', { exact: true }).waitFor();
  await page.locator('.server-side-head').getByRole('button', { name: 'Add channel', exact: true }).click();
  await page.getByPlaceholder('general, updates, voice-chat').fill('new-channel');
  await page.getByRole('button', { name: 'Create channel', exact: true }).click();
  await page.getByText('A channel with that name already exists in this server.', { exact: true }).waitFor();
  assert.equal(await page.getByPlaceholder('general, updates, voice-chat').inputValue(), 'new-channel', 'failed creation preserves the channel form');
  await page.getByRole('button', { name: 'Create channel', exact: true }).click();
  await page.getByPlaceholder('general, updates, voice-chat').waitFor({ state: 'detached' });
  await page.locator('.server-channel-list').getByText('new-channel', { exact: true }).waitFor();

  const skewContext = await browser.newContext(); await setup(skewContext);
  const skewPage = await skewContext.newPage(); skewPage.on('pageerror', error => errors.push(error.message));
  await skewPage.clock.install({ time: new Date(Date.now() + 60000) });
  await skewPage.goto(origin + '/#dm/1'); await skewPage.waitForSelector('#compose');
  serverAdvance += 31000; await skewPage.clock.fastForward(31000);
  await skewPage.locator('#compose').fill('Fresh group message');
  await skewPage.locator('.composer-send').click();
  await skewPage.locator('.msg[data-mid="99"]').waitFor().catch(async error => {
    console.log({ lastMessage, errors, text: await skewPage.locator('body').innerText() }); throw error;
  });
  assert.equal(await skewPage.locator('.msg[data-mid="99"] .msg-time').textContent(), 'Just now', 'fresh group messages use server time after a periodic tick on a fast client clock');
  assert.deepEqual(errors, [], 'no runtime errors in workspace controls');
  console.log('PASS: persisted server drag folders, collapse/reload, mobile rename/ungroup, template preview race isolation, invalid Discord import, safe JSON preview, retryable server and channel creation, immediate server navigation refresh, and group timestamps under client clock skew.');
} finally { await browser.close(); server.close(); }
