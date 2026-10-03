-module(pw_e2ee).
-export([is_envelope/1, valid_key_id/1, valid_envelope/2, key_id/1, nonce/1, preview/1]).

%% The relay validates framing only. It never receives the DM key and cannot
%% authenticate or decrypt these client-created AES-GCM envelopes.
is_envelope(<<"pw-e2ee-", _/binary>>) -> true;
is_envelope(_) -> false.

valid_key_id(KeyId) when is_binary(KeyId), byte_size(KeyId) =:= 64 ->
    re:run(KeyId, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match;
valid_key_id(_) -> false.

valid_envelope(Body, KeyId) when is_binary(Body), byte_size(Body) =< 8192 ->
    case {valid_key_id(KeyId), binary:split(Body, <<":">>, [global])} of
        {true, [<<"pw-e2ee-v1">>, KeyId, IV, Cipher]} ->
            valid_base64url(IV, 12, 12) andalso valid_base64url(Cipher, 26, 6000);
        {true, [<<"pw-e2ee-v2">>, KeyId, Nonce, IV, Cipher]} ->
            valid_base64url(Nonce, 16, 16) andalso valid_base64url(IV, 12, 12)
                andalso valid_base64url(Cipher, 26, 6000);
        _ -> false
    end;
valid_envelope(_, _) -> false.

key_id(Body) when is_binary(Body) ->
    case binary:split(Body, <<":">>, [global]) of
        [_, KeyId | _] -> KeyId;
        _ -> <<>>
    end;
key_id(_) -> <<>>.

nonce(Body) when is_binary(Body) ->
    case binary:split(Body, <<":">>, [global]) of
        [<<"pw-e2ee-v2">>, _, Nonce, _, _] -> Nonce;
        _ -> <<>>
    end;
nonce(_) -> <<>>.

valid_base64url(Value, Min, Max) ->
    re:run(Value, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match
    andalso begin
        Bytes = pw_util:base64url_decode(Value),
        byte_size(Bytes) >= Min andalso byte_size(Bytes) =< Max
        andalso pw_util:base64url(Bytes) =:= Value
    end.

preview(Body) ->
    case is_envelope(Body) of
        true -> <<"Encrypted text message">>;
        false -> Body
    end.
