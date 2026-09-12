-module(pw_security_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- constant_time ---

constant_time_equal_test() ->
    ?assert(pw_util:constant_time(<<"abc">>, <<"abc">>)).

constant_time_not_equal_test() ->
    ?assertNot(pw_util:constant_time(<<"abc">>, <<"abd">>)).

constant_time_different_length_test() ->
    ?assertNot(pw_util:constant_time(<<"abc">>, <<"ab">>)).

constant_time_empty_test() ->
    ?assert(pw_util:constant_time(<<>>, <<>>)).

constant_time_single_byte_test() ->
    ?assert(pw_util:constant_time(<<0>>, <<0>>)),
    ?assertNot(pw_util:constant_time(<<0>>, <<1>>)).

%% --- signal_ok ---

signal_ok_offer_test() ->
    Sig = #{<<"kind">> => <<"offer">>, <<"sdp">> => #{<<"type">> => <<"offer">>, <<"sdp">> => <<"v=0\r\n">>}},
    ?assert(pw_ws:signal_ok(Sig)).

signal_ok_answer_test() ->
    Sig = #{<<"kind">> => <<"answer">>, <<"sdp">> => #{<<"type">> => <<"answer">>, <<"sdp">> => <<"v=0\r\n">>}},
    ?assert(pw_ws:signal_ok(Sig)).

signal_ok_candidate_test() ->
    Sig = #{<<"kind">> => <<"candidate">>, <<"candidate">> => #{<<"candidate">> => <<"1">>, <<"sdpMid">> => <<"0">>}},
    ?assert(pw_ws:signal_ok(Sig)).

signal_ok_renegotiate_test() ->
    ?assert(pw_ws:signal_ok(#{<<"kind">> => <<"renegotiate">>})),
    ?assertNot(pw_ws:signal_ok(#{<<"kind">> => <<"renegotiate">>, <<"junk">> => <<"payload">>})).

signal_ok_rejects_unknown_kind_test() ->
    ?assertNot(pw_ws:signal_ok(#{<<"kind">> => <<"banana">>})).

signal_ok_rejects_empty_test() ->
    ?assertNot(pw_ws:signal_ok(#{})).

signal_ok_rejects_missing_sdp_test() ->
    ?assertNot(pw_ws:signal_ok(#{<<"kind">> => <<"offer">>})).

signal_ok_rejects_bad_sdp_type_test() ->
    Sig = #{<<"kind">> => <<"offer">>, <<"sdp">> => #{<<"type">> => <<"banana">>, <<"sdp">> => <<"v=0">>}},
    ?assertNot(pw_ws:signal_ok(Sig)).

signal_ok_rejects_huge_sdp_test() ->
    Huge = list_to_binary(lists:duplicate(40000, $A)),
    Sig = #{<<"kind">> => <<"offer">>, <<"sdp">> => #{<<"type">> => <<"offer">>, <<"sdp">> => Huge}},
    ?assertNot(pw_ws:signal_ok(Sig)).

signal_ok_rejects_non_map_test() ->
    ?assertNot(pw_ws:signal_ok(<<"not a map">>)).

%% --- room_capacity ---

room_capacity_is_positive_test() ->
    Cap = pw_hub:room_capacity(),
    ?assert(Cap >= 2),
    ?assert(Cap =< 32).

share_capacity_is_positive_test() ->
    Cap = pw_hub:share_capacity(),
    ?assert(Cap >= 1),
    ?assert(Cap =< 8).

security_headers_deny_embedding_test() ->
    Headers = pw_util:security_headers(),
    ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, Headers)),
    Csp = maps:get(<<"content-security-policy">>, Headers),
    ?assert(binary:match(Csp, <<"frame-ancestors 'none'">>) =/= nomatch),
    ?assert(binary:match(Csp, <<"form-action 'self'">>) =/= nomatch).

security_headers_allow_first_party_media_permissions_test() ->
    Headers = pw_util:security_headers(),
    Policy = maps:get(<<"permissions-policy">>, Headers),
    ?assert(binary:match(Policy, <<"microphone=(self)">>) =/= nomatch),
    ?assert(binary:match(Policy, <<"display-capture=(self)">>) =/= nomatch),
    ?assert(binary:match(Policy, <<"camera=()">>) =/= nomatch).
