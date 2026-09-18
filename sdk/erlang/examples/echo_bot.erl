-module(echo_bot).
-export([run/3]).

run(BaseUrl, Token, ChannelId) ->
    {ok, Bot} = plainwire_bot:start_link(#{base_url => BaseUrl, token => Token}),
    ok = plainwire_bot:subscribe(Bot, iolist_to_binary([<<"channel:">>, integer_to_binary(ChannelId)])),
    loop(Bot, ChannelId).

loop(Bot, ChannelId) ->
    receive
        {plainwire_bot, Bot, {event, #{<<"type">> := <<"message_created">>,
                                      <<"message">> := #{<<"body">> := <<"!ping">>}}}} ->
            _ = plainwire_bot:send_message(Bot, ChannelId, <<"pong">>),
            loop(Bot, ChannelId);
        {plainwire_bot, Bot, _Other} ->
            loop(Bot, ChannelId)
    end.
