-module(pw_github_tests).
-include_lib("eunit/include/eunit.hrl").

invalid_repository_is_rejected_before_network_test() ->
    ?assertEqual({error, invalid_repository}, pw_github:repository(<<"../Plainwire">>)),
    ?assertEqual({error, invalid_repository}, pw_github:repository(<<"Plainwire/other">>)),
    ?assertEqual({error, invalid_repository}, pw_github:repository(<<".">>)),
    ?assertEqual({error, invalid_repository}, pw_github:repository(<<"..">>)),
    ?assertEqual({error, invalid_repository}, pw_github:repository(<<>>)).

invalid_commit_is_rejected_before_network_test() ->
    ?assertEqual({error, invalid_commit}, pw_github:commit(<<"Plainwire">>, <<"not-a-sha">>)),
    ?assertEqual({error, invalid_commit}, pw_github:commit(<<"Plainwire">>, <<"123456">>)).

invalid_profile_is_rejected_before_network_test() ->
    ?assertEqual({error, invalid_profile}, pw_github:profile(<<"-leading">>)),
    ?assertEqual({error, invalid_profile}, pw_github:profile(<<"trailing-">>)),
    ?assertEqual({error, invalid_profile}, pw_github:profile(<<"bad_login">>)).

unsafe_content_path_is_rejected_before_network_test() ->
    ?assertEqual({error, invalid_path}, pw_github:content(<<"Plainwire">>, <<"../secret">>, <<"main">>)),
    ?assertEqual({error, invalid_path}, pw_github:content(<<"Plainwire">>, <<"src//pw_api.erl">>, <<"main">>)),
    ?assertEqual({error, invalid_ref}, pw_github:content(<<"Plainwire">>, <<"src/pw_api.erl">>, <<"bad", 0, "ref">>)).
