-module(pw_upload_gc).
-behaviour(gen_server).
-export([start_link/0, lookup/2, invalidate_user/1, acquire/2, release/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% auth cache is per user+upload. sharing that answer would be quite the bug.
lookup(Uid, Id) ->
    Now = erlang:monotonic_time(millisecond),
    case authorized(Uid, Id, Now) of
        {ok, false} -> {error, forbidden};
        {ok, true} ->
            case ets:lookup(pw_upload_metadata_cache, Id) of
                [{Id, Value, Expires}] when Expires > Now -> Value;
                _ -> fetch(Uid, Id, Now)
            end;
        unknown -> fetch(Uid, Id, Now)
    end.

fetch(Uid, Id, Now) ->
    Value = pw_db:get_upload(Uid, Id),
    case Value of
        {ok, _} ->
            ets:insert(pw_upload_metadata_cache, {Id, Value, Now + 300000}),
            ets:insert(pw_upload_authz_cache, {{Uid, Id}, true, Now + 300000});
        {error, forbidden} ->
            ets:insert(pw_upload_authz_cache, {{Uid, Id}, false, Now + 60000});
        _ ->
            ok
    end,
    Value.

authorized(Uid, Id, Now) ->
    case ets:lookup(pw_upload_authz_cache, {Uid, Id}) of
        [{_, Allowed, Expires}] when Expires > Now -> {ok, Allowed};
        _ -> unknown
    end.

%% membership changed, so this user's cached yes/no answers are stale.
invalidate_user(Uid) when is_integer(Uid) ->
    try ets:match_delete(pw_upload_authz_cache, {{Uid, '_'}, '_', '_'})
    catch error:badarg -> ok end,
    ok;
invalidate_user(_) -> ok.

acquire(Uid, Size) when is_integer(Size), Size > 0 ->
    GlobalMax = max(1, pw_util:env_int("PLAINWIRE_UPLOAD_CONCURRENCY", 64)),
    UserMax = max(1, pw_util:env_int("PLAINWIRE_UPLOAD_USER_CONCURRENCY", 4)),
    GlobalBytesMax = max(262144000, pw_util:env_int("PLAINWIRE_UPLOAD_INFLIGHT_BYTES", 1073741824)),
    UserBytesMax = max(262144000, pw_util:env_int("PLAINWIRE_UPLOAD_USER_INFLIGHT_BYTES", 536870912)),
    Global = ets:update_counter(pw_upload_active, global, {2, 1}, {global, 0}),
    User = ets:update_counter(pw_upload_active, {user, Uid}, {2, 1}, {{user, Uid}, 0}),
    GlobalBytes = ets:update_counter(pw_upload_active, global_bytes, {2, Size}, {global_bytes, 0}),
    UserBytes = ets:update_counter(pw_upload_active, {user_bytes, Uid}, {2, Size}, {{user_bytes, Uid}, 0}),
    case Global =< GlobalMax andalso User =< UserMax andalso
         GlobalBytes =< GlobalBytesMax andalso UserBytes =< UserBytesMax of
        true -> ok;
        false -> release(Uid, Size), {error, busy}
    end;
acquire(_, _) -> {error, busy}.

release(Uid, Size) ->
    try
        _ = ets:update_counter(pw_upload_active, global, {2, -1, 0, 0}, {global, 0}),
        _ = ets:update_counter(pw_upload_active, {user, Uid}, {2, -1, 0, 0}, {{user, Uid}, 0}),
        _ = ets:update_counter(pw_upload_active, global_bytes, {2, -Size, 0, 0}, {global_bytes, 0}),
        _ = ets:update_counter(pw_upload_active, {user_bytes, Uid}, {2, -Size, 0, 0}, {{user_bytes, Uid}, 0})
    catch error:badarg -> ok end,
    ok.

init([]) ->
    _ = ets:new(pw_upload_metadata_cache, [named_table, public, set,
        {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(pw_upload_authz_cache, [named_table, public, set,
        {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(pw_upload_active, [named_table, public, set, {write_concurrency, true}]),
    erlang:send_after(60000, self(), sweep),
    erlang:send_after(5000, self(), upload_ref_backfill),
    {ok, #{}}.

handle_info(sweep, State) ->
    Now = pw_util:now_ms(),
    RetentionDays = max(1, pw_util:env_int("PLAINWIRE_UPLOAD_RETENTION_DAYS", 90)),
    %% profile files stay; stale_uploads filters them out.
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
    Expiry = [{{'_', '_', '$1'}, [{'<', '$1', erlang:monotonic_time(millisecond)}], [true]}],
    _ = ets:select_delete(pw_upload_metadata_cache, Expiry),
    _ = ets:select_delete(pw_upload_authz_cache, Expiry),
    erlang:send_after(3600000, self(), sweep),
    {noreply, State};
%% backfill old encrypted messages in restart-safe batches.
handle_info(upload_ref_backfill, State) ->
    case pw_db:upload_ref_backfill(500) of
        {ok, done} ->
            logger:notice("[plainwire:uploads] upload_ref_backfill complete"),
            {noreply, State};
        {ok, continue} ->
            erlang:send_after(250, self(), upload_ref_backfill),
            {noreply, State};
        Other ->
            logger:warning("[plainwire:uploads] upload_ref_backfill deferred result=~p", [Other]),
            erlang:send_after(30000, self(), upload_ref_backfill),
            {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
