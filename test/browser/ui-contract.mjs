import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const [elm, types, bridge, markdown, sourceHub, githubBackend, githubCache, supervisor, api, db, util, less, sourceLess, scss, contentLess, callsScss, notificationView, componentsScss, refinementsScss] = await Promise.all([
  readFile('priv/static/elm/src/Main.elm', 'utf8'),
  readFile('priv/static/elm/src/Types.elm', 'utf8'),
  readFile('priv/static/elm-bridge.js', 'utf8'),
  readFile('web/markdown.js', 'utf8'),
  readFile('web/source-hub.js', 'utf8'),
  readFile('src/pw_github.erl', 'utf8'),
  readFile('src/pw_github_cache.erl', 'utf8'),
  readFile('src/pw_sup.erl', 'utf8'),
  readFile('src/pw_api.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8'),
  readFile('src/pw_util.erl', 'utf8'),
  readFile('priv/static/_theme-hooks.less', 'utf8'),
  readFile('priv/static/_source-hub.less', 'utf8'),
  readFile('priv/static/_message-extras.scss', 'utf8'),
  readFile('priv/static/_content.less', 'utf8'),
  readFile('priv/static/_calls.scss', 'utf8'),
  readFile('priv/static/elm/src/View/Notifications.elm', 'utf8'),
  readFile('priv/static/_components.scss', 'utf8'),
  readFile('priv/static/_refinements.scss', 'utf8')
]);

