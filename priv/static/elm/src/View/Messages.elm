module View.Messages exposing (groupedMessageViews)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Lazy as Lazy
import Json.Encode as E
import Set
import Time
import Types exposing (..)
import View.Markdown as Markdown
import View.Ui exposing (..)


groupedMessageViews : Model -> List Message -> List ( String, Html Msg )
groupedMessageViews model messages =
    messages
        |> List.foldl
            (\message ( previous, rendered ) ->
                let
                    grouped =
                        shouldGroup previous message

                    dateChanged =
                        previous |> Maybe.map (\prev -> dateLabel model.timeZone prev.createdAt /= dateLabel model.timeZone message.createdAt) |> Maybe.withDefault True

                    unreadStart =
                        case model.entryReadId of
                            Just marker ->
                                (message.id > marker)
                                    && (previous |> Maybe.map (\prev -> prev.id <= marker) |> Maybe.withDefault True)

                            Nothing ->
                                False

                    row =
                        ( "message-" ++ String.fromInt message.id, messageView model (grouped && not dateChanged) message )

                    divider =
                        ( "date-" ++ String.fromInt message.id, div [ class "message-date" ] [ span [] [ text (dateLabel model.timeZone message.createdAt) ] ] )

                    unreadDivider =
                        ( "unread-" ++ String.fromInt message.id, div [ class "message-date unread-marker", id "unread-marker" ] [ span [] [ text "New messages" ] ] )

                    withDate =
                        if dateChanged then
                            divider :: rendered

                        else
                            rendered

                    withUnread =
                        if unreadStart then
                            unreadDivider :: withDate

                        else
                            withDate
                in
                ( Just message, row :: withUnread )
            )
            ( Nothing, [] )
        |> Tuple.second
        |> List.reverse


dateLabel : Time.Zone -> Int -> String
dateLabel zone millis =
    let
        t =
            Time.millisToPosix millis

        month =
            case Time.toMonth zone t of
                Time.Jan ->
                    "January"

                Time.Feb ->
                    "February"

                Time.Mar ->
                    "March"

                Time.Apr ->
                    "April"

                Time.May ->
                    "May"

                Time.Jun ->
                    "June"

                Time.Jul ->
                    "July"

                Time.Aug ->
                    "August"

                Time.Sep ->
                    "September"

                Time.Oct ->
                    "October"

                Time.Nov ->
                    "November"

                Time.Dec ->
                    "December"
    in
    month ++ " " ++ String.fromInt (Time.toDay zone t) ++ ", " ++ String.fromInt (Time.toYear zone t)


shouldGroup : Maybe Message -> Message -> Bool
shouldGroup previous message =
    case previous of
        Just prev ->
            prev.userId
                == message.userId
                && prev.kind
                == "text"
                && message.kind
                == "text"
                && message.replyTo
                == Nothing
                && prev.id
                >= 0
                && message.id
                >= 0
                && message.createdAt
                - prev.createdAt
                >= 0
                && message.createdAt
                - prev.createdAt
                < 420000

        Nothing ->
            False


messageView : Model -> Bool -> Message -> Html Msg
messageView model grouped m =
    if m.kind == "missed_call" || m.kind == "call_ended" then
        missedCallView model m

    else
        textMessageView model grouped m


