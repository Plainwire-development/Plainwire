-module(pw_media_tests).

-include_lib("eunit/include/eunit.hrl").

blocks_private_and_local_urls_test() ->
    ?assertEqual({error, blocked_url}, pw_media:validate_url(<<"http://127.0.0.1/image.png">>)),
    ?assertEqual({error, blocked_url}, pw_media:validate_url(<<"http://10.0.0.5/image.png">>)),
    ?assertEqual({error, blocked_url}, pw_media:validate_url(<<"http://192.168.1.10/image.png">>)),
    ?assertEqual({error, blocked_url}, pw_media:validate_url(<<"http://169.254.169.254/latest/meta-data">>)).

rejects_invalid_url_schemes_test() ->
    ?assertEqual({error, invalid_url}, pw_media:validate_url(<<"file:///etc/passwd">>)),
    ?assertEqual({error, invalid_url}, pw_media:validate_url(<<"data:image/png;base64,abc">>)),
    ?assertEqual({error, invalid_url}, pw_media:validate_url(<<"/local/path.png">>)).

legacy_proxy_token_is_decoded_then_validated_test() ->
    Token = pw_util:base64url(<<"http://127.0.0.1/image.png">>),
    ?assertEqual({error, blocked_url}, pw_media:fetch(1, Token)).

profile_image_signatures_test() ->
    ?assert(pw_db:profile_file_signature(<<"image/jpeg">>, <<16#ff,16#d8,16#ff,0>>)),
    ?assert(pw_db:profile_file_signature(<<"image/png">>, <<16#89,"PNG",13,10,26,10,0>>)),
    ?assert(pw_db:profile_file_signature(<<"image/gif">>, <<"GIF89a",0>>)),
    ?assert(pw_db:profile_file_signature(<<"image/webp">>, <<"RIFF",0,0,0,0,"WEBP",0>>)),
    ?assert(pw_db:profile_file_signature(<<"image/avif">>, <<0,0,0,24,"ftypavif",0,0,0,0>>)),
    ?assertNot(pw_db:profile_file_signature(<<"image/png">>, <<"<script>alert(1)</script>">>)),
    ?assertNot(pw_db:profile_file_signature(<<"image/svg+xml">>, <<"<svg/>">>)).
