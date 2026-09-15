-module(pw_util_tests).

-include_lib("eunit/include/eunit.hrl").

base64url_round_trip_test() ->
    Bin = <<0, 1, 2, 250, 251, 252, 253, 254, 255>>,
    Enc = pw_util:base64url(Bin),
    ?assertEqual(nomatch, binary:match(Enc, <<"=">>)),
    ?assertEqual(nomatch, binary:match(Enc, <<"+">>)),
    ?assertEqual(nomatch, binary:match(Enc, <<"/">>)),
    ?assertEqual(Bin, pw_util:base64url_decode(Enc)).

normalize_username_test() ->
    ?assertEqual(<<"alice_123-ok">>, pw_util:normalize_username(<<" Alice_123-OK!! ">>)),
    ?assertEqual(<<"">>, pw_util:normalize_username(<<"!@#$">>)).

clean_text_strips_nul_and_keeps_valid_utf8_test() ->
    ?assertEqual(<<"abcdef">>, pw_util:clean_text(<<"abc", 0, "def">>, 20)),
    Clean = pw_util:clean_text(<<"ååå">>, 5),
    ?assert(is_binary(Clean)),
    ?assert(is_binary(unicode:characters_to_binary(Clean, utf8, utf8))).

safe_profile_image_data_urls_test() ->
    ?assert(pw_util:safe_image_data_url(<<"data:image/gif;base64,R0lGODlh">>)),
    ?assert(pw_util:safe_image_data_url(<<"data:image/png;base64,iVBORw0KGgo=">>)),
    ?assertNot(pw_util:safe_image_data_url(<<"data:image/svg+xml;base64,PHN2Zz4=">>)),
    ?assertNot(pw_util:safe_image_data_url(<<"data:text/html;base64,PGgxPg==">>)).

malformed_profile_data_avatar_maps_to_fallback_test() ->
    ?assertEqual(<<>>, pw_util:proxied_image(<<"data:image/svg+xml;base64,PHN2Zz4=">>)),
    ?assertEqual(<<>>, pw_util:proxied_image(<<"data:image/png;base64,definitely-broken">>)).


env_bool_uses_default_for_invalid_values_test() ->
    with_env("PLAINWIRE_TEST_BOOL", "definitely-not-a-bool", fun() ->
        ?assertEqual(true, pw_util:env_bool("PLAINWIRE_TEST_BOOL", true)),
        ?assertEqual(false, pw_util:env_bool("PLAINWIRE_TEST_BOOL", false))
    end),
    with_env("PLAINWIRE_TEST_BOOL", "OFF", fun() ->
        ?assertEqual(false, pw_util:env_bool("PLAINWIRE_TEST_BOOL", true))
    end),
    with_env("PLAINWIRE_TEST_BOOL", " on ", fun() ->
        ?assertEqual(true, pw_util:env_bool("PLAINWIRE_TEST_BOOL", false))
    end).

password_hash_iteration_floor_test() ->
    with_env("PLAINWIRE_PBKDF2_ITERS", "-500", fun() ->
        Hash = pw_util:pbkdf2(<<"password">>, <<"salt">>),
        [IterBin, _] = binary:split(Hash, <<"$">>, [global]),
        ?assertEqual(10000, binary_to_integer(IterBin))
    end).

password_hash_verify_test() ->
    with_env("PLAINWIRE_PBKDF2_ITERS", "1", fun() ->
        Salt = <<"salt">>,
        Hash = pw_util:pbkdf2(<<"password">>, Salt),
        ?assert(pw_util:verify_password(<<"password">>, Salt, Hash)),
        ?assertNot(pw_util:verify_password(<<"wrong">>, Salt, Hash))
    end).

password_hash_upgrade_detection_test() ->
    with_env("PLAINWIRE_PBKDF2_ITERS", "200000", fun() ->
        ?assert(pw_util:password_needs_rehash(<<"160000$0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>)),
        ?assertNot(pw_util:password_needs_rehash(<<"200000$0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>)),
        ?assertNot(pw_util:password_needs_rehash(<<"300000$0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>)),
        ?assert(pw_util:password_needs_rehash(<<"broken">>))
    end).

with_env(Name, Value, Fun) ->
    Old = os:getenv(Name),
    os:putenv(Name, Value),
    try Fun()
    after
        case Old of
            false -> os:unsetenv(Name);
            _ -> os:putenv(Name, Old)
        end
    end.
