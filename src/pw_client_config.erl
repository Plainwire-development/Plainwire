-module(pw_client_config).
-export([public/0, version/0, asset_version/0, default_theme/0, upload_max_bytes/0, profile_image_max_bytes/0]).

-define(MAX_UPLOAD_BYTES, 262144000).
-define(MIN_UPLOAD_BYTES, 1048576).
-define(MAX_PROFILE_IMAGE_BYTES, 16777216).

public() ->
    #{media_quality_enabled => os:getenv("PLAINWIRE_MEDIA_QUALITY") =/= "off",
      adaptive_screen => pw_util:env_bool("PLAINWIRE_ADAPTIVE_SCREEN", false),
      version => version(),
      asset_version => asset_version(),
      app_name => clean_app_name(pw_util:env_str("PLAINWIRE_APP_NAME", <<"Plainwire">>)),
      default_theme => default_theme(),
      registration_enabled => pw_util:env_bool("PLAINWIRE_REGISTRATION_ENABLED", true),
      instance_description => pw_util:clean_text(pw_util:env_str("PLAINWIRE_INSTANCE_DESCRIPTION", <<"A fast, self-hosted place to talk.">>), 120),
      upload_max_bytes => upload_max_bytes(),
      profile_image_max_bytes => profile_image_max_bytes(),
      upload_max_files => clamp(pw_util:env_int("PLAINWIRE_UPLOAD_MAX_FILES", 10), 1, 25),
      idle_timeout_ms => clamp(pw_util:env_int("PLAINWIRE_IDLE_TIMEOUT_MS", 600000), 60000, 86400000),
      compress_oversize_uploads => pw_util:env_bool("PLAINWIRE_COMPRESS_OVERSIZE_UPLOADS", true),
      max_image_dimension => clamp(pw_util:env_int("PLAINWIRE_UPLOAD_IMAGE_MAX_DIMENSION", 4096), 512, 8192)}.

version() ->
    case application:get_key(plainwire_relay, vsn) of
        {ok, Vsn} -> pw_util:bin(Vsn);
        _ -> <<"1.7.2-2">>
    end.

asset_version() ->
    Override = pw_util:clean_text(pw_util:env_str("PLAINWIRE_ASSET_VERSION", <<>>), 64),
    case string:trim(Override) of
        <<>> -> cached_asset_version();
        Value -> Value
    end.

cached_asset_version() ->
    Key = {?MODULE, asset_version},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Value = compute_asset_version(),
            persistent_term:put(Key, Value),
            Value;
        Value ->
            Value
    end.

compute_asset_version() ->
    case code:priv_dir(plainwire_relay) of
        Dir when is_list(Dir) ->
            Static = filename:join(Dir, "static"),
            Paths = ["app.js", "app.css", "elm-bridge.js", "bootstrap.js", "call-health.js", "markdown.js", "highlight-all.js"],
            case read_asset_parts(Static, Paths, []) of
                {ok, Parts} ->
                    Hash = pw_util:sha256_hex(iolist_to_binary(lists:reverse(Parts))),
                    binary:part(Hash, 0, erlang:min(16, byte_size(Hash)));
                error ->
                    version()
            end;
        _ ->
            version()
    end.

read_asset_parts(_Static, [], Acc) -> {ok, Acc};
read_asset_parts(Static, [Name | Rest], Acc) ->
    case file:read_file(filename:join(Static, Name)) of
        {ok, Bin} -> read_asset_parts(Static, Rest, [Bin | Acc]);
        _ -> error
    end.

default_theme() ->
    case string:lowercase(pw_util:env_str("PLAINWIRE_DEFAULT_THEME", <<"system">>)) of
        <<"dark">> -> <<"dark">>;
        <<"system">> -> <<"system">>;
        <<"light">> -> <<"light">>;
        _ -> <<"system">>
    end.

upload_max_bytes() ->
    clamp(pw_util:env_int("PLAINWIRE_UPLOAD_MAX_BYTES", ?MAX_UPLOAD_BYTES), ?MIN_UPLOAD_BYTES, ?MAX_UPLOAD_BYTES).

profile_image_max_bytes() ->
    clamp(pw_util:env_int("PLAINWIRE_PROFILE_IMAGE_MAX_BYTES", ?MAX_PROFILE_IMAGE_BYTES), 262144, min(?MAX_PROFILE_IMAGE_BYTES, upload_max_bytes())).

clean_app_name(Value0) ->
    Value = pw_util:clean_text(Value0, 48),
    case string:trim(Value) of
        <<>> -> <<"Plainwire">>;
        Name -> Name
    end.

clamp(Value, Min, Max) when is_integer(Value) -> erlang:min(Max, erlang:max(Min, Value));
clamp(_, Min, _Max) -> Min.
