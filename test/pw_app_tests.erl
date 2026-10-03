-module(pw_app_tests).
-include_lib("eunit/include/eunit.hrl").

production_distribution_requires_disabled_listeners_test() ->
    Node = 'plainwire_relay@host', Disabled = {ok, [["false"]]},
    ?assert(pw_app:distribution_allowed(true, nonode@nohost, error, error)),
    ?assert(pw_app:distribution_allowed(true, Node, Disabled, Disabled)),
    ?assertNot(pw_app:distribution_allowed(true, Node, error, error)),
    ?assertNot(pw_app:distribution_allowed(true, Node, {ok, [["true"]]}, Disabled)),
    ?assertNot(pw_app:distribution_allowed(true, Node, Disabled, error)),
    ?assertNot(pw_app:distribution_allowed(true, Node, {ok, [["false"], ["true"]]}, Disabled)),
    ?assert(pw_app:distribution_allowed(false, Node, error, error)).
