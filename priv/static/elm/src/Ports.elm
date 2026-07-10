port module Ports exposing
    ( ApiRequest(..), encodeApiRequest, apiSend, apiReceive
    , wsSend, wsReceive
    , bridgeSend, bridgeReceive
    , setHash, onHashChange
    , copyText
    , playRingtone, playOutgoingRingtone, playNotification
    , readFile, fileInput
    , requestNotifyPermission
    )

import Json.Decode as D
import Json.Encode as E


{-| JS boundary for effects Elm cannot perform directly.
FOR FUTURE DEVS:

Keep this module small and boring. Ports are intentionally raw at the boundary,
but callers should prefer typed helpers like `ApiRequest` instead of constructing
JSON ad hoc in feature code. Dont overdo this file.
-}


-- API (HTTP)
-- Encoded requests are consumed by `elm-bridge.js`, which prefixes `/api` and
-- attaches CSRF. Only same-origin absolute-path API routes should be sent.

type ApiRequest
    = ApiGet String
    | ApiPost String (Maybe E.Value)

encodeApiRequest : ApiRequest -> E.Value
encodeApiRequest req =
    case req of
        ApiGet path ->
            E.object
                [ ( "method", E.string "GET" )
                , ( "path", E.string (apiPath path) )
                ]

        ApiPost path body ->
            E.object
                [ ( "method", E.string "POST" )
                , ( "path", E.string (apiPath path) )
                , ( "body", Maybe.withDefault E.null body )
                ]


apiPath : String -> String
apiPath raw =
    let
        trimmed = String.trim raw
    in
    if String.startsWith "/" trimmed then
        trimmed

    else
        "/" ++ trimmed

port apiSend : E.Value -> Cmd msg
port apiReceive : (E.Value -> msg) -> Sub msg


-- WEBSOCKET
-- Incoming websocket payloads must be decoded/validated in Main before use.

port wsSend : E.Value -> Cmd msg
port wsReceive : (E.Value -> msg) -> Sub msg


-- BRIDGE
-- Escape hatch for call/WebRTC and small browser APIs. Prefer adding a typed
-- port above if a command becomes broadly reused.

port bridgeSend : E.Value -> Cmd msg
port bridgeReceive : (E.Value -> msg) -> Sub msg


-- HASH ROUTING

port setHash : String -> Cmd msg
port onHashChange : (String -> msg) -> Sub msg


-- MISC CMD PORTS

port copyText : String -> Cmd msg
port playRingtone : Bool -> Cmd msg
port playOutgoingRingtone : Bool -> Cmd msg
port playNotification : Bool -> Cmd msg
port readFile : String -> Cmd msg
port fileInput : (E.Value -> msg) -> Sub msg
port requestNotifyPermission : Bool -> Cmd msg
