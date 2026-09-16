import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const [elm, bridge, hub, ws] = await Promise.all([
  readFile('priv/static/elm/src/Main.elm', 'utf8'),
  readFile('priv/static/elm-bridge.js', 'utf8'),
  readFile('src/pw_hub.erl', 'utf8'),
  readFile('src/pw_ws.erl', 'utf8')
]);

const between = (text, start, end) => {
  const a = text.indexOf(start);
  assert(a >= 0, `missing ${start}`);
  const b = text.indexOf(end, a + start.length);
  assert(b > a, `missing ${end} after ${start}`);
  return text.slice(a, b);
};

const joinElm = between(elm, '        JoinCall conversationId ->', '        CallSignal _ _ ->');
assert.match(joinElm, /E\.string "join_call"/, 'existing-call Join uses the dedicated join protocol');
assert.doesNotMatch(joinElm, /E\.string "accept_call"/, 'existing-call Join must never impersonate ringing-call Accept');

const acceptBridge = between(bridge, "      case 'accept_call':", "      case 'join_call':");
assert.match(acceptBridge, /type: 'call_accept'/, 'ringing-call Accept still uses call_accept');
const joinBridge = between(bridge, "      case 'join_call':", "      case 'decline_call':");
assert.match(joinBridge, /type: 'call_join'/, 'existing-call Join sends call_join');
assert.doesNotMatch(joinBridge, /type: 'call_accept'/, 'existing-call Join does not send call_accept');

