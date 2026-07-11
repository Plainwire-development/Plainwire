-module(pw_upload_gc).
-behaviour(gen_server).
-export([start_link/0, lookup/2, acquire/1, release/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

lookup(Uid, Id) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(pw_upload_metadata_cache, Id) of
        [{Id, Value, Expires}] when Expires > Now -> Value;
        _ ->
            Value = pw_db:get_upload(Uid, Id),
            case Value of
                {ok, _} -> ets:insert(pw_upload_metadata_cache, {Id, Value, Now + 300000});
                _ -> ok
            end,
            Value
    end.

acquire(Uid) ->
    GlobalMax = max(1, pw_util:env_int("PLAINWIRE_UPLOAD_CONCURRENCY", 64)),
    UserMax = max(1, pw_util:env_int("PLAINWIRE_UPLOAD_USER_CONCURRENCY", 4)),
    Global = ets:update_counter(pw_upload_active, global, {2, 1}, {global, 0}),
    User = ets:update_counter(pw_upload_active, {user, Uid}, {2, 1}, {{user, Uid}, 0}),
    case Global =< GlobalMax andalso User =< UserMax of
        true -> ok;
        false -> release(Uid), {error, busy}
    end.

release(Uid) ->
    try
        _ = ets:update_counter(pw_upload_active, global, {2, -1, 0, 0}, {global, 0}),
        _ = ets:update_counter(pw_upload_active, {user, Uid}, {2, -1, 0, 0}, {{user, Uid}, 0})
    catch error:badarg -> ok end,
    ok.

init([]) ->
    _ = ets:new(pw_upload_metadata_cache, [named_table, public, set,
        {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(pw_upload_active, [named_table, public, set, {write_concurrency, true}]),
    erlang:send_after(60000, self(), sweep),
    {ok, #{}}.

handle_info(sweep, State) ->
    Now = pw_util:now_ms(),
    RetentionDays = max(1, pw_util:env_int("PLAINWIRE_UPLOAD_RETENTION_DAYS", 90)),
    case pw_db:stale_uploads(Now - 86400000, Now - RetentionDays * 86400000) of
        {ok, Items} ->
            lists:foreach(fun(#{id := Id, path := Path}) ->
                _ = file:delete(binary_to_list(Path)),
                _ = file:delete(binary_to_list(<<Path/binary, ".part">>)),
                ets:delete(pw_upload_metadata_cache, Id),
                _ = pw_db:delete_upload(Id)
            end, Items);
        _ -> ok
    end,
    _ = ets:select_delete(pw_upload_metadata_cache,
        [{{'_', '_', '$1'}, [{'<', '$1', erlang:monotonic_time(millisecond)}], [true]}]),
    erlang:send_after(3600000, self(), sweep),
    {noreply, State};
handle_info(_, State) -> {noreply, State}.

handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
