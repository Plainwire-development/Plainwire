-module(pw_server_template).
-export([normalize/1, preview/1, from_discord/1, discord_code/1, fetch_discord/1]).

%% Imported structures never carry permissions, members, credentials or history.
%% Custom imports start with no member permissions; the owner reviews access.
normalize(null) -> {ok, preset(<<"blank">>), false};
normalize(undefined) -> normalize(null);
normalize(Name) when is_binary(Name) ->
    case lists:member(Name, [<<"blank">>, <<"friends">>, <<"gaming">>, <<"study">>, <<"community">>]) of
        true -> {ok, preset(Name), false};
        false -> {error, invalid_server_template}
    end;
normalize(M) when is_map(M) ->
    try
        Categories = bounded_list(maps:get(<<"categories">>, M, []), 25),
        Channels = bounded_list(maps:get(<<"channels">>, M), 100),
        true = Channels =/= [],
        Roles = bounded_list(maps:get(<<"roles">>, M, []), 50),
        Cats = [#{<<"name">> => label(maps:get(<<"name">>, C), 48)} || C <- Categories],
        Chans = [channel(C, length(Cats)) || C <- Channels],
        Rs = [#{<<"name">> => label(maps:get(<<"name">>, R), 48), <<"color">> => color(maps:get(<<"color">>, R, <<"#99aab5">>))} || R <- Roles],
        unique_names(Cats), unique_names(Chans), unique_names(Rs),
        {ok, #{<<"format">> => <<"plainwire-server-template-v1">>,
               <<"name">> => label(maps:get(<<"name">>, M, <<"Imported server">>), 80),
               <<"categories">> => Cats, <<"channels">> => Chans, <<"roles">> => Rs}, true}
    catch _:_ -> {error, invalid_server_template} end;
normalize(_) -> {error, invalid_server_template}.

preview(#{<<"serialized_source_guild">> := _} = M) -> from_discord(M);
preview(M) ->
    case normalize(M) of
        {ok, Clean, Review} ->
            {ok, #{template => case is_map(M) of true -> Clean; false -> M end,
                   preview => Clean, permissions_review => Review, warnings => review_warnings(Review)}};
        Error -> Error
    end.

bounded_list(L, Max) when is_list(L), length(L) =< Max -> L.
label(B, Max) when is_binary(B), byte_size(B) =< 4096 ->
    Clean = string:trim(pw_util:clean_text(B, Max)),
    true = Clean =/= <<>>,
    Clean.
color(C) when is_binary(C) ->
    true = re:run(C, <<"^#[0-9a-fA-F]{6}$">>, [{capture, none}]) =:= match,
    C.
unique_names(Items) ->
    Names = [string:casefold(maps:get(<<"name">>, Item)) || Item <- Items],
    true = length(lists:usort(Names)) =:= length(Names).
channel(C, Count) ->
    Kind = maps:get(<<"kind">>, C),
    true = Kind =:= <<"text">> orelse Kind =:= <<"voice">>,
    Category = maps:get(<<"category">>, C, null),
    true = Category =:= null orelse (is_integer(Category) andalso Category >= 0 andalso Category < Count),
    Topic = maps:get(<<"topic">>, C, <<>>),
    true = is_binary(Topic) andalso byte_size(Topic) =< 4096,
    Slow = maps:get(<<"slowmode_seconds">>, C, 0),
    true = is_integer(Slow) andalso Slow >= 0 andalso Slow =< 21600,
    #{<<"name">> => label(maps:get(<<"name">>, C), 40), <<"kind">> => Kind,
      <<"category">> => Category, <<"topic">> => pw_util:clean_text(Topic, 1024), <<"slowmode_seconds">> => Slow}.