assert.match(markdown, /eyes:\s*'👀'/u, ':eyes: renders as the eyes emoji');
assert.match(markdown, /plainwire_emoji_shortcodes/, 'emoji shortcodes are transformed in Markdown text tokens');
assert.match(elm, /kind == "emoji_picker"/, 'emoji picker is a first-class Elm surface');
assert.match(elm, /emojiPickerItems/, 'emoji picker uses a maintained item list');
assert.match(bridge, /insert_composer_text/, 'emoji selection inserts at the active composer cursor');
assert.match(markdown, /mention\.dataset\.mentionUsername/, 'mentions retain an exact username target');
assert.match(markdown, /profile-by-username\?username=/, 'clicking a mention resolves the exact profile');
assert.match(markdown, /const EMBED_LIMIT = 5/, 'chat supports several bounded rich previews per message');
assert.match(markdown, /wireCodeForUrl[\s\S]*plainwi\.re[\s\S]*\/api\/wires\//, 'active Markdown rendering resolves canonical plainwi.re Wire links through invite metadata');
assert.match(markdown, /wireEmbedCard[\s\S]*PLAINWIRE WIRE[\s\S]*Open Wire/, 'active Markdown rendering builds a first-party server invite card');


// Plainwire Source: the logo opens a real first-class route backed by a bounded,
// same-origin GitHub metadata proxy. The browser never receives upstream tokens.
assert.match(types, /\| SourceHub/, 'Source Hub is a typed Elm route');
assert.match(elm, /onClick \(Go "#source"\)/, 'Plainwire mark opens the Source Hub');
assert.match(elm, /Html\.node "pw-source-hub"/, 'Source Hub mounts as a first-class page');
assert.match(api, /\[<<"development">>, <<"overview">>\]/, 'Source Hub overview endpoint is authenticated through the main API');
assert.match(api, /pw_rate:allow\(\{github_source, uid\(Session\)\}/, 'Source Hub upstream requests have a per-session rate limit');
assert.match(sourceHub, /\/api\/development\//, 'Source Hub browser traffic stays on the Plainwire origin');
assert.doesNotMatch(sourceHub, /fetch\(['"`]https:\/\/api\.github\.com/, 'Source Hub never calls the GitHub REST API directly from the browser');
assert.match(sourceHub, /no-embeds/, 'repository and release Markdown disables chat-style remote link previews');
assert.match(sourceHub, /no-mentions/, 'GitHub Markdown does not resolve @mentions as Plainwire users');
assert.match(markdown, /no-embeds/, 'safe Markdown supports an explicit no-embed mode');
assert.match(markdown, /no-mentions/, 'safe Markdown supports an explicit no-mention mode');
assert.match(sourceHub, /source-active-contributors/, 'recent GitHub actors are surfaced as active contributors');
assert.match(githubBackend, /anon=1&per_page=100&page=/, 'GitHub contributor requests include anonymous/unlinked commit authors and page through GitHub’s maximum page size');
assert.match(githubBackend, /cached_contributor_pages[\s\S]*length\(People\) < 100/, 'Source Hub keeps paging contributor history until GitHub returns the final contributor page');
assert.match(githubBackend, /organization_contributors\(Repos\)/, 'Source overview aggregates contributors across public Plainwire repositories');
assert.match(githubBackend, /public_contributor\(Person\)[\s\S]*anonymous[\s\S]*Unlinked author/, 'anonymous contributor records are projected to a safe public shape');
assert.match(githubBackend, /public_git_identity\(Identity\)[\s\S]*maps:remove\(<<"email">>/, 'commit author e-mail is removed before GitHub commit metadata reaches the cache or browser');
assert.match(githubBackend, /public_event_commit\(Commit\)[\s\S]*maps:remove\(<<"email">>/, 'event commit author e-mail is removed before GitHub activity reaches the cache or browser');
assert.match(sourceHub, /pushCommitCount[\s\S]*'pushed updates'/, 'push events never invent a zero-commit count when GitHub omits push commit details');
assert.match(sourceHub, /SOURCE_ORG\.toLowerCase\(\)/, 'the Plainwire organization is not treated as a person in contributor activity');
assert.doesNotMatch(sourceHub, /ranked\.slice\(0,\s*18\)/, 'organization contributor view does not silently cap visible commit authors');
assert.match(sourceHub, /No recent public activity[\s\S]*Commit authors are still loaded independently/, 'an empty delayed Events feed does not hide repository contributor data');
assert.doesNotMatch(sourceLess, /(?:linear|radial)-gradient\(/, 'Source Hub avoids decorative gradients and keeps Plainwire’s flat UI language');
assert.match(sourceHub, /source-event-commit-button/, 'push-event commits can open a bounded commit diff');
assert.match(sourceHub, /renderLanguages/, 'repository language metadata has a dedicated detector view');
assert.match(sourceHub, /decoded_content/, 'bounded source-file contents are rendered without raw HTML insertion');
assert.match(sourceHub, /textContent/, 'Source Hub builds GitHub metadata with textContent');
assert.doesNotMatch(sourceHub, /\.innerHTML\s*=/, 'Source Hub never injects GitHub metadata through innerHTML');
assert.match(sourceHub, /PLAINWIRE|Plainwire Source|Source tour/, 'Source Hub includes the guided architecture experience');
assert.match(sourceLess, /\.source-tour-guide\.is-visible/, 'Source tour uses the established Plainwire tour transition');
assert.match(sourceLess, /@media \(max-width: 760px\)/, 'Source Hub has an explicit mobile layout');
assert.match(util, /https:\/\/avatars\.githubusercontent\.com/, 'CSP permits only GitHub’s canonical avatar CDN for mirrored profiles');
assert.match(sourceHub, /githubOnly[\s\S]*hostname\.toLowerCase\(\) !== 'github\.com'/, 'GitHub action links are restricted to canonical github.com HTTPS URLs');
assert.match(sourceHub, /Cached · refresh incomplete/, 'Source Hub labels partial upstream failures as cached/degraded instead of falsely live');
assert.match(sourceHub, /validGitHubLogin/, 'Source Hub validates profile route names before issuing requests');
assert.match(githubBackend, /-define\(CACHE_MAX_ENTRIES, 128\)/, 'GitHub metadata cache has an explicit hard entry bound');
assert.match(githubBackend, /-define\(CACHE_TARGET_ENTRIES, 96\)/, 'GitHub metadata cache prunes below the hard bound');
assert.match(githubBackend, /Value =\/= <<"\.">>[\s\S]*Value =\/= <<"\.\.">>/, 'repository validation rejects dot path-normalization edge cases');
assert.match(githubCache, /ets:new\(\?TABLE, \[named_table, public, set/, 'GitHub metadata cache has a dedicated long-lived ETS owner');
assert.match(supervisor, /id => pw_github_cache[\s\S]*start => \{pw_github_cache, start_link, \[\]\}/, 'GitHub cache owner is supervised before HTTP traffic');
assert.match(githubBackend, /cached_json\(Key, Path, MaxBytes, Transform\)/, 'GitHub content can be sanitized before entering the shared cache');
assert.match(githubBackend, /fun decoded_content\/1/, 'README and source-file payloads drop upstream base64 before caching');
assert.match(githubBackend, /case github_token\(\) of[\s\S]*cached_json\(Key, Base[\s\S]*fetch_json\(Base, \?MAX_JSON, undefined, fun public_repository_metadata\/1\)/, 'token-authenticated repository visibility is rechecked live while unauthenticated reads may share safe public cache');
assert.match(githubBackend, /maps:without\(\[[\s\S]*permissions[\s\S]*security_and_analysis[\s\S]*custom_properties/, 'authenticated GitHub repo responses drop permission and organization-private metadata');
assert.match(githubBackend, /fun public_profile\/1/, 'profile metadata is projected to the public GitHub user shape before caching');
assert.match(githubBackend, /public_repository_meta\(Repo\)[\s\S]*With a server token, never make that decision from stale cache[\s\S]*public_repository_result/, 'repository detail uses a non-stale visibility gate whenever authenticated GitHub reads could cross into private data');
assert.match(sourceHub, /validRepoName/, 'Source Hub mirrors backend repository-name validation before requests');
assert.match(sourceHub, /routeSerial !== this\.routeSerial/, 'late repository/profile responses cannot overwrite a newer Source route');
assert.match(sourceHub, /dialogSerial !== this\.dialogSerial/, 'late commit/file responses cannot reopen or replace a newer Source dialog');
assert.match(sourceHub, /addEventListener\('cancel',[\s\S]*dismissDialog/, 'Source dialogs invalidate pending viewers when dismissed with Escape');

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

assert.match(bridge, /nativeEditingContextTarget\(target\)[\s\S]*return;[\s\S]*event\.preventDefault\(\)/, 'editable controls retain the native context menu while app surfaces suppress browser chrome');
assert.match(bridge, /MediaRecorder WebM files commonly omit a duration header[\s\S]*Number\.MAX_SAFE_INTEGER/, 'voice notes discover missing WebM duration metadata without requiring full playback');
assert.match(bridge, /durationHint[\s\S]*dataset\.duration[\s\S]*totalDuration/, 'voice notes use their recorded duration while browser metadata is incomplete');
assert.match(bridge, /makeVoiceNotePlayer[\s\S]*dataMediaAction = 'speed'|makeVoiceNotePlayer[\s\S]*dataset\.mediaAction = 'speed'/, 'voice notes use the custom player with playback-speed control');
assert.match(bridge, /plainwire:dialog-close[\s\S]*cleanupRecorder/, 'closing the voice recorder through any dialog control releases its capture resources');
assert.match(scss, /\.voice-note-player\s*\{[\s\S]*grid-template-columns:[\s\S]*@media \(max-width:620px\)/, 'voice-note controls use the shared responsive UI language');
assert.match(componentsScss, /\.call-overlay-controls \.call-icon\s*\{[^}]*margin:\s*0;/, 'wide call controls keep their icon and label centered as one group');
assert.match(refinementsScss, /\.channel-glyph\.voice::before\s*\{[^}]*transform:\s*translateY\(-1px\)/, 'voice-channel headphones receive the same optical centering as call controls');
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



// Reaction activity should be useful without becoming a notification-abuse surface.
assert.match(db, /best_effort_reaction_notification[\s\S]*AuthorUid =:= ReactorUid[\s\S]*can_read_messages\(Conn, AuthorUid, Scope, ScopeId\)[\s\S]*reaction_notify[\s\S]*3, 300000/, 'reaction notifications exclude self-reactions, require current recipient access, and are per-message rate bounded');
assert.match(db, /create_notification\(Conn, AuthorUid, <<"message_reaction">>[\s\S]*pw_hub:notify_user\(AuthorUid/, 'reaction additions are persisted and delivered through the normal notification channel');
assert.match(elm, /handleNotificationEvent[\s\S]*message_reaction[\s\S]*playNotification model\.soundEnabled[\s\S]*notify/, 'reaction realtime notifications update the activity feed and surface sound/desktop feedback');
assert.match(notificationView, /"message_reaction"[\s\S]*"Reaction"/, 'reaction notifications have a human-facing activity label');

// Mobile onboarding follows visible mobile controls instead of spotlighting hidden desktop chrome.
assert.match(bridge, /mobileSelector:\s*'\.mobile-nav-btn\[aria-label\^="Messages"\]'/, 'tour defines mobile-first targets for hidden desktop navigation');
assert.match(bridge, /usableTourTarget[\s\S]*getBoundingClientRect[\s\S]*style\.display === 'none'/, 'tour target resolution rejects hidden or zero-size elements');
assert.match(bridge, /const tourSelector = \(step\)[\s\S]*step\.mobileSelector/, 'tour selects responsive targets at runtime');
assert.match(bridge, /guide\.classList\.toggle\('is-top'[\s\S]*viewportHeight/, 'mobile guide moves away from lower-screen targets');
assert.match(componentsScss, /\.pw-tour-guide\.is-top[\s\S]*safe-area-inset-top/, 'mobile guide supports safe-area-aware top placement');
assert.match(componentsScss, /\.pw-tour-source-card[\s\S]*margin-left:\s*0/, 'mobile completion/source card no longer inherits desktop indentation');


// Realtime is the fast path, with a bounded visible-tab safety net for missed events.
assert.match(bridge, /APP_RECONCILE_MS\s*=\s*180000/, 'visible-tab state reconciliation is deliberately low-frequency');
assert.match(bridge, /reconcileVisibleApp[\s\S]*document\.hidden[\s\S]*navigator\.onLine[\s\S]*\/sync\?since=0/, 'fallback reconciliation only runs for visible online authenticated sessions');
assert.match(bridge, /periodic_safety_net[\s\S]*APP_RECONCILE_MS/, 'periodic fallback state reconciliation is scheduled');
assert.match(bridge, /messages\?scope=direct&scope_id=\$\{match\[1\]\}[\s\S]*messages\?scope=channel&scope_id=\$\{match\[1\]\}/, 'fallback reconciliation refreshes the active conversation/channel without polling every route');

console.log('PASS: emoji, mentions, DM sender summaries, edit/forward, context menus, shortcuts, attachment ACLs, and SCSS/Less layering contracts.');
