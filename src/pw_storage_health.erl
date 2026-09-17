-module(pw_storage_health).
-export([snapshot/0]).

snapshot() ->
    Pg = postgres_health(),
    Redis = redis_health(),
    Scylla = scylla_health(),
    Backend = pw_scylla_config:backend(),
    Overall = overall(Backend, Pg, Redis, Scylla),
    #{status => Overall, backend => Backend,
      postgresql => Pg, redis => Redis, scylla => Scylla,
      collected_at => pw_util:now_ms()}.

postgres_health() ->
    case pw_db:health() of
        {ok, Details} -> Details#{status => healthy, available => true};
        {error, Reason} -> #{status => unavailable, available => false,
                             error => safe_reason(Reason)}
    end.

redis_health() ->
    Stats = pw_redis:stats(),
    Status = case {maps:get(enabled, Stats, false), maps:get(connected, Stats, false)} of
        {false, _} -> disabled;
        {true, true} -> healthy;
        {true, false} -> degraded
    end,
    Stats#{status => Status}.

scylla_health() ->
    Health = pw_scylla:health(),
    case maps:get(enabled, Health, false) of
        false -> Health#{status => disabled};
        true -> Health
    end.

overall(_Backend, #{status := unavailable}, _Redis, _Scylla) -> unavailable;
overall(postgres, _Pg, Redis, _Scylla) ->
    optional_status(Redis);
overall(dual, _Pg, Redis, Scylla) ->
    required_scylla_status(Redis, Scylla);
overall(scylla, _Pg, Redis, Scylla) ->
    required_scylla_status(Redis, Scylla);
overall(_, _Pg, _Redis, _Scylla) -> degraded.

required_scylla_status(Redis, Scylla) ->
    case maps:get(status, Scylla, unavailable) of
        healthy -> optional_status(Redis);
        _ -> degraded
    end.

optional_status(#{status := degraded}) -> degraded;
optional_status(_) -> healthy.

safe_reason(R) -> pw_storage_sanitize:safe_reason(R).
