-module(pw_mention).

-export([tokens/1, resolve/2, strip_fences/1]).

tokens(Body0) ->
    Body = strip_fences(Body0),
    case re:run(Body, <<"(?:^|[^A-Za-z0-9_.-])@([A-Za-z0-9_-]+)">>,
                 [global, caseless, {capture, [1], binary}]) of
        {match, Groups} ->
            lists:usort([pw_util:normalize_username(M) || [M] <- Groups]);
        nomatch ->
            []
    end.

resolve(Body, Users) ->
    Mentioned = lists:foldl(fun(T, Acc) -> maps:put(T, true, Acc) end, #{}, tokens(Body)),
    [Uid || {Uid, Username} <- Users, maps:is_key(pw_util:normalize_username(Username), Mentioned)].

strip_fences(Body) ->
    parts(binary:split(Body, <<"```">>, [global]), true, <<>>).

parts([Last], _Outside, Acc) ->
    <<Acc/binary, Last/binary>>;
parts([Piece, Next | Rest], Outside, Acc) ->
    case Outside of
        true -> parts([Next | Rest], false, <<Acc/binary, Piece/binary>>);
        false -> parts([Next | Rest], true, Acc)
    end.
