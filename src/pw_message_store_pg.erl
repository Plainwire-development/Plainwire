-module(pw_message_store_pg).
%% get/1 here is a storage lookup, not erlang:get/1's process dictionary.
-compile({no_auto_import, [get/1]}).
-export([get/1, get_recent/3, get_before/4, get_after/4, get_around/5,
         bulk_get/1, edit/3, delete/2]).

%% PostgreSQL implementation of the storage-only message contract. This module
%% does not perform product authorization; callers that mutate user-visible
%% messages continue to go through pw_db's authenticated domain operations.

get(Id) -> pw_db:storage_pg_message_get(Id).
get_recent(Scope, ScopeId, Limit) -> pw_db:storage_pg_message_recent(Scope, ScopeId, Limit).
get_before(Scope, ScopeId, Before, Limit) -> pw_db:storage_pg_message_before(Scope, ScopeId, Before, Limit).
get_after(Scope, ScopeId, After, Limit) -> pw_db:storage_pg_message_after(Scope, ScopeId, After, Limit).

get_around(Scope, ScopeId, Id, Before, After) ->
    case {get_before(Scope, ScopeId, Id, Before), get(Id), get_after(Scope, ScopeId, Id, After)} of
        {{ok, OlderDesc}, {ok, Mid}, {ok, NewerAsc}} ->
            {ok, lists:reverse(OlderDesc) ++ [Mid] ++ NewerAsc};
        {_, {error, not_found}, _} -> {error, not_found};
        {Error = {error, _}, _, _} -> Error;
        {_, Error = {error, _}, _} -> Error;
        {_, _, Error = {error, _}} -> Error
    end.

bulk_get(Ids) when is_list(Ids) -> pw_db:storage_pg_message_bulk(Ids);
bulk_get(_) -> {error, bad_request}.

edit(Id, Body, EditedAt) -> pw_db:storage_pg_message_edit(Id, Body, EditedAt).
delete(Id, ActorId) -> pw_db:storage_pg_message_delete(Id, ActorId).
