port module Ports exposing
    ( ApiRequest(..), encodeApiRequest, apiSend, apiReceive
    , wsSend, wsReceive
    , bridgeSend, bridgeReceive
    , setHash, onHashChange
    , setTitle, notify, copyText
    , localStorageGet, localStorageSet
    , playTone, playRingtone, playOutgoingRingtone, playNotification
    , scrollTo, requestAnimationFrame
    , readFile, fileInput
    , requestNotifyPermission
    )

import Json.Decode as D
import Json.Encode as E


-- API (HTTP) - uses fetch via JS

type ApiRequest
    = ApiGet String
    | ApiPost String (Maybe E.Value)

encodeApiRequest : ApiRequest -> E.Value
encodeApiRequest req = case req of
    ApiGet path -> E.object [("method", E.string "GET"), ("path", E.string path)]
    ApiPost path body -> E.object
        [ ("method", E.string "POST"), ("path", E.string path)
        , ("body", Maybe.withDefault E.null body |> identity)
        ]

port apiSend : E.Value -> Cmd msg
port apiReceive : (E.Value -> msg) -> Sub msg


-- WEBSOCKET

port wsSend : E.Value -> Cmd msg
port wsReceive : (E.Value -> msg) -> Sub msg


-- BRIDGE (general JS interop for voice/call/localStorage/etc)

port bridgeSend : E.Value -> Cmd msg
port bridgeReceive : (E.Value -> msg) -> Sub msg


-- HASH ROUTING

port setHash : String -> Cmd msg
port onHashChange : (String -> msg) -> Sub msg


-- MISC CMD PORTS

port setTitle : String -> Cmd msg
port notify : E.Value -> Cmd msg
port copyText : String -> Cmd msg
port localStorageGet : E.Value -> Cmd msg
port localStorageSet : E.Value -> Cmd msg
port playTone : E.Value -> Cmd msg
port playRingtone : Bool -> Cmd msg
port playOutgoingRingtone : Bool -> Cmd msg
port playNotification : Bool -> Cmd msg
port scrollTo : String -> Cmd msg
port requestAnimationFrame : (Int -> msg) -> Sub msg
port readFile : String -> Cmd msg
port fileInput : (E.Value -> msg) -> Sub msg
port requestNotifyPermission : Bool -> Cmd msg
