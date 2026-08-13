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


{-| the JS escape hatch. keep it small and boring, please. -}


-- API (HTTP)
-- elm-bridge adds /api and CSRF. paths stay same-origin.

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
-- decode this stuff in Main before believing it.

port wsSend : E.Value -> Cmd msg
port wsReceive : (E.Value -> msg) -> Sub msg


-- BRIDGE
-- calls/WebRTC and other browser-shaped oddities.

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
