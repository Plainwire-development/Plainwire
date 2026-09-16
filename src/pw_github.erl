-module(pw_github).
-export([overview/0, repository/1, commit/2, profile/1, content/3]).

-define(ORG, <<"Plainwire-development">>).
-define(API, <<"https://api.github.com">>).
-define(CACHE, pw_github_cache).
-define(API_VERSION, <<"2026-03-10">>).
-define(MAX_JSON, 4194304).
-define(MAX_CONTENT_JSON, 4194304).
-define(MAX_TEXT_PREVIEW, 524288).
-define(CACHE_MAX_ENTRIES, 128).
-define(CACHE_TARGET_ENTRIES, 96).

%% Public GitHub metadata is fetched server-side so self-hosters can optionally
%% use a token without ever exposing it to browsers. Paths are constructed only
%% beneath the fixed Plainwire organization (or GitHub's public user endpoint),
%% and every response is size-bounded and cached to protect the upstream quota.

overview() ->
    Tasks = [
        {organization, fun() -> cached_json(<<"org">>, <<"/orgs/", ?ORG/binary>>, ?MAX_JSON, fun public_organization/1) end},
        {repositories, fun() -> cached_json(<<"org-repos">>, <<"/orgs/", ?ORG/binary, "/repos?type=public&sort=updated&per_page=100">>, ?MAX_JSON, fun public_repositories/1) end},
        {activity, fun() -> cached_json(<<"org-events">>, <<"/orgs/", ?ORG/binary, "/events?per_page=50">>, ?MAX_JSON) end}
    ],
    Results = parallel(Tasks),
    Repos = value_or(maps:get(repositories, Results, undefined), []),
    FeaturedNames = [<<"Plainwire">>, <<"PlainSimple-License">>, <<"Plainwire-desktop">>, <<"Plainwire-Forum">>],
    Featured = [#{name => Name, available => repo_present(Name, Repos)} || Name <- FeaturedNames],
    {ok, #{
        organization => value_or(maps:get(organization, Results, undefined), #{}),
        repositories => Repos,
        activity => value_or(maps:get(activity, Results, undefined), []),
        featured => Featured,
        errors => errors(Results),
        fetched_at => erlang:system_time(millisecond),
        cache_ttl_ms => cache_ttl_ms()
    }}.

repository(Repo0) ->
    case repo_name(Repo0) of
        {ok, Repo} ->
            case public_repository_meta(Repo) of
                {ok, Meta} -> repository_public(Repo, Meta);
                Error -> Error
            end;
        Error -> Error
    end.

repository_public(Repo, Meta) ->
    Base = <<"/repos/", ?ORG/binary, "/", Repo/binary>>,
    Prefix = <<"repo:", Repo/binary, ":">>,
    Tasks = [
        {languages, fun() -> cached_json(<<Prefix/binary, "languages">>, <<Base/binary, "/languages">>, ?MAX_JSON) end},
        {commits, fun() -> cached_json(<<Prefix/binary, "commits">>, <<Base/binary, "/commits?per_page=30">>, ?MAX_JSON) end},
        {releases, fun() -> cached_json(<<Prefix/binary, "releases">>, <<Base/binary, "/releases?per_page=20">>, ?MAX_JSON) end},
        {tags, fun() -> cached_json(<<Prefix/binary, "tags">>, <<Base/binary, "/tags?per_page=30">>, ?MAX_JSON) end},
        {branches, fun() -> cached_json(<<Prefix/binary, "branches">>, <<Base/binary, "/branches?per_page=30">>, ?MAX_JSON) end},
        {contributors, fun() -> cached_json(<<Prefix/binary, "contributors">>, <<Base/binary, "/contributors?per_page=50">>, ?MAX_JSON) end},
        {contents, fun() -> cached_json(<<Prefix/binary, "contents-root">>, <<Base/binary, "/contents">>, ?MAX_CONTENT_JSON) end},
        {readme, fun() -> cached_json(<<Prefix/binary, "readme">>, <<Base/binary, "/readme">>, ?MAX_CONTENT_JSON, fun decoded_content/1) end}
    ],
    Results = parallel(Tasks),
    Readme = value_or(maps:get(readme, Results, undefined), #{}),
    {ok, #{
        repository => Meta,
        languages => value_or(maps:get(languages, Results, undefined), #{}),
        commits => value_or(maps:get(commits, Results, undefined), []),
        releases => value_or(maps:get(releases, Results, undefined), []),
        tags => value_or(maps:get(tags, Results, undefined), []),
        branches => value_or(maps:get(branches, Results, undefined), []),
        contributors => value_or(maps:get(contributors, Results, undefined), []),
        contents => value_or(maps:get(contents, Results, undefined), []),
        readme => Readme,
        errors => errors(Results),
        fetched_at => erlang:system_time(millisecond)
    }}.

commit(Repo0, Sha0) ->
    case {repo_name(Repo0), commit_sha(Sha0)} of
        {{ok, Repo}, {ok, Sha}} ->
            case ensure_public_repository(Repo) of
                ok ->
                    Path = <<"/repos/", ?ORG/binary, "/", Repo/binary, "/commits/", Sha/binary>>,
                    cached_json(<<"commit:", Repo/binary, ":", Sha/binary>>, Path, ?MAX_CONTENT_JSON);
                Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

profile(Login0) ->
    case github_login(Login0) of
        {ok, Login} ->
            Prefix = <<"profile:", Login/binary, ":">>,
            Tasks = [
                {profile, fun() -> cached_json(<<Prefix/binary, "meta">>, <<"/users/", Login/binary>>, ?MAX_JSON, fun public_profile/1) end},
                {repositories, fun() -> cached_json(<<Prefix/binary, "repos">>, <<"/users/", Login/binary, "/repos?sort=updated&per_page=100">>, ?MAX_JSON, fun public_repositories/1) end},
                {organizations, fun() -> cached_json(<<Prefix/binary, "orgs">>, <<"/users/", Login/binary, "/orgs?per_page=100">>, ?MAX_JSON, fun public_organizations/1) end},
                {activity, fun() -> cached_json(<<Prefix/binary, "events">>, <<"/users/", Login/binary, "/events/public?per_page=30">>, ?MAX_JSON) end}
            ],
            Results = parallel(Tasks),
            case maps:get(profile, Results, undefined) of
                {error, not_found} -> {error, not_found};
                _ -> {ok, #{
                    profile => value_or(maps:get(profile, Results, undefined), #{}),
                    repositories => value_or(maps:get(repositories, Results, undefined), []),
                    organizations => value_or(maps:get(organizations, Results, undefined), []),
                    activity => value_or(maps:get(activity, Results, undefined), []),
                    errors => errors(Results),
                    fetched_at => erlang:system_time(millisecond)
                }}
            end;
        Error -> Error
    end.

content(Repo0, Path0, Ref0) ->
    case {repo_name(Repo0), content_path(Path0), git_ref(Ref0)} of
        {{ok, Repo}, {ok, Path}, {ok, Ref}} ->
            case ensure_public_repository(Repo) of
                ok ->
                    EncodedPath = encode_path(Path),
                    Base = <<"/repos/", ?ORG/binary, "/", Repo/binary, "/contents">>,
                    Resource = case EncodedPath of
                        <<>> -> Base;
                        _ -> <<Base/binary, "/", EncodedPath/binary>>
                    end,
                    Query = case Ref of <<>> -> <<>>; _ -> <<"?ref=", (quote(Ref))/binary>> end,
                    Key = <<"content:", Repo/binary, ":", Path/binary, ":", Ref/binary>>,
                    case cached_json(Key, <<Resource/binary, Query/binary>>, ?MAX_CONTENT_JSON, fun decoded_content/1) of
                        {ok, Data} -> {ok, Data};
                        Error -> Error
                    end;
                Error -> Error
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

public_repository_meta(Repo) ->
    Base = <<"/repos/", ?ORG/binary, "/", Repo/binary>>,
    Key = <<"repo:", Repo/binary, ":meta">>,
    %% Public visibility is an authorization decision, not merely display data.
    %% With a server token, never make that decision from stale cache: the token
    %% might still access a repository that just became private. Without a token,
    %% cached public metadata is safe because all follow-up GitHub reads are also
    %% unauthenticated and therefore cannot cross the public/private boundary.
    Result = case github_token() of
        <<>> -> cached_json(Key, Base, ?MAX_JSON, fun public_repository_metadata/1);
        _ -> fetch_json(Base, ?MAX_JSON, undefined, fun public_repository_metadata/1)
    end,
    case Result of
        {ok, Meta, _Etag} when is_map(Meta) -> public_repository_result(Meta);
        {ok, Meta} when is_map(Meta) -> public_repository_result(Meta);
        {ok, _, _} -> {error, not_found};
        {ok, _} -> {error, not_found};
        Error -> Error
    end.

public_repository_result(Meta) ->
    case public_repository(Meta) of
        true -> {ok, Meta};
        false -> {error, not_found}
    end.

ensure_public_repository(Repo) ->
    case public_repository_meta(Repo) of
        {ok, _} -> ok;
        Error -> Error
    end.

public_repository(Repo) when is_map(Repo) ->
    Private = maps:get(<<"private">>, Repo, true),
    Visibility = maps:get(<<"visibility">>, Repo, undefined),
    Private =:= false andalso (Visibility =:= <<"public">> orelse Visibility =:= undefined);
public_repository(_) -> false.

public_repository_metadata(Repo) when is_map(Repo) ->
    case public_repository(Repo) of
        true ->
            %% A server-side token is only a quota helper. GitHub can add
            %% permission/security/custom-property fields when the token has
            %% broader access, so remove auth-context metadata before the value
            %% reaches either the shared cache or the browser.
            maps:without([
                <<"permissions">>, <<"security_and_analysis">>, <<"temp_clone_token">>,
                <<"role_name">>, <<"custom_properties">>, <<"organization">>
            ], Repo);
        false -> #{}
    end;
public_repository_metadata(_) -> #{}.

public_repositories(Repos) when is_list(Repos) ->
    [public_repository_metadata(Repo) || Repo <- Repos, public_repository(Repo)];
public_repositories(_) -> [].

public_profile(Profile) when is_map(Profile) ->
    %% Deliberately project the public-user shape. Authenticated /users/:login
    %% responses can contain private-account fields when the token belongs to
    %% that user; those must never become Source Hub metadata.
    maps:with([
        <<"login">>, <<"id">>, <<"node_id">>, <<"avatar_url">>, <<"gravatar_id">>,
        <<"url">>, <<"html_url">>, <<"followers_url">>, <<"following_url">>,
        <<"gists_url">>, <<"starred_url">>, <<"subscriptions_url">>,
        <<"organizations_url">>, <<"repos_url">>, <<"events_url">>,
        <<"received_events_url">>, <<"type">>, <<"user_view_type">>,
        <<"site_admin">>, <<"name">>, <<"company">>, <<"blog">>, <<"location">>,
        <<"email">>, <<"hireable">>, <<"bio">>, <<"twitter_username">>,
        <<"public_repos">>, <<"public_gists">>, <<"followers">>, <<"following">>,
        <<"created_at">>, <<"updated_at">>
    ], Profile);
public_profile(_) -> #{}.

public_organization(Org) when is_map(Org) ->
    maps:with([
        <<"login">>, <<"id">>, <<"node_id">>, <<"url">>, <<"repos_url">>,
        <<"events_url">>, <<"hooks_url">>, <<"issues_url">>, <<"members_url">>,
        <<"public_members_url">>, <<"avatar_url">>, <<"description">>, <<"name">>,
        <<"company">>, <<"blog">>, <<"location">>, <<"email">>,
        <<"twitter_username">>, <<"is_verified">>, <<"has_organization_projects">>,
        <<"has_repository_projects">>, <<"public_repos">>, <<"public_gists">>,
        <<"followers">>, <<"following">>, <<"html_url">>, <<"created_at">>,
        <<"updated_at">>, <<"archived_at">>, <<"type">>
    ], Org);
public_organization(_) -> #{}.

public_organizations(Orgs) when is_list(Orgs) ->
    [public_organization(Org) || Org <- Orgs, is_map(Org)];
public_organizations(_) -> [].

repo_present(Name, Repos) when is_list(Repos) ->
    lists:any(fun(R) -> maps:get(<<"name">>, R, <<>>) =:= Name end, Repos);
repo_present(_, _) -> false.

value_or({ok, Value}, _Default) -> Value;
value_or(_, Default) -> Default.

errors(Results) ->
    maps:from_list([
        {Key, error_name(Reason)}
     || {Key, {error, Reason}} <- maps:to_list(Results)
    ]).

error_name(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
error_name(Reason) -> pw_util:bin(Reason).

parallel(Tasks) ->
    Parent = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() -> Parent ! {pw_github_result, Ref, Key, safe_call(Fun)} end),
        {Ref, Key}
    end || {Key, Fun} <- Tasks],
    collect_parallel(Refs, #{}, erlang:monotonic_time(millisecond) + 12000).

safe_call(Fun) ->
    try Fun() of Result -> Result catch _:_ -> {error, upstream_failed} end.

collect_parallel([], Acc, _Deadline) -> Acc;
collect_parallel(Refs, Acc, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {pw_github_result, Ref, Key, Result} ->
            collect_parallel(lists:keydelete(Ref, 1, Refs), Acc#{Key => Result}, Deadline)
    after Remaining ->
        lists:foldl(fun({_Ref, Key}, A) -> A#{Key => {error, timeout}} end, Acc, Refs)
    end.

cached_json(Key, Path, MaxBytes) ->
    cached_json(Key, Path, MaxBytes, fun(Value) -> Value end).

cached_json(Key, Path, MaxBytes, Transform) ->
    case cache_lookup(Key) of
        unavailable -> fetch_uncached(Path, MaxBytes, Transform);
        Cached -> cached_json_with_cache(Key, Path, MaxBytes, Transform, Cached)
    end.

cached_json_with_cache(Key, Path, MaxBytes, Transform, Cached) ->
    Now = erlang:system_time(millisecond),
    Ttl = cache_ttl_ms(),
    StaleFor = erlang:max(900000, Ttl * 6),
    case Cached of
        [{Key, FreshUntil, _StaleUntil, Value, _Etag}] when FreshUntil > Now ->
            {ok, Value};
        [Entry = {Key, _FreshUntil, StaleUntil, Value, Etag}] ->
            case fetch_json(Path, MaxBytes, Etag, Transform) of
                {ok, not_modified, NewEtag} ->
                    store_cache(Key, Value, choose_etag(NewEtag, Etag), Now, Ttl, StaleFor),
                    {ok, Value};
                {ok, Fresh, NewEtag} ->
                    store_cache(Key, Fresh, NewEtag, Now, Ttl, StaleFor),
                    {ok, Fresh};
                {error, not_found} = Error ->
                    %% A repository/user/file may have been removed or made private.
                    %% Do not keep serving a stale public copy after GitHub says 404.
                    delete_cache(Key),
                    Error;
                {error, _} when StaleUntil > Now ->
                    %% GitHub being briefly unavailable should not blank the source hub.
                    touch_stale(Entry, Now, Ttl),
                    {ok, Value};
                Error -> Error
            end;
        [] ->
            case fetch_json(Path, MaxBytes, undefined, Transform) of
                {ok, Fresh, Etag} when Fresh =/= not_modified ->
                    store_cache(Key, Fresh, Etag, Now, Ttl, StaleFor),
                    {ok, Fresh};
                {ok, not_modified, _} -> {error, upstream_failed};
                Error -> Error
            end
    end.

fetch_json(Path, MaxBytes, Etag, Transform) ->
    Url = <<?API/binary, Path/binary>>,
    Opts = #{
        accept => "application/vnd.github+json",
        user_agent => "PlainwireRelay/1.8 SourceHub",
        headers => github_headers(Etag)
    },
    case pw_http_fetch:get(Url, MaxBytes, Opts) of
        {ok, 304, Headers, _} -> {ok, not_modified, header_value(<<"etag">>, Headers)};
        {ok, Code, Headers, Body} when Code >= 200, Code < 300 ->
            try jsx:decode(Body, [return_maps]) of
                Data -> {ok, Transform(Data), header_value(<<"etag">>, Headers)}
            catch _:_ -> {error, invalid_json}
            end;
        {ok, 404, _, _} -> {error, not_found};
        {ok, 403, Headers, _} ->
            case {header_value(<<"x-ratelimit-remaining">>, Headers),
                  header_value(<<"retry-after">>, Headers)} of
                {<<"0">>, _} -> {error, rate_limited};
                {"0", _} -> {error, rate_limited};
                {_, RetryAfter} when RetryAfter =/= undefined -> {error, rate_limited};
                _ -> {error, forbidden}
            end;
        {ok, 429, _, _} -> {error, rate_limited};
        {ok, Code, _, _} when Code >= 500 -> {error, upstream_unavailable};
        {ok, _, _, _} -> {error, upstream_failed};
        {error, _} -> {error, upstream_unavailable}
    end.

github_headers(Etag) ->
    Version = [{<<"x-github-api-version">>, ?API_VERSION}],
    Auth = case github_token() of
        <<>> -> [];
        Token -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
    end,
    Conditional = case Etag of
        undefined -> [];
        <<>> -> [];
        Value -> [{<<"if-none-match">>, pw_util:bin(Value)}]
    end,
    Version ++ Auth ++ Conditional.

github_token() ->
    case os:getenv("PLAINWIRE_GITHUB_TOKEN") of
        false -> <<>>;
        Value -> string:trim(pw_util:bin(Value))
    end.

cache_ttl_ms() ->
    Default = case github_token() of <<>> -> 600000; _ -> 60000 end,
    clamp(pw_util:env_int("PLAINWIRE_GITHUB_CACHE_TTL_MS", Default), 30000, 3600000).

store_cache(Key, Value, Etag, Now, Ttl, StaleFor) ->
    try
        ets:insert(?CACHE, {Key, Now + Ttl, Now + StaleFor, Value, Etag}),
        prune_cache(Now),
        ok
    catch error:badarg -> ok end.

touch_stale({Key, _Fresh, Stale, Value, Etag}, Now, Ttl) ->
    try ets:insert(?CACHE, {Key, Now + erlang:min(Ttl div 4, 60000), Stale, Value, Etag})
    catch error:badarg -> true end,
    ok.

choose_etag(undefined, Old) -> Old;
choose_etag(<<>>, Old) -> Old;
choose_etag(New, _Old) -> New.

cache_lookup(Key) ->
    try ets:lookup(?CACHE, Key)
    catch error:badarg -> unavailable
    end.

fetch_uncached(Path, MaxBytes, Transform) ->
    case fetch_json(Path, MaxBytes, undefined, Transform) of
        {ok, Fresh, _Etag} when Fresh =/= not_modified -> {ok, Fresh};
        {ok, not_modified, _} -> {error, upstream_failed};
        Error -> Error
    end.

delete_cache(Key) ->
    try ets:delete(?CACHE, Key)
    catch error:badarg -> true end,
    ok.

prune_cache(Now) ->
    try
        case ets:info(?CACHE, size) of
            Size when is_integer(Size), Size > ?CACHE_MAX_ENTRIES ->
                Entries = ets:tab2list(?CACHE),
                lists:foreach(fun({Key, _Fresh, Stale, _Value, _Etag}) ->
                    case Stale =< Now of true -> ets:delete(?CACHE, Key); false -> ok end
                end, Entries),
                %% Query parameters can create many legitimate cache keys (profiles,
                %% commits, and source paths). Writes prune after insertion so even
                %% concurrent request bursts settle back below the hard ceiling.
                case ets:info(?CACHE, size) of
                    Remaining when is_integer(Remaining), Remaining > ?CACHE_MAX_ENTRIES ->
                        Live = ets:tab2list(?CACHE),
                        Sorted = lists:keysort(2, Live),
                        Drop = Remaining - ?CACHE_TARGET_ENTRIES,
                        lists:foreach(fun({Key, _, _, _, _}) -> ets:delete(?CACHE, Key) end,
                                      lists:sublist(Sorted, Drop));
                    _ -> ok
                end;
            _ -> ok
        end
    catch error:badarg -> ok end.

header_value(Name0, Headers) ->
    Name = string:lowercase(pw_util:bin(Name0)),
    case [pw_util:bin(V) || {K, V} <- Headers, string:lowercase(pw_util:bin(K)) =:= Name] of
        [V | _] -> V;
        [] -> undefined
    end.

decoded_content(Data) when is_map(Data) ->
    case {maps:get(<<"type">>, Data, <<>>), maps:get(<<"encoding">>, Data, <<>>), maps:get(<<"content">>, Data, <<>>)} of
        {<<"file">>, <<"base64">>, Content} when is_binary(Content), byte_size(Content) > 0 ->
            %% Never echo the upstream base64 blob and its decoded copy to the
            %% browser. Keep the GitHub metadata, plus one bounded text preview.
            Base = (maps:remove(<<"content">>, Data))#{<<"content_omitted">> => true},
            Clean0 = binary:replace(Content, <<"\n">>, <<>>, [global]),
            Clean = binary:replace(Clean0, <<"\r">>, <<>>, [global]),
            try base64:decode(Clean) of
                Bin when byte_size(Bin) =< ?MAX_TEXT_PREVIEW ->
                    case text_preview(Bin) of
                        {ok, Text} -> Base#{<<"decoded_content">> => Text, <<"preview_binary">> => false};
                        error -> Base#{<<"decoded_content">> => <<>>, <<"preview_binary">> => true}
                    end;
                _ -> Base#{<<"decoded_content">> => <<>>, <<"preview_binary">> => false, <<"preview_too_large">> => true}
            catch _:_ -> Base#{<<"decoded_content">> => <<>>, <<"preview_binary">> => true}
            end;
        _ -> Data
    end;
decoded_content(Data) -> Data.

text_preview(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Text when is_binary(Text) ->
            case binary:match(Text, <<0>>) of
                nomatch -> {ok, Text};
                _ -> error
            end;
        _ -> error
    end.

repo_name(Value0) ->
    Value = string:trim(pw_util:bin(Value0)),
    case byte_size(Value) >= 1 andalso byte_size(Value) =< 100 andalso
         Value =/= <<".">> andalso Value =/= <<"..">> andalso valid_repo_chars(Value) of
        true -> {ok, Value};
        false -> {error, invalid_repository}
    end.

valid_repo_chars(<<>>) -> true;
valid_repo_chars(<<C, Rest/binary>>) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                                          (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $_ orelse C =:= $- ->
    valid_repo_chars(Rest);
valid_repo_chars(_) -> false.

commit_sha(Value0) ->
    Value = string:trim(pw_util:bin(Value0)),
    Size = byte_size(Value),
    case Size >= 7 andalso Size =< 64 andalso valid_hex(Value) of
        true -> {ok, Value};
        false -> {error, invalid_commit}
    end.

valid_hex(<<>>) -> true;
valid_hex(<<C, Rest/binary>>) when (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F) -> valid_hex(Rest);
valid_hex(_) -> false.

github_login(Value0) ->
    Value = string:trim(pw_util:bin(Value0)),
    Size = byte_size(Value),
    case Size >= 1 andalso Size =< 39 andalso login_chars(Value) andalso binary:first(Value) =/= $- andalso binary:last(Value) =/= $- of
        true -> {ok, Value};
        false -> {error, invalid_profile}
    end.

login_chars(<<>>) -> true;
login_chars(<<C, Rest/binary>>) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                                    (C >= $0 andalso C =< $9) orelse C =:= $- -> login_chars(Rest);
login_chars(_) -> false.

content_path(undefined) -> {ok, <<>>};
content_path(Value0) ->
    Value = string:trim(pw_util:bin(Value0)),
    case byte_size(Value) =< 1024 andalso safe_path_segments(Value) of
        true -> {ok, Value};
        false -> {error, invalid_path}
    end.

safe_path_segments(<<>>) -> true;
safe_path_segments(Path) ->
    Segments = binary:split(Path, <<"/">>, [global]),
    lists:all(fun(S) -> S =/= <<>> andalso S =/= <<".">> andalso S =/= <<"..">> andalso byte_size(S) =< 255 end, Segments).

git_ref(undefined) -> {ok, <<>>};
git_ref(Value0) ->
    Value = string:trim(pw_util:bin(Value0)),
    case byte_size(Value) =< 255 andalso binary:match(Value, <<0>>) =:= nomatch of
        true -> {ok, Value};
        false -> {error, invalid_ref}
    end.

encode_path(<<>>) -> <<>>;
encode_path(Path) ->
    iolist_to_binary(lists:join(<<"/">>, [quote(S) || S <- binary:split(Path, <<"/">>, [global])])).

quote(Bin) ->
    pw_util:bin(uri_string:quote(binary_to_list(Bin))).

clamp(Value, Min, Max) when is_integer(Value) -> erlang:min(Max, erlang:max(Min, Value));
clamp(_, Min, _Max) -> Min.
