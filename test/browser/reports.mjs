import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { chromium } from 'playwright';
import { me, people, now, sync, messages, conversations } from './fixtures.mjs';

const version = (await readFile('VERSION', 'utf8')).trim();
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3qkAAAAASUVORK5CYII=', 'base64');
async function serve(directory) {
  const root = resolve(directory);
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      const path = resolve(root, url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/assets\//, '').replace(/^\//, ''));
      if (!path.startsWith(root + '/')) throw Error('path');
      res.writeHead(200, { 'content-type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' })[extname(path)] || 'application/octet-stream' });
      res.end(await readFile(path));
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}
const app = await serve('priv/static'), admin = await serve('priv/admin');
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const errors = [], posts = [], reports = [], submissions = new Map();
let profileBlocked = false;
let uploads = 0, failResponse = true, delayDetails = false, releaseDetail, adminRole = 'owner';
const publicReport = report => { const { history, reporter_id, reporter_username, reporter_display_name, message_context, assignee_id, ...safe } = report; return safe; };
const response = (route, data, status = 200, error) => route.fulfill({ status, json: { ok: status < 400, data, ...(error ? { error } : {}) } });
const list = url => ({ items: reports.filter(r => url.searchParams.get('status') !== 'active' || ['open', 'in_review'].includes(r.status)).toReversed(), next_before: null, counts: { open: reports.filter(r => r.status === 'open').length, in_review: reports.filter(r => r.status === 'in_review').length } });
async function reportApi(route, isAdmin) {
  const req = route.request(), url = new URL(req.url()), path = url.pathname, method = req.method();
  if (method !== 'GET') posts.push({ isAdmin, path, body: req.postDataJSON(), csrf: req.headers()['x-csrf-token'] });
  if (/\/evidence\/\d+$/.test(path)) return route.fulfill({ contentType: 'image/png', body: png });
  if (path === '/api/reports' && method === 'GET') {
    const data = list(url); if (!isAdmin) data.items = reports.toReversed().map(publicReport);
    return response(route, data);
  }
  if (path === '/api/reports' && method === 'POST') {
    const body = req.postDataJSON(); let report = submissions.get(body.request_key);
    if (!report) {
      report = { id: reports.length + 1, reporter_id: me.id, reporter_username: me.username, reporter_display_name: me.display_name, subject_id: body.user_id, subject_username: people[1].username, subject_display_name: people[1].display_name, category: body.category, reason: body.reason, message_context: body.message_id ? { message_id: body.message_id, created_at: now, ...(body.include_message ? { body: messages[0].body } : {}) } : {}, evidence: body.evidence_ids.map((id, i) => ({ id: i + 1, name: 'screenshot.png', content_type: 'image/png', size: png.length })), status: 'open', priority: 'normal', assignee_id: null, public_response: '', revision: 1, created_at: now, updated_at: now, history: [{ id: 1, actor_username: me.username, action: 'submitted', note: '', created_at: now }] };
      submissions.set(body.request_key, report); reports.push(report);
    }
    if (failResponse) { failResponse = false; return response(route, null, 503, 'database_busy'); }
    return response(route, publicReport(report));
  }
  const report = reports.find(r => r.id === Number(path.split('/')[3]));
  if (!report) return response(route, null, 404, 'not_found');
  if (method === 'GET') {
    if (delayDetails) { delayDetails = false; releaseDetail = () => response(route, report); return; }
    return response(route, report);
  }
  const body = req.postDataJSON();
  if (body.expected_revision !== report.revision) return response(route, null, 409, 'report_conflict');
  if (path.endsWith('/withdraw')) report.status = 'withdrawn';
  else if (body.action === 'claim') { report.assignee_id = 3; report.status = 'in_review'; }
  else if (body.action === 'unassign') { report.assignee_id = null; report.status = 'open'; }
  else if (body.action === 'priority') report.priority = body.priority;
  else if (['resolve', 'dismiss'].includes(body.action)) { report.status = body.action === 'resolve' ? 'resolved' : 'dismissed'; report.public_response = body.public_response; report.resolution = body.resolution; }
  else if (body.action === 'reopen') { report.status = 'in_review'; report.assignee_id = 3; report.public_response = ''; }
  report.revision++; report.history.unshift({ id: report.revision, actor_username: 'owner', action: body.action || 'withdrawn', note: body.note || '', created_at: now });
  return response(route, isAdmin ? report : publicReport(report));
}
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path.startsWith('/api/reports')) return reportApi(route, false);
    if (path === '/api/uploads') { uploads++; assert.equal(req.headers()['x-csrf-token'], 'report-csrf'); return response(route, { id: 'report-file-1234567890123456', name: 'screenshot.png', type: 'image/png', size: png.length }); }
    if (path === '/api/client-config') return route.fulfill({ json: { app_name: 'Plainwire', version, registration_enabled: true } });
    if (path === '/api/me') return response(route, { user: me, csrf: 'report-csrf', server_time: now });
    if (path === '/api/sync') return response(route, sync);
    if (/^\/api\/profile\/\d+$/.test(path)) return response(route, { user: people[Number(path.split('/').at(-1)) - 1], relationship: { status: profileBlocked ? 'blocked' : 'none', blocked_by_me: profileBlocked } });
    if (path === '/api/messages') return response(route, messages);
    if (path === '/api/conversation/1') return response(route, { conversation: conversations[0], members: conversations[0].members });
    if (path === '/api/rtc-config') return response(route, { iceServers: [] });
    return response(route, []);
  });
  await context.routeWebSocket('**/ws', ws => ws.send(JSON.stringify({ type: 'hello', session: { user: me } })));
  const page = await context.newPage(); page.on('pageerror', e => errors.push(e.message));
  await page.goto(app.origin + '/#dm/1'); await page.locator('.msg[data-mid="1"]').waitFor();
  await page.locator('#compose').fill('Keep this draft');
  await page.locator('.msg[data-mid="1"]').click({ button: 'right' });
  await page.getByText('Report message', { exact: true }).click();
  const dialog = page.getByRole('dialog');
  await dialog.locator('[name="reason"]').fill('<img src=x onerror=alert(1)> Report reason');
  await dialog.locator('[name="category"]').selectOption('harassment');
  await dialog.locator('[name="include_message"]').check();
  await dialog.locator('[name="evidence"]').setInputFiles({ name: 'screenshot.png', mimeType: 'image/png', buffer: png });
  await page.waitForFunction(() => document.querySelector('.report-evidence-gallery img')?.naturalWidth > 0);
  await dialog.getByRole('button', { name: 'Submit report', exact: true }).click();
  await dialog.getByRole('status').filter({ hasText: 'server is busy' }).waitFor();
  await dialog.getByRole('button', { name: 'Submit report', exact: true }).click();
  await dialog.getByRole('heading', { name: 'Report #1 submitted' }).waitFor();
  assert.equal(reports.length, 1, 'an ambiguous failed response can be retried without a duplicate case');
  assert.equal(uploads, 1, 'retry reuses the successfully uploaded evidence');
  const attempts = posts.filter(p => !p.isAdmin && p.path === '/api/reports');
  assert.equal(attempts[0].body.request_key, attempts[1].body.request_key);
  assert.equal(attempts[0].body.user_id, 2); assert.equal(attempts[0].body.include_message, true);
  assert.equal(attempts[0].csrf, 'report-csrf');
  await dialog.getByRole('button', { name: 'Done', exact: true }).click();
  assert.equal(await page.locator('#compose').inputValue(), 'Keep this draft', 'report uploads do not attach evidence or clear the chat draft');

  // Profile reports are available on desktop and phone, including blocked
  // accounts. A rejected file selection keeps the existing evidence intact.
  await page.goto(app.origin + '/#profile/2');
  await page.getByRole('button', { name: 'Report user', exact: true }).click();
  await page.getByRole('dialog').locator('[name="evidence"]').setInputFiles({ name: 'first.png', mimeType: 'image/png', buffer: png });
  await page.getByRole('dialog').locator('[name="evidence"]').setInputFiles({ name: 'unsafe.svg', mimeType: 'image/svg+xml', buffer: Buffer.from('<svg/>') });
  assert.equal(await page.locator('.report-evidence-gallery figure').count(), 1);
  await page.getByRole('button', { name: 'Remove screenshot first.png', exact: true }).click();
  assert.equal(await page.locator('.report-evidence-gallery figure').count(), 0);
  await page.locator('.report-form textarea').evaluate((node, bytes) => {
    const transfer = new DataTransfer();
    transfer.items.add(new File([new Uint8Array(bytes)], 'pasted.png', { type: 'image/png' }));
    node.dispatchEvent(new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true }));
  }, [...png]);
  await page.getByRole('button', { name: 'Remove screenshot pasted.png', exact: true }).waitFor();
  assert.equal(await page.getByRole('dialog').locator('[name="include_message"]').count(), 0, 'profile reports never imply sharing a chat message');
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
  profileBlocked = true;
  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload(); await page.getByRole('button', { name: 'Unblock', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Report user', exact: true }).click();
  assert.ok(await page.getByRole('dialog').evaluate(node => node.scrollWidth <= node.clientWidth + 2));
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
  await page.goto(app.origin + '/#profile/1'); await page.getByRole('button', { name: 'Edit profile', exact: true }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Report user', exact: true }).count(), 0, 'self profile offers report history instead of self reporting');
  await page.getByRole('button', { name: 'My reports', exact: true }).click();
  await page.locator('.report-case-card').waitFor();
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(app.origin + '/#dm/1'); await page.locator('.msg[data-mid="1"]').waitFor();

  const operators = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await operators.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path.startsWith('/api/reports')) return reportApi(route, true);
    if (path === '/api/status') return response(route, { instance_id: 'report-test', bootstrap_available: false });
    if (path === '/api/me') return response(route, { username: 'owner', display_name: 'Owner', role: adminRole, user_id: 3, csrf: 'operator-csrf' });
    if (path === '/api/overview') return response(route, { runtime: {} });
    if (path === '/api/users/2/moderation' && req.method() === 'POST') {
      const body = req.postDataJSON(); posts.push({ isAdmin: true, path, body, csrf: req.headers()['x-csrf-token'] });
      assert.equal(body.report_id, 1); assert.equal(body.report_revision, reports[0].revision);
      reports[0].status = 'resolved'; reports[0].resolution = 'action_taken'; reports[0].public_response = 'Reviewed. Moderation action was taken.'; reports[0].revision++;
      return response(route, { account_state: 'suspended' });
    }
    return response(route, []);
  });
  const panel = await operators.newPage(); panel.on('pageerror', e => errors.push(e.message));
  await panel.goto(admin.origin); await panel.locator('#app').waitFor({ state: 'visible' });
  await panel.locator('[data-view="reports"]').click();
  await panel.locator('.report-queue-item[data-report-id="1"]').click();
  await panel.locator('.report-detail').waitFor();
  assert.ok((await panel.locator('.report-detail').textContent()).includes(me.username));
  assert.ok((await panel.locator('.report-detail').textContent()).includes(people[1].username));
  assert.equal(await panel.locator('.report-detail .report-text').first().textContent(), '<img src=x onerror=alert(1)> Report reason');
  assert.equal(await panel.locator('.report-detail .report-text img').count(), 0, 'reported text is never rendered as markup');
  assert.equal(await panel.locator('.report-detail pre').textContent(), messages[0].body);
  await panel.waitForFunction(() => document.querySelector('.report-evidence-gallery img')?.naturalWidth > 0);
  await panel.getByRole('button', { name: 'Assign to me', exact: true }).click();
  await panel.getByRole('button', { name: 'Unassign', exact: true }).waitFor();
  await panel.locator('.report-actions select[name="priority"]').selectOption('urgent');
  await panel.getByRole('button', { name: 'Set priority', exact: true }).click();
  await panel.locator('.report-status').filter({ hasText: 'Urgent' }).first().waitFor();
  await panel.locator('.report-note-form textarea').fill('Private operator assessment');
  await panel.getByRole('button', { name: 'Add internal note', exact: true }).click();
  await panel.locator('.report-history').getByText('Private operator assessment', { exact: true }).waitFor();
  reports[0].revision++;
  await panel.locator('.report-note-form textarea').fill('Stale note');
  await panel.getByRole('button', { name: 'Add internal note', exact: true }).click();
  await panel.locator('.toast').filter({ hasText: 'This case changed' }).waitFor();
  assert.ok(!reports[0].history.some(h => h.note === 'Stale note'));
  await panel.getByRole('button', { name: 'Reload case', exact: true }).click();
  await panel.locator('.report-note-form').waitFor();
  await panel.getByRole('button', { name: 'Suspend account', exact: true }).click();
  await panel.locator('#account-moderation-form input[name="reason"]').fill('Repeated policy violation');
  await panel.getByRole('button', { name: 'Suspend account', exact: true }).click();
  await panel.locator('.report-status').filter({ hasText: 'Resolved' }).waitFor();
  assert.equal(posts.find(p => p.path === '/api/users/2/moderation').csrf, 'operator-csrf');
  assert.equal(posts.find(p => p.path === '/api/users/2/moderation').body.reason, 'Repeated policy violation');

  await page.locator('.workspace-menu summary').click();
  await page.getByRole('button', { name: 'My reports', exact: true }).click();
  await page.locator('.report-case-card').waitFor();
  assert.ok((await page.locator('.report-case-card').textContent()).includes('Moderation action was taken'));
  assert.ok(!(await page.locator('.report-case-card').textContent()).includes('Private operator assessment'));
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();

  // Screenshot-only reporting, reason validation, and withdrawal on a phone.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('.msg[data-mid="1"]').click({ button: 'right' }); await page.getByText('Report message', { exact: true }).click();
  await page.getByRole('button', { name: 'Submit report', exact: true }).click();
  await page.getByRole('status').filter({ hasText: 'Add a reason' }).waitFor();
  await page.locator('[name="evidence"]').setInputFiles({ name: 'unsafe.svg', mimeType: 'image/svg+xml', buffer: Buffer.from('<svg/>') });
  await page.getByRole('status').filter({ hasText: 'PNG or JPEG' }).waitFor();
  await page.locator('[name="evidence"]').setInputFiles({ name: 'screenshot.png', mimeType: 'image/png', buffer: png });
  await page.getByRole('button', { name: 'Submit report', exact: true }).click();
  await page.getByRole('heading', { name: 'Report #2 submitted' }).waitFor();
  assert.equal(reports[1].reason, ''); assert.equal(reports[1].message_context.body, undefined, 'message sharing is opt-in');
  await page.getByRole('dialog').getByRole('button', { name: 'My reports', exact: true }).click();
  await page.locator('.report-case-card[data-report-id="2"]').waitFor();
  assert.ok(await page.getByRole('dialog').evaluate(node => node.scrollWidth <= node.clientWidth + 2), 'report modal fits mobile width');
  page.once('dialog', dialog => dialog.accept());
  await page.locator('.report-case-card[data-report-id="2"]').getByRole('button', { name: 'Withdraw report' }).click();
  await page.locator('.report-case-card[data-report-id="2"] .report-status').filter({ hasText: 'Withdrawn' }).waitFor();

  await panel.setViewportSize({ width: 390, height: 844 });
  await panel.locator('.report-decision-form textarea[name="note"]').fill('Additional review required');
  await panel.getByRole('button', { name: 'Reopen report' }).click();
  await panel.locator('.report-decision-form select').waitFor();
  await panel.locator('.report-decision-form textarea[name="note"]').fill('Reviewed evidence; dismissing duplicate');
  await panel.locator('.report-decision-form select').selectOption('duplicate');
  await panel.locator('.report-decision-form textarea[name="public_response"]').fill('This was reviewed with the original case.');
  await panel.getByRole('button', { name: 'Dismiss report' }).click();
  await panel.locator('.report-status').filter({ hasText: 'Dismissed' }).waitFor();
  assert.ok(await panel.locator('.modal').evaluate(node => node.scrollWidth <= node.clientWidth + 2), 'moderation case fits mobile width');
  await mkdir('test-results', { recursive: true }); await panel.screenshot({ path: 'test-results/reports-admin-mobile.png' });
  await panel.locator('#modal-close').click();
  await panel.setViewportSize({ width: 1440, height: 1000 });
  await panel.locator('.report-filters select[name="status"]').selectOption('all'); await panel.getByRole('button', { name: 'Filter reports' }).click();
  delayDetails = true; await panel.locator('.report-queue-item[data-report-id="1"]').click();
  await panel.waitForFunction(() => document.querySelector('#modal-subtitle').textContent === 'Loading case…');
  await panel.locator('#modal-close').click();
  for (let i = 0; !releaseDetail && i < 100; i++) await new Promise(r => setTimeout(r, 20));
  assert.ok(releaseDetail); await releaseDetail();
  await panel.waitForTimeout(150); assert.equal(await panel.locator('#modal-backdrop').isVisible(), false, 'late case responses do not reopen a dismissed modal');
  adminRole = 'viewer'; await panel.reload(); await panel.locator('#app').waitFor({ state: 'visible' });
  assert.equal(await panel.locator('[data-view="reports"]').isVisible(), false, 'viewers cannot open reports');
  assert.deepEqual(errors, []);
  console.log('PASS: reporting forms, scoped evidence, screenshot-only reports, retry idempotency, draft isolation, private admin review, assignment, conflicts, linked restrictions, decisions, withdrawal, stale modals, viewer isolation, and mobile layouts.');
} finally {
  await browser.close(); await Promise.all([app.server, admin.server].map(server => new Promise(r => server.close(r))));
}
