module ServerLayout exposing (decode, encode, reconcile, dropOnServer, dropOnFolder, toggle)

import Json.Decode as D
import Json.Encode as E
import Types exposing (ServerLayoutItem(..))


decode : D.Decoder (List ServerLayoutItem)
decode =
    D.list
        (D.oneOf
            [ D.map ServerEntry (D.field "server_id" D.int)
            , D.map4 (\id name serverIds collapsed -> ServerFolder { id = id, name = name, serverIds = serverIds, collapsed = collapsed })
                (D.field "id" D.string)
                (D.field "name" D.string)
                (D.field "server_ids" (D.list D.int))
                (D.field "collapsed" D.bool)
            ]
        )


encode : List ServerLayoutItem -> E.Value
encode =
    E.list
        (\item ->
            case item of
                ServerEntry sid ->
                    E.object [ ( "server_id", E.int sid ) ]

                ServerFolder folder ->
                    E.object
                        [ ( "id", E.string folder.id )
                        , ( "name", E.string folder.name )
                        , ( "server_ids", E.list E.int folder.serverIds )
                        , ( "collapsed", E.bool folder.collapsed )
                        ]
        )


ids : ServerLayoutItem -> List Int
ids item =
    case item of
        ServerEntry sid ->
            [ sid ]

        ServerFolder folder ->
            folder.serverIds


reconcile : List Int -> List ServerLayoutItem -> List ServerLayoutItem
reconcile members items =
    let
        pruned =
            List.filterMap
                (\item ->
                    case item of
                        ServerEntry sid ->
                            if List.member sid members then Just item else Nothing

                        ServerFolder folder ->
                            let
                                kept = List.filter (\sid -> List.member sid members) folder.serverIds
                            in
                            if List.isEmpty kept then Nothing else Just (ServerFolder { folder | serverIds = kept })
                )
                items

        existing = List.concatMap ids pruned
    in
    pruned ++ List.map ServerEntry (List.filter (\sid -> not (List.member sid existing)) members)


remove : Int -> List ServerLayoutItem -> List ServerLayoutItem
remove sid items =
    reconcile (List.filter ((/=) sid) (List.concatMap ids items)) items


dropOnFolder : Int -> String -> List ServerLayoutItem -> List ServerLayoutItem
dropOnFolder sid target items =
    if List.any (\item -> case item of
                    ServerFolder folder -> folder.id == target && not (List.member sid folder.serverIds) && List.length folder.serverIds < 100
                    _ -> False
                ) items then
        List.map (\item -> case item of
                        ServerFolder folder ->
                            if folder.id == target then ServerFolder { folder | serverIds = folder.serverIds ++ [ sid ], collapsed = False } else item
                        _ -> item
                    ) (remove sid items)
    else
        items


dropOnServer : String -> Int -> Int -> List ServerLayoutItem -> List ServerLayoutItem
dropOnServer newId sid target items =
    if sid == target then
        items
    else
        case List.filterMap (\item -> case item of
                                    ServerFolder folder -> if List.member target folder.serverIds then Just folder.id else Nothing
                                    _ -> Nothing
                                ) items |> List.head of
            Just folderId ->
                dropOnFolder sid folderId items

            Nothing ->
                List.map (\item -> case item of
                                ServerEntry id ->
                                    if id == target then ServerFolder { id = newId, name = "New folder", serverIds = [ target, sid ], collapsed = False } else item
                                _ -> item
                            ) (remove sid items)


toggle : String -> List ServerLayoutItem -> List ServerLayoutItem
toggle target =
    List.map (\item -> case item of
                    ServerFolder folder -> if folder.id == target then ServerFolder { folder | collapsed = not folder.collapsed } else item
                    _ -> item
                )
