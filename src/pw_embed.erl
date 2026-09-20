-module(pw_embed).
-export([fetch/1]).
-ifdef(TEST).
-export([parse_og/2, page_meta/3]).
-endif.

%% Only a prefix is read: metadata sits in <head>, and many pages are megabytes.
-define(MAX_BYTES, 524288).
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
            %% redirects are followed there, each hop re-checked for SSRF.
            case pw_media:fetch_page(Url, ?MAX_BYTES) of
                {ok, Type, Body} ->
                    case page_meta(Url, Type, Body) of
                        {ok, Meta} ->
                            ets:insert(pw_media_cache, {Key, jsx:encode(Meta), <<"application/json">>, Now + ?TTL_MS}),
                            {ok, Meta};
                        Err ->
                            Err
                    end;
                Err ->
                    Err
            end
    end.

page_meta(Url, <<"text/html">>, Body) -> {ok, parse_og(Body, Url)};
page_meta(Url, <<"application/xhtml+xml">>, Body) -> {ok, parse_og(Body, Url)};
page_meta(Url, <<"image/gif">>, _) -> {ok, image_meta(Url, gif)};
page_meta(Url, Type, _) when Type =:= <<"image/png">>; Type =:= <<"image/jpeg">>;
                             Type =:= <<"image/webp">>; Type =:= <<"image/avif">> ->
    {ok, image_meta(Url, image)};
page_meta(Url, <<"application/pdf">>, _) -> {ok, document_meta(Url, <<"PDF document">>, <<"pdf">>)};
page_meta(Url, <<"text/plain">>, _) -> {ok, document_meta(Url, <<"Text document">>, <<"text">>)};
page_meta(Url, <<"application/json">>, _) -> {ok, document_meta(Url, <<"JSON document">>, <<"code">>)};
page_meta(_, _, _) -> {error, unsupported_type}.

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

document_meta(Url, FallbackTitle, Kind) ->
    #{
        <<"url">> => Url,
        <<"title">> => pick(url_filename(Url), FallbackTitle, FallbackTitle),
        <<"description">> => FallbackTitle,
        <<"image">> => <<>>,
        <<"favicon">> => <<>>,
        <<"site_name">> => host_of(Url),
        <<"kind">> => Kind
    }.

parse_og(Html, Url) ->
    Meta = meta_tags(Html),
    Get = fun(Keys) -> first_value(Keys, Meta) end,
    Title = text(Get([<<"og:title">>, <<"twitter:title">>]), 300),
    Desc = text(Get([<<"og:description">>, <<"twitter:description">>, <<"description">>]), 1000),
    Image = text(Get([<<"og:image:secure_url">>, <<"og:image">>, <<"og:image:url">>,
                      <<"twitter:image">>, <<"twitter:image:src">>]), 2048),
    Site = text(Get([<<"og:site_name">>, <<"application-name">>]), 200),
    PageKind = text(Get([<<"og:type">>]), 40),
    ProxiedImage = case absolutize(Image, Url) of
        <<"http://", _/binary>> = Abs -> pw_media:proxy_url(Abs);
        <<"https://", _/binary>> = Abs -> pw_media:proxy_url(Abs);
        _ -> <<>>
    end,
    ProxiedIcon = case absolutize(icon_href(Html), Url) of
        <<"http://", _/binary>> = IconAbs -> pw_media:proxy_url(IconAbs);
        <<"https://", _/binary>> = IconAbs -> pw_media:proxy_url(IconAbs);
        _ -> <<>>
    end,
    #{
        <<"url">> => Url,
        <<"title">> => pick(Title, text(title_tag(Html), 300), host_of(Url)),
        <<"description">> => Desc,
        <<"image">> => ProxiedImage,
        <<"favicon">> => ProxiedIcon,
        <<"site_name">> => pick(Site, host_of(Url), <<>>),
        <<"kind">> => pick(PageKind, <<"link">>, <<"link">>)
    }.

%% Decoded per value rather than per page, so one stray byte elsewhere cannot turn
%% a UTF-8 title into Latin-1 mojibake. An attribute value is complete, so anything
%% that is not valid UTF-8 is treated as Latin-1.
to_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Utf8 when is_binary(Utf8) -> Utf8;
        _ ->
            case unicode:characters_to_binary(Bin, latin1, utf8) of
                Latin when is_binary(Latin) -> Latin;
                _ -> <<>>
            end
    end.

%% Attribute order and quoting vary: content may come before property, values may
%% be single-quoted, and names differ in case.
meta_tags(Html) ->
    Head = head_html(Html),
    case re:run(Head, <<"<meta\\s[^>]*>">>, [global, caseless, {capture, first, binary}]) of
        {match, Tags} -> lists:reverse(lists:foldl(fun([Tag], Acc) -> add_meta(attrs(Tag), Acc) end, [], Tags));
        nomatch -> []
    end.

