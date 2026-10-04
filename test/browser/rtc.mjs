import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';
import { now, people, sync, conversations } from './fixtures.mjs';
import { nativeHealth } from './native-health.mjs';
import { measureAudioPower } from './rtc-audio.mjs';
import { testGroupInvitations } from './rtc-group-invites.mjs';

// Real RTCPeerConnections and RTP media. Only identity, signaling transport and
// microphone hardware are fixtures, so no microphone or external server is needed.
const root = resolve('priv/static');
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const file = url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/assets\//, '');
    const path = resolve(root, file);
    if (!path.startsWith(root + '/')) throw Error('path');
    const bytes = await readFile(path);
    res.writeHead(200, { 'content-type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' })[extname(path)] || 'application/octet-stream' });
    res.end(bytes);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage', '--autoplay-policy=no-user-gesture-required', '--disable-features=WebRtcHideLocalIpsWithMdns', '--allow-loopback-in-peer-connection'] });
const sockets = new Map();
const errors = [];
const clientMessages = [];
const send = (uid, data) => sockets.get(uid)?.send(JSON.stringify(data));
const states = new Map();
const members = new Set();
// Simulates a slow relay path: ICE candidates arrive long after offer/answer.
let candidateDelayMs = 0;
let dropNextRing = false;
let groupMode = false;
let invitation = null;
let invitationSequence = 0;
const callUsers = () => groupMode ? [1, 2, 3] : [1, 2];
const callConversation = () => groupMode ? { ...conversations[0], name: 'Group call regression', member_count: 3,
  members: people.slice(0, 3).map(user => ({ user, role: user.id === 1 ? 'owner' : 'member' })) } : conversations[0];
