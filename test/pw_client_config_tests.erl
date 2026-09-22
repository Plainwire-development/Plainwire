-module(pw_client_config_tests).
-include_lib("eunit/include/eunit.hrl").

default_theme_is_system_test() ->
    with_env_unset("PLAINWIRE_DEFAULT_THEME", fun() ->
        ?assertEqual(<<"system">>, pw_client_config:default_theme())
    end).

default_theme_accepts_explicit_values_test() ->
    with_env("PLAINWIRE_DEFAULT_THEME", "dark", fun() ->
        ?assertEqual(<<"dark">>, pw_client_config:default_theme())
    end),
    with_env("PLAINWIRE_DEFAULT_THEME", "light", fun() ->
        ?assertEqual(<<"light">>, pw_client_config:default_theme())
    end),
    with_env("PLAINWIRE_DEFAULT_THEME", "system", fun() ->
        ?assertEqual(<<"system">>, pw_client_config:default_theme())
    end).

invalid_default_theme_falls_back_to_system_test() ->
    with_env("PLAINWIRE_DEFAULT_THEME", "neon-space", fun() ->
        ?assertEqual(<<"system">>, pw_client_config:default_theme())
    end).

public_config_has_release_version_test() ->
    Config = pw_client_config:public(),
    ?assert(maps:is_key(version, Config)),
    ?assert(maps:is_key(asset_version, Config)),
    ?assertEqual(<<"2.5.4">>, maps:get(version, Config)),
    ?assert(maps:is_key(password_reset_enabled, Config)),
    AssetVersion = maps:get(asset_version, Config),
    ?assert(is_binary(AssetVersion)),
    ?assert(byte_size(AssetVersion) > 0).

asset_version_override_test() ->
    with_env("PLAINWIRE_ASSET_VERSION", "deploy-20260912", fun() ->
        ?assertEqual(<<"deploy-20260912">>, pw_client_config:asset_version())
    end).

with_env(Name, Value, Fun) ->
    Old = os:getenv(Name),
    os:putenv(Name, Value),
    try Fun()
    after restore_env(Name, Old) end.

with_env_unset(Name, Fun) ->
    Old = os:getenv(Name),
    os:unsetenv(Name),
    try Fun()
    after restore_env(Name, Old) end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).
