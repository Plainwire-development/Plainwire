-module(pw_admin_runtime).
-export([snapshot/0, safe_config/0]).

snapshot() ->
    Memory = maps:from_list(erlang:memory()),
    {UptimeMs, _SinceLast} = erlang:statistics(wall_clock),
    Db = case pw_db:health() of
        {ok, Map} -> Map#{available => true};
        {error, Reason} -> #{available => false, error => pw_util:bin(Reason)}
    end,
    #{instance_id => pw_admin_identity:instance_id(),
      release => release_version(),
      node => pw_util:bin(node()),
      otp_release => pw_util:bin(erlang:system_info(otp_release)),
      system_architecture => pw_util:bin(erlang:system_info(system_architecture)),
      os_type => pw_util:bin(os:type()),
      os_version => pw_util:bin(os:version()),
      schedulers => erlang:system_info(schedulers),
      schedulers_online => erlang:system_info(schedulers_online),
      logical_processors => logical_processors(),
      process_count => erlang:system_info(process_count),
      process_limit => erlang:system_info(process_limit),
      run_queue => erlang:statistics(run_queue),
      ets_table_count => length(ets:all()),
      port_count => erlang:system_info(port_count),
      atom_count => erlang:system_info(atom_count),
      atom_limit => erlang:system_info(atom_limit),
      uptime_ms => UptimeMs,
      memory => Memory,
      database => Db,
      realtime => pw_hub:stats(),
      cluster => pw_cluster:status(),
      rate_limiter => pw_rate:stats(),
      media => pw_media:stats(),
      uploads => pw_upload_gc:stats(),
      native_media_quality => #{available => pw_media_quality:available()},
      turn => #{cloudflare_configured => pw_cf_turn:configured(),
                static_turn_configured => os:getenv("PLAINWIRE_TURN_URLS") =/= false},
      config => safe_config(),
      collected_at => pw_util:now_ms()}.

safe_config() ->
    #{environment => env_bin("PLAINWIRE_ENV", <<"development">>),
      public_url => env_bin("PLAINWIRE_PUBLIC_URL", <<>>),
      admin_public_url => env_bin("PLAINWIRE_ADMIN_PUBLIC_URL", <<>>),
      registration_enabled => pw_util:env_bool("PLAINWIRE_REGISTRATION_ENABLED", true),
      upload_max_bytes => pw_util:env_int("PLAINWIRE_UPLOAD_MAX_BYTES", 262144000),
      upload_retention_days => pw_util:env_int("PLAINWIRE_UPLOAD_RETENTION_DAYS", 90),
      upload_concurrency => pw_util:env_int("PLAINWIRE_UPLOAD_CONCURRENCY", 64),
      http_max_connections => pw_util:env_int("PLAINWIRE_HTTP_MAX_CONNECTIONS", 100000),
      db_pool_size => pw_util:env_int("PLAINWIRE_DB_POOL_SIZE", 10),
      voice_max_participants => pw_hub:room_capacity(),
      voice_max_shares => pw_hub:share_capacity(),
      require_turn => pw_util:env_bool("PLAINWIRE_REQUIRE_TURN", false),
      krisp_enabled => pw_util:env_bool("PLAINWIRE_KRISP_ENABLED", false),
      media_quality_mode => env_bin("PLAINWIRE_MEDIA_QUALITY", <<"auto">>),
      adaptive_screen => pw_util:env_bool("PLAINWIRE_ADAPTIVE_SCREEN", false),
      cluster_backend => maps:get(backend, pw_cluster_config:get(), local)}.

release_version() ->
    case application:get_key(plainwire_relay, vsn) of
        {ok, Vsn} -> pw_util:bin(Vsn);
        _ -> <<"unknown">>
    end.

env_bin(Name, Default) -> pw_util:env_str(Name, Default).

logical_processors() ->
    case erlang:system_info(logical_processors_available) of
        unknown -> erlang:system_info(schedulers_online);
        N when is_integer(N) -> N
    end.
