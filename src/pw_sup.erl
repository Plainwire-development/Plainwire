-module(pw_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => pw_rate, start => {pw_rate, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_rate]},
        #{id => pw_hub, start => {pw_hub, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_hub]},
        #{id => pw_media, start => {pw_media, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_media]},
        #{id => pw_db, start => {pw_db, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_db]},
        #{id => pw_upload_gc, start => {pw_upload_gc, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_upload_gc]}
    ],
    {ok, {{one_for_one, 20, 10}, Children}}.