preset(Name) ->
    {Title, Categories, Channels} = case Name of
        <<"friends">> -> {<<"Friends">>, [<<"Hangout">>], [{<<"general">>, text, 0}, {<<"photos">>, text, 0}, {<<"Lounge">>, voice, 0}]};
        <<"gaming">> -> {<<"Gaming">>, [<<"Lobby">>, <<"Voice">>], [{<<"general">>, text, 0}, {<<"looking-for-group">>, text, 0}, {<<"clips">>, text, 0}, {<<"Lobby">>, voice, 1}, {<<"Team 1">>, voice, 1}, {<<"Team 2">>, voice, 1}]};
        <<"study">> -> {<<"Study group">>, [<<"Study">>], [{<<"general">>, text, 0}, {<<"resources">>, text, 0}, {<<"questions">>, text, 0}, {<<"Study room">>, voice, 0}]};
        <<"community">> -> {<<"Community">>, [<<"Welcome">>, <<"Community">>], [{<<"welcome">>, text, 0}, {<<"rules">>, text, 0}, {<<"general">>, text, 1}, {<<"introductions">>, text, 1}, {<<"Lounge">>, voice, 1}]};
        _ -> {<<"Blank server">>, [], [{<<"general">>, text, null}, {<<"Lounge">>, voice, null}]}
    end,
    #{<<"format">> => <<"plainwire-server-template-v1">>, <<"name">> => Title,
      <<"categories">> => [#{<<"name">> => N} || N <- Categories], <<"roles">> => [],
      <<"channels">> => [#{<<"name">> => N, <<"kind">> => atom_to_binary(K, utf8), <<"category">> => C, <<"topic">> => <<>>, <<"slowmode_seconds">> => 0} || {N,K,C} <- Channels]}.

review_warnings(false) -> [];
review_warnings(true) -> [<<"Imported servers start with member access disabled. Review member and role permissions in Server settings before inviting people. Discord channel overrides are not transferred.">>].

from_discord(M) ->
    try
        Guild = maps:get(<<"serialized_source_guild">>, M),
        All = bounded_list(maps:get(<<"channels">>, Guild, []), 500),
        Sorted = lists:sort(fun(A, B) -> maps:get(<<"position">>, A, 0) =< maps:get(<<"position">>, B, 0) end, All),
        Restricted = [discord_id(maps:get(<<"id">>, C)) || C <- All, maps:get(<<"permission_overwrites">>, C, []) =/= []],
        Safe = [C || C <- Sorted, not lists:member(discord_id(maps:get(<<"id">>, C)), Restricted),
                    not lists:member(discord_id(maps:get(<<"parent_id">>, C, null)), Restricted)],
        Cats = unique_labels([#{<<"name">> => maps:get(<<"name">>, C)} || C <- Safe, maps:get(<<"type">>, C) =:= 4], 48),
        CatIds = [discord_id(maps:get(<<"id">>, C)) || C <- Safe, maps:get(<<"type">>, C) =:= 4],
        Index = maps:from_list(lists:zip(CatIds, lists:seq(0, length(CatIds)-1))),
        RawChannels = [#{<<"name">> => maps:get(<<"name">>, C),
                         <<"kind">> => case maps:get(<<"type">>, C) of 2 -> <<"voice">>; _ -> <<"text">> end,
                         <<"category">> => maps:get(discord_id(maps:get(<<"parent_id">>, C, null)), Index, null),
                         <<"topic">> => case maps:get(<<"topic">>, C, <<>>) of null -> <<>>; T -> T end,
                         <<"slowmode_seconds">> => maps:get(<<"rate_limit_per_user">>, C, 0)}
                       || C <- Safe, lists:member(maps:get(<<"type">>, C), [0,2])],
        RawRoles = bounded_list(maps:get(<<"roles">>, Guild, []), 250),
        Roles = unique_labels([#{<<"name">> => maps:get(<<"name">>, R), <<"color">> => discord_color(maps:get(<<"color">>, R, 0))}
                              || R <- RawRoles, maps:get(<<"name">>, R) =/= <<"@everyone">>, maps:get(<<"managed">>, R, false) =:= false], 48),
        Raw = #{<<"name">> => maps:get(<<"name">>, Guild, <<"Imported Discord server">>), <<"categories">> => Cats,
                <<"channels">> => unique_labels(RawChannels, 40), <<"roles">> => Roles},
        {ok, Clean, true} = normalize(Raw),
        Skipped = length(All) - length(Cats) - length(RawChannels),
        Warnings = review_warnings(true) ++ case Skipped of
            0 -> [];
            _ -> [<<(integer_to_binary(Skipped))/binary, " restricted or unsupported channels/categories were omitted. Messages, members, integrations and credentials are not imported.">>]
        end,
        {ok, #{template => Clean, preview => Clean, permissions_review => true, warnings => Warnings}}
    catch _:_ -> {error, invalid_server_template} end.

discord_id(null) -> null;
discord_id(I) when is_integer(I), I >= 0 -> integer_to_binary(I);
discord_id(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 32 -> B.
discord_color(0) -> <<"#99aab5">>;
discord_color(I) when is_integer(I), I >= 0, I =< 16#ffffff ->
    iolist_to_binary(io_lib:format("#~6.16.0b", [I])).

unique_labels(Items, Max) ->
    {Result, _} = lists:foldl(fun(Item, {Acc, Seen}) ->
        Base = label(maps:get(<<"name">>, Item), Max),
        Name = available_name(Base, Max, Seen, 1),
        {[Item#{<<"name">> => Name} | Acc], sets:add_element(string:casefold(Name), Seen)}
    end, {[], sets:new()}, Items),
    lists:reverse(Result).
available_name(Base, Max, Seen, N) ->
    Suffix = case N of 1 -> <<>>; _ -> <<"-", (integer_to_binary(N))/binary>> end,
    Name = <<(pw_util:clean_text(Base, Max-byte_size(Suffix)))/binary, Suffix/binary>>,
    case sets:is_element(string:casefold(Name), Seen) of
        false -> Name;
        true -> available_name(Base, Max, Seen, N+1)
    end.

discord_code(Input) when is_binary(Input), byte_size(Input) =< 256 ->
    Trimmed = string:trim(Input),
    Code = case Trimmed of
        <<"https://discord.new/", Rest/binary>> -> Rest;
        <<"https://discord.com/template/", Rest/binary>> -> Rest;
        _ -> Trimmed
    end,
    case re:run(Code, <<"^[A-Za-z0-9_-]{2,64}$">>, [{capture, none}]) of
        match -> {ok, Code};
        _ -> {error, invalid_discord_template}
    end;
discord_code(_) -> {error, invalid_discord_template}.

fetch_discord(Input) ->
    case discord_code(Input) of
        {ok, Code} ->
            Url = <<"https://discord.com/api/v10/guilds/templates/", Code/binary>>,
            case pw_outbound_url:resolve_allowed(Url) of
                {ok, #{address := Address}} ->
                    case pw_http_fetch:get_pinned(Url, Address, 1048576, #{accept => <<"application/json">>}) of
                        {ok, 200, _, Body} ->
                            try from_discord(jsx:decode(Body, [return_maps])) catch _:_ -> {error, invalid_server_template} end;
                        {ok, 404, _, _} -> {error, template_not_found};
                        {ok, 429, _, _} -> {error, template_rate_limited};
                        _ -> {error, template_unavailable}
                    end;
                _ -> {error, template_unavailable}
            end;
        Error -> Error
    end.
