-module(pw_permissions).
-export([all/0, member_default/0, admin_default/0, catalog/0, mask/1, has/2, sanitize/1]).

%% Server permissions are additive. Legacy owner/admin/member membership remains
%% valid, while custom roles OR these bits on top. This keeps upgrades safe for
%% existing servers and avoids surprising deny-order semantics.
-define(VIEW_CHANNELS,      1 bsl 0).
-define(SEND_MESSAGES,      1 bsl 1).
-define(MANAGE_MESSAGES,    1 bsl 2).
-define(MANAGE_CHANNELS,    1 bsl 3).
-define(MANAGE_SERVER,      1 bsl 4).
-define(MANAGE_ROLES,       1 bsl 5).
-define(KICK_MEMBERS,       1 bsl 6).
-define(MANAGE_PROFILES,    1 bsl 7).
-define(CREATE_WIRES,       1 bsl 8).
-define(VOICE_CONNECT,      1 bsl 9).
-define(MANAGE_WIRES,       1 bsl 11).
-define(MENTION_EVERYONE,   1 bsl 12).
-define(ADMINISTRATOR,      1 bsl 30).

all() ->
    ?VIEW_CHANNELS bor ?SEND_MESSAGES bor ?MANAGE_MESSAGES bor ?MANAGE_CHANNELS bor
    ?MANAGE_SERVER bor ?MANAGE_ROLES bor ?KICK_MEMBERS bor ?MANAGE_PROFILES bor
    ?CREATE_WIRES bor ?VOICE_CONNECT bor ?MANAGE_WIRES bor
    ?MENTION_EVERYONE bor ?ADMINISTRATOR.

member_default() ->
    ?VIEW_CHANNELS bor ?SEND_MESSAGES bor ?CREATE_WIRES bor ?VOICE_CONNECT.

admin_default() -> all().

sanitize(Value) when is_integer(Value), Value >= 0 -> Value band all();
sanitize(Value) ->
    case catch binary_to_integer(pw_util:bin(Value)) of
        I when is_integer(I), I >= 0 -> I band all();
        _ -> 0
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
mask(<<"manage_wires">>) -> ?MANAGE_WIRES;
mask(<<"mention_everyone">>) -> ?MENTION_EVERYONE;
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
      entry(<<"manage_profiles">>, <<"Manage server profiles">>, ?MANAGE_PROFILES, <<"Moderate server nicknames and server-specific profiles.">>),
      entry(<<"create_wires">>, <<"Create wires">>, ?CREATE_WIRES, <<"Create server access Wires.">>),
      entry(<<"voice_connect">>, <<"Connect to voice">>, ?VOICE_CONNECT, <<"Join server voice channels.">>),
      entry(<<"manage_wires">>, <<"Manage wires">>, ?MANAGE_WIRES, <<"List and revoke server wires.">>),
      entry(<<"mention_everyone">>, <<"Mention everyone">>, ?MENTION_EVERYONE, <<"Use server-wide attention mentions.">>),
      entry(<<"administrator">>, <<"Administrator">>, ?ADMINISTRATOR, <<"Grant every server permission. Use sparingly.">>)
    ].

entry(Key, Label, Bit, Description) ->
    #{key => Key, label => Label, bit => Bit, description => Description}.