const roster = () => people.slice(0, groupMode ? 3 : 2).map(p => ({ user_id: p.id, profile: p, muted: false, deafened: false, screen: false, ...states.get(p.id) }));
const joinedRoster = () => roster().filter(user => members.has(user.user_id));
function finishInvitation(status) {
  if (!invitation) return;
  send(invitation.target, { type: 'call_invite_ended', conversation_id: 1, invite_id: invitation.token, reason: status });
  send(invitation.from, { type: 'call_invite_status', conversation_id: 1, to_user_id: invitation.target,
    invite_id: invitation.token, expires_at: invitation.expires, status });
  invitation = null;
}
const voiceRoster = () => people.slice(0, 2).map(p => ({ user_id: p.id, profile: p, muted: false, deafened: false, screen: false, screen_audio: false, reconnecting: false }));
async function setup(uid) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.grantPermissions(['microphone']);
  await context.addInitScript(({ uid }) => {
    window.PLAINWIRE_DEBUG = true;
    const NativePC = window.RTCPeerConnection;
    window.__pcs = [];
    window.__mics = [];
    window.__tones = [];
    const createOscillator = AudioContext.prototype.createOscillator;
    AudioContext.prototype.createOscillator = function () {
      const osc = createOscillator.call(this);
      const record = { osc, ended: false };
      osc.addEventListener('ended', () => { record.ended = true; });
      window.__tones.push(record);
      return osc;
    };
    window.__screens = [];
    window.__displayRequests = [];
    window.__gumRequests = [];
    if (uid === 1) localStorage.setItem('plainwire_audio_input', 'unplugged');
    navigator.mediaDevices.enumerateDevices = async () => [
      { kind: 'audioinput', deviceId: 'desk', label: 'Desk microphone' },
      { kind: 'audioinput', deviceId: 'headset', label: 'Headset microphone' }
    ];
    navigator.mediaDevices.getDisplayMedia = async constraints => {
      window.__displayRequests.push(constraints);
      const canvas = document.createElement('canvas');
      canvas.width = 640; canvas.height = 360;
      const ctx = canvas.getContext('2d');
      let frame = 0;
      const timer = setInterval(() => {
        ctx.fillStyle = frame++ % 2 ? '#326b98' : '#98a4af';
        ctx.fillRect(0, 0, 640, 360);
      }, 60);
      const stream = canvas.captureStream(15);
      if (constraints.audio) {
        const screenAudioContext = new AudioContext();
        await screenAudioContext.resume();
        // Use the native constructor captured above so screen audio is not
        // counted as one of the UI sound previews in this suite.
        const oscillator = createOscillator.call(screenAudioContext);
        const gain = screenAudioContext.createGain();
        const destination = screenAudioContext.createMediaStreamDestination();
        oscillator.frequency.value = 880;
        gain.gain.value = 0.12;
        oscillator.connect(gain).connect(destination);
        oscillator.start();
        stream.addTrack(destination.stream.getAudioTracks()[0]);
        window.__screens.push({ stream, timer, screenAudioContext, oscillator });
      } else {
        window.__screens.push({ stream, timer });
      }
      return stream;
    };
    window.RTCPeerConnection = class extends NativePC {
      constructor(config) { super(config); window.__pcs.push(this); }
    };
    navigator.mediaDevices.getUserMedia = async (constraints) => {
      window.__gumRequests.push(constraints);
      if (constraints.audio?.deviceId?.exact === 'unplugged') throw new DOMException('Device removed', 'NotFoundError');
      if (window.__micDisconnected && constraints.audio?.deviceId?.exact === 'desk') throw new DOMException('Device removed', 'NotFoundError');
      const ctx = new AudioContext();
      await ctx.resume();
      const oscillator = ctx.createOscillator();
      const gain = ctx.createGain();
      const dest = ctx.createMediaStreamDestination();
      oscillator.frequency.value = uid === 1 ? 440 : 660;
      gain.gain.value = 0.15;
      oscillator.connect(gain).connect(dest);
      oscillator.start();
      window.__mics.push({ ctx, oscillator, stream: dest.stream });
      return dest.stream;
    };
  }, { uid });
  await context.route('**/api/**', async route => {
    const path = new URL(route.request().url()).pathname;
    const reply = data => route.fulfill({ json: { ok: true, data } });
    if (path === '/api/client-config') return route.fulfill({ json: { app_name: 'Plainwire', default_theme: 'system', version: '1.9.0', asset_version: '1.9.0', registration_enabled: true } });
    if (path === '/api/me') return reply({ user: people[uid - 1], csrf: 'test', server_time: now });
    if (path === '/api/sync') return reply({ ...sync, conversations: [{ ...callConversation(), peer_id: uid === 1 ? 2 : 1, peer_name: people[uid === 1 ? 1 : 0].display_name }] });
    if (path === '/api/messages') return reply([]);
    if (path === '/api/conversation/1') return reply({ conversation: callConversation(), members: callConversation().members });
    if (path === '/api/rtc-config') return reply({ iceServers: [] });
    if (path === '/api/voice-processing-config') return reply({ krisp_available: false });
    return reply({});
  });
  await context.routeWebSocket('**/ws', ws => {
    sockets.set(uid, ws);
    ws.onMessage(raw => {
      const msg = JSON.parse(raw);
      clientMessages.push({ uid, msg });
      if (msg.type === 'call_quality' && process.env.PLAINWIRE_TEST_NATIVE === '1') {
        nativeHealth(msg.samples).then(result => send(uid, { type: 'call_quality_result', request_id: msg.request_id, peer_id: msg.peer_id, result })).catch(error => errors.push(error.message));
        return;
      }
      if (msg.type === 'ping') return send(uid, { type: 'pong' });
      if (msg.type === 'call_signal') {
        const deliver = () => send(msg.to_user_id, { ...msg, conversation_id: 1, from_user_id: uid });
        return msg.signal?.kind === 'candidate' && candidateDelayMs ? setTimeout(deliver, candidateDelayMs) : deliver();
      }
      if (msg.type === 'voice_signal') return send(msg.to_user_id, { ...msg, channel_id: 9, from_user_id: uid });
      if (msg.type === 'voice_join') {
        return send(uid, { type: 'voice_state', channel_id: 9, users: voiceRoster() });
      }
      if (msg.type === 'call_ring') {
        if (dropNextRing) {
          dropNextRing = false;
          ws.close({ code: 1011, reason: 'simulated transport loss' });
          return;
        }
        send(uid, { type: 'call_ringing', conversation_id: 1, profile: people[uid === 1 ? 1 : 0] });
        for (const target of callUsers().filter(id => id !== uid)) {
          send(target, { type: 'call_incoming', conversation_id: 1, from_user_id: uid, profile: people[uid - 1] });
        }
      }
      if (msg.type === 'call_invite') {
        assert(groupMode && members.has(uid) && msg.to_user_id === 3 && !members.has(3), 'only a joined caller rings the absent group member');
        invitation = { from: uid, target: 3, token: `rtc-invite-${++invitationSequence}`, expires: Date.now() + 45000 };
        send(uid, { type: 'call_invite_status', conversation_id: 1, to_user_id: 3, invite_id: invitation.token,
          expires_at: invitation.expires, status: 'ringing' });
        send(3, { type: 'call_incoming', conversation_id: 1, from_user_id: uid, profile: people[uid - 1],
          invite_id: invitation.token, expires_at: invitation.expires });
      }
      if (msg.type === 'call_decline') {
        if (msg.invite_id === 'busy-invite') return;
        if (msg.invite_id) {
          assert.equal(msg.invite_id, invitation?.token, 'decline carries the matching invitation');
          finishInvitation('declined');
        } else {
          for (const target of callUsers()) send(target, { type: 'call_declined', conversation_id: 1 });
        }
      }
      if (msg.type === 'call_accept') {
        if (msg.invite_id) {
          assert.equal(uid, invitation?.target);
          assert.equal(msg.invite_id, invitation?.token, 'accept carries the matching invitation');
          const caller = invitation.from;
          finishInvitation('accepted');
          send(uid, { type: 'call_accepted', conversation_id: 1, user_id: caller, profile: people[caller - 1] });
          for (const target of members) send(target, { type: 'call_peer_joined', conversation_id: 1, user_id: uid, profile: people[uid - 1] });
          members.add(uid);
          for (const target of members) send(target, { type: 'call_state', conversation_id: 1, users: joinedRoster() });
          return;
        }
        states.clear();
        members.add(1); members.add(2);
        for (const target of [1, 2]) {
          send(target, { type: 'call_accepted', conversation_id: 1, user_id: target === 1 ? 2 : 1, profile: people[target === 1 ? 1 : 0] });
          send(target, { type: 'call_state', conversation_id: 1, users: joinedRoster() });
        }
        if (groupMode) {
          for (const target of members) send(target, { type: 'call_state', conversation_id: 1, users: joinedRoster() });
          send(3, { type: 'call_ended', conversation_id: 1, reason: 'accepted' });
        }
      }
      if (msg.type === 'call_join') {
        const wasMember = members.has(uid);
        members.add(uid);
        const joinedRoster = roster().filter(user => members.has(user.user_id));
        for (const target of members) {
          if (!wasMember && target !== uid) {
            send(target, { type: 'call_peer_joined', conversation_id: 1, user_id: uid, profile: people[uid - 1] });
          }
          send(target, { type: 'call_state', conversation_id: 1, users: joinedRoster });
        }
      }
      if (msg.type === 'call_state' && msg.patch) {
        states.set(uid, { ...states.get(uid), ...msg.patch });
        for (const target of members) send(target, { type: 'call_state', conversation_id: 1, users: joinedRoster() });
      }
      if (msg.type === 'call_leave') {
        members.delete(uid);
        for (const other of members) {
          send(other, { type: 'call_peer_left', conversation_id: 1, user_id: uid });
          send(other, { type: 'call_state', conversation_id: 1, users: joinedRoster() });
        }
        for (const target of callUsers()) send(target, { type: 'call_presence', conversation_id: 1, active: members.size > 0, users: joinedRoster() });
        if (invitation?.from === uid) finishInvitation('caller_left');
      }
      if (msg.type === 'call_cancel') {
        for (const target of [1, 2]) send(target, { type: 'call_cancelled', conversation_id: 1 });
      }
    });
    send(uid, { type: 'hello', session: { user: people[uid - 1] } });
  });
  const page = await context.newPage();
  page.on('pageerror', e => errors.push(e.message));
  if (process.env.RTC_DEBUG) page.on('console', m => console.log(uid, m.text()));
  await page.goto(origin + '/#dm/1');
  await page.waitForSelector('#compose');
  return page;
}
async function stats(page) {
  return page.evaluate(async () => {
    const pc = window.__pcs.filter(p => p.signalingState !== 'closed').at(-1);
    if (!pc) return null;
    const reports = [...(await pc.getStats()).values()];
    return { video: reports.filter(r => r.type === 'inbound-rtp' && r.kind === 'video').map(r => r.framesDecoded), connection: pc.connectionState, transceivers: pc.getTransceivers().map(t => ({ mid: t.mid, direction: t.currentDirection, kind: t.receiver.track.kind, sending: !!t.sender.track, enabled: t.sender.track?.enabled })), inbound: reports.filter(r => r.type === 'inbound-rtp' && r.kind === 'audio').map(r => ({ id: r.id, packets: r.packetsReceived, energy: r.totalAudioEnergy, duration: r.totalSamplesDuration })), outbound: reports.filter(r => r.type === 'outbound-rtp' && r.kind === 'audio').map(r => r.packetsSent) };
  });
}
async function audioPower(page, label) {
  const sample = await measureAudioPower(async () => (await stats(page))?.inbound[0], { label });
  if (process.env.RTC_DEBUG) console.log(label, sample);
  return sample.power;
}
try {
  const [a, b] = await Promise.all([setup(1), setup(2)]);
  if (!process.env.PLAINWIRE_TEST_GROUP_CALL_ONLY && !process.env.PLAINWIRE_TEST_LISTEN_ONLY) {
  await a.getByRole('button', { name: 'Start call', exact: true }).click();
  await b.getByRole('button', { name: 'Accept', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.some(p => p.connectionState === 'connected'), null, { timeout: 15000 }).catch(async e => { console.log(await stats(a), await stats(b)); throw e; });
  await b.waitForFunction(() => window.__pcs.some(p => p.connectionState === 'connected'));
  await a.waitForTimeout(1800);
  const initial = await Promise.all([stats(a), stats(b)]);
  if (process.env.RTC_DEBUG) console.log(JSON.stringify(initial, null, 2));
  for (const [i, result] of initial.entries()) {
    assert(result.inbound.some(r => r.packets > 10 && r.energy > 0), `peer ${i + 1} receives audible RTP`);
    assert(result.transceivers.some(t => t.kind === 'audio' && t.sending && t.enabled && t.direction === 'sendrecv'), `peer ${i + 1} sends microphone on negotiated transceiver`);
  }
  // Losing the signaling socket in an active call must rebuild the seat and
  // both media paths without a page refresh.
  const oldPeerCount = await a.evaluate(() => window.__pcs.length);
  members.delete(1);
  send(2, { type: 'call_peer_left', conversation_id: 1, user_id: 1 });
  send(2, { type: 'call_state', conversation_id: 1, users: roster().filter((user) => members.has(user.user_id)) });
  await sockets.get(1).close({ code: 1011, reason: 'simulated transport loss' });
  await a.waitForFunction((count) => window.__pcs.length > count && window.__pcs.at(-1).connectionState === 'connected', oldPeerCount, { timeout: 20000 });
  await b.waitForFunction(() => window.__pcs.at(-1).connectionState === 'connected');
  await a.waitForFunction(async () => [...(await window.__pcs.at(-1).getStats()).values()]
    .some((report) => report.type === 'inbound-rtp' && report.kind === 'audio' && report.packetsReceived > 5 && report.totalAudioEnergy > 0));
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_audio_input')), '', 'unavailable saved microphone recovers to default');
  await a.getByRole('button', { name: 'Open call details', exact: true }).click();
  await a.waitForSelector('#call-microphone');
  // The first resize must work without a prior keyboard resize or viewport
  // change; Browser.application replaces the original mount element.
  const header = await a.locator('.call-overlay-title').boundingBox();
  await a.mouse.move(header.x + 20, header.y + 10);
  await a.mouse.down();
  await a.mouse.move(60, 50, { steps: 8 });
  await a.mouse.up();
  const firstGrip = await a.getByRole('button', { name: 'Resize call window', exact: true }).boundingBox();
  await a.mouse.move(firstGrip.x + firstGrip.width / 2, firstGrip.y + firstGrip.height / 2);
  await a.mouse.down();
  await a.mouse.move(firstGrip.x + 180, firstGrip.y + 50, { steps: 8 });
  await a.mouse.up();
  const firstResized = await a.locator('.call-overlay').boundingBox();
  assert(firstResized.width > 500, 'first pointer resize expands the call window');
  await a.getByRole('button', { name: 'Minimize call', exact: true }).click();
  await a.locator('.call-bar.compact').waitFor();
  await a.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const firstCompact = await a.locator('.call-bar.compact').boundingBox();
  assert(firstCompact.width <= 390 && firstCompact.height < 100, 'first pointer resize must not leave a giant minimized call bar');
  await a.getByRole('button', { name: 'Open call details', exact: true }).click();
  await a.waitForFunction(width => Math.abs((document.querySelector('.call-overlay.expanded')?.getBoundingClientRect().width || 0) - width) < 2, firstResized.width);
  await a.getByRole('button', { name: 'Reset window', exact: true }).click();
  // Keyboard resizing persists and reflows participant cards at wider sizes.
  const grip = a.getByRole('button', { name: 'Resize call window', exact: true });
  const originalWidth = (await a.locator('.call-overlay').boundingBox()).width;
  await grip.focus();
  for (let n = 0; n < 7; n++) await grip.press('ArrowRight');
  assert((await a.locator('.call-overlay').boundingBox()).width > originalWidth + 150);
  assert.equal(await a.locator('.call-overlay-users').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length), 2);
  assert(await a.evaluate(() => JSON.parse(localStorage.getItem('plainwire_call_size_v1')).w > 560));
  // Minimizing a resized panel returns to the compact bar size, and reopening
  // restores the chosen size.
  const resizedBox = await a.locator('.call-overlay').boundingBox();
  await a.getByRole('button', { name: 'Minimize call', exact: true }).click();
  await a.locator('.call-bar.compact').waitFor();
  await a.waitForFunction(() => { const bar = document.querySelector('.call-bar.compact'); return bar && !bar.style.width && !bar.style.height; });
  assert((await a.locator('.call-bar.compact').boundingBox()).width < resizedBox.width - 100, 'minimized call bar is not left at the resized size');
  await a.getByRole('button', { name: 'Open call details', exact: true }).click();
  await a.waitForFunction(width => Math.abs((document.querySelector('.call-overlay.expanded')?.getBoundingClientRect().width || 0) - width) < 2, resizedBox.width);
  // Phone layout ignores desktop geometry without losing the user's saved
  // dimensions or position when returning to desktop.
  const desktopPosition = await a.evaluate(() => localStorage.getItem('plainwire_call_window_v2'));
  await a.setViewportSize({ width: 390, height: 844 });
  await a.waitForFunction(() => { const panel = document.querySelector('.call-overlay.expanded'); return panel && panel.getBoundingClientRect().width <= 390 && !panel.style.height; });
  assert.ok((await a.locator('.call-overlay').boundingBox()).height < 844);
  await a.setViewportSize({ width: 1280, height: 900 });
  await a.waitForFunction(width => Math.abs((document.querySelector('.call-overlay.expanded')?.getBoundingClientRect().width || 0) - width) < 2, resizedBox.width);
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_call_window_v2')), desktopPosition, 'phone layout preserves the saved desktop position');
  await a.waitForSelector('#call-microphone');
  await a.locator('.call-overlay-title').dblclick();
  assert.equal(Math.round((await a.locator('.call-overlay').boundingBox()).width), Math.round(originalWidth));
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_call_size_v1')), null);
  const corner = await grip.boundingBox();
  await a.mouse.move(corner.x + corner.width / 2, corner.y + corner.height / 2);
  await a.mouse.down();
  await a.mouse.move(corner.x - 50, corner.y - 70, { steps: 4 });
  await a.mouse.up();
  assert((await a.locator('.call-overlay').boundingBox()).width < originalWidth - 40, 'pointer resizing changes the actual call panel');
  await a.locator('.call-overlay-title').dblclick();
  await a.waitForFunction(() => Number(document.querySelector('[data-call-mic-meter]')?.getAttribute('aria-valuenow')) > 0);
  await a.locator('pw-user-volume[user-id="2"] input').fill('35');
  assert.equal(await a.evaluate(() => document.querySelector('#remote-audio-2').volume), .35);
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_peer_volume_1_2')), '35');
  await a.locator('pw-input-volume input').fill('0');
  const quietPower = await audioPower(b, 'input volume 0%');
  await a.locator('pw-input-volume input').fill('100');
  const loudPower = await audioPower(b, 'input volume 100%');
  assert(quietPower < .0001 && loudPower > quietPower * 4 + .0001,
    `input volume changes real outgoing audio energy (quiet power ${quietPower}, loud power ${loudPower})`);
  await a.getByRole('button', { name: 'Mute', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === false);
  await a.waitForFunction(() => document.querySelector('[data-call-mic-meter]')?.getAttribute('aria-valuenow') === '0');
  assert.equal(await a.getByRole('button', { name: 'Unmute', exact: true }).getAttribute('aria-pressed'), 'true');
  await a.getByRole('button', { name: 'Unmute', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === true);

  // Live microphone swap transmits the new track and releases the old hardware.
  await a.evaluate(() => { window.__beforeMicSwap = window.__pcs.at(-1)._audioSender.track; });
  await a.locator('#call-microphone').selectOption('desk');
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track !== window.__beforeMicSwap && window.__pcs.at(-1)._audioSender.track.readyState === 'live');
  await a.waitForFunction(() => window.__beforeMicSwap.readyState === 'ended');
  await a.waitForFunction(() => window.__mics[0].stream.getAudioTracks()[0].readyState === 'ended');
  assert(await audioPower(b, 'switched microphone') > .0001, 'switched microphone remains audible remotely');

  // A sender failure must preserve the current microphone and roll back selection.
  await a.evaluate(() => {
    const sender = window.__pcs.at(-1)._audioSender;
    const original = sender.replaceTrack.bind(sender);
    window.__beforeFailedSwap = sender.track;
    sender.replaceTrack = async track => { sender.replaceTrack = original; throw new DOMException('Injected sender failure', 'InvalidModificationError'); };
  });
  await a.locator('#call-microphone').selectOption('headset');
  await a.waitForFunction(() => document.querySelector('#call-microphone')?.value === 'desk');
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track === window.__beforeFailedSwap && window.__beforeFailedSwap.readyState === 'live'), true);

  // A processed Web Audio track can stay live when its physical source dies.
  // The call must switch to the default device and resume audible RTP.
  await a.evaluate(() => {
    window.__beforeDisconnect = window.__pcs.at(-1)._audioSender.track;
    const raw = window.__mics.findLast((mic) => mic.stream.getAudioTracks()[0].readyState === 'live').stream.getAudioTracks()[0];
    window.__micDisconnected = true;
    raw.stop();
    raw.dispatchEvent(new Event('ended'));
  });
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track !== window.__beforeDisconnect && window.__pcs.at(-1)._audioSender.track.readyState === 'live');
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_audio_input')), '', 'disconnected selected input falls back to the default');
  assert(await audioPower(b, 'recovered microphone') > .0001, 'microphone recovers without rejoining or refreshing');
  await a.evaluate(() => {
    const output = window.__pcs.at(-1)._audioSender.track;
    window.__beforeOutputDisconnect = output;
    output.stop();
    output.dispatchEvent(new Event('ended'));
  });
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track !== window.__beforeOutputDisconnect && window.__pcs.at(-1)._audioSender.track.readyState === 'live');

  // Screen audio is mixed onto the negotiated audio sender, preserving the
  // existing SDP shape and microphone controls.
  await a.evaluate(() => { window.__beforeShareAudio = window.__pcs.at(-1)._audioSender.track; });
  await a.getByRole('button', { name: 'Share', exact: true }).click();
  await a.waitForSelector('.call-sharing-row');
  await a.locator('.call-overlay.expanded').evaluate(el => { el.style.width = '620px'; });
  await a.waitForFunction(() => getComputedStyle(document.querySelector('.call-control')).flexDirection === 'row');
  const wideControlOffset = await a.locator('.call-control').first().evaluate(button => {
    const box = button.getBoundingClientRect();
    const icon = button.querySelector('.call-icon').getBoundingClientRect();
    const label = button.querySelector('span:last-child').getBoundingClientRect();
    return Math.abs((icon.left + label.right) / 2 - (box.left + box.right) / 2);
  });
  assert(wideControlOffset <= 2, `wide call control icon and label stay centered together (${wideControlOffset}px offset)`);
  await a.waitForFunction(() => {
    const sender = window.__pcs.at(-1)._audioSender;
    return sender?.track && sender.track !== window.__beforeShareAudio && sender.track.readyState === 'live';
  });
  await a.evaluate(() => { window.__firstMixedScreenAudio = window.__pcs.at(-1)._audioSender.track; });
  assert.equal(await a.evaluate(() => window.__displayRequests[0].audio), true, 'screen chooser requests source audio');
  assert.equal(await a.evaluate(() => window.__displayRequests[0].windowAudio), 'window', 'window sharing requests the selected window audio');
  assert.equal(await a.evaluate(() => window.__displayRequests[0].systemAudio), 'include', 'monitor sharing keeps system audio available');
  assert.equal(await a.evaluate(() => window.__displayRequests[0].audioSelection), 'preferred', 'the screen chooser is asked to prefer an audio-enabled source');
  assert.equal(await a.evaluate(() => window.__screens[0].stream.getAudioTracks().length), 1, 'display capture supplies shared audio');
  await b.waitForFunction(async () => [...(await window.__pcs.at(-1).getStats()).values()].some(r => r.type === 'inbound-rtp' && r.kind === 'video' && r.framesDecoded > 2));
  await b.getByRole('button', { name: 'Open call details', exact: true }).click();
  assert.equal(await b.locator('#call-microphone').evaluate(el => el.selectedOptions[0]?.textContent), 'System default');
  await b.getByText('Sharing screen · audio included', { exact: true }).waitFor();
  await b.getByRole('button', { name: 'Watch screen', exact: true }).click();
  await b.waitForFunction(() => document.querySelector('#pw-float-stage-1 video')?.videoWidth > 0);
  assert.equal(await a.evaluate(() => window.__displayRequests[0].video.frameRate.max), 30);
  await a.locator('pw-screen-settings summary').click();
  await a.locator('[data-screen-audio-status].active').waitFor();
  await a.getByText('Shared audio is flowing and mixed with your microphone.', { exact: true }).waitFor();
  await a.getByRole('button', { name: 'Mute', exact: true }).click();
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track.enabled), true, 'muting the microphone keeps the mixed share track live');
  assert(await audioPower(b, 'screen audio with microphone muted') > .0001, 'shared source audio continues while the microphone is muted');
  await a.getByRole('button', { name: 'Unmute', exact: true }).click();
  await a.getByRole('combobox', { name: 'Screen sharing quality', exact: true }).selectOption('motion');
  await a.getByRole('button', { name: 'Change shared screen', exact: true }).click();
  await a.waitForFunction(() => window.__screens.length === 2 && window.__screens[0].stream.getTracks().every(track => track.readyState === 'ended') && window.__firstMixedScreenAudio.readyState === 'ended');
  assert.equal(await a.evaluate(() => window.__displayRequests[1].video.frameRate.max), 60);
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._videoSender.track === window.__screens[1].stream.getVideoTracks()[0]), true);
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track !== window.__firstMixedScreenAudio && window.__pcs.at(-1)._audioSender.track.readyState === 'live'), true, 'changing source replaces the audio mix atomically');
  const framesBeforeSwitch = (await stats(b)).video[0];
  await b.waitForFunction(async frames => [...(await window.__pcs.at(-1).getStats()).values()].some(r => r.type === 'inbound-rtp' && r.kind === 'video' && r.framesDecoded > frames + 3), framesBeforeSwitch);
  // Cancellation and sender failure both leave the existing share usable.
  await a.evaluate(() => {
    const original = navigator.mediaDevices.getDisplayMedia;
    navigator.mediaDevices.getDisplayMedia = async () => { navigator.mediaDevices.getDisplayMedia = original; throw new DOMException('Cancelled', 'NotAllowedError'); };
  });
  await a.getByRole('button', { name: 'Change shared screen', exact: true }).click();
  await a.getByText('Screen sharing was cancelled or is unavailable.', { exact: true }).waitFor();
  assert.equal(await a.evaluate(() => window.__screens[1].stream.getVideoTracks()[0].readyState), 'live');
  await a.evaluate(() => {
    const sender = window.__pcs.at(-1)._videoSender, original = sender.replaceTrack.bind(sender);
    window.__beforeFailedScreenAudio = window.__pcs.at(-1)._audioSender.track;
    sender.replaceTrack = async () => { sender.replaceTrack = original; throw new DOMException('Injected failure', 'InvalidModificationError'); };
  });
  await a.getByRole('button', { name: 'Change shared screen', exact: true }).click();
  await a.waitForFunction(() => window.__screens.length === 3 && window.__screens[2].stream.getVideoTracks()[0].readyState === 'ended');
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._videoSender.track === window.__screens[1].stream.getVideoTracks()[0] && window.__pcs.at(-1)._videoSender.track.readyState === 'live'), true);
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track === window.__beforeFailedScreenAudio && window.__beforeFailedScreenAudio.readyState === 'live'), true, 'failed source change restores the previous shared audio');
  await a.locator('pw-screen-settings summary').click();
  const viewer = b.locator('#pw-float-stage-1');
  await viewer.getByRole('button', { name: 'Fill view', exact: true }).click();
  assert.equal(await viewer.locator('video').evaluate(el => getComputedStyle(el).objectFit), 'cover');
  await viewer.getByRole('button', { name: 'Fit view', exact: true }).click();
  await viewer.getByRole('button', { name: 'Fullscreen screen share', exact: true }).click();
  await b.waitForFunction(() => document.fullscreenElement?.id === 'pw-float-stage-1');
  assert(await viewer.locator('.screen-viewer-footer').isVisible());
  await viewer.getByRole('button', { name: 'Fullscreen screen share', exact: true }).click();
  await b.waitForFunction(() => !document.fullscreenElement);
  // Exercise colour reporting using metadata fixtures, not an HDR hardware claim.
  await b.evaluate(() => {
    const NativeFrame = window.VideoFrame, video = document.querySelector('#pw-float-stage-1 video');
    window.VideoFrame = class { colorSpace = { transfer: 'pq' }; close() { window.__frameClosed = true; } };
    video.dispatchEvent(new Event('loadeddata')); window.VideoFrame = NativeFrame;
  });
  assert.equal(await viewer.getAttribute('data-hdr'), 'true');
  assert.equal(await b.evaluate(() => window.__frameClosed), true);
  await b.evaluate(() => document.querySelector('#pw-float-stage-1 video').dispatchEvent(new Event('loadeddata')));
  assert.equal(await viewer.getAttribute('data-hdr'), 'false', 'ordinary SDR video must not be labelled HDR');
  const viewerHeight = (await viewer.boundingBox()).height;
  await viewer.getByRole('button', { name: 'Hide shared screen', exact: true }).click();
  await b.waitForFunction(() => document.querySelector('#pw-float-stage-1')?.classList.contains('screen-visual-hidden'));
  assert.equal(await viewer.locator('video').isVisible(), false, 'hiding a share removes the video without closing it');
  assert((await viewer.boundingBox()).height < viewerHeight / 2, 'hidden share collapses to a compact title bar');
  await b.setViewportSize({ width: 1280, height: 890 });
  await b.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await viewer.getByRole('button', { name: 'Show shared screen', exact: true }).click();
  await viewer.locator('video').waitFor({ state: 'visible' });
  assert(Math.abs((await viewer.boundingBox()).height - viewerHeight) < 2, 'hide/show and viewport changes preserve the expanded viewer height');
  await b.setViewportSize({ width: 1280, height: 900 });
  await viewer.getByRole('button', { name: 'Stop watching screen', exact: true }).click();
  await b.getByRole('button', { name: 'Watch screen', exact: true }).click();
  await b.waitForFunction(() => document.querySelector('#pw-float-stage-1 video')?.videoWidth > 0);
  await b.screenshot({ path: 'test-results/screen-viewer.png' });
  await b.setViewportSize({ width: 390, height: 844 });
  const compactViewer = await viewer.boundingBox();
  await viewer.getByRole('button', { name: 'Center and fit window', exact: true }).click();
  assert((await viewer.boundingBox()).height > compactViewer.height + 200, 'mobile expand provides useful viewing space');
  assert(await viewer.getByRole('button', { name: 'Stop watching screen', exact: true }).isVisible());
  await b.screenshot({ path: 'test-results/screen-mobile.png' });
  await viewer.getByRole('button', { name: 'Center and fit window', exact: true }).click();
  await b.setViewportSize({ width: 1280, height: 900 });
  await b.getByRole('button', { name: 'Share', exact: true }).click();
  await a.waitForFunction(async () => [...(await window.__pcs.at(-1).getStats()).values()].some(r => r.type === 'inbound-rtp' && r.kind === 'video' && r.framesDecoded > 2));
  await a.getByRole('button', { name: 'Watch screen', exact: true }).click();
  await a.waitForFunction(() => document.querySelector('#pw-float-stage-2 video')?.videoWidth > 0);
  await a.locator('.call-health summary').click();
  await a.waitForFunction(() => document.querySelector('[data-call-health-list]')?.textContent.includes('kb/s'), null, { timeout: 12000 });
  if (process.env.PLAINWIRE_TEST_NATIVE === '1') {
    await a.waitForFunction(() => document.querySelector('.call-health-score strong')?.textContent && document.querySelector('.call-health-native')?.textContent === 'Connection analysis', null, { timeout: 20000 });
    assert(await a.locator('.call-health-sparkline').count() > 0);
    await a.locator('.call-overlay').evaluate(el => { el.scrollTop = el.scrollHeight; });
    await a.screenshot({ path: 'test-results/native-call-health.png' });
  }
  await a.locator('.call-health summary').click();
  await a.evaluate(() => {
    window.__healthMutations = 0;
    window.__healthObserver = new MutationObserver(records => { window.__healthMutations += records.length; });
    window.__healthObserver.observe(document.querySelector('[data-call-health-list]'), { childList: true, subtree: true });
  });
  await a.waitForTimeout(5200);
  assert.equal(await a.evaluate(() => window.__healthMutations), 0, 'collapsed diagnostics do not rebuild hidden DOM');
  await a.evaluate(() => window.__healthObserver.disconnect());
  await a.locator('.call-health summary').click();
  // Stop while replacement is settling: both old and new captures must end.
  await a.evaluate(() => {
    const sender = window.__pcs.at(-1)._videoSender, original = sender.replaceTrack.bind(sender);
    sender.replaceTrack = async track => {
      sender.replaceTrack = original;
      await original(track);
      await new Promise(resolve => { window.__finishScreenSwap = resolve; });
    };
  });
  await a.locator('pw-screen-settings summary').click();
  await a.getByRole('button', { name: 'Change shared screen', exact: true }).click();
  await a.waitForFunction(() => typeof window.__finishScreenSwap === 'function');
  await a.getByRole('button', { name: 'Stop share', exact: true }).click();
  await a.evaluate(() => window.__finishScreenSwap());
  await a.waitForFunction(() => window.__screens.every(s => s.stream.getTracks().every(t => t.readyState === 'ended')));
  await a.locator('pw-screen-settings summary').click();
  await b.getByRole('button', { name: 'Stop share', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._videoSender.track === null);
  assert.equal(await a.evaluate(() => window.__screens.every(s => s.stream.getTracks().every(t => t.readyState === 'ended'))), true);
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track === window.__beforeShareAudio && window.__beforeShareAudio.readyState === 'live'), true, 'stopping a share restores the microphone sender');

  // Regression: joining an already-active call is not the same protocol as
  // accepting a ringing call. Leaving while the other participant stays should
  // expose Join Call, send call_join, and build a fresh peer session.
  const joinsBefore = clientMessages.filter(item => item.uid === 1 && item.msg.type === 'call_join').length;
  const acceptsBefore = clientMessages.filter(item => item.uid === 1 && item.msg.type === 'call_accept').length;
  await a.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).click();
  await a.getByRole('button', { name: 'Join Call', exact: true }).waitFor();
  await a.getByRole('button', { name: 'Join Call', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)?.connectionState === 'connected', null, { timeout: 15000 });
  await b.waitForFunction(() => window.__pcs.at(-1)?.connectionState === 'connected', null, { timeout: 15000 });
  assert.equal(clientMessages.filter(item => item.uid === 1 && item.msg.type === 'call_join').length, joinsBefore + 1, 'existing call uses call_join');
  assert.equal(clientMessages.filter(item => item.uid === 1 && item.msg.type === 'call_accept').length, acceptsBefore, 'existing call never sends call_accept');
  await a.getByRole('button', { name: 'Call details', exact: true }).click();
  await a.locator('.call-overlay').waitFor();

  await a.locator('.toast-close').click({ timeout: 1000 }).catch(() => {});
  await mkdir('test-results', { recursive: true });
  await a.screenshot({ path: 'test-results/call-desktop.png' });
  await a.emulateMedia({ colorScheme: 'dark' });
  await a.waitForTimeout(200);
  await a.screenshot({ path: 'test-results/call-dark.png' });
  await a.setViewportSize({ width: 390, height: 844 });
  assert.equal(await a.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  const leave = await a.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).boundingBox();
  assert(leave && leave.y + leave.height < 844 && leave.width >= 44, 'mobile call controls fit and have touch targets');
  await a.screenshot({ path: 'test-results/call-mobile.png' });
  await a.setViewportSize({ width: 1280, height: 900 });
  await a.emulateMedia({ colorScheme: 'light' });

  // Deafen silences playback and the microphone; undeafen restores both and the
  // call keeps flowing in both directions. A pre-existing mute is preserved.
  const remotePlayback = page => page.evaluate(() => [...document.querySelectorAll('audio[id^="remote-audio-"]')].map(el => el.muted));
  await a.getByRole('button', { name: 'Deafen', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === false && [...document.querySelectorAll('audio')].filter(el => el.srcObject).every(el => el.muted));
  assert.deepEqual(await remotePlayback(a), [true], 'deafen mutes remote playback');
  await a.getByRole('button', { name: 'Undeafen', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === true && [...document.querySelectorAll('audio')].filter(el => el.srcObject).every(el => !el.muted));
  assert.deepEqual(await remotePlayback(a), [false], 'undeafen restores remote playback');
  assert.equal(await a.getByRole('button', { name: 'Mute', exact: true }).getAttribute('aria-pressed'), 'false', 'undeafen restores the unmuted microphone');
  assert(await audioPower(b, 'undeafened microphone') > .0001, 'microphone is audible again after undeafening');
  assert.equal((await stats(a)).connection, 'connected', 'deafening does not disturb the connection');
  await a.getByRole('button', { name: 'Mute', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === false);
  await a.getByRole('button', { name: 'Deafen', exact: true }).click();
  await a.getByRole('button', { name: 'Undeafen', exact: true }).click();
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track.enabled), false, 'undeafen preserves a pre-existing mute');
  assert.deepEqual(await remotePlayback(a), [false], 'undeafen restores playback while preserving the microphone mute');
  await a.getByRole('button', { name: 'Unmute', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === true);
  await a.getByRole('button', { name: 'Deafen', exact: true }).click();
  await a.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).click();
  await b.waitForFunction(() => window.__pcs.every(pc => pc.connectionState === 'closed'));
  await b.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).click();
  assert.equal(await a.evaluate(() => window.__pcs.every(pc => pc.connectionState === 'closed')), true);
  assert.equal(await a.evaluate(() => window.__mics.every(m => m.stream.getTracks().every(t => t.readyState === 'ended'))), true);
  // Candidates arrive long after the offer and answer, like a slow relay path. The
  // call must wait for them instead of restarting ICE until it gives up.
  candidateDelayMs = 9000;
  await b.getByRole('button', { name: 'Start call', exact: true }).click();
  await a.getByRole('button', { name: 'Accept', exact: true }).click();
  await a.waitForFunction(async () => {
    const pc = window.__pcs.at(-1);
    return pc.connectionState === 'connected' && [...(await pc.getStats()).values()].some(r => r.type === 'inbound-rtp' && r.kind === 'audio' && r.totalAudioEnergy > 0.005);
  }, null, { timeout: 30000 });
  await b.waitForFunction(async () => { const pc = window.__pcs.at(-1); return pc.connectionState === 'connected' && [...(await pc.getStats()).values()].some(r => r.type === 'inbound-rtp' && r.kind === 'audio' && r.totalAudioEnergy > 0.005); });
  candidateDelayMs = 0;
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender?.track?.readyState === 'live');
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track.enabled), true, 'new call starts unmuted after leaving deafened');
  assert.equal(await a.evaluate(() => [...document.querySelectorAll('audio')].filter(el => el.srcObject).every(el => !el.muted)), true, 'new call playback is not left deafened');
  assert.equal(await a.getByRole('button', { name: 'Deafen', exact: true }).getAttribute('aria-pressed'), 'false', 'call controls are not left showing deafened');
  assert.equal(await a.getByRole('button', { name: 'Mute', exact: true }).getAttribute('aria-pressed'), 'false', 'call controls are not left showing muted');
  await a.getByRole('button', { name: 'Open call details', exact: true }).click();
  await a.getByRole('button', { name: 'Audio settings', exact: true }).click();
  await a.waitForSelector('.voice-settings');
  await a.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).click();
  await b.waitForFunction(() => window.__pcs.every(pc => pc.connectionState === 'closed'));
  await b.locator('.call-bar [title="Leave call"]').click();
  await a.locator('.settings-sidebar').getByRole('button', { name: 'Notifications', exact: true }).click();
  await a.waitForSelector('.sound-preview-list');
  const toneCount = () => a.evaluate(() => window.__tones.length);
  for (const name of ['Message', 'Incoming call', 'Calling']) {
    const before = await toneCount();
    await a.locator('.sound-preview-btn').filter({ hasText: name }).click();
    await a.waitForFunction(before => window.__tones.length > before, before);
  }
  await a.getByRole('switch', { name: 'Toggle sound effects', exact: true }).click();
  await a.waitForFunction(() => window.__tones.filter(t => !window.__mics.some(m => m.oscillator === t.osc)).every(t => t.ended));
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_sound_enabled')), 'false');
  const previewCount = await toneCount();
  await a.locator('.sound-preview-btn').filter({ hasText: 'Message' }).click();
  await a.waitForFunction(before => window.__tones.length > before, previewCount);
  await a.screenshot({ path: 'test-results/sounds-desktop.png' });
  await a.evaluate(() => location.hash = '#dm/1');
  await a.waitForSelector('#compose');
  await a.waitForTimeout(600);
  const silentCount = await toneCount();
  const ringsBeforeReconnect = clientMessages.filter((item) => item.uid === 2 && item.msg.type === 'call_ring').length;
  dropNextRing = true;
  await b.getByRole('button', { name: 'Start call', exact: true }).click();
  await a.getByRole('button', { name: 'Decline', exact: true }).waitFor();
  assert(clientMessages.filter((item) => item.uid === 2 && item.msg.type === 'call_ring').length >= ringsBeforeReconnect + 2, 'pending call intent replays after signaling loss');
  await a.waitForTimeout(100);
  assert.equal(await toneCount(), silentCount, 'disabled sounds suppress incoming ringing');
  await a.getByRole('button', { name: 'Decline', exact: true }).click();

  // Reproduce a hard refresh directly on a server voice route. The realtime
  // roster arrives without server member data, so names must come from each
  // roster profile instead of flashing "User (id)" until navigation changes.
  await a.evaluate(() => sessionStorage.setItem('plainwire_rtc_room', JSON.stringify({
    kind: 'voice', id: 9, muted: false, deafened: false, muted_before_deafen: false, at: Date.now()
  })));
  await a.goto(origin + '/?voice-refresh=1#voice/9');
  await a.waitForFunction(() => document.querySelectorAll('.voice-participant').length === 2);
  assert.deepEqual((await a.locator('.voice-participant .grow b').allTextContents()).sort(), ['Alex Morgan', 'Jamie Chen'], 'refreshed voice roster renders profile names immediately');
  assert.equal(await a.getByText(/^User \d+$/).count(), 0, 'voice refresh never exposes numeric fallback labels');
  await a.screenshot({ path: 'test-results/voice-refresh-roster.png' });
  await a.getByRole('button', { name: 'Leave', exact: true }).click();
  }
  if (!process.env.PLAINWIRE_TEST_GROUP_CALL_ONLY) {
    await a.goto(origin + '/#dm/1'); await a.waitForSelector('#compose');
    for (const unavailable of ['NotFoundError', 'NotAllowedError']) {
      await a.evaluate(name => {
        window.__normalGum = navigator.mediaDevices.getUserMedia;
        navigator.mediaDevices.getUserMedia = async () => { throw new DOMException('Microphone unavailable', name); };
      }, unavailable);
      await a.getByRole('button', { name: 'Start call', exact: true }).click();
      await b.getByRole('button', { name: 'Accept', exact: true }).click();
      await a.getByRole('button', { name: 'Open call details', exact: true }).click();
      await a.getByRole('button', { name: 'Enable microphone', exact: true }).waitFor();
      await a.waitForFunction(() => window.__pcs.at(-1)?.connectionState === 'connected');
      const audioDeadline = Date.now() + 15000;
      while (!(await stats(a))?.inbound.some(r => r.energy > .005) && Date.now() < audioDeadline) await new Promise(resolve => setTimeout(resolve, 100));
      assert(await audioPower(a, 'listening without a microphone') > .0001, unavailable + ': listener receives audible RTP');
      const peerCount = await a.evaluate(() => window.__pcs.length);
      await a.getByRole('button', { name: 'Enable microphone', exact: true }).click();
      await a.getByText(/Microphone still unavailable/).waitFor();
      assert.equal((await stats(a)).connection, 'connected', unavailable + ': failed microphone retry preserves the call');
      if (unavailable === 'NotFoundError') {
        await a.getByRole('button', { name: 'Share', exact: true }).click();
        await a.waitForSelector('.call-sharing-row');
        await b.getByRole('button', { name: 'Open call details', exact: true }).click();
        await b.getByText('Sharing screen · audio included', { exact: true }).waitFor();
        await b.getByRole('button', { name: 'Watch screen', exact: true }).click();
        await b.waitForFunction(() => document.querySelector('#pw-float-stage-1 video')?.videoWidth > 0);
        assert(await audioPower(b, 'screen audio without microphone hardware') > .0001, 'microphone-free listener can share audible screen media');
        await a.getByRole('button', { name: 'Stop share', exact: true }).click();
        await a.getByRole('button', { name: 'Enable microphone', exact: true }).waitFor();
      }
      await a.getByRole('button', { name: 'Deafen', exact: true }).click();
      await a.getByRole('button', { name: 'Undeafen', exact: true }).click();
      await a.getByRole('button', { name: 'Enable microphone', exact: true }).waitFor();
      await a.evaluate(() => { navigator.mediaDevices.getUserMedia = window.__normalGum; });
      if (unavailable === 'NotAllowedError') {
        await a.evaluate(() => {
          navigator.mediaDevices.getUserMedia = constraints => new Promise((resolve, reject) => {
            window.__finishMicrophone = () => window.__normalGum(constraints).then(resolve, reject);
          });
        });
      }
      await a.getByRole('button', { name: 'Enable microphone', exact: true }).click();
      if (unavailable === 'NotAllowedError') {
        await a.waitForFunction(() => typeof window.__finishMicrophone === 'function');
        await a.getByRole('button', { name: 'Deafen', exact: true }).click();
        await a.evaluate(() => window.__finishMicrophone());
        await a.getByRole('button', { name: 'Unmute', exact: true }).waitFor();
        assert.equal(await a.evaluate(() => window.__pcs.at(-1)._audioSender.track.enabled), false, 'microphone permission finishing while deafened never transmits audio');
        await a.getByRole('button', { name: 'Undeafen', exact: true }).click();
        await a.getByRole('button', { name: 'Unmute', exact: true }).click();
        await a.evaluate(() => { navigator.mediaDevices.getUserMedia = window.__normalGum; });
      }
      await a.getByRole('button', { name: 'Mute', exact: true }).waitFor();
      assert(await audioPower(b, 'microphone enabled after listening') > .0001, unavailable + ': enabling the microphone sends audible RTP');
      assert.equal(await a.evaluate(() => window.__pcs.length), peerCount, 'enabling microphone keeps the existing peer connection');
      await a.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).click();
      await b.waitForFunction(() => window.__pcs.every(pc => pc.connectionState === 'closed'));
      if (await b.locator('.call-overlay.expanded').count()) await b.locator('.call-overlay').getByRole('button', { name: 'Leave', exact: true }).click();
      else await b.locator('.call-bar [title="Leave call"]').click();
    }
  }
  if (!process.env.PLAINWIRE_TEST_LISTEN_ONLY) {
    groupMode = true;
    await testGroupInvitations({ a, b, setup, origin, send, clientMessages, finishInvitation });
  }
  assert.deepEqual(errors, [], 'no browser exceptions during calls and screen sharing');
  if (process.env.PLAINWIRE_TEST_LISTEN_ONLY) console.log('PASS: missing microphone and denied permission join real calls, receive audible RTP, preserve the call on a failed microphone retry, restore listening after deafen, and enable a microphone without replacing peers.');
  else if (process.env.PLAINWIRE_TEST_GROUP_CALL_ONLY) console.log('PASS: targeted group invitations, decline/expiry isolation, stale notifications, mobile long press, and real three-peer audio without interrupting the original call.');
  else  console.log('PASS: real bidirectional RTP; signaling reconnect and pending call replay; physical and processed microphone recovery; missing device fallback; live input meter; mute/unmute; deafen state restoration; microphone swap and failed-swap recovery; screen sharing with mixed audio in both directions; hide/show and reopen viewing; quality presets; source replacement/cancellation/rollback/stop race; fullscreen and colour metadata; pointer/keyboard resizing; mobile viewer expansion; call-health measurements; mobile controls; call cleanup; refreshed voice profile roster; direct audio settings; all sound previews and disabled ringing; targeted group invitations, decline/expiry isolation, mobile long press, and three-peer audio without interrupting the original call.');
} finally { await browser.close(); server.close(); }
