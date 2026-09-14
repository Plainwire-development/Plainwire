module View.Notifications exposing (view)

import Html exposing (Html, a, b, button, div, h1, h2, p, span, text)
import Html.Attributes exposing (attribute, class, disabled, href)
import Html.Events exposing (onClick)
import Types exposing (Model, Msg(..), Notification)


view : (Int -> Int -> String) -> Model -> Html Msg
view relativeTime model =
    let
        unseen =
            List.length (List.filter (\notification -> not notification.seen) model.notifs)
    in
    div [ class "notifications-page page-stack" ]
        [ div [ class "page-heading notifications-head" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "Inbox" ]
                , h1 [] [ text "Notifications" ]
                , p [ class "muted" ]
                    [ text
                        (if unseen == 0 then
                            "You're caught up."

                         else
                            String.fromInt unseen
                                ++ " unread item"
                                ++ (if unseen == 1 then
                                        "."

                                    else
                                        "s."
                                   )
                        )
                    ]
                ]
            , button [ class "btn secondary", onClick ClearNotifs, disabled (List.isEmpty model.notifs) ] [ text "Clear all" ]
            ]
        , div [ class "card notifications-list" ]
            (if List.isEmpty model.notifs then
                [ div [ class "empty notifications-empty" ]
                    [ span [ class "ui-icon ui-icon-notifications", attribute "aria-hidden" "true" ] []
                    , h2 [] [ text "Nothing new" ]
                    , p [] [ text "Mentions, replies, requests, and messages will appear here." ]
                    ]
                ]

             else
                List.map (notificationView relativeTime model.serverTime) model.notifs
            )
        ]


notificationView : (Int -> Int -> String) -> Int -> Notification -> Html Msg
notificationView relativeTime now notification =
    let
        isMention =
            notification.kind == "mention"
    in
    a
        [ class
            ("notification-row"
                ++ (if notification.seen then
                        ""

                    else
                        " unseen"
                   )
                ++ (if isMention then
                        " is-mention"

                    else
                        ""
                   )
            )
        , href notification.url
        , onClick (Go notification.url)
        ]
        [ span [ class "notification-mark", attribute "aria-hidden" "true" ] []
        , div [ class "notification-copy" ]
            [ div [ class "notification-title-row" ]
                [ b [] [ text (notificationLabel notification.kind) ]
                , span [ class "muted notif-time" ] [ text (relativeTime now notification.createdAt) ]
                ]
            , p [] [ text notification.body ]
            ]
        ]


notificationLabel : String -> String
notificationLabel kind =
    case kind of
        "mention" ->
            "Mention"

        "missed_call" ->
            "Missed call"

        "direct_message" ->
            "Direct message"

        "channel_message" ->
            "Channel message"

        "thread_reply" ->
            "Thread reply"

        "message_request" ->
            "Message request"

        "message_request_accepted" ->
            "Request accepted"

        "conversation_created" ->
            "New conversation"

        "conversation_closed" ->
            "Request declined"

        _ ->
            kind
