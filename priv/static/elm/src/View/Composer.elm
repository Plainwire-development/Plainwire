module View.Composer exposing (view)

import Dict
import Html exposing (Attribute, Html, button, div, p, small, span, text, textarea)
import Html.Attributes exposing (attribute, class, disabled, id, maxlength, placeholder, rows, title, type_, value)
import Html.Events exposing (custom, onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Set
import Types exposing (ActiveRoute(..), BotCommand, Model, Msg(..), User)


view : String -> String -> Model -> Html Msg
view key placeholderText model =
    div [ class "composer", attribute "data-draft" key ]
        [ case model.replyTo of
            Just reply ->
                div [ class "reply-bar" ]
                    [ span [ class "reply-to-label" ] [ text ("Replying to " ++ reply.displayName) ]
                    , span [ class "reply-preview-text", title reply.body ] [ text ("“" ++ ellipsize 96 reply.body ++ "”") ]
                    , button [ class "btn secondary", onClick CancelReply ] [ text "Cancel" ]
                    ]

            Nothing ->
                text ""
        , textarea
            [ id "compose"
            , attribute "aria-label" placeholderText
            , maxlength 5000
            , rows 1
            , placeholder placeholderText
            , value model.inputText
            , onInput InputText
            , onComposerKeyDown model.chatEnterSends
            ]
            []
        , commandSuggestions model
        , Html.node "pw-mention-picker"
            [ attribute "data-scope" key
            , attribute "data-members" (mentionCandidatesJson model)
            ]
            []
        , Html.node "pw-typing-indicator"
            [ attribute "data-scope" key
            , attribute "aria-live" "polite"
            , attribute "aria-atomic" "true"
            ]
            []
        , div [ class "composer-footer" ]
            [ button
                [ class "btn secondary attach-btn composer-action"
                , type_ "button"
                , title "Attach files or images"
                , attribute "aria-label" "Attach files or images"
                , onClick (BridgeEvent "pick_attachments" E.null)
                ]
                [ span [ class "ui-icon ui-icon-attach", attribute "aria-hidden" "true" ] []
                , span [ class "composer-action-label" ] [ text "Attach" ]
                ]
            , button
                [ class "btn secondary composer-action spoiler-action"
                , type_ "button"
                , title "Hide or reveal the latest attachment as a spoiler"
                , attribute "aria-label" "Toggle spoiler on latest attachment"
                , onClick ToggleLastAttachmentSpoiler
                ]
                [ span [ class "composer-action-spoiler", attribute "aria-hidden" "true" ] [ text "◐" ]
                , span [ class "composer-action-label" ] [ text "Spoiler" ]
                ]
            , button
                [ class "btn secondary composer-action voice-note-action"
                , type_ "button"
                , title "Record a voice note"
                , attribute "aria-label" "Record a voice note"
                , onClick (BridgeEvent "record_voice_note" E.null)
                ]
                [ span [ class "composer-action-voice", attribute "aria-hidden" "true" ] [ text "●" ]
                , span [ class "composer-action-label" ] [ text "Voice" ]
                ]
            , button
                [ class "btn secondary composer-action gif-action"
                , type_ "button"
                , title "Search GIFs (Ctrl / Cmd + G)"
                , attribute "aria-label" "Search GIFs"
                , onClick (BridgeEvent "open_gif_picker" E.null)
                ]
                [ span [ class "composer-action-gif", attribute "aria-hidden" "true" ] [ text "GIF" ]
                , span [ class "composer-action-label" ] [ text "GIF" ]
                ]
            , Html.details [ class "compose-format-help" ]
                [ Html.summary [ attribute "aria-label" "Message formatting" ]
                    [ span [ class "format-symbol", attribute "aria-hidden" "true" ] [ text "Aa" ]
                    , text "Format"
                    ]
                , div [ class "compose-format-panel", attribute "role" "region", attribute "aria-label" "Formatting tools" ]
                    [ div [ class "format-panel-head" ]
                        [ Html.b [] [ text "Format your message" ]
                        , button [ type_ "button", class "format-close", attribute "data-format-close" "", attribute "aria-label" "Close formatting" ] [ text "×" ]
                        ]
                    , div [ class "format-tools" ]
                        (List.map
                            (\( action, labelText ) -> button [ type_ "button", attribute "data-format" action ] [ text labelText ])
                            [ ( "bold", "Bold" ), ( "italic", "Italic" ), ( "code", "Code" ), ( "quote", "Quote" ), ( "block", "Code block" ) ]
                        )
                    , p [ class "format-tip" ] [ text "Select text first, or start with a button. Ctrl/⌘ + B or I also works." ]
                    , div [ class "compose-preview" ]
                        [ small [] [ text "MESSAGE PREVIEW" ]
                        , if String.isEmpty model.inputText then
                            p [ class "muted" ] [ text "Your formatted message will appear here." ]

                          else
                            Html.node "pw-markdown" [ attribute "source" model.inputText ] []
                        ]
                    , p [ class "format-tip" ] [ text "Markdown supports lists, links, tables, and fenced code. Add a language after the opening ``` to highlight code." ]
                    ]
                ]
            , small [ class "composer-count", attribute "aria-label" "Message character count" ]
                [ text
                    (if String.length model.inputText >= 4000 then
                        String.fromInt (String.length model.inputText) ++ " / 5000"

                     else
                        ""
                    )
                ]
            , small [ class "muted composer-hint" ]
                [ text
                    (if model.chatEnterSends then
                        "Enter to send · Shift + Enter for a new line"

                     else
                        "Enter for a new line · Ctrl + Enter to send"
                    )
                ]
            , button
                [ class "btn composer-send composer-action"
                , disabled (String.isEmpty (String.trim model.inputText))
                , onClick SendMessage
                , attribute "aria-label" "Send message"
                ]
                [ span [ class "composer-action-label" ] [ text "Send" ]
                , span [ class "ui-icon ui-icon-send", attribute "aria-hidden" "true" ] []
                ]
            ]
        ]


commandSuggestions : Model -> Html Msg
commandSuggestions model =
    let
        trimmed =
            String.trimLeft model.inputText

        prefix =
            if String.startsWith "/" trimmed && not (String.contains " " trimmed) then
                String.toLower (String.dropLeft 1 trimmed)

            else
                ""

        matches =
            if String.isEmpty prefix && trimmed /= "/" then
                []

            else
                model.availableCommands
                    |> List.filter (\command -> String.startsWith prefix (String.toLower command.name))
                    |> List.take 8
    in
    if List.isEmpty matches then
        text ""

    else
        div [ class "command-suggestions", attribute "role" "listbox", attribute "aria-label" "Available bot commands" ]
            (List.map
                (\command ->
                    button
                        [ type_ "button"
                        , class "command-suggestion"
                        , onClick (InsertComposerText ("/" ++ command.name ++ " "))
                        ]
                        [ span [ class "command-suggestion-name" ] [ text ("/" ++ command.name) ]
                        , span [ class "command-suggestion-description" ]
                            [ text
                                (if String.isEmpty command.description then
                                    "Bot command"

                                 else
                                    command.description
                                )
                            ]
                        , if String.isEmpty (commandOptionHint command) then
                            text ""

                          else
                            span [ class "command-suggestion-options" ] [ text (commandOptionHint command) ]
                        , span [ class "pill bot-badge" ] [ text "BOT" ]
                        ]
                )
                matches
            )


commandOptionHint : BotCommand -> String
commandOptionHint command =
    command.options
        |> List.map
            (\option ->
                if option.required then
                    "<" ++ option.name ++ ">"

                else
                    "[" ++ option.name ++ "]"
            )
        |> String.join " "


onComposerKeyDown : Bool -> Attribute Msg
onComposerKeyDown enterSends =
    custom "keydown"
        (D.map5
            (\key shift ctrl meta composing ->
                let
                    shouldSend =
                        key
                            == "Enter"
                            && not composing
                            && ((enterSends && not shift) || (not enterSends && (ctrl || meta)))
                in
                if shouldSend then
                    { message = SendMessage, stopPropagation = True, preventDefault = True }

                else
                    { message = NoOp, stopPropagation = False, preventDefault = False }
            )
            (D.field "key" D.string)
            (D.field "shiftKey" D.bool)
            (D.field "ctrlKey" D.bool)
            (D.field "metaKey" D.bool)
            (D.oneOf [ D.field "isComposing" D.bool, D.succeed False ])
        )


mentionCandidatesJson : Model -> String
mentionCandidatesJson model =
    let
        meId =
            Maybe.map .id model.me

        roster =
            List.filter (\member -> meId /= Just member.id) (dedupeUsers (mentionCandidates model))

        sorted =
            List.sortBy (\member -> String.toLower member.displayName) roster

        encodeMember member =
            E.object
                [ ( "id", E.int member.id )
                , ( "name", E.string member.displayName )
                , ( "username", E.string member.username )
                , ( "avatar", E.string member.avatarUrl )
                ]
    in
    E.encode 0 (E.list identity (List.map encodeMember sorted))


dedupeUsers : List User -> List User
dedupeUsers users =
    List.foldr
        (\user ( acc, ids ) ->
            if Set.member user.id ids then
                ( acc, ids )

            else
                ( user :: acc, Set.insert user.id ids )
        )
        ( [], Set.empty )
        users
        |> Tuple.first


mentionCandidates : Model -> List User
mentionCandidates model =
    case model.active of
        DmView conversationId ->
            case Dict.get conversationId model.conversationMembers of
                Just members ->
                    List.map .user members

                Nothing ->
                    model.convs
                        |> List.filter (\conversation -> conversation.id == conversationId)
                        |> List.head
                        |> Maybe.map (\conversation -> List.map .user conversation.members)
                        |> Maybe.withDefault []

        ChannelView _ ->
            serverMembersOrFriends model

        ThreadView _ ->
            serverMembersOrFriends model

        _ ->
            []


serverMembersOrFriends : Model -> List User
serverMembersOrFriends model =
    let
        fromFriends =
            List.filter (\friend -> friend.status == "accepted") model.friends
                |> List.map .user
    in
    case model.currentServer of
        Just server ->
            if List.isEmpty server.members then
                fromFriends

            else
                List.map .user server.members

        Nothing ->
            fromFriends


ellipsize : Int -> String -> String
ellipsize maxLength source =
    let
        trimmed =
            String.trim source
    in
    if String.length trimmed <= maxLength then
        trimmed

    else
        String.left maxLength trimmed ++ "..."
