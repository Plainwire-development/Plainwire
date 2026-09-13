-module(pw_rtc_config).
-export([get/0, get/1, voice_processing/0, validate/1]).

-define(DEFAULT_STUN, <<"stun:stun.l.google.com:19302">>).
-define(DEFAULT_TTL_SECONDS, 3600).

get() -> ?MODULE:get(undefined).

get(UserId) ->
    StunUrls = urls("PLAINWIRE_STUN_URLS", [?DEFAULT_STUN], stun),
    IceServers0 = maybe_server(StunUrls, []),
    {Entry, Status, Refresh, Remaining} = turn_entry(UserId),
    IceServers = case Entry of undefined -> IceServers0; _ -> IceServers0 ++ [Entry] end,
    Policy = case pw_util:env_str("PLAINWIRE_ICE_TRANSPORT_POLICY", <<"all">>) of
        <<"relay">> -> <<"relay">>;
        _ -> <<"all">>
    end,
    #{iceServers => IceServers, iceTransportPolicy => Policy, turnStatus => Status,
      turnLimitReached => Status =:= over_limit, refreshAfterSeconds => Refresh, turnTtlSeconds => Remaining}.

turn_entry(UserId) ->
    case pw_cf_turn:configured() of
        true ->
            case pw_cf_turn:ice_entry(UserId) of
                {ok, Entry, Remaining} -> {Entry, ready, max(30, min(300, Remaining - 300)), Remaining};
                {error, Reason} -> {undefined, Reason, 30, 0}
            end;
        false ->
            case urls("PLAINWIRE_TURN_URLS", [], turn) of
                [] -> {undefined, not_configured, 300, 0};
                U ->
                    Ttl = clamp_ttl(pw_util:env_int("PLAINWIRE_TURN_TTL_SECONDS", 3600)),
                    {turn_server(U, UserId), ready, min(300, max(30, Ttl div 2)), Ttl}
            end
    end.

voice_processing() ->
    Enabled = pw_util:env_bool("PLAINWIRE_KRISP_ENABLED", false),
    Ready = Enabled andalso krisp_assets_ready(),
    #{
        krisp_available => Ready,
        sdk_url => <<"/assets/krisp/krispsdk.mjs">>,
        model_8_url => <<"/assets/krisp/models/model_8.kef">>,
        model_nc_url => <<"/assets/krisp/models/model_nc_mq.kef">>
    }.

validate(Production) ->
    case pw_cf_turn:validate() of
        ok -> case pw_cf_turn:configured() of true -> ok; false -> validate_legacy(Production) end;
        Error -> Error
    end.

validate_legacy(Production) ->
    TurnUrls = urls("PLAINWIRE_TURN_URLS", [], turn),
    RequireTurn = pw_util:env_bool("PLAINWIRE_REQUIRE_TURN", Production),
    SecretReady = byte_size(pw_util:env_str("PLAINWIRE_TURN_SECRET", <<>>)) >= 32,
    StaticAllowed = not Production orelse pw_util:env_bool("PLAINWIRE_ALLOW_STATIC_TURN_CREDENTIALS", false),
    CredentialsReady = SecretReady orelse (StaticAllowed andalso credentials_configured()),
    case {RequireTurn, TurnUrls, CredentialsReady} of
        {true, [], _} -> {error, turn_urls_required};
        {true, _, false} -> {error, turn_credentials_required};
        {false, [], _} -> ok;
        {false, _, false} -> {error, turn_credentials_required};
        _ -> ok
    end.

krisp_assets_ready() ->
    case code:priv_dir(plainwire_relay) of
        Priv when is_list(Priv) ->
            Root = filename:join([Priv, "static", "krisp"]),
            lists:all(fun filelib:is_regular/1, [
                filename:join(Root, "krispsdk.mjs"),
                filename:join([Root, "models", "model_8.kef"]),
                filename:join([Root, "models", "model_nc_mq.kef"])
            ]);
        _ ->
            false
    end.

maybe_server([], Acc) -> Acc;
maybe_server(Urls, Acc) -> Acc ++ [#{urls => Urls}].

turn_server(Urls, UserId) ->
    case pw_util:env_str("PLAINWIRE_TURN_SECRET", <<>>) of
        <<>> -> static_turn_server(Urls);
        Secret -> temporary_turn_server(Urls, Secret, UserId)
    end.

static_turn_server(Urls) ->
    Username = pw_util:env_str("PLAINWIRE_TURN_USERNAME", <<>>),
    Credential = pw_util:env_str("PLAINWIRE_TURN_CREDENTIAL", <<>>),
    #{urls => Urls, username => Username, credential => Credential,
      credentialType => <<"password">>}.

temporary_turn_server(Urls, Secret, UserId) ->
    Ttl = clamp_ttl(pw_util:env_int("PLAINWIRE_TURN_TTL_SECONDS", ?DEFAULT_TTL_SECONDS)),
    Expires = erlang:system_time(second) + Ttl,
    Label0 = pw_util:env_str("PLAINWIRE_TURN_USERNAME", <<"plainwire">>),
    Label1 = safe_label(Label0),
    Label = case UserId of
        Id when is_integer(Id), Id > 0 -> <<Label1/binary, "-", (integer_to_binary(Id))/binary>>;
        _ -> Label1
    end,
    Username = <<(integer_to_binary(Expires))/binary, ":", Label/binary>>,
    Credential = base64:encode(crypto:mac(hmac, sha, Secret, Username)),
    #{urls => Urls, username => Username, credential => Credential,
      credentialType => <<"password">>}.

credentials_configured() ->
    Secret = pw_util:env_str("PLAINWIRE_TURN_SECRET", <<>>),
    Username = pw_util:env_str("PLAINWIRE_TURN_USERNAME", <<>>),
    Credential = pw_util:env_str("PLAINWIRE_TURN_CREDENTIAL", <<>>),
    byte_size(Secret) >= 32 orelse (Username =/= <<>> andalso Credential =/= <<>>).

safe_label(Label) ->
    Clean = pw_util:clean_text(Label, 64),
    binary:replace(Clean, <<":">>, <<"_">>, [global]).

clamp_ttl(N) when N >= 300, N =< 86400 -> N;
clamp_ttl(N) when N < 300 -> 300;
clamp_ttl(_) -> ?DEFAULT_TTL_SECONDS.

urls(Name, Default, Kind) ->
    case os:getenv(Name) of
        false -> Default;
        Value ->
            [unicode:characters_to_binary(Url) || Part <- string:split(Value, ",", all),
                Url <- [string:trim(Part)], Url =/= "", valid_url(Url, Kind)]
    end.

valid_url("stun:" ++ Rest, stun) -> valid_endpoint(Rest);
valid_url("stuns:" ++ Rest, stun) -> valid_endpoint(Rest);
valid_url("turn:" ++ Rest, turn) -> valid_endpoint(Rest);
valid_url("turns:" ++ Rest, turn) -> valid_endpoint(Rest);
valid_url(_, _) -> false.

valid_endpoint([]) -> false;
valid_endpoint(Rest) ->
    not lists:any(fun(C) -> C =< 32 orelse C =:= $\\ orelse C =:= $@ orelse C =:= $# end, Rest).
