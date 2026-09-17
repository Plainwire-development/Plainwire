-module(pw_storage_sanitize).
-export([without_secrets/1, encode_payload/1, encode_payload/2, safe_reason/1]).

-define(MAX_DEPTH, 10).
-define(MAX_LIST_ITEMS, 256).
-define(DEFAULT_MAX_BYTES, 65536).

without_secrets(Value) -> scrub(Value, 0).

encode_payload(Value) -> encode_payload(Value, ?DEFAULT_MAX_BYTES).
encode_payload(Value, MaxBytes0) ->
    MaxBytes = clamp(MaxBytes0, 1024, 262144),
    Safe = without_secrets(Value),
    Bin = jsx:encode(Safe),
    case byte_size(Bin) =< MaxBytes of
        true -> Bin;
        false ->
            %% Preserve useful forensic metadata without retaining an oversized
            %% or potentially sensitive body in the timeline row.
            jsx:encode(#{truncated => true,
                         original_bytes => byte_size(Bin),
                         sha256 => pw_util:sha256_hex(Bin)})
    end.

%% Error terms cross driver/process boundaries and are eventually rendered in
%% operator diagnostics. Keep useful structure while refusing to serialize
%% arbitrary payloads or configured credentials into logs.
safe_reason(Value) -> safe_reason(Value, 0).

safe_reason(_Value, Depth) when Depth >= 5 -> internal_error;
safe_reason(Value, _Depth) when is_atom(Value); is_integer(Value); is_float(Value); is_boolean(Value) -> Value;
safe_reason(Bin, _Depth) when is_binary(Bin) -> redact_known_secrets(truncate_binary(Bin, 256));
safe_reason(Map, Depth) when is_map(Map) ->
    Pairs = lists:sublist(maps:to_list(Map), 32),
    maps:from_list([case sensitive_key(K) of
                        true -> {K, <<"[redacted]">>};
                        false -> {K, safe_reason(V, Depth + 1)}
                    end || {K,V} <- Pairs]);
safe_reason({K, _V}, _Depth) when is_atom(K),
                                    (K =:= password orelse K =:= passwd orelse
                                     K =:= secret orelse K =:= token orelse
                                     K =:= credentials orelse K =:= authorization orelse
                                     K =:= private_key) ->
    {K, <<"[redacted]">>};
safe_reason(Tuple, Depth) when is_tuple(Tuple), tuple_size(Tuple) =< 12 ->
    list_to_tuple([safe_reason(V, Depth + 1) || V <- tuple_to_list(Tuple)]);
safe_reason(List, Depth) when is_list(List) ->
    case maybe_text_binary(List) of
        {ok, Bin} -> safe_reason(Bin, Depth + 1);
        error -> [safe_reason(V, Depth + 1) || V <- lists:sublist(List, 32)]
    end;
safe_reason(_, _) -> internal_error.

maybe_text_binary(List) ->
    try
        Bin = unicode:characters_to_binary(List),
        case byte_size(Bin) =< 4096 of true -> {ok, Bin}; false -> error end
    catch _:_ -> error end.

truncate_binary(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_binary(Bin, Max) -> binary:part(Bin, 0, Max).

redact_known_secrets(Bin) ->
    Names = ["PLAINWIRE_SCYLLA_PASSWORD", "PLAINWIRE_DB_PASS",
             "PLAINWIRE_REDIS_PASSWORD", "PLAINWIRE_ADMIN_BOOTSTRAP_TOKEN",
             "PLAINWIRE_CF_TURN_API_TOKEN"],
    lists:foldl(fun(Name, Acc) ->
        case os:getenv(Name) of
            false -> Acc;
            "" -> Acc;
            Secret when length(Secret) >= 4 ->
                binary:replace(Acc, unicode:characters_to_binary(Secret), <<"[redacted]">>, [global]);
            _ -> Acc
        end
    end, Bin, Names).

scrub(_Value, Depth) when Depth >= ?MAX_DEPTH ->
    #{omitted => <<"depth_limit">>};
scrub(Map, Depth) when is_map(Map) ->
    maps:from_list(
      [{K, scrub(V, Depth + 1)} || {K, V} <- maps:to_list(Map), not sensitive_key(K)]);
scrub(List, Depth) when is_list(List) ->
    scrub_list(List, Depth + 1, ?MAX_LIST_ITEMS, []);
scrub(Tuple, Depth) when is_tuple(Tuple) ->
    scrub(tuple_to_list(Tuple), Depth + 1);
scrub(Atom, _Depth) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
scrub(Value, _Depth) -> Value.

scrub_list([], _Depth, _Remaining, Acc) -> lists:reverse(Acc);
scrub_list(_Rest, _Depth, 0, Acc) -> lists:reverse([#{omitted => <<"item_limit">>} | Acc]);
scrub_list([H | T], Depth, Remaining, Acc) ->
    scrub_list(T, Depth, Remaining - 1, [scrub(H, Depth) | Acc]).

sensitive_key(Key0) ->
    Key = lower_key(Key0),
    Exact = [<<"authorization">>, <<"proxy_authorization">>, <<"headers">>,
             <<"cookie">>, <<"set_cookie">>, <<"password">>, <<"passwd">>,
             <<"secret">>, <<"token">>, <<"bot_token">>, <<"webhook_secret">>,
             <<"access_token">>, <<"refresh_token">>, <<"client_secret">>,
             <<"api_key">>, <<"apikey">>, <<"private_key">>],
    Suffixes = [<<"_token">>, <<"_secret">>, <<"_password">>, <<"_passwd">>,
                <<"_api_key">>, <<"_private_key">>],
    lists:member(Key, Exact) orelse lists:any(fun(S) -> ends_with(Key, S) end, Suffixes).

lower_key(Key) ->
    Bin = try pw_util:bin(Key) catch _:_ -> iolist_to_binary(io_lib:format("~0p", [Key])) end,
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Bin))).

ends_with(Bin, Suffix) when is_binary(Bin), is_binary(Suffix) ->
    B = byte_size(Bin), S = byte_size(Suffix),
    B >= S andalso binary:part(Bin, B - S, S) =:= Suffix.

clamp(V, Min, Max) when is_integer(V) -> erlang:min(Max, erlang:max(Min, V));
clamp(_, Min, _Max) -> Min.
