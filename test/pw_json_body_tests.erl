-module(pw_json_body_tests).
-include_lib("eunit/include/eunit.hrl").

%% Use Cowboy's real read_body implementation with a deterministic stream
%% process. Its best-effort length can return oversized complete chunks.
final_chunk_cannot_bypass_limit_test() ->
    ?assertMatch({error, too_large, _}, read_chunks([json_body(1025)], 1024)).

accumulated_final_chunk_cannot_bypass_limit_test() ->
    Body = json_body(1025),
    <<First:512/binary, Last/binary>> = Body,
    ?assertMatch({error, too_large, _}, read_chunks([First, Last], 1024)).

exact_limit_is_accepted_test() ->
    ?assertMatch({ok, #{<<"ok">> := true}, _}, read_chunks([json_body(1024)], 1024)),
    Body = json_body(1024),
    <<First:512/binary, Last/binary>> = Body,
    ?assertMatch({ok, #{<<"ok">> := true}, _}, read_chunks([First, Last], 1024)).

oversized_intermediate_chunk_is_rejected_test() ->
    ?assertMatch({error, too_large, _}, read_chunks([json_body(1025), <<" ">>], 1024)).

invalid_json_remains_an_error_test() ->
    ?assertMatch({error, invalid_json, _}, read_chunks([<<"not JSON">>], 1024)).

default_limit_is_enforced_test() ->
    ?assertMatch({error, too_large, _}, read_chunks([json_body(1048577)], default)).

json_body(Size) ->
    Prefix = <<"{\"ok\":true}">>,
    <<Prefix/binary, (binary:copy(<<" ">>, Size - byte_size(Prefix)))/binary>>.

read_chunks(Chunks, Limit) ->
    Stream = spawn_link(fun() -> stream(Chunks, 0) end),
    Req = #{pid => Stream, streamid => 1, has_body => true, headers => #{}},
    try
        case Limit of
            default -> pw_util:read_json(Req);
            _ -> pw_util:read_json(Req, Limit)
        end
    after
        unlink(Stream), exit(Stream, shutdown)
    end.

stream([Chunk | Rest], Total) ->
    receive
        {{_, 1}, {read_body, Caller, Ref, _, _}} ->
            case Rest of
                [] -> Caller ! {request_body, Ref, fin, Total + byte_size(Chunk), Chunk};
                _ -> Caller ! {request_body, Ref, nofin, Chunk}, stream(Rest, Total + byte_size(Chunk))
            end
    end.
