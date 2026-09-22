-module(pw_crypto).
-export([
    enabled/0, validate/0,
    encrypt/1, decrypt/1,
    search_enabled/0, search_key_fingerprint/0, search_hashes/1,
    proxy_token/1, verify_proxy_token/2
]).

%% Plainwire durable-content crypto.
%%
%% PLAINWIRE_ENC_KEY is the primary 32-byte base64 AES-256-GCM key.
%% PLAINWIRE_ENC_PREVIOUS_KEYS is an optional comma-separated list of up to four
%% previous keys. New values are always encrypted with the primary key while
%% decryption tries the primary and then the previous keys. This makes key
%% rotation non-disruptive without writing key material or key ids beside data.
%%
%% PLAINWIRE_SEARCH_KEY is an optional independent 32-byte base64 key used for
%% keyed blind-index tokens. When absent, a dedicated key is derived from the
%% encryption key with HMAC-SHA256. Search tokens are not reversible plaintext.

-define(MAX_PREVIOUS_KEYS, 4).
-define(MAX_SEARCH_TOKENS, 64).
-define(SEARCH_LABEL, <<"plainwire-search-v1">>).

enabled() ->
    case primary_key() of
        {ok, _} -> true;
        _ -> false
    end.

validate() ->
    case primary_key() of
        {error, no_key} -> {error, no_encryption_key};
        {error, bad_key} -> {error, invalid_encryption_key};
        {ok, _} ->
            case previous_keys() of
                {error, _} = Error -> Error;
                {ok, _} ->
                    case validate_optional_key("PLAINWIRE_SEARCH_KEY", invalid_search_key) of
                        ok -> validate_optional_key("PLAINWIRE_MEDIA_SIGNING_KEY", invalid_media_signing_key);
                        Error -> Error
                    end
            end
    end.

encrypt(Plain0) when is_binary(Plain0) ->
    case primary_key() of
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
            case safe_base64_decode(Enc) of
                <<IV:12/binary, Tag:16/binary, Cipher/binary>> ->
                    case decrypt_with_keys(all_decryption_keys(), IV, Cipher, Tag) of
                        {ok, Plain} -> Plain;
                        %% A well-formed envelope that fails authentication is not
                        %% plaintext. Returning it would publish ciphertext and
                        %% could be reused as a webhook secret or API key.
                        error -> <<>>
                    end;
                _ -> Bin0
            end;
        _ -> Bin0
    end;
decrypt(X) -> decrypt(pw_util:bin(X)).

decrypt_with_keys({ok, Keys}, IV, Cipher, Tag) ->
    decrypt_with_key_list(Keys, IV, Cipher, Tag);
decrypt_with_keys(_, _IV, _Cipher, _Tag) -> error.

decrypt_with_key_list([], _IV, _Cipher, _Tag) -> error;
decrypt_with_key_list([Key | Rest], IV, Cipher, Tag) ->
    case safe_decrypt(Key, IV, Cipher, <<>>, Tag) of
        Plain when is_binary(Plain) -> {ok, Plain};
        _ -> decrypt_with_key_list(Rest, IV, Cipher, Tag)
    end.

search_enabled() ->
    case search_key() of {ok, _} -> true; _ -> false end.

search_key_fingerprint() ->
    case search_key() of
        {ok, Key} ->
            <<Prefix:12/binary, _/binary>> = crypto:hash(sha256, Key),
            pw_util:base64url(Prefix);
        _ -> <<>>
    end.

%% Return unique, bounded keyed tokens. Persist these values, never the
%% normalized words themselves. The maximum makes indexing deterministic and
%% prevents a single pathological message from creating unbounded rows.
search_hashes(Value0) ->
    case search_key() of
        {ok, Key} ->
            Words = lists:sublist(search_words(Value0), ?MAX_SEARCH_TOKENS),
            [search_hash(Key, Word) || Word <- Words];
        _ -> []
    end.

search_hash(Key, Word) ->
    Mac = crypto:mac(hmac, sha256, Key, <<?SEARCH_LABEL/binary, 0, Word/binary>>),
    <<Short:16/binary, _/binary>> = Mac,
    pw_util:base64url(Short).

