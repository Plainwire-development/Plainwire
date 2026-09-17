-module(pw_scylla_config).
-export([enabled/0, backend/0, config/0, consistency/0, bucket_policy/0, validate/0]).

enabled() ->
    pw_util:env_bool("PLAINWIRE_SCYLLA_ENABLED", false) orelse lists:member(backend(), [dual, scylla]).

backend() ->
    case string:lowercase(os:getenv("PLAINWIRE_MESSAGE_BACKEND", "postgres")) of
        "postgres" -> postgres;
        "dual" -> dual;
        "scylla" -> scylla;
        Other -> erlang:error({invalid_message_backend, Other})
    end.

config() ->
    #{enabled => enabled(),
      backend => backend(),
      contact_points => contact_points(),
      port => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_PORT", 9042), 1, 65535),
      keyspace => pw_util:clean_text(os:getenv("PLAINWIRE_SCYLLA_KEYSPACE", "plainwire"), 96),
      username => secret_env("PLAINWIRE_SCYLLA_USERNAME"),
      password => secret_env("PLAINWIRE_SCYLLA_PASSWORD"),
      tls => pw_util:env_bool("PLAINWIRE_SCYLLA_TLS", false),
      ca_file => secret_env("PLAINWIRE_SCYLLA_CA_FILE"),
      cert_file => secret_env("PLAINWIRE_SCYLLA_CERT_FILE"),
      key_file => secret_env("PLAINWIRE_SCYLLA_KEY_FILE"),
      local_dc => pw_util:clean_text(os:getenv("PLAINWIRE_SCYLLA_LOCAL_DC", ""), 96),
      consistency => consistency(),
      pool_size => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_POOL_SIZE", 2), 1, 64),
      io_threads => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_IO_THREADS", 2), 1, 64),
      queue_size => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_DRIVER_QUEUE", 32768), 1024, 1048576),
      connect_timeout_ms => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_CONNECT_TIMEOUT_MS", 5000), 250, 60000),
      request_timeout_ms => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_REQUEST_TIMEOUT_MS", 5000), 250, 60000),
      operation_timeout_ms => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_OPERATION_TIMEOUT_MS", 8000), 500, 120000),
      max_inflight => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_MAX_INFLIGHT", 256), 8, 8192),
      max_partition_inflight => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_MAX_PARTITION_INFLIGHT", 8), 1, 256),
      max_queue => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_MAX_QUEUE", 4096), 16, 65536),
      max_partition_queue => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_MAX_PARTITION_QUEUE", 128), 1, 4096),
      cache_ttl_ms => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_CACHE_TTL_MS", 20000), 1000, 300000),
      event_retention_days => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_EVENT_RETENTION_DAYS", 365), 1, 3650),
      delivery_retention_days => clamp(pw_util:env_int("PLAINWIRE_SCYLLA_DELIVERY_RETENTION_DAYS", 90), 1, 3650),
      bucket_policy => bucket_policy(),
      migration_mode => migration_mode()}.

consistency() ->
    case string:lowercase(os:getenv("PLAINWIRE_SCYLLA_CONSISTENCY", "local_quorum")) of
        "one" -> one;
        "quorum" -> quorum;
        "local_one" -> local_one;
        "local_quorum" -> local_quorum;
        Other -> erlang:error({invalid_scylla_consistency, Other})
    end.

bucket_policy() ->
    case string:lowercase(os:getenv("PLAINWIRE_SCYLLA_BUCKET_POLICY", "month")) of
        "day" -> day;
        "week" -> week;
        "month" -> month;
        Other -> erlang:error({invalid_scylla_bucket_policy, Other})
    end.

migration_mode() ->
    case string:lowercase(os:getenv("PLAINWIRE_SCYLLA_MIGRATION_MODE", "manual")) of
        "manual" -> manual;
        "verify" -> verify;
        Other -> erlang:error({invalid_scylla_migration_mode, Other})
    end.

validate() ->
    Cfg = config(),
    case maps:get(enabled, Cfg) of
        false -> ok;
        true ->
            case {maps:get(contact_points, Cfg), valid_keyspace(maps:get(keyspace, Cfg))} of
                {[], _} -> {error, no_contact_points};
                {_, false} -> {error, invalid_keyspace};
                {_, true} -> validate_tls(Cfg)
            end
    end.

validate_tls(#{tls := false, cert_file := <<>>, key_file := <<>>}) -> ok;
validate_tls(#{tls := false}) -> {error, client_certificate_requires_tls};
validate_tls(#{tls := true, ca_file := <<>>}) -> {error, tls_ca_required};
validate_tls(#{tls := true, ca_file := Ca, cert_file := Cert, key_file := Key}) ->
    case filelib:is_regular(binary_to_list(Ca)) of
        false -> {error, tls_ca_not_found};
        true ->
            case {Cert, Key} of
                {<<>>, <<>>} -> ok;
                {<<>>, _} -> {error, incomplete_client_certificate};
                {_, <<>>} -> {error, incomplete_client_certificate};
                _ ->
                    case filelib:is_regular(binary_to_list(Cert)) andalso filelib:is_regular(binary_to_list(Key)) of
                        true -> ok;
                        false -> {error, client_certificate_not_found}
                    end
            end
    end.

valid_keyspace(Bin) when is_binary(Bin) ->
    case re:run(Bin, <<"^[A-Za-z][A-Za-z0-9_]*$">>, [{capture, none}]) of match -> true; _ -> false end;
valid_keyspace(_) -> false.

contact_points() ->
    Raw = os:getenv("PLAINWIRE_SCYLLA_CONTACT_POINTS", "127.0.0.1"),
    [unicode:characters_to_binary(string:trim(X)) || X <- string:split(Raw, ",", all), string:trim(X) =/= ""].

secret_env(Name) -> unicode:characters_to_binary(os:getenv(Name, "")).
clamp(V, Min, Max) -> erlang:min(Max, erlang:max(Min, V)).
