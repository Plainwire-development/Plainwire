import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const [elm, types, bridge, markdown, api, db, less, scss, contentLess, callsScss] = await Promise.all([
  readFile('priv/static/elm/src/Main.elm', 'utf8'),
  readFile('priv/static/elm/src/Types.elm', 'utf8'),
  readFile('priv/static/elm-bridge.js', 'utf8'),
  readFile('web/markdown.js', 'utf8'),
  readFile('src/pw_api.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8'),
  readFile('priv/static/_theme-hooks.less', 'utf8'),
  readFile('priv/static/_message-extras.scss', 'utf8'),
  readFile('priv/static/_content.less', 'utf8'),
  readFile('priv/static/_calls.scss', 'utf8')
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
assert.match(elm, /conversationPreviewSummary[\s\S]*attachmentCount[\s\S]*String\.left 117 plain \+\+ "…"/, 'DM previews collapse whitespace, bound text, and summarize attachment floods');
assert.match(elm, /text \(conversationPreviewSummary lastText\)/, 'DM navigation renders a plain-text bounded preview instead of rich Markdown embeds');
assert.doesNotMatch(elm, /class "muted dm-preview"[\s\S]{0,240}Markdown\.preview lastText/, 'DM navigation never renders message media or rich Markdown');
assert.match(db, /conversation_preview_body\(StoredBody\)[\s\S]*clean_text\(load_message\(StoredBody\), 512\)/, 'conversation sync bounds last-message preview payloads server-side');
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


// Server-scoped identity, reactions, responsive composer controls, and destructive server UI.
assert.match(types, /type alias Reaction\s*=\s*\{ emoji : String[\s\S]*count : Int[\s\S]*me : Bool/, 'message reactions have an explicit typed client model');
assert.match(types, /type alias ServerProfile\s*=\s*\{ serverId : Int[\s\S]*member : ServerMember[\s\S]*roles : List ServerProfileRole/, 'server profiles carry scoped member identity and roles');
assert.match(api, /\[<<"server">>, Id, <<"member">>, UserId, <<"profile">>\]/, 'targeted server-profile endpoint is exposed');
assert.match(elm, /ShowServerProfile serverId userId[\s\S]*\/member\/" \+\+ String\.fromInt userId \+\+ "\/profile"/, 'server profile UI uses one targeted member request');
assert.match(elm, /serverMemberContext[\s\S]*View server profile[\s\S]*View full profile/, 'member context menu preserves both server and global profile choices');
assert.match(elm, /onContextMenu \(OpenServerMemberCtx serverId m\)/, 'server member rows expose the scoped profile through the context gesture');
assert.match(elm, /attribute "data-long-context" "true"/, 'rich member/message context actions opt into touch long-press');
assert.match(bridge, /pointerType !== 'touch'[\s\S]*data-long-context="true"[\s\S]*MouseEvent\('contextmenu'/, 'touch long-press maps onto the existing context-menu interaction');
assert.match(bridge, /suppressLongPressTarget === target[\s\S]*suppressLongPressTarget = null/, 'long-press click suppression releases retained DOM targets');
assert.match(elm, /memberRow[\s\S]*if String\.isEmpty m\.roleColor[\s\S]*style "color" m\.roleColor/, 'server member usernames use backend-selected role color');
assert.match(elm, /case \( m\.scope, model\.currentServer \) of[\s\S]*ShowServerProfile[\s\S]*style "color" m\.roleColor/, 'channel message usernames use server profiles and backend-selected role color without affecting DMs');
assert.match(elm, /handleServerData[\s\S]*roleColors =\s*Dict\.fromList[\s\S]*message\.scope == "channel"[\s\S]*roleColor = color/, 'role updates reconcile visible channel-message colors without recoloring DMs or refetching message pages');

assert.match(api, /\[<<"message">>, MsgId, <<"reactions">>\][\s\S]*\{reaction, uid\(Session\)\}/, 'reaction writes have an independent API rate limit');
assert.match(elm, /message_reaction_changed/, 'reaction changes are applied from realtime events');
assert.match(elm, /OpenReactionPicker[\s\S]*emojiPickerItems/, 'message reactions reuse the maintained emoji picker');
assert.match(elm, /aria-pressed[\s\S]*reaction\.me/, 'reaction chips expose the current user toggle state accessibly');
assert.match(contentLess, /\.message-reactions/, 'reaction chips have dedicated layout styling');
assert.match(contentLess, /\.composer \.gif-action \.composer-action-label\s*\{\s*display:\s*none;/, 'GIF action does not render duplicate text that collides at compact widths');

assert.match(elm, /modalHead "Delete server"[\s\S]*Delete server permanently/, 'server deletion uses a deliberate destructive confirmation surface');
assert.match(elm, /String\.trim model\.modalBody == model\.modalTitle/, 'server deletion requires exact typed-name confirmation in the UI');
assert.match(elm, /server-danger-zone/, 'owner server settings expose deletion without replacing existing customization controls');
assert.match(contentLess, /\.server-danger-zone/, 'server danger controls follow the existing settings visual language');
assert.match(callsScss, /\.call-popup-copy[\s\S]*\.call-popup-kicker[\s\S]*\.call-popup-sub/, 'call popup hierarchy is enhanced without replacing its existing actions');

console.log('PASS: emoji, mentions, DM sender summaries, edit/forward, context menus, shortcuts, attachment ACLs, and SCSS/Less layering contracts.');
