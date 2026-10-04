-module(pw_server_template_tests).
-include_lib("eunit/include/eunit.hrl").

preset_and_permission_safety_test() ->
    [?assertMatch({ok, _, false}, pw_server_template:normalize(Name)) || Name <- [null, <<"blank">>, <<"friends">>, <<"gaming">>, <<"study">>, <<"community">>]],
    ?assertEqual({error, invalid_server_template}, pw_server_template:normalize(<<"unknown">>)),
    Import = (template())#{<<"permissions_review">> => false, <<"default_permissions">> => 1073741824,
        <<"roles">> => [#{<<"name">> => <<"Staff">>, <<"permissions">> => 1073741824}]},
    {ok, Clean, true} = pw_server_template:normalize(Import),
    ?assertNot(maps:is_key(<<"default_permissions">>, Clean)),
    [Role] = maps:get(<<"roles">>, Clean),
    ?assertNot(maps:is_key(<<"permissions">>, Role)),
    ?assertMatch({ok, #{permissions_review := true}}, pw_server_template:preview(Import)).

template_validation_test() ->
    Base = template(),
    [C] = maps:get(<<"channels">>, Base),
    Bad = [Base#{<<"channels">> => []}, Base#{<<"channels">> => lists:duplicate(101, C)},
           Base#{<<"channels">> => [C, C#{<<"name">> => <<"GENERAL">>}]},
           Base#{<<"channels">> => [C#{<<"kind">> => <<"forum">>}]},
           Base#{<<"channels">> => [C#{<<"category">> => 0}]},
           Base#{<<"channels">> => [C#{<<"category">> => -1}]},
           Base#{<<"channels">> => [C#{<<"slowmode_seconds">> => 21601}]},
           Base#{<<"roles">> => [#{<<"name">> => <<"role">>, <<"color">> => <<"url(javascript:x)">>}]},
           Base#{<<"categories">> => [#{<<"name">> => <<" ">>}]},
           Base#{<<"channels">> => [C#{<<"name">> => #{<<"unexpected">> => true}}]}],
    [?assertEqual({error, invalid_server_template}, pw_server_template:normalize(M)) || M <- Bad].

discord_restricted_channels_and_roles_test() ->
    Override = [#{<<"id">> => 0, <<"deny">> => <<"1024">>, <<"allow">> => <<"0">>}],
    Channels = [dc(1, <<"Staff">>, 4, null, Override), dc(2, <<"secrets">>, 0, 1, []),
                dc(3, <<"Public">>, 4, null, []), dc(4, <<"general">>, 0, 3, []),
                dc(5, <<"general">>, 2, 3, []), dc(6, <<"restricted">>, 0, 3, Override),
                dc(7, <<"forum">>, 15, 3, [])],
    Source = #{<<"serialized_source_guild">> => #{<<"name">> => <<"Discord import">>, <<"channels">> => Channels,
        <<"roles">> => [#{<<"name">> => <<"@everyone">>}, #{<<"name">> => <<"Admin">>, <<"permissions">> => <<"8">>, <<"color">> => 16#ff0000},
                        #{<<"name">> => <<"Integration">>, <<"managed">> => true}]}},
    {ok, #{template := Clean, permissions_review := true, warnings := Warnings}} = pw_server_template:from_discord(Source),
    ?assertEqual([#{<<"name">> => <<"Public">>}], maps:get(<<"categories">>, Clean)),
    [First, Second] = maps:get(<<"channels">>, Clean),
    ?assertEqual(<<"general">>, maps:get(<<"name">>, First)),
    ?assertEqual(<<"general-2">>, maps:get(<<"name">>, Second)),
    ?assertEqual(0, maps:get(<<"category">>, First)),
    ?assertEqual([#{<<"name">> => <<"Admin">>, <<"color">> => <<"#ff0000">>}], maps:get(<<"roles">>, Clean)),
    ?assertEqual(2, length(Warnings)).

discord_url_policy_test() ->
    [?assertEqual({ok, <<"hgM48av5Q69A">>}, pw_server_template:discord_code(C)) || C <- [<<"hgM48av5Q69A">>, <<"https://discord.new/hgM48av5Q69A">>, <<"https://discord.com/template/hgM48av5Q69A">>]],
    [?assertEqual({error, invalid_discord_template}, pw_server_template:discord_code(C)) || C <-
        [<<"https://127.0.0.1/private">>, <<"https://discord.com@127.0.0.1/x">>, <<"https://discord.new/../../users/@me">>,
         <<"https://discord.new/a?redirect=https://localhost">>, <<"https://discord.new/a#x">>, <<"https://discord.new/a/">>,
         <<"javascript:alert(1)">>, <<"//discord.new/ab">>, <<"ab%2fcd">>, <<"ab\ncd">>, null]].

template() -> #{<<"channels">> => [#{<<"name">> => <<"general">>, <<"kind">> => <<"text">>}] }.
dc(Id, Name, Type, Parent, Overrides) -> #{<<"id">> => Id, <<"name">> => Name, <<"type">> => Type, <<"parent_id">> => Parent, <<"permission_overwrites">> => Overrides, <<"position">> => Id}.
