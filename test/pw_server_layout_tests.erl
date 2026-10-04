-module(pw_server_layout_tests).
-include_lib("eunit/include/eunit.hrl").

layout_validation_test() ->
    Folder = folder([1,2]),
    ?assertEqual({ok, [Folder, #{<<"server_id">> => 3}]}, pw_server_layout:validate([Folder, #{<<"server_id">> => 3}], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([Folder, #{<<"server_id">> => 1}], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([folder([1,99])], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([folder([1,1])], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([folder([])], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([Folder#{<<"id">> => <<"../evil">>}], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([Folder#{<<"collapsed">> => <<"false">>}], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([Folder#{<<"name">> => <<" ">>}], [1,2,3])),
    ?assertEqual({error, invalid_server_layout}, pw_server_layout:validate([Folder#{<<"user_id">> => 10}], [1,2,3])).

membership_reconciliation_test() ->
    ?assertEqual([folder([2]), #{<<"server_id">> => 3}], pw_server_layout:reconcile([folder([1,2]), #{<<"server_id">> => 4}], [2,3])),
    ?assertEqual([#{<<"server_id">> => 3}], pw_server_layout:reconcile([folder([1,2])], [3])).

folder(Ids) -> #{<<"id">> => <<"folder-1">>, <<"name">> => <<"Friends">>, <<"server_ids">> => Ids, <<"collapsed">> => false}.
