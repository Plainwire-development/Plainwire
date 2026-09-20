-module(pw_media_topology).
-export([mode/0, room_capacity/0, share_capacity/0, capabilities/0]).

%% Plainwire 2.2.0 deliberately supports exactly one media topology: WebRTC
%% full mesh. Keeping topology policy behind this module prevents call/session
%% code from baking mesh-specific capacity decisions into unrelated state logic,
%% while refusing to advertise an SFU mode that does not exist yet.
mode() -> mesh.

room_capacity() ->
    min(32, max(2, pw_util:env_int("PLAINWIRE_VOICE_MAX_PARTICIPANTS", 8))).

share_capacity() ->
    min(8, max(1, pw_util:env_int("PLAINWIRE_VOICE_MAX_SHARES", 2))).

capabilities() ->
    #{
      mode => mode(),
      max_participants => room_capacity(),
      max_shares => share_capacity(),
      server_forwarded_media => false,
      client_mesh => true
     }.