textMessageView : Model -> Bool -> Message -> Html Msg
textMessageView model grouped m =
    let
        mine =
            case model.me of
                Just user ->
                    user.id == m.userId

                Nothing ->
                    False

        failed =
            Set.member m.id model.failedMsgIds
    in
    div
        [ class
            ("msg"
                ++ (if mine then
                        " mine"

                    else
                        ""
                   )
                ++ (if grouped then
                        " compact"

                    else
                        ""
                   )
                ++ (if m.id < 0 then
                        " pending"

                    else
                        ""
                   )
                ++ (if failed then
                        " failed"

                    else
                        ""
                   )
            )
        , attribute "data-mid" (String.fromInt m.id)
        , attribute "data-long-context" "true"
        , onContextMenu (OpenMessageCtx m)
        ]
        [ if grouped then
            div [ class "avatar avatar-spacer" ] []

          else
            presenceAvatar model.userStatuses m.userId m.avatarUrl m.displayName ""
        , div [ class "msg-main" ]
            [ if grouped then
                timestampButton model "msg-time compact-time" m

              else
                div [ class "msg-head" ]
                    [ b
                        ([ class "msg-name"
                         , onClick
                            (case ( m.scope, model.currentServer ) of
                                ( "channel", Just data ) ->
                                    ShowServerProfile data.server.id m.userId

                                _ ->
                                    ShowUserPopup m.userId
                            )
                         ]
                            ++ (if String.isEmpty m.roleColor then
                                    []

                                else
                                    [ style "color" m.roleColor ]
                               )
                        )
                        [ text m.displayName ]
                    , botBadge m.isBot
                    , timestampButton model "msg-time" m
                    , if mine then
                        span [ class "pill self-pill" ] [ text "you" ]

                      else
                        text ""
                    ]
            , case m.replyTo of
                Just r ->
                    button
                        [ class "reply-preview"
                        , type_ "button"
                        , onClick (JumpToMessage r.id)
                        , title "Jump to replied-to message"
                        , attribute "aria-label" ("Jump to message from " ++ r.displayName)
                        ]
                        [ span [ class "reply-line", attribute "aria-hidden" "true" ] []
                        , span [ class "reply-author" ] [ text r.displayName ]
                        , span [ class "reply-preview-body" ] [ text r.body ]
                        ]

                Nothing ->
                    text ""
            , if m.pinned then
                span [ class "message-pinned-indicator", title "Pinned message" ]
                    [ span [ attribute "aria-hidden" "true" ] [ text "📌" ]
                    , text " Pinned"
                    ]

              else
                text ""
            , case m.forwardedFrom of
                Just forwarded ->
                    button
                        [ class "forwarded-message-origin"
                        , type_ "button"
                        , onClick (ShowUserPopup forwarded.userId)
                        , title "Open original author's profile"
                        ]
                        [ span [ class "forwarded-icon", attribute "aria-hidden" "true" ] [ text "↗" ]
                        , span [] [ text ("Forwarded from " ++ forwarded.displayName) ]
                        ]

                Nothing ->
                    text ""
            , if model.editingMessageId == Just m.id then
                div [ class "message-editor" ]
                    [ textarea
                        [ class "message-edit-input"
                        , value model.editingMessageText
                        , maxlength 5000
                        , rows 3
                        , onInput EditMessageText
                        , attribute "aria-label" "Edit message"
                        , attribute "data-message-editor" "true"
                        ]
                        []
                    , div [ class "message-edit-actions" ]
                        [ small [ class "muted" ] [ text "Enter to save · Esc to cancel" ]
                        , button [ class "btn ghost", type_ "button", onClick CancelEditMessage, attribute "data-edit-cancel" "true" ] [ text "Cancel" ]
                        , button [ class "btn", type_ "button", onClick (SaveEditMessage m.id), disabled (String.isEmpty (String.trim model.editingMessageText)), attribute "data-edit-save" "true" ] [ text "Save" ]
                        ]
                    ]

              else
                Lazy.lazy2 Markdown.body (Maybe.withDefault "" (Maybe.map .username model.me)) m.body
            , if m.editedAt /= Nothing && model.editingMessageId /= Just m.id then
                small [ class "message-edited", title "This message was edited" ] [ text "(edited)" ]

              else
                text ""
            , renderMessageReactions m
            , if failed then
                div [ class "msg-failed-bar" ]
                    [ span [ class "msg-failed-text" ] [ text "Failed to send" ]
                    , button [ class "msg-action", onClick (RetryMessage m.id) ] [ text "Retry" ]
                    , button [ class "msg-action danger", onClick (DismissFailedMessage m.id) ] [ text "Dismiss" ]
                    ]

              else
                text ""
            , if model.editingMessageId == Just m.id then
                text ""

              else
                div [ class "msg-actions" ]
                    [ button [ class "msg-action", disabled (m.id < 0), onClick (OpenReactionPicker m.id), title "Add reaction" ] [ text "React" ]
                    , button [ class "msg-action", disabled (m.id < 0), onClick (SetReplyTo m) ] [ text "Reply" ]
                    , button [ class "msg-action", disabled (m.id < 0), onClick (OpenForwardModal m) ] [ text "Forward" ]
                    , button [ class "msg-action", onClick (CopyText m.body) ] [ text "Copy" ]
                    , if mine && m.id > 0 && m.forwardedFrom == Nothing then
                        button [ class "msg-action", onClick (StartEditMessage m) ] [ text "Edit" ]

                      else
                        text ""
                    , if mine && m.id > 0 then
                        button [ class "msg-action danger", onClick (DeleteMessage m.id) ] [ text "Delete" ]

                      else
                        text ""
                    ]
            ]
        ]