search_words(Value0) ->
    Bin = pw_util:bin(Value0),
    %% Message size is already bounded, but cap again because this helper is
    %% also used by search queries supplied by clients/bots.
    Limited = case byte_size(Bin) > 12000 of true -> binary:part(Bin, 0, 12000); false -> Bin end,
    Lower = try unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Limited)))
            catch _:_ -> <<>> end,
    Parts = try re:split(Lower, <<"[^\\p{L}\\p{N}_]+">>, [unicode, {return, binary}, trim])
            catch _:_ -> [] end,
    lists:usort([W || W <- Parts, byte_size(W) >= 2, byte_size(W) =< 64]).

%% Signed opaque tokens for proxied media URLs (no raw URL in client requests).
proxy_token(Url) ->
    {ok, Key} = signing_key(),
    %% Stable tokens stop every sync from reloading every avatar.
    <<Nonce:8/binary, _/binary>> = crypto:mac(hmac, sha256, Key, <<"media:", Url/binary>>),
    Mac = crypto:mac(hmac, sha256, Key, <<Nonce/binary, Url/binary>>),
    <<$p, $1, $:, (pw_util:base64url(<<Nonce/binary, Mac:16/binary>>))/binary, $., (pw_util:base64url(Url))/binary>>.

verify_proxy_token(Token, Url) ->
    {ok, Key} = signing_key(),
    case Token of
        <<$p, $1, $:, Rest/binary>> ->
            case binary:split(Rest, <<".">>, []) of
                [SigB64, UrlB64] ->
                    case {pw_util:base64url_decode(SigB64), pw_util:base64url_decode(UrlB64)} of
                        {<<Nonce:8/binary, Mac:16/binary>>, DecUrl} when DecUrl =:= Url ->
                            <<Expected:16/binary, _/binary>> = crypto:mac(hmac, sha256, Key, <<Nonce/binary, Url/binary>>),
                            constant_time(Mac, Expected);
                        _ -> false
                    end;
                _ -> false
            end;
        _ -> false
    end.

signing_key() ->
    case os:getenv("PLAINWIRE_MEDIA_SIGNING_KEY") of
        false ->
            case primary_key() of
                {ok, _} = Found -> Found;
                _ -> ephemeral_signing_key()
            end;
        _ -> env_key("PLAINWIRE_MEDIA_SIGNING_KEY")
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

search_key() ->
    case os:getenv("PLAINWIRE_SEARCH_KEY") of
        false ->
            case primary_key() of
                {ok, EncKey} -> {ok, crypto:mac(hmac, sha256, EncKey, ?SEARCH_LABEL)};
                Error -> Error
            end;
        _ -> env_key("PLAINWIRE_SEARCH_KEY")
    end.

validate_optional_key(Name, ErrorAtom) ->
    case os:getenv(Name) of
        false -> ok;
        "" -> {error, ErrorAtom};
        _ ->
            case env_key(Name) of
                {ok, _} -> ok;
                _ -> {error, ErrorAtom}
            end
    end.

primary_key() -> env_key("PLAINWIRE_ENC_KEY").

all_decryption_keys() ->
    case {primary_key(), previous_keys()} of
        {{ok, Primary}, {ok, Previous}} -> {ok, [Primary | Previous]};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

previous_keys() ->
    case os:getenv("PLAINWIRE_ENC_PREVIOUS_KEYS") of
        false -> {ok, []};
        "" -> {ok, []};
        Raw ->
            Parts0 = [string:trim(P) || P <- string:split(Raw, ",", all)],
            Parts = [P || P <- Parts0, P =/= ""],
            case length(Parts) =< ?MAX_PREVIOUS_KEYS of
                false -> {error, too_many_previous_encryption_keys};
                true -> decode_previous_keys(Parts, [])
            end
    end.

decode_previous_keys([], Acc) -> {ok, lists:reverse(Acc)};
decode_previous_keys([Value | Rest], Acc) ->
    case decode_key(list_to_binary(Value)) of
        {ok, Key} -> decode_previous_keys(Rest, [Key | Acc]);
        _ -> {error, invalid_previous_encryption_key}
    end.

env_key(Name) ->
    case os:getenv(Name) of
        false -> {error, no_key};
        V -> decode_key(list_to_binary(V))
    end.

decode_key(V) ->
    case safe_base64_decode(V) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> {ok, Key};
        _ -> {error, bad_key}
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
