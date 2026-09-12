-module(pw_client_config).
-export([public/0, default_theme/0, upload_max_bytes/0, profile_image_max_bytes/0]).

-define(MAX_UPLOAD_BYTES, 262144000).
-define(MIN_UPLOAD_BYTES, 1048576).
-define(MAX_PROFILE_IMAGE_BYTES, 16777216).

public() ->
    #{app_name => clean_app_name(pw_util:env_str("PLAINWIRE_APP_NAME", <<"Plainwire">>)),
      default_theme => default_theme(),
      registration_enabled => pw_util:env_bool("PLAINWIRE_REGISTRATION_ENABLED", true),
      instance_description => pw_util:clean_text(pw_util:env_str("PLAINWIRE_INSTANCE_DESCRIPTION", <<"A fast, self-hosted place to talk.">>), 120),
      upload_max_bytes => upload_max_bytes(),
      profile_image_max_bytes => profile_image_max_bytes(),
      upload_max_files => clamp(pw_util:env_int("PLAINWIRE_UPLOAD_MAX_FILES", 10), 1, 25),
      idle_timeout_ms => clamp(pw_util:env_int("PLAINWIRE_IDLE_TIMEOUT_MS", 600000), 60000, 86400000),
      compress_oversize_uploads => pw_util:env_bool("PLAINWIRE_COMPRESS_OVERSIZE_UPLOADS", true),
      max_image_dimension => clamp(pw_util:env_int("PLAINWIRE_UPLOAD_IMAGE_MAX_DIMENSION", 4096), 512, 8192)}.

default_theme() ->
    case string:lowercase(pw_util:env_str("PLAINWIRE_DEFAULT_THEME", <<"light">>)) of
        <<"dark">> -> <<"dark">>;
        <<"system">> -> <<"system">>;
        _ -> <<"light">>
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
