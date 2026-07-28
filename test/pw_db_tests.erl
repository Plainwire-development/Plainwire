-module(pw_db_tests).
-include_lib("eunit/include/eunit.hrl").

extract_file_ids_basic_test() ->
    ?assertEqual([], pw_db:extract_file_ids(<<>>)),
    ?assertEqual([], pw_db:extract_file_ids(<<"hello world">>)).

extract_file_ids_single_test() ->
    Id = <<"abcdefghijklmnopqrstuvwxyz1234">>,
    Body = <<"check out /api/files/", Id/binary, "/download">>,
    ?assertEqual([Id], pw_db:extract_file_ids(Body)).

extract_file_ids_multiple_test() ->
    Id1 = <<"abcdefghijklmnopqrstuvwx">>,
    Id2 = <<"ABCDEFGHIJKLMNOPQRSTUVWX">>,
    Id3 = <<"0123456789abcdefghijklmnop">>,
    Body = <<"/api/files/", Id1/binary, " /api/files/", Id2/binary, " /api/files/", Id3/binary>>,
    Result = pw_db:extract_file_ids(Body),
    ?assertEqual(3, length(Result)),
    ?assert(lists:member(Id1, Result)),
    ?assert(lists:member(Id2, Result)),
    ?assert(lists:member(Id3, Result)).

extract_file_ids_rejects_short_id_test() ->
    ?assertEqual([], pw_db:extract_file_ids(<<"/api/files/short">>)).

extract_file_ids_rejects_empty_after_prefix_test() ->
    ?assertEqual([], pw_db:extract_file_ids(<<"/api/files/">>)).

extract_file_ids_dedup_test() ->
    Id = <<"abcdefghijklmnopqrstuvwx">>,
    Body = <<"/api/files/", Id/binary, " /api/files/", Id/binary>>,
    Result = pw_db:extract_file_ids(Body),
    ?assertEqual([Id], Result).
