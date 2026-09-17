-module(pw_storage_sanitize_tests).
-include_lib("eunit/include/eunit.hrl").

nested_secrets_are_removed_test() ->
    Input = #{type => <<"webhook.executed">>,
              nested => #{authorization => <<"Bearer nope">>,
                          bot_token => <<"nope">>,
                          safe => <<"kept">>,
                          deeper => [#{client_secret => <<"nope">>, value => 42}] }},
    Safe = pw_storage_sanitize:without_secrets(Input),
    Nested = maps:get(nested, Safe),
    ?assertEqual(false, maps:is_key(authorization, Nested)),
    ?assertEqual(false, maps:is_key(bot_token, Nested)),
    ?assertEqual(<<"kept">>, maps:get(safe, Nested)),
    [Deep] = maps:get(deeper, Nested),
    ?assertEqual(false, maps:is_key(client_secret, Deep)),
    ?assertEqual(42, maps:get(value, Deep)).

suffixed_secret_keys_are_removed_test() ->
    Safe = pw_storage_sanitize:without_secrets(#{github_token => <<"x">>, signing_secret => <<"y">>, label => <<"ok">>}),
    ?assertEqual(false, maps:is_key(github_token, Safe)),
    ?assertEqual(false, maps:is_key(signing_secret, Safe)),
    ?assertEqual(<<"ok">>, maps:get(label, Safe)).

oversized_payload_becomes_metadata_test() ->
    Bin = pw_storage_sanitize:encode_payload(#{safe => binary:copy(<<"a">>, 4096)}, 1024),
    Decoded = jsx:decode(Bin, [return_maps]),
    ?assertEqual(true, maps:get(<<"truncated">>, Decoded)),
    ?assert(maps:get(<<"original_bytes">>, Decoded) > 1024),
    ?assert(byte_size(maps:get(<<"sha256">>, Decoded)) > 0).
