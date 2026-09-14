-module(pw_mention_tests).
-include_lib("eunit/include/eunit.hrl").

simple_mention_is_found_test() ->
    ?assertEqual([<<"bob">>], pw_mention:tokens(<<"hey @bob how are you">>)),
    ?assertEqual([<<"bob">>], pw_mention:tokens(<<"@bob start of line">>)).

matching_is_case_insensitive_test() ->
    ?assertEqual([<<"bob">>], pw_mention:tokens(<<"ping @Bob, ok?">>)).

multiple_mentions_are_deduped_test() ->
    ?assertEqual([<<"alice">>, <<"bob">>], pw_mention:tokens(<<"@alice and @Bob then @ALICE">>)).

mention_inside_a_word_is_ignored_test() ->
    ?assertEqual([], pw_mention:tokens(<<"email me at test@bob.example">>)),
    ?assertEqual([], pw_mention:tokens(<<"check v@bob for the version">>)).

mention_inside_fenced_code_is_ignored_test() ->
    Body = <<"here's the thing\n```\nrun with @alice now\n```\nafter">>,
    ?assertEqual([], pw_mention:tokens(Body)),
    ?assertEqual([<<"alice">>], pw_mention:tokens(<<"@alice before\n```\n@bob\n```\nafter">>)).

empty_body_has_no_mentions_test() ->
    ?assertEqual([], pw_mention:tokens(<<>>)),
    ?assertEqual([], pw_mention:tokens(<<"just text">>)).

username_charset_matches_normalize_test() ->
    ?assertEqual([<<"a_b-c9">>], pw_mention:tokens(<<"hello @A_b-C9!">>)),
    ?assertEqual([<<"bob_">>], pw_mention:tokens(<<"@bob_">>)).

resolve_maps_tokens_to_users_test() ->
    Users = [{10, <<"bob">>}, {20, <<"alice">>}, {30, <<"carol">>}],
    ?assertEqual([10], pw_mention:resolve(<<"@bob on it">>, Users)),
    ?assertEqual([10, 20], pw_mention:resolve(<<"@Bob and @ALICE!">>, Users)),
    ?assertEqual([30], pw_mention:resolve(<<"the report from @carol">>, Users)).

resolve_skips_users_not_mentioned_test() ->
    Users = [{10, <<"bob">>}, {20, <<"alice">>}],
    ?assertEqual([], pw_mention:resolve(<<"nobody here">>, Users)).