import assert from 'node:assert/strict';
import { people } from './fixtures.mjs';

// Use the existing suite's real peer connections and media, including the third
// participant. HTTP identity and WebSocket signaling remain the only fixtures.
export async function testGroupInvitations({ a, b, setup, origin, send, clientMessages, finishInvitation }) {
  await Promise.all([a.goto(origin + '/?group-call=1#dm/1'), b.goto(origin + '/?group-call=1#dm/1')]);
  const c = await setup(3);
  for (const page of [a, b, c]) await page.locator('.group-member').filter({ hasText: 'Sam Rivera' }).waitFor();
  const member = (page, name) => page.getByRole('button', { name: `Open ${name}'s profile`, exact: true });
  const menu = page => page.locator('.ctx-menu');
  const ring = page => menu(page).getByRole('menuitem', { name: 'Ring to call', exact: true });
  const dismissMenu = async page => { await page.keyboard.press('Escape'); await menu(page).waitFor({ state: 'hidden' }); };
  await member(a, 'Sam Rivera').click({ button: 'right' });
  assert.equal(await ring(a).count(), 0, 'ring requires joining a group call');
  await dismissMenu(a);
  await a.getByRole('button', { name: 'Start call', exact: true }).click();
  await c.getByRole('button', { name: 'Accept', exact: true }).waitFor();
  await b.getByRole('button', { name: 'Accept', exact: true }).click();
  await c.getByRole('button', { name: 'Accept', exact: true }).waitFor({ state: 'hidden' });
  for (const page of [a, b]) {
    await page.waitForFunction(() => window.__pcs.some(pc => pc.connectionState === 'connected'));
    await page.evaluate(() => { window.__originalGroupPeer = window.__pcs.find(pc => pc.connectionState === 'connected'); window.__groupMicCount = window.__mics.length; });
  }
  assert.equal(await c.evaluate(() => window.__mics.length), 0, 'ringing does not capture the recipient microphone');
  for (const name of ['Alex Morgan', 'Jamie Chen']) {
    await member(a, name).click({ button: 'right' });
    assert.equal(await ring(a).count(), 0, 'self and already joined members cannot be rung');
    await dismissMenu(a);
  }

  await member(a, 'Sam Rivera').click({ button: 'right' });
  await ring(a).click();
  await c.getByText('Invited you to Group call regression.', { exact: false }).waitFor({ timeout: 5000 }).catch(async error => {
    console.log('Group invitation failure', clientMessages.slice(-12), await c.locator('body').innerText());
    throw error;
  });
  await member(a, 'Sam Rivera').locator('.group-ringing').waitFor();
  assert.equal(await c.evaluate(() => window.__mics.length), 0, 'targeted invitation leaves microphone off until accepted');
  const first = clientMessages.filter(item => item.msg.type === 'call_invite').at(-1);
  assert.deepEqual(first, { uid: 1, msg: { type: 'call_invite', conversation_id: 1, to_user_id: 3 } });
  await member(a, 'Sam Rivera').click({ button: 'right' });
  assert.equal(await menu(a).getByRole('menuitem', { name: 'Ringing…', exact: true }).isDisabled(), true, 'pending invitation disables repeat ringing');
  await dismissMenu(a);
  await c.getByRole('button', { name: 'Decline', exact: true }).click();
  await member(a, 'Sam Rivera').locator('.group-ringing').waitFor({ state: 'hidden' });
  await c.getByRole('button', { name: 'Accept', exact: true }).waitFor({ state: 'hidden' });
  for (const page of [a, b]) {
    assert.equal(await page.evaluate(() => window.__originalGroupPeer.connectionState === 'connected' && window.__mics.length === window.__groupMicCount), true,
      'declining leaves the original peer and microphone untouched');
  }

  // A marked member button supports the same menu on touch screens.
  await b.setViewportSize({ width: 390, height: 844 });
  await member(b, 'Sam Rivera').scrollIntoViewIfNeeded();
  await b.waitForTimeout(650); // Let mobile layout and smooth scrolling settle before holding still.
  await member(b, 'Sam Rivera').dispatchEvent('pointerdown', { pointerId: 7, pointerType: 'touch', button: 0, clientX: 150, clientY: 180 });
  await ring(b).waitFor({ timeout: 5000 });
  await member(b, 'Sam Rivera').dispatchEvent('pointerup', { pointerId: 7, pointerType: 'touch', button: 0 });
  assert.equal(await b.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'mobile group call has no horizontal page overflow');
  await b.screenshot({ path: 'test-results/group-ring-mobile.png' });
  await ring(b).click();
  await c.getByRole('button', { name: 'Accept', exact: true }).waitFor();
  await b.setViewportSize({ width: 1280, height: 900 });
  const declined = clientMessages.findLast(item => item.uid === 3 && item.msg.type === 'call_decline' && item.msg.invite_id);
  send(3, { type: 'call_invite_ended', conversation_id: 1, invite_id: declined.msg.invite_id, reason: 'timeout' });
  await c.waitForTimeout(100);
  assert.equal(await c.getByRole('button', { name: 'Accept', exact: true }).isVisible(), true, 'stale invitation end cannot close a replacement popup');
  await c.getByRole('button', { name: 'Accept', exact: true }).click();
  for (const page of [a, b, c]) {
    await page.waitForFunction(async () => {
      const peers = window.__pcs.filter(pc => pc.signalingState !== 'closed');
      if (peers.length !== 2 || peers.some(pc => pc.connectionState !== 'connected')) return false;
      const reports = await Promise.all(peers.map(pc => pc.getStats()));
      return reports.every(stats => [...stats.values()].some(r => r.type === 'inbound-rtp' && r.kind === 'audio' && r.packetsReceived > 10 && r.totalAudioEnergy > 0));
    }, null, { timeout: 20000 });
  }
  for (const page of [a, b]) {
    assert.equal(await page.evaluate(() => window.__originalGroupPeer.connectionState === 'connected' && window.__mics.length === window.__groupMicCount), true,
      'joining a third member preserves the original live peer and microphone');
  }
  assert.equal(clientMessages.filter(item => item.uid === 3 && item.msg.type === 'call_accept').at(-1).msg.invite_id.startsWith('rtc-invite-'), true,
    'accept carries the invitation capability');
  await a.screenshot({ path: 'test-results/group-ring-connected.png' });
  send(1, { type: 'call_invite_error', conversation_id: 1, to_user_id: 3, error: 'rate_limited' });
  await a.getByText('Please wait before ringing again.', { exact: true }).waitFor();
  send(1, { type: 'call_incoming', conversation_id: 1, from_user_id: 2, profile: people[1], invite_id: 'busy-invite', expires_at: Date.now() + 45000 });
  await a.waitForTimeout(100);
  assert(clientMessages.some(item => item.uid === 1 && item.msg.type === 'call_decline' && item.msg.invite_id === 'busy-invite'), 'busy recipient sends a scoped decline');
  assert.equal(await a.getByRole('button', { name: 'Accept', exact: true }).count(), 0, 'busy participant does not get a disruptive incoming popup');
  assert.equal(await a.evaluate(() => window.__originalGroupPeer.connectionState), 'connected');
  await c.locator('.call-bar [title="Leave call"]').click();
  for (const page of [a, b]) await page.waitForFunction(() => window.__pcs.filter(pc => pc.signalingState !== 'closed').length === 1);
  await member(a, 'Sam Rivera').click({ button: 'right' });
  await ring(a).click();
  await c.getByRole('button', { name: 'Accept', exact: true }).waitFor();
  finishInvitation('timeout');
  await c.getByRole('button', { name: 'Accept', exact: true }).waitFor({ state: 'hidden' });
  await member(a, 'Sam Rivera').locator('.group-ringing').waitFor({ state: 'hidden' });
  assert.equal(await a.evaluate(() => window.__originalGroupPeer.connectionState), 'connected', 'invitation expiry preserves the call');
  for (const page of [a, b]) await page.locator('.call-bar [title="Leave call"]').click();
  for (const page of [a, b, c]) await page.waitForFunction(() => window.__pcs.every(pc => pc.signalingState === 'closed'));
}
