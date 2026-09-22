module View.Ui exposing (..)

import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (custom)
import Json.Decode as D
import Time
import Types exposing (..)


onContextMenu : (Int -> Int -> Msg) -> Attribute Msg
onContextMenu toMsg =
    custom "contextmenu"
        (D.map2
            (\x y -> { message = toMsg x y, stopPropagation = True, preventDefault = True })
            (D.field "clientX" D.int)
            (D.field "clientY" D.int)
        )


stopClick : Attribute Msg
stopClick =
    custom "click" (D.succeed { message = NoOp, stopPropagation = True, preventDefault = False })


onClickStop : Msg -> Attribute Msg
onClickStop msg =
    custom "click" (D.succeed { message = msg, stopPropagation = True, preventDefault = True })


avatarColor : String -> String
avatarColor name =
    let
        palette =
            [ "#5865f2", "#3b82f6", "#16877a", "#37854f", "#9a6716", "#b64d6b", "#7c5bb5", "#a75432" ]

        code =
            case String.uncons (String.toLower name) of
                Just ( first, _ ) ->
                    Char.toCode first

                Nothing ->
                    0

        index =
            modBy (List.length palette) code
    in
    listAt index palette |> Maybe.withDefault "#5865f2"


avatarImg : String -> String -> String -> Html Msg
avatarImg =
    avatarImgWithLoading "lazy"


avatarImgWithLoading : String -> String -> String -> String -> Html Msg
avatarImgWithLoading loadingMode url name cls =
    if String.isEmpty url then
        div [ class ("avatar " ++ cls), style "background-color" (avatarColor name), style "color" "#ffffff" ]
            [ text (String.left 1 (String.toUpper name)) ]

    else
        img
            [ class ("avatar " ++ cls)
            , src url
            , alt (name ++ " avatar")
            , style "background-color" (avatarColor name)
            , attribute "decoding" "async"
            , attribute "loading" loadingMode
            , attribute "fetchpriority"
                (if loadingMode == "eager" then
                    "high"

                 else
                    "low"
                )
            , attribute "data-avatar-fallback" name
            , attribute "data-avatar-src" url
            ]
            []


presenceAvatar : Dict String String -> Int -> String -> String -> String -> Html Msg
presenceAvatar statuses userId url name cls =
    let
        presence =
            statusClass statuses userId

        label =
            case presence of
                "away" ->
                    "Away"

                "busy" ->
                    "Busy"

                "online" ->
                    "Online"

                _ ->
                    "Offline"
    in
    div [ class "presence-avatar", title label, attribute "aria-label" (name ++ "  -  " ++ label) ]
        [ avatarImgWithLoading "lazy" url name cls
        , span [ class ("avatar-presence-dot " ++ presence), attribute "aria-hidden" "true" ] []
        ]



-- APP SHELL


statusClass : Dict String String -> Int -> String
statusClass userStatuses uid =
    case Dict.get (String.fromInt uid) userStatuses of
        Just "online" ->
            "online"

        Just "busy" ->
            "busy"

        Just "away" ->
            "away"

        Just "invisible" ->
            "invisible"

        _ ->
            "offline"


botBadge : Bool -> Html Msg
botBadge isBot =
    if isBot then
        span [ class "pill bot-badge", title "Automated account" ] [ text "BOT" ]

    else
        text ""


cssImage : String -> String
cssImage url =
    let
        unsafe =
            String.any
                (\c -> c == '\'' || c == '"' || c == '(' || c == ')' || c == '\\' || c == '\n' || c == '\r' || c == ';')
                url
    in
    if String.isEmpty url || unsafe then
        "none"

    else
        "url('" ++ url ++ "')"


ago : Int -> Int -> String
ago now t =
    agoAt now t


ellipsize : Int -> String -> String
ellipsize maxLen value =
    let
        trimmed =
            String.trim value
    in
    if String.length trimmed <= maxLen then
        trimmed

    else
        String.left maxLen trimmed ++ "..."


agoAt : Int -> Int -> String
agoAt now t =
    if t == 0 then
        "never"

    else if now <= 0 then
        "now"

    else
        let
            s =
                Basics.max 1 ((now - t) // 1000)
        in
        if s < 60 then
            String.fromInt s ++ "s"

        else
            let
                m =
                    s // 60
            in
            if m < 60 then
                String.fromInt m ++ "m"

            else
                let
                    h =
                        m // 60
                in
                if h < 24 then
                    String.fromInt h ++ "h"

                else
                    String.fromInt (h // 24) ++ "d"


absoluteTime : Time.Zone -> Int -> String
absoluteTime zone t =
    let
        posix =
            Time.millisToPosix t
    in
    pad2 (Time.toHour zone posix) ++ ":" ++ pad2 (Time.toMinute zone posix)


pad2 : Int -> String
pad2 n =
    if n < 10 then
        "0" ++ String.fromInt n

    else
        String.fromInt n


listAt : Int -> List a -> Maybe a
listAt idx items =
    if idx < 0 then
        Nothing

    else
        case items of
            [] ->
                Nothing

            x :: xs ->
                if idx == 0 then
                    Just x

                else
                    listAt (idx - 1) xs

