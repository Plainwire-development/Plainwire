-module(pw_klipy).
-export([enabled/0, search/3, register_share/3]).

-define(BASE, <<"https://api.klipy.com/v2">>).
-define(MAX_RESPONSE, 2097152).

%% KLIPY stays server-side: the browser never receives the integration key.
enabled() -> byte_size(api_key()) > 0.

search(Uid, Query0, Pos0) ->
    Query = pw_util:clean_text(Query0, 120),
    Pos = pw_util:clean_text(Pos0, 160),
    case {enabled(), byte_size(Query) >= 1, pw_rate:allow({klipy_search, Uid}, 45, 60000)} of
        {false, _, _} -> {error, gif_search_unavailable};
        {_, false, _} -> {error, invalid_query};
        {_, _, false} -> {error, rate_limited};
        _ ->
            Params0 = [
                {<<"key">>, api_key()}, {<<"q">>, Query}, {<<"country">>, country()},
                {<<"locale">>, locale()}, {<<"contentfilter">>, content_filter()},
                {<<"media_filter">>, <<"gif,tinygif,mp4,tinymp4">>}, {<<"limit">>, <<"24">>}
            ],
            Params = case Pos of <<>> -> Params0; _ -> Params0 ++ [{<<"pos">>, Pos}] end,
            get_json(<<(?BASE)/binary, "/search?", (query(Params))/binary>>, fun(Map) ->
                Items0 = list_or_empty(maps:get(<<"results">>, Map, [])),
                Items = [I || I <- [normalise_item(Item) || Item <- Items0], I =/= skip],
                #{provider => <<"KLIPY">>, query => Query,
                  next => pw_util:clean_text(maps:get(<<"next">>, Map, <<>>), 256), results => Items}
            end)
    end.

register_share(Uid, Id0, Query0) ->
    Id = pw_util:clean_text(Id0, 160),
    Query = pw_util:clean_text(Query0, 120),
    case {enabled(), byte_size(Id) > 0, pw_rate:allow({klipy_share, Uid}, 120, 60000)} of
        {false, _, _} -> {error, gif_search_unavailable};
        {_, false, _} -> {error, invalid_gif};
        {_, _, false} -> {error, rate_limited};
        _ ->
            Params0 = [{<<"key">>, api_key()}, {<<"id">>, Id}, {<<"country">>, country()}, {<<"locale">>, locale()}],
            Params = case Query of <<>> -> Params0; _ -> Params0 ++ [{<<"q">>, Query}] end,
            %% Sharing telemetry is best-effort UX metadata. A KLIPY outage must
            %% not prevent the already-selected GIF from being sent.
            case get_json(<<(?BASE)/binary, "/registershare?", (query(Params))/binary>>, fun(_) -> #{registered => true} end) of
                {ok, Data} -> {ok, Data};
                _ -> {ok, #{registered => false}}
            end
    end.

api_key() -> pw_util:clean_text(pw_util:env_str("PLAINWIRE_KLIPY_API_KEY", <<>>), 512).

country() ->
    Value = string:uppercase(pw_util:clean_text(pw_util:env_str("PLAINWIRE_KLIPY_COUNTRY", <<"US">>), 2)),
    case re:run(Value, <<"^[A-Z]{2}$">>, [{capture, none}]) of
        match -> Value;
        nomatch -> <<"US">>
    end.

locale() ->
    Value = pw_util:clean_text(pw_util:env_str("PLAINWIRE_KLIPY_LOCALE", <<"en_US">>), 16),
    case re:run(Value, <<"^[A-Za-z]{2}(?:_[A-Za-z]{2})?$">>, [{capture, none}]) of
        match -> Value;
        nomatch -> <<"en_US">>
    end.

content_filter() ->
    case string:lowercase(pw_util:env_str("PLAINWIRE_KLIPY_CONTENT_FILTER", <<"medium">>)) of
        <<"off">> -> <<"off">>;
        <<"low">> -> <<"low">>;
        <<"high">> -> <<"high">>;
        _ -> <<"medium">>
    end.

query(Pairs) -> iolist_to_binary(uri_string:compose_query(Pairs)).

get_json(Url, Normalise) ->
    case pw_http_fetch:get(Url, ?MAX_RESPONSE, #{accept => "application/json", user_agent => "PlainwireRelay/KLIPY"}) of
        {ok, Code, _Headers, Body} when Code >= 200, Code < 300 ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> {ok, Normalise(Map)};
                _ -> {error, invalid_provider_response}
            catch _:_ -> {error, invalid_provider_response}
            end;
        {ok, 429, _, _} -> {error, provider_rate_limited};
        {ok, _, _, _} -> {error, provider_unavailable};
        {error, _} -> {error, provider_unavailable}
    end.

normalise_item(#{<<"type">> := <<"ad">>}) -> skip;
normalise_item(Item) when is_map(Item) ->
    Formats = map_or_empty(maps:get(<<"media_formats">>, Item, #{})),
    Gif = format_url(Formats, [<<"gif">>, <<"tinygif">>]),
    Preview = format_url(Formats, [<<"tinygif">>, <<"gif">>]),
    Mp4 = format_url(Formats, [<<"tinymp4">>, <<"mp4">>]),
    case Gif of
        <<>> -> skip;
        _ -> #{
            id => pw_util:clean_text(maps:get(<<"id">>, Item, <<>>), 160),
            title => pw_util:clean_text(maps:get(<<"title">>, Item, <<"GIF">>), 160),
            url => Gif,
            preview_url => Preview,
            mp4_url => Mp4,
            width => format_dimension(Formats, [<<"tinygif">>, <<"gif">>], 1),
            height => format_dimension(Formats, [<<"tinygif">>, <<"gif">>], 2)
        }
    end;
normalise_item(_) -> skip.

format_url(Formats, Keys) ->
    Candidates = [maps:get(<<"url">>, map_or_empty(maps:get(Key, Formats, #{})), <<>>) || Key <- Keys],
    case [U || U <- Candidates, is_binary(U), valid_klipy_url(U)] of
        [Url | _] -> Url;
        [] -> <<>>
    end.

format_dimension(Formats, Keys, Index) ->
    Values = [maps:get(<<"dims">>, map_or_empty(maps:get(Key, Formats, #{})), []) || Key <- Keys],
    case [N || Dims <- Values, is_list(Dims), length(Dims) >= Index,
               N <- [lists:nth(Index, Dims)], is_integer(N), N > 0, N =< 4096] of
        [Value | _] -> Value;
        [] -> 0
    end.

map_or_empty(Value) when is_map(Value) -> Value;
map_or_empty(_) -> #{}.

list_or_empty(Value) when is_list(Value) -> Value;
list_or_empty(_) -> [].

valid_klipy_url(Url) when is_binary(Url), byte_size(Url) =< 4096 ->
    %% Provider data is external input. uri_string:parse/1 can throw on malformed
    %% percent escapes/Unicode, so a bad search result must be dropped rather than
    %% taking the GIF endpoint down for the whole request.
    try uri_string:parse(Url) of
        #{scheme := <<"https">>, host := Host} when is_binary(Host) ->
            H = string:lowercase(Host),
            H =:= <<"static.klipy.com">> orelse H =:= <<"cdn.klipy.com">> orelse H =:= <<"media.klipy.com">>;
        #{scheme := "https", host := Host0} when is_list(Host0) ->
            H0 = string:lowercase(Host0),
            lists:member(H0, ["static.klipy.com", "cdn.klipy.com", "media.klipy.com"]);
        _ -> false
    catch
        _:_ -> false
    end;
valid_klipy_url(_) -> false.