head_html(Html) ->
    case re:run(Html, <<"</head\\s*>">>, [caseless, {capture, first, index}]) of
        {match, [{Pos, _}]} -> binary:part(Html, 0, Pos);
        nomatch -> Html
    end.

icon_href(Html) ->
    Head = head_html(Html),
    case re:run(Head, <<"<link\\s[^>]*>">>, [global, caseless, {capture, first, binary}]) of
        {match, Tags} -> first_icon_href(Tags);
        nomatch -> <<>>
    end.

first_icon_href([]) -> <<>>;
first_icon_href([[Tag] | Rest]) ->
    Attrs = attrs(Tag),
    Rel = string:lowercase(first_value([<<"rel">>], Attrs)),
    Href = first_value([<<"href">>], Attrs),
    case Href =/= <<>> andalso re:run(Rel, <<"(?:^|\\s)(?:shortcut\\s+)?icon(?:\\s|$)|(?:^|\\s)apple-touch-icon(?:\\s|$)">>, [{capture, none}]) =:= match of
        true -> Href;
        false -> first_icon_href(Rest)
    end.

add_meta(Attrs, Acc) ->
    Key = first_value([<<"property">>, <<"name">>, <<"itemprop">>], Attrs),
    case {Key, lists:keyfind(<<"content">>, 1, Attrs)} of
        {<<>>, _} -> Acc;
        {_, {_, Content}} -> [{string:lowercase(Key), Content} | Acc];
        _ -> Acc
    end.

attrs(Tag) ->
    Pattern = <<"([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))">>,
    case re:run(Tag, Pattern, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> [{string:lowercase(Name), first_nonempty(Values)} || [Name | Values] <- Matches];
        nomatch -> []
    end.

first_nonempty(Values) ->
    case [V || V <- Values, V =/= <<>>] of
        [V | _] -> V;
        [] -> <<>>
    end.

first_value([], _) -> <<>>;
first_value([Key | Rest], Pairs) ->
    case [V || {K, V} <- Pairs, K =:= Key, V =/= <<>>] of
        [V | _] -> V;
        [] -> first_value(Rest, Pairs)
    end.

title_tag(Html) ->
    case re:run(Html, <<"<title[^>]*>([^<]*)</title">>, [{capture, [1], binary}, caseless]) of
        {match, [T]} -> T;
        _ -> <<>>
    end.

text(Value, Max) ->
    Collapsed = re:replace(unescape(to_utf8(Value)), <<"\\s+">>, <<" ">>, [global, {return, binary}]),
    pw_util:clean_text(string:trim(Collapsed), Max).

unescape(Bin) -> unescape(Bin, <<>>).

unescape(<<>>, Acc) -> Acc;
unescape(<<"&", Rest/binary>>, Acc) ->
    case binary:match(Rest, <<";">>) of
        {Pos, 1} when Pos > 0, Pos =< 10 ->
            <<Name:Pos/binary, ";", After/binary>> = Rest,
            case entity(Name) of
                undefined -> unescape(Rest, <<Acc/binary, "&">>);
                Char -> unescape(After, <<Acc/binary, Char/binary>>)
            end;
        _ ->
            unescape(Rest, <<Acc/binary, "&">>)
    end;
unescape(<<C, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, C>>).

entity(<<"amp">>) -> <<"&">>;
entity(<<"lt">>) -> <<"<">>;
entity(<<"gt">>) -> <<">">>;
entity(<<"quot">>) -> <<"\"">>;
entity(<<"apos">>) -> <<"'">>;
entity(<<"nbsp">>) -> <<" ">>;
entity(<<"#", X, Hex/binary>>) when X =:= $x; X =:= $X -> codepoint(Hex, 16);
entity(<<"#", Dec/binary>>) -> codepoint(Dec, 10);
entity(_) -> undefined.

codepoint(Digits, Base) ->
    try binary_to_integer(Digits, Base) of
        N when N > 0 -> <<N/utf8>>;
        _ -> undefined
    catch _:_ -> undefined
    end.

host_of(Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{host := H} -> pw_util:bin(H);
        _ -> <<>>
    end.

url_filename(Url) ->
    try uri_string:parse(binary_to_list(Url)) of
        #{path := Path} ->
            Name0 = pw_util:bin(filename:basename(Path)),
            Name = try uri_string:percent_decode(Name0) of
                Decoded when is_binary(Decoded) -> Decoded;
                _ -> Name0
            catch _:_ -> Name0
            end,
            text(Name, 300);
        _ -> <<>>
    catch _:_ -> <<>>
    end.

pick(<<>>, Alt, _Def) when byte_size(Alt) > 0 -> Alt;
pick(<<>>, _, Def) -> Def;
pick(V, _, _) -> V.

%% og:image may be absolute, protocol-relative ("//cdn/..."), or relative.
absolutize(<<>>, _) -> <<>>;
absolutize(Ref, Base) ->
    try uri_string:resolve(Ref, Base) of
        Resolved when is_binary(Resolved) -> Resolved;
        _ -> <<>>
    catch _:_ -> <<>>
    end.
