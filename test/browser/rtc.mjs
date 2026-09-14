import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';
import { now, people, sync, conversations } from './fixtures.mjs';
import { nativeHealth } from './native-health.mjs';

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
const send = (uid, data) => sockets.get(uid)?.send(JSON.stringify(data));
const states = new Map();
const members = new Set();
// Simulates a slow relay path: ICE candidates arrive long after offer/answer.
let candidateDelayMs = 0;
const roster = () => people.slice(0, 2).map(p => ({ user_id: p.id, profile: p, muted: false, deafened: false, screen: false, ...states.get(p.id) }));
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
      window.__screens.push({ stream, timer });
      return stream;
    };
    window.RTCPeerConnection = class extends NativePC {
      constructor(config) { super(config); window.__pcs.push(this); }
    };
    navigator.mediaDevices.getUserMedia = async (constraints) => {
      window.__gumRequests.push(constraints);
      if (constraints.audio?.deviceId?.exact === 'unplugged') throw new DOMException('Device removed', 'NotFoundError');
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
    if (path === '/api/client-config') return route.fulfill({ json: { app_name: 'Plainwire', default_theme: 'system', version: '1.7.2-2', asset_version: '1.7.2-2', registration_enabled: true } });
    if (path === '/api/me') return reply({ user: people[uid - 1], csrf: 'test', server_time: now });
    if (path === '/api/sync') return reply({ ...sync, conversations: [{ ...conversations[0], peer_id: uid === 1 ? 2 : 1, peer_name: people[uid === 1 ? 1 : 0].display_name }] });
    if (path === '/api/messages') return reply([]);
    if (path === '/api/conversation/1') return reply({ conversation: conversations[0], members: conversations[0].members });
    if (path === '/api/rtc-config') return reply({ iceServers: [] });
    if (path === '/api/voice-processing-config') return reply({ krisp_available: false });
    return reply({});
  });
  await context.routeWebSocket('**/ws', ws => {
    sockets.set(uid, ws);
    ws.onMessage(raw => {
      const msg = JSON.parse(raw);
      if (msg.type === 'call_quality' && process.env.PLAINWIRE_TEST_NATIVE === '1') {
        nativeHealth(msg.samples).then(result => send(uid, { type: 'call_quality_result', request_id: msg.request_id, peer_id: msg.peer_id, result })).catch(error => errors.push(error.message));
        return;
      }
      if (msg.type === 'ping') return send(uid, { type: 'pong' });
      if (msg.type === 'call_signal') {
        const deliver = () => send(msg.to_user_id, { ...msg, conversation_id: 1, from_user_id: uid });
        return msg.signal?.kind === 'candidate' && candidateDelayMs ? setTimeout(deliver, candidateDelayMs) : deliver();
      }
      if (msg.type === 'call_ring') {
        send(uid, { type: 'call_ringing', conversation_id: 1, profile: people[uid === 1 ? 1 : 0] });
        send(uid === 1 ? 2 : 1, { type: 'call_incoming', conversation_id: 1, from_user_id: uid, profile: people[uid - 1] });
      }
      if (msg.type === 'call_accept') {
        states.clear();
        members.add(1); members.add(2);
        for (const target of [1, 2]) {
          send(target, { type: 'call_accepted', conversation_id: 1, user_id: target === 1 ? 2 : 1, profile: people[target === 1 ? 1 : 0] });
          send(target, { type: 'call_state', conversation_id: 1, users: roster() });
        }
      }
      if (msg.type === 'call_state' && msg.patch) {
        states.set(uid, { ...states.get(uid), ...msg.patch });
        for (const target of [1, 2]) send(target, { type: 'call_state', conversation_id: 1, users: roster() });
      }
      if (msg.type === 'call_leave') {
        members.delete(uid);
        const other = uid === 1 ? 2 : 1;
        send(other, { type: 'call_peer_left', conversation_id: 1, user_id: uid });
        send(other, { type: 'call_state', conversation_id: 1, users: roster().filter(u => members.has(u.user_id)) });
        for (const target of [1, 2]) send(target, { type: 'call_presence', conversation_id: 1, active: members.size > 0, users: roster().filter(u => members.has(u.user_id)) });
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
    return { video: reports.filter(r => r.type === 'inbound-rtp' && r.kind === 'video').map(r => r.framesDecoded), connection: pc.connectionState, transceivers: pc.getTransceivers().map(t => ({ mid: t.mid, direction: t.currentDirection, kind: t.receiver.track.kind, sending: !!t.sender.track, enabled: t.sender.track?.enabled })), inbound: reports.filter(r => r.type === 'inbound-rtp' && r.kind === 'audio').map(r => ({ packets: r.packetsReceived, energy: r.totalAudioEnergy })), outbound: reports.filter(r => r.type === 'outbound-rtp' && r.kind === 'audio').map(r => r.packetsSent) };
  });
}
try {
  const [a, b] = await Promise.all([setup(1), setup(2)]);
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
  assert.equal(await a.evaluate(() => localStorage.getItem('plainwire_audio_input')), '', 'unavailable saved microphone recovers to default');
  await a.getByRole('button', { name: 'Open call details', exact: true }).click();
  await a.waitForSelector('#call-microphone');
  // Keyboard resizing persists and reflows participant cards at wider sizes.
  const grip = a.getByRole('button', { name: 'Resize call window', exact: true });
  const originalWidth = (await a.locator('.call-overlay').boundingBox()).width;
  await grip.focus();
  for (let n = 0; n < 7; n++) await grip.press('ArrowRight');
  assert((await a.locator('.call-overlay').boundingBox()).width > originalWidth + 150);
  assert.equal(await a.locator('.call-overlay-users').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length), 2);
  assert(await a.evaluate(() => JSON.parse(localStorage.getItem('plainwire_call_size_v1')).w > 560));
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
  await a.waitForTimeout(600);
  const quietBefore = (await stats(b)).inbound[0].energy;
  await b.waitForTimeout(300);
  const quietDelta = (await stats(b)).inbound[0].energy - quietBefore;
  await a.locator('pw-input-volume input').fill('100');
  await a.waitForTimeout(500);
  const loudBefore = (await stats(b)).inbound[0].energy;
  await b.waitForTimeout(300);
  const loudDelta = (await stats(b)).inbound[0].energy - loudBefore;
  assert(loudDelta > quietDelta * 4 + .0001, 'input volume changes real outgoing audio energy');
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
  const beforeSwap = (await stats(b)).inbound[0].energy;
  await b.waitForTimeout(250);
  assert((await stats(b)).inbound[0].energy > beforeSwap, 'switched microphone remains audible remotely');

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

  // Both negotiated video directions work without sacrificing microphone audio.
  await a.getByRole('button', { name: 'Share', exact: true }).click();
  await a.waitForSelector('.call-sharing-row');
  await b.waitForFunction(async () => [...(await window.__pcs.at(-1).getStats()).values()].some(r => r.type === 'inbound-rtp' && r.kind === 'video' && r.framesDecoded > 2));
  await b.getByRole('button', { name: 'Open call details', exact: true }).click();
  assert.equal(await b.locator('#call-microphone').evaluate(el => el.selectedOptions[0]?.textContent), 'System default');
  await b.getByRole('button', { name: 'Watch screen', exact: true }).click();
  await b.waitForFunction(() => document.querySelector('#pw-float-stage-1 video')?.videoWidth > 0);
  assert.equal(await a.evaluate(() => window.__displayRequests[0].video.frameRate.max), 30);
  await a.locator('pw-screen-settings summary').click();
  await a.getByRole('combobox', { name: 'Screen sharing quality', exact: true }).selectOption('motion');
  await a.getByRole('button', { name: 'Change shared screen', exact: true }).click();
  await a.waitForFunction(() => window.__screens.length === 2 && window.__screens[0].stream.getVideoTracks()[0].readyState === 'ended');
  assert.equal(await a.evaluate(() => window.__displayRequests[1].video.frameRate.max), 60);
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._videoSender.track === window.__screens[1].stream.getVideoTracks()[0]), true);
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
    sender.replaceTrack = async () => { sender.replaceTrack = original; throw new DOMException('Injected failure', 'InvalidModificationError'); };
  });
  await a.getByRole('button', { name: 'Change shared screen', exact: true }).click();
  await a.waitForFunction(() => window.__screens.length === 3 && window.__screens[2].stream.getVideoTracks()[0].readyState === 'ended');
  assert.equal(await a.evaluate(() => window.__pcs.at(-1)._videoSender.track === window.__screens[1].stream.getVideoTracks()[0] && window.__pcs.at(-1)._videoSender.track.readyState === 'live'), true);
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
  await b.locator('#pw-float-stage-1').getByRole('button', { name: 'Close screen share', exact: true }).click();
  await b.getByRole('button', { name: 'Watch screen', exact: true }).click();
  await b.waitForFunction(() => document.querySelector('#pw-float-stage-1 video')?.videoWidth > 0);
  await b.screenshot({ path: 'test-results/screen-viewer.png' });
  await b.setViewportSize({ width: 390, height: 844 });
  const compactViewer = await viewer.boundingBox();
  await viewer.getByRole('button', { name: 'Center and fit window', exact: true }).click();
  assert((await viewer.boundingBox()).height > compactViewer.height + 200, 'mobile expand provides useful viewing space');
  assert(await viewer.getByRole('button', { name: 'Close screen share', exact: true }).isVisible());
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

  if (await a.locator('.toast-close').count()) await a.locator('.toast-close').click();
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
  // call keeps flowing in both directions.
  const remotePlayback = page => page.evaluate(() => [...document.querySelectorAll('audio[id^="remote-audio-"]')].map(el => el.muted));
  await a.getByRole('button', { name: 'Deafen', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === false);
  assert.deepEqual(await remotePlayback(a), [true], 'deafen mutes remote playback');
  await a.getByRole('button', { name: 'Undeafen', exact: true }).click();
  await a.waitForFunction(() => window.__pcs.at(-1)._audioSender.track.enabled === true);
  assert.deepEqual(await remotePlayback(a), [false], 'undeafen restores remote playback');
  assert.equal(await a.getByRole('button', { name: 'Mute', exact: true }).getAttribute('aria-pressed'), 'false', 'undeafen restores the unmuted microphone');
  const beforeUndeafenEnergy = (await stats(b)).inbound[0].energy;
  await b.waitForTimeout(400);
  assert((await stats(b)).inbound[0].energy > beforeUndeafenEnergy, 'microphone is audible again after undeafening');
  assert.equal((await stats(a)).connection, 'connected', 'deafening does not disturb the connection');

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
  await a.locator('.settings-tab').filter({ hasText: /^Notifications$/ }).click();
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
  await b.getByRole('button', { name: 'Start call', exact: true }).click();
  await a.getByRole('button', { name: 'Decline', exact: true }).waitFor();
  await a.waitForTimeout(100);
  assert.equal(await toneCount(), silentCount, 'disabled sounds suppress incoming ringing');
  assert.deepEqual(errors, [], 'no browser exceptions during calls and screen sharing');
  console.log('PASS: real bidirectional RTP; missing device fallback; live input meter; mute/unmute; microphone swap and failed-swap recovery; screen sharing in both directions; visible screen viewing and reopening; quality presets; source replacement/cancellation/rollback/stop race; fullscreen and colour metadata; pointer/keyboard resizing; mobile viewer expansion; call-health measurements; mobile controls; deafened exit/rejoin; call cleanup; direct audio settings; all sound previews and disabled ringing.');
} finally { await browser.close(); server.close(); }