renderMessageReactions : Message -> Html Msg
renderMessageReactions message =
    if List.isEmpty message.reactions then
        text ""

    else
        div [ class "message-reactions", attribute "aria-label" "Message reactions" ]
            (List.map
                (\reaction ->
                    button
                        [ class ("message-reaction" ++ (if reaction.me then " mine" else ""))
                        , type_ "button"
                        , onClick (ToggleReaction message.id reaction.emoji)
                        , attribute "aria-pressed" (if reaction.me then "true" else "false")
                        , attribute "aria-label" (reaction.emoji ++ " reaction, " ++ String.fromInt reaction.count)
                        , title (if reaction.me then "Remove reaction" else "Add reaction")
                        ]
                        [ span [ class "message-reaction-emoji", attribute "aria-hidden" "true" ] [ text reaction.emoji ]
                        , span [ class "message-reaction-count" ] [ text (String.fromInt reaction.count) ]
                        ]
                )
                message.reactions
            )


missedCallView : Model -> Message -> Html Msg
missedCallView model m =
    let
        mine =
            Maybe.map .id model.me == Just m.userId

        callTitle =
            if m.kind == "call_ended" then
                "Call ended"

            else if mine then
                "No answer"

            else
                "Missed call"

        callDetail =
            if m.kind == "call_ended" then
                m.body

            else if mine then
                "Your call was not answered"

            else
                m.displayName ++ " tried to reach you"

        callAction =
            if m.kind == "call_ended" then
                "Call again"

            else if mine then
                "Call again"

            else
                "Call back"
    in
    div
        [ class ("msg call-event" ++ (if m.kind == "call_ended" then " completed" else "") ++ (if mine then " mine" else ""))
        , attribute "data-mid" (String.fromInt m.id)
        , attribute "role" "note"
        , attribute "aria-label" (callTitle ++ ". " ++ callDetail)
        ]
        [ div [ class "call-event-icon", attribute "aria-hidden" "true" ]
            [ span [ class "ui-icon ui-icon-call" ] [] ]
        , div [ class "call-event-copy" ]
            [ div [ class "call-event-heading" ]
                [ b [] [ text callTitle ]
                , span [ class "call-event-time" ] [ text (timestampText model m) ]
                ]
            , small [] [ text callDetail ]
            ]
        , button
            [ class "btn secondary call-event-action"
            , type_ "button"
            , onClick (BridgeEvent "start_call" (E.int m.scopeId))
            ]
            [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] []
            , text callAction
            ]
        ]


timestampButton : Model -> String -> Message -> Html Msg
timestampButton model cls m =
    button
        [ type_ "button"
        , class cls
        , title "Click to switch timestamp format"
        , onClick ToggleTimestampMode
        ]
        [ text (timestampText model m) ]


timestampText : Model -> Message -> String
timestampText model m =
    if m.id < 0 then
        "sending"

    else if model.absoluteTimestamps then
        absoluteTime model.timeZone m.createdAt

    else
        agoAt model.serverTime m.createdAt ++ " ago"

