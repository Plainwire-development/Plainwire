-module(pw_storage_reconciler).
-behaviour(gen_server).
-export([start_link/0, run_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {interval_ms = 300000}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
run_now() -> gen_server:call(?MODULE, run_now, 120000).

init([]) ->
    Interval = erlang:min(3600000, erlang:max(30000, pw_util:env_int("PLAINWIRE_SCYLLA_RECONCILE_INTERVAL_MS", 300000))),
    erlang:send_after(Interval, self(), reconcile),
    {ok, #st{interval_ms=Interval}}.

handle_call(run_now, _From, S) -> {reply, maybe_reconcile(), S};
handle_call(_, _From, S) -> {reply, {error, bad_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(reconcile, S) ->
    _ = maybe_reconcile(),
    erlang:send_after(S#st.interval_ms, self(), reconcile),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

maybe_reconcile() ->
    case pw_scylla_config:enabled() andalso pw_scylla:ready() of
        true ->
            Intents = pw_storage_migration:reconcile_write_intents(),
            case Intents of
                {ok, #{reconciled := IntentN}} when IntentN > 0 ->
                    logger:warning("[plainwire:storage] recovered interrupted Scylla writes count=~p", [IntentN]);
                {error, Reason0} ->
                    logger:warning("[plainwire:storage] write-intent reconciliation failed reason=~p", [pw_storage_sanitize:safe_reason(Reason0)]);
                _ -> ok
            end,
            Shadow = case pw_scylla_config:backend() of
                dual -> pw_storage_migration:shadow_sample();
                _ -> {ok, #{skipped => true}}
            end,
            case Shadow of
                {ok, #{mismatch_count := ShadowN}} when ShadowN > 0 ->
                    logger:warning("[plainwire:storage] shadow read found mismatches count=~p", [ShadowN]);
                {error, Reason} ->
                    logger:warning("[plainwire:storage] shadow read failed reason=~p", [pw_storage_sanitize:safe_reason(Reason)]);
                _ -> ok
            end,
            Reconcile = pw_storage_migration:reconcile(),
            case Reconcile of
                {ok, #{repaired := RepairN}} when RepairN > 0 ->
                    logger:warning("[plainwire:storage] reconciliation repaired rows=~p", [RepairN]);
                {error, Reason1} ->
                    logger:warning("[plainwire:storage] reconciliation failed reason=~p", [pw_storage_sanitize:safe_reason(Reason1)]);
                _ -> ok
            end,
            Summary = #{write_intents => Intents, shadow => Shadow, reconcile => Reconcile},
            case first_error([Intents, Shadow, Reconcile]) of
                none -> {ok, Summary};
                {error, StageReason} -> {error, {reconciliation_stage_failed, StageReason, Summary}}
            end;
        false -> {error, scylla_unavailable}
    end.

first_error([]) -> none;
first_error([{error, Reason} | _]) -> {error, Reason};
first_error([{ok, Report} | Rest]) when is_map(Report) ->
    case {maps:get(ok, Report, true), maps:get(errors, Report, [])} of
        {false, _} -> {error, {reported_failure, Report}};
        {_, []} -> first_error(Rest);
        {_, Errors} -> {error, {reported_errors, Errors}}
    end;
first_error([_ | Rest]) -> first_error(Rest).
