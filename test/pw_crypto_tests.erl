-module(pw_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

signed_proxy_token_round_trip_test() ->
    with_env("PLAINWIRE_ENC_KEY", test_key(), fun() ->
        Url = <<"https://example.com/image.png">>,
        Token = pw_crypto:proxy_token(Url),
        ?assertEqual(Token, pw_crypto:proxy_token(Url)),
        ?assertMatch(<<"p1:", _/binary>>, Token),
        ?assert(pw_crypto:verify_proxy_token(Token, Url)),
        ?assertNot(pw_crypto:verify_proxy_token(Token, <<"https://example.com/other.png">>))
    end).

unsigned_proxy_token_round_trip_test() ->
    with_env("PLAINWIRE_ENC_KEY", unset, fun() ->
        Url = <<"https://example.com/image.png">>,
        Token = pw_crypto:proxy_token(Url),
        ?assert(pw_crypto:verify_proxy_token(Token, Url)),
        ?assertNot(pw_crypto:verify_proxy_token(Token, <<"https://example.com/other.png">>))
    end).

encryption_round_trip_test() ->
    with_env("PLAINWIRE_ENC_KEY", test_key(), fun() ->
        Plain = <<"hello private message">>,
        Cipher = pw_crypto:encrypt(Plain),
        ?assertMatch(<<"e1:", _/binary>>, Cipher),
        ?assertEqual(Plain, pw_crypto:decrypt(Cipher))
    end).

tampered_envelope_is_not_returned_test() ->
    with_env("PLAINWIRE_ENC_KEY", test_key(), fun() ->
        Cipher = pw_crypto:encrypt(<<"hello private message">>),
        <<"e1:", Rest/binary>> = Cipher,
        Decoded = base64:decode(Rest),
        <<Byte, Tail/binary>> = Decoded,
        Bad = <<"e1:", (base64:encode(<<(Byte bxor 16#ff), Tail/binary>>))/binary>>,
        ?assertEqual(<<>>, pw_crypto:decrypt(Bad)),
        ?assertNotEqual(Bad, pw_crypto:decrypt(Bad))
    end).

missing_key_does_not_return_ciphertext_test() ->
    Cipher = with_env("PLAINWIRE_ENC_KEY", test_key(), fun() ->
        pw_crypto:encrypt(<<"hello private message">>)
    end),
    with_env("PLAINWIRE_ENC_KEY", unset, fun() ->
        ?assertEqual(<<>>, pw_crypto:decrypt(Cipher))
    end).

bad_key_leaves_plaintext_test() ->
    with_env("PLAINWIRE_ENC_KEY", "bad-key", fun() ->
        Plain = <<"hello">>,
        ?assertEqual(Plain, pw_crypto:encrypt(Plain)),
        ?assertEqual(Plain, pw_crypto:decrypt(Plain))
    end).

test_key() ->
    binary_to_list(base64:encode(<<0:256>>)).

with_env(Name, Value, Fun) ->
    Old = os:getenv(Name),
    set_env(Name, Value),
    try Fun()
    after restore_env(Name, Old)
    end.

set_env(Name, unset) -> os:unsetenv(Name);
set_env(Name, Value) -> os:putenv(Name, Value).

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).
