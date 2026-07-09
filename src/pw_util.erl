-module(pw_util).
-export([
    env_int/2, env_bool/2, env_str/2, now_ms/0, random_token/1, sha256_hex/1,
    base64url/1, base64url_decode/1, pbkdf2/2, verify_password/3,
    normalize_username/1, clean_text/2, int/1, bool/1, bin/1, json/1,
    read_json/1, ok_json/2, err_json/3, set_cookie/3, clear_cookie/1, cookie_value/2,
    require_csrf/2, ip/1, security_headers/0, proxied_image/1
]).

env_int(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        V -> case safe_list_to_integer(V) of I when is_integer(I) -> I; _ -> Default end
    end.

env_bool(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "1" -> true;
        "true" -> true;
        "TRUE" -> true;
        "yes" -> true;
        _ -> false
    end.

env_str(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        V -> list_to_binary(V)
    end.

now_ms() -> erlang:system_time(millisecond).

random_token(N) ->
    base64url(crypto:strong_rand_bytes(N)).

base64url(Bin) ->
    B64 = base64:encode(Bin),
    NoPad = binary:replace(B64, <<"=">>, <<>>, [global]),
    binary:replace(binary:replace(NoPad, <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]).

base64url_decode(Bin0) ->
    Bin = binary:replace(binary:replace(Bin0, <<"-">>, <<"+">>, [global]), <<"_">>, <<"/">>, [global]),
    Pad = case byte_size(Bin) rem 4 of
        0 -> <<>>;
        2 -> <<"==">>;
        3 -> <<"=">>;
        _ -> <<>>
    end,
    case safe_base64_decode(<<Bin/binary, Pad/binary>>) of
        Dec when is_binary(Dec) -> Dec;
        _ -> <<>>
    end.

sha256_hex(Bin0) -> hex(crypto:hash(sha256, bin(Bin0))).

pbkdf2(Pass, Salt) ->
    Iter = env_int("PLAINWIRE_PBKDF2_ITERS", 160000),
    Hash = crypto:pbkdf2_hmac(sha256, bin(Pass), bin(Salt), Iter, 32),
    iolist_to_binary([integer_to_binary(Iter), <<"$">>, hex(Hash)]).

verify_password(Pass, Salt, Stored) ->
    Parts = binary:split(bin(Stored), <<"$">>, [global]),
    case Parts of
        [IterBin, Hex] ->
            Iter = int(IterBin),
            Hash = crypto:pbkdf2_hmac(sha256, bin(Pass), bin(Salt), Iter, 32),
            constant_time(hex(Hash), Hex);
        _ -> false
    end.

constant_time(A, B) when byte_size(A) =/= byte_size(B) -> false;
constant_time(A, B) -> constant_time(binary_to_list(A), binary_to_list(B), 0) =:= 0.
constant_time([], [], Acc) -> Acc;
constant_time([A|As], [B|Bs], Acc) -> constant_time(As, Bs, Acc bor (A bxor B)).

hex(Bin) -> << <<(hex_char((X bsr 4) band 15)), (hex_char(X band 15))>> || <<X>> <= Bin >>.
hex_char(N) when N < 10 -> $0 + N;
hex_char(N) -> $a + N - 10.

bin(undefined) -> <<>>;
bin(null) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(T) -> unicode:characters_to_binary(io_lib:format("~p", [T])).

normalize_username(U0) ->
    U1 = string:lowercase(binary_to_list(clean_text(U0, 40))),
    Allowed = [C || C <- U1, (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $-],
    bin(Allowed).

clean_text(T0, Max) ->
    T1 = bin(T0),
    T2 = binary:replace(T1, <<0>>, <<>>, [global]),
    T3 = unicode:characters_to_binary(T2, utf8, utf8),
    T4 = case T3 of Bin when is_binary(Bin) -> Bin; _ -> <<>> end,
    trim_bytes(T4, Max).

trim_bytes(Bin, Max) when byte_size(Bin) =< Max -> Bin;
trim_bytes(Bin, Max) ->
    <<Part:Max/binary, _/binary>> = Bin,
    case unicode:characters_to_binary(Part, utf8, utf8) of
        B when is_binary(B) -> B;
        _ -> trim_bytes(binary:part(Bin, 0, Max - 1), Max - 1)
    end.

int(undefined) -> undefined;
int(null) -> undefined;
int(<<>>) -> undefined;
int(I) when is_integer(I) -> I;
int(B) when is_binary(B) -> case safe_binary_to_integer(B) of I when is_integer(I) -> I; _ -> undefined end;
int(L) when is_list(L) -> case safe_list_to_integer(L) of I when is_integer(I) -> I; _ -> undefined end;
int(_) -> undefined.

bool(true) -> true; bool(false) -> false; bool(1) -> true; bool(0) -> false;
bool(<<"true">>) -> true; bool(<<"1">>) -> true; bool(_) -> false.

json(Term) -> jsx:encode(jsonable(Term)).

jsonable(M) when is_map(M) -> maps:fold(fun(K,V,A) -> A#{key(K)=>jsonable(V)} end, #{}, M);
jsonable(L) when is_list(L) -> [jsonable(X) || X <- L];
jsonable(T) when is_tuple(T) -> jsonable(tuple_to_list(T));
jsonable(true) -> true;
jsonable(false) -> false;
jsonable(undefined) -> null;
jsonable(A) when is_atom(A) -> atom_to_binary(A, utf8);
jsonable(B) when is_binary(B) -> B;
jsonable(I) when is_integer(I) -> I;
jsonable(F) when is_float(F) -> F;
jsonable(X) -> bin(X).

key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_binary(K) -> K;
key(K) -> bin(K).

read_json(Req0) ->
    read_json_body(Req0, <<>>, 1048576).

read_json_body(Req0, Acc, Remaining) when Remaining > 0 ->
    case cowboy_req:read_body(Req0, #{length => Remaining, period => 5000}) of
        {ok, Body, Req1} ->
            decode_json_body(<<Acc/binary, Body/binary>>, Req1);
        {more, Body, Req1} when byte_size(Body) < Remaining ->
            read_json_body(Req1, <<Acc/binary, Body/binary>>, Remaining - byte_size(Body));
        {more, _, Req1} ->
            {error, too_large, Req1};
        Other ->
            {error, Other, Req0}
    end;
read_json_body(Req0, _Acc, _Remaining) ->
    {error, too_large, Req0}.

decode_json_body(Body, Req) ->
    case safe_json_decode(Body) of
        M when is_map(M) -> {ok, M, Req};
        _ -> {error, invalid_json, Req}
    end.

safe_list_to_integer(V) ->
    try list_to_integer(V) catch _:_ -> undefined end.

safe_binary_to_integer(V) ->
    try binary_to_integer(V) catch _:_ -> undefined end.

safe_base64_decode(V) ->
    try base64:decode(V) catch _:_ -> error end.

safe_json_decode(V) ->
    try jsx:decode(V, [return_maps]) catch _:_ -> error end.

ok_json(Req0, Data) ->
    Req = cowboy_req:reply(200, headers(), json(Data), Req0),
    {ok, Req, undefined}.

err_json(Req0, Code, Error) ->
    Req = cowboy_req:reply(Code, headers(), json(#{ok=>false,error=>Error}), Req0),
    {ok, Req, undefined}.

headers() ->
    maps:merge(security_headers(), #{
        <<"content-type">> => <<"application/json; charset=utf-8">>
    }).

security_headers() -> #{
    <<"cache-control">> => <<"no-store">>,
    <<"x-content-type-options">> => <<"nosniff">>,
    <<"x-frame-options">> => <<"SAMEORIGIN">>,
    <<"cross-origin-resource-policy">> => <<"same-origin">>,
    <<"referrer-policy">> => <<"same-origin">>,
    <<"permissions-policy">> => <<"camera=(), microphone=(self), geolocation=()">>
}.

proxied_image(Url0) ->
    Url = bin(Url0),
    case Url of
        <<>> -> <<>>;
        <<"data:", _/binary>> -> Url;
        <<"/api/media/", _/binary>> -> Url;
        <<"http://", _/binary>> -> pw_media:proxy_url(Url);
        <<"https://", _/binary>> -> pw_media:proxy_url(Url);
        _ -> Url
    end.

set_cookie(Req, Name, Value) ->
    Secure = env_bool("COOKIE_SECURE", false),
    cowboy_req:set_resp_cookie(Name, Value, Req, #{
        http_only => true,
        secure => Secure,
        same_site => lax,
        path => <<"/">>,
        max_age => 2592000
    }).

clear_cookie(Req) ->
    cowboy_req:set_resp_cookie(<<"pw_session">>, <<>>, Req, #{http_only=>true, path=><<"/">>, max_age=>0}).

cookie_value(Req, Name) ->
    Cookies = cowboy_req:parse_cookies(Req),
    proplists:get_value(Name, Cookies).

require_csrf(Req, Session) ->
    Csrf = maps:get(csrf, Session, <<>>),
    Header = cowboy_req:header(<<"x-csrf-token">>, Req, <<>>),
    Csrf =/= <<>> andalso Header =:= Csrf.

ip(Req) ->
    case cowboy_req:peer(Req) of
        {{A,B,C,D}, _} -> {A,B,C,D};
        {Addr, _} -> Addr;
        _ -> unknown
    end.
