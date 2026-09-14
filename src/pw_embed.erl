-module(pw_embed).
-export([fetch/1]).

-define(MAX_BYTES, 262144).
-define(TTL_MS, 900000).

fetch(Url0) ->
    Url = pw_util:bin(Url0),
    case pw_media:validate_url(Url) of
        ok ->
            case image_kind(Url) of
                none ->
                    fetch_page(Url);
                Kind ->
                    {ok, image_meta(Url, Kind)}
            end;
        Err ->
            Err
    end.

fetch_page(Url) ->
    Key = {embed, pw_util:sha256_hex(Url)},
    Now = pw_util:now_ms(),
    case ets:lookup(pw_media_cache, Key) of
        [{Key, Json, _, Expires}] when Expires > Now ->
            {ok, jsx:decode(Json, [return_maps])};
        _ ->
            case http_get(Url) of
                {ok, Html} ->
                    Meta = parse_og(Html, Url),
                    Json = jsx:encode(Meta),
                    ets:insert(pw_media_cache, {Key, Json, <<"application/json">>, Now + ?TTL_MS}),
                    {ok, Meta};
                Err ->
                    Err
            end
    end.

image_kind(Url) ->
    try uri_string:parse(binary_to_list(Url)) of
        #{path := Path} ->
            case string:lowercase(filename:extension(Path)) of
                ".gif" -> gif;
                ".png" -> image;
                ".jpg" -> image;
                ".jpeg" -> image;
                ".webp" -> image;
                ".avif" -> image;
                _ -> none
            end;
        _ -> none
    catch _:_ -> none
    end.

image_meta(Url, Kind) ->
    #{
        <<"url">> => Url,
        <<"title">> => case Kind of gif -> <<"Animated image">>; _ -> <<"Image">> end,
        <<"description">> => <<>>,
        <<"image">> => pw_media:proxy_url(Url),
        <<"site_name">> => host_of(Url),
        <<"kind">> => atom_to_binary(Kind, utf8)
    }.

http_get(Url) ->
    case pw_http_fetch:get(Url, ?MAX_BYTES) of
        {ok, Code, _, Body} when Code >= 200, Code < 300 -> {ok, Body};
        {ok, Code, _, _} when Code >= 300, Code < 400 ->
            {error, blocked_url};
        {ok, Code, _, _} ->
            {error, {http, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

parse_og(Html, Url) ->
    Title = bounded(meta(Html, <<"og:title">>), 300),
    Desc = bounded(meta(Html, <<"og:description">>), 1000),
    Image = bounded(meta(Html, <<"og:image">>), 2048),
    Site = bounded(meta(Html, <<"og:site_name">>), 200),
    AbsoluteImage = absolutize(Image, Url),
    ProxiedImage = case AbsoluteImage of
        <<>> -> <<>>;
        _ -> pw_media:proxy_url(AbsoluteImage)
    end,
    #{
        <<"url">> => Url,
        <<"title">> => pick(Title, bounded(title_tag(Html), 300), host_of(Url)),
        <<"description">> => pick(Desc, bounded(meta(Html, <<"description">>), 1000), <<>>),
        <<"image">> => ProxiedImage,
        <<"site_name">> => pick(Site, host_of(Url), <<>>)
    }.

bounded(Value, Max) -> pw_util:clean_text(Value, Max).

meta(Html, Prop) ->
    Pats = [
        <<"property=\"", Prop/binary, "\" content=\"">>,
        <<"name=\"", Prop/binary, "\" content=\"">>,
        <<"content=\"", Prop/binary, "\" property=\"">>
    ],
    find_meta(Html, Pats).

find_meta(_, []) -> <<>>;
find_meta(Html, [Pat | Rest]) ->
    case binary:match(Html, Pat) of
        {Start, Len} ->
            After = binary:part(Html, Start + Len, byte_size(Html) - Start - Len),
            take_attr(After);
        nomatch ->
            find_meta(Html, Rest)
    end.

take_attr(Bin) ->
    case binary:match(Bin, <<"\"">>) of
        {End, _} -> binary:part(Bin, 0, End);
        nomatch -> <<>>
    end.

title_tag(Html) ->
    case re:run(Html, <<"<title[^>]*>([^<]+)</title">>, [{capture, [1], binary}, caseless]) of
        {match, [T]} -> html_unescape(T);
        _ -> <<>>
    end.

html_unescape(Bin) ->
    Bin1 = binary:replace(Bin, <<"&amp;">>, <<"&">>, [global]),
    Bin2 = binary:replace(Bin1, <<"&lt;">>, <<"<">>, [global]),
    binary:replace(Bin2, <<"&gt;">>, <<">">>, [global]).

host_of(Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{host := H} -> pw_util:bin(H);
        _ -> <<>>
    end.

pick(<<>>, Alt, _Def) when byte_size(Alt) > 0 -> Alt;
pick(<<>>, _, Def) -> Def;
pick(V, _, _) -> V.

absolutize(<<>>, _) -> <<>>;
absolutize(<<"http://", _/binary>> = U, _) -> U;
absolutize(<<"https://", _/binary>> = U, _) -> U;
absolutize(<<"/", _/binary>> = Path, Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{scheme := S, host := H} ->
            PortPart = case uri_string:parse(binary_to_list(Url)) of
                #{port := P} when is_integer(P), P =/= 443, P =/= 80 -> <<":", (integer_to_binary(P))/binary>>;
                _ -> <<>>
            end,
            <<(pw_util:bin(S))/binary, "://", (pw_util:bin(H))/binary, PortPart/binary, Path/binary>>;
        _ ->
            Path
    end;
absolutize(Rel, Url) -> absolutize(<<"/", Rel/binary>>, Url).