assert.match(ws, /<<"call_join">>[\s\S]*pw_hub:call_rejoin/, 'browser call_join is routed through active-room-only rejoin');
assert.match(hub, /handle_call\(\{call_rejoin[\s\S]*maps:find\(\{call, ConversationId\}[\s\S]*\{error, no_active_call\}/, 'stale call rejoin cannot resurrect an ended room');

assert.match(ws, /reply_rtc_error\(State, E, Kind, Id\)[\s\S]*rtc_kind => Kind[\s\S]*rtc_id => Id/, 'RTC join errors carry exact room correlation metadata');
assert.match(bridge, /errorKind !== pendingRtcAction\.kind \|\| errorId !== pendingRtcAction\.id/, 'unrelated websocket errors cannot tear down a pending RTC join');
assert.match(bridge, /unrelated_error_while_joining/, 'mismatched RTC errors remain observable in diagnostics');

assert.match(bridge, /RTC_RESUME_HEARTBEAT_MS\s*=\s*5000/, 'joined calls refresh their resume intent');
assert.match(bridge, /RTC_OWNER_KEY\s*=\s*'plainwire_rtc_owner_v1'/, 'cross-tab RTC ownership is explicit');
assert.match(bridge, /addEventListener\('storage'[\s\S]*RTC_OWNER_KEY/, 'duplicate tabs react to RTC ownership handoff immediately');
assert.match(bridge, /room_superseded_storage/, 'old tabs stop local capture once a replacement tab owns the session');
assert.match(bridge, /room_resume_suppressed_other_tab/, 'duplicate tabs do not silently steal the live RTC seat');
assert.match(elm, /Connected elsewhere/, 'duplicate-tab or other-client ownership is explained in the call UI');
assert.match(elm, /Ready to rejoin/, 'reconnect grace is explained instead of looking like a ghost participant');
assert.match(bridge, /SYSTEM_AUDIO_DEVICE_RE/, 'screen audio has a high-confidence monitor\/loopback fallback');
assert.match(bridge, /screenAudioSource === 'loopback'/, 'screen audio UI reports loopback fallback accurately');
assert.match(bridge, /this browser did not provide system audio/i, 'missing screen audio is surfaced instead of silently ignored');


// Muting/deafening must be local media state, while genuinely unhealthy peers self-heal.
const muteBlock = between(bridge, '  const setMuted = (muted) => {', '  const setDeafened = (value) => {');
for (const destructive of ['leaveRtcRoom(', 'replacePeerSession(', 'restartPeerIce(', 'makeOffer(']) {
  assert.ok(!muteBlock.includes(destructive), `mute must not invoke destructive RTC operation ${destructive}`);
}
const deafenBlock = between(bridge, '  const setDeafened = (value) => {', '  const enableDrag = () => {');
for (const destructive of ['leaveRtcRoom(', 'replacePeerSession(', 'restartPeerIce(', 'makeOffer(']) {
  assert.ok(!deafenBlock.includes(destructive), `deafen must not invoke destructive RTC operation ${destructive}`);
}
assert.match(bridge, /RTC_PEER_REBUILD_WINDOW_MS\s*=\s*90000[\s\S]*RTC_MAX_PEER_REBUILDS\s*=\s*2/, 'full peer repair is explicitly budgeted against reconnect storms');
assert.match(bridge, /function schedulePeerRebuild[\s\S]*peerStillExpected[\s\S]*consumePeerRepairBudget[\s\S]*replacePeerSession[\s\S]*ensurePeer/, 'terminal media recovery rebuilds only the expected failed peer');
assert.match(bridge, /remote_audio_ended[\s\S]*schedulePeerRebuild/, 'ended audio receivers trigger full peer repair instead of requiring a refresh');
assert.match(bridge, /remote_audio_missing[\s\S]*schedulePeerRebuild/, 'connected transports with missing audio trigger full peer repair');
assert.match(bridge, /restartPeerIce[\s\S]*pc\.restartIce\?\.\(\)[\s\S]*makeOffer\(uid, pc, \{ iceRestart: true \}\)/, 'ordinary transport failures keep ICE restart as the cheaper first-line recovery path');
assert.match(bridge, /peerRepairPromises\.clear\(\)[\s\S]*peerRepairHistory\.clear\(\)/, 'leaving a room clears automatic peer-repair state');
assert.match(bridge, /room\.roster = roster/, 'automatic repair is guarded by the latest authoritative room roster');
assert.match(bridge, /room\.audioConnectedAnnounced[\s\S]*Audio reconnected[\s\S]*Call audio connected/, 'connection/reconnection feedback is room-deduplicated instead of peer-spammed');
assert.match(elm, /Incoming voice call[\s\S]*Outgoing voice call[\s\S]*Answer to join the call[\s\S]*Ringing… waiting for/, 'call popup preserves actions while adding clearer call-state context');



// Half-open websocket and media paths self-heal instead of requiring a page refresh.
assert.match(bridge, /WS_HEARTBEAT_MS\s*=\s*25000[\s\S]*WS_STALE_AFTER_MS\s*=\s*55000/, 'realtime transport has an explicit heartbeat/staleness budget');
assert.match(bridge, /heartbeat_stale_socket[\s\S]*ws\.close\(4000, 'heartbeat timeout'\)/, 'half-open websocket paths are forced through normal reconnect recovery');
assert.match(bridge, /const reconnected = wsEverConnected[\s\S]*api\(\{ method: 'GET', path: '\/sync\?since=0' \}\)/, 'websocket reconnection reconciles missed account state without a page refresh');
assert.match(bridge, /const auditRtcPeers[\s\S]*currentTrack !== audioTrack[\s\S]*playRemoteAudio\(audio\)/, 'RTC audit repairs suspended/replaced browser audio playback before rebuilding transports');
assert.match(bridge, /sustained_audio_stall[\s\S]*schedulePeerRebuild/, 'sustained muted receiver/RTP stalls trigger bounded peer-only reconstruction');
assert.match(bridge, /startRtcRefresh[\s\S]*auditRtcPeers\('periodic'\)/, 'active rooms receive periodic media health auditing');
assert.match(bridge, /visibilitychange[\s\S]*auditRtcPeers\('foreground'\)/, 'returning to a suspended tab rechecks call playback immediately');

console.log('PASS: RTC protocol contracts, scoped join errors, stale-room protection, duplicate-tab ownership, resume heartbeat, and screen-audio fallback wiring.');
