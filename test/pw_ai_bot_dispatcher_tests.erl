-module(pw_ai_bot_dispatcher_tests).
-include_lib("eunit/include/eunit.hrl").

openai_chat_response_test() ->
    Body = <<"{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}">>,
    ?assertEqual({ok, <<"hello">>}, pw_ai_bot_dispatcher:parse_ai_response(<<"openai">>, Body)).

anthropic_response_test() ->
    Body = <<"{\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"text\",\"text\":\"two\"}]}">>,
    ?assertEqual({ok, <<"one\ntwo">>}, pw_ai_bot_dispatcher:parse_ai_response(<<"anthropic">>, Body)).

google_response_test() ->
    Body = <<"{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"gemini reply\"}]}}]}">>,
    ?assertEqual({ok, <<"gemini reply">>}, pw_ai_bot_dispatcher:parse_ai_response(<<"google">>, Body)).

responses_api_response_test() ->
    Body = <<"{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"response text\"}]}]}">>,
    ?assertEqual({ok, <<"response text">>}, pw_ai_bot_dispatcher:parse_ai_response(<<"openai_responses">>, Body)).

google_endpoint_building_test() ->
    ?assertEqual(
        <<"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent">>,
        pw_ai_bot_dispatcher:google_endpoint(
            <<"https://generativelanguage.googleapis.com/v1beta/models/">>,
            <<"gemini-2.5-flash">>
        )
    ).

provider_normalization_test() ->
    ?assertEqual(<<"anthropic">>, pw_db:normalize_ai_provider(<<"Anthropic">>)),
    ?assertEqual(invalid, pw_db:normalize_ai_provider(<<"unknown">>)),
    ?assertEqual(<<"mention_or_reply">>, pw_db:normalize_ai_chat_trigger(<<"mention_or_reply">>)),
    ?assertEqual(2.0, pw_db:normalize_ai_temperature(99)),
    ?assertEqual(0.0, pw_db:normalize_ai_temperature(-2)).

command_options_from_args_test() ->
    ?assertEqual(#{<<"text">> => <<"hello">>},
                 pw_db:command_options_from_args(#{<<"raw">> => <<"hello">>, <<"source">> => <<"chat">>, <<"text">> => <<"hello">>})),
    ?assertEqual(#{}, pw_db:command_options_from_args(#{<<"raw">> => <<"only">>})).

chat_prompt_test() ->
    Text = pw_ai_bot_dispatcher:ai_user_content(#{
        command => <<"chat">>, member_name => <<"Ada">>, channel_name => <<"general">>,
        args => #{<<"raw">> => <<"hello bot">>, <<"source">> => <<"chat">>}
    }),
    ?assertEqual(true, binary:match(Text, <<"#general">>) =/= nomatch),
    ?assertEqual(true, binary:match(Text, <<"Ada">>) =/= nomatch),
    ?assertEqual(true, binary:match(Text, <<"hello bot">>) =/= nomatch).
