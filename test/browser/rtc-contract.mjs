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

console.log('PASS: RTC protocol contracts, scoped join errors, stale-room protection, duplicate-tab ownership, resume heartbeat, and screen-audio fallback wiring.');
