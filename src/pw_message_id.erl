-module(pw_message_id).
-behaviour(gen_server).

-export([start_link/0, next/0, decode_timestamp/1, max_id/0, epoch_ms/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([test_generate/5, test_anchored_now/3]).
-endif.

%% Browser-safe Snowflake layout: 41 bits timestamp, 6 bits node, 6 bits sequence.
%% 41+6+6 = 53 bits, so every generated ID is exactly representable by JS/Elm.
-define(EPOCH_MS, 1767225600000). %% 2026-01-01T00:00:00Z
-define(NODE_BITS, 6).
-define(SEQ_BITS, 6).
-define(MAX_NODE, ((1 bsl ?NODE_BITS) - 1)).
-define(MAX_SEQ, ((1 bsl ?SEQ_BITS) - 1)).
-define(MAX_TS, ((1 bsl 41) - 1)).
-define(MAX_SAFE_JS_INT, 9007199254740991).
-define(CHECKPOINT_KEY, {?MODULE, checkpoint}).
-define(OWNER_KEY, {?MODULE, owner}).
-define(LEASE_MS, 30000).
-define(RENEW_MS, 10000).

-record(st, {node_id = 0, owner = <<>>, lease_valid = false, lease_until = 0,
             lease_deadline_mono = 0, lease_worker = undefined,
             clock_anchor_ms = 0, clock_anchor_mono = 0,
             last_ms = -1, seq = -1, rollback_tolerance_ms = 2000}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

next() ->
    try gen_server:call(?MODULE, next, 5000)
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:{timeout, _} -> {error, timeout}
    end.

max_id() -> ?MAX_SAFE_JS_INT.
epoch_ms() -> ?EPOCH_MS.

decode_timestamp(Id) when is_integer(Id), Id >= 0, Id =< ?MAX_SAFE_JS_INT ->
    ?EPOCH_MS + (Id bsr (?NODE_BITS + ?SEQ_BITS));
decode_timestamp(_) -> undefined.

init([]) ->
    Identity = instance_identity(),
    Owner = owner_id(Identity),
    Tolerance = clamp(pw_util:env_int("PLAINWIRE_MESSAGE_ID_CLOCK_ROLLBACK_MS", 2000), 0, 60000),
    case claim_node_id(Owner, Identity) of
        {ok, NodeId, LeaseUntil, DbNowMs} ->
            {Last0, Seq0} = checkpoint(NodeId),
            %% PostgreSQL is the wall-clock authority for the leased node slot.
            %% From that trusted sample forward, derive time from BEAM monotonic
            %% time. This prevents a host wall-clock rollback after a VM restart
            %% from reusing a timestamp/node/sequence range.
            MonoNow = erlang:monotonic_time(millisecond),
            Last = erlang:max(Last0, DbNowMs),
            Seq = case Last0 >= DbNowMs of true -> Seq0; false -> -1 end,
            erlang:send_after(?RENEW_MS, self(), renew_lease),
            {ok, #st{node_id = NodeId, owner = Owner, lease_valid = true, lease_until = LeaseUntil,
                     lease_deadline_mono = lease_deadline(), clock_anchor_ms = Last,
                     clock_anchor_mono = MonoNow, last_ms = Last, seq = Seq,
                     rollback_tolerance_ms = Tolerance}};
        {error, Reason} ->
            {stop, {message_id_node_claim_failed, Reason}}
    end.

handle_call(next, _From, S0) ->
    %% The durable lease is measured by PostgreSQL's clock. Locally, fence ID
    %% generation with monotonic time so a host wall-clock rollback can never
    %% extend our belief that the lease is still valid.
    LeaseOk = S0#st.lease_valid andalso
              erlang:monotonic_time(millisecond) < S0#st.lease_deadline_mono,
    case LeaseOk of
        false -> {reply, {error, node_lease_lost}, S0#st{lease_valid = false}};
        true -> case generate_runtime(S0) of
        {ok, Id, S1} ->
            persistent_term:put(?CHECKPOINT_KEY, {S1#st.node_id, S1#st.last_ms, S1#st.seq}),
            {reply, {ok, Id}, S1};
        {error, Reason, S1} -> {reply, {error, Reason}, S1}
    end
    end;
handle_call(_Req, _From, S) -> {reply, {error, bad_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(renew_lease, S0 = #st{lease_worker = undefined}) ->
    {Pid, MRef} = start_lease_worker(renew, S0#st.node_id, S0#st.owner, ?LEASE_MS),
    erlang:send_after(5000, self(), {lease_worker_timeout, Pid, MRef, renew}),
    erlang:send_after(?RENEW_MS, self(), renew_lease),
    {noreply, S0#st{lease_worker = {Pid, MRef, renew}}};
handle_info(renew_lease, S0) ->
    %% A slow database call must not create an unbounded pile of renew workers.
    %% The existing worker is monitored; its result or DOWN signal will clear it.
    erlang:send_after(1000, self(), renew_lease),
    {noreply, S0};
handle_info({lease_worker_result, Pid, renew, _LeaseMs, {ok, renewed, LeaseUntil, DbNowMs}},
            S0 = #st{lease_worker = {Pid, MRef, renew}}) ->
    erlang:demonitor(MRef, [flush]),
    S1 = refresh_clock_anchor(S0, DbNowMs),
    {noreply, S1#st{lease_valid = true, lease_until = LeaseUntil,
                    lease_deadline_mono = lease_deadline(), lease_worker = undefined}};
handle_info({lease_worker_result, Pid, renew, _LeaseUntil, Error},
            S0 = #st{lease_worker = {Pid, MRef, renew}}) ->
    erlang:demonitor(MRef, [flush]),
    logger:error("[plainwire:message_id] node lease renewal failed node_id=~p reason=~p; IDs stop at lease expiry",
                 [S0#st.node_id, Error]),
    erlang:send_after(1000, self(), reclaim_lease),
    {noreply, S0#st{lease_worker = undefined}};
handle_info(reclaim_lease, S0 = #st{lease_worker = undefined}) ->
    {Pid, MRef} = start_lease_worker(reclaim, S0#st.node_id, S0#st.owner, ?LEASE_MS),
    erlang:send_after(5000, self(), {lease_worker_timeout, Pid, MRef, reclaim}),
    {noreply, S0#st{lease_worker = {Pid, MRef, reclaim}}};
handle_info(reclaim_lease, S0) -> {noreply, S0};
handle_info({lease_worker_result, Pid, reclaim, _LeaseMs, {ok, claimed, LeaseUntil, DbNowMs}},
            S0 = #st{lease_worker = {Pid, MRef, reclaim}}) ->
    erlang:demonitor(MRef, [flush]),
    logger:notice("[plainwire:message_id] node lease reclaimed node_id=~p", [S0#st.node_id]),
    S1 = refresh_clock_anchor(S0, DbNowMs),
    {noreply, S1#st{lease_valid = true, lease_until = LeaseUntil,
                    lease_deadline_mono = lease_deadline(), lease_worker = undefined}};
handle_info({lease_worker_result, Pid, reclaim, _LeaseUntil, _Error},
            S0 = #st{lease_worker = {Pid, MRef, reclaim}}) ->
    erlang:demonitor(MRef, [flush]),
    erlang:send_after(2000, self(), reclaim_lease),
    {noreply, S0#st{lease_worker = undefined}};
handle_info({lease_worker_timeout, Pid, MRef, Kind},
            S0 = #st{lease_worker = {Pid, MRef, Kind}}) ->
    %% pw_db deliberately serializes whole PostgreSQL transactions. If the pool
    %% is wedged, a lease helper can otherwise wait forever behind that lock.
    %% Kill only the helper; ID generation continues safely until the already
    %% granted lease expires, and the DOWN handler schedules recovery.
    catch exit(Pid, kill),
    {noreply, S0};
handle_info({lease_worker_timeout, _Pid, _MRef, _Kind}, S0) ->
    {noreply, S0};
handle_info({'DOWN', MRef, process, Pid, Reason},
            S0 = #st{lease_worker = {Pid, MRef, Kind}}) ->
    %% A crashed helper must never leave renewal permanently marked in-flight.
    %% Keep the existing lease valid only until its known expiry, then retry.
    logger:error("[plainwire:message_id] lease worker crashed kind=~p node_id=~p reason=~p",
                 [Kind, S0#st.node_id, Reason]),
    Delay = case Kind of renew -> 1000; reclaim -> 2000 end,
    Next = case Kind of renew -> reclaim_lease; reclaim -> reclaim_lease end,
    erlang:send_after(Delay, self(), Next),
    {noreply, S0#st{lease_worker = undefined}};
handle_info({lease_worker_result, _Pid, _Kind, _LeaseUntil, _Result}, S0) ->
    %% Late/stale result from a worker that was already superseded.
    {noreply, S0};
handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, #st{}) ->
    %% Deliberately do not release the node lease early. The lease is a fencing
    %% window, not merely a liveness marker: retaining it across an orderly
    %% restart prevents a wall-clock rollback from immediately reusing the same
    %% node/timestamp/sequence space. A new auto-assigned runtime probes another
    %% slot; an explicitly pinned node id becomes reusable after the short lease
    %% expires. This is safer than optimizing a 30-second restart edge case at
    %% the cost of possible duplicate message IDs.
    ok.
code_change(_Old, State, _Extra) -> {ok, State}.

generate_runtime(S0) ->
    Now = runtime_now(S0),
    generate(S0, Now, fun() -> runtime_now(S0) end).

generate(S, Now) ->
    generate(S, Now, fun system_ms/0).

generate(S = #st{last_ms = Last, rollback_tolerance_ms = Tolerance}, Now, _ClockFun) when Last >= 0, Now < Last - Tolerance ->
    {error, {clock_rollback, Last - Now}, S};
generate(S0 = #st{last_ms = Last, seq = PrevSeq}, Now0, ClockFun) ->
    Now = erlang:max(Now0, Last),
    {Ts, Seq} = case Now of
        Last when PrevSeq < ?MAX_SEQ -> {Last, PrevSeq + 1};
        Last -> wait_next_ms(Last, 25, ClockFun);
        _ -> {Now, 0}
    end,
    case Ts of
        timeout -> {error, sequence_exhausted, S0};
        _ when Ts < ?EPOCH_MS -> {error, clock_before_epoch, S0};
        _ ->
            Delta = Ts - ?EPOCH_MS,
            case Delta =< ?MAX_TS of
                false -> {error, id_epoch_exhausted, S0};
                true ->
                    Id = (Delta bsl (?NODE_BITS + ?SEQ_BITS)) bor (S0#st.node_id bsl ?SEQ_BITS) bor Seq,
                    case Id =< ?MAX_SAFE_JS_INT of
                        true -> {ok, Id, S0#st{last_ms = Ts, seq = Seq}};
                        false -> {error, js_precision_exhausted, S0}
                    end
            end
    end.

wait_next_ms(_Last, 0, _ClockFun) -> {timeout, 0};
wait_next_ms(Last, Remaining, ClockFun) ->
    timer:sleep(1),
    case ClockFun() of
        Now when Now > Last -> {Now, 0};
        _ -> wait_next_ms(Last, Remaining - 1, ClockFun)
    end.

claim_node_id(Owner, Identity) ->
    case os:getenv("PLAINWIRE_MESSAGE_NODE_ID", "auto") of
        "auto" -> claim_candidates(Owner, auto_candidates(Identity));
        Raw ->
            case string:to_integer(Raw) of
                {N, ""} when N >= 0, N =< ?MAX_NODE -> claim_exact(Owner, N);
                _ -> {error, {invalid_message_node_id, Raw}}
            end
    end.

claim_candidates(_Owner, []) -> {error, no_message_node_slots};
claim_candidates(Owner, [N | Rest]) ->
    case claim_exact(Owner, N) of
        {ok, N, LeaseUntil, DbNowMs} -> {ok, N, LeaseUntil, DbNowMs};
        {error, node_id_in_use} -> claim_candidates(Owner, Rest);
        Error -> Error
    end.

claim_exact(Owner, N) ->
    case pw_db:message_id_claim_node(N, Owner, ?LEASE_MS) of
        {ok, claimed, LeaseUntil, DbNowMs} -> {ok, N, LeaseUntil, DbNowMs};
        {error, _} = Error -> Error;
        Other -> {error, {claim_failed, Other}}
    end.

auto_candidates(Owner) ->
    Start = erlang:phash2(Owner, ?MAX_NODE + 1),
    [((Start + I) rem (?MAX_NODE + 1)) || I <- lists:seq(0, ?MAX_NODE)].

instance_identity() ->
    NodeBin = atom_to_binary(node(), utf8),
    Host = unicode:characters_to_binary(os:getenv("HOSTNAME", "unknown-host")),
    case unicode:characters_to_binary(os:getenv("PLAINWIRE_INSTANCE_ID", "")) of
        <<>> -> <<Host/binary, ":", NodeBin/binary>>;
        Explicit -> Explicit
    end.

owner_id(Identity) ->
    %% The lease owner is unique per running BEAM, but stable across a supervised
    %% restart of this gen_server. Without the persistent boot nonce, an explicit
    %% PLAINWIRE_MESSAGE_NODE_ID would see its own still-live lease as belonging
    %% to a stranger after a process crash and could take the whole supervisor
    %% down while repeatedly failing to reclaim the slot. A full VM restart gets
    %% a fresh nonce and therefore remains fenced by the old short lease.
    case persistent_term:get(?OWNER_KEY, undefined) of
        {Identity, Owner} when is_binary(Owner) -> Owner;
        _ ->
            Nonce = pw_util:random_token(12),
            Owner = <<Identity/binary, ":", Nonce/binary>>,
            persistent_term:put(?OWNER_KEY, {Identity, Owner}),
            Owner
    end.


start_lease_worker(Kind, NodeId, Owner, LeaseMs) ->
    Parent = self(),
    spawn_monitor(fun() ->
        Result = case Kind of
            renew -> pw_db:message_id_renew_node(NodeId, Owner, LeaseMs);
            reclaim -> pw_db:message_id_claim_node(NodeId, Owner, LeaseMs)
        end,
        Parent ! {lease_worker_result, self(), Kind, LeaseMs, Result}
    end).

lease_deadline() ->
    %% Leave one renewal interval of local margin. The lease helper itself has a
    %% five-second hard timeout, so this local fence cannot outlive the durable
    %% PostgreSQL lease even when a response is delayed.
    erlang:monotonic_time(millisecond) + (?LEASE_MS - ?RENEW_MS).

runtime_now(#st{clock_anchor_ms = AnchorMs, clock_anchor_mono = AnchorMono}) ->
    anchored_now(AnchorMs, AnchorMono, erlang:monotonic_time(millisecond)).

anchored_now(AnchorMs, AnchorMono, MonoNow) ->
    AnchorMs + erlang:max(0, MonoNow - AnchorMono).

refresh_clock_anchor(S0, DbNowMs) when is_integer(DbNowMs) ->
    MonoNow = erlang:monotonic_time(millisecond),
    LogicalNow = anchored_now(S0#st.clock_anchor_ms, S0#st.clock_anchor_mono, MonoNow),
    Anchor = erlang:max(erlang:max(LogicalNow, S0#st.last_ms), DbNowMs),
    S0#st{clock_anchor_ms = Anchor, clock_anchor_mono = MonoNow};
refresh_clock_anchor(S0, _Invalid) -> S0.

checkpoint(NodeId) ->
    case persistent_term:get(?CHECKPOINT_KEY, undefined) of
        {CheckpointNode, L, S} when CheckpointNode =:= NodeId, is_integer(L), is_integer(S) -> {L, S};
        _ -> {-1, -1}
    end.

system_ms() -> erlang:system_time(millisecond).
clamp(V, Min, Max) -> erlang:min(Max, erlang:max(Min, V)).

-ifdef(TEST).
test_generate(NodeId, LastMs, Seq, Tolerance, Now) ->
    case generate(#st{node_id=NodeId,last_ms=LastMs,seq=Seq,rollback_tolerance_ms=Tolerance}, Now) of
        {ok, Id, S} -> {ok, Id, S#st.last_ms, S#st.seq};
        {error, Reason, S} -> {error, Reason, S#st.last_ms, S#st.seq}
    end.

test_anchored_now(AnchorMs, AnchorMono, MonoNow) ->
    anchored_now(AnchorMs, AnchorMono, MonoNow).
-endif.
