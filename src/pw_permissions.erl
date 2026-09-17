-module(pw_permissions).
-export([all/0, member_default/0, admin_default/0, catalog/0, mask/1, has/2, sanitize/1]).

%% Server permissions are additive. Legacy owner/admin/member membership remains
%% valid, while custom roles OR these bits on top. Keep existing bit numbers
%% stable forever: role masks are durable database data and changing a bit would
%% silently reinterpret old roles after an upgrade.
-define(VIEW_CHANNELS,       (1 bsl 0)).
-define(SEND_MESSAGES,       (1 bsl 1)).
-define(MANAGE_MESSAGES,     (1 bsl 2)).
-define(MANAGE_CHANNELS,     (1 bsl 3)).
-define(MANAGE_SERVER,       (1 bsl 4)).
-define(MANAGE_ROLES,        (1 bsl 5)).
-define(KICK_MEMBERS,        (1 bsl 6)).
-define(MANAGE_PROFILES,     (1 bsl 7)).
-define(CREATE_WIRES,        (1 bsl 8)).
-define(VOICE_CONNECT,       (1 bsl 9)).
-define(ATTACH_FILES,        (1 bsl 10)).
-define(MANAGE_WIRES,        (1 bsl 11)).
-define(MENTION_EVERYONE,    (1 bsl 12)).
-define(ADD_REACTIONS,       (1 bsl 13)).
-define(SEND_VOICE_NOTES,    (1 bsl 14)).
-define(STREAM,              (1 bsl 15)).
-define(MUTE_MEMBERS,        (1 bsl 16)).
-define(DEAFEN_MEMBERS,      (1 bsl 17)).
-define(MOVE_MEMBERS,        (1 bsl 18)).
-define(MANAGE_WEBHOOKS,     (1 bsl 19)).
-define(MANAGE_BOTS,         (1 bsl 20)).
-define(MANAGE_EXPRESSIONS,  (1 bsl 21)).
-define(VIEW_AUDIT_LOG,      (1 bsl 22)).
-define(MANAGE_EVENTS,       (1 bsl 23)).
-define(MANAGE_THREADS,      (1 bsl 24)).
-define(CREATE_THREADS,      (1 bsl 25)).
-define(BAN_MEMBERS,         (1 bsl 26)).
-define(MANAGE_NICKNAMES,    (1 bsl 27)).
-define(CHANGE_NICKNAME,     (1 bsl 28)).
-define(PRIORITY_SPEAKER,    (1 bsl 29)).
-define(ADMINISTRATOR,       (1 bsl 30)).

all() ->
    ?VIEW_CHANNELS bor ?SEND_MESSAGES bor ?MANAGE_MESSAGES bor ?MANAGE_CHANNELS bor
    ?MANAGE_SERVER bor ?MANAGE_ROLES bor ?KICK_MEMBERS bor ?MANAGE_PROFILES bor
    ?CREATE_WIRES bor ?VOICE_CONNECT bor ?ATTACH_FILES bor ?MANAGE_WIRES bor
    ?MENTION_EVERYONE bor ?ADD_REACTIONS bor ?SEND_VOICE_NOTES bor ?STREAM bor
    ?MANAGE_WEBHOOKS bor ?MANAGE_BOTS bor ?BAN_MEMBERS bor ?ADMINISTRATOR.

%% Defaults preserve 1.x behavior for ordinary members while making every newly
%% exposed permission a real enforced capability. Reserved permission bits that
%% do not yet map to a complete product feature are intentionally not exposed.
member_default() ->
    ?VIEW_CHANNELS bor ?SEND_MESSAGES bor ?CREATE_WIRES bor ?VOICE_CONNECT bor
    ?ATTACH_FILES bor ?ADD_REACTIONS bor ?SEND_VOICE_NOTES bor ?STREAM.

admin_default() -> all().

sanitize(Value) when is_integer(Value), Value >= 0 -> Value band all();
sanitize(Value) ->
    try binary_to_integer(pw_util:bin(Value)) of
        I when I >= 0 -> I band all();
        _ -> 0
    catch
        error:badarg -> 0
    end.

has(Permissions, Bit) when is_integer(Permissions), is_integer(Bit) ->
    (Permissions band ?ADMINISTRATOR) =/= 0 orelse (Permissions band Bit) =/= 0.

