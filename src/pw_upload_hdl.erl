-module(pw_upload_hdl).
-behaviour(cowboy_handler).
-export([init/2]).

-define(MAX_FILE, 262144000).

init(Req0, _) ->
    case {cowboy_req:method(Req0), auth(Req0)} of
        {<<"POST">>, {ok, Session}} -> upload(Req0, Session);
        {_, {error, _}} -> pw_util:err_json(Req0, 401, <<"not_authenticated">>);
        _ -> pw_util:err_json(Req0, 405, <<"method_not_allowed">>)
    end.

upload(Req0, Session) ->
    Max = min(?MAX_FILE, pw_client_config:upload_max_bytes()),
    Uid = maps:get(id, maps:get(user, Session)),
    case pw_util:require_csrf(Req0, Session) of
        false -> pw_util:err_json(Req0, 403, <<"bad_csrf">>);
        true ->
            case content_length(Req0, Max) of
                missing -> pw_util:err_json(Req0, 411, <<"content_length_required">>);
                invalid -> pw_util:err_json(Req0, 400, <<"invalid_content_length">>);
                too_large -> pw_util:err_json(Req0, 413, <<"file_too_large">>);
                {ok, Size} ->
                    case pw_rate:allow({upload, Uid}, 120, 10800000) of
                        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
                        true ->
                            case pw_upload_gc:acquire(Uid, Size) of
                                ok ->
                                    try begin_upload(Req0, Uid, Size)
                                    after pw_upload_gc:release(Uid, Size) end;
                                {error, busy} ->
                                    pw_util:err_json(Req0, 429, <<"too_many_concurrent_uploads">>)
                            end
                    end
            end
    end.

begin_upload(Req0, Uid, Size) ->
    Id = pw_util:random_token(24),
    Name = clean_filename(cowboy_req:header(<<"x-file-name">>, Req0, <<"file">>)),
    Type = clean_type(cowboy_req:header(<<"content-type">>, Req0, <<"application/octet-stream">>)),
    Dir = upload_dir(),
    Path = filename:join(Dir, binary_to_list(Id)),
    Tmp = Path ++ ".part",
    case filelib:ensure_dir(Tmp) of
        ok -> begin_upload_reserved(Req0, Uid, Size, Id, Name, Type, Path, Tmp);
        {error, _} -> pw_util:err_json(Req0, 503, <<"upload_storage_unavailable">>)
    end.

begin_upload_reserved(Req0, Uid, Size, Id, Name, Type, Path, Tmp) ->
    case pw_db:begin_upload(Uid, Id, Name, Type, Size, list_to_binary(Path)) of
        {ok, reserved} ->
            case stream_to_file(Req0, Tmp, Size) of
                {ok, Req1, Hash} ->
                    case file:rename(Tmp, Path) of
                        ok ->
                            case pw_db:finish_upload(Uid, Id, Hash) of
                                ok ->
                                    pw_util:ok_json(Req1, #{ok => true, data => #{id => Id, name => Name,
                                        content_type => Type, size => Size, url => <<"/api/files/", Id/binary>>}});
                                {error, not_found} ->
                                    %% A missing pending reservation is definitive: do not leave an
                                    %% orphaned finalized file that the database sweeper cannot discover.
                                    _ = file:delete(Path),
                                    pw_util:err_json(Req1, 409, <<"upload_reservation_lost">>);
                                {error, _} ->
                                    %% The database write can be ambiguous if a connection dies after
                                    %% PostgreSQL commits. Keep the finalized file in place so either the
                                    %% ready row remains usable or the stale-upload sweeper removes it.
                                    pw_util:err_json(Req1, 503, <<"upload_finalize_unavailable">>)
                            end;
                        {error, _} ->
                            fail_upload(Uid, Id, Tmp, Req1, 503, <<"upload_storage_unavailable">>)
                    end;
                {error, size_mismatch, Req1} ->
                    fail_upload(Uid, Id, Tmp, Req1, 400, <<"upload_size_mismatch">>);
                {error, malformed_body, Req1} ->
                    fail_upload(Uid, Id, Tmp, Req1, 400, <<"invalid_upload_body">>);
                {error, storage, Req1} ->
                    fail_upload(Uid, Id, Tmp, Req1, 503, <<"upload_storage_unavailable">>)
            end;
        {error, quota_exceeded} -> pw_util:err_json(Req0, 429, <<"upload_quota_exceeded">>);
        {error, _} -> pw_util:err_json(Req0, 503, <<"upload_unavailable">>)
    end.

