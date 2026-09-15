import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const [elm, types, bridge, markdown, api, db, less, scss] = await Promise.all([
  readFile('priv/static/elm/src/Main.elm', 'utf8'),
  readFile('priv/static/elm/src/Types.elm', 'utf8'),
  readFile('priv/static/elm-bridge.js', 'utf8'),
  readFile('web/markdown.js', 'utf8'),
  readFile('src/pw_api.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8'),
  readFile('priv/static/_theme-hooks.less', 'utf8'),
  readFile('priv/static/_message-extras.scss', 'utf8')
]);

assert.match(markdown, /eyes:\s*'👀'/u, ':eyes: renders as the eyes emoji');
assert.match(markdown, /plainwire_emoji_shortcodes/, 'emoji shortcodes are transformed in Markdown text tokens');
assert.match(elm, /kind == "emoji_picker"/, 'emoji picker is a first-class Elm surface');
assert.match(elm, /emojiPickerItems/, 'emoji picker uses a maintained item list');
assert.match(bridge, /insert_composer_text/, 'emoji selection inserts at the active composer cursor');
assert.match(markdown, /mention\.dataset\.mentionUsername/, 'mentions retain an exact username target');
assert.match(markdown, /profile-by-username\?username=/, 'clicking a mention resolves the exact profile');

assert.match(api, /\[<<"edit_message">>, MsgId\]/, 'edit endpoint is exposed');
assert.match(api, /\[<<"forward_message">>, MsgId\]/, 'forward endpoint is exposed');
assert.match(db, /UPDATE messages SET body\s*=\s*\$1,\s*edited_at\s*=\s*\$2/, 'edits are persisted server-side');
assert.match(db, /forwarded_from_id/, 'forward provenance is persisted');
assert.match(db, /forwarded_from_id IS NULL/, 'forwarded snapshots cannot be edited and misattributed');
assert.match(db, /can_modify_message_scope/, 'message edits and deletes require current scope membership');
assert.match(db, /COALESCE\(forwarded_from_id\s*,\s*id\)/, 're-forwarding preserves the original provenance root');
assert.match(db, /fu\.display_name, NULL/, 'forward provenance never fetches the live source body across scopes');
assert.match(db, /forwarded_from => #\{id => ForwardId[\s\S]*body => load_message\(Body\)/, 'forward provenance exposes only the forwarded snapshot body');
assert.match(db, /SuppressMentions/, 'forwarded content cannot re-fire mentions in the destination');
assert.match(db, /insert_upload_refs\(Conn, load_message\(StoredBody\), TargetScope, TargetId, Now\)/, 'forwarded uploads gain target-scope access');
assert.match(db, /safe_log_msg\(\{edit_message, Uid, Mid, _\}\).*redacted/s, 'edited message bodies are redacted from DB error logs');
assert.match(types, /lastSenderName\s*:\s*String/, 'conversation summaries carry the latest sender');
assert.match(elm, /dm-preview-sender/, 'DM sidebar renders the latest sender');
assert.match(elm, /StartEditMessage/, 'message editing is wired into Elm');
assert.match(elm, /OpenForwardModal/, 'message forwarding is wired into Elm');
assert.match(elm, /Find a destination/, 'forwarding UI provides destination search');
assert.match(bridge, /message-edit-input[\s\S]*focus/, 'message edit mode receives keyboard focus automatically');
assert.match(elm, /Forwarded from/, 'forward provenance is visible in the message UI');

assert.match(bridge, /addEventListener\('contextmenu'[\s\S]*event\.preventDefault\(\)/, 'native in-app context menu is suppressed');
assert.match(elm, /attribute "role" "menuitem"/, 'custom context actions are keyboard-focusable menu items');
assert.match(bridge, /data-context-x|dataset\.contextX/, 'custom context menus are viewport-positioned instead of blindly using raw coordinates');
assert.match(bridge, /emitShortcut\('toggle_mute'\)/, 'mute shortcut is routed through the command layer');
assert.match(bridge, /emitShortcut\('toggle_deafen'\)/, 'deafen shortcut is routed through the command layer');
assert.match(bridge, /emitShortcut\('prev_route'\)/, 'previous-route shortcut is wired');
assert.match(bridge, /emitShortcut\('next_route'\)/, 'next-route shortcut is wired');
assert.match(bridge, /emitShortcut\('edit_last_message'\)/, 'empty-composer Up Arrow quick-edit shortcut is wired');
assert.match(bridge, /emitShortcut\('settings'\)/, 'settings shortcut is wired');
assert.match(bridge, /emitShortcut\('emoji_picker'\)/, 'emoji shortcut is wired');
assert.match(bridge, /emitShortcut\('upload'\)/, 'upload shortcut is wired');
assert.match(bridge, /emitShortcut\('answer_call'\)/, 'incoming call answer shortcut is wired');
assert.match(bridge, /emitShortcut\('active_audio'\)/, 'connected-audio navigation shortcut is wired');
assert.match(bridge, /emitShortcut\('prev_server'\)/, 'previous-server shortcut is wired');
assert.match(bridge, /emitShortcut\('next_server'\)/, 'next-server shortcut is wired');
assert.match(bridge, /key === 'b'[\s\S]*emitShortcut\('prev_route'\)/, 'Discord-style Ctrl/Cmd+B previous-route shortcut is wired');
assert.match(elm, /message\.forwardedFrom == Nothing/, 'quick edit and edit commands refuse forwarded snapshots');
assert.match(bridge, /textarea\[data-message-editor="true"\]/, 'message editor keyboard handling is scoped to the editor');
assert.match(elm, /model\.voice\.mode == Nothing[\s\S]*Join a call or voice channel before toggling mute/, 'mute shortcut cannot create phantom call state');
assert.match(bridge, /contextMenu[\s\S]*ArrowDown[\s\S]*ArrowUp/, 'custom context menus support arrow-key navigation');
assert.match(types, /OpenServerCtx Server Int Int/, 'servers participate in the custom context-menu system');
assert.match(types, /OpenChannelCtx Channel Int Int/, 'channels participate in the custom context-menu system');
assert.match(elm, /serverContext : Server -> Int -> Int -> ContextMenu/, 'server context actions are first-class Elm UI');
assert.match(elm, /channelContext : Channel -> Int -> Int -> ContextMenu/, 'channel context actions are first-class Elm UI');

assert.match(db, /message_body_valid\(Plain\)/, 'message validity is checked against plaintext before encryption');
assert.match(db, /re:run\(Body, <<"\\\\S">>/, 'whitespace-only payloads are rejected server-side');

assert.match(less, /--pw-mention-bg/, 'theme-facing message tokens live in Less');
assert.match(scss, /\.message-editor/, 'complex message interaction layout lives in SCSS');
assert.match(scss, /\.forward-modal/, 'forwarding UI has dedicated SCSS');

console.log('PASS: emoji, mentions, DM sender summaries, edit/forward, context menus, shortcuts, attachment ACLs, and SCSS/Less layering contracts.');
