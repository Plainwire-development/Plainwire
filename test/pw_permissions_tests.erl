-module(pw_permissions_tests).

-include_lib("eunit/include/eunit.hrl").

%% The permission bits are macros combined with bor/band by their callers.
%% Erlang gives bsl and bor equal precedence (left associative) and binds band
%% tighter than bsl, so defining them without parentheses silently turns all/0
%% into a 99-bit value that no bigint column can hold, and makes has/2 treat
%% every odd mask as Administrator.
all_fits_in_a_bigint_test() ->
    All = pw_permissions:all(),
    ?assertEqual(1073748991, All),
    ?assert(All =< 16#7FFFFFFFFFFFFFFF).

member_default_matches_schema_default_test() ->
    ?assertEqual(771, pw_permissions:member_default()).

member_default_does_not_imply_moderation_test() ->
    Member = pw_permissions:member_default(),
    ?assert(pw_permissions:has(Member, pw_permissions:mask(<<"view_channels">>))),
    ?assert(pw_permissions:has(Member, pw_permissions:mask(<<"send_messages">>))),
    ?assertNot(pw_permissions:has(Member, pw_permissions:mask(<<"manage_messages">>))),
    ?assertNot(pw_permissions:has(Member, pw_permissions:mask(<<"manage_server">>))),
    ?assertNot(pw_permissions:has(Member, pw_permissions:mask(<<"kick_members">>))),
    ?assertNot(pw_permissions:has(Member, pw_permissions:mask(<<"administrator">>))).

administrator_grants_every_catalog_bit_test() ->
    Admin = pw_permissions:mask(<<"administrator">>),
    lists:foreach(fun(#{bit := Bit}) ->
        ?assert(pw_permissions:has(Admin, Bit))
    end, pw_permissions:catalog()).

catalog_bits_are_distinct_and_in_range_test() ->
    Bits = [Bit || #{bit := Bit} <- pw_permissions:catalog()],
    ?assertEqual(length(Bits), length(lists:usort(Bits))),
    lists:foreach(fun(Bit) ->
        ?assertEqual(Bit, Bit band pw_permissions:all())
    end, Bits).

sanitize_keeps_known_bits_and_drops_the_rest_test() ->
    ?assertEqual(771, pw_permissions:sanitize(771)),
    ?assertEqual(pw_permissions:all(), pw_permissions:sanitize(pw_permissions:all())),
    ?assertEqual(pw_permissions:all(), pw_permissions:sanitize(16#FFFFFFFF)),
    ?assertEqual(771, pw_permissions:sanitize(<<"771">>)),
    ?assertEqual(0, pw_permissions:sanitize(<<"not-a-number">>)).
