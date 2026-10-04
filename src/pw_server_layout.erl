-module(pw_server_layout).
-export([validate/2, reconcile/2]).

%% Layouts contain only the caller's server IDs, never server metadata or ACLs.
validate(Items, Members) when is_list(Items), length(Items) =< 500, is_list(Members) ->
    try
        Allowed = sets:from_list(Members),
        {Clean, _, _} = lists:foldl(fun(Item, {Acc, Servers, Folders}) ->
            case Item of
                #{<<"server_id">> := Sid} when map_size(Item) =:= 1 ->
                    checked_server(Sid, Allowed, Servers),
                    {[#{<<"server_id">> => Sid} | Acc], sets:add_element(Sid, Servers), Folders};
                #{<<"id">> := Id, <<"name">> := Name, <<"server_ids">> := Ids, <<"collapsed">> := Collapsed}
                  when map_size(Item) =:= 4, is_binary(Id), byte_size(Id) =< 64,
                       is_binary(Name), byte_size(Name) =< 200, is_list(Ids),
                       length(Ids) > 0, length(Ids) =< 100, is_boolean(Collapsed) ->
                    true = re:run(Id, <<"^[A-Za-z0-9_-]{1,64}$">>, [{capture, none}]) =:= match,
                    false = sets:is_element(Id, Folders),
                    true = sets:size(Folders) < 100,
                    Label = string:trim(pw_util:clean_text(Name, 48)),
                    true = byte_size(Label) > 0,
                    Next = lists:foldl(fun(Sid, Seen) -> checked_server(Sid, Allowed, Seen), sets:add_element(Sid, Seen) end, Servers, Ids),
                    {[#{<<"id">> => Id, <<"name">> => Label, <<"server_ids">> => Ids, <<"collapsed">> => Collapsed} | Acc], Next, sets:add_element(Id, Folders)};
                _ -> throw(invalid_layout)
            end
        end, {[], sets:new(), sets:new()}, Items),
        {ok, lists:reverse(Clean)}
    catch _:_ -> {error, invalid_server_layout} end;
validate(_, _) -> {error, invalid_server_layout}.

checked_server(Sid, Allowed, Seen) ->
    true = is_integer(Sid) andalso Sid > 0,
    true = sets:is_element(Sid, Allowed),
    false = sets:is_element(Sid, Seen),
    ok.

reconcile(Items, Members) ->
    Allowed = sets:from_list(Members),
    Pruned = lists:filtermap(fun
        (#{<<"server_id">> := Sid} = Item) -> case sets:is_element(Sid, Allowed) of true -> {true, Item}; false -> false end;
        (#{<<"server_ids">> := Ids} = Item) ->
            Kept = [Sid || Sid <- Ids, sets:is_element(Sid, Allowed)],
            case Kept of [] -> false; _ -> {true, Item#{<<"server_ids">> => Kept}} end;
        (_) -> false
    end, Items),
    Existing = sets:from_list(lists:flatmap(fun
        (#{<<"server_id">> := Sid}) -> [Sid];
        (#{<<"server_ids">> := Ids}) -> Ids
    end, Pruned)),
    Pruned ++ [#{<<"server_id">> => Sid} || Sid <- Members, not sets:is_element(Sid, Existing)].