mask(<<"view_channels">>) -> ?VIEW_CHANNELS;
mask(<<"send_messages">>) -> ?SEND_MESSAGES;
mask(<<"manage_messages">>) -> ?MANAGE_MESSAGES;
mask(<<"manage_channels">>) -> ?MANAGE_CHANNELS;
mask(<<"manage_server">>) -> ?MANAGE_SERVER;
mask(<<"manage_roles">>) -> ?MANAGE_ROLES;
mask(<<"kick_members">>) -> ?KICK_MEMBERS;
mask(<<"manage_profiles">>) -> ?MANAGE_PROFILES;
mask(<<"create_wires">>) -> ?CREATE_WIRES;
mask(<<"voice_connect">>) -> ?VOICE_CONNECT;
mask(<<"attach_files">>) -> ?ATTACH_FILES;
mask(<<"manage_wires">>) -> ?MANAGE_WIRES;
mask(<<"mention_everyone">>) -> ?MENTION_EVERYONE;
mask(<<"add_reactions">>) -> ?ADD_REACTIONS;
mask(<<"send_voice_notes">>) -> ?SEND_VOICE_NOTES;
mask(<<"stream">>) -> ?STREAM;
mask(<<"mute_members">>) -> ?MUTE_MEMBERS;
mask(<<"deafen_members">>) -> ?DEAFEN_MEMBERS;
mask(<<"move_members">>) -> ?MOVE_MEMBERS;
mask(<<"manage_webhooks">>) -> ?MANAGE_WEBHOOKS;
mask(<<"manage_bots">>) -> ?MANAGE_BOTS;
mask(<<"manage_expressions">>) -> ?MANAGE_EXPRESSIONS;
mask(<<"view_audit_log">>) -> ?VIEW_AUDIT_LOG;
mask(<<"manage_events">>) -> ?MANAGE_EVENTS;
mask(<<"manage_threads">>) -> ?MANAGE_THREADS;
mask(<<"create_threads">>) -> ?CREATE_THREADS;
mask(<<"ban_members">>) -> ?BAN_MEMBERS;
mask(<<"manage_nicknames">>) -> ?MANAGE_NICKNAMES;
mask(<<"change_nickname">>) -> ?CHANGE_NICKNAME;
mask(<<"priority_speaker">>) -> ?PRIORITY_SPEAKER;
mask(<<"administrator">>) -> ?ADMINISTRATOR;
mask(Name) when is_list(Name) -> mask(unicode:characters_to_binary(Name));
mask(_) -> 0.

catalog() ->
    [
      entry(<<"view_channels">>, <<"View channels">>, ?VIEW_CHANNELS, <<"See server channels and history.">>),
      entry(<<"send_messages">>, <<"Send messages">>, ?SEND_MESSAGES, <<"Send messages in text channels.">>),
      entry(<<"manage_messages">>, <<"Manage messages">>, ?MANAGE_MESSAGES, <<"Delete other members' messages below your role.">>),
      entry(<<"manage_channels">>, <<"Manage channels">>, ?MANAGE_CHANNELS, <<"Create, move, edit and remove channels and categories.">>),
      entry(<<"manage_server">>, <<"Manage server">>, ?MANAGE_SERVER, <<"Edit server identity and settings.">>),
      entry(<<"manage_roles">>, <<"Manage roles">>, ?MANAGE_ROLES, <<"Create roles and assign roles below your highest role.">>),
      entry(<<"kick_members">>, <<"Kick members">>, ?KICK_MEMBERS, <<"Remove members below your highest role.">>),
      entry(<<"ban_members">>, <<"Ban members">>, ?BAN_MEMBERS, <<"Ban or unban members below your highest role and block Wire re-entry.">>),
      entry(<<"manage_profiles">>, <<"Manage server profiles">>, ?MANAGE_PROFILES, <<"Moderate server nicknames and server-specific profiles.">>),
      entry(<<"create_wires">>, <<"Create wires">>, ?CREATE_WIRES, <<"Create server access Wires.">>),
      entry(<<"voice_connect">>, <<"Connect to voice">>, ?VOICE_CONNECT, <<"Join server voice channels.">>),
      entry(<<"attach_files">>, <<"Attach files">>, ?ATTACH_FILES, <<"Attach uploaded files to server messages.">>),
      entry(<<"manage_wires">>, <<"Manage wires">>, ?MANAGE_WIRES, <<"List and revoke server wires.">>),
      entry(<<"mention_everyone">>, <<"Mention everyone">>, ?MENTION_EVERYONE, <<"Use server-wide attention mentions.">>),
      entry(<<"add_reactions">>, <<"Add reactions">>, ?ADD_REACTIONS, <<"Add and remove reactions on server messages.">>),
      entry(<<"send_voice_notes">>, <<"Send voice notes">>, ?SEND_VOICE_NOTES, <<"Record and send voice notes in text channels.">>),
      entry(<<"stream">>, <<"Share screen">>, ?STREAM, <<"Share a screen while connected to server voice.">>),
      entry(<<"manage_webhooks">>, <<"Manage webhooks">>, ?MANAGE_WEBHOOKS, <<"Create, rotate, test and remove server webhooks.">>),
      entry(<<"manage_bots">>, <<"Manage bots">>, ?MANAGE_BOTS, <<"Create bot applications and rotate their tokens.">>),
      entry(<<"administrator">>, <<"Administrator">>, ?ADMINISTRATOR, <<"Grant every server permission. Use sparingly.">>)
    ].

entry(Key, Label, Bit, Description) ->
    #{key => Key, label => Label, bit => Bit, description => Description}.
