-module(pw_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    case pw_cluster_config:validate(pw_cluster_config:get()) of
        ok -> ok;
        {error, Reason} -> erlang:error({cluster_configuration_error, Reason})
    end,
    ensure_secure_config(),
    %% listener belongs under the supervisor. dead-but-running is a bad look.
    pw_sup:start_link().

stop(_State) -> ok.

ensure_secure_config() ->
    Production = production_env(),
    ensure_upload_config(Production),
    case Production of
        false ->
            ensure_rtc_config(Production);
        true ->
            true = pw_crypto:enabled(),
            true = secure_cookie_configured(),
            true = db_password_configured(),
            true = db_ssl_configured(),
            true = public_url_configured(),
            true = password_cost_configured(),
            ensure_rtc_config(Production)
    end.

ensure_rtc_config(Production) ->
    case pw_rtc_config:validate(Production) of
        ok -> ok;
        {error, Reason} -> erlang:error({insecure_production_config, Reason})
    end.

production_env() ->
    lists:member(os:getenv("PLAINWIRE_ENV"), ["prod", "production"]) orelse
        lists:member(os:getenv("NODE_ENV"), ["prod", "production"]).

secure_cookie_configured() ->
    case os:getenv("COOKIE_SECURE") of
        false ->
            %% This matches pw_util:cookie_secure_default/0: HTTPS public URLs
            %% default to secure cookies when COOKIE_SECURE is not set.
            case os:getenv("PLAINWIRE_PUBLIC_URL") of
                "https://" ++ _ -> true;
                _ -> erlang:error({insecure_production_config, cookie_secure})
            end;
        "1" -> true;
        "true" -> true;
        "TRUE" -> true;
        "yes" -> true;
        _ -> erlang:error({insecure_production_config, cookie_secure})
    end.

db_password_configured() ->
    case os:getenv("PLAINWIRE_DB_PASS") of
        false -> erlang:error({insecure_production_config, db_password});
        "plainwire" -> erlang:error({insecure_production_config, db_password});
        Password when length(Password) >= 16 -> true;
        _ -> erlang:error({insecure_production_config, db_password_too_short})
    end.

db_ssl_configured() ->
    case {os:getenv("PLAINWIRE_DB_SSL"), os:getenv("PLAINWIRE_ALLOW_INSECURE_DB")} of
        {"1", _} -> true;
        {"true", _} -> true;
        {"TRUE", _} -> true;
        {"yes", _} -> true;
        {_, "1"} -> true;
        {_, "true"} -> true;
        {_, "TRUE"} -> true;
        {_, "yes"} -> true;
        _ -> erlang:error({insecure_production_config, db_ssl})
    end.

public_url_configured() ->
    case os:getenv("PLAINWIRE_PUBLIC_URL") of
        "https://" ++ Host when Host =/= [] -> true;
        _ -> erlang:error({insecure_production_config, public_https_url})
    end.

password_cost_configured() ->
    case pw_util:env_int("PLAINWIRE_PBKDF2_ITERS", 160000) of
        N when N >= 100000 -> true;
        _ -> erlang:error({insecure_production_config, password_hash_cost})
    end.

ensure_upload_config(Production) ->
    DirBin = pw_util:env_str("PLAINWIRE_UPLOAD_DIR", <<"data/uploads/">>),
    Dir = binary_to_list(DirBin),
    case Production andalso not (filename:pathtype(Dir) =:= absolute) of
        true -> erlang:error({insecure_production_config, upload_dir_must_be_absolute});
        false -> ok
    end,
    Probe = filename:join(Dir, ".plainwire-write-test"),
    ok = filelib:ensure_dir(Probe),
    case file:write_file(Probe, <<>>, [write, raw]) of
        ok -> file:delete(Probe), ok;
        {error, Reason} -> erlang:error({upload_storage_unavailable, Reason})
    end.
