module View.Home exposing (Config, view)

import Html exposing (Html, b, button, div, h1, h2, p, section, small, span, text)
import Html.Attributes exposing (attribute, class)
import Html.Events exposing (onClick)
import Types exposing (Conversation, Model, Notification)


type alias Config msg =
    { conversationRow : Conversation -> Html msg
    , navigate : String -> msg
    , newMessage : msg
    , newServer : msg
    , openServers : msg
    , relativeTime : Int -> Int -> String
    , sortConversations : List Conversation -> List Conversation
    }


view : Config msg -> Model -> Html msg
view config model =
    let
        unreadNotifications =
            List.length (List.filter (\notification -> not notification.seen) model.notifs)

        unreadMessages =
            List.sum (List.map (\conversation -> conversation.unread) model.convs)

        recentConversations =
            List.take 5 (config.sortConversations model.convs)

        displayName =
            model.me
                |> Maybe.map .displayName
                |> Maybe.withDefault "there"
    in
    div [ class "home-page home-dashboard" ]
        [ section [ class "home-welcome" ]
            [ div [ class "home-welcome-copy" ]
                [ span [ class "eyebrow" ] [ text "Home" ]
                , h1 [] [ text ("Hello, " ++ displayName ++ ".") ]
                , p [] [ text "Pick up a conversation or see what needs your attention." ]
                ]
            , div [ class "home-primary-actions" ]
                [ button [ class "btn", onClick config.newMessage ] [ text "New message" ]
                , button [ class "btn secondary", onClick config.newServer ] [ text "Create server" ]
                ]
            ]
        , div [ class "stat-grid home-stat-grid", attribute "aria-label" "Workspace overview" ]
            [ statCard "Servers" (String.fromInt (List.length model.servers)) "communities" config.openServers
            , statCard "Unread messages" (String.fromInt unreadMessages) "direct messages" (config.navigate "#dms")
            , statCard "Notifications" (String.fromInt unreadNotifications) "new activity" (config.navigate "#notifications")
            ]
        , div [ class "home-columns" ]
            [ section [ class "card pad home-panel" ]
                [ div [ class "section-head" ]
                    [ div []
                        [ h2 [] [ text "Recent messages" ]
                        , p [ class "muted" ] [ text "Continue where you left off." ]
                        ]
                    , button [ class "btn ghost", onClick (config.navigate "#dms") ] [ text "View all" ]
                    ]
                , div [ class "home-recent-list" ]
                    (if List.isEmpty recentConversations then
                        [ div [ class "empty home-empty" ]
                            [ b [] [ text "No conversations yet" ]
                            , p [] [ text "Start a message when you are ready." ]
                            ]
                        ]

                     else
                        List.map config.conversationRow recentConversations
                    )
                ]
            , section [ class "card pad home-panel home-activity" ]
                [ div [ class "section-head" ]
                    [ div []
                        [ h2 [] [ text "Activity" ]
                        , p [ class "muted" ] [ text "Mentions, replies, and requests." ]
                        ]
                    , button [ class "btn ghost", onClick (config.navigate "#notifications") ] [ text "View all" ]
                    ]
                , div [ class "home-activity-list" ]
                    (if List.isEmpty model.notifs then
                        [ div [ class "empty home-empty" ]
                            [ b [] [ text "You are all caught up" ]
                            , p [] [ text "New activity will appear here." ]
                            ]
                        ]

                     else
                        List.map (notificationView config model.serverTime) (List.take 5 model.notifs)
                    )
                , div [ class "home-quick-links" ]
                    [ button [ class "btn secondary", onClick (config.navigate "#forums") ] [ text "Browse forums" ]
                    , button [ class "btn secondary", onClick (config.navigate "#friends") ] [ text "Friends" ]
                    ]
                ]
            ]
        ]


notificationView : Config msg -> Int -> Notification -> Html msg
notificationView config now notification =
    button
        [ class
            ("home-activity-row"
                ++ (if notification.seen then
                        ""

                    else
                        " unseen"
                   )
            )
        , onClick (config.navigate notification.url)
        ]
        [ span [ class "home-activity-mark", attribute "aria-hidden" "true" ] []
        , span [ class "home-activity-copy" ]
            [ b [] [ text notification.body ]
            , small [ class "muted" ] [ text (activityLabel notification.kind ++ " · " ++ config.relativeTime now notification.createdAt) ]
            ]
        ]


activityLabel : String -> String
activityLabel kind =
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

        _ ->
            "Activity"


statCard : String -> String -> String -> msg -> Html msg
statCard label value note message =
    button [ class "stat-card", onClick message ]
        [ span [ class "stat-value" ] [ text value ]
        , span [ class "stat-card-copy" ]
            [ b [] [ text label ]
            , small [] [ text note ]
            ]
        , span [ class "stat-card-arrow", attribute "aria-hidden" "true" ] [ text "→" ]
        ]
