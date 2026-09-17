-module(pw_outbound_url_tests).
-include_lib("eunit/include/eunit.hrl").

public_ipv4_test() ->
    ?assert(pw_outbound_url:public_ip({8,8,8,8})),
    ?assertNot(pw_outbound_url:public_ip({127,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({10,1,2,3})),
    ?assertNot(pw_outbound_url:public_ip({100,64,0,1})),
    ?assertNot(pw_outbound_url:public_ip({169,254,1,1})),
    ?assertNot(pw_outbound_url:public_ip({172,16,0,1})),
    ?assertNot(pw_outbound_url:public_ip({192,0,2,1})),
    ?assertNot(pw_outbound_url:public_ip({192,168,1,1})),
    ?assertNot(pw_outbound_url:public_ip({198,18,0,1})),
    ?assertNot(pw_outbound_url:public_ip({198,51,100,1})),
    ?assertNot(pw_outbound_url:public_ip({203,0,113,1})),
    ?assertNot(pw_outbound_url:public_ip({224,0,0,1})).

public_ipv6_test() ->
    ?assert(pw_outbound_url:public_ip({16#2606,16#4700,16#4700,0,0,0,0,16#1111})),
    ?assertNot(pw_outbound_url:public_ip({0,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#0064,16#ff9b,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#0064,16#ff9b,1,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#0100,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#2001,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#2001,2,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#2001,16#0db8,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#2002,16#0808,16#0808,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#3fff,16#0001,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#5f00,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#fc00,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#fe80,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#fec0,0,0,0,0,0,0,1})),
    ?assertNot(pw_outbound_url:public_ip({16#ff02,0,0,0,0,0,0,1})).
