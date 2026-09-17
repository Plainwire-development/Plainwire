-module(pw_message_bucket).
-export([for_timestamp/1, for_timestamp/2, start_ms/1, previous/2, previous/3, next/2, next/3, policy/0]).

-define(DAY_MS, 86400000).

policy() -> pw_scylla_config:bucket_policy().

for_timestamp(Ts) -> for_timestamp(Ts, policy()).

for_timestamp(Ts, day) when is_integer(Ts), Ts >= 0 -> (Ts div ?DAY_MS) * ?DAY_MS;
for_timestamp(Ts, week) when is_integer(Ts), Ts >= 0 -> (Ts div (7 * ?DAY_MS)) * (7 * ?DAY_MS);
for_timestamp(Ts, month) when is_integer(Ts), Ts >= 0 ->
    {{Y, M, _}, _} = calendar:system_time_to_universal_time(Ts, millisecond),
    calendar:datetime_to_gregorian_seconds({{Y, M, 1}, {0, 0, 0}}) * 1000 - epoch_offset_ms().

start_ms(Bucket) when is_integer(Bucket), Bucket >= 0 -> Bucket.

previous(Bucket, Count) -> previous(Bucket, Count, policy()).
previous(_Bucket, Count, _Policy) when Count =< 0 -> [];
previous(Bucket, Count, day) -> [Bucket - I * ?DAY_MS || I <- lists:seq(0, Count - 1), Bucket - I * ?DAY_MS >= 0];
previous(Bucket, Count, week) -> [Bucket - I * 7 * ?DAY_MS || I <- lists:seq(0, Count - 1), Bucket - I * 7 * ?DAY_MS >= 0];
previous(Bucket, Count, month) ->
    {{Y, M, _}, _} = calendar:system_time_to_universal_time(Bucket, millisecond),
    [month_start(add_months(Y, M, -I)) || I <- lists:seq(0, Count - 1)].

add_months(Y, M, Delta) ->
    Zero = Y * 12 + (M - 1) + Delta,
    {Zero div 12, (Zero rem 12) + 1}.

month_start({Y, M}) ->
    calendar:datetime_to_gregorian_seconds({{Y, M, 1}, {0, 0, 0}}) * 1000 - epoch_offset_ms().

epoch_offset_ms() ->
    calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}) * 1000.

next(Bucket, Count) -> next(Bucket, Count, policy()).
next(_Bucket, Count, _Policy) when Count =< 0 -> [];
next(Bucket, Count, day) -> [Bucket + I * ?DAY_MS || I <- lists:seq(0, Count - 1)];
next(Bucket, Count, week) -> [Bucket + I * 7 * ?DAY_MS || I <- lists:seq(0, Count - 1)];
next(Bucket, Count, month) ->
    {{Y, M, _}, _} = calendar:system_time_to_universal_time(Bucket, millisecond),
    [month_start(add_months(Y, M, I)) || I <- lists:seq(0, Count - 1)].
