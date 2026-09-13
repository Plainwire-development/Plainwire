-module(pw_cluster_local).
-export([deliver/2]).

deliver({user, Uid}, Event) -> gen_server:cast(pw_hub, {notify_user, Uid, Event});
deliver({topic, Key}, Event) -> gen_server:cast(pw_hub, {broadcast, Key, Event}).
