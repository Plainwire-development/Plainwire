-module(pw_message_store).
-export([backend/0, get/1, get_recent/3, get_before/4, get_after/4,
         get_around/5, bulk_get/1, edit/3, delete/2]).

%% Stable high-volume storage boundary. Authorization and relational metadata
%% remain outside this module. During a migration, dual mode intentionally
%% keeps PostgreSQL as the read authority until the operator switches to scylla.
backend() -> pw_scylla_config:backend().

%% Message writes are intentionally coordinated by pw_db so PostgreSQL transactions,
%% Scylla write intents, and the durable outbox cannot be bypassed accidentally.

get(Id) -> store_module():get(Id).
get_recent(Scope, ScopeId, Limit) -> store_module():get_recent(Scope, ScopeId, Limit).
get_before(Scope, ScopeId, Before, Limit) -> store_module():get_before(Scope, ScopeId, Before, Limit).
get_after(Scope, ScopeId, After, Limit) -> store_module():get_after(Scope, ScopeId, After, Limit).
get_around(Scope, ScopeId, Id, Before, After) -> store_module():get_around(Scope, ScopeId, Id, Before, After).
bulk_get(Ids) -> store_module():bulk_get(Ids).
edit(Id, Body, EditedAt) -> store_module():edit(Id, Body, EditedAt).
delete(Id, ActorId) -> store_module():delete(Id, ActorId).

store_module() ->
    case backend() of
        scylla -> pw_message_store_scylla;
        postgres -> pw_message_store_pg;
        dual -> pw_message_store_pg
    end.
