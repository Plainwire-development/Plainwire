-module(pw_admin_identity).
-behaviour(gen_server).
-export([start_link/0, enabled/0, instance_id/0, hash_secret/1,
         bootstrap_available/0, recovery_available/0, claim_bootstrap/3, claim_recovery/3,
         new_operator_key/0, new_enrollment_code/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(KEY_BYTES, 32).

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

enabled() -> pw_util:env_bool("PLAINWIRE_ADMIN_ENABLED", false).

instance_id() ->
    try gen_server:call(?SERVER, instance_id, 1000)
    catch exit:_ -> <<>> end.

hash_secret(Value0) ->
    Value = pw_util:bin(Value0),
    try gen_server:call(?SERVER, {hash_secret, Value}, 1000)
    catch exit:_ -> <<>> end.

bootstrap_available() ->
    try gen_server:call(?SERVER, bootstrap_available, 1000)
    catch exit:_ -> false end.

recovery_available() ->
    try gen_server:call(?SERVER, recovery_available, 1000)
    catch exit:_ -> false end.

claim_bootstrap(Code0, Username0, Password0) ->
    Code = pw_util:clean_text(Code0, 256),
    Username = pw_util:normalize_username(Username0),
    Password = pw_util:clean_text(Password0, 256),
    try gen_server:call(?SERVER, {claim_bootstrap, Code, Username, Password}, 15000)
    catch exit:_ -> {error, unavailable} end.

claim_recovery(Code0, Username0, Password0) ->
    Code = pw_util:clean_text(Code0, 256),
    Username = pw_util:normalize_username(Username0),
    Password = pw_util:clean_text(Password0, 256),
    try gen_server:call(?SERVER, {claim_recovery, Code, Username, Password}, 15000)
    catch exit:_ -> {error, unavailable} end.

new_operator_key() -> make_scoped_token(<<"op">>, 32).
new_enrollment_code() -> make_scoped_token(<<"enroll">>, 24).

init([]) ->
    case enabled() of
        false -> {stop, disabled};
        true ->
            Secret = load_or_create_secret(),
            InstanceId = binary:part(pw_util:sha256_hex(Secret), 0, 16),
            {Bootstrap, Recovery} = case pw_db:admin_operator_count() of
                {ok, 0} ->
                    Token = make_scoped_token(<<"bootstrap">>, 24, InstanceId),
                    logger:warning("[plainwire:admin] FIRST-RUN bootstrap token (one-time): ~s", [Token]),
                    {Token, undefined};
                {ok, _Count} ->
                    case pw_util:env_bool("PLAINWIRE_ADMIN_LOCAL_RECOVERY", false) of
                        true ->
                            RecoveryToken = make_scoped_token(<<"recovery">>, 24, InstanceId),
                            logger:warning("[plainwire:admin] LOCAL RECOVERY token (one-time; remove PLAINWIRE_ADMIN_LOCAL_RECOVERY after use): ~s", [RecoveryToken]),
                            {undefined, RecoveryToken};
                        false -> {undefined, undefined}
                    end;
                _ -> {undefined, undefined}
            end,
            logger:notice("[plainwire:admin] instance_id=~s bootstrap_available=~p local_recovery_available=~p",
                          [InstanceId, Bootstrap =/= undefined, Recovery =/= undefined]),
            {ok, #{secret => Secret, instance_id => InstanceId, bootstrap => Bootstrap, recovery => Recovery}}
    end.

handle_call(instance_id, _From, State) ->
    {reply, maps:get(instance_id, State), State};
handle_call({hash_secret, Value}, _From, State) ->
    Secret = maps:get(secret, State),
    {reply, pw_util:hex_binary(crypto:mac(hmac, sha256, Secret, Value)), State};
handle_call(bootstrap_available, _From, State) ->
    {reply, maps:get(bootstrap, State, undefined) =/= undefined, State};
handle_call(recovery_available, _From, State) ->
    {reply, maps:get(recovery, State, undefined) =/= undefined, State};
handle_call({claim_bootstrap, Code, Username, Password}, _From, State) ->
    case maps:get(bootstrap, State, undefined) of
        undefined -> {reply, {error, bootstrap_unavailable}, State};
        Expected ->
            case byte_size(Code) =< 256 andalso pw_util:constant_time(Code, Expected) of
                false -> {reply, {error, bad_bootstrap}, State};
                true ->
                    VerificationKey = make_scoped_token(<<"op">>, 32, maps:get(instance_id, State)),
                    VerificationHash = pw_util:hex_binary(crypto:mac(hmac, sha256, maps:get(secret, State), VerificationKey)),
                    case pw_db:admin_bootstrap_owner(Username, Password, VerificationHash) of
                        {ok, Operator} ->
                            {reply, {ok, Operator#{verification_key => VerificationKey}}, State#{bootstrap => undefined}};
                        Error -> {reply, Error, State}
                    end
            end
    end;
handle_call({claim_recovery, Code, Username, Password}, _From, State) ->
    case maps:get(recovery, State, undefined) of
        undefined -> {reply, {error, recovery_unavailable}, State};
        Expected ->
            case byte_size(Code) =< 256 andalso pw_util:constant_time(Code, Expected) of
                false -> {reply, {error, bad_recovery}, State};
                true ->
                    VerificationKey = make_scoped_token(<<"op">>, 32, maps:get(instance_id, State)),
                    VerificationHash = pw_util:hex_binary(crypto:mac(hmac, sha256, maps:get(secret, State), VerificationKey)),
                    case pw_db:admin_recover_owner(Username, Password, VerificationHash) of
                        {ok, Operator} ->
                            {reply, {ok, Operator#{verification_key => VerificationKey}}, State#{recovery => undefined}};
                        Error -> {reply, Error, State}
                    end
            end
    end;
handle_call(_, _From, State) -> {reply, {error, unsupported}, State}.

handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

make_scoped_token(Kind, Bytes) ->
    make_scoped_token(Kind, Bytes, instance_id()).

make_scoped_token(Kind, Bytes, InstanceId) ->
    Random = pw_util:random_token(Bytes),
    <<"pwadm1.", Kind/binary, ".", InstanceId/binary, ".", Random/binary>>.

load_or_create_secret() ->
    Path = secret_path(),
    case file:read_file(Path) of
        {ok, Secret} when byte_size(Secret) >= ?KEY_BYTES ->
            _ = file:change_mode(Path, 8#600),
            Secret;
        {ok, _} -> erlang:error({invalid_admin_instance_secret, Path});
        {error, enoent} -> create_secret(Path);
        {error, Reason} -> erlang:error({admin_instance_secret_unavailable, Path, Reason})
    end.

secret_path() ->
    case os:getenv("PLAINWIRE_ADMIN_SECRET_FILE") of
        false ->
            case production_env() of
                true -> "/var/lib/plainwire/admin-instance.key";
                false -> "data/admin-instance.key"
            end;
        Path when is_list(Path), Path =/= [] -> Path;
        _ -> erlang:error(invalid_admin_secret_file)
    end.

create_secret(Path) ->
    ok = filelib:ensure_dir(Path),
    Secret = crypto:strong_rand_bytes(?KEY_BYTES),
    case file:open(Path, [write, raw, binary, exclusive]) of
        {ok, Io} ->
            try
                ok = file:change_mode(Path, 8#600),
                ok = file:write(Io, Secret),
                ok = file:sync(Io)
            after
                ok = file:close(Io)
            end,
            Secret;
        {error, eexist} ->
            case file:read_file(Path) of
                {ok, Existing} when byte_size(Existing) >= ?KEY_BYTES -> Existing;
                Other -> erlang:error({admin_instance_secret_race_failed, Other})
            end;
        {error, Reason} -> erlang:error({admin_instance_secret_create_failed, Reason})
    end.

production_env() ->
    lists:member(os:getenv("PLAINWIRE_ENV"), ["prod", "production"]) orelse
        lists:member(os:getenv("NODE_ENV"), ["prod", "production"]).