stream_to_file(Req0, Tmp, Expected) ->
    case file:open(Tmp, [write, raw, binary, exclusive]) of
        {ok, Io} ->
            Ctx = crypto:hash_init(sha256),
            try stream_chunks(Req0, Io, Expected, 0, Ctx)
            after file:close(Io) end;
        {error, _} -> {error, storage, Req0}
    end.

stream_chunks(Req0, Io, Expected, Read, Ctx) ->
    try cowboy_req:read_body(Req0, #{length => 1048576, period => 30000}) of
        {more, Data, Req1} when is_binary(Data) ->
            Total = Read + byte_size(Data),
            case Total =< Expected of
                true ->
                    case file:write(Io, Data) of
                        ok -> stream_chunks(Req1, Io, Expected, Total, crypto:hash_update(Ctx, Data));
                        {error, _} -> {error, storage, Req1}
                    end;
                false ->
                    {error, size_mismatch, Req1}
            end;
        {ok, Data, Req1} when is_binary(Data) ->
            Total = Read + byte_size(Data),
            case Total =:= Expected of
                true ->
                    case file:write(Io, Data) of
                        ok -> {ok, Req1, pw_util:hex_binary(crypto:hash_final(crypto:hash_update(Ctx, Data)))};
                        {error, _} -> {error, storage, Req1}
                    end;
                false ->
                    {error, size_mismatch, Req1}
            end;
        _ ->
            {error, malformed_body, Req0}
    catch
        _:_ -> {error, malformed_body, Req0}
    end.

fail_upload(Uid, Id, Tmp, Req, Status, Code) ->
    _ = file:delete(Tmp),
    _ = pw_db:abort_upload(Uid, Id),
    pw_util:err_json(Req, Status, Code).

auth(Req) ->
    case pw_util:cookie_value(Req, <<"pw_session">>) of
        undefined -> {error, no_session};
        Token -> case pw_db:session_fast(Token) of {ok, S} -> {ok, S}; _ -> pw_db:session(Token) end
    end.

content_length(Req, Max) ->
    case cowboy_req:header(<<"content-length">>, Req, undefined) of
        undefined -> missing;
        <<>> -> missing;
        Raw ->
            case pw_util:int(Raw) of
                Size when is_integer(Size), Size > 0, Size =< Max -> {ok, Size};
                Size when is_integer(Size), Size > Max -> too_large;
                _ -> invalid
            end
    end.

upload_dir() -> binary_to_list(pw_util:env_str("PLAINWIRE_UPLOAD_DIR", <<"data/uploads/">>)).

clean_filename(Name0) ->
    Name1 = try uri_string:percent_decode(Name0) catch _:_ -> Name0 end,
    Name2 = filename:basename(binary_to_list(pw_util:clean_text(Name1, 240))),
    case pw_util:bin(Name2) of <<>> -> <<"file">>; Name -> Name end.

clean_type(Type0) ->
    Type = string:lowercase(string:trim(hd(binary:split(pw_util:clean_text(Type0, 120), <<";">>)))),
    case valid_media_type(Type) of
        true -> Type;
        false -> <<"application/octet-stream">>
    end.

valid_media_type(Type) when is_binary(Type), byte_size(Type) >= 3, byte_size(Type) =< 120 ->
    case binary:split(Type, <<"/">>, [global]) of
        [Major, Minor] when Major =/= <<>>, Minor =/= <<>> ->
            lists:all(fun valid_type_char/1, binary_to_list(Major)) andalso
                lists:all(fun valid_type_char/1, binary_to_list(Minor));
        _ -> false
    end;
valid_media_type(_) -> false.

valid_type_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse
    lists:member(C, "!#$&^_.+-").
