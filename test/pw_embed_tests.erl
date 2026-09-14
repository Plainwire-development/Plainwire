-module(pw_embed_tests).

-include_lib("eunit/include/eunit.hrl").

-define(URL, <<"https://news.example.com/articles/42">>).

meta_attributes_in_any_order_and_quoting_test() ->
    Html = <<"<!doctype html><html><head>",
             "<meta content=\"A &amp; B &#8212; launch\" property=\"og:title\">",
             "<meta name='description' content='Plain description'>",
             "<META PROPERTY=\"og:site_name\" CONTENT=\"Example News\"/>",
             "<title>Fallback title</title></head>",
             "<body><meta property=\"og:title\" content=\"from the body\"></body></html>">>,
    Meta = pw_embed:parse_og(Html, ?URL),
    ?assertEqual(<<"A & B ", 226, 128, 148, " launch">>, maps:get(<<"title">>, Meta)),
    ?assertEqual(<<"Plain description">>, maps:get(<<"description">>, Meta)),
    ?assertEqual(<<"Example News">>, maps:get(<<"site_name">>, Meta)),
    ?assertEqual(<<>>, maps:get(<<"image">>, Meta)).

twitter_and_title_fallbacks_test() ->
    Html = <<"<html><head><title>\n   Page   Title\n</title>",
             "<meta name=\"twitter:description\" content=\"From twitter\">",
             "<meta name=\"twitter:image\" content=\"//cdn.example.net/card.png\">",
             "</head></html>">>,
    Meta = pw_embed:parse_og(Html, ?URL),
    ?assertEqual(<<"Page Title">>, maps:get(<<"title">>, Meta)),
    ?assertEqual(<<"From twitter">>, maps:get(<<"description">>, Meta)),
    ?assertEqual(<<"news.example.com">>, maps:get(<<"site_name">>, Meta)),
    ?assertEqual(pw_media:proxy_url(<<"https://cdn.example.net/card.png">>), maps:get(<<"image">>, Meta)).

relative_image_resolves_against_page_test() ->
    Html = <<"<head><meta property=\"og:image\" content=\"../img/cover.jpg\"></head>">>,
    Meta = pw_embed:parse_og(Html, ?URL),
    ?assertEqual(pw_media:proxy_url(<<"https://news.example.com/img/cover.jpg">>), maps:get(<<"image">>, Meta)).

non_utf8_and_truncated_pages_still_parse_test() ->
    Latin1 = <<"<head><meta property=\"og:title\" content=\"Caf", 233, "\"></head>">>,
    ?assertEqual(<<"Caf", 195, 169>>, maps:get(<<"title">>, pw_embed:parse_og(Latin1, ?URL))),
    %% an invalid byte elsewhere in the page leaves UTF-8 values intact
    Mixed = <<"<head><meta property=\"og:title\" content=\"GitHub ", 194, 183, " Home\"></head><script>", 255, "</script>">>,
    ?assertEqual(<<"GitHub ", 194, 183, " Home">>, maps:get(<<"title">>, pw_embed:parse_og(Mixed, ?URL))),
    %% a byte-limited prefix can end inside a tag and inside a character
    Cut = <<"<head><meta property=\"og:title\" content=\"Whole\"><meta name=\"description\" content=\"cut ", 226, 128>>,
    Meta = pw_embed:parse_og(Cut, ?URL),
    ?assertEqual(<<"Whole">>, maps:get(<<"title">>, Meta)),
    ?assert(is_binary(jsx:encode(Meta))).

response_types_test() ->
    ?assertMatch({ok, #{<<"kind">> := <<"gif">>}}, pw_embed:page_meta(?URL, <<"image/gif">>, <<>>)),
    ?assertMatch({ok, #{<<"kind">> := <<"image">>}}, pw_embed:page_meta(?URL, <<"image/png">>, <<>>)),
    ?assertMatch({ok, #{<<"title">> := <<"T">>}}, pw_embed:page_meta(?URL, <<"text/html">>, <<"<title>T</title>">>)),
    ?assertEqual({error, unsupported_type}, pw_embed:page_meta(?URL, <<"application/pdf">>, <<>>)).
