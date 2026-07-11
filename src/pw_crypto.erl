-module(pw_crypto).
-export([enabled/0, encrypt/1, decrypt/1, proxy_token/1, verify_proxy_token/2]).

%% AES-256-GCM field encryption for message bodies at rest.
%% Set PLAINWIRE_ENC_KEY to a base64-encoded 32-byte key.

enabled() ->
    case key() of
        {ok, _} -> true;
        _ -> false
    end.

encrypt(Plain0) when is_binary(Plain0) ->
    case key() of
        {ok, Key} ->
            IV = crypto:strong_rand_bytes(12),
            AAD = <<>>,
            {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Plain0, AAD, true),
            <<$e, $1, $:, (base64:encode(<<IV/binary, Tag/binary, Cipher/binary>>))/binary>>;
        _ ->
            Plain0
    end;
encrypt(Plain) -> encrypt(pw_util:bin(Plain)).

decrypt(Bin0) when is_binary(Bin0) ->
    case Bin0 of
        <<$e, $1, $:, Enc/binary>> ->
            case key() of
                {ok, Key} ->
                    case safe_base64_decode(Enc) of
                        <<IV:12/binary, Tag:16/binary, Cipher/binary>> ->
                            AAD = <<>>,
                            case safe_decrypt(Key, IV, Cipher, AAD, Tag) of
                                Plain when is_binary(Plain) -> Plain;
                                _ -> Bin0
                            end;
                        _ ->
                            Bin0
                    end;
                _ ->
                    Bin0
            end;
        _ ->
            Bin0
    end;
decrypt(X) -> decrypt(pw_util:bin(X)).

%% Signed opaque tokens for proxied media URLs (no raw URL in client requests).
proxy_token(Url) ->
    case signing_key() of
        {ok, Key} ->
            %% Keep media URLs stable across API refreshes. Random tokens caused
            %% browsers to reload every avatar on each sync even when unchanged.
            <<Nonce:8/binary, _/binary>> = crypto:mac(hmac, sha256, Key, <<"media:", Url/binary>>),
            Mac = crypto:mac(hmac, sha256, Key, <<Nonce/binary, Url/binary>>),
            <<$p, $1, $:, (pw_util:base64url(<<Nonce/binary, Mac:16/binary>>))/binary, $., (pw_util:base64url(Url))/binary>>;
        _ -> erlang:error(media_signing_key_not_configured)
    end.

verify_proxy_token(Token, Url) ->
    case signing_key() of
        {ok, Key} ->
            case Token of
                <<$p, $1, $:, Rest/binary>> ->
                    case binary:split(Rest, <<".">>, []) of
                        [SigB64, UrlB64] ->
                            case {pw_util:base64url_decode(SigB64), pw_util:base64url_decode(UrlB64)} of
                                {<<Nonce:8/binary, Mac:16/binary>>, DecUrl} when DecUrl =:= Url ->
                                    <<Expected:16/binary, _/binary>> = crypto:mac(hmac, sha256, Key, <<Nonce/binary, Url/binary>>),
                                    constant_time(Mac, Expected);
                                _ ->
                                    false
                            end;
                        _ ->
                            false
                    end;
                _ ->
                    false
            end;
        _ -> false
    end.

signing_key() ->
    case env_key("PLAINWIRE_MEDIA_SIGNING_KEY") of
        {ok, _} = Found -> Found;
        _ ->
            case key() of
                {ok, _} = Found -> Found;
                _ -> ephemeral_signing_key()
            end
    end.

ephemeral_signing_key() ->
    Key = {?MODULE, media_signing_key},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Generated = crypto:strong_rand_bytes(32),
            persistent_term:put(Key, Generated),
            {ok, Generated};
        Existing -> {ok, Existing}
    end.

key() ->
    env_key("PLAINWIRE_ENC_KEY").

env_key(Name) ->
    case os:getenv(Name) of
        false ->
            {error, no_key};
        V ->
            case safe_base64_decode(list_to_binary(V)) of
                Key when byte_size(Key) =:= 32 -> {ok, Key};
                _ -> {error, bad_key}
            end
    end.

safe_base64_decode(V) ->
    try base64:decode(V) catch _:_ -> error end.

safe_decrypt(Key, IV, Cipher, AAD, Tag) ->
    try crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Cipher, AAD, Tag, false)
    catch _:_ -> error
    end.

constant_time(A, B) when byte_size(A) =/= byte_size(B) -> false;
constant_time(A, B) -> constant_time(binary_to_list(A), binary_to_list(B), 0) =:= 0.
constant_time([], [], Acc) -> Acc;
constant_time([A|As], [B|Bs], Acc) -> constant_time(As, Bs, Acc bor (A bxor B)).
